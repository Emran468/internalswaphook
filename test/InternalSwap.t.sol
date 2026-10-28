// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {BaseTest} from "./utils/BaseTest.sol";
import {InternalSwap} from "../src/InternalSwap.sol";

contract InternalSwapTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    Currency currency0;
    Currency currency1;

    InternalSwap hook;
    PoolKey poolKey;

    // Default hook uses a HIGH threshold so fees only accumulate.
    uint256 constant HIGH_THRESHOLD = 1 ether;
    // Low threshold hook is used to test donations.
    uint256 constant LOW_THRESHOLD = 1e15;

    uint160 constant HOOK_FLAGS = Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        (hook, poolKey) = _deployHookAndPool(HIGH_THRESHOLD, 0x1111);
    }

    // ---------------------------------------------------------------------
    // Basic checks
    // ---------------------------------------------------------------------

    function test_permissions() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();

        assertTrue(p.beforeAddLiquidity);
        assertTrue(p.beforeRemoveLiquidity);
        assertTrue(p.beforeSwap);
        assertTrue(p.afterSwap);
        assertTrue(p.afterSwapReturnDelta);

        assertFalse(p.beforeInitialize);
        assertFalse(p.afterInitialize);
        assertFalse(p.afterAddLiquidity);
        assertFalse(p.afterRemoveLiquidity);
        assertFalse(p.beforeDonate);
        assertFalse(p.afterDonate);
        assertFalse(p.beforeSwapReturnDelta);
        assertFalse(p.afterAddLiquidityReturnDelta);
        assertFalse(p.afterRemoveLiquidityReturnDelta);
    }

    function test_constants() public view {
        assertEq(hook.HOOK_FEE_BPS(), 50);
        assertEq(hook.donateThreshold(), HIGH_THRESHOLD);
    }

    function test_hookCallbacks_revertWhenNotPoolManager() public {
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});

        vm.expectRevert();
        hook.beforeSwap(address(this), poolKey, params, Constants.ZERO_BYTES);
    }

    function test_noFeesPendingBeforeAnySwap() public view {
        InternalSwap.ClaimableFees memory f = hook.pendingFees(poolKey);
        assertEq(f.amount0, 0);
        assertEq(f.amount1, 0);
    }

    // ---------------------------------------------------------------------
    // Fee capture in afterSwap
    // ---------------------------------------------------------------------

    /// Exact input, currency0 -> currency1: unspecified currency is currency1 (the output).
    function test_exactInput_zeroForOne_collectsFeeInCurrency1() public {
        BalanceDelta d = _swapExactIn(poolKey, true, 1e18);

        assertEq(d.amount0(), -1e18);

        uint256 net = _abs(d.amount1());
        InternalSwap.ClaimableFees memory f = hook.pendingFees(poolKey);

        assertGt(f.amount1, 0);
        assertEq(f.amount0, 0);
        // fee == 0.5% of the gross output (net + fee)
        assertEq(f.amount1, ((net + f.amount1) * hook.HOOK_FEE_BPS()) / 10_000);

        // Hook actually holds the tokens
        assertEq(currency1.balanceOf(address(hook)), f.amount1);
        assertEq(currency0.balanceOf(address(hook)), 0);
    }

    /// Exact input, currency1 -> currency0: unspecified currency is currency0 (the output).
    function test_exactInput_oneForZero_collectsFeeInCurrency0() public {
        BalanceDelta d = _swapExactIn(poolKey, false, 1e18);

        assertEq(d.amount1(), -1e18);

        uint256 net = _abs(d.amount0());
        InternalSwap.ClaimableFees memory f = hook.pendingFees(poolKey);

        assertGt(f.amount0, 0);
        assertEq(f.amount1, 0);
        assertEq(f.amount0, ((net + f.amount0) * hook.HOOK_FEE_BPS()) / 10_000);

        assertEq(currency0.balanceOf(address(hook)), f.amount0);
        assertEq(currency1.balanceOf(address(hook)), 0);
    }

    /// Exact output, currency0 -> currency1: unspecified currency is currency0 (the input).
    /// The swapper pays the fee on top, so the hook delta must make them pay MORE.
    function test_exactOutput_zeroForOne_swapperPaysFeeInCurrency0() public {
        BalanceDelta d = _swapExactOut(poolKey, true, 1e18);

        assertEq(d.amount1(), 1e18);

        uint256 paid = _abs(d.amount0());
        InternalSwap.ClaimableFees memory f = hook.pendingFees(poolKey);

        assertGt(f.amount0, 0);
        assertEq(f.amount1, 0);
        // fee == 0.5% of the gross input (paid - fee)
        assertEq(f.amount0, ((paid - f.amount0) * hook.HOOK_FEE_BPS()) / 10_000);

        assertEq(currency0.balanceOf(address(hook)), f.amount0);
    }

    function test_fees_accumulateBelowThreshold() public {
        _swapExactIn(poolKey, true, 1e18);
        uint256 first = hook.pendingFees(poolKey).amount1;
        assertGt(first, 0);
        assertLt(first, HIGH_THRESHOLD);

        _swapExactIn(poolKey, true, 1e18);
        uint256 second = hook.pendingFees(poolKey).amount1;

        // Nothing was donated, so pending fees only grow
        assertGt(second, first);
        assertEq(currency1.balanceOf(address(hook)), second);
    }

    function testFuzz_feeIsHalfPercentOfGrossOutput(uint96 amountIn) public {
        uint256 amount = bound(uint256(amountIn), 1e12, 10e18);

        BalanceDelta d = _swapExactIn(poolKey, true, amount);

        uint256 net = _abs(d.amount1());
        uint256 fee = hook.pendingFees(poolKey).amount1;

        assertEq(fee, ((net + fee) * 50) / 10_000);
        assertEq(currency1.balanceOf(address(hook)), fee);
    }

    // ---------------------------------------------------------------------
    // Fee distribution (donate)
    // ---------------------------------------------------------------------

    function test_donatesBeforeNextSwap_whenThresholdReached() public {
        (InternalSwap h, PoolKey memory k) = _deployHookAndPool(LOW_THRESHOLD, 0x2222);

        // First swap collects a fee above the threshold
        _swapExactIn(k, true, 1e18);
        InternalSwap.ClaimableFees memory f1 = h.pendingFees(k);
        assertGe(f1.amount1, LOW_THRESHOLD);
        assertEq(currency1.balanceOf(address(h)), f1.amount1);

        // Second swap: beforeSwap donates the first fee to LPs
        vm.expectEmit(true, false, false, false, address(h));
        emit InternalSwap.FeesDonated(k.toId(), 0, 0);
        _swapExactIn(k, true, 1e18);

        // After the donation, only the second swap's fee is held by the hook
        InternalSwap.ClaimableFees memory f2 = h.pendingFees(k);
        assertEq(currency1.balanceOf(address(h)), f2.amount1);
    }

    function test_donatesBeforeAddLiquidity_andResetsPending() public {
        (InternalSwap h, PoolKey memory k) = _deployHookAndPool(LOW_THRESHOLD, 0x3333);

        _swapExactIn(k, true, 1e18);
        assertGe(h.pendingFees(k).amount1, LOW_THRESHOLD);

        // Adding liquidity triggers beforeAddLiquidity -> distribute
        _addLiquidity(k, 10e18);

        InternalSwap.ClaimableFees memory f = h.pendingFees(k);
        assertEq(f.amount0, 0);
        assertEq(f.amount1, 0);
        assertEq(currency1.balanceOf(address(h)), 0);
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    /// Deploys a fresh hook (with a unique address namespace) and a pool using it.
    function _deployHookAndPool(uint256 threshold, uint16 salt) internal returns (InternalSwap h, PoolKey memory key) {
        address flags = address(uint160(HOOK_FLAGS) ^ (uint160(salt) << 144));

        bytes memory constructorArgs = abi.encode(poolManager, threshold);
        deployCodeTo("InternalSwap.sol:InternalSwap", constructorArgs, flags);
        h = InternalSwap(flags);

        key = PoolKey(currency0, currency1, 3000, 60, IHooks(h));
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);

        _addLiquidity(key, 100e18);
    }

    function _addLiquidity(PoolKey memory key, uint128 liquidity) internal {
        int24 tickLower = TickMath.minUsableTick(key.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(key.tickSpacing);

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());

        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96, TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), liquidity
        );

        positionManager.mint(
            key,
            tickLower,
            tickUpper,
            liquidity,
            amount0 + 1,
            amount1 + 1,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );
    }

    function _swapExactIn(PoolKey memory key, bool zeroForOne, uint256 amountIn) internal returns (BalanceDelta) {
        return swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
    }

    function _swapExactOut(PoolKey memory key, bool zeroForOne, uint256 amountOut) internal returns (BalanceDelta) {
        return swapRouter.swapTokensForExactTokens({
            amountOut: amountOut,
            amountInMax: 100e18,
            zeroForOne: zeroForOne,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
    }

    function _abs(int128 x) internal pure returns (uint256) {
        return x < 0 ? uint256(-int256(x)) : uint256(int256(x));
    }
}
