# Current local compiler

Use **O1 only** for ongoing compiler and protocol validation, per the user
preference of 2026-09-23. Existing O2 artifacts remain historical evidence.

The completed port (2026-09-24) is validated with Fe master
`f00132a97429f966804d70c40206ef40ebca6960` plus these fixes, merged in order
on the local branch `uniswap-integrated-2026-09-24` (`9e2213a79`):

| Fix | Source |
| --- | --- |
| Implicit borrows of record literals | PR [#1586](https://github.com/argotorg/fe/pull/1586) |
| Unpadded ABI dynamic payloads | PR [#1587](https://github.com/argotorg/fe/pull/1587) |
| Composed ABI decoder borrows | PR [#1575](https://github.com/argotorg/fe/pull/1575) |
| Payable value-returning handlers | PR [#1567](https://github.com/argotorg/fe/pull/1567) (one import-list conflict with master) |
| Overflowing dynamic ABI offsets | PR [#1591](https://github.com/argotorg/fe/pull/1591) |
| Bounded read-only raw STATICCALL | branch `fix/uniswap-bounded-staticcall` |
| Error/event names longer than 31 bytes | branch `fix/uniswap-long-error-event-names` |
| CTFE panic on integer operations with view-typed results (new) | branch `fix/ctfe-view-int-shape` |

The last fix is new: current master panics while checking the port
(`optional CTFE fold invariant failed: constant integer exceeds its declared
type`, triggered by `x != !(0 as u256)` in `claims.fe`). See
[COMPILER_FIX_BRANCHES.md](COMPILER_FIX_BRANCHES.md).

`results/fe-integrated-build.json` records every merged head, the binary hash
and the combined source patch `results/fe-integrated-2026-09-24.patch`.
Reproduce it in a fresh checkout:

```sh
git clone https://github.com/argotorg/fe.git /tmp/fe-uniswap
cd /tmp/fe-uniswap
git checkout f00132a97429f966804d70c40206ef40ebca6960
git apply /path/to/uniswap_v4_demo/tests/results/fe-integrated-2026-09-24.patch
npm ci --prefix crates/tree-sitter-fe
export PATH="$PWD/crates/tree-sitter-fe/node_modules/.bin:$PATH"
cargo build --release -p fe
```

Pass `--fe-repo /tmp/fe-uniswap` to `run_math_parity.py` and
`run_upstream_suites.py`.

# Previous compiler (historical)

The 2026-09-24 upstream check resolved master to
`e2fa7e53c8bb5710c79afbf6c8450a194640dbd8`. The standalone port also requires
local fixes for bounded read-only static calls, implicit record-literal borrows,
unpadded ABI payloads, composed ABI decoder borrows, payable return handlers, and generated signatures
for error/event names longer than 31 bytes.
`results/fe-position-current-build.json` records the local commits and compiler hash;
`results/fe-position-current-local-fixes.patch` contains the complete source changes and
regression fixtures, without the demo sources.

Reproduce this source state in a fresh checkout:

```sh
git clone https://github.com/argotorg/fe.git /tmp/fe-uniswap
cd /tmp/fe-uniswap
git checkout e2fa7e53c8bb5710c79afbf6c8450a194640dbd8
git apply /path/to/uniswap_v4_demo/tests/results/fe-position-current-local-fixes.patch
npm ci --prefix crates/tree-sitter-fe
export PATH="$PWD/crates/tree-sitter-fe/node_modules/.bin:$PATH"
cargo build --release -p fe
```

The reconstructed checkout has an uncommitted patch and a different commit ID
from the locally committed build; byte-identical compiler binaries are not
promised. The parity runner records binary and worktree patch hashes. To move
onto a newer master, reapply the fixes that are still absent and rerun their
regression fixtures and protocol suites.

Select this compiler explicitly from the demo root:

```sh
python3 tests/run_math_parity.py --fe-repo /tmp/fe-uniswap --suite descriptor \
  --reference-openzeppelin /path/to/pinned/openzeppelin \
  --solc /path/to/solc-0.8.26 --runs 10000
```

The local working checkout for this session is `/tmp/fe-uniswap-permissioned-position`.
The original sibling Fe checkout and its extracted demo deletions were preserved.

Independent local fix branches for review are listed in [COMPILER_FIX_BRANCHES.md](COMPILER_FIX_BRANCHES.md).
