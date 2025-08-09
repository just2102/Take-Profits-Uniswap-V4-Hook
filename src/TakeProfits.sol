// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";

contract TakeProfits is BaseHook, ERC1155 {
    // StateLibrary is new here and we haven't seen that before
    // It's used to add helper functions to the PoolManager to read
    // storage values.
    // In this case, we use it for accessing `currentTick` values
    // from the pool manager
    using StateLibrary for IPoolManager;

    error InvalidOrder();
    error NothingToClaim();
    error NotEnoughToClaim();

    constructor(IPoolManager _manager, string memory _uri) BaseHook(_manager) ERC1155(_uri) {}

    mapping(PoolId poolId => mapping(int24 tick => mapping(bool zeroForOne => uint256 amount))) public pendingOrders;
    mapping(uint256 orderId => uint256 claimsSupply) public claimTokensSupply;
    mapping(uint256 orderId => uint256 outputClaimable) public claimableOutputTokens;
    mapping(PoolId poolId => int24 lastTick) public lastTicks;

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick) internal override returns (bytes4) {
        lastTicks[key.toId()] = tick;
        return this.afterInitialize.selector;
    }

    function _afterSwap(address sender, PoolKey calldata key, SwapParams calldata params, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        // prevent reentrance & recursive swaps
        if (sender == address(this)) return (this.afterSwap.selector, 0);

        bool shouldSwapMore = true;
        int24 currentTick;

        while (shouldSwapMore) {
            // reverse zeroForOne since we want to trade the opposite
            // e.g. if someone sold token0 we will sell token1 since its price has increased
            (shouldSwapMore, currentTick) = tryExecuteOrders(key, !params.zeroForOne);
        }

        lastTicks[key.toId()] = currentTick;
        return (this.afterSwap.selector, 0);
    }

    function tryExecuteOrders(PoolKey calldata key, bool zeroForOne) internal returns (bool, int24) {
        (, int24 currentTick,,) = poolManager.getSlot0(key.toId());
        int24 lastTick = lastTicks[key.toId()];
        int24 currentTickToUse = getLowerUsableTick(currentTick, key.tickSpacing);

        if (currentTickToUse < lastTick) {
            for (int24 tick = lastTick; tick >= currentTickToUse; tick -= key.tickSpacing) {
                uint256 inputAmount = pendingOrders[key.toId()][tick][zeroForOne];
                if (inputAmount > 0) {
                    executeOrder(key, tick, zeroForOne, inputAmount);
                    return (true, tick);
                }
            }
        } else if (currentTickToUse > lastTick) {
            for (int24 tick = lastTick; tick <= currentTickToUse; tick += key.tickSpacing) {
                uint256 inputAmount = pendingOrders[key.toId()][tick][zeroForOne];
                if (inputAmount > 0) {
                    executeOrder(key, tick, zeroForOne, inputAmount);
                    return (true, tick);
                }
            }
        }

        return (false, currentTick);
    }

    function placeOrder(PoolKey calldata key, bool zeroForOne, uint256 amount, int24 sellTick)
        external
        returns (int24)
    {
        int24 tick = getLowerUsableTick(sellTick, key.tickSpacing);

        pendingOrders[key.toId()][tick][zeroForOne] += amount;

        uint256 orderId = getOrderId(key, tick, zeroForOne);
        claimTokensSupply[orderId] += amount;
        _mint(msg.sender, orderId, amount, "");

        transferTokens(key, zeroForOne, amount, msg.sender, address(this), false);

        return tick;
    }

    function cancelOrder(PoolKey calldata key, int24 sellTick, bool zeroForOne, uint256 amountToCancel) external {
        int24 tick = getLowerUsableTick(sellTick, key.tickSpacing);
        uint256 orderId = getOrderId(key, tick, zeroForOne);

        uint256 positionTokens = balanceOf(msg.sender, orderId);
        if (positionTokens <= 0) {
            revert NothingToClaim();
        }
        if (positionTokens < amountToCancel) {
            revert NotEnoughToClaim();
        }

        pendingOrders[key.toId()][tick][zeroForOne] -= amountToCancel;
        claimTokensSupply[orderId] -= amountToCancel;
        _burn(msg.sender, orderId, amountToCancel);

        Currency token = zeroForOne ? key.currency0 : key.currency1;
        token.transfer(msg.sender, amountToCancel);
    }

    function redeem(PoolKey calldata key, int24 sellTick, bool zeroForOne, uint256 inputAmountToClaimFor) external {
        int24 tick = getLowerUsableTick(sellTick, key.tickSpacing);
        uint256 orderId = getOrderId(key, tick, zeroForOne);

        if (claimableOutputTokens[orderId] == 0) {
            revert NothingToClaim();
        }
        uint256 claimTokens = balanceOf(msg.sender, orderId);
        if (claimTokens < inputAmountToClaimFor) {
            revert NotEnoughToClaim();
        }

        uint256 outputAmount = FixedPointMathLib.mulDivDown(
            inputAmountToClaimFor, claimableOutputTokens[orderId], claimTokensSupply[orderId]
        );

        claimableOutputTokens[orderId] -= outputAmount;
        claimTokensSupply[orderId] -= inputAmountToClaimFor;
        _burn(msg.sender, orderId, inputAmountToClaimFor);

        transferTokens(key, zeroForOne, outputAmount, address(this), msg.sender, true);
    }

    function executeOrder(PoolKey calldata key, int24 tick, bool zeroForOne, uint256 amount) internal {
        BalanceDelta delta = swapAndSettleBalances(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amount),
                // todo: calculate sqrtPriceLimitX96 correctly based on slippage settings
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );

        pendingOrders[key.toId()][tick][zeroForOne] -= amount;
        uint256 orderId = getOrderId(key, tick, zeroForOne);
        uint256 outputAmount = zeroForOne ? uint256(int256(delta.amount1())) : uint256(int256(delta.amount0()));
        claimableOutputTokens[orderId] += outputAmount;
    }

    function swapAndSettleBalances(PoolKey calldata key, SwapParams memory params) internal returns (BalanceDelta) {
        BalanceDelta delta = poolManager.swap(key, params, "");

        if (params.zeroForOne) {
            if (delta.amount0() < 0) {
                _settle(key.currency0, uint128(-delta.amount0()));
            }

            if (delta.amount1() > 0) {
                _take(key.currency1, uint128(delta.amount1()));
            }
        } else {
            if (delta.amount0() > 0) {
                _take(key.currency0, uint128(delta.amount0()));
            }

            if (delta.amount1() < 0) {
                _settle(key.currency1, uint128(-delta.amount1()));
            }
        }

        return delta;
    }

    function _settle(Currency currency, uint128 amount) internal {
        poolManager.sync(currency);
        if (currency == CurrencyLibrary.ADDRESS_ZERO) {
            SafeTransferLib.safeTransferETH(address(poolManager), amount);
        } else {
            currency.transfer(address(poolManager), amount);
        }
        poolManager.settle();
    }

    function _take(Currency currency, uint128 amount) internal {
        poolManager.take(currency, address(this), amount);
    }

    function getOrderId(PoolKey calldata key, int24 tick, bool zeroForOne) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(key.toId(), tick, zeroForOne)));
    }

    function getLowerUsableTick(int24 tick, int24 tickSpacing) internal pure returns (int24) {
        int24 intervals = tick / tickSpacing;

        if (tick < 0 && tick % tickSpacing != 0) {
            intervals--;
        }

        return intervals * tickSpacing;
    }

    function transferTokens(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amount,
        address from,
        address to,
        bool isRedeem
    ) internal {
        Currency token;
        if (isRedeem) {
            token = zeroForOne ? key.currency1 : key.currency0;
        } else {
            token = zeroForOne ? key.currency0 : key.currency1;
        }

        if (token == CurrencyLibrary.ADDRESS_ZERO) {
            return SafeTransferLib.safeTransferETH(to, amount);
        }

        if (isRedeem) {
            return token.transfer(to, amount);
        }

        IERC20(Currency.unwrap(token)).transferFrom(from, to, amount);
    }
}
