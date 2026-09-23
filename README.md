# Uniswap v4 in Fe

A complete port of Uniswap v4 core and periphery to Fe. Every production
contract of the pinned v4-core and v4-periphery revisions has a Fe
implementation: PoolManager, PositionManager, PermissionedPositionManager,
V4Router, PermissionedV4Router, V4Quoter, StateView, ReservesLens,
PositionDescriptor, PermissionsAdapter(Factory) and
UniswapV4DeployerCompetition, together with all libraries.

**Upstream conformance.** The unmodified upstream Foundry suites of both
repositories run against the Fe contracts, with every outcome identical to
the original Solidity contracts (`tests/run_upstream_suites.py`, 1,000 fuzz
runs, O1):

| Suite | Solidity | Fe |
| --- | --- | --- |
| v4-core (598 tests) | 597 passed, 1 failed | 597 passed, 1 failed (same test) |
| v4-periphery (942 tests) | 942 passed | 942 passed |

The single v4-core failure is an upstream fuzz-test bug at the pinned revision
(`TickMath.t.sol`, input -887273 below `MIN_TICK`); it touches no Fe code.
The periphery run excludes only `ReservesLens.fork.t.sol`, which needs a live
RPC endpoint. Evidence: `tests/results/upstream-conformance-o1.{json,log}` and
the per-test table `upstream-conformance-o1-tests.json`. The complete native
Fe test run passes all 1,948 tests (`native-integrated-o1`).

Limits:

- Five runtimes exceed the EIP-170 limit of 24,576 bytes: PoolManager (33,354),
  PositionManager (40,174), ReservesLens (41,652), PositionDescriptor (45,153)
  and PermissionedPositionManager (47,474). Deployment needs a chain or test
  environment without that limit.
- A locally patched Fe compiler is required: current master plus open PRs and
  one new fix. See [tests/COMPILER.md](tests/COMPILER.md).
- The raw Fe ABI JSON has known metadata limitations. Use the checked
  `*.protocol.abi.json` exports described below.

Run the upstream suites (clones the pinned revisions, builds all Fe contracts):

```sh
python3 tests/run_upstream_suites.py --fe-repo /path/to/patched/fe \
  --work-dir /tmp/v4-upstream-run
```

The patches in `tests/upstream/` change only deployment helpers: when
`$FE_ARTIFACTS/<Contract>.bin` exists, the Fe creation bytecode is deployed
instead of the Solidity artifact. A probe test fails the run if any listed
contract does not resolve to Fe. The abstract V4Router/PermissionedV4Router
are exercised through Fe ports of the upstream test mocks
(`src/upstream_test_mocks.fe`). Other test-only contracts stay Solidity:
the v4-core test routers (PoolSwapTest etc.), hooks, tokens and MockMulticall.

The port contains the core math, pool/tick/position accounting, hooks, transient
accounting, currencies, claims, ownership, protocol fees and external storage
interfaces. The PoolManager exposes all 33 entrypoints and passes the current
O1/O2 integration suite, including settlement and adversarial callbacks. Its
runtime still exceeds the usual deployment size limit.

Periphery coverage includes liquidity/slippage math, packed position metadata,
paths, action decoding, StateView, transient-state reads, payments, router, quoter,
PositionManager, PositionDescriptor and SVG generation. Detailed coverage, reference differences and
outstanding work are tracked in [REPORT.md](REPORT.md) and
[core_status.json](core_status.json) and
[periphery_status.json](periphery_status.json).

Reference: https://github.com/Uniswap/v4-core at `46c6834698c48bc4a463a86d8420f4eb1d7f3b75` (retrieved 2026-09-22). Source file SPDX licenses apply to translations. Arithmetic and type libraries are MIT; Position, Pool, transient accounting and their test harnesses retain BUSL-1.1. Those license texts are included; the AGPL-3.0-only license for the pinned Solmate Owned dependency is also retained. FullMath's algorithm credits Remco Bloemen. Periphery: https://github.com/Uniswap/v4-periphery at `9969eec44cfdf07e24b41de47f40276a58401976`. [reference_manifest.json](reference_manifest.json) records every reference source hash and direct submodule revision, including reference test fixtures.

