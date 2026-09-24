# Porting report

## Environment

- Starting Fe revision: `aad737010`; worktree initially clean.
- The tool sandbox fails before executing commands: `bwrap: loopback: Failed RTM_NEWADDR: Operation not permitted`. Approved escalated commands work. This is an execution environment obstacle, not an Fe compiler defect.
- No existing v4 port was found in the worktree. Existing v2 benchmarks are not a v4 implementation.
- OpenSpec files are ignored by this repository. The active proposal is `openspec/changes/add-uniswap-v4`; durable project status is kept here as well.

## Implementation evidence

- `target/release/fe check examples/uniswap_v4`: passed after adapting integer API usage.
- `target/release/fe test examples/uniswap_v4`: **1947 passed, 0 failed** (before the separate revert integration test was added).
- `target/release/fe test examples/uniswap_v4 --filter math_reverts_have_empty_payload`: **1 passed, 0 failed**.
- The generated suite comprises 1114 division cases and 832 bit cases, plus a basic require test. `tests/generate_math_vectors.py` reproduces vectors using Python arbitrary-precision integers and a fixed seed. Coverage includes a 512-bit product, every power-of-two denominator, zero denominators, floor/ceil overflow, phantom overflow, every bit position, and random values. Expected-revert vectors do not prove error payloads; the additional real contract-call test checks those explicitly, with a successful call as a positive control.
- One compiler defect is now confirmed; see the unchecked-negation report below. No blocker PRs merged.
- OpenSpec validation: `openspec validate add-uniswap-v4 --strict` passed.

## Language/API adaptations

These are encountered porting obstacles, not confirmed compiler bugs:

- ~~Fe has no `u256::MAX` associated constant in the current standard library; the port defines an explicit maximum word constant.~~ Correction (2026-09-24): this was wrong. `core::num::Bounded` (since `41e0c3aec`, 2026-05-25, already in `aad737010`) provides `u256::max()` / `min()` as `const fn` for every integer type. The port now uses `u256::max()`; see the correction at the end of this report.
- `as` rejects narrowing `u256` to `u8`, even when the algorithm bounds the value to 128. BitMath uses `downcast_truncate()` after establishing that bound.
- External file modules are discovered automatically; Rust-style `mod name` declarations without bodies are invalid.
- Numeric `for` ranges default to `usize`; typed message arguments require explicit widening.
- Fe arithmetic is checked by default. FullMath and least-significant-bit isolation explicitly use `#[arithmetic(unchecked)]` where wraparound is part of the algorithm.
- Fe assertions emit panic data, while these Solidity libraries use empty `require` reverts. A shared helper uses `std::evm::revert(())`; the contract integration test confirms zero-length returndata, including the ceiling-only overflow case.

## Next implementation steps

1. Currency, pool-key and external operation interfaces.
2. PoolManager lifecycle, hooks, transient flash accounting and settlement.
3. Claims, settlement, protocol fees, storage views and complete periphery.
4. Differential Solidity execution, adversarial tests and full transaction invariants. Native arithmetic checks are only the first validation layer.

Core and periphery revisions, direct dependency gitlinks and a per-file inventory are recorded in `reference_manifest.json`. Upstream test support contracts are included in the inventory so they can supply adversarial fixtures; their presence is not a claim of implementation.

## Outstanding fidelity checks

The protocol and periphery remain incomplete despite the validated arithmetic foundation. Arithmetic tests alone cannot establish protocol parity. Match reference revert bytes (including empty `require` reverts versus Fe assertion panics), ABI widths, signed arithmetic, storage, hooks, transient storage and token transfer edge cases before completion.


## Arithmetic port and differential validation (2026-09-22)

New modules: TickMath (including logarithmic inverse and usable ticks), SqrtPriceMath
(all next-price and signed/unsigned amount-delta paths), SwapMath (price targets
and complete swap steps), SafeCast and UnsafeMath. Checked and wrapping operations
are selected per upstream expression; the `UnsafeMath` zero-divisor behavior is
explicitly preserved. Signed liquidity includes MIN_INT128, and exact-input swap
magnitudes include MIN_INT256.

`tests/run_math_parity.py` is the runnable differential gate. The Solidity wrappers
invoke the pinned original libraries. The Fe wrapper exposes the same ABI. Every
comparison checks both success status and the entire return/revert payload.
Fourteen deterministic fuzz properties cover all exported arithmetic families;
two boundary tests add thousands of specific calls (including zero-price and
zero-liquidity combinations, denominator/product overflow, powers of two,
custom-error parameters, exact tick boundaries and adjacent prices, 100% swap
fees and minimum signed integers). A separate successful-swap property requires
prices to stay between current and target and input/output amounts to respect
specified budgets.

Initial binary `fe 26.3.0 (d5af64cec)` passed all 16 Forge tests at `-O1` and `-O2`,
with 10,000 runs for each of 14 fuzz properties (140,000 generated cases per build,
plus the boundary loops). This is randomized and targeted evidence, not an
exhaustive proof. The old binary identity was discovered during provenance
validation; a clean Cargo build was then run against the current worktree
(`cargo build --release -p fe`, success, compiler now `fe 26.3.0 (aad737010)`).
Current-compiler verification is complete:

- `fe 26.3.0 (aad737010)`, binary SHA256 `bcca32a599986969df798656735d88167e0f95957ba18f8ec9aa6dffb7c3ecf5`.
- `target/release/fe test examples/uniswap_v4`: **1948 passed, 0 failed**.
- Differential suite at `-O1`: **16 tests passed**, including 14 × 10,000 fuzz runs.
- Differential suite at `-O2`: **16 tests passed**, including 14 × 10,000 fuzz runs.
- Solidity 0.8.30 / Cancun; Forge 1.5.1; fixed fuzz seed `0x554e495634`.
- Checked-in `tests/results/` contains source-hash-linked validation records and
  Forge logs. Hashes were checked against the current sources before recording.
- This validates the listed math modules, not pool accounting, hooks, settlement
  or periphery. Those remaining requirements are still unimplemented.

## Confirmed compiler defect: unchecked unary signed negation

- Minimal source: `tests/repros/unchecked_neg.fe` (also reproduced after rebuilding
  the current `aad737010` compiler).
- Command: `target/release/fe build examples/uniswap_v4/tests/repros/unchecked_neg.fe --standalone --out-dir /tmp/fe-v4-neg-repro`.
- Reproduces at `-O0`, `-O1`, `-O2`, and `-Os`. Actual failure at `-O1`: `EVM machine IR contains unsupported instruction at inst16: neg`.
- Expected: emit wrapping signed negation, including MIN_INT256.
- Impact: direct translation of `uint256(-amountRemaining)` in SwapMath cannot compile.
- Workaround: `(0 as i256) - remaining` inside the unchecked function. It preserves
  the 256-bit bit pattern and is exercised by the Solidity parity suite.
- Relevant Fe location: `crates/codegen/src/sonatina/lower_runtime.rs`,
  `lower_unary`, `UnOp::Minus` emits Sonatina `arith::Neg`.
- Open Fe and Sonatina PR lists were inspected on 2026-09-22. No matching fix was
  identified from their titles; no PR was merged. The compiler defect remains
  open in this report; the workaround unblocks the port. No issue has been
  published externally.

## Additional API/tooling observations

- Generic `downcast_truncate()` sometimes needs a typed intermediate variable;
  an enclosing signed arithmetic expression did not infer its output type.
- The build binary's embedded Git revision can lag the source checkout. Record
  the compiler version and SHA256 rather than attributing an existing binary's
  results to the checkout automatically. The test driver now does this.
- `run_math_parity.py` verifies SHA256 of every imported reference source and
  stores the exact test/build configuration with successful results.


## Fees, packed types, TickBitmap and Position (2026-09-22)

Implemented LPFeeLibrary (including dynamic and override flags), ProtocolFeeLibrary,
LiquidityMath, FixedPoint96/128 constants, BalanceDelta (checked component arithmetic
and equality), BeforeSwapDelta, Slot0 (all getters/setters), TickBitmap and Position.
At this stage Pool actions and tick liquidity/fee-growth accounting were pending.
The following Pool integration section records subsequent progress; currency and
pool-key interfaces still keep task 1.4 open.

The foundation suite checks complete ABI results and revert payloads for fees,
liquidity over/underflow, signed packed deltas and all Slot0 operations. It includes
reserved-bit preservation and extreme signed/unsigned values. Initial `-O1` run:
**7 tests passed**, six fuzz properties with 10,000 cases each plus boundary loops.
Final source-hash-linked `-O2` run: **7 tests passed**, again 60,000 fuzz cases
plus boundary loops. Results: `tests/results/foundation-parity-o2.{json,log}`.

The state suite checks real storage updates against the original Solidity libraries:

- Tick compression, word/bit indices, misaligned flips, initialized/uninitialized
  searches in both directions, random word masks, and double-flip restoration.
- Exact mapping-slot hashes, including negative keys and the assembly intermediate
  `+32768` key at `MIN_INT24 / -1`.
- Position-key hashing: exactly 58 packed bytes of owner, lower/upper tick and salt.
- Fee accrual using liquidity before a change; modulo-256 fee-growth subtraction;
  liquidity bounds and CannotUpdateEmptyPosition errors; subsequent fee pokes.
- Raw comparison of all three position slots after successes and reverts, with
  random high/reserved bits deliberately seeded in the liquidity slot.
- A mint/partial-remove/full-remove/poke sequence with independently checked fees.

Initial state `-O1` run: **7 tests passed**, five fuzz properties with 1,000 cases
and two targeted tests. Final `-O2` run: **7 tests passed**, five properties with
10,000 cases each (50,000 cases) plus the two targeted tests. Results:
`tests/results/state-parity-o1.{json,log}` and `state-parity-o2.{json,log}`.
All saved source and test hashes were checked against the final files.
The newly implemented behavior has no unresolved differential-test failures.

### API and reference semantics encountered

- `StorageMap<K,V>` requires `V: WordRepr`, so the multi-slot Position state uses
  a storage view with explicit slot pointers. It preserves Solidity's three-slot
  layout and unused upper liquidity bits rather than changing storage layout.
- `EncodePacked` currently has no implementation for the custom-width `Int24`
  wrapper. Position key encoding therefore writes the exact three-byte tick fields
  into a bounded buffer before hashing. The differential test checks the hash
  against Solidity `abi.encodePacked` independently of Position.calculatePositionKey.
- The Solidity TickBitmap uses raw SDIV/SMOD, which return zero for a zero divisor.
  Normal Fe division would revert, so zero is handled explicitly here.
- A plain int16-keyed abstraction would truncate the `+32768` intermediate in
  upstream `flipTick(MIN_INT24,-1)`. The Fe bitmap uses sign-extended i32 keys,
  preserving int16 slot encoding for valid protocol tick spacings and also that
  standalone assembly edge case. Pool-level spacing validation remains required.
- The type of a complemented integer literal must be made explicit in the reserved
  position-bit mask; inference from the neighboring u256 expression was insufficient.
- Position.sol is BUSL-1.1. Its translation and state harness retain that SPDX marker;
  `LICENSE-BUSL-1.1` is copied from the pinned reference. Other newly ported files
  retain MIT. No new confirmed compiler defect or PR integration in this step.

Earlier validation records remain historical snapshots; their hashes identify the
exact sources tested at that stage. New state/foundation records supersede them
for the newly added modules; they do not imply that PoolManager is implemented.


## Full Pool library integration (2026-09-22)

`pool.fe` and `pool_swap.fe` port the complete pinned Pool.sol library:
initialization and fee setters, maximum-liquidity calculation, tick update/clear/
crossing, inside-fee growth, position liquidity modifications and fee collection,
donations, and the multi-tick exact-input/exact-output swap loop with protocol
fee splitting, overrides and price limits. State uses the exact seven-slot root
layout, three-slot ticks and three-slot positions, including reserved bits.

The pool suite compares the unmodified Solidity Pool library at runtime-selected
storage roots. It checks complete return/revert data and raw storage after
successes and failures. Coverage includes bounded successful liquidity/swap/
donation/removal lifecycles, random seeded tick state, global/outside fee-growth
wraparound, empty pools, MIN_INT256, 100% fees, invalid overrides and price limits,
misordered/misaligned ticks, tick gross and signed-net overflow, tick clearing,
reserved liquidity bits, and swaps through multiple initialized ticks in both
directions. Two pools have different fees/liquidity to check root isolation.

Initial `-O1` smoke run passed all 9 tests (five properties × 64 fuzz cases plus
four scenarios). Final current-source validation passed:

- Pool `-O1`: **9 tests passed**, five properties × 10,000 cases = 50,000 cases,
  plus four targeted scenarios.
- Pool `-O2`: **9 tests passed**, another 50,000 cases plus the same scenarios.
- Static Bitmap/Position regression after refactoring, `-O2`: **7 tests passed**,
  five properties × 10,000 cases = 50,000 cases plus boundary/lifecycle tests.
- Records and complete Forge logs: `tests/results/pool-parity-o1.*`,
  `pool-parity-o2.*`, `state-bitmap-refactor-o2.*`. Source/test hashes were
  checked against the final files before copying the records.
- Test deployment uses normal CREATE without increasing the EVM code-size limit.
  The Fe PoolHarness runtime is below the 24,576-byte deployment limit.

This implements the Pool library, not the PoolManager's authorization, callbacks,
hooks, token transfers or flash-accounting invariants. Those gates remain open.

### New compiler/library obstacle: dynamic map roots

`StorPtr<StorageMap<i32,u256>>.read()` at a runtime slot fails with diagnostic
`17-0001`, "no runtime layout root is available for component 0". Minimal repro:
`tests/repros/dynamic_bitmap_layout.fe`. A direct mutable pointer effect binding
also failed to provide the required StorageMap effect in this usage.

Workaround: `tick_bitmap::Bitmap` explicitly computes the storage key from its
runtime root and shares compression, flip-location and word-search code with
the existing StorageMap interface. This retains arbitrary pool addresses and
Solidity-compatible slots; no fixed-address or single-pool restriction was added.
The old static API is regression-tested after this refactoring.

Open PRs #1564 (`d883c2102488dbf65540235f1e93d42cc81c84e0`) and #1494
(`168787afaeae56757ac147998bedbaa60871ae52`) were inspected. Their descriptions
address temporary trait-effect provider identity and aggregate map entries,
respectively, not this reported inferred-root failure. Neither was merged or
claimed to be verified as a fix. Details and links are in `tests/repros/README.md`.

### Solidity test-tooling obstacle

The wide swap harness function exceeds Solidity's legacy code generator stack
limit. The pool suite uses solc 0.8.30 with optimization and `viaIR = true`; this
setting is included in validation metadata. Upstream library sources remain
unchanged and hash-verified. Fe code does not depend on Solidity for execution.


## Transient accounting libraries

Implemented `Lock`, `NonzeroDeltaCount`, `CurrencyDelta` and `CurrencyReserves`
in `src/transient.fe`, preserving the reference slots and address-key hashing.
Also implemented PoolManager's `_accountDelta` and `_accountPoolBalanceDelta`
logic as helpers: zero deltas are skipped; the count changes only when a balance
enters or leaves zero. The PoolManager contract itself remains pending.

Preserved details include checked signed 256-bit delta addition, unchecked
256-bit counter wrapping, int128 component extraction, and `resetCurrency`
clearing only the synced currency while retaining the reserves word.

### Validation

`TransientParity.t.sol` imports the four unmodified, hash-verified reference
libraries. Its two account helpers mirror PoolManager's helper logic; this is
not an integration test of the complete reference PoolManager. Independent
models additionally verify account balances and counts.

- O1 and O2 each passed six fuzz properties with 10,000 cases per property:
  120,000 differential cases total, comparing complete return/revert bytes.
- Two additional scenarios at each optimization cover signed extrema, same
  currency cancellation, independent accounts/contracts, and rollback of the
  first currency and counter if the second currency overflows.
- Properties cover exact transient slots, sync/reset semantics, count wrapping,
  zero deltas, repeated calls, empty revert payloads and rejected static TSTORE.
- `run_transient_transactions.py` starts an isolated local Cancun Anvil node,
  mines writes for Fe and Solidity, verifies actual nonzero TSTORE operations
  from opcode traces, then checks that subsequent calls see zero state. Ten
  transactions passed per optimization level (five operations × two languages).
- Compiler: Fe 26.3.0 (`aad737010`), the same compiler hash recorded above.
  Successful records and Forge logs are retained as
  `tests/results/transient-parity-o{1,2}.{json,log}` and
  `tests/results/transient-transactions-o{1,2}.json`. All source/test/script
  hashes and the transaction-to-parity record links were verified before copying.

### Obstacles encountered in this step

No new Fe compiler defect was observed. Test-infrastructure adjustments:

1. `apply` is reserved in Solidity; the test ABI now uses `applyDelta`.
2. Anvil may return the transaction hash before a receipt exists; the runner
   waits for mining with a bounded timeout.
