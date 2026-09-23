# Compiler reproductions

## Unchecked signed negation leaves an unsupported Sonatina instruction

Observed with local binary `fe 26.3.0 (d5af64cec)`, SHA256
`e6e48366b284c92c0736e0fe56d41879692e7af6c920df21615b5e58e59e0a61`.
Reproduced again after `cargo build --release -p fe` with compiler
`fe 26.3.0 (aad737010)`. See the main REPORT.md for parity validation.

```sh
target/release/fe build examples/uniswap_v4/tests/repros/unchecked_neg.fe \
  --standalone --out-dir /tmp/fe-v4-neg-repro
```

Expected: compilable wrapping signed negation, including `-MIN_INT256 == MIN_INT256`.
Reproduces at `-O0`, `-O1`, `-O2`, and `-Os`. Observed at default `-O1`:

```text
EVM machine IR contains unsupported instruction at inst16: neg
```

The Fe Sonatina lowerer emits `arith::Neg` in `lower_unary` for `UnOp::Minus`.
A source-level workaround is `(0 as i256) - value` inside the unchecked function.
It compiles; SwapMath uses it, with differential tests covering both the minimum
signed integer and random exact-input swaps. This does not fix the compiler.

On 2026-09-22 the GitHub open-PR lists for `argotorg/fe` and `fe-lang/sonatina`
were checked; no matching fix was identified from titles. No PR was merged and
no issue was published. The checked-in reproduction retains the failing syntax.


## Dynamic StorageMap layout root is lost through StorPtr.read

Reproduced with `fe 26.3.0 (aad737010)`:

```sh
target/release/fe build examples/uniswap_v4/tests/repros/dynamic_bitmap_layout.fe \
  --standalone --out-dir /tmp/fe-v4-dynamic-bitmap-repro
```

Reading `StorPtr<StorageMap<i32,u256>>` at a runtime slot and forwarding the result
as a StorageMap effect fails in MIR layout inference:

```text
error[17-0001]: cannot determine inferred layout
no runtime layout root is available for component 0
```

This prevents the straightforward composition of a pool's runtime storage root
with its TickBitmap mapping. Forwarding the pointer itself instead of `.read()`
also fails to satisfy the mutable StorageMap effect in this usage.

The port uses `tick_bitmap::Bitmap { slot }`, an explicit storage view that hashes
`abi.encode(signedKey, slot)` and delegates bit arithmetic to the same shared
functions as the static StorageMap API. It preserves arbitrary pool roots and
the exact Solidity mapping layout. The pool suite exercises runtime roots,
multiple pools and direct storage equality; the state suite retains coverage
of the static API. This is a workaround, not a compiler fix.

Inspected open PRs on 2026-09-22:

- https://github.com/argotorg/fe/pull/1564 at
  `d883c2102488dbf65540235f1e93d42cc81c84e0`: repeated temporary trait-effect
  provider identity; depends on the native-execution base.
- https://github.com/argotorg/fe/pull/1494 at
  `168787afaeae56757ac147998bedbaa60871ae52`: multi-word map entries and packed
  struct pointers.

Their descriptions do not identify a fix for this inferred runtime-root error.
Neither was merged, and neither was claimed to have been tested as a fix.

## ABI export panics for encode_msg_calldata

Reproduced with `fe 26.3.0 (aad737010)`:

```sh
RUST_BACKTRACE=1 target/release/fe build \
  examples/uniswap_v4/tests/repros/encode_msg_abi.fe --standalone \
  --emit abi --out-dir /tmp/fe-v4-encode-abi-repro
```

A single `encode_msg_calldata` invocation triggers an out-of-bounds panic at
`crates/hir/src/analysis/ty/binder.rs:136`, called from
`fe::abi::instantiate_callable_typed_body` during event collection. The generic
argument slice has length 1, but the instantiation accesses index 1. The default
build originally produced Currency bytecode and then panicked while exporting
ABI; its bytecode passed the initial Currency differential suite.

The port avoids this call by explicitly writing the selector and argument words
for `transfer(address,uint256)` and `balanceOf(address)`. The resulting ABI
export succeeds. This is a source workaround, not a compiler fix. Stacktrace:
`../results/encode-msg-abi-panic.log`.

All 35 open Fe PR titles/descriptions returned on 2026-09-22 were inspected;
no matching fix was identified from those descriptions. No PR was tested as a
fix or merged. Query and revision records: `../results/currency-open-pr-inspection.json`.
In particular, PR #1540 concerns strict bool-return lengths, not this panic;
v4's hand-written transfer routine deliberately accepts trailing bytes.