This is the standalone demo repository, extracted from the Fe checkout's
`uniswapv4_demo` branch at `7021a1d69`, including its uncommitted demo changes.
The core inventory maps all 46 production reference files to Fe modules and
specific test evidence. The 38 upstream `src/test` files are listed separately
as reference test actors. Historical status strings in `reference_manifest.json`
predate the current implementation; use the core/periphery inventories for the
current review, and the manifest for source hashes and revisions. An inventory
mapping alone is not a claim of complete behavioral parity.

Historical test evidence and paths in REPORT.md and tests/results are retained
as recorded; they refer to the original checkout when applicable.

The Fe compiler remains a separate dependency. The parity runner defaults to
the sibling checkout `../fe` and its `target/release/fe` binary. Use
`--fe-repo /path/to/fe --fe /path/to/fe-binary` to select another checkout/build.
Existing evidence records the exact compiler hashes. Reproducible compiler
patches and build instructions are in [tests/COMPILER.md](tests/COMPILER.md).

Current validation policy: use **O1 only**. Existing O2 results are historical
records; all further builds and tests use O1. The parity runner defaults to
`--optimize 1` and rejects other optimization levels.

Run from this repository's root:

```sh
python3 tests/generate_math_vectors.py
../fe/target/release/fe check .
../fe/target/release/fe test . -O1
```

Direct Solidity parity tests build a Fe harness, deploy it in Forge, and
compare success/revert status and complete return/revert bytes with unmodified,
hash-verified upstream Solidity libraries. Requires Forge and solc 0.8.30:

```sh
python3 tests/run_math_parity.py --suite math --runs 10000
python3 tests/run_math_parity.py --suite foundation --runs 10000
python3 tests/run_math_parity.py --suite state --runs 10000
python3 tests/run_math_parity.py --suite pool --runs 10000
python3 tests/run_math_parity.py --suite transient --runs 10000
python3 tests/run_math_parity.py --suite currency --runs 10000
python3 tests/run_math_parity.py --suite types --runs 10000
python3 tests/run_math_parity.py --suite hooks --runs 10000
python3 tests/run_math_parity.py --suite claims --runs 10000
python3 tests/run_math_parity.py --suite owned --runs 10000
python3 tests/run_math_parity.py --suite protocol_fees --runs 10000
python3 tests/run_math_parity.py --suite extload --runs 10000
# Optional offline reference checkout with an explicit O1 build:
python3 tests/run_math_parity.py \
  --reference-core /path/to/v4-core --optimize 1 --runs 10000
```

The script prints its temporary artifact directory and retains bytecode, source,
Forge logs and `validation.json` (compiler identity, source hashes and settings).
The production arithmetic accepts Solidity-width wrapper types (`Int24`,
`Uint24`, `Uint160`); internal callers must supply canonical values, as ABI
entrypoints do. The harness contracts are test infrastructure, not protocol deployments.
The state suite additionally compares raw storage, reserved bits and sequences of
bitmap and position operations, including reverted updates.
The pool suite additionally tests complete liquidity/swap/donation sequences and
isolation of pools at different runtime storage roots. Solidity uses `viaIR` for
the pool harness to avoid its stack-too-deep code-generation limitation.
The transient suite compares raw transient slots, checked delta arithmetic,
wrapped counters, account/currency isolation, static-call failures and atomic
rollback. Its account helper mirrors PoolManager; the four reference libraries
are imported unchanged. To additionally check transaction-end reset on a fresh
local Anvil node (requires `anvil` and `cast`):

```sh
python3 tests/run_math_parity.py --suite transient \
  --runs 10000 --work-dir /tmp/v4-transient
python3 tests/run_transient_transactions.py \
  /tmp/v4-transient --output /tmp/v4-transient/transactions.json
```

