// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// NOTE: use the same BaseHook import line that your own repo already uses.
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

/// @title InternalSwap
/// @notice Takes a small extra fee on every swap, holds it in the hook, and
///         donates it to the pool's LPs once enough has been collected.
/// @dev Simplified alternative to an "internal swap pool" hook: no order filling
///      in beforeSwap, only fee capture (afterSwap) and fee distribution (donate).
contract InternalSwap is BaseHook {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using StateLibrary for IPoolManager;

    /// @dev Fees collected but not yet donated, per pool
    struct ClaimableFees {
        uint256 amount0;
        uint256 amount1;
    }

    mapping(PoolId => ClaimableFees) internal _poolFees;

    /// Extra hook fee in basis points (50 = 0.5%) taken from the unspecified currency
    uint256 public constant HOOK_FEE_BPS = 50;
    uint256 private constant BPS_DENOMINATOR = 10_000;

    /// Minimum collected amount (raw token units) before a donation is made
    uint256 public immutable donateThreshold;

    event FeesCollected(PoolId indexed poolId, Currency indexed currency, uint256 amount);
    event FeesDonated(PoolId indexed poolId, uint256 amount0, uint256 amount1);

    constructor(IPoolManager _poolManager, uint256 _donateThreshold) BaseHook(_poolManager) {
        donateThreshold = _donateThreshold;
    }

    /// @notice Fees currently waiting to be donated for a pool
    function pendingFees(PoolKey calldata key) external view returns (ClaimableFees memory) {
        return _poolFees[key.toId()];
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---------------------------------------------------------------------
    // Hook callbacks
    // ---------------------------------------------------------------------

    /// Donate collected fees before the swap so the swapper pays into a pool
    /// that has already been topped up.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _distributeFees(key);
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// Take the hook fee from the unspecified currency of the swap.
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        // Unspecified currency: output for exact-input, input for exact-output
        bool unspecifiedIsCurrency1 = (params.amountSpecified < 0) == params.zeroForOne;
        Currency unspecified = unspecifiedIsCurrency1 ? key.currency1 : key.currency0;
        int128 amount = unspecifiedIsCurrency1 ? delta.amount1() : delta.amount0();

        // Use the absolute value (it is negative when the swapper pays this currency)
        uint256 absAmount = amount < 0 ? uint256(-int256(amount)) : uint256(int256(amount));
        uint256 fee = (absAmount * HOOK_FEE_BPS) / BPS_DENOMINATOR;

        if (fee == 0) return (this.afterSwap.selector, 0);

        // Record the fee, then pull the tokens into this contract
        PoolId poolId = key.toId();
        if (unspecifiedIsCurrency1) {
            _poolFees[poolId].amount1 += fee;
        } else {
            _poolFees[poolId].amount0 += fee;
        }
        unspecified.take(poolManager, address(this), fee, false);

        emit FeesCollected(poolId, unspecified, fee);

        // Positive value: the hook keeps this amount out of the swapper's delta
        return (this.afterSwap.selector, int128(int256(fee)));
    }

    /// Distribute before liquidity changes so new LPs do not share fees they did not earn.
    function _beforeAddLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        internal
        override
        returns (bytes4)
    {
        _distributeFees(key);
        return this.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        internal
        override
        returns (bytes4)
    {
        _distributeFees(key);
        return this.beforeRemoveLiquidity.selector;
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    function _distributeFees(PoolKey calldata key) internal {
        PoolId poolId = key.toId();
        ClaimableFees memory fees = _poolFees[poolId];

        // Not enough collected yet
        if (fees.amount0 < donateThreshold && fees.amount1 < donateThreshold) return;

        // donate() reverts if the pool has no liquidity
        if (poolManager.getLiquidity(poolId) == 0) return;

        // Effects before interactions
        delete _poolFees[poolId];

        BalanceDelta delta = poolManager.donate(key, fees.amount0, fees.amount1, "");

        // Pay what the hook now owes the PoolManager
        if (delta.amount0() < 0) {
            key.currency0.settle(poolManager, address(this), uint256(uint128(-delta.amount0())), false);
        }
        if (delta.amount1() < 0) {
            key.currency1.settle(poolManager, address(this), uint256(uint128(-delta.amount1())), false);
        }

        emit FeesDonated(poolId, fees.amount0, fees.amount1);
    }
}