3. Anvil needs `--steps-tracing` to supply the opcode traces used as evidence.
   The runner enables it explicitly and rejects missing TSTORE traces.

No compiler changes or PR merges were required. Unlock callbacks, settlement,
hooks, claims and all periphery remain open; these library results do not
establish the full PoolManager invariant that all deltas settle before relocking.


## Currency transfers and balances

`src/currency.fe` ports Currency's native/ERC20 transfers, balance queries,
address/ID conversion (including truncating high ID bits), zero-address detection
and comparisons. Transfer failures use exact ERC-7751
`WrappedError(address,bytes4,bytes,bytes)` encoding; balance failures bubble raw
revert data. The wrapper helper also provides the behavior hooks will need.
Currency is currently an internal value wrapper; integration into final ABI
parameter types, PoolKey and PoolManager remains open.

The v4 rules differ from generic safe-ERC20 helpers: a successful empty response
is accepted even from an address without code. A nonempty transfer response is
accepted only if at least 32 bytes long and its first word is exactly 1; trailing
bytes are allowed. Balance queries accept at least 32 bytes, decode the first
word and use STATICCALL. The port uses raw calls and explicit calldata rather
than changing these behaviors to fit std::evm::erc20.

### Validation

At both O1 and O2, five properties with 10,000 cases each passed against pinned,
unmodified Currency.sol: 100,000 differential cases total. Four additional
scenarios per optimization cover return lengths 0/1/4/31/32/33/63/64/255,
codeless addresses, attempted state mutation during balance queries, actual
STATICCALL entry, correct owner/self arguments and a 4097-byte wrapped revert.
The suite checks native balances, recipient/token side effects and rollback,
insufficient native funds, ID truncation/comparisons and full return/revert bytes.
The successful source/test hashes were verified before retaining
`tests/results/currency-parity-o{1,2}.{json,log}`. Compiler remains Fe 26.3.0
(`aad737010`) with the previously recorded SHA256.

### New compiler obstacle: ABI export after typed calldata encoding

`encode_msg_calldata` causes ABI-only export to panic in
`instantiate_callable_typed_body` (event reachability collection), through
`InstantiateFolder` at `crates/hir/src/analysis/ty/binder.rs:136`: generic argument
index 1 is accessed in a slice of length 1. Minimal standalone reproduction:
`tests/repros/encode_msg_abi.fe`; stacktrace and instructions are retained.
The original Currency build wrote bytecode before failing to write ABI. That
bytecode passed the exploratory runtime tests; the failure was isolated to
ABI generation, not inferred to invalidate successful runtime behavior.

Workaround: explicitly encode the two fixed ERC20 calldata shapes in owned
memory buffers. The final normal build now exports all requested artifacts
without panic. No compiler patch was made. All 35 open Fe PR titles/descriptions
were inspected, with revisions recorded in
`tests/results/currency-open-pr-inspection.json`; no matching fix was identified
from those descriptions, and no PR was merged or tested as a fix.

### ABI metadata limitations, still unresolved

- Custom errors are absent from generated JSON, including directly used errors.
  `tests/repros/custom_error_abi.fe` compiles but omits `Failure(uint256)`.
  Currency's generated ABI omits WrappedError; runtime error bytes are tested.
  The Solidity Currency harness also omits its assembly-generated errors, so
  the direct Failure reproduction is the evidence for Fe's exporter limitation,
  not a claimed difference between those two harness error lists.
- Balance functions are emitted as `nonpayable` rather than `view` because ABI
  mutability derivation treats mutable RawMem/Call effects as state mutation.
  Direct STATICCALL tests prove these balance entrypoints execute successfully.
- Fe's multiple return values appear as one tuple output, whereas the Solidity
  harness declares separate outputs. The tested static values encode identically,
  but the JSON client-facing result shape differs.

`tests/results/currency-abi-audit-o{1,2}.json` retain the exact differences. Runtime
parity is not a claim of complete protocol ABI parity. These issues must be
resolved for final interface delivery. Named-argument corrections and parentheses
around comparisons in a tuple were source-language adaptations during this step.


## PoolKey, PoolId and external operation types

`src/pool_types.fe` adds the five-word PoolKey and its exact
`keccak256(abi.encode(key))` PoolId calculation, plus external
ModifyLiquidityParams (including signed 256-bit liquidityDelta) and SwapParams.
These are distinct from the Pool library's internal parameter structs.
Field order, widths, signed extension and original Solidity field names are
preserved. PoolId hashing does not add PoolManager-level validity checks.

At the ABI boundary Currency and IHooks are represented as Address, and PoolId
as Bytes32, matching Solidity's erased user-defined/interface types. This avoids
Fe's metadata exporter treating custom one-field wrappers as nested tuples.
The internal Currency wrapper remains available for transfer/balance behavior.

### Validation

Five differential properties × 10,000 cases × O1/O2 = 100,000 cases passed,
covering PoolId hashes, structure round trips and arbitrary replacement words
for every field. Additional scenarios cover extrema, same/zero currency
addresses, every truncated fixed-head calldata length, and accepted trailing
calldata. All comparisons invoke Fe and Solidity via STATICCALL and check both
success and complete return/revert bytes. Hash results are also checked against
an independent `keccak256(abi.encode(key))` expression.

`check_types_abi.py` verifies all parameter/return field names and nested ABI
shapes against the Solidity harness. The sole mutability difference is the
previously reported RawMem classification: Fe emits poolId as nonpayable,
Solidity as pure. This remains open for final protocol metadata delivery.
Records: `tests/results/types-parity-o{1,2}.{json,log}` and
`types-abi-audit-o{1,2}.json`. Source, test and checker hashes were verified before
copying the records. Compiler remains `fe 26.3.0 (aad737010)`.

### New compiler obstacle: composing ABI decoders

Calling `Address::decode_payload(mut decoder)` twice to construct a two-address
Copy struct fails semantic borrow checking while lowering decode_runtime_args:
`borrow conflict in fn decode_payload`. Delegating the PoolKey decoder to a
single tuple decode also failed. Minimal standalone reproduction and log are
`tests/repros/composed_decode_borrow.fe` and
`tests/results/composed-decode-borrow.log`.

The working codecs read raw words and enforce the same canonical address,
uint24/uint160, signed int24 and bool checks before constructing values.
Differential rejection tests cover this workaround. PR #1564's changed files
and added borrow-check tests were inspected at
`d883c2102488dbf65540235f1e93d42cc81c84e0`; they address trait-effect provider
identity and do not include this composed-decoder case. The PR was not tested
as a fix or merged. Inspection provenance is recorded in
`tests/results/types-pr1564-inspection.json`.

This completes the planned foundation-type/library item. PoolManager, its
unlock lifecycle, hooks, settlement, claims, protocol fee administration,
external storage access and complete periphery are still required.


## Complete Hooks library dispatch and delta handling

`src/hooks.fe` implements the Hooks library's permission constants/Permissions,
address validation, generic call/return-delta helpers and all ten callbacks for
initialization, adding/removing liquidity, swaps and donations. The public
lifecycle helpers take the hook address from PoolKey, as every PoolManager call
site does. ParseBytes behavior is implemented at the bounded hook-response call
sites; no standalone unchecked arbitrary-memory parser is exposed.

Preserved reference details:

- The hook itself as caller suppresses every lifecycle callback and its deltas.
- A zero liquidity change takes the remove-liquidity path.
- Selector answers need at least 32 bytes; bytes4 padding is ignored. Return
  deltas require exactly 64 bytes when requested; otherwise extra data is ignored.
  beforeSwap requires exactly 96 bytes even without delta-return permission.
- Only dynamic-fee pools read the override word, truncated to 24 bits. Fee
  validation remains in the downstream Pool logic, matching the reference.
- A beforeSwap delta may reduce the remaining amount to zero but cannot flip
  exact input/output mode. Checked signed arithmetic, safe int128 narrowing,
  unspecified-delta addition, token0/token1 mapping and caller subtraction match.
- Hook failures preserve complete returndata in the existing ERC-7751 wrapper
  with the attempted selector and HookCallFailed context.

### Validation

Eight properties with 10,000 cases each passed at both O1 and O2: 160,000
cases total. Four additional scenarios per optimization cover response-length
boundaries, short/codeless calls, successful dispatch of every callback,
self-call suppression, static/dynamic fee address rules, amount sign changes,
zero remaining amounts and signed overflow boundaries.

The Solidity side imports the unmodified, hash-verified Hooks library. Response
contracts are installed at addresses with chosen hook flags. Every comparison
checks success/revert and full return/revert bytes, callback count increments,
and the keccak hash of the entire callback calldata. Independent models check
valid swap/liquidity deltas and their failure boundaries. Both successful and
reverting callback side effects are included through the count checks.

Solidity uses optimized solc 0.8.30 with viaIR for this suite. Fe runtime sizes:
O1 7851 bytes; O2 7795 bytes. Test deployment uses normal CREATE under the
standard code-size limit. Source/test hashes were verified before retaining
`tests/results/hooks-parity-o{1,2}.{json,log}`.

No new Fe compiler defect or PR merge was needed in this step. The port uses
explicit selector/static-head/dynamic-tail encoding to avoid the previously
reported encode_msg_calldata ABI-export panic. The tests verify this encoding
against actual Solidity callback calldata, including arbitrary hookData.

This completes library dispatch and delta behavior, not PoolManager integration.
Event ordering around pool mutations, actual reentrant pool lifecycles, unlock
callbacks, settlement invariants, claims, protocol fees and periphery remain open.


## ERC6909 and claims accounting

`src/claims.fe` ports ERC6909 and ERC6909Claims: balances, operators, approvals,
transfer/transferFrom, ERC165 support, internal mint/burn and authorized burnFrom.
The three mappings retain Solidity's nested keccak layout at an explicit base
slot, ready to follow ProtocolFees state in PoolManager. Operator writes preserve
unused upper slot bits. Full 256-bit token IDs are retained; currency-ID truncation
belongs to PoolManager's mint/burn entrypoints rather than ERC6909 itself.

Owner/operator allowance bypass, unlimited allowances, checked finite allowance
subtraction and balance overflow/underflow match. Balance updates preserve
self-transfer ordering. Zero addresses and zero amounts remain permitted exactly
where the reference permits them. Transfer/Approval/OperatorSet events preserve
field order, indexed topics, caller/from/to identity and data words.

### Validation

Seven properties × 10,000 cases × O1/O2 = 140,000 cases; every case runs against
both root-0 and root-3 deployments. Each call compares success and complete
return/revert bytes, all log topics/data (normalizing only emitter address), and
relevant raw storage. Independent models additionally check balances, allowances,
authorization, overflow and Transfer event encoding. Root 3 is compared against
unmodified ERC6909Claims inherited after a three-slot Solidity prefix.

The sequence property exercises mint, approval, allowance transfer, operator
approval/transfer/revocation, self-transfer and burns without seeding token state.
It also overwrites prefix slots and verifies that the Fe root is code-backed,
that unrelated storage remains intact, and that the final balances settle to zero.
Three additional scenarios per optimization check extreme/zero values, complete
allowance/sender rollback on recipient overflow, and real STATICCALL getters.

`check_claims_events.py` verifies the three exported event ABI definitions exactly
against Solidity, including names, types, order and indexed flags. Known function
metadata differences (getter mutability/result names and isOperator parameter
name; supportsInterface pure vs view) are retained separately in the audit, not
claimed as complete ABI parity.

Normal CREATE deployment stayed below the EVM code-size limit: runtime O1
2116 bytes; O2 2117 bytes. Final records are
`tests/results/claims-parity-o{1,2}.{json,log}` and
`claims-event-abi-o{1,2}.json`. Source, test and checker hashes were checked before
copying. The harness exposes unguarded mint/burn helpers solely for testing;
PoolManager's unlock/accounting authorization remains to be integrated.

### Obstacles and dependency preparation

No new Fe compiler bug or PR merge was needed. Source/test adaptations:

- Fe's maximum uint256 was expressed as `!(0 as u256)`. Corrected later: `u256::max()` from `core::num::Bounded` is the standard spelling and is used now.
- Solidity reserves `reference`; the test variable was renamed.
- The large Solidity state/log comparison needed viaIR stack spilling. Marking
  the read-only CREATE assembly block `memory-safe` enabled that transformation.