The transaction test checks traces for actual nonzero TSTORE writes before
verifying zero values in subsequent calls. The work directory must be new.
The Currency suite checks unusual token returns, native payments, static balance
queries, transaction rollback and complete ERC-7751 error bytes. Generated ABI
JSON currently omits custom errors and misclassifies the balance harness as
nonpayable; see REPORT.md.
The standalone compiler reproductions under `tests/repros` expose compilation
failures or incorrect ABI metadata.

Historical note: this section predates the completed port; the upstream conformance results at the top of this README supersede its remaining-work statement. See [REPORT.md](REPORT.md) for obstacles and evidence.

The `types` suite covers PoolId hashing, structured argument/return codecs,
noncanonical words, every truncated fixed-head length and trailing calldata.
After a retained types run, compare ABI field names and shapes with:

```sh
python3 tests/check_types_abi.py /path/to/types-parity-artifacts
```

The checker records the known `poolId` mutability metadata mismatch separately.
External Currency/IHooks fields use Address and PoolId uses Bytes32, matching
Solidity's erased user-defined/interface types.

The `hooks` suite checks permission masks, hook response shapes, all callback
calldata, callback counts, self-call suppression, fee truncation, wrapped errors,
and caller/hook delta arithmetic. Its mock contracts are installed at addresses
with the desired low-bit flags. Solidity uses viaIR for this suite. Complete
pool lifecycle ordering and reentrant settlement await PoolManager integration.

The `claims` suite compares ERC6909/Claims at storage roots 0 and 3, including
raw slots, packed operator bits, allowances, complete events, rollback and full
mint/transfer/burn sequences. The harness's unguarded mint/burn entries are for
testing internal helpers; they are not a deployable claims token or PoolManager.
To check event metadata after a retained claims run:

```sh
python3 tests/check_claims_events.py /path/to/claims-parity-artifacts
```

The `owned` suite uses the pinned Solmate reference rather than v4-core; pass
`--reference-solmate /path/to/solmate` for offline runs. It checks constructor and
transfer events, original Error(string) reverts, packed slot preservation and
owner transitions including zero/self addresses. The Owned port retains its
AGPL-3.0-only source license.

For Owned, per-handler effect declarations preserve `view` metadata. Its complete
harness ABI can be compared with the reference using:

```sh
python3 tests/check_owned_abi.py /path/to/owned-parity-artifacts
```

The `protocol_fees` suite uses both pinned v4-core and Solmate sources. Offline
runs accept both `--reference-core` and `--reference-solmate`. Tests cover owner
and controller authorization, pool fee validation/events, wrapping accrual,
native/token collection, synced-currency guards, unlocked collection and atomic
rollback, including the accrued balance visible inside a token transfer callback.
To audit ABI shapes/events and record remaining metadata gaps:

```sh
python3 tests/check_protocol_fees_abi.py /path/to/protocol-fees-artifacts
```

The `extload` suite checks every Extsload/Exttload overload, sparse/repeated slots,
range slot wraparound, empty arrays, overflowed range lengths and malformed ABI
heads/tails. Rebuild Fe with the local core ABI bounds-check fix before running:

```sh
cargo build --release -p fe
python3 tests/run_math_parity.py --suite extload --runs 10000
python3 tests/check_extload_abi.py /path/to/extload-artifacts
```

The runner retains the compiler source diff alongside its binary hash. Earlier
component records remain results for their recorded compiler versions.

Current integrated validation: PoolManager O1/O2 each pass 16 tests including
60,000 fuzz cases; periphery arithmetic and packed-position/path suites each
pass 30,000 fuzz cases per optimization. Periphery entrypoint contracts remain
in progress. Manager deployment size and ABI metadata differences remain
documented in REPORT.md. New suites: `--suite periphery_math` and
`--suite periphery_types`, optionally with `--reference-periphery PATH`.

StateView validation uses `--suite state_view` with solc 0.8.26 and the pinned
core/periphery/Solmate sources. It covers all state-reading endpoints and
malformed manager responses; see REPORT.md for reference-decoder details.

Successful PoolManager and StateView parity runs also export
`fe/<Contract>.protocol.abi.json` with a hash audit. Use these checked protocol
interfaces for clients; the raw Fe ABI retains the compiler's return-tuple/name
limitations. The adapter rejects incompatible wire layouts and does not alter
bytecode. StateView now passes 60,000 fuzz cases at each optimization level.

