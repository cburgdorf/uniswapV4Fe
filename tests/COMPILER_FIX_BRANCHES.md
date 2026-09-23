# Fe compiler fix branches

Repository: `/home/cburgdorf/Documents/hacking/fe/fe`. The branches `fix/uniswap-bounded-staticcall`, `fix/uniswap-long-error-event-names`, and `fix/uniswap-abi-offset-overflow` were pushed to `upstream` (`argotorg/fe`). The four duplicate branches remain local.

Each branch contains one focused commit directly on upstream master
`e2fa7e53c8bb5710c79afbf6c8450a194640dbd8`. They are independent branches, not a stack.
The original `uniswapv4_demo` checkout and its uncommitted changes were preserved.

| Branch | Commit | Fix |
| --- | --- | --- |
| `fix/uniswap-bounded-staticcall` | `3a34aa76bc34` | Allow bounded raw STATICCALL through a read-only Call effect; retain view ABI. |
| `fix/uniswap-record-literal-borrows` | `dd323ca04a65` | Lower implicit borrows of record literals without losing place information or panicking. |
| `fix/uniswap-unpadded-abi-payloads` | `107c823cb6bf` | Accept ABI bytes/string tails without unused trailing padding; preserve bounds and bounded copies. |
| `fix/uniswap-composed-decoder-borrows` | `40bc9b5b5e30` | Preserve ordinary mutable argument memory contracts in borrow summaries for composed decoders. |
| `fix/uniswap-payable-return-verifier` | `a5516a52a5a7` | Verify payable receive handlers that return values. |
| `fix/uniswap-long-error-event-names` | `04baed1a6b2e` | Hash long error/event signatures in supported 31-byte string chunks. |
| `fix/uniswap-abi-offset-overflow` | `01ae70d036f7` | Reject overflowing dynamic ABI offsets and byte-length heads with decode errors instead of arithmetic panics. |


Open-PR audit (2026-09-24): these are **not seven new fixes to submit**.
All 38 currently open PRs were screened using their descriptions and changed files;
relevant diffs were compared. The API snapshot and per-PR file inventory are in
[fe-open-pr-audit.json](results/fe-open-pr-audit.json).

| Local branch suffix | Existing PR | Result |
| --- | --- | --- |
| `record-literal-borrows` | [#1586](https://github.com/argotorg/fe/pull/1586) | Identical stable patch ID. Use existing PR. |
| `unpadded-abi-payloads` | [#1587](https://github.com/argotorg/fe/pull/1587) | Identical stable patch ID. Use existing PR. |
| `composed-decoder-borrows` | [#1575](https://github.com/argotorg/fe/pull/1575) | Identical stable patch ID. Use existing PR. |
| `payable-return-verifier` | [#1567](https://github.com/argotorg/fe/pull/1567) | Same bug; PR has stronger return-helper/type-specialization verification and negative tests. Local implementation is older. Use existing PR. |
| `long-error-event-names` | [#1589](https://github.com/argotorg/fe/pull/1589) | Partial overlap: nested tuples for error signatures. Splitting long names remains separate; adapt to its shared signature builder if it lands first. |
| `bounded-staticcall` | None found | Separate fix; #1427 modifies typed calls, not this bounded raw-call method. |
| `abi-offset-overflow` | None found | Separate fix; #1587 and #1589 do not fix these overflowing decoder additions. |

Every branch's single fix commit contains a nonempty newsfragment. Three missing
fragments were added by amending their fix commits; no extra news-only commits
were created. Duplicate branches are retained locally for traceability, not as
recommendations for additional PRs.

Each branch includes regression tests. The six earlier fixes were already exercised
together by the port compiler. Separate per-branch release builds and O1 fixture
tests are being recorded under `/tmp/fe-fix-branches/validation`; no full repository
CI result is claimed. The independent ABI-offset branch passes five O1 tests;
the same isolated fixture fails four cases on the prior compiler.

The offset compiler binary was built before a fixture-only amendment. Its compiler
sources are unchanged; the validation record identifies both revisions. The first
fixture used a composed decoder and exposed the separate borrow-checker bug on
plain master. The final fixture tests the four ABI helpers directly, without that
dependency.

Inspect or test a branch without switching the existing checkout:

```sh
git -C ../fe show --stat fix/uniswap-abi-offset-overflow
git -C ../fe worktree add /tmp/fe-offset-review fix/uniswap-abi-offset-overflow
cd /tmp/fe-offset-review
npm ci --prefix crates/tree-sitter-fe
export PATH="$PWD/crates/tree-sitter-fe/node_modules/.bin:$PATH"
cargo build --release -p fe
target/release/fe test crates/fe/tests/fixtures/fe_test/dynamic_offset_overflow.fe -O1
```

Use O1 for Fe tests. Compiler build instructions and required tree-sitter tooling
are described in [COMPILER.md](COMPILER.md). Port changes and parity-runner bugs
belong to this Uniswap repository and are not included in the compiler branches.

## New fix for the completed port (2026-09-24)

| Branch | Commit | Base | Fix |
| --- | --- | --- | --- |
| `fix/ctfe-view-int-shape` | `83d80ea7a8b7` | master `f00132a97429` | Keep integer width for view-typed values in constant evaluation. |

This is the only new compiler fix needed for the completed port; it is local
and not pushed. No open PR fixes it: the CTFE/`consts.rs` diffs of the open
PRs #1576, #1581, #1582, #1585 and #1589 were checked for `int_ty_shape` and
view handling; only #1582 touches those lines, by reordering an import list. The upstream
`abi-offset-overflow` branch is now PR [#1591](https://github.com/argotorg/fe/pull/1591).

Master `f00132a97` panics while checking the port, in `claims.fe`
(`allowed != !(0 as u256)`): "optional CTFE fold invariant failed: constant
integer exceeds its declared type". `int_ty_shape` returned no width for a
`view` of an integer, so CTFE's bitwise-not fell back to `-v - 1` without
normalizing. The verified-constant check, which already unwraps views,
then rejected the negative unsigned value. The fix unwraps views in
`int_ty_shape` (+2 lines).

The single commit contains the fix, the newsfragment
`newsfragments/+ctfe-view-int-shape.bugfix.md` and the regression fixture
`crates/fe/tests/fixtures/fe_test/ctfe_view_int_bitnot.fe` (u8/u16/u128/u256/i8/i256
and a masking case). Validation on the branch:

- The fixture panics on unmodified master and passes with the fix.
- `cargo test --release -p fe-hir`: 429 passed.
- `cargo test --release -p fe --test cli_output` (including every `fe_test`
  fixture) and `--test fmt_semantic_roundtrip`: all passed, 0 failed.

No full repository CI run is claimed.