For upcoming ProtocolFees integration, Solmate Owned.sol was retrieved from the
core's pinned gitlink `4b47a19038b798b4a33d9749d25e570443520647`. Its SPDX license
is AGPL-3.0-only (unlike v4's MIT ERC6909 copy); the actual source SHA256 and
license hash are recorded under `solmate` in the manifest, with the license text
retained. At that stage Owned was still unimplemented (completed below). This is provenance/license tracking, not
a claim that the complete manager or its inherited dependencies are finished.


## Solmate ownership dependency

`src/owned.fe` ports the pinned Solmate Owned dependency used by ProtocolFees,
retaining AGPL-3.0-only. It preserves constructor/transfer OwnershipTransferred
events, the original Error(string) UNAUTHORIZED payload, null/self owner
transitions and the low-160-bit address layout with untouched upper slot bits.
The library supplies initialize, owner, check_owner and transfer_ownership;
ProtocolFees and final PoolManager integration remain open.

Both O1 and O2 passed 10,000 ownership-sequence cases plus a zero/self-owner
scenario. Each case compares constructor storage/events, unauthorized calls,
transfers, final storage and static owner/restricted getters. Complete ABI
comparison also passed, including constructor, methods, mutability, parameter
names and event indexing (ignoring Solidity-only internalType annotations and
entry order). Runtime size: O1 524, O2 524 bytes.
Source/test/checker hashes were verified before saving
`tests/results/owned-parity-o{1,2}.{json,log}` and `owned-abi-o{1,2}.json`.
Solidity reference: Solmate `4b47a19038b798b4a33d9749d25e570443520647`, solc
0.8.30 with viaIR; Fe remains `aad737010`.

### Refined diagnosis: inherited mutable effects affect ABI metadata

The initial Owned harness declared mutable storage/log effects at contract scope.
Even its read-only handlers were then exported as nonpayable. Moving effect
requirements to individual constructor/recv handlers makes owner/restricted
correctly export as view, with no compiler change. This fixes Owned's metadata
and demonstrates that inherited capability scope explains part of the earlier
harness mismatches. It does not establish that all previous cases are fixed:
Currency/PoolId/Claims helpers still declare local mutable memory/call effects,
and their recorded ABI audits remain historical evidence. Final PoolManager
handlers should use precise effect declarations.

No new Fe compiler defect or PR merge was required. The standard selector-prefixed
Error(string) encoding uses a typed error rather than bare std::evm::revert,
which encodes its value without adding the standard error selector.

### Upcoming ProtocolFees reference discrepancy

Source inspection found that IProtocolFees.collectProtocolFees documentation
says collection reverts while unlocked, but the pinned ProtocolFees implementation
contains no such lock check. It checks controller authorization and blocks a
non-native currency if it is currently synced; its abstract _isUnlocked helper
is not called there. The upcoming port and tests must follow executable reference
behavior, not introduce an extra guard from the stale comment. This was initially a source-based observation; the ProtocolFees runtime tests
below now confirm it. Complete PoolManager integration remains pending.

## Protocol fee administration and collection

`src/protocol_fees.fe` ports the pinned ProtocolFees base contract using Owned,
Pool, Currency and transient-reserve helpers. The explicit storage view preserves
owner at root, accrued-fee mapping at root+1 and packed controller at root+2;
the caller supplies the pools mapping root. The differential harness uses root 0
and pools at slot 3, matching the Solidity subclass. Final PoolManager integration
must use its own inherited layout.

The port preserves only-owner/controller authorization, fee-validation precedence,
initialized-pool checks, ProtocolFeeControllerUpdated/ProtocolFeeUpdated logs,
unchecked accrual wrapping and checked collection subtraction. Collection debits
before the external transfer, returns the collected amount, treats zero as all
accrued fees and blocks only the currently synced non-native currency. Tests
compare exact return/revert bytes, logs, storage, transfer side effects and
rollback; an ERC20 callback checks the already-debited accrued balance using
STATICCALL. Native collection also checks balances and recipient rollback.

The `protocol_fees` runner verifies both unmodified v4-core and pinned Solmate
Owned sources and records both revisions. O1 and O2 each pass five properties
with 10,000 cases each, plus three boundary/sync scenarios: 100,000 fuzz cases
total. Runtime sizes are O1 6,181 bytes and O2 6,150 bytes. Source/test hashes
were verified before archiving `tests/results/protocol-fees-parity-o{1,2}.{json,log}`
and `protocol-fees-abi-o{1,2}.json`. Fe remains aad737010; Solidity uses 0.8.30
with viaIR. Both builds and the Python/Fe formatting checks passed.

### Confirmed reference documentation discrepancy and ABI metadata gaps

The runtime differential test confirms the earlier source observation: collection
succeeds while unlocked if other conditions hold. A synced token still blocks a
zero-amount collection with zero accrued fees; another synced token does not.
The stale IProtocolFees comment must not become an extra implementation guard.

The ABI checker verifies all function argument shapes/names and event fields and
indexing, recording these remaining differences explicitly:

- Fe omits InvalidCaller, ProtocolFeeCurrencySynced and ProtocolFeeTooLarge from
  ABI JSON. Their runtime encodings match the reference.
- protocolFeesAccrued exports nonpayable instead of view because its mapping hash
  requires a local mutable RawMem effect. The actual getter succeeds in STATICCALL.
  owner and protocolFeeController export view with per-handler effect declarations.
- The reference names return values `amount` and `amountCollected`; Fe exports
  empty names. `crates/fe/src/abi.rs` constructs the output NamedAbiParamDesc with
  `String::new()` unconditionally. Wire encoding is unaffected, but generated
  client metadata is not yet identical.

No compiler source change or PR merge was necessary for this component. These
metadata gaps remain part of final ABI work, and the complete protocol remains
unfinished.

## External storage access and a local core ABI fix

The Extsload/Exttload port implements single-slot, contiguous persistent-range
and sparse persistent/transient reads. Range arithmetic follows the reference's
unchecked EVM shift: count bits above bit 250 disappear from the payload size,
while the original count is retained in the returned length word. Counts of
uint256.max and uint256.max-1 return just the offset word and empty data,
respectively. A checked DynArray constructor cannot represent those deliberately
malformed reference returns, so the range entry emits the raw return buffer.
Single/sparse reads use Bytes32 and DynArray<Bytes32> codecs. Empty arrays do not
expose the reference assembly's redundant one-slot read; no gas equivalence is
claimed.

### Reproduced decoder overflow defect and local correction

Malformed sparse-array calldata with an overflowing relative offset produced
Panic(0x11) in Fe and an empty revert in Solidity. The core library's
checked_tail, checked_frame_end and dyn_array_payload_end_with_input_len performed
checked arithmetic before their intended overflow/error branches. The local
`ingots/core/src/abi.fe` patch validates available lengths and subtraction/division
bounds before addition/multiplication, preserving the ABI decode_error path.
This is a standard-library fix, not a change to Solidity/reference source.

Four regression tests in
`crates/fe/tests/fixtures/fe_test/abi_array_overflow_revert.fe` fail on the original
binary and pass after the fix: relative-tail overflow, length-word-end overflow,
array element-frame multiplication overflow and final-frame addition overflow.
The assertions inspect CallOutcome.returndata_len(), because a zero-capacity
MemBuffer remains empty even when the callee returns error data. An initial test
assertion on buffer length was corrected before retaining baseline evidence.

The four new tests plus 40 existing nested-message, dynamic-payload, DynArray and
MemVec tests all pass under both O1 and O2. Before/after logs, fixture hashes and
the exact patch are under `tests/results/abi-array-overflow-*`. Original compiler
SHA256: bcca32a599986969df798656735d88167e0f95957ba18f8ec9aa6dffb7c3ecf5;
rebuilt compiler SHA256: be208062c6dd982b2428828036434bd92b0b8347c93c7c135ff09310797629fe.
Both version strings report aad737010; the second includes the recorded local
core patch. The parity runner now retains its compiler source diff and hash.
Historical component results still identify the earlier compiler and must not be
represented as reruns under the patched one.

Public open-PR metadata and relevant ABI patches were inspected. PRs #1422,
#1451, #1462 and #1540 did not provide the specific bounds fix; no PR was merged.
The snapshots are `extload-open-pr-inspection.json` and
`extload-abi-pr-patches.json`. The GitHub CLI was unavailable, so the read-only
inspection used GitHub's public API. This focused fix does not establish that
every malformed dynamic ABI shape is fixed: separate Bytes/view helpers contain
similar arithmetic and need their own adversarial coverage during integration.


### PoolManager layout preparation

The unchanged pinned PoolManager was compiled with its required solc 0.8.26
(binary SHA256 verified against the official solc-bin listing). The resulting
storage layout confirms owner slot 0, protocolFeesAccrued slot 1,
protocolFeeController slot 2, ERC6909 isOperator/balanceOf/allowance slots 3/4/5,
and pools slot 6. The artifact includes source hashes, both reference revisions,
compiler hash/version and settings:
`tests/results/pool-manager-reference-layout.json`. Only production sources were
included; the first broad source glob also picked up upstream src/test helpers
with missing test-only dependencies and was corrected. This is integration
preparation, not a claim that the Fe PoolManager exists yet.


### Final external storage validation

Both final builds pass 50,000 differential cases plus two boundary scenarios
per optimization level (100,000 fuzz cases total). Tests exercise all five read
overloads, persistent/transient isolation, duplicate sparse slots, slot-index
wraparound, truncated/unaligned/trailing calldata, overflowing dynamic offsets
and lengths, and the reference's wrapped range return encoding. Complete ABI
comparison passes, including overloads, names, shapes and view mutability.

The range reader uses core::abi::store_word on its allocated memory and an
immutable RawOps capability. This keeps the exported handler view; an earlier
mutable RawOps declaration unnecessarily exported nonpayable. Final evidence is
`tests/results/extload-parity-o{1,2}.{json,log}` and `extload-abi-o{1,2}.json`, with
source/test/compiler-patch hashes verified before archival. Runtime sizes: O1
1366 bytes, O2 1366 bytes. Solidity uses 0.8.30 without viaIR.
Fe formatting, Python syntax and git diff whitespace checks also passed.

All external storage methods are ready for PoolManager composition; this does
not complete manager unlock/settlement, no-delegatecall protection or periphery.


## Initial singleton PoolManager integration (not yet validated for delivery)

manager.fe and pool_manager.fe now compose all 33 manager/inherited entrypoints,
immutable delegatecall protection, hooks/events, pools at slot 6, claims at slot 3,
protocol fees, unlock callbacks, native/ERC20 settlement and delta accounting.
The complete contract compiles. The initial actual-Solidity integration run passes
10 of 11 tests, including liquidity/swap/donate/remove lifecycle, claims,
settleFor/clear, protocol fees, dynamic LP fees, locked calls, delegatecall rejection
and unsettled/reentrant unlock rollback. Four successful fuzz properties used
100 cases each. This is initial coverage, not full manager parity.

Two current blockers were identified: malformed callback return data differs
(size=65, offset=11, length=500, no callback revert), and O1 runtime size is 33,069
bytes, exceeding the Cancun EIP-170 limit of 24,576 bytes. Forge's successful test
deployment is not evidence of deployability under that limit. Both remain open.
Evidence: tests/results/manager-initial-status.json.

The payable value-returning settle/settleFor handlers initially failed compiler
verification with InvalidReturnClass. PR #1567 at dbc73bff5678c96c3c230d810ebc8fac6155667b
was inspected and locally merged as 5d3da6ade23099f3b29608bdd8880e8b0ec25492, retaining
the local core ABI bounds fix. A fast-forward was unavailable because the branches
diverged; the explicit merge succeeded without conflicts. Its four payable return
regressions pass at O0/O1/O2/Os. Before/after logs and compiler provenance are in
manager-payable-*. Current compiler hash is recorded there. No upstream messages
or pull requests were published.

## Local integration of the isolated compiler fixes

The user authorized completing the full port using the local PR branches and
deprioritized (but did not waive) the deployment-size issue. The initial port
and historical validation evidence are preserved in local commit 3f8133778.
No Uniswap sources are added to the upstream compiler PRs.

Locally merged PR revisions:

| PR | Revision | Fix |
| --- | --- | --- |
| #1567 | dbc73bff5678c96c3c230d810ebc8fac6155667b | Payable value-returning handlers (previously merged) |
| #1570 | 5e2e607040082ab8ba1bdc0465698519040c2672 | ABI array overflow rejection and redundant panic code |
| #1571 | 3a94ac7653aa32f593a2209d224490fe797fa1ef | Unchecked signed negation |
| #1572 | fdc7a61998c9f1ec0d6167e6c43022d9cba32ee3 | Memory effects in ABI mutability |
| #1573 | 659a1096c8eb21e2fce01db0282eac820246ab59 | Reachable custom-error ABI entries |
| #1574 | 2c4b0f3c1a4036541383acc76a9daadda899d2c6 | Generic ABI traversal instantiation |
| #1575 | 5b6fa5fdd1cd89ceb287213f77cc4a6f765d483a | Composed ABI decoder borrow checking |

The #1573/#1574 merge required combining the new visited-target representation
with semantic generic substitution (rather than positional Binder substitution).
Test conflicts were resolved by retaining all independent regressions. All 30
ABI unit tests pass in the integrated compiler. Runtime integration is validated
separately below; these unit results alone do not prove protocol compatibility.

The existing unlock callback patch was applied directly to manager.fe rather
than merging the withdrawn upstream branch, which included the entire example.
It preserves the pinned solc decoder's allocation-panic precedence over payload
bounds checks. Named tests cover the original unaligned-offset counterexample
and allocation sizes near uint64.max. Full manager lifecycle tests now also
compare hook calldata traces and callback counts, hook rejection/rollback, and
reentrant unlock rejection. These additions are pending validation.

Periphery work has started with LiquidityAmounts, SlippageCheck and BipsLibrary.
The new differential suite imports hash-verified, unchanged pinned periphery
sources and compares both successful results and complete revert bytes. This
is foundation work; PositionManager, router, quoter and lenses remain pending.

### Integrated runtime regressions and periphery arithmetic validation

The nine overflow, unchecked-negation and composed-decoder runtime regressions
pass at O1 and O2. The whole example passes `fe check` under the combined compiler.
Periphery arithmetic passes three fuzz properties with 10,000 cases each at
both O1 and O2 (60,000 generated cases total), plus boundary scenarios. Full
return and revert bytes match the unchanged Solidity libraries. Archived
`periphery-math-o{1,2}.{json,log}` records hashes, compiler and reference identity.
The successful interior-price scenario additionally verifies the expected
liquidity numerically, and the boundaries include zero denominators, checked
percentage overflow, and int128 minimum slippage deltas.

The parity runner now freezes compilation sources under its artifact directory
and excludes unrelated harnesses/generated math tests by default; use
`--build-full-ingot` to retain the previous build scope. Production modules are
retained unchanged. A full ingot build was used for the O1 arithmetic run and
the initial integrated manager run; O2 arithmetic used the frozen subset.
This avoids repeatedly checking thousands of unrelated test functions during
component development. Full ingot tests remain part of final validation.

### Integrated manager and periphery type validation

The corrected manager passes all 16 integration tests at both O1 and O2,
including six properties with 10,000 cases each (120,000 fuzz cases total).
Both levels cover malformed callback returns, claims, initialization, lifecycle
and hook lifecycle, plus deterministic settlement/protocol-fee/delegatecall/
rollback scenarios. Hook traces compare ordered calldata and callback counts;
a returned native-currency hook delta is actually paid and its transient balance
cleared. These results improve coverage but do not establish exhaustive protocol
parity or complete ABI metadata equality.

Two test-oracle mistakes were found and corrected: a swap may exhaust the active
range before a donation (both references revert NoLiquidityToReceiveFees), and
the multi-scenario hook test must reset its reentry mode before initializing a
second pool. The recorded trace identifies matching reference/Fe rejection; these
were test defects rather than compiler or port defects. The runner now writes
validation metadata even on failure. `retest_parity.py` verifies unchanged Fe
source/bytecode hashes and preserves previous failures before running an edited
Solidity test against existing artifacts. Final results are archived as
`manager-integrated-final-o{1,2}.{json,log}`.

Manager runtime remains oversized: O1 33,127 bytes and O2 32,856 bytes. Test
deployment is not evidence of EIP-170 deployability; the user explicitly gave
this limitation lower priority while functional completion proceeds.

PositionInfoLibrary and PathKeyLibrary are now ported. Their type harness passes
30,000 fuzz cases per optimization, plus signed-tick/subscriber-bit boundaries
and the equal-currency swap-direction case. Complete return bytes match the
hash-verified pinned libraries. Evidence: `periphery-types-o{1,2}.{json,log}`.
The exported test pool-id value widens the reference bytes25 to bytes32 with zero
low bits; production packing still uses exactly the highest 200 pool-id bits.

### Remaining manager ABI export differences

A complete 33-function audit is reproducible with `tests/check_manager_abi.py`.
It currently fails its strict surface check; `manager-integrated-abi-o2.json`
retains the differences rather than treating runtime parity as ABI completeness:

- `modifyLiquidity` is exported with one tuple output, whereas Solidity declares
  two top-level int256 outputs. The static wire bytes match in integration, but
  generated-client return shapes differ. This needs an ABI export solution.
- `supportsInterface` is exported as pure rather than the reference's view.
- Named Solidity return values are absent from Fe metadata (previously reported).
- Fe now exports 25 additional reachable errors, including library/assembly-used
  errors and standard Error/Panic, which solc's ABI does not list. Runtime error
  parity is checked separately; suppressing reachable Fe errors would hide useful
  metadata and would undo the intent of #1573.
- Solidity internalType labels are language-specific and recorded separately
  from wire types; the checker omits those labels from its structural comparison.

Upcoming action-decoder work must preserve the pinned periphery decoder's strict
layout and 32-bit masking rules rather than substitute ordinary ABI decoding.
This is based on source inspection of CalldataDecoder.sol, not yet runtime proof.

## StateView and StateLibrary port

The complete StateView surface (12 functions, including the immutable manager
getter and both getPositionInfo overloads) is implemented. StateLibrary preserves
the single-slot versus range extsload calls, signed tick encoding, packed
liquidity extraction, position-key hashing and wrapping fee-growth arithmetic.
O1 and O2 each pass all nine tests, including six 10,000-case properties
(120,000 fuzz cases across both optimization levels). Tests use the unchanged pinned PoolManager as the storage provider,
write independently calculated storage roots, and additionally exercise a real
initialized pool and arbitrary reverting/malformed providers. This component
validation does not replace final workflows using the Fe PoolManager.

### External array-return decoder and reference assembly behavior

Adversarial reader responses revealed two observable reference behaviors:

1. solc 0.8.26 allocates a dynamic returned array before checking its payload
   bounds. Excessive counts raise Panic(0x41), while Fe's general ABI decoder
   rejects the bounds first with empty data. An unaligned 96-byte response with
   offset 21 reproduces the discrepancy; uint256.max length is a simpler case.
   This is related to, but distinct from, the malformed *input* issue fixed in
   #1570. The core library is unchanged; the port handles this return behavior.
2. StateLibrary reads returned array elements using unchecked assembly. A
   single zero word is accepted as an empty array at offset zero. The next
   word can contain four bytes left over from the extsload call arguments:
   getTickInfo returns liquidityNet = 3 << 96 in the pinned reference. This
   is confirmed runtime behavior, not a claim that the backing manager is
   well formed. Canonical empty arrays behave differently and are tested too.

The local reader tracks the pinned StateView allocator's offsets independently
from Fe's scratch memory and preserves its panic precedence and short-array
reads. Allocation boundaries are checked both at the first range call and
after preceding successful reads in getFeeGrowthInside. The owner-derived
position hash does not advance the Solidity allocator: its assembly cleans
scratch memory without allocating; the port accounts for that distinction.
The runtime excerpts are retained in state-view-allocation-before.log and
state-view-short-return-before.log. This compatibility logic is pinned to the
reference compiler/settings and needs revalidation if those change.

### Read-only raw STATICCALL API limitation

Call.raw_staticcall requires a mutable Call capability, which makes exported
ABI functions nonpayable even though they execute STATICCALL. The underlying
ops.staticcall intrinsic is private to std. StateView uses the public
staticcall_decode<()> helper to perform and bubble the call without interpreting
the result, then copies returndata for its dedicated decoder. This entails an
extra returndata copy, but preserves read-only capability declarations. The
limitation is an API ergonomics/performance issue, not a state-write bug.

All 26 pinned Actions.sol codes and ActionConstants sentinel values are also
ported for the upcoming router dispatch. Reserved/deprecated action codes are
retained; each router must still enforce its own supported subset.

### Protocol ABI packaging

`export_protocol_abi.py` validates callable signatures, event indexing,
mutability and output layouts before exporting the pinned client interface.
It permits Fe's single *static* tuple output to represent the reference's
multiple outputs, and permits a pure implementation of a view interface. It
rejects dynamic tuple flattening, changed types, missing signatures, duplicate
signatures, changed event indexing, and incompatible mutability. Target names
and internalType metadata come from the pinned interface. Error declarations
are interface metadata: Solidity may include unreachable inherited declarations
(e.g. StateView.NotPoolManager) whereas Fe lists reachable errors (e.g. Panic).
Both inventories are retained in the audit instead of claiming identical
compiler error reachability.

PoolManager.protocol.abi.json and StateView.protocol.abi.json are accompanied by
source/artifact/adapter hash audits. The combined runtime suites already compare
return bytes decoded through the Solidity interfaces. Negative adapter probes
reject dynamic return flattening, uint128/uint256 changes and payable/view
mismatches. Successful future manager/state_view runs generate these interface
artifacts automatically. This is an explicit port-side metadata workaround;
it does not claim to fix Fe's raw ABI export limitations. StateView exports all
12 functions as view already; only names/static return grouping need adapting.

The StateView runtime sizes are O1 5,887 bytes and O2 5896 bytes.
Archived state-view-o{1,2}.{json,log} files capture compiler/source/test/reference
identity for the passing builds. The remaining full goal still includes the
ReservesLens, router, quoter, PositionManager and their transaction workflows.

## Periphery calldata decoder

All CalldataDecoder helper entrypoints are ported, using absolute calldata views
rather than ordinary ABI decoding. The pinned assembly deliberately masks some
lengths and offsets to 32 bits, enforces a canonical actions/params tail layout,
and permits scalar reads outside the logical bytes view. Parameter access keeps
Solidity's subsequent full-calldata bounds checks. Swap helpers return lazy
struct locations: the decoder tests verify those locations, not yet the router's
nested field accesses or swap execution.

O1 and O2 each pass five 10,000-case differential properties and the exhaustive
0–384 byte length matrix across all 17 decoder modes. Canonical/mutated action
arrays, dirty scalar fields, mint/liquidity parameters, unpadded slices and
32-bit-masked offsets/lengths are compared byte for byte, including reverts.
Evidence is in `calldata-decoder-o{1,2}.{json,log}`.

A port defect was exposed by a 32-byte zero-filled mint payload: the initial
PoolKey reader used the general ABI decoder, which rejected the missing 160-byte
struct head. Solidity's assembly-created calldata struct instead validates
individual fields when accessed, while CALLDATALOAD zero-fills beyond calldata.
The replacement retains canonical field validation without an aggregate length
check. The before trace is `calldata-decoder-short-mint-before.log`; the length
matrix and dirty-field fuzzing prove the correction. No compiler change was
needed or claimed.

The current MemVec API stores fixed-length static single-word elements; it
cannot directly build a dynamic `bytes[]` with push operations. Production code
therefore traverses calldata views, and the decoder test adapter explicitly
constructs ABI output for the variable-size parameters. This is a collection/API
limitation, not a protocol simplification.

## External transient reads and DeltaResolver

The complete TransientStateLibrary query surface now reads the manager via
STATICCALL: synced currency/reserves, nonzero delta count, currency delta and
unlock state. Currency-delta keys preserve two padded address words; synced
currency truncates to 160 bits, and native currency short-circuits reserve reads.
DeltaResolver's debt/credit and settle/take/wrap amount mapping preserves sign
errors, checked MIN_INT256 negation, balance sentinels, explicit-amount early
returns and insufficient-balance errors. O1/O2 each pass three 10,000-case
properties plus boundary scenarios. Tests independently calculate slots and
values, require expected external calls, compare malformed/reverting providers,
and exercise native and token balances. This component proof does not substitute
for final workflows with the Fe manager.

Evidence: `delta-resolver-o{1,2}.{json,log}`. The first runner registration omitted
the periphery revision from metadata despite verifying/copied source hashes.
The runner is corrected. Archived affected records explicitly annotate the
metadata repair with the original record hash and fresh verification of every
compiled periphery source against the pinned manifest. Execution results and
source snapshots were not changed.

The source-by-source periphery inventory is now `periphery_status.json`. It
retains pending interfaces and less central pinned components (permissioned
extensions, metadata/SVG libraries and deployment competition utilities), with
no implicit exclusion from the outstanding scope. Component checks are
explicitly distinguished from final transaction-workflow completion.

## Settlement and Permit2 payment sequencing

`payments.fe` implements DeltaResolver's take/settle operations and a TokenPayer
hook, with Permit2Payment matching the pinned PositionManager payment policy.
Zero amounts return before calls; sync precedes payment; native settlement sends
value directly; token payment precedes zero-value settlement. Self-payment uses
the previously validated Currency.transfer behavior. External payer payment
preserves PositionManager's explicit uint160 truncation before Permit2.transferFrom.
Caller/payer authorization belongs to the invoking router/position manager and
is not supplied by this low-level library.

O1 and O2 each pass 20,000 fuzz cases and two boundary scenarios. The Solidity
adapter derives from the actual pinned DeltaResolver and supplies the
PositionManager payment hook. Instrumented manager/token/Permit2 providers
validate call order, all parameters, native balances, state rollback, skipped
zero calls, injected failures, short settle returns, missing contract code,
insufficient native funds and uint160 truncation. Providers are test doubles;
full Permit2/ERC20/Fe-manager transaction workflows remain outstanding.
Evidence: `payments-o{1,2}.{json,log}`.

Fe Call.call with a unit return type does not itself enforce code existence,
where Solidity high-level void calls do. The port explicitly checks code before
sync, take and Permit2 transferFrom. This is an API/semantic difference handled
locally, not a claim that raw EVM calls must reject empty-code destinations.
The differential missing-code scenarios validate the adapter behavior.

The complete ingot passed `fe check` during this work; the final payment harness
subsequently compiled and passed both optimization suites. No compiler or std
changes were required for these additions. Router action dispatch and swaps,
quoting, position management, remaining inventory components and complete
end-to-end/invariant verification still remain open.

## Router execution implementation — validation in progress

`router.fe` now contains the pinned router's four swap actions and five payment
actions, including per-hop price checks, all-or-nothing exact output at every
hop, sentinel amounts, recipient mapping and a pool-validation hook for the
permissioned extension. `router_params.fe` keeps typed calldata accesses lazy.
`v4_router.fe` supplies an explicit concrete execute(bytes) entrypoint, immutable
manager/Permit2 addresses, manager-only callback and the pinned transient locker.
The upstream V4Router is abstract, so this wrapper's public execute ABI is a
port choice, not an upstream ABI claim.

A direct differential suite derives from the unchanged pinned V4Router and
compares status, revert bytes and complete ordered swap calldata. It includes
single/multi-hop inputs, dirty and short encodings, price checks and second-hop
exact-output shortfall. Validation is still running; this entry does not claim
passing router parity. The concrete wrapper's callback/reentrancy and combined
payment flows still require their own integration coverage.

The first router differential run passed six tests but found a dirty-hook-offset
counterexample in `testFuzz_mutatedSingle`. The initial typed-tail accessor used
unsigned bounds and a uint64 offset limit. Pinned solc 0.8.26's generated
`access_calldata_tail_bytes_calldata` instead uses signed SLT/SGT comparisons,
wrapping additions/subtractions and only restricts the *length* to uint64. A
relative hook offset of
`0xc090fc4683624cfc3884e9d8de5eca132f2d0ec062aff75d43c0465d5ceeab23`
is accepted and yields empty hook bytes from beyond calldata; the original Fe
accessor rejected it. A deterministic before trace is retained in
`router-negative-offset-before.log`. The typed bytes/array/path accessors now
mirror the generated checks. This is a port compatibility defect, not a newly
identified Fe compiler bug. The fixed regression and full O1 rerun now pass.
O2 and concrete-wrapper integration have not yet been validated.


The corrected swap implementation passes all nine O1 tests: 50,000 fuzz cases
across single/multi-hop parameters, random bytes and dirty scalar/array/path
locations, plus success, per-hop shortfall/price, length-boundary and signed-offset
regressions. Ordered manager swap calldata and transaction rollback agree with
the actual pinned V4Router. Evidence: `router-o1.{json,log}`. The adapter exposes
only `_handleAction` for swap testing and deliberately does not supply a token
payment implementation; it therefore establishes swap-component parity, not
combined router settlement or execute/unlock lifecycle parity. O2 is running.

Router swap parity also passes O2: nine tests, 50,000 fuzz cases and all fixed
regressions. Both optimization artifacts are retained as `router-o{1,2}`. The
concrete O1 V4Router contract builds successfully as well.

Combined workflow validation is now in progress. `RouterWorkflows.t.sol` runs
Solidity-router/Solidity-manager, Fe-router/Solidity-manager and Fe-router/
Fe-manager systems from identical snapshots so contract addresses, event topics
and balances can be compared directly. It seeds real pool liquidity and checks
native/ERC20 payment, output taking, relocking, cleared deltas, callback
permissions, reverting batches and payment-triggered reentrancy. Permit2 is an
explicit transport test double; full Permit2 allowance/permit integration remains
outstanding. The runner accepts a previously validated PoolManager artifact only
after checking its compiler, optimization, every recorded source hash and actual
bytecode hash; this avoids recompiling unchanged manager code without weakening
artifact provenance.

The initial combined O1 run passes 20,000 fuzz cases plus callback/empty-batch
and payment-reentrancy scenarios. Extending to two pools exposed a test-model
error, not a port discrepancy: input amounts of one or two smallest units can
round to zero intermediate output in the first pool; the second pool rejects
`amountSpecified == 0` with SwapAmountCannotBeZero. This was reproduced first on
the unchanged Solidity system. The test now explicitly requires that error,
retains the tiny amounts in fuzzing and adds deterministic amounts 1, 2 and 3.
The reference trace is `router-workflow-tiny-input-reference.log`. Expanded O1/O2
runs additionally cover SETTLE_ALL, TAKE_ALL and TAKE_PORTION, including failed
maximum-settlement and invalid-bips checks after a swap.

The expanded combined router suite passes all seven tests under both O1 and O2:
four 10,000-case properties plus callback/empty-batch, payment-reentrancy and tiny
intermediate-amount scenarios. O1 additionally replays the cached tiny-input
counterexample. Every property compares the Solidity baseline with both mixed
and fully Fe systems, including complete event data, hot pool storage, native and
token balances, rollback, cleared transient currency deltas and restored locks.
Both single- and two-pool routes cover exact input/output; payment variants cover
external-payer and self-payment, settle/take-all, partial taking, settlement caps
and invalid bips. No production change was required for these workflow checks.
Evidence: `router-workflows-o{1,2}.{json,log}` includes the separately verified
manager artifact's full provenance. Router runtime sizes are 10,144 bytes (O1)
and 9,974 bytes (O2); the manager's larger deployment-size issue remains open.

This completes the current router component/workflow checkpoint. Full Permit2
semantics, quotes, tokenized positions, remaining inventoried periphery and the
final protocol-wide adversarial/ABI/invariant audit remain outstanding.

## Quoter implementation and tuple-array ABI limitation

The four V4Quoter quote paths and BaseV4Quoter callback/self-call flow are now
implemented and undergoing differential validation. Quotes use temporary swaps
and QuoteSwap reverts; the sender marker intentionally does not impose a router
reentrancy lock. Exact-input uint128-to-int128 conversion and checked int128
negation in exact-output result conversion follow the pinned source.
Gas estimates measure the Fe execution and are not expected to equal Solidity
bytecode costs; tests compare quote amounts/reverts and check measured-gas bounds.
No successful quoter parity result is claimed yet.

A concrete standard-library gap was encountered: Encode/Decode support a
five-field path tuple, but AbiSpan tuple implementations stop at arity four.
Consequently DynArray<(Address, Uint24, Int24, Address, Bytes)> fails Decode<Sol>
bounds. `tests/repros/tuple5_dynarray.fe` reproduces the expected compile failure
(copy it outside the project ingot before running `fe check` to avoid checking
unrelated generated vector tests); `quoter-tuple5-abispan-before.log` records the
diagnostics. PathKey now supplies local ABI codecs. Its span uses a nested static
four-tuple followed by bytes, preserving the same wire layout. No compiler/std
change is claimed. Dynamic array forwarding also explicitly canonicalizes paths,
because DynArray's encoder otherwise preserves the original encoded tail.

The first quoter implementation passed canonical O1 single/multi quote fuzzing
(20,000 cases) and sign/caller scenarios. An added dirty-bool direct call to
_quoteExactInputSingle then proved a revert-precedence defect: Solidity's
calldata struct checks only the head before selfOnly, returning NotSelf; eager Fe
tuple decoding rejected the scalar first with empty bytes. The before trace is
`quoter-auth-before.log`. Internal quote message types now check only their
calldata heads, preserve the declared wire fields for ABI metadata, and defer
scalar/tail reads to the simulation after caller authorization. Public memory
parameters remain eagerly decoded and canonicalized. The corrected full run,
including filled multi-hop routes and oversized arrays, is in progress.

The lazy internal decoder passed the authorization regression and 30,000 O1
quote/filled-route cases, but an oversized public path array exposed another
port mismatch: Solidity returns Panic(0x41), while generic Fe decoding returns
empty bytes. Public Solidity memory decoding checks allocations before payload
bounds, unlike its calldata views. `quoter_memory.fe` now preflights the pinned
reference allocator and field-validation order before ordinary decoding,
including nested path structs and hook bytes. This is a local compatibility
adapter; the standard library is unchanged. Boundary/malformed-input validation
is in progress and this correction is not yet reported as passing.

The memory-decoder O1 run passed 40,000 fuzz cases and all allocation/auth/sign
regressions, but a new short-revert test failed. With only the QuoteSwap selector,
Solidity returns 324 (the length of its encoded internal-single call) whereas Fe
returned zero. The pinned solc IR reuses the unlock call scratch region for the
catch bytes and does not clear bytes beyond returndata; QuoterRevert's unchecked
load reads the old argument-length word. `parse_unlock_quote` now explicitly
combines returned bytes with that length for 4–35 byte reasons. This preserves
the pinned artifact behavior without relying on Fe allocation accidents. Before
evidence: `quoter-array-before.log`, `quoter-short-before.log`. Revalidation of
all four public quote methods is pending.

The short-revert correction passed all four public methods and 40,000 O1
fuzz cases. Exhaustive truncation then found that generic Fe Bytes decoding
requires trailing ABI padding that Solidity's memory decoder does not require.
A complete four-byte hook payload without its padding was rejected by Fe before
reaching the manager (`quoter-padding-before.log`). The local memory adapter now
builds canonical bytes/path tails from the validated payload itself, preserving
alias/reordered path pointers and accepting missing padding. Revalidation is
pending; no standard-library fix is claimed.

The corrected O1 quoter component run now passes 14 tests, including 50,000
fuzz cases, exhaustive truncation of single/multi calls, aliased/reordered path
tails, allocator/error precedence, all short QuoteSwap lengths (0–36) for all
four public methods, sign boundaries and nested sender-marker behavior. The
checked protocol ABI export succeeds. Evidence is `quoter-o1.{json,log}` and
`V4Quoter.protocol.abi{,.audit}.json`; runtime is 14,261 bytes. O2 and real-pool
workflow validation are still pending at this point in the log.

The parity runner now supports `--reuse-fe-artifact` for workflow tests against
an already-passed component build. It requires exactly identical frozen source
hashes, compiler hash and optimization, verifies creation bytecode, and embeds
the original validation and copied-artifact hashes. PoolManager evidence remains
separately verified; an early workflow attempt was rejected after a quoter source
changed, and refreshed manager builds are used rather than bypassing that check.

## Quoter component and real-pool checkpoint

Both O1 and O2 now pass the full 14-test quoter component suite (50,000 fuzz
cases each) and checked protocol ABI export. Runtime sizes are 14,261 and 14,106
bytes respectively. `quoter-o{1,2}.{json,log}` records the exact compiler, source
and test hashes; `quoter-o{1,2}-abi-audit.json` records the ABI checks.

`QuoterWorkflows.t.sol` additionally passes 20,000 single/multi-pool properties
plus tiny/zero/uninitialized/insufficient-liquidity scenarios at each optimization.
Each compares Solidity/Solidity, Fe/Solidity and Fe/Fe quoter/manager systems at
identical addresses using snapshot restoration. Native and ERC20 pools, both
directions and exact input/output are covered. Pool hot storage, token/native
balances, manager lock/nonzero-delta count, all route-currency transient deltas
and the sender marker must remain unchanged/reset after successful or rejected
quotes. Quote amounts and exact revert bytes match; gas estimates are positive
measurements of each implementation, not required to match each other.

Evidence: `quoter-workflows-o{1,2}.{json,log}` embeds passed, hash-checked quoter
and manager builds. Refreshed manager runs also pass all 16 tests and 60,000 fuzz
cases per optimization (`manager-quoter-o{1,2}.{json,log}`). The periphery inventory
marks only this component milestone. ReservesLens, tokenized positions and their
supporting contracts, remaining inventoried periphery, real Permit2 and final
protocol-wide validation are still outstanding.

## ReservesLens: read-only bounded STATICCALL gap

ReservesLens requires bounded, failure-tolerant STATICCALL for ERC165 and hook
statistics. `staticcall_decode` always bubbles failure and copies all returndata;
`Call.raw_staticcall` provides the necessary bounded buffer but unnecessarily
requires `mut self`. A minimal read-only Call example fails with error 8-0066;
using mutable Call compiles but emits a nonpayable ABI instead of view. Evidence:
`reserves-staticcall-before.log`. The standard-library receiver is changed to
immutable; the output buffer remains mutable. An ABI regression and the existing
identity-precompile output-buffer test now exercise read-only Call/Evm. Validation
and the ReservesLens implementation are in progress.

The read-only receiver correction passes all 31 ABI unit tests and all seven
precompile runtime tests. The output buffer still receives only its capacity
while RawCallOutcome reports the full return size. The minimal example now
compiles and emits view; `raw_staticcall_readonly.fe` and
`reserves-staticcall-{abi-tests,runtime-tests}.log` plus
`reserves-staticcall-view.abi.json` retain the evidence.

Proposed release note for a future numbered fix PR: Allow Call.raw_staticcall
through a read-only Call capability, so bounded external reads can be exposed
as view functions. No PR/issue number is invented for a newsfragment; the
repository convention requires assigning that number when a PR is opened.

ReservesLens wire types, errors and paged tick-scan logic are now being ported.
They are not yet runtime validated or a complete lens implementation.

ReservesLens now has an initial implementation of all seven public methods,
including batched complete scans, bounded paged scans, populated tick reads,
snapshot/cursor validation and URC-3/ERC165 hook statistics. The OpenZeppelin
ERC165Checker/IERC165 dependency is pinned and hashed at the v4-core gitlink
revision dbb6104ce834628e473d2173bbc9d47f81a9eec3. Initial differential validation
is running; no passing lens component or end-to-end result is claimed yet.

The paged methods require Solidity's three top-level return values rather than
Fe's ordinary single dynamic-tuple return. They explicitly encode the flat
result/cursor/done head via return_page. Protocol ABI export therefore requires
an explicit per-signature dynamic-flattening exception, applied only after the
runtime suite compares the returned bytes. Default dynamic-shape rejection is
unchanged; six adapter boundary tests pass, including rejection of changed
inputs, mutability, unknown signatures and incompatible return fields.

## ReservesLens component checkpoint

O1 and O2 each pass eight tests and 30,000 fuzz cases. Coverage includes all
seven methods, overlapping ranges and zero-net ticks, full/paged equality,
mid-word continuation, cursor snapshot errors, manager batch failures, batch
length mismatch, ERC165 noncanonical true values, hook call failures/short and
oversized responses, invalid effective reserves and insufficient hook gas.
Tick spacing one additionally exercises the entire bitmap domain, multiple
256-slot batches and multiple pages. All calls are STATICCALLs and returned
bytes/reverts are compared against the pinned Solidity implementation.

Evidence: `reserves-lens-o{1,2}.{json,log}`, per-optimization ABI audits and
`ReservesLens.protocol.abi.json`. Both exports pass with exactly the two explicit
flat-dynamic-return signatures. Six ABI-adapter boundary tests also pass.
The first corrected O1 run passed 3,000 cases before these expanded checks;
the initial compiler diagnostics were ordinary port type/argument-label errors,
not compiler regressions.

Runtime sizes are 40,944 bytes (O1) and 40,375 bytes (O2), above EIP-170.
Deployment-size reduction remains explicitly deprioritized. The manager storage
and hook providers here are controlled fixtures, so real-pool Lens workflows
and broader malformed ABI/returndata tests remain final protocol gates. This
is a component milestone, not completion of the full Uniswap implementation.

## Position permit foundations in progress

UnorderedNonce, ERC721PermitHash and EIP712_v4 domain/digest helpers are now
implemented and undergoing reference comparison, including replay rollback,
chain-ID changes and the reference's cached-domain delegatecall behavior.
An initial compile encountered Fe's documented inline String<31> ceiling when
expressing the 67-byte EIP-712 type string (`permit-inline-string-limit.log`).
The domain uses its precomputed keccak constant instead; the Solidity test
independently computes that hash from the full type string. This is a language
capacity limitation, not a newly claimed compiler regression. Signature
verification and complete ERC721/PositionManager integration remain outstanding.

## Permit foundation checkpoint

EIP712_v4, ERC721PermitHash and UnorderedNonce helpers pass four tests and
30,000 fuzz cases at each of O1/O2 (`permit-foundations-o{1,2}.{json,log}`).
Tests cover arbitrary name bytes, chain forks and restoration, typed-data
hashes, permit/permit-for-all field hashes, raw nonce mapping slots, sibling
bits and replay rollback. Payable revocation retains value only on success.
The original-chain delegatecall uses the cached separator, while a changed
chain rebuilds using the delegate caller's address, as documented upstream.

A failing initial delegate assertion was a Solidity test-oracle issue, not a
Fe production defect: vm.chainId mutates an environment value that solc treats
as transaction-constant and may reload. Fe actually returned the independently
verified hash for chain 31338 and the relay address. The test now captures the
original chain through an external currentChain() boundary; both reference and
Fe then pass without a production change. `permit-delegate-test-before.log`
retains the failure trace. The helpers are validated components; signature
verification, ERC721 and PositionManager integration are still in progress.

## Dynamic ABI padding regression and fix

SignatureVerification's valid 65-byte signature exposed a shared ABI decoder
incompatibility: a complete calldata payload with omitted trailing padding was
accepted by Solidity 0.8.26 but rejected by Fe. The original differential trace
is retained in `tests/results/signature-padding-before.log`.

Core decoding now validates actual byte lengths independently of padded owned
allocation sizes. Bytes/DynString copies clear padding and copy only validated
bytes, including with bounded memory inputs containing poisoned data beyond the
logical end. Dynamic array span discovery accepts a truncated final padding
region and copies its validated, potentially unaligned span. Arrays retain
wire-layout encoding by design; this does not introduce general canonicalization
of arbitrary nested array offsets or padding.

Ten focused regressions cover four Bytes decoding entry points, poisoned memory,
strings, nested arrays, aligned/empty data, missing heads/payload and overflowing
lengths. Along with existing dynamic-payload, nested-message and composed-decoder
regressions, all 25 tests pass at both O1 and O2 (`abi-unpadded-o{1,2}.log`).
Compiler SHA-256: 3237760c6e2bbc33ca03d02d65459523d9d8cb718a7d5903e668e9dcbd7b5ca3.
The signature differential suites are being refreshed with this compiler.
Proposed release note (pending an assigned issue/PR number): accept complete
unpadded dynamic ABI byte/string payloads while preserving memory bounds and
zeroing owned trailing padding. No unrelated allocation-limit parity claim.

## Signature verification checkpoint

Pinned Permit2 SignatureVerification is ported and passes 30,000 differential
cases plus the unpadded-valid-signature regression at each O1/O2
(`signature-verification-o{1,2}.{json,log}`). Coverage includes 65-byte and
EIP-2098 signatures, reference-compatible high-S acceptance, wrong signers,
invalid lengths/signatures and ERC-1271 contracts. Contract checks cover revert
bubbling, static-call enforcement, short/dirty/wrong-magic returns and oversized
successful returndata, with only a bounded word copied on success. Exact
low-gas exhaustion behavior and integration into ERC721 permits remain pending.
Both runs use the corrected ABI compiler recorded above. This validates the
signature library component, not the full Permit2 payment contract.

## ERC721 permit integration in progress

ERC721 token operations, the reference's approval override, ERC721 receiver
callbacks, permit/permit-for-all sequencing and constructor string storage are
implemented and being compared against ERC721Permit_v4 plus pinned Solmate.
The new test adapter exposes internal mint/burn operations without adding them
to a claimed production PositionManager API. Initial differential coverage is
being built for storage/log equality, authorization, self-transfers, signature
replay/revocation/deadlines, receiver reentrancy/rollback and short/long metadata.
This component is not yet marked validated.

Compiler build provenance for the padding/signature/ERC721 runs: the binary
reports revision `8b43741b4`, with the then-uncommitted core ABI patch archived as
`tests/results/abi-unpadded-compiler.patch` (subsequently committed in
`170108fba`). Later test runs can correctly record an empty current-worktree
compiler diff because that patch is now committed; this does not mean the
binary was built from unmodified 8b43741b4. Its SHA-256 remains the identity used
by artifact reuse checks.

## ERC721 permit component checkpoint

The token/permit integration passes seven tests with 60,000 fuzz cases at each
O1/O2 (`erc721-permit-o{1,2}.{json,log}`). Exact raw slots and events match the
Solmate/ERC721Permit_v4 reference across mint/burn, authorization, self-transfer,
approvals, nonce replay/revocation, EOA and ERC-1271 permits, deadline boundaries,
receiver reentrancy/rollback and short/long arbitrary-byte name/symbol storage.
Half of the EOA permit cases omit final ABI padding. The reference's unused
NoSelfPermit declaration is not turned into an extra behavioral restriction.

This test harness deliberately exposes internal operations; it is not the
PositionManager contract. Descriptor-driven tokenURI, subscription-aware
transfers, the PositionManager action engine and final whole-protocol ABI /
workflow validation remain pending. The harness's isolated eight-module source
closure is frozen and hashed by the runner; broader integration is a later gate.

## Multicall implementation in progress

Delegatecall execution and canonical bytes[] result encoding are implemented,
with differential tests for shared sender/value context, nesting, dynamic
results, whole-batch rollback and nonpayable inner calls. A separate adversarial
probe (`tests/repros/MulticallDecoderOrder.t.sol`) is prepared for the known
semantic distinction between Fe's owned dynamic-array decoding and Solidity's
lazy calldata element access; its outcome is not yet established. No complete
Multicall parity claim is made at this point.

## Multicall functional checkpoint and confirmed ABI limitation

Four tests with 30,000 fuzz cases at each O1/O2 pass for recursive batches,
shared msg.sender/msg.value, canonical dynamic results, arbitrary revert
bubbling, atomic state/value rollback, empty batches and nonpayable inner calls
(`multicall-o{1,2}.{json,log}`).

The separate `MulticallDecoderOrder.t.sol` probe confirms a limitation, retained
in `multicall-decoder-order.log`: a valid first call reverts with `first call
failed`, while a later element has an out-of-range offset. Solidity's calldata
array accesses that later element lazily, so it propagates the first revert.
Fe's owning DynArray decoder validates all dynamic tails before entering the
body and instead returns an empty ABI-decoding revert. Both transactions revert
and preserve state/value; exact error precedence differs. This is a confirmed
owned-versus-calldata ABI semantics gap, not a claim that the reference accepts
a successfully executed malformed element. Full malformed-calldata parity is
explicitly not achieved. The component inventory uses
`implemented_with_known_abi_gap`, not `component_validated`.

## Native wrapper component checkpoint

NativeWrapper passes three tests and 20,000 fuzz cases at each O1/O2
(`native-wrapper-o{1,2}.{json,log}`). Tests compare deposited/withdrawn value,
wrapped/native balances, rollback, WETH/manager receive authorization, unknown
selectors, zero-amount short-circuiting and non-contract WETH addresses. The
reference's code-existence checks for void-returning calls are explicit in Fe.
The initial Solidity test compile required an explicit bytes cast in a ternary;
no production correction was needed. Actual wrapped-token and PositionManager
workflows remain integration gates.

## Pool initializer checkpoint

PoolInitializer_v4 passes 10,000 fuzz cases plus no-code/dirty-argument scenarios
at each O1/O2 (`pool-initializer-o{1,2}.{json,log}`). It preserves the exact
try/catch boundary: failed manager calls return int24.max; successful calls with
short, empty or noncanonical int24 returndata revert in the caller. Large
successful returndata is bounded to one copied word. Callback calldata, retained
value and callee rollback match the reference.

An initial port incorrectly called Decode::decode_from directly on a scalar
return without validating its head. That API explicitly assigns bounds checks
to the caller; using decode_from_bounded fixed the port. This was an adapter
mistake, not a newly claimed compiler bug. Full real-manager/multicall workflows
remain integration gates.

## Subscriber notifier component checkpoint

Notifier passes four tests and 20,000 fuzz cases at each O1/O2
(`notifier-o{1,2}.{json,log}`). Exact subscriber/position-flag storage, logs,
callback calldata, wrapped errors and value rollback match the reference.
Callbacks observe subscription flags/mappings already set or cleared; reentrant
unsubscribe during subscribe matches the reference's resulting event/state
sequence. Unsubscribe swallows callback failure/OOG, rejects an insufficient
parent gas budget, and skips callbacks after subscriber code removal. Burn
clears the subscriber before calling it, while modification preserves it.

As with the reference abstract Notifier, parent pool-lock and token-approval
guards are integration responsibilities. The harness intentionally supplies
no-op modifiers so this checkpoint isolates notification behavior; these guards
must be present in PositionManager before end-to-end completion is claimed.

## Permit2 forwarding and real dependency workflows

Permit2Forwarder single/batch operations pass 20,000 differential cases plus
noncanonical-array/no-code scenarios at each O1/O2
(`permit2-forwarder-o{1,2}.{json,log}`). The adapter preserves arbitrary owner and
spender fields, catches call reverts as returned bytes, retains incoming native
value, ignores success returndata and validates narrow static-array fields
before forwarding. An initial message-variant/type-name shadowing error and a
missing argument label were ordinary port compile errors, corrected locally.

Real Permit2 workflows pass another 20,000 cases per O1/O2
(`permit2-workflows-o{1,2}.{json,log}`). These deploy the pinned, unmodified
Permit2 contract twice and compare Fe/Solidity forwarders using independently
signed EIP-712 domains. Tests cover expiration, replay rejection, sequential
batch nonces for a repeated token, reference-compatible empty-batch replay,
allowance values/Permit events and subsequent ERC20 transferFrom payments.
Tokens are controlled ERC20 fixtures; router/PositionManager settlement remains
an explicit integration gate. A Solidity test helper initially attempted to
ABI-encode a tuple-valued external call directly; destructuring fixed that
oracle compile error without changing production code.

Permit2's exact 0.8.17 pragma requires a separate dependency build. The new
`tests/build_permit2_reference.py` verifies the compiler binary and every pinned
source hash, retains its original 1,000,000 optimizer runs/via-IR/no-bytecode-hash
settings, and records the 9,152-byte runtime in `permit2-reference.json`.
Its Solmate revision is 8d910d876f51c3b2585c9109409d601f600e68e1, distinct from
v4-core's dependency and taken from Permit2's own gitlink. Integration artifact
reuse verifies revision, compiler settings/hash, complete source hash map and
creation bytecode hash before execution; retests also verify the bytecode hash.

## PositionManager integration checkpoint

The concrete PositionManager now has the pinned storage layout, NFT/permit and
subscriber entrypoints, transient locker, liquidity action dispatcher, native
wrapping, Permit2 forwarding and descriptor forwarding. O1/O2 integration validation now passes; final protocol-wide gates and the
inherited Multicall ABI gap remain open.

The new lifecycle oracle uses the actual pinned Permit2 runtime and compares
Solidity/Solidity, Fe/Solidity and Fe/Fe PositionManager/PoolManager combinations.
It covers mint/increase/decrease/burn, donations and fee collection, ERC20/native
settlement, subscriber callbacks, slippage rollback, packed storage and events.
All three implementation combinations pass 20,000 fuzz cases and three
scenarios at each O1/O2 (`position-manager-o{1,2}.{json,log}`). Guards/public-entrypoint tests additionally
exercise callback authorization, deadlines, locker cleanup, initialization,
multicall, native receive restrictions and transfer-triggered unsubscribe.

Initial port mistakes included message/type name shadowing, an ambiguous struct
literal in a condition, and incorrect NFT string constant lengths/padding; these
were corrected locally. The Solidity fixture required a non-reserved variable
name and memory-safe annotation on its deployment assembly. None is currently
classified as a new compiler bug. The inherited Multicall malformed-array error
precedence gap remains open. Test deployment limits are explicitly raised for
this suite, consistent with the requested lower priority for deployment size.

## Legacy position config and vanity helpers

The pinned PositionConfig/PositionConfigId and VanityAddressLib components now
pass 40,000 differential cases plus vanity boundary cases at each O1/O2
(`periphery-aux-o{1,2}.{json,log}`). The hash compares the canonical packed
72-byte position configuration; config-ID operations compare raw slot contents
and subscriber-bit transitions, including setters receiving a high bit already
set. Vanity checks include leading-zero/four counts, tie behavior and nibble
index panics. The AddressStringUtil uppercase-prefix formatter and invalid length errors
also pass. Their auxiliary harness has its own five-module build closure.

An initial port omitted the 24-bit mask when constructing FixedBytes<3> from
negative ticks. The packed encoder correctly rejected these noncanonical values;
masking the signed two's-complement bits corrected the port. The reference
assembly accepts some noncanonical raw calldata without validating each field;
this canonical-value helper suite does not claim parity for such an externally
exposed assembly adapter. Deployment competition remains independently pending.

The PositionManager suite also covers externally initiated unlocks, deprecated
FROM_DELTAS actions, close/clear/take, wrap/unwrap/sweep, ERC1271 NFT permits,
nonce replay/revocation and operator permits. Protocol ABI audits are archived
for both optimizations, including an explicit fallback-to-receive adapter:
the Fe fallback accepts only empty calldata and enforces the reference sender
restriction; unknown selectors and 1–3 byte calldata revert in both versions.
The export adapter requires explicit opt-in and rejects other signature or
mutability changes (eight adapter unit tests pass).

PositionManager runtime is 37,886 bytes at O1 and 36,505 at O2. Its Foundry
fixture raises `code_size_limit` to 200,000 for execution; normal EIP-170
deployment remains over the limit and is not claimed. Both builds took roughly
eight minutes on this machine. A moved Bytes32 salt reused for event emission
was another local ownership mistake, corrected by constructing the event field
from the token ID. Fresh PoolManager O1/O2 artifacts with the current ABI-fixed
compiler pass 16 tests/60,000 fuzz cases each (`manager-position-o{1,2}`).

## SafeCurrencyMetadata

Token symbol/decimals extraction passes 20,000 fuzz cases plus byte-length and
unaligned-offset boundaries at each O1/O2 (`currency-metadata-o{1,2}`). Tests
cover arbitrary success/revert returndata, native labels, no-code currencies,
bytes32 symbols (removing every zero byte), the 12-byte truncation rule, short
truncate panics, oversized decimals and malformed dynamic-string success data.
Unpadded dynamic returns are accepted consistently with the core ABI fix.
The pinned OpenZeppelin IERC20Metadata interface and hash are added to the
reference manifest. An initial missing Fe argument label was corrected before
runtime validation. Full PositionDescriptor/SVG integration remains pending.

## New compiler panic: record literal in Address equality

The SVG port exposed a reproducible semantic-lowering panic in
`crates/hir/src/analysis/semantic/lower/body.rs:1001`: `record field should
resolve`. `tests/repros/record_literal_comparison.fe` reduces it to
`value == (Address { inner: 0 })`, with `core::ops::Eq` in scope; running its
single test with the current release compiler exits 1 after a compiler panic.
`tests/results/record-literal-comparison-panic.log` retains the backtrace.
The SVG generator compares address `.inner` values as a behavior-preserving
workaround. This is an open compiler issue, not an EVM runtime mismatch.

## Isolated upstream fixes and local parity corrections (2026-09-23)

Two independent one-commit branches based on upstream/master `50d0fefb8`
were pushed, each with a regression fixture and newsfragment:

- `fix/record-literal-borrow-panic` (`1278db2f3`): unwrap the implicit
  view before record field lookup and aggregate construction. The original
  Address literal comparison panics without the fix; 15 focused tests pass
  at both O1 and O2, including struct/enum literal method receivers.
- `fix/abi-unpadded-dynamic-payloads` (`8bc1412aa`): isolate the prior demo
  compiler patch accepting omitted trailing padding and bounding copies to
  validated bytes. Four regression cases fail on upstream without this patch;
  22 focused tests pass at both O1 and O2.

Neither upstream branch contains the Uniswap demo or its history.

The local Multicall correction replaces eager owned-array decoding with a
calldata-only view. The offset table is validated before execution; each bytes
payload is checked just before its delegatecall. A malformed later payload
therefore cannot mask an earlier revert. The explicit selector remains
`0xac9650d8`; Fe omits numerically selected handlers from its raw ABI, so
protocol export now requires the explicit `--lazy-multicall` adapter (alongside
`--fallback-receive` for PositionManager). The adapter is backed by differential
runtime tests, not by raw compiler ABI metadata; its unit tests reject unrelated
signature, output and mutability changes.

The SVG oracle now uses the unchanged pinned Solidity library with solc 0.8.26,
via-IR and **optimizer disabled**. This avoids the reference compiler's Yul
stack-too-deep failure. The runner records the optimizer setting in its evidence;
this is a reference test configuration fix, not a Fe compiler fix.

Fresh O1/O2 runs each pass 40,000 Multicall differential cases plus the empty
and nonpayable scenario, and 20,000 SVG differential cases plus boundaries.
Evidence: `multicall-local-fix-o{1,2}.{json,log}` and
`svg-local-fix-o{1,2}.{json,log}`. Multicall protocol ABI audits are archived
alongside them. All 13 ABI export adapter tests pass.

Fresh PositionManager O1/O2 builds also pass all five integration tests (20,000
fuzz cases per optimization), including the malformed-later-item regression
through the actual PositionManager callback guard. Protocol ABI exports pass
with both explicit adapters. Evidence is archived as
`position-manager-lazy-multicall-o{1,2}.{json,log}` and the corresponding ABI
audits. The initially running runner processes lacked the new export flag;
exports were completed separately with `--fallback-receive --lazy-multicall`,
and the runner now supplies both flags for subsequent runs.

## Current-master compiler refresh and metadata validation (2026-09-23)

The standalone checkout was clean at the start of this continuation. A live
`git ls-remote` check resolved Fe upstream master to
`fd5f11847143070e9ba8fda364a2d31caf3356e5`. It was fetched into an isolated
checkout and built locally. The original sibling checkout, including its
already-deleted extracted demo files, was left unchanged.

A fresh compiler build initially failed because the tree-sitter CLI was absent
from PATH. Reusing the installed CLI resolved this build dependency; it was not
a Fe language/compiler defect. Unmodified master then rejected the existing
read-only `Call.raw_staticcall` consumers with four mutable-borrow diagnostics
(`fe-current-unpatched-check.log`). The prior staticcall fix is still needed.
The payable wrapper verifier also still lacks the previously required terminal
call case. Local integration therefore includes the five already identified
fixes: read-only bounded staticcall, record-literal implicit borrows, unpadded
ABI payloads, composed decoder borrows and payable value returns.

The resulting local revision is `09385e70d`; all 31 regression tests in those
five fixture groups pass at both O1/O2 (`fe-current-regressions-o{1,2}.log`).
This is targeted compiler evidence, not protocol-wide revalidation.
`tests/COMPILER.md`, `fe-current-build.json` and
`fe-current-local-fixes.patch` retain build instructions, exact revisions,
binary/patch hashes and all local source changes plus regression fixtures.
The parity runner now also records the full compiler checkout revision.

The descriptor formatting suite passes 40,000 differential fuzz cases plus
boundaries at each O1/O2. O1 uses unmodified current master, O2 the locally
corrected build. Evidence: `descriptor-format-current-o{1,2}.{json,log}`.
This covers fees, price/tick decimal formatting, string escaping, hexadecimal
formatting, decimal integers and Base64 against the pinned Solidity sources.

The new complete Descriptor oracle initially exceeded solc 0.8.26's Yul stack
limit in the sixteen-argument test wrapper. The corrected oracle accepts the
original parameter struct directly; only the Fe harness takes a flat test ABI.
Tests therefore independently verify the Fe calldata construction as well as
all output bytes. The pinned Descriptor/SVG sources remain unmodified; the
reference runs via IR without optimization, as required for the prior SVG
oracle. `descriptor-oracle-stack-before.log` retains the initial failure.

The status inventory's old Multicall error-precedence gap and pending SVG
entries were stale. Their archived O1/O2 source hashes were rechecked against
the current files before updating them and the corresponding PositionManager
entries. Protocol ABI export still needs the documented explicit adapters.

The user subsequently requested O1-only development because O2 compilation is
too slow. All further validation uses O1. The already-running complete
Descriptor O2 Forge process was terminated at that request; its unfinished
run is not a passed validation. Previously completed O2 evidence is retained
as history, and O2 is no longer a completion gate.

The first 10,000-case complete Descriptor run exposed a test-domain mistake:
`testFuzz_render` assumed every uint64 token ID could render successfully.
Upstream SVG calls `BitMath.mostSignificantBit(tokenId)`, which rejects zero
with empty revert data. The property now allows that reference rejection and
an explicit zero-ID regression checks the reference's empty revert. Other
renderable IDs still must succeed. The initial failure is retained in
`descriptor-zero-id-before.log`; it did not demonstrate a production mismatch.

The corrected complete Descriptor suite now passes at O1 on unmodified current
master: four 10,000-case fuzz properties, the cached zero-ID counterexample
replay and the explicit boundary scenario (`descriptor-current-o1.{json,log}`).
It compares complete token-URI and SVG bytes, successful rendering across tick
ranges, native/zero currencies, hook addresses, symbol escaping and arbitrary
invalid parameter/revert behavior. The Fe source and final Solidity test hashes
were rechecked before archiving. No Descriptor production mismatch was found
in these runs. The source inventory now marks the Descriptor library validated;
this does not complete the still-missing public PositionDescriptor contract.

The integrated compiler also emits `view` for the read-only StaticProbe ABI
(`fe-current-staticcall.abi.json`). Run file-level repro builds with
`--standalone`: without it the CLI discovers the containing ingot, causing an
unintended whole-project build. That redundant probe build was stopped and the
isolated O1 build completed successfully.

At this checkpoint the full `fe check .` using
`/tmp/fe-uniswap-integrated/target/release/fe` is still live (PID 1713740,
PTY tool session 2715), with no diagnostic output after 14 minutes. Its log is
`/tmp/fe-uniswap-integrated-check.log`. This is explicitly **not** a passed
check. Revalidate that process/session before waiting or restarting it. The
completed component and compiler-regression results above stand independently;
whole-project current-compiler checking and protocol-wide parity remain open.

## Public PositionDescriptor and current-master refresh (2026-09-23)

The previously pending full check completed successfully (exit 0, no diagnostics)
on local compiler `09385e70d`, before the new PositionDescriptor source was added.
`fe-prior-current-check.json` supersedes its earlier running status. A fresh
remote check then found Fe master at `84434d4ba1d2a0d00ea981e52821f906f1167df0`.
An isolated checkout reapplies the five still-needed fixes without conflicts;
local compiler `91d3e8215` builds and passes all 31 O1 compiler regressions.
`fe-latest-build.json`, `fe-latest-local-fixes.patch` and the updated
`tests/COMPILER.md` record the new source and binary provenance.

The new `position_descriptor.fe` implements all six public entrypoints,
constructor configuration, first-zero native-label truncation, chain-aware
currency priorities, position and slot0 reads, native/ERC20 metadata and complete
NFT token URI construction. `currency_ratio_sort_order.fe` retains the six
reference priority constants. Constructor values continue to work through a
foreign delegatecall context, matching Solidity immutables.

The O1 differential suite passes 30,000 fuzz cases and five scenario tests
(`position-descriptor-o1.{json,log}`). It compares complete return/revert bytes,
all getters, chain-dependent priority ordering, wrapped-native priority override,
32-byte native labels, malformed/failed external responses, the high pool-ID
validity check, exact pool slot hashing, unknown/short/noncanonical calldata,
nonpayable guards, tick-range edges and token metadata fallbacks. The protocol
ABI export passes and is retained as `PositionDescriptor.protocol.abi.json`.

Two fixture mistakes were found and corrected. The initial reference source
selection included unrelated interfaces and concrete core contracts, causing
missing PathKey/Solmate dependencies; the runner now selects the actual import
closure. The initial chain-ID fuzz parameter exceeded Forge's uint64 host
limit; the fixture now uses uint64 while explicitly exercising chain 1 and
non-mainnet branches. Their original logs are retained as
`position-descriptor-reference-dependencies-before.log` and
`position-descriptor-chainid-fixture-before.log`. Neither was a Fe runtime bug.

For real lifecycle integration, `--descriptor-artifact` supplies the validated
Fe Descriptor and the original Solidity Descriptor to PositionManager workflows.
The reference recorder checks all 50 compiler-metadata source hashes against
pinned manifest hashes and records creation bytecode provenance. Forge's parsed
metadata drops documentation fields and normalizes remapping prefixes; the
recorder therefore uses solc's original `rawMetadata`. Workflow and retest
runners reject changed Fe sources or mismatching bytecode hashes. The new
optional workflow test reports an explicit skip if no Descriptor artifact was
provided; that skip must not be counted as metadata integration coverage.

The fresh current-compiler PoolManager O1 suite also passes all 16 tests,
including 60,000 fuzz cases and its protocol ABI export (`manager-current-o1`).
Full PositionManager/Descriptor lifecycle evidence is recorded separately once
that workflow run completes.

The Fe PositionDescriptor runtime is 45,136 bytes at O1. Its test fixture raises
the deployment size limit consistently with the user's size exception. The
reference helper's limited escaping is retained: it escapes quotes and selected
control characters, but leaves backslashes unchanged. For example, a symbol
containing a literal backslash followed by `x` can produce an invalid JSON escape
inside the decoded metadata. Differential tests include backslashes and preserve
upstream bytes; they do not claim that arbitrary upstream metadata is valid JSON.

The real Descriptor lifecycle run now passes all six PositionManager tests at
O1 on the latest compiler (`position-descriptor-workflows-o1.{json,log}`):
1,000 fuzz cases each for the existing lifecycle and credit/native properties,
plus 1,000 new metadata lifecycle cases and three fixed scenarios. Each new
case runs Solidity/Solidity, Fe/Solidity and Fe/Fe PositionManager/PoolManager
combinations with real Permit2. Mint, increase, decrease and burn are checked
against the original Solidity Descriptor, including unminted/burned rejection,
native/ERC20 positions and prices inside/outside the position range. The
fixture installs the exact deployed Fe Descriptor runtime (including its
constructor configuration) at the descriptor address held by the PositionManager.
No mocked metadata implementation participates in this new property. All tests
execute; none are skipped when the Descriptor artifact is supplied.

Reference artifact reuse now also forces a Solidity rebuild and requires exact
creation-bytecode reproduction from the pinned inputs, rather than relying on
source metadata alone. The successful rebuild record is retained in
`descriptor-reference-build.log` and `descriptor-reference.json`. Both public
PositionManager and PositionDescriptor protocol ABI exports pass.

A negative artifact check deliberately appended a byte to the Solidity creation
code in an isolated copy. The reference recorder rejected it after recompilation
(`descriptor-reference-bytecode-guard.log`). Final workflow source hashes and
both Descriptor creation-code hashes were rechecked after archiving.

The complete native Fe tests are currently running on a frozen source tree at
`/tmp/fe-native-current-o1`, using compiler `91d3e8215`, `-O 1 --jobs 2`.
PID 1760048/tool session 56037 was verified live after 8m51s; no result has yet
been emitted. The source hash map is `source-hashes.json` and the log is
`test.log` in that directory. Revalidate the process/session before waiting or
restarting; this is not a passed full-suite claim.

The next remaining reference sources have been fetched and hash-checked under
`/tmp/fe-periphery-remaining`: permissioned adapters/factory/router/position
manager, allowlist base/flags and UniswapV4DeployerCompetition. Their OpenZeppelin
Ownable2Step/ERC20/ERC165/Create2 dependency closure still needs to be added to
the manifest when those ports are implemented. The pinned Create2 helper
converts failed creation to `Create2FailedDeployment()` rather than bubbling
constructor revert bytes; that distinction must be preserved. Permissioned
PositionManager additionally requires forced unwind, bounded delivery attempts
and fallback ERC-6909 claims. These are functional requirements, not optional
size optimizations, and remain open together with final protocol-wide invariants.

### Latest-master O1: deployment competition and permission foundations

The upstream Fe master was rechecked and remains
`84434d4ba1d2a0d00ea981e52821f906f1167df0`; the local patched compiler is
`91d3e8215`. The parity runner now rejects optimization levels other than O1,
matching the user's instruction. Historical O2 evidence is retained.

`deployer_competition.fe` now implements all nine public methods of the pinned
UniswapV4DeployerCompetition. It preserves immutable constructor configuration,
checked exclusive-deadline addition, packed submitter storage, salt ownership,
strict vanity-score improvement, event topics/data, exact error precedence,
and actual CREATE2 deployment. The pinned OpenZeppelin Create2 source has been
added to the dependency manifest. CREATE2 receives zero value even when the
competition contract holds ETH; existing target balances are preserved. Failed
constructors return `Create2FailedDeployment()` rather than bubbling their revert
payload. Empty init code fails while nonempty init code returning empty runtime
succeeds. `Create2InsufficientBalance` is present in reference ABI metadata but
unreachable with a zero-value deployment.

The new suite passes 40,000 fuzz cases and three fixed boundary scenarios at O1
(`deployer-competition-o1.{json,log}`). Fe and Solidity run at the same address,
with state restored between branches so predicted child addresses are identical.
Comparisons cover complete return/revert bytes, storage (including packed high
bits), logs, child code/storage/balance and competition balance. The public ABI
export also passes. Creation collisions, invalid opcode, reverting constructor,
constructor overflow, deadline endpoints, exclusive/public deployment, prefunded
addresses, nonpayable and malformed ABI calls have explicit coverage.

Two initial fixed scenarios failed because the test harness forwarded almost
all its gas into CREATE2 failure cases. Snapshot restoration does not restore
gas, leaving insufficient gas for the second comparison or later fixture setup.
Each external branch now receives a 5,000,000 gas budget, retaining enough gas
for oracle comparison. The unchanged Fe implementation then passed all cases.
The original failure is preserved as `deployer-competition-gas-fixture-before.log`.
An earlier runner invocation also started before its new Solidity test file had
been written and failed on the missing file; it is not counted as validation.

`permission_flags.fe` supplies a narrow typed PermissionFlag with AND, OR and Eq
implementations, the four original constants, and bytes2 ABI conversion. Unknown
flag bits are retained. `allowlist_checker.fe` supplies the external message
interface and BaseAllowlistChecker's shared ERC165 behavior. As upstream's base
is abstract, concrete account/token permission policy remains with its consumer;
the parity harness uses an identical deterministic policy on both sides only
to exercise the interface. The pinned ERC165/IERC165 dependency sources are now
manifested. The suite passes 30,000 fuzz cases plus constants/interface and
malformed-ABI scenarios (`permission-foundations-o1.{json,log}`), including dirty
fixed-byte padding and noncanonical addresses.

The previously running full native Fe suite completed with exit 0: **1,948 passed,
0 failed**, using O1 and two jobs. `native-current-o1.{json,log}` records the
compiler and every frozen source hash. All frozen files still match the working
tree. The snapshot predates the deployment competition and permission foundations;
these new modules are covered by the independent differential builds above.

Remaining functional scope includes PermissionsAdapter, its factory, the
permissioned router and permissioned position manager (including forced unwind,
bounded delivery and fallback claims), followed by the final protocol-wide ABI,
adversarial workflow and invariant audit. Passing component suites does not
establish completion of those requirements.

### Permissioned adapters, factory and long generated ABI names

`permissions_adapter.fe`, its IO/state modules and
`permissions_adapter_factory.fe` now implement the pinned PermissionsAdapter
and PermissionsAdapterFactory, using native Fe CREATE for children. Token state
matches OpenZeppelin 5's ERC20 layout, including nested allowances and packed
owner/checker/flag writes. Transfers from PoolManager burn the wrapper units and
release underlying tokens; self-transfer to PoolManager is rejected. Other
senders cannot transfer wrapper balances. Finite allowances decrease without
an Approval event, unlimited allowances remain unchanged, and external transfer
failure rolls back balances, allowances and logs. Solmate's acceptance of empty
transfer returns, including no-code targets, is preserved.

Metadata has its own pinned adapter semantics: strict offset 32, nonempty bounded
string payloads, original name/symbol prefixes and fallback labels, decimals
fallback 18. This differs from SafeCurrencyMetadata and is not silently routed
through that helper. The ERC165 checker uses three short-circuited 30,000-gas
static calls and accepts any nonzero full-word answer, while the actual allowlist
result is decoded strictly as bytes2. Owner transfer is two-step; renounce always
reverts even for non-owners. Unchanged hook permissions suppress their event,
while wrapper and swapping updates still emit. Deposits preserve the dedicated
verification event. Factory verification uses the underlying token's balance,
rejects unknown/zero-token mappings and repeated verification, and does not
silently substitute native balances for a zero token address.

The initial adapter build needed ordinary API corrections (`staticcall` is not
a typed Call method, maximum integers and string generic lengths must use the
actual Fe APIs). The first test setup also lacked the two Solmate source files,
and a nested storage-hash expression had an extra closing parenthesis. These
were setup errors; the initial 100-case adapter run then passed without changing
its state transitions. All newly required OpenZeppelin and Solmate sources are
pinned by revision and SHA-256 in the manifest.

A genuine compiler failure blocked the factory's
`PermissionsAdapterAlreadyVerified` error. Error/event lowering used a single
fixed string for the whole name, exceeding Fe's **31-byte** inline-string limit.
It reported only a failed generated SELECTOR/TOPIC0 evaluation. The minimal
reproducer is `tests/repros/long_error_name.fe`; before/intermediate diagnostics
are preserved under `tests/results/fe-long-names-*.log`. The final local fix
splits declaration names on UTF-8 boundaries within the compiler's supported
width and preserves the exact signature bytes. Error tuples also use the same
bounded-arity grouping as event tuples.

An intermediate investigation used 32-byte chunks and speculated about a
String<32> mask underflow. String<32> is outside the supported language range;
that speculative core-library change was reverted. The final compiler diff
contains no string/num changes relative to the previous local build. Independent
cast-computed error selectors and event topics for name lengths 31, 32, 33, 64
and 65 now pass, as do all five earlier fix regression fixtures and many-field
event regressions: **47 passed, 0 failed**, O1. The final compiler is local
`31e5b965e`, SHA-256
`e1a92b53c0a5859da469e9d8e4c9830ec1d335c5357202ae7469471ca2c320cd`, still based
on upstream master `84434d4ba1d2a0d00ea981e52821f906f1167df0`.
`fe-permissioned-build.json` and `fe-permissioned-local-fixes.patch` preserve
provenance and a reproducible cumulative patch; older evidence remains intact.

Factory O1 validation passes **40,000 fuzz cases plus boundaries**, covering all
five methods and the public ABI (`permissions-factory-o1.{json,log}`). The
comparison restores both creator nonce and state, yielding identical factory
and child addresses in Fe/Solidity branches. It compares exact errors, events,
registry entries, constructor storage and child getters. Actual newly created
Fe adapters additionally execute deposit, wrap and payout operations inside the
comparison branches; the factory does not merely store mock child addresses.

The final-compiler adapter suite passes **70,000 fuzz cases and four fixed
boundary scenarios**, all 27 public functions and its protocol ABI export
(`permissions-adapter-o1.{json,log}`). That includes 10,000 sequences of 20
operations each, with PoolManager-only-holder and underlying-balance coverage
invariants checked after every step. Other properties cover ordinary and
unlimited allowances, owner/admin changes, malformed/raw metadata, exact
allowlist account/token arguments and permission bits. Fixed tests include
unpadded strings at storage-word boundaries, short/invalid balance return data,
checker rejection and noncanonical booleans, underlying transfer return modes,
nonpayable/unknown calls, ownership cancellation, checked wrapping underflow,
zero PoolManager and a token callback that reenters an owner method. Fe and
Solidity run at the same address from the same state snapshot; comparisons
include exact errors/returns, logs, packed slots, mappings, allowances and
underlying balances, including failed-call rollback.

A new full native suite runs on frozen `/tmp/fe-native-permissioned-o1`, with
source hashes and compiler provenance alongside `test.log`. Its Python wrapper
writes `run-result.json` only after termination. Tool session **87585**, Fe PID
**1819576**, was verified live after 3m23s. It uses compiler `31e5b965e`, O1,
`--jobs 2`, and includes both new adapter modules and the factory. This is not
yet a passed full-suite claim; revalidate the process before waiting or restarting.
The previous full-suite success remains separately recorded as
`native-current-o1` on compiler `91d3e8215`.

The remaining permissioned production contracts are PermissionedV4Router and
PermissionedPositionManager. Router integration needs permission-aware payment,
take and CONTRACT_BALANCE mapping in addition to per-pool hook checks. The
position manager additionally needs transfer restrictions, liquidity admission,
forced unwind, bounded asset delivery and fallback claims. These remain required
along with final protocol-wide invariant, adversarial workflow and ABI review.

### Permissioned router implementation and validation

`permissioned_router.fe` implements all pinned PermissionedV4Router overrides:
both pool currencies' hook allowlists, swap enablement and sender permissions,
standard and permissioned funding, guarded take, and underlying-token
CONTRACT_BALANCE mapping. The two abstract funding hooks remain a generic
`PermissionedFunding` policy; Permit2 is the supplied concrete policy.
`permissioned_v4_router.fe` provides the same transient caller-lock/execute
wrapper used for the original abstract V4Router, with the additional factory
configuration getter. The pinned source is abstract and does not itself specify
an execute entrypoint or Permit2 policy; the Solidity workflow wrapper supplies
the identical policy/entrypoints for comparison.

Shared `TokenPayer` now exposes default `take` and `map_settle` hooks. The ordinary
router retains its former implementation through these defaults; its new O1
regression passes 50,000 fuzz cases plus four scenarios (`router-current-o1`),
and ordinary real-pool workflows pass 4,000 fuzz cases plus three scenarios
(`router-workflows-current-o1`). A fresh PoolManager O1 artifact on compiler
`31e5b965e` passes 60,000 fuzz cases and all 16 tests, including its public ABI
(`manager-permissioned-current-o1`).

The isolated permissioned-router suite passes 70,000 fuzz cases plus three fixed
scenarios (`permissioned-router-o1`). It compares exact success/error bytes,
external call traces, token balances, events, and rollback from the same target
address. It covers both currency checks, single/multihop validation, sender and
permission arguments, short/dirty/trailing registry and bool return data, a zero
factory, malformed inputs and supported action sequencing. Authorization before
a zero-amount TAKE is deliberately preserved; zero-amount SETTLE instead returns
before reaching `_pay`. Factory lookup still happens when mapping a literal
settle amount. These ordering distinctions must not be optimized away.

Setup corrections: the first isolated build omitted modules reexported by
`lib.fe`, and an unqualified `take` inside the trait default resolved to the
trait method instead of the free function. The module closure and qualified call
were corrected. Two later setup attempts found missing V4Router/BipsLibrary
files in a partial reference directory. The full set of 69 manifested periphery
sources is now locally available and hash-verified. These failures are archived
as `permissioned-router-setup-*.log`; they are not successful test evidence.

The first large real-pool workflow run found a test-oracle expectation bug:
`testFuzz_rollback(1e18,127,false,false)` normalized its amount to 1 and selected a
blocked recipient. At the seeded price/fee the swap produced zero output, so
DeltaResolver's zero TAKE shortcut made no underlying transfer and the original
Solidity workflow succeeded. The test incorrectly required every blocked-recipient
case to fail. The revised expectation allows successful no-payout cases while
asserting that the denied recipient receives no tokens; dedicated native/ERC20
zero-output cases were added. Fe source was unchanged. The failure is preserved
as `permissioned-router-zero-output-fixture-before.log`.

The full native suite started in the previous checkpoint has completed with
exit 0: **1,948 passed, 0 failed** on compiler `31e5b965e`, O1. Evidence is
`native-permissioned-o1.{json,log}`. Its frozen source tree contains the adapters
and factory but predates changes to `payments.fe`/`router.fe` and the three new
permissioned-router modules. Those exact differences are listed in the result
metadata; the subsequent router component/workflow suites cover the new code.

The corrected real-pool PermissionedV4Router suite now passes all nine tests:
**40,000 fuzz cases plus the saved failure replay and five fixed scenarios**
(`permissioned-router-workflows-o1.{json,log}`). Each workflow compares four
systems: Solidity-only; Fe router with Solidity dependencies; Fe router and
Fe adapter factory with Solidity PoolManager; and the full Fe router/factory/
PoolManager combination. All use the original hash-verified Permit2 bytecode,
real factory-created adapters and a hook that checks the authenticated sender's
permissions. Single- and multihop exact-input/output routes, native/ERC20 and
router-held funding, CONTRACT_BALANCE plus refunds, full/portion takes, revoked
hooks/permissions, disabled swapping, recipient restrictions, zero output, real
Permit2 payment reentrancy, callback authorization and malformed batches pass.
Comparisons include pool storage, exact logs and errors, underlying/wrapper
balances, Permit2 allowance state, native balances and hook execution. Independent
assertions require cleared currency deltas/locks, token backing and PoolManager
as sole wrapper holder. The concrete router protocol ABI (including the explicit
receive adapter) also passes.

Workflow artifact reuse now validates the current compiler, every frozen factory
source and factory creation-bytecode hash in addition to PoolManager and Permit2;
the retest tool repeats these nested checks. Final archived sources and all four
creation-code hashes were rechecked. Deployment size limits remain the user's
sole relaxed deployment constraint.

PermissionedPositionManager is the remaining unimplemented periphery production
contract. Its forced unwind, subscriber reattachment cleanup, capped delivery,
ERC-6909 fallback/withdrawal, nontransferable NFTs and liquidity admission remain
required. The final protocol-wide source/interface inventory, adversarial tests
and invariant audit remain open as well; this checkpoint is not full-port
completion.

### PermissionedPositionManager implementation and newer Fe master (2026-09-24)

The remaining production contract now has an initial Fe implementation in
`permissioned_position_manager.fe`, `permissioned_position_policy.fe`, and
`permissioned_position_unwind.fe`. It shares the original PositionManager action
engine through a `PositionPolicy` trait with ordinary-token defaults. Mint and
increase checks retain the reference's ordering; decrease/burn remain open after
permission revocation. Factory reads deliberately do not use the router's
zero-address shortcut. Funding and sweeps use the underlying token, while the
special ERC-6909 actions preserve zero-amount calls and raw recipient semantics.
The concrete receiver retains the base EIP712 name despite different display
metadata and disables all NFT transfers with the reference's different lock
precedence for safe transfers.

Forced exits first burn into claims, include existing stray claims, then attempt
LP/admin delivery in independent gas-bounded unlocks before transferring claims.
An unsubscribe callback that reattaches is detached without a second callback;
the forced approval intentionally emits no Approval event. Dynamic `bytes[]`
batches use a local canonical ABI-tail builder because std's mutable array builder
currently supports static elements only. Fe type checking passed; these new
paths are not yet claimed to have complete differential/invariant coverage.

The shared-engine regression on compiler `31e5b965e` passes **20,000 O1 fuzz
cases plus three fixed scenarios**, and its public ABI audit passes
(`position-policy-regression-o1.{json,log}`). The optional real Descriptor case
was skipped; the older metadata evidence is retained without relabeling it as a
new run. Initial permissioned workflows exercise real pinned Permit2, actual
factory-created adapters, three Fe/Solidity combinations, native/ERC20 liquidity,
revocation, real-asset/claim forced exits, withdrawal, EIP712, transfer guards and
malicious subscriber reattachment. Their build/run is still pending at this
checkpoint. Setup found a Solidity Yul stack limit in the test digest; splitting
the digest into position/assets/claims hashes fixed it without altering the
reference or Fe implementation. A draft domain expectation included a version;
source review corrected it to the pinned versionless EIP712 domain before runs.

A fresh upstream check found master `e2fa7e53c8bb5710c79afbf6c8450a194640dbd8`
(native process arguments and CPU timing, PR #1566). It merged cleanly with the
existing local fixes in the separate checkout
`/tmp/fe-uniswap-permissioned-position`, producing local revision `702686c98`.
The release compiler SHA-256 is
`f3aaead7171e522c76b07fba14d25b70997fe3251a952686b0ad9c918aebac44`.
All **47 targeted O1 compiler regressions pass**. Reproducible source patch,
compiler provenance and regression logs are archived under `fe-position-current-*`;
`tests/COMPILER.md` now points at this upstream. PoolManager and the new
PermissionedPositionManager O1 workflow builds are running on this compiler.
Historical evidence remains bound to its actual compiler and source hashes.

The new-master PoolManager suite has now completed: **16 tests pass**, including
**60,000 fuzz cases**, with a passing protocol ABI audit
(`manager-position-current-o1.{json,log}`). The initial permissioned NFT fixture
also passes 64 fuzz cases plus its two fixed scenarios using the original
Solidity PositionManager in both NFT branches (and the new Fe PoolManager where
selected). This smoke run only validates fixture assumptions; it is deliberately
not recorded as Fe PermissionedPositionManager parity evidence.

The first Fe PermissionedPositionManager workflow run found a porting bug in
constructor metadata: `bytes_from_words_prefix<36, 2>` truncated the final `T` of
`Uniswap v4 Permissioned Positions NFT`. The actual UTF-8 length is **37 bytes**.
The targeted trace confirms the returned `... Positions NF`; the original
Solidity branch passes. This is an implementation error, not a compiler bug.
The prefix length is corrected to 37; the failed run, provenance and trace are
preserved as `permissioned-position-name-before.{json,log}` and
`permissioned-position-name-trace.log`. The corrected code requires a fresh
build and is not represented as validated by the failed artifact.

The new-master PermissionsAdapterFactory regression also passes **40,000 fuzz
cases and one fixed scenario**, with ABI audit
(`permissions-factory-position-current-o1.{json,log}`). The corrected NFT suite
now requires a hash-verified factory artifact and uses Fe factory/children in its
all-Fe branch, in addition to the Solidity-only and Fe-NFT/Solidity-dependency
branches. Its initial coverage has grown to three fuzz properties and four fixed
tests: unverified/ordinary/noncontract currency admission, revoked hooks/owners,
increase/from-deltas authorization ordering, repeated subscriber attachment,
bounded malicious native delivery (gas exhaustion or a deliberately stranded
delta), and later withdrawal of the fallback claim. More inherited-ABI,
malformed-response, stray-claim and stateful coverage remains required.

The inherited ABI preflight found another porting mismatch: Fe inferred `view`
for permissioned `transferFrom`, while the pinned reference retains its inherited
`nonpayable` declaration (the override only checks the manager lock and reverts).
Both safe-transfer overloads are correctly pure. The Fe receiver now explicitly
retains its mutable-storage effect contract, matching the reference ABI without
introducing any storage operation. The exporter was not relaxed; a preflight
changing only this metadata entry confirms that all other callable/event layouts
match. Runtime tests and export must still pass on a fresh artifact containing
this receiver declaration.

### Permissioned NFT workflow expansion and evidence gates (2026-09-24)

The name-corrected NFT build completed **40,000 fuzz cases and seven fixed tests**
with no runtime failures. The fuzz suite includes 10,000 sequences of 16 actions
per implementation: permission/hook changes, liquidity changes and contract-held
underlying settlement into claims. Every step checks NFT ownership, liquidity
accounting, cleared locks/deltas, adapter backing and PoolManager as sole wrapper
holder. Forced exits cover existing stray claims, native/ERC20 delivery, admin
and claim fallbacks, subscriber reattachment, gas exhaustion and recipient-induced
unsettled deltas. Error matrices exhaust all selected response shapes and
admission failures rather than repeatedly fuzzing small finite sets. Three
systems are compared: Solidity-only; Fe NFT manager with Solidity dependencies;
and Fe NFT manager/factory/PoolManager, all using original Permit2 bytecode.

This intermediate build still failed the mandatory ABI audit on `transferFrom`.
Its evidence is explicitly archived as **runtime_passed_abi_failed** in
`permissioned-position-runtime-before-abi.{json,log}`. The frozen artifact's
incorrect top-level passed status was corrected while preserving the original
metadata file. The ABI-corrected build is separate and currently running. Further
fixture coverage adds generic inherited callbacks, receive/unknown-selector and
lazy Multicall precedence, ERC721 permits/replay/nonces, real Permit2 single/batch
forwarding, nonpayable guards, zero-factory failure and separated owner/funder
permissions (including a disallowed owner of one-sided native liquidity).
These additions pass the reference smoke check; their final Fe run is pending.

The workflow exposed a **test-runner evidence bug**: `validation.json` was marked
passed immediately after Forge, before the required protocol ABI export. An ABI
failure therefore left a reusable-looking artifact. `protocol_abi_gate.py` now
keeps `runtime_result` and `protocol_abi_result` separate and exposes a top-level
passed result only after the required audit succeeds. Pending/failed audits are
not reusable. `retest_parity.py` runs the same audit after test edits instead of
silently resetting the status to passed. The gate's own hash is recorded. Two
regression tests use the real exporter to prove that ABI failure cannot be hidden
by runtime success and that failed runtime validation cannot be promoted. The
ABI compatibility rules themselves were not relaxed.

Latest-master ordinary PositionManager regression passes **20,000 fuzz cases plus
three fixed scenarios** (`position-policy-latest-o1.{json,log}`). The Descriptor
also passes **30,000 fuzz cases and five fixed scenarios**, including its ABI audit
(`position-descriptor-latest-o1.{json,log}`). Real Descriptor/Permit2 integration
has now been rerun on the same compiler: **3,000 fuzz cases**, including 1,000
complete metadata lifecycles, and three fixed scenarios, with **no skipped tests**
(`position-metadata-latest-o1.{json,log}`). The original Solidity Descriptor was
rebuilt and verified against 50 pinned input sources before reuse. A complete
native O1 run on a frozen current Fe source tree is also running at
`/tmp/fe-native-position-current-o1`; no success is claimed before it completes.

The ABI-corrected NFT artifact and the final role-separated fixture now pass
**all 14 tests: 40,000 fuzz cases plus ten fixed tests**, with the full protocol
ABI audit under the corrected result gate. Final archived source/test hashes and
NFT/PoolManager/factory/Permit2 bytecode hashes were independently rechecked.
Evidence: `permissioned-position-workflows-o1.{json,log}` and
`PermissionedPositionManager.protocol.abi{.audit}.json`. This completes the first
validated workflow implementation of the last pending production periphery
contract; it does not complete the final protocol-wide audit. The immutable-base,
IImmutableState and IMsgSender inventory entries were reconciled with the now
validated concrete consumers. WETH wrapping/receive regression also passes
20,000 current-master O1 cases plus zero/no-code boundaries
(`native-wrapper-latest-o1`). The full frozen native run remains in progress.

Final NFT reference audit rehashed all **115 copied Solidity reference files**
against their repository entries in `reference_manifest.json`, in addition to the
already checked Fe/compiler/test/bytecode provenance. All match; the file-level
record is `permissioned-position-reference-audit.json` and is bound to the final
validation JSON hash. The full native run was last confirmed live after more
than 20 minutes of compilation; its absence of a completed result is not treated
as failure and it has not been restarted.


Current-master native O1 validation completed: **1,948 passed, zero failed**.
All 127 current Fe source hashes match the frozen snapshot; evidence is
`native-position-current-o1.{json,log}`. Earlier running-status entries above
are historical observations.

Latest compiler revalidation passes Router **50,000 fuzz cases + five fixed
tests**, Quoter **50,000 + nine**, StateView **60,000 + three**, ReservesLens
**30,000 + five**, and Quoter/current-PoolManager integration **20,000 + one**.
All required ABI audits pass. Before archiving, all included current Fe sources,
Solidity fixtures and decoded creation bytecode were hash-checked. Evidence:
`router-interface-latest-o1`, `quoter-interface-latest-o1`, `state-view-latest-o1`,
`reserves-lens-latest-o1`, `quoter-workflows-latest-o1` under `tests/results`.

`tests/audit_periphery_interfaces.py` verifies 30 action/sentinel constants,
eight IV4Router errors and their runtime error matrix, four swap schemas and
WETH9 consumer selectors. WETH9 is an external dependency interface in the
reference, not a missing periphery implementation. The four remaining interface
and constant entries now have specific evidence in `periphery-interface-audit.json`.
This does not substitute for the final protocol-wide behavioral/invariant audit.


The protocol review identified a remaining **standard-router integration gap**:
its real-pool suite still used an instrumented Permit2 transport mock. The suite
now deploys the original hash-verified pinned Permit2 (solc 0.8.17) and exercises
token-driven reentrancy through its actual transfer path. All **40,000 O1 fuzz
cases plus four fixed tests pass** on compiler `702686c98` across three
router/manager combinations. Finite allowances are checked for exact debit,
untouched metadata and rollback. Explicit insufficient/expired allowance cases
verify complete error payloads and pool/lock rollback. No production Fe change
was needed. Evidence: `router-real-permit2-latest-o1.{json,log}`.

The concrete standard-router wrapper now requires a protocol ABI audit before
its artifact can be accepted; it passes, including the existing explicit native
receive adapter. All 15 exporter/gate tests pass. Latest-master permissioned
router revalidation also passes **40,000 fuzz cases plus five fixed tests**,
real Permit2/factory/PoolManager dependencies and its protocol ABI audit
(`permissioned-router-workflows-latest-o1`). The official upstream master was
rechecked and remains `e2fa7e53c8bb5710c79afbf6c8450a194640dbd8`.

Documentation review found historical incomplete-status statements for already
validated permits, multicall, wrapping and router payment integration. Their
periphery inventory entries now link concrete current workflow evidence. The
core reference manifest also contains historical pending statements (including
PoolManager itself); its source hashes remain useful, but these status strings
must not be used as the final completion inventory. Core-wide reconciliation
and the final behavioral/invariant audit remain open.


The core completion review now has an explicit source inventory in
`core_status.json`: **46 production reference files**, mapped to Fe modules,
behavior and specific evidence, plus the **38 upstream test actor/harness files**.
It records idiomatic adaptations (typed errors instead of scratch-memory
revert overloads, shared delegate-call guards, external token/hook interfaces)
without claiming that file coverage establishes complete parity. Every listed
Fe module has at least one referenced evidence record matching its current hash.
Historical manifest status strings are retained as history, not completion gates.

The Foundation suite now passes **60,000 O1 fuzz cases plus boundary tests** on
compiler `702686c98`; its isolated nine-module closure avoids unrelated analysis.
Evidence: `foundation-latest-o1.{json,log}`. This supplements its historical O2
record without running any new O2 validation.

The Manager suite gained a randomized 20-step, two-pool accounting test. It
compares complete position/tick words and pool headers after each action, plus
independent models for position liquidity, tick gross/net liquidity, active
liquidity and both bitmap words. Failed excessive removals must roll back.
The first version passed 10,000 sequences (200,000 action steps), alongside the
existing 60,000 cases and ten fixed tests. A final extension additionally removes
all liquidity on selected steps to check tick/bitmap deletion; its result is
recorded below once complete.

A second **retest evidence bug** was found during this review: while a changed
fixture was running, `retest_parity.py` left the previous `passed` metadata in
place. An interrupted or still-running retest could therefore look reusable.
The tool now preserves the old evidence, withdraws success and records pending
runtime/ABI states **before** replacing the fixture. Failed runtime validation
remains failed; interruption leaves a non-reusable pending artifact. A subprocess
regression test observes metadata at the Forge boundary and verifies failure
and backup preservation. All **16 infrastructure tests pass**. The one already
running pre-fix retest also had its stale status withdrawn after confirming
that its process was still live.


The final Manager sequence extension passes: **17 tests, 70,000 fuzz cases and
ten fixed tests**, including **10,000 sequences / 200,000 independently checked
action steps** with full liquidity removal and tick/bitmap cleanup. Its protocol
ABI audit passes. Current Fe sources, the final Solidity fixture and creation
bytecode were hash-verified before archiving `manager-stateful-latest-o1.{json,log}`.
All 127 Fe files still match the previously completed 1,948-test native O1 run.
No production Fe correction was required by these additional invariants.
The source inventories and these tests strengthen the final audit; they do not
alone establish complete protocol-wide behavioral parity.


Malformed Permit2-forwarder mutation testing exposed two new offset-overflow
parity failures. An inner batch-details offset of uint256.max and a signature
offset of uint256.max - 31 produce Fe arithmetic Panic(0x11), while the pinned
Solidity reference returns an empty revert. Every truncated prefix passes; the
failure is specifically in overflowing offsets. Original failed fixture hashes
were preserved separately before tracing. Evidence: `forwarder-malformed-before`,
`forwarder-bounded-before`, and the offset/signature trace logs in `tests/results`.

The port's Batch decoder now uses bounded tuple decoding. This fixes the first
case, but the second additionally requires a Fe core ABI correction: checked
dynamic-byte head validation was doing `pos + 32` before rejecting overflow.
Unbounded nested dynamic-field additions also needed the existing checked-tail
helper. An independent five-case compiler fixture passes three controls and
fails the two reproductions on compiler 702686c98 (`fe-abi-offsets-before.log`).
The isolated compiler fix is being validated; no final success is claimed yet.
Because `src/permit2_forwarder.fe` changed, the earlier 127-source native snapshot
and NFT artifacts are historical until their affected paths are revalidated.

The new PositionManager initialize/mint Multicall workflow independently passed
10,000 cases across Solidity/Solidity, Fe/Solidity and Fe/Fe systems before the
forwarder correction. It checks duplicate-initialize sentinel returns, native
refunds, atomic creation/mint and pool/value rollback on mint failure. Its full
suite passes 30,000 cases and three fixed scenarios (real Descriptor test omitted
in that artifact); integration will be rerun with the corrected forwarder/compiler.


## Completion: upstream test suites against Fe (2026-09-24)

### Compiler refresh and a new CTFE defect

Fe master advanced to `f00132a97`. On top of it, the integrated compiler
merges the fixes the port needs: PRs #1586, #1587, #1575, #1567 and #1591,
plus local branches `fix/uniswap-bounded-staticcall` and
`fix/uniswap-long-error-event-names`. PR #1567 had one import-list conflict
with master, which was resolved by keeping both imports. See
`tests/COMPILER.md` and `results/fe-integrated-build.json`.

With these merges, `fe check` of the port **panicked** in the new CTFE code:
"optional CTFE fold invariant failed: constant integer exceeds its declared
type". The trigger is `allowed != !(0 as u256)` in `claims.fe`. A minimal
repro (`x == !(0 as T)` for any unsigned T) panics on unmodified master.
Cause: `int_ty_shape` returns no width for `view` wrappers of integers. The
bitwise-not fold therefore fell back to `-v - 1` without normalization, and
the verified-constant check, which does unwrap views, rejected the value.
Fix branch `fix/ctfe-view-int-shape` (`83d80ea7a`) unwraps views in
`int_ty_shape` and adds a regression fixture and newsfragment. The fe-hir
(429), CLI (all `fe_test` fixtures) and formatter round-trip suites pass. No
port source change was needed. With the fix, `fe check` passes on the whole
ingot and the complete native run passes **1,948/1,948** tests
(`native-integrated-o1`).

### Upstream Foundry suites

The earlier evidence consisted of the port's own differential fixtures.
`tests/run_upstream_suites.py` now runs **the upstream v4-core and
v4-periphery test suites themselves** against the Fe contracts. The patches
in `tests/upstream/` touch only deployment helpers: `Deployers`, `Deploy`, the
permissioned deployers, the ReservesLens test setups, the deployer-competition
setup and the router test helpers. They select `$FE_ARTIFACTS/<Contract>.bin`
when present, and `foundry.toml` lifts the code-size limit. A probe test proves
that every listed contract resolves to Fe bytecode, and a manual code-size
probe confirmed the Fe PoolManager and router are actually deployed. Each
suite runs once on Solidity and once on Fe. The run passes only if every test
has the same status.

Final result (fresh pinned clones, 1,000 fuzz runs, O1, compiler `9e2213a79`):
v4-core **597 passed, 1 failed** on both Solidity and Fe, and v4-periphery
**942 passed** on both. There are no status mismatches and no missing or extra
tests. The single failure, `TickMath.t.sol::test_fuzz_getTickAtSqrtPrice_getSqrtPriceAtTick_relation`,
is a pure Solidity library test. Upstream fails it identically at this
revision (counterexample -887273 < MIN_TICK with seed 0x4444). Only
`ReservesLens.fork.t.sol` (live RPC) is excluded. Evidence:
`upstream-conformance-o1.{json,log}` and `upstream-conformance-o1-tests.json`.

The abstract V4Router and PermissionedV4Router are only reachable upstream
through concrete Solidity test mocks. `src/upstream_test_mocks.fe` ports
`MockV4Router` (direct ERC20/solmate payments, ETH sweep) and
`MockPermissionedRouter` (Universal-Router-style `execute`, Permit2 permit
dispatch, `_toBytes`, allow-revert flags) onto the Fe router core. All 84
router tests and all 386 permissioned-pool tests therefore execute Fe router
code. One mock bug was found and fixed before the final run: Solidity
evaluates `_toBytes` (SliceOutOfBounds) before the calldata struct
validation, and the first port had them in the opposite order.

### ReservesLens gas budgets

The upstream suite found two failures the differential fixtures had not covered:
ReservesLens gas budgets. Every behavioral test already passed, but a
512-read page cost 3.18M gas (budget 3.0M) and a single-shot scan of an empty
tick-spacing-1 pool cost 50.7M (budget 40M). Solidity costs 2.03M / 31.7M.
The Fe PoolManager was not the cause: the Solidity lens with the Fe manager
measured 2.02M. The cause was per-word memory allocation in the Fe lens:
two `keccak_packed` buffers, a fresh call buffer and the struct round-trip
through `process_word` for empty words. Fe's bump allocator never reclaims
memory, so expansion cost grew quadratically. `reserves_scan.fe` now hoists the
pool slot, reuses one hash buffer and one call buffer per scan, and skips
`process_word` for empty bitmap words, which is a no-op there. Fe lens with
Solidity manager: **1.69M / 22.6M**, below Solidity. All 59 upstream lens
tests pass, and the port's own `reserves_lens` differential suite passes 8
tests with 10,000 runs each plus the ABI audit (`reserves-lens-integrated-o1`).

### Pending items from the previous checkpoint

- Permit2 forwarder malformed offsets: with PR #1591 in the compiler, the
  `permit2_forwarder` suite passes, including `testFuzz_mutatedCalldata`
  (10,000 runs each; `permit2-forwarder-integrated-o1`).
- PositionManager initialize+mint multicall with the corrected forwarder: the
  upstream `PositionManager.multicall.t.sol` and the rest of the PositionManager
  suites pass against the Fe PositionManager, Fe Descriptor and Fe
  PoolManager.

The remaining deviation is contract size, which was explicitly out of scope:
five runtimes exceed EIP-170 (see README).

### Correction: integer bounds are in the standard library

The early adaptation note claiming Fe lacks `u256::MAX` was wrong.
`core::num::Bounded` (commit `41e0c3aec`, 2026-05-25, already present at the
port's starting revision `aad737010`) provides `min()`/`max()` as `const fn`
for every integer type. The port's own `MAX_U256` constant and every
`!(0 as u256)` were replaced with `u256::max()` (full_math, tick_math,
tick_bitmap, claims, extload, permissions_adapter_state, quoter,
reserves_scan, math_reverts). All 28 production creation/runtime artifacts
built from the changed sources are byte-identical to those used by
`upstream-conformance-o1`, so that evidence applies unchanged. The native run
on the changed sources passes 1,948/1,948 (`native-integrated-o1`, updated).
Parity harness bytecode was not rebuilt for this change.