Periphery action/parameter decoding is validated at O1/O2 against the pinned
CalldataDecoder (100,000 fuzz cases total plus length boundaries). Run the same
parity command with `--suite calldata_decoder`. Swap structs remain lazy views;
this component result does not yet establish router execution parity.

[periphery_status.json](periphery_status.json) inventories every pinned periphery
source, its current Fe counterpart and available validation. Production contracts, shared helpers and external dependency interfaces are
listed by reference source; the final inventory audit remains open.

`--suite delta_resolver` checks external transient queries and debt/credit/balance
amount mapping (60,000 O1/O2 fuzz cases). `--suite payments` checks settlement and
Permit2 payment sequencing (40,000 O1/O2 fuzz cases), including rollback, short
returns and missing-code targets. These use instrumented providers; the real router and PositionManager
workflow results are recorded below.

The router's four swap actions now pass the O1 differential suite, including
per-hop exact-output shortfalls and malformed calldata. Run `--suite router`
with solc 0.8.26, required by the pinned V4Router source. Further runs use O1 only. Integrated execute/unlock/payment validation
is recorded in the later workflow results below.

The current O1 router workflow suite passes 40,000 fuzz cases plus four fixed
scenarios across Solidity/Solidity, Fe/Solidity and Fe/Fe router/manager pairs.
It uses real pool liquidity and the original pinned Permit2 runtime. Single- and
two-pool routes, payment actions, expired/insufficient allowances, exact allowance
debits, rollback and token-driven reentrancy are checked. The concrete wrapper
ABI passes the required audit. Run `--suite router_workflows
--manager-artifact <validated-manager-artifact>
--permit2-artifact <verified-permit2-build>` with solc 0.8.26 and O1; the runner
verifies both reused dependencies. Evidence: `router-real-permit2-latest-o1`.

PositionManager now passes O1/O2 integration tests across Solidity/Solidity,
Fe/Solidity and Fe/Fe combinations with the pinned real Permit2 runtime. Use
`--suite position_manager --permit2-artifact <verified-permit2-build>
--manager-artifact <verified-manager-build>` with all pinned reference paths,
solc 0.8.26 and matching optimization. `tests/build_permit2_reference.py` builds
Permit2 separately with its pinned 0.8.17 compiler. The suite checks lifecycle,
fees, native/ERC20 settlement, credits, subscriptions, permits and guards.
Its runtime exceeds EIP-170; the fixture raises the deployment size limit.
The Multicall malformed-array error-precedence gap is fixed by lazy decoding;
see the later validation checkpoint in REPORT.md. This is not a claim of completed protocol-wide compatibility.

`--suite periphery_aux` checks legacy PositionConfig hashes/subscriber bits,
vanity scoring and uppercase address formatting (40,000 cases at each O1/O2).

Current compiler setup: [tests/COMPILER.md](tests/COMPILER.md) records the latest
checked Fe master and the remaining local fixes, with a reproducible patch.
The completed-port validation used the integrated build described there (local checkout `/tmp/fe-uniswap-final`).
The historical checkpoints below the introduction describe their recorded
versions; the report and status inventory identify superseding evidence.

`--suite descriptor` compares complete NFT token-URI and SVG bytes against the
pinned Descriptor library. Current-master O1 passes 40,000 fuzz cases plus
boundary/replay cases; `--suite descriptor_format` independently covers 40,000
formatting cases. Use solc 0.8.26 and `--reference-openzeppelin` for both suites.
The public PositionDescriptor contract and its real PositionManager integration
now pass the O1 suites described below.

`--suite position_descriptor` validates the public metadata contract and all its
configuration/read endpoints (30,000 O1 fuzz cases plus boundary tests). It needs
solc 0.8.26 and the pinned OpenZeppelin and Permit2 sources. The checked
`PositionDescriptor.protocol.abi.json` is retained in `tests/results`.
Pass `--descriptor-artifact /path/to/validated-position-descriptor` to the
PositionManager suite to exercise actual NFT metadata during liquidity lifecycles;
without that option the added metadata workflow test is explicitly skipped.

