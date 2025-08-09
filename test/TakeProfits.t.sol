// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

import {TakeProfits} from "../src/TakeProfits.sol";

contract LimitOrderBookTest is Test, Deployers, ERC1155Holder {
    TakeProfits public hook;

    using StateLibrary for IPoolManager;

    int24 TICK_SPACING = 30;

    Currency token0;
    Currency token1;
    PoolKey poolKey;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployHook();
        deployTokens();
        deployPool();
    }

    function test_PlaceOrder() external {
        int24 tick = 100;
        uint256 amount = 10e18;
        bool zeroForOne = true;

        uint256 originalBalanceToken0 = token0.balanceOfSelf();

        int24 tickLower = _placeOrder(tick, amount, zeroForOne);
        uint256 newBalanceToken0 = token0.balanceOfSelf();
        assertEq(tickLower, 90);
        assertEq(originalBalanceToken0 - newBalanceToken0, amount);

        uint256 orderId = hook.getOrderId(key, tickLower, zeroForOne);
        uint256 tokenBalance = hook.balanceOf(address(this), orderId);
        assertTrue(orderId != 0);
        assertEq(tokenBalance, amount);
    }

    function test_CancelOrder() external {
        int24 tick = 100;
        uint256 amount = 10e18;
        bool zeroForOne = true;

        uint256 originalBalanceToken0 = token0.balanceOfSelf();
        int24 tickLower = _placeOrder(tick, amount, zeroForOne);
        uint256 newBalanceToken0 = token0.balanceOfSelf();
        assertEq(tickLower, 90);
        assertEq(originalBalanceToken0 - newBalanceToken0, amount);

        uint256 orderId = hook.getOrderId(key, tickLower, zeroForOne);
        uint256 tokenBalance = hook.balanceOf(address(this), orderId);
        assertTrue(orderId != 0);
        assertEq(tokenBalance, amount);

        hook.cancelOrder(key, tickLower, zeroForOne, amount);
        uint256 finalBalance = token0.balanceOfSelf();
        assertEq(finalBalance, originalBalanceToken0);

        tokenBalance = hook.balanceOf(address(this), orderId);
        assertEq(tokenBalance, 0);
    }

    function test_orderExecute_zeroForOne() public {
        int24 tick = 60;
        uint256 amount = 1 ether;
        bool zeroForOne = true;

        int24 tickLower = _placeOrder(tick, amount, zeroForOne);

        SwapParams memory params = SwapParams({
            zeroForOne: !zeroForOne,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        uint256 pendingTokenPositionBefore = hook.pendingOrders(key.toId(), tick, zeroForOne);
        assertEq(pendingTokenPositionBefore, 1 ether);

        swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        uint256 pendingTokenPosition = hook.pendingOrders(key.toId(), tick, zeroForOne);
        assertEq(pendingTokenPosition, 0);

        uint256 orderId = hook.getOrderId(key, tickLower, zeroForOne);
        uint256 claimableOutputTokensForOrderId = hook.claimableOutputTokens(orderId);
        uint256 hookContractTokenBalance = token1.balanceOf(address(hook));
        assertEq(claimableOutputTokensForOrderId, hookContractTokenBalance);

        uint256 token1BalanceBeforeRedeem = token1.balanceOf(address(this));
        hook.redeem(key, tick, zeroForOne, amount);
        uint256 newToken1Balance = token1.balanceOf(address(this));

        assertEq(newToken1Balance - token1BalanceBeforeRedeem, claimableOutputTokensForOrderId);
    }

    function test_orderExecute_oneForZero() public {
        int24 tick = -60;
        uint256 amount = 1 ether;
        bool zeroForOne = false;

        int24 tickLower = _placeOrder(tick, amount, zeroForOne);

        SwapParams memory params = SwapParams({
            zeroForOne: !zeroForOne,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        uint256 pendingTokenPositionBefore = hook.pendingOrders(key.toId(), tick, zeroForOne);
        assertEq(pendingTokenPositionBefore, 1 ether);

        swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        uint256 pendingTokenPosition = hook.pendingOrders(key.toId(), tick, zeroForOne);
        assertEq(pendingTokenPosition, 0);

        uint256 orderId = hook.getOrderId(key, tickLower, zeroForOne);
        uint256 claimableOutputTokensForOrderId = hook.claimableOutputTokens(orderId);
        uint256 hookContractTokenBalance = token0.balanceOf(address(hook));
        assertEq(claimableOutputTokensForOrderId, hookContractTokenBalance);

        uint256 token0BalanceBeforeRedeem = token0.balanceOf(address(this));
        hook.redeem(key, tick, zeroForOne, amount);
        uint256 newToken0Balance = token0.balanceOf(address(this));

        assertEq(newToken0Balance - token0BalanceBeforeRedeem, claimableOutputTokensForOrderId);
    }

    function test_orderExecute_zeroForOne_onlyOne() public {
        uint256 amount = 0.01 ether;
        bool zeroForOne = true;

        // only first order should be fulfilled
        // since executing it moves the tick above 60
        int24 tickFirst = _placeOrder(0, amount, zeroForOne);
        int24 tickSecond = _placeOrder(60, amount, zeroForOne);

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        (, int24 currentTick,,) = manager.getSlot0(key.toId());
        assertEq(currentTick, 0);

        SwapParams memory params = SwapParams({
            zeroForOne: !zeroForOne,
            amountSpecified: -0.1 ether,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });

        swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        uint256 tokensLeftToSellOrder1 = hook.pendingOrders(key.toId(), tickFirst, zeroForOne);
        assertEq(tokensLeftToSellOrder1, 0);

        uint256 tokensLeftToSellOrder2 = hook.pendingOrders(key.toId(), tickSecond, zeroForOne);
        assertEq(tokensLeftToSellOrder2, amount);
    }

    function test_multiple_orderExecute_zeroForOne_both() public {
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        uint256 amount = 0.01 ether;
        bool zeroForOne = true;

        // both orders should be executed
        // since executing the first order does not increase the tick above 30
        int24 tickFirst = _placeOrder(0, amount, zeroForOne);
        int24 tickSecond = _placeOrder(30, amount, zeroForOne);

        SwapParams memory params =
            SwapParams({zeroForOne: false, amountSpecified: -0.1 ether, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1});

        (, int24 currentTick,,) = manager.getSlot0(key.toId());
        assertEq(currentTick, 0);

        swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        uint256 tokensLeftToSell = hook.pendingOrders(key.toId(), tickFirst, true);
        assertEq(tokensLeftToSell, 0);

        tokensLeftToSell = hook.pendingOrders(key.toId(), tickSecond, true);
        assertEq(tokensLeftToSell, 0);
    }

    function _placeOrder(int24 tick, uint256 amount, bool zeroForOne) internal returns (int24) {
        int24 tickLower = hook.placeOrder(poolKey, zeroForOne, amount, tick);
        return tickLower;
    }

    function deployTokens() internal {
        (token0, token1) = deployMintAndApprove2Currencies();
        uint256 token1BalanceBeforeAnything = token1.balanceOf(address(this));

        MockERC20(Currency.unwrap(token0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(token1)).approve(address(hook), type(uint256).max);
    }

    function deployHook() internal {
        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG) | uint160(Hooks.AFTER_SWAP_FLAG);

        string memory uri = "https://test.api.com";
        deployCodeTo("TakeProfits.sol", abi.encode(manager, uri), address(flags));

        hook = TakeProfits(address(flags));
    }

    function deployPool() internal {
        (key,) = initPool(token0, token1, hook, 3000, TICK_SPACING, SQRT_PRICE_1_1);
        poolKey = key;
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 10 ether, salt: bytes32(0)}),
            ZERO_BYTES
        );

        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 10 ether, salt: bytes32(0)}),
            ZERO_BYTES
        );

        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }
}
