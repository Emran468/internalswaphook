# InternalSwap Hook (Uniswap v4)

A Uniswap v4 hook that takes a small extra fee on every swap, holds it inside the hook, and donates it to the pool's liquidity providers once enough has been collected.

Built as UHI homework. It is a simplified take on an "internal swap pool" style hook: it keeps the fee-capture and fee-distribution parts and leaves out the order-filling logic.

## Idea

Swappers pay a small hook fee (0.5%) on top of the pool's normal LP fee. Instead of sending it somewhere else, the hook keeps it and later hands it to the pool's LPs through Uniswap's `donate`. LPs earn extra yield without having to claim anything.

## How it works

Contract: `src/InternalSwap.sol`

| Callback | What it does |
|---|---|
| `afterSwap` | Takes `HOOK_FEE_BPS` (0.5%) from the **unspecified currency** of the swap, records it in `_poolFees[poolId]`, and pulls the tokens into the hook with `afterSwapReturnDelta`. Emits `FeesCollected`. |
| `beforeSwap` | Donates collected fees to LPs if the threshold is reached. |
| `beforeAddLiquidity` | Donates first, so new LPs do not share fees they did not earn. |
| `beforeRemoveLiquidity` | Donates first, so leaving LPs get their share. |

### Specified vs. unspecified currency

In a swap the user fixes one token amount (**specified**) and the pool calculates the other (**unspecified**).

- Exact input (`amountSpecified < 0`): the unspecified currency is the output.
- Exact output (`amountSpecified > 0`): the unspecified currency is the input.

```solidity
bool unspecifiedIsCurrency1 = (params.amountSpecified < 0) == params.zeroForOne;
```

In `afterSwap` a hook can only change the delta of the unspecified currency, so the fee is always taken from it. The fee is `abs(amount) * 50 / 10_000`. The absolute value matters: the amount is negative when the swapper pays that currency (exact output).

Example (exact input, gross output of 1000 units):

```
fee      = 1000 * 50 / 10_000 = 5
swapper  receives 1000 - 5 = 995
hook     holds 5 until it is donated
```

### Fee distribution

`_distributeFees` runs when either collected amount reaches `donateThreshold`:

1. Return if both amounts are below the threshold.
2. Return if the pool has zero liquidity (`donate` would revert).
3. Clear the stored fees first (effects before interactions).
4. Call `poolManager.donate(key, amount0, amount1, "")`.
5. Settle what the hook owes the PoolManager, for both currencies.
6. Emit `FeesDonated`.

## Public interface

| Item | Description |
|---|---|
| `HOOK_FEE_BPS` | Hook fee in basis points (`50` = 0.5%) |
| `donateThreshold` | Minimum collected amount (raw token units) before a donation. Set in the constructor |
| `pendingFees(PoolKey)` | Returns the fees waiting to be donated, as `(amount0, amount1)` |
| `FeesCollected(poolId, currency, amount)` | Emitted after each swap that collects a fee |
| `FeesDonated(poolId, amount0, amount1)` | Emitted when fees are donated to LPs |

Constructor: `InternalSwap(IPoolManager _poolManager, uint256 _donateThreshold)`.

The hook does not depend on tick spacing or fee tier. It works with any pool key; it only reads swap amounts and the pool's liquidity.

## Hook permissions

Enabled: `beforeAddLiquidity`, `beforeRemoveLiquidity`, `beforeSwap`, `afterSwap`, `afterSwapReturnDelta`. All others are disabled.

The deployed hook address must encode these flags. The tests use `deployCodeTo`; for a real deployment, mine the address with `HookMiner`.

## Setup

- Solidity `0.8.26`, Foundry
- Dependencies are git submodules (Uniswap v4-core, OpenZeppelin Uniswap Hooks, hookmate, forge-std)

```bash
# install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# clone WITH submodules
git clone --recurse-submodules https://github.com/Emran468/internalswaphook.git
cd internalswaphook

# if you already cloned without submodules
git submodule update --init --recursive

forge build
forge test
```

Windows users: use WSL or Git Bash to install Foundry.

## Tests

`test/InternalSwap.t.sol` has 11 tests. The repo also contains the template's 6 `EasyPosm` tests, so `forge test` runs 17 in total.

- Permissions and constants are as expected
- Hook callbacks revert when not called by the PoolManager
- No fees pending before any swap
- Exact input, currency0 -> currency1: fee collected in currency1
- Exact input, currency1 -> currency0: fee collected in currency0
- Exact output, currency0 -> currency1: swapper pays the fee on top, in currency0
- Fees accumulate while below the threshold
- Fuzz: the fee is always 0.5% of the gross amount
- Fees are donated before the next swap once the threshold is reached
- Fees are donated before adding liquidity and pending fees reset to zero

```bash
forge test --match-contract InternalSwapTest -vvv
forge coverage --match-path src/InternalSwap.sol
```

## Differences from a full internal swap pool

| | Full version | This version |
|---|---|---|
| Fee capture | `afterSwap` | `afterSwap` |
| Fill swaps from held fees in `beforeSwap` | Yes | **No** |
| Donated currencies | currency0 only | **Both** |
| Negative unspecified amount | Not handled | Uses the absolute value |
| Zero-liquidity check before donate | No | Yes |
| Threshold | Constant | Constructor argument |

## Limitations

- **Raw-unit threshold:** `donateThreshold` is in raw token units, so the same number means different things for tokens with different decimals (for example USDC vs WETH).
- **Extra cost for swappers:** the 0.5% hook fee is charged on top of the pool's own LP fee.
- **Funds held in the hook:** collected fees sit in the hook until donated, so a bug in the hook could lock them.
- **Donation timing:** fees are only donated when a swap or liquidity change happens after the threshold is reached.
- **Not covered by tests yet:** `beforeRemoveLiquidity` distribution and the zero-liquidity skip.
- **Not audited:** for learning only.

## Possible improvements

- Make the fee configurable per pool
- Use a per-currency threshold to handle different decimals
- Add a keeper function so anyone can trigger a donation
- Add tests for remove-liquidity and zero-liquidity cases

## License

MIT