The Descriptor-enabled PositionManager run passes 1,000 metadata lifecycle fuzz
cases across all three Solidity/Fe manager combinations, in addition to the
existing lifecycle, credit/native and guard tests. See
`tests/results/position-descriptor-workflows-o1.json` for exact source/compiler
and reused-artifact hashes.

An earlier O1 native snapshot passes all 1,948 tests; provenance and frozen
source hashes are in `tests/results/native-current-o1.json`. The subsequent
DeploymentCompetition port passes 40,000 differential fuzz cases plus CREATE2,
deadline and ABI boundaries, including the public protocol ABI export
(`deployer-competition-o1`). Typed PermissionFlags and the abstract allowlist
base's ERC165/interface behavior pass 30,000 differential cases
(`permission-foundations-o1`). Subsequent adapter and permissioned-consumer results follow below;
the final protocol-wide audit remains open.

PermissionsAdapter and PermissionsAdapterFactory now pass O1 component parity
on the current patched master: respectively 70,000 and 40,000 fuzz cases, boundary
scenarios and public ABI exports. Adapter sequences check token backing and the
PoolManager as sole wrapper holder; factory tests also exercise the Fe adapters
it actually deploys. See `permissions-adapter-o1` and `permissions-factory-o1`
under `tests/results`. The compiler additionally fixes generated error/event
names longer than Fe's 31-byte inline-string limit, with 47 targeted regression
tests passing. Permissioned router and position-manager integration results
follow below.

PermissionedV4Router now passes 70,000 component fuzz cases and 40,000 real-pool
workflow cases plus replay/boundaries, using real Permit2 and factory-created
adapters across four Fe/Solidity combinations. Single/multihop swaps, permission
revocation, rollback, native/ERC20 funding, refunds and reentrancy are covered;
the concrete wrapper ABI is verified. Standard router regression suites also
pass after the shared payment-policy extension. The earlier native
snapshot passes 1,948 tests (`native-permissioned-o1`); its metadata explicitly
lists subsequent router changes covered by the new suites.

PermissionedPositionManager now passes 40,000 O1 fuzz cases (including 10,000
16-step sequences per implementation), ten fixed scenarios and the full protocol
ABI audit on Fe master `e2fa7e53` with local fixes (`702686c98`). Three systems use
real Permit2: Solidity-only, Fe NFT manager, and full Fe NFT/factory/PoolManager.
Coverage includes forced exits and stray claims, isolated malicious recipients,
subscriber reattachment, separate owner/funder permissions, inherited permits and
Multicall, malformed permission responses, and backing/lock invariants. Evidence:
`permissioned-position-workflows-o1` and `PermissionedPositionManager.protocol.abi`.
The ordinary PositionManager and real Descriptor workflows also pass on this
compiler (`position-policy-latest-o1`, `position-descriptor-latest-o1`, and
`position-metadata-latest-o1`).

The parity runner and retest tool only mark an artifact passed after all required
runtime and protocol ABI checks succeed. Compiler and porting bugs, including the
former premature passed status, are documented in REPORT.md. The complete current Fe test run passes all 1,948 tests at O1, with all 127
source hashes verified (`native-position-current-o1`). Latest reader checks pass
50,000 Quoter, 60,000 StateView and 30,000 ReservesLens fuzz cases; Quoter with
the current Fe PoolManager adds 20,000 cases. The interface audit verifies action
constants, router schemas/errors and the WETH9 consumer interface
(`periphery-interface-audit`). The final protocol-wide audit remains open.

The current O1 PoolManager suite passes 70,000 fuzz cases and ten fixed tests
(`manager-stateful-latest-o1`). Its 10,000 randomized two-pool sequences check
200,000 action steps, with independent liquidity/bitmap models and exact
tick/position storage comparisons after each step, including complete removal
and rejected overdraw. The full protocol ABI audit passes. Foundation arithmetic
and packed types additionally pass 60,000 current O1 cases (`foundation-latest-o1`).