## ABI export omits custom errors

```sh
target/release/fe build examples/uniswap_v4/tests/repros/custom_error_abi.fe \
  --standalone --emit abi --out-dir /tmp/fe-v4-error-abi-probe
```

Build succeeds, but `ErrorAbiProbe.abi.json` contains only the `fail()` function;
`Failure(uint256)` is absent although the function unconditionally uses it.
The Currency harness similarly omits `WrappedError` (as does the Solidity
harness, which constructs its errors in assembly). Runtime revert bytes are
validated separately; generated JSON must not be treated as complete error ABI.

The Currency balance harness also exports `nonpayable` instead of `view` because
`derive_state_mutability` classifies any mutable effect (including RawMem/Call)
as nonpayable. Tests separately verify successful STATICCALL execution. This
metadata limitation remains open for final protocol ABI delivery.

## Composed struct ABI decoder fails semantic borrow checking

```sh
target/release/fe build examples/uniswap_v4/tests/repros/composed_decode_borrow.fe \
  --standalone --out-dir /tmp/fe-v4-composed-decode
```

Fe `aad737010` rejects decoding a two-Address `Copy` struct by calling
`Address::decode_payload(mut d)` twice and returning the two values. Diagnostic:
`decode_runtime_args`: semantic borrow checking failed, `borrow conflict in fn
decode_payload`. Delegating to the corresponding tuple decoder also failed for
the PoolKey port. The standalone reproduction preserves the original composition.

Workaround: read the ABI words from the decoder and explicitly validate address,
uint24/uint160, int24 sign extension and bool canonicality before constructing
the output. No persistent references to the decoder are kept. The type suite
compares valid, noncanonical, truncated and trailing-data inputs against Solidity.

PR #1564's changed files/tests were inspected at the previously recorded revision:
its added cases concern temporary trait-effect provider identity. No matching
composed decoder regression was found in those changes. It was not merged or
verified as a fix for this failure. Log: `../results/composed-decode-borrow.log`.

## Custom scalar wrappers are not transparent to ABI metadata

`crates/hir/src/analysis/ty/abi_ty.rs::std_sol_compat_abi_type` recognizes only
standard-library wrappers. Other structs are emitted recursively as tuples;
a Currency struct containing Address would become `(address)` rather than
`address`, even with hand-written word encoding. The port therefore uses Address
for Currency/IHooks in external PoolKey fields and Bytes32 for PoolId, exactly
matching Solidity's erased user-defined/interface types. The internal Currency
wrapper still supplies typed transfer and balance behavior.

## Dynamic array ABI overflow emits Panic instead of decode-error revert (fixed locally)

```sh
cargo build --release -p fe
target/release/fe test crates/fe/tests/fixtures/fe_test/abi_array_overflow_revert.fe -O 1
target/release/fe test crates/fe/tests/fixtures/fe_test/abi_array_overflow_revert.fe -O 2
```

The four tests fail with the original aad737010 binary and pass with the local
`ingots/core/src/abi.fe` bounds-check correction. They inspect actual returndata
length, not the capacity-limited raw-call output buffer. Before/after evidence
and the precise patch are retained in `../results/abi-array-overflow-*`.
The external storage parity suite independently compares malformed calldata with
unmodified Solidity. Full malformed Bytes/view decoding is outside this fix's
validated scope; see REPORT.md.

`long_error_name.fe` reproduces a generated `#[error]` selector failure for
`PermissionsAdapterAlreadyVerified(address)` on Fe master
`84434d4ba1d2a0d00ea981e52821f906f1167df0` (also on local `91d3e8215`). The
same defect affects event topics: lowering placed the whole declaration name
in a fixed string, exceeding Fe's 31-byte inline-string limit. The local fix
splits names into UTF-8-safe fragments within that limit and hashes their exact
concatenation. O1 regression cases check independent selectors/topics for names
of 31, 32, 33, 64 and 65 bytes. See `results/fe-permissioned-local-fixes.patch`
and `results/fe-permissioned-regressions-o1.log` for the complete fix and evidence.

## CTFE panics on bitwise-not with a view-typed result (fixed on a branch)

```sh
target/release/fe test tests/repros/ctfe_view_bitnot.fe
```

Fe master `f00132a97` panics: `optional CTFE fold invariant failed: constant
integer exceeds its declared type`. The port hits it in `claims.fe`
(`allowed != !(0 as u256)`). Fix branch `fix/ctfe-view-int-shape`
(`83d80ea7a`) passes; see `../COMPILER_FIX_BRANCHES.md`.
