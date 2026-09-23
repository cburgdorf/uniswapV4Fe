#!/usr/bin/env python3
"""Build Fe and run byte-for-byte Solidity differential tests in a temp project.

Requires Fe (default ../fe/target/release/fe), forge and solc 0.8.30 (forge can install).
Reference source is downloaded at the pinned revision and verified against the
manifest, or read from --reference-core for an offline run. No forge-std needed.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import urllib.request
from protocol_abi_gate import complete_validation

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_FE_REPO = ROOT.parent / 'fe'
PERIPHERY_SUITES = {'periphery_math', 'periphery_types', 'state_view', 'calldata_decoder', 'delta_resolver', 'payments', 'router', 'router_workflows', 'permissioned_router', 'permissioned_router_workflows', 'quoter', 'quoter_workflows', 'reserves_lens', 'permit_foundations', 'signature_verification', 'erc721_permit', 'multicall', 'native_wrapper', 'pool_initializer', 'notifier', 'permit2_forwarder', 'permit2_workflows', 'position_manager', 'permissioned_position_manager', 'periphery_aux', 'currency_metadata', 'descriptor_format', 'descriptor', 'position_descriptor', 'deployer_competition', 'permission_foundations', 'permissions_adapter', 'permissions_factory', 'svg'}
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--suite', choices=['math', 'foundation', 'state', 'pool', 'transient', 'currency', 'types', 'hooks', 'claims', 'owned', 'protocol_fees', 'extload', 'manager', 'periphery_math', 'periphery_types', 'state_view', 'calldata_decoder', 'delta_resolver', 'payments', 'router', 'router_workflows', 'permissioned_router', 'permissioned_router_workflows', 'quoter', 'quoter_workflows', 'reserves_lens', 'permit_foundations', 'signature_verification', 'erc721_permit', 'multicall', 'native_wrapper', 'pool_initializer', 'notifier', 'permit2_forwarder', 'permit2_workflows', 'position_manager', 'permissioned_position_manager', 'periphery_aux', 'currency_metadata', 'descriptor_format', 'descriptor', 'position_descriptor', 'deployer_competition', 'permission_foundations', 'permissions_adapter', 'permissions_factory', 'svg'], default='math')
parser.add_argument('--fe-repo', type=Path, default=DEFAULT_FE_REPO,
                    help='Fe compiler checkout for source provenance (default: ../fe)')
parser.add_argument('--fe', type=Path, help='Compiler binary (default: <fe-repo>/target/release/fe)')
parser.add_argument('--reuse-fe-artifact', type=Path, help='Reuse a passed build with identical compiler, optimization and frozen sources')
parser.add_argument('--permit2-artifact', type=Path, help='Hash-verified pinned Permit2 reference build')
parser.add_argument('--permissions-factory-artifact', type=Path, help='Passed PermissionsAdapterFactory artifact for permissioned workflows')
parser.add_argument('--descriptor-artifact', type=Path, help='Passed PositionDescriptor artifact for real metadata workflows')
parser.add_argument('--manager-artifact', type=Path, help='Verified PoolManager parity artifact for combined workflows')
parser.add_argument('--reference-core', type=Path)
parser.add_argument('--reference-solmate', type=Path)
parser.add_argument('--reference-openzeppelin', type=Path)
parser.add_argument('--reference-periphery', type=Path)
parser.add_argument('--reference-permit2', type=Path)
parser.add_argument('--solc', help='Solidity compiler path or version; defaults to 0.8.26 for manager, 0.8.30 otherwise')
parser.add_argument('--runs', type=int, default=1024)
parser.add_argument('--optimize', choices=['1'], default='1',
                    help='Fe optimization level (O1 only; higher levels are too slow)')
parser.add_argument('--work-dir', type=Path, help='Retain artifacts here; directory must not exist')
parser.add_argument('--build-full-ingot', action='store_true', help='Also compile unrelated test harnesses and generated vector tests')
args = parser.parse_args()
args.fe_repo = args.fe_repo.resolve()
if args.fe is None:
    args.fe = args.fe_repo / 'target/release/fe'
if args.runs <= 0:
    parser.error('--runs must be positive')
harness = {'math': 'MathHarness', 'foundation': 'FoundationHarness', 'state': 'StateHarness', 'pool': 'PoolHarness', 'transient': 'TransientHarness', 'currency': 'CurrencyHarness', 'types': 'TypesHarness', 'hooks': 'HooksHarness', 'claims': 'ClaimsHarness', 'owned': 'OwnedHarness', 'protocol_fees': 'ProtocolFeesHarness', 'extload': 'ExtloadHarness', 'manager': 'PoolManager', 'periphery_math': 'PeripheryMathHarness', 'periphery_types': 'PeripheryTypesHarness', 'state_view': 'StateView', 'calldata_decoder': 'CalldataDecoderHarness', 'delta_resolver': 'DeltaResolverHarness', 'payments': 'PaymentsHarness', 'router': 'RouterHarness', 'permissioned_router': 'PermissionedRouterHarness', 'permissioned_router_workflows': 'PermissionedV4Router', 'router_workflows': 'V4Router', 'quoter': 'V4Quoter', 'quoter_workflows': 'V4Quoter', 'reserves_lens': 'ReservesLens', 'permit_foundations': 'PermitFoundationsHarness', 'signature_verification': 'SignatureVerificationHarness', 'erc721_permit': 'ERC721PermitHarness', 'multicall': 'MulticallHarness', 'native_wrapper': 'NativeWrapperHarness', 'pool_initializer': 'PoolInitializerHarness', 'notifier': 'NotifierHarness', 'permit2_forwarder': 'Permit2ForwarderHarness', 'permit2_workflows': 'Permit2ForwarderHarness', 'position_manager': 'PositionManager', 'permissioned_position_manager': 'PermissionedPositionManager', 'periphery_aux': 'PeripheryAuxHarness', 'currency_metadata': 'CurrencyMetadataHarness', 'descriptor_format': 'DescriptorFormatHarness', 'permissions_adapter': 'PermissionsAdapter', 'permissions_factory': 'PermissionsAdapterFactory', 'permission_foundations': 'PermissionFoundationsHarness', 'deployer_competition': 'UniswapV4DeployerCompetition', 'position_descriptor': 'PositionDescriptor', 'descriptor': 'DescriptorHarness', 'svg': 'SvgHarness'}[args.suite]
test_file = {'math': 'MathParity.t.sol', 'foundation': 'FoundationParity.t.sol', 'state': 'StateParity.t.sol', 'pool': 'PoolParity.t.sol', 'transient': 'TransientParity.t.sol', 'currency': 'CurrencyParity.t.sol', 'types': 'TypesParity.t.sol', 'hooks': 'HooksParity.t.sol', 'claims': 'ClaimsParity.t.sol', 'owned': 'OwnedParity.t.sol', 'protocol_fees': 'ProtocolFeesParity.t.sol', 'extload': 'ExtloadParity.t.sol', 'manager': 'ManagerParity.t.sol', 'periphery_math': 'PeripheryMathParity.t.sol', 'periphery_types': 'PeripheryTypesParity.t.sol', 'state_view': 'StateViewParity.t.sol', 'calldata_decoder': 'CalldataDecoderParity.t.sol', 'delta_resolver': 'DeltaResolverParity.t.sol', 'payments': 'PaymentsParity.t.sol', 'router': 'RouterParity.t.sol', 'permissioned_router': 'PermissionedRouterParity.t.sol', 'permissioned_router_workflows': 'PermissionedRouterWorkflows.t.sol', 'router_workflows': 'RouterWorkflows.t.sol', 'quoter': 'QuoterParity.t.sol', 'quoter_workflows': 'QuoterWorkflows.t.sol', 'reserves_lens': 'ReservesLensParity.t.sol', 'permit_foundations': 'PermitFoundationsParity.t.sol', 'signature_verification': 'SignatureVerificationParity.t.sol', 'erc721_permit': 'ERC721PermitParity.t.sol', 'multicall': 'MulticallParity.t.sol', 'native_wrapper': 'NativeWrapperParity.t.sol', 'pool_initializer': 'PoolInitializerParity.t.sol', 'notifier': 'NotifierParity.t.sol', 'permit2_forwarder': 'Permit2ForwarderParity.t.sol', 'permit2_workflows': 'Permit2ForwarderWorkflows.t.sol', 'position_manager': 'PositionManagerWorkflows.t.sol', 'permissioned_position_manager': 'PermissionedPositionManagerWorkflows.t.sol', 'periphery_aux': 'PeripheryAuxParity.t.sol', 'currency_metadata': 'CurrencyMetadataParity.t.sol', 'descriptor_format': 'DescriptorFormatParity.t.sol', 'permissions_adapter': 'PermissionsAdapterParity.t.sol', 'permissions_factory': 'PermissionsFactoryParity.t.sol', 'permission_foundations': 'PermissionFoundationsParity.t.sol', 'deployer_competition': 'DeployerCompetitionParity.t.sol', 'position_descriptor': 'PositionDescriptorParity.t.sol', 'descriptor': 'DescriptorParity.t.sol', 'svg': 'SvgParity.t.sol'}[args.suite]
work = args.work_dir.resolve() if args.work_dir else Path(tempfile.mkdtemp(prefix='fe-v4-math-parity-'))
if args.work_dir:
    work.mkdir(parents=True)
print(f'Parity artifacts: {work}', flush=True)
compiler_version = subprocess.check_output([str(args.fe.resolve()), '--version'], text=True).strip()
compiler_hash = hashlib.sha256(args.fe.read_bytes()).hexdigest()
compiler_revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=args.fe_repo, text=True).strip()
compiler_diff = subprocess.check_output(['git', 'diff', '--', 'ingots', 'crates'], cwd=args.fe_repo)
(work / 'compiler-source.patch').write_bytes(compiler_diff)
# Freeze exactly the sources being built. Unrelated harnesses and the 1,947
# generated arithmetic unit tests are checked separately by `fe test`.
build_root = work / 'ingot'
(build_root / 'src').mkdir(parents=True)
shutil.copyfile(ROOT / 'fe.toml', build_root / 'fe.toml')
source_hashes = {}
# The isolated ERC721 adapter has a small, explicit module closure. Freeze and
# hash every member, avoiding unrelated PoolManager/math-vector analysis.
erc721_modules = {'erc721.fe', 'erc721_permit.fe', 'erc721_permit_harness.fe',
                  'storage_string.fe', 'eip712.fe', 'unordered_nonce.fe',
                  'erc721_permit_hash.fe', 'signature_verification.fe'}
# Freeze the PoolManager's explicit core module closure, so changes to unrelated
# periphery consumers do not invalidate a previously verified manager binary.
manager_modules = {name + '.fe' for name in (
    'lib balance_delta before_swap_delta bit_math claims currency extload fixed_point '
    'full_math hooks liquidity_math lp_fee manager owned pool pool_manager pool_swap '
    'pool_types position protocol_fee protocol_fees safe_cast slot0 sqrt_price_math '
    'swap_math tick_bitmap tick_math transient unsafe_math liquidity_amounts slippage_check bips'
).split()}
position_manager_modules = manager_modules | {name + '.fe' for name in (
    'actions calldata_decoder delta_resolver eip712 erc721 erc721_permit erc721_permit_hash '
    'multicall native_wrapper notifier payments permit2_forwarder position_info '
    'position_manager position_manager_actions position_manager_state pool_initializer '
    'router router_params signature_verification state_library storage_string '
    'transient_state_library unordered_nonce'
).split()}
adapter_modules = {'permissions_adapter.fe', 'permissions_adapter_io.fe', 'permissions_adapter_state.fe', 'permission_flags.fe', 'allowlist_checker.fe', 'storage_string.fe', 'metadata_text.fe'}
router_modules = (manager_modules - {'pool_manager.fe'}) | {n + '.fe' for n in 'lib actions bips currency delta_resolver payments calldata_decoder router router_params pool_types balance_delta safe_cast tick_math bit_math full_math transient_state_library transient'.split()}
# Readers and quoters do not depend on NFT managers, factories or descriptors.
# Keep their complete explicit import closures while avoiding unrelated analysis.
reader_modules = (manager_modules - {'pool_manager.fe'}) | {'state_library.fe'}
quoter_modules = reader_modules | {n + '.fe' for n in 'quoter quoter_calldata quoter_memory v4_quoter path_key router_params calldata_decoder'.split()}
reserves_modules = reader_modules | {n + '.fe' for n in 'reserves_lens reserves_scan reserves_hooks reserves_errors reserves_types'.split()}
foundation_modules = {n + '.fe' for n in 'foundation_harness lp_fee protocol_fee liquidity_math fixed_point balance_delta before_swap_delta slot0 safe_cast'.split()}
for source in sorted((ROOT / 'src').glob('*.fe')):
    if not args.build_full_ingot:
        selected = {'foundation': foundation_modules, 'state_view': reader_modules | {'state_view.fe'}, 'quoter': quoter_modules, 'quoter_workflows': quoter_modules, 'reserves_lens': reserves_modules}.get(args.suite)
        if selected is not None and source.name not in selected:
            continue
    if args.suite in ['router', 'router_workflows', 'permissioned_router', 'permissioned_router_workflows'] and not args.build_full_ingot:
        extra = {'router_harness.fe'} if args.suite == 'router' else {'v4_router.fe'} if args.suite == 'router_workflows' else {'permissioned_router.fe', 'permissioned_router_harness.fe' if args.suite == 'permissioned_router' else 'permissioned_v4_router.fe'}
        if source.name not in router_modules | extra:
            continue
    if args.suite in ['permissions_adapter', 'permissions_factory'] and not args.build_full_ingot and source.name not in (adapter_modules | ({'permissions_adapter_factory.fe'} if args.suite == 'permissions_factory' else set())):
        continue
    if args.suite == 'permission_foundations' and not args.build_full_ingot and source.name not in {'permission_flags.fe', 'allowlist_checker.fe', 'permission_foundations_harness.fe'}:
        continue
    if args.suite == 'deployer_competition' and not args.build_full_ingot and source.name not in {'deployer_competition.fe', 'vanity_address.fe'}:
        continue
    if args.suite == 'position_descriptor' and not args.build_full_ingot and source.name not in ((manager_modules - {'pool_manager.fe'}) | {'metadata_text.fe', 'svg.fe', 'svg_math.fe', 'descriptor.fe', 'descriptor_image.fe', 'descriptor_format.fe', 'position_descriptor.fe', 'currency_ratio_sort_order.fe', 'safe_currency_metadata.fe', 'address_string.fe', 'position_info.fe', 'state_library.fe'}):
        continue
    if args.suite == 'descriptor' and not args.build_full_ingot and source.name not in ((manager_modules - {'pool_manager.fe'}) | {'metadata_text.fe', 'svg.fe', 'svg_math.fe', 'descriptor.fe', 'descriptor_image.fe', 'descriptor_format.fe', 'descriptor_harness.fe'}):
        continue
    if args.suite == 'svg' and not args.build_full_ingot and source.name not in ((manager_modules - {'pool_manager.fe'}) | {'metadata_text.fe', 'svg.fe', 'svg_math.fe', 'svg_harness.fe'}):
        continue
    if args.suite == 'descriptor_format' and not args.build_full_ingot and source.name not in ((manager_modules - {'pool_manager.fe'}) | {'metadata_text.fe', 'descriptor_format.fe', 'descriptor_format_harness.fe'}):
        continue
    if args.suite == 'currency_metadata' and not args.build_full_ingot and source.name not in {'safe_currency_metadata.fe', 'address_string.fe', 'currency_metadata_harness.fe'}:
        continue
    if args.suite == 'periphery_aux' and not args.build_full_ingot and source.name not in {'pool_types.fe', 'position_config.fe', 'vanity_address.fe', 'address_string.fe', 'periphery_aux_harness.fe'}:
        continue
    if args.suite in ['position_manager', 'permissioned_position_manager'] and not args.build_full_ingot:
        extra = {'permissioned_position_manager.fe', 'permissioned_position_policy.fe', 'permissioned_position_unwind.fe', 'permissioned_router.fe'} if args.suite == 'permissioned_position_manager' else set()
        if source.name not in position_manager_modules | extra:
            continue
    if args.suite == 'manager' and not args.build_full_ingot and source.name not in manager_modules:
        continue
    if args.suite in ['permit2_forwarder', 'permit2_workflows'] and not args.build_full_ingot and source.name not in {'permit2_forwarder.fe', 'permit2_forwarder_harness.fe'}:
        continue
    if args.suite == 'notifier' and not args.build_full_ingot and source.name not in {'notifier.fe', 'notifier_harness.fe', 'currency.fe'}:
        continue
    if args.suite == 'pool_initializer' and not args.build_full_ingot and source.name not in {'pool_initializer.fe', 'pool_initializer_harness.fe', 'pool_types.fe'}:
        continue
    if args.suite == 'native_wrapper' and not args.build_full_ingot and source.name not in {'native_wrapper.fe', 'native_wrapper_harness.fe'}:
        continue
    if args.suite == 'multicall' and not args.build_full_ingot and source.name not in {'multicall.fe', 'multicall_harness.fe'}:
        continue
    if args.suite == 'erc721_permit' and not args.build_full_ingot and source.name not in erc721_modules:
        continue
    data = source.read_bytes()
    if not args.build_full_ingot:
        if source.name in ['math_vectors.fe', 'math_reverts.fe']:
            continue
        if source.stem.endswith('_harness') and ('pub contract ' + harness + ' {').encode() not in data:
            continue
    (build_root / 'src' / source.name).write_bytes(data)
    source_hashes[str(source.relative_to(ROOT))] = hashlib.sha256(data).hexdigest()
print(f'Compiler: {compiler_version}; sha256={compiler_hash}', flush=True)
reused_build = None
if args.reuse_fe_artifact:
    artifact = args.reuse_fe_artifact.resolve()
    raw = (artifact / 'validation.json').read_bytes()
    previous = json.loads(raw)
    if previous['result'] != 'passed' or previous['compiler_sha256'] != compiler_hash or previous['optimization'] != args.optimize or previous['sources'] != source_hashes:
        raise ValueError('Reused build must be passed and match compiler, optimization and every frozen source')
    creation = artifact / 'fe' / (harness + '.bin')
    code = bytes.fromhex(creation.read_text().strip().removeprefix('0x'))
    if hashlib.sha256(code).hexdigest() != previous['creation_bytecode_sha256']:
        raise ValueError('Reused creation bytecode hash mismatch')
    (work / 'fe').mkdir()
    copied = {}
    for suffix in ['.bin', '.runtime.bin', '.abi.json']:
        name = harness + suffix
        data = (artifact / 'fe' / name).read_bytes()
        (work / 'fe' / name).write_bytes(data)
        copied[name] = hashlib.sha256(data).hexdigest()
    reused_build = {'validation_sha256': hashlib.sha256(raw).hexdigest(), 'files_sha256': copied, 'validation': previous}
else:
    subprocess.run([str(args.fe.resolve()), 'build', str(build_root), '--contract', harness,
                    '-O', args.optimize, '--out-dir', str(work / 'fe')], check=True)
bytecode = next((work / 'fe').rglob(harness + '.bin')).read_text().strip()
(work / 'fe-bytecode.txt').write_text(bytecode if bytecode.startswith('0x') else '0x' + bytecode)
(work / 'test/reference').mkdir(parents=True)
manifest = json.loads((ROOT / 'reference_manifest.json').read_text())['solmate' if args.suite == 'owned' else 'v4-core']
reference_dir = args.reference_solmate if args.suite == 'owned' else args.reference_core
if args.suite in ['currency_metadata', 'deployer_competition', 'permission_foundations']:
    reference_paths = []
elif args.suite in ['permissions_adapter', 'permissions_factory']:
    reference_paths = [p for p in manifest['sources'] if p.startswith(('src/types/', 'src/interfaces/'))]
    reference_paths += ['src/libraries/SafeCast.sol', 'src/libraries/CustomRevert.sol']
elif args.suite == 'owned':
    reference_paths = ['src/auth/Owned.sol']
elif args.suite == 'math':
    reference_paths = [f'src/libraries/{name}.sol' for name in ['FullMath', 'BitMath', 'TickMath', 'CustomRevert', 'SqrtPriceMath', 'SafeCast', 'UnsafeMath', 'FixedPoint96', 'SwapMath']]
elif args.suite == 'foundation':
    reference_paths = [f'src/libraries/{name}.sol' for name in ['LPFeeLibrary', 'ProtocolFeeLibrary', 'LiquidityMath', 'SafeCast', 'CustomRevert', 'FixedPoint96', 'FixedPoint128']]
    reference_paths += [f'src/types/{name}.sol' for name in ['BalanceDelta', 'BeforeSwapDelta', 'Slot0']]
elif args.suite == 'state':
    reference_paths = [f'src/libraries/{name}.sol' for name in ['TickBitmap', 'BitMath', 'Position', 'FullMath', 'FixedPoint128', 'LiquidityMath', 'CustomRevert']]
elif args.suite == 'position_descriptor':
    reference_paths = [p for p in manifest['sources'] if p.startswith(('src/types/', 'src/interfaces/'))]
    reference_paths += [f'src/libraries/{n}.sol' for n in ['SafeCast', 'CustomRevert', 'FullMath', 'BitMath', 'TickMath', 'LPFeeLibrary', 'StateLibrary', 'Position', 'FixedPoint128', 'LiquidityMath']]
elif args.suite in ['descriptor', 'svg', 'descriptor_format', 'periphery_aux', 'periphery_types', 'calldata_decoder', 'delta_resolver', 'payments', 'router']:
    reference_paths = [p for p in manifest['sources'] if p.startswith(('src/types/', 'src/interfaces/'))]
    reference_paths += ['src/libraries/SafeCast.sol', 'src/libraries/CustomRevert.sol']
    if args.suite in ['descriptor', 'position_descriptor', 'deployer_competition', 'permission_foundations', 'permissions_adapter', 'permissions_factory', 'svg', 'descriptor_format']:
        reference_paths += [f'src/libraries/{n}.sol' for n in ['FullMath', 'BitMath', 'TickMath', 'LPFeeLibrary']]
    if args.suite in ['delta_resolver', 'payments', 'router', 'router_workflows', 'permissioned_router', 'permissioned_router_workflows']:
        reference_paths += [f'src/libraries/{n}.sol' for n in ['TransientStateLibrary', 'CurrencyReserves', 'NonzeroDeltaCount', 'Lock']]
    if args.suite == 'router':
        reference_paths += ['src/libraries/TickMath.sol', 'src/libraries/BitMath.sol']
elif args.suite == 'periphery_math':
    reference_paths = ['src/libraries/FullMath.sol', 'src/libraries/FixedPoint96.sol', 'src/libraries/SafeCast.sol', 'src/libraries/CustomRevert.sol', 'src/types/BalanceDelta.sol']
elif args.suite in ['manager', 'state_view', 'router_workflows', 'permissioned_router', 'permissioned_router_workflows', 'quoter', 'quoter_workflows', 'reserves_lens', 'permit_foundations', 'signature_verification', 'erc721_permit', 'multicall', 'native_wrapper', 'pool_initializer', 'notifier', 'permit2_forwarder', 'permit2_workflows', 'position_manager', 'permissioned_position_manager']:
    reference_paths = [p for p in manifest['sources'] if p.startswith('src/') and not p.startswith('src/test/')]
elif args.suite == 'extload':
    reference_paths = ['src/Extsload.sol', 'src/Exttload.sol', 'src/interfaces/IExtsload.sol', 'src/interfaces/IExttload.sol']
elif args.suite == 'claims':
    reference_paths = ['src/ERC6909.sol', 'src/ERC6909Claims.sol', 'src/interfaces/external/IERC6909Claims.sol']
elif args.suite == 'hooks':
    reference_paths = [p for p in manifest['sources'] if p.startswith(('src/types/', 'src/interfaces/'))]
    reference_paths += [f'src/libraries/{name}.sol' for name in ['Hooks', 'ParseBytes', 'LPFeeLibrary', 'SafeCast', 'CustomRevert']]
elif args.suite == 'types':
    reference_paths = [f'src/types/{name}.sol' for name in ['PoolKey', 'PoolId', 'PoolOperation', 'Currency', 'BalanceDelta', 'BeforeSwapDelta']]
    reference_paths += ['src/interfaces/IHooks.sol', 'src/interfaces/external/IERC20Minimal.sol', 'src/libraries/CustomRevert.sol', 'src/libraries/SafeCast.sol']
elif args.suite == 'currency':
    reference_paths = ['src/types/Currency.sol', 'src/libraries/CustomRevert.sol', 'src/interfaces/external/IERC20Minimal.sol']
elif args.suite == 'transient':
    reference_paths = [f'src/libraries/{name}.sol' for name in ['Lock', 'NonzeroDeltaCount', 'CurrencyDelta', 'CurrencyReserves', 'CustomRevert', 'SafeCast']]
    reference_paths += ['src/types/Currency.sol', 'src/types/BalanceDelta.sol', 'src/interfaces/external/IERC20Minimal.sol']
else:
    reference_paths = [f'src/libraries/{name}.sol' for name in ['Pool', 'SafeCast', 'TickBitmap', 'BitMath', 'Position', 'FullMath', 'FixedPoint128', 'FixedPoint96', 'TickMath', 'SqrtPriceMath', 'SwapMath', 'UnsafeMath', 'LiquidityMath', 'CustomRevert', 'ProtocolFeeLibrary', 'LPFeeLibrary']]
    reference_paths += [f'src/types/{name}.sol' for name in ['BalanceDelta', 'Slot0']]
if args.suite == 'protocol_fees':
    reference_paths += ['src/ProtocolFees.sol', 'src/libraries/CurrencyReserves.sol', 'src/libraries/Lock.sol']
    reference_paths += [p for p in manifest['sources'] if p.startswith(('src/types/', 'src/interfaces/'))]
    reference_paths = sorted(set(reference_paths))
for source_path in reference_paths:
    if reference_dir:
        data = (reference_dir / source_path).read_bytes()
    else:
        repository = 'transmissions11/solmate' if args.suite == 'owned' else 'Uniswap/v4-core'
        url = f'https://raw.githubusercontent.com/{repository}/{manifest["revision"]}/{source_path}'
        with urllib.request.urlopen(url, timeout=60) as response:
            data = response.read()
    if hashlib.sha256(data).hexdigest() != manifest['sources'][source_path]['sha256']:
        raise ValueError(f'Reference hash mismatch: {source_path}')
    destination = work / 'test/reference' / (Path(source_path).name if args.suite == 'math' else source_path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(data)
if args.suite in ['protocol_fees', 'manager', 'state_view', 'router_workflows', 'permissioned_router', 'permissioned_router_workflows', 'quoter', 'quoter_workflows', 'reserves_lens', 'permit_foundations', 'signature_verification', 'erc721_permit', 'multicall', 'native_wrapper', 'pool_initializer', 'notifier', 'permit2_forwarder', 'permit2_workflows', 'position_manager', 'permissioned_position_manager']:
    dependency = json.loads((ROOT / 'reference_manifest.json').read_text())['solmate']
    source = 'src/auth/Owned.sol'
    if args.reference_solmate:
        data = (args.reference_solmate / source).read_bytes()
    else:
        with urllib.request.urlopen(f'https://raw.githubusercontent.com/transmissions11/solmate/{dependency["revision"]}/{source}', timeout=60) as response:
            data = response.read()
    if hashlib.sha256(data).hexdigest() != dependency['sources'][source]['sha256']:
        raise ValueError('Reference hash mismatch: solmate Owned.sol')
    destination = work / 'test/reference/solmate' / source
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(data)
if args.suite in ['erc721_permit', 'position_manager', 'permissioned_position_manager']:
    if not args.reference_solmate:
        parser.error('--reference-solmate is required for erc721_permit')
    source = 'src/tokens/ERC721.sol'
    data = (args.reference_solmate / source).read_bytes()
    if hashlib.sha256(data).hexdigest() != dependency['sources'][source]['sha256']:
        raise ValueError('Reference hash mismatch: solmate ERC721.sol')
    destination = work / 'test/reference/solmate' / source
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(data)
if args.suite in PERIPHERY_SUITES:
    periphery = json.loads((ROOT / 'reference_manifest.json').read_text())['v4-periphery']
    names = ['LiquidityAmounts', 'SlippageCheck', 'BipsLibrary'] if args.suite == 'periphery_math' else ['PositionInfoLibrary', 'PathKey']
    sources = [f'src/libraries/{name}.sol' for name in names]
    if args.suite in ['descriptor', 'position_descriptor', 'deployer_competition', 'permission_foundations', 'permissions_adapter', 'permissions_factory', 'svg', 'descriptor_format']:
        sources = [f'src/libraries/{n}.sol' for n in ['Descriptor', 'SVG', 'HexStrings']]
    if args.suite == 'permission_foundations':
        sources = ['src/hooks/permissionedPools/' + p for p in ['BaseAllowListChecker.sol', 'interfaces/IAllowlistChecker.sol', 'libraries/PermissionFlags.sol']]
    if args.suite in ['permissions_adapter', 'permissions_factory']:
        sources = ['src/hooks/permissionedPools/' + p for p in ['PermissionsAdapter.sol', 'PermissionsAdapterFactory.sol', 'interfaces/IPermissionsAdapter.sol', 'interfaces/IPermissionsAdapterFactory.sol', 'interfaces/IAllowlistChecker.sol', 'libraries/PermissionFlags.sol']]
    if args.suite == 'deployer_competition':
        sources = ['src/UniswapV4DeployerCompetition.sol', 'src/interfaces/IUniswapV4DeployerCompetition.sol', 'src/libraries/VanityAddressLib.sol']
    if args.suite == 'position_descriptor':
        sources = ['src/PositionDescriptor.sol']
        sources += [f'src/interfaces/{n}.sol' for n in ['IPositionDescriptor', 'IPositionManager', 'INotifier', 'IImmutableState', 'IERC721Permit_v4', 'IEIP712_v4', 'IMulticall_v4', 'IPoolInitializer_v4', 'IUnorderedNonce', 'IPermit2Forwarder', 'ISubscriber']]
        sources += [f'src/libraries/{n}.sol' for n in ['Descriptor', 'SVG', 'HexStrings', 'CurrencyRatioSortOrder', 'SafeCurrencyMetadata', 'AddressStringUtil', 'PositionInfoLibrary']]
    if args.suite == 'currency_metadata':
        sources = ['src/libraries/SafeCurrencyMetadata.sol', 'src/libraries/AddressStringUtil.sol']
    if args.suite == 'periphery_aux':
        sources = [f'src/libraries/{name}.sol' for name in ['PositionConfig', 'PositionConfigId', 'VanityAddressLib', 'AddressStringUtil']]
    if args.suite == 'state_view':
        sources = ['src/lens/StateView.sol', 'src/base/ImmutableState.sol', 'src/interfaces/IStateView.sol', 'src/interfaces/IImmutableState.sol']
    if args.suite == 'calldata_decoder':
        sources = ['src/libraries/CalldataDecoder.sol', 'src/libraries/PathKey.sol', 'src/interfaces/IV4Router.sol', 'src/interfaces/IImmutableState.sol']
    if args.suite in ['delta_resolver', 'payments', 'router', 'router_workflows', 'permissioned_router', 'permissioned_router_workflows']:
        sources = ['src/base/DeltaResolver.sol', 'src/base/ImmutableState.sol', 'src/interfaces/IImmutableState.sol', 'src/libraries/ActionConstants.sol']
    if args.suite in ['router', 'router_workflows', 'permissioned_router', 'permissioned_router_workflows']:
        sources += ['src/V4Router.sol', 'src/base/BaseActionsRouter.sol', 'src/base/SafeCallback.sol', 'src/libraries/Actions.sol', 'src/libraries/BipsLibrary.sol', 'src/libraries/CalldataDecoder.sol', 'src/libraries/PathKey.sol', 'src/interfaces/IV4Router.sol', 'src/interfaces/IMsgSender.sol']
    if args.suite in ['router_workflows', 'permissioned_router_workflows']:
        sources += ['src/base/ReentrancyLock.sol', 'src/libraries/Locker.sol']
    if args.suite in ['permissioned_router', 'permissioned_router_workflows']:
        sources += ['src/hooks/permissionedPools/' + p for p in ['PermissionedV4Router.sol', 'interfaces/IPermissionsAdapter.sol', 'interfaces/IPermissionsAdapterFactory.sol', 'interfaces/IAllowlistChecker.sol', 'libraries/PermissionFlags.sol']]
    if args.suite == 'permissioned_router_workflows':
        sources += ['src/hooks/permissionedPools/PermissionsAdapter.sol', 'src/hooks/permissionedPools/PermissionsAdapterFactory.sol']
    if args.suite in ['quoter', 'quoter_workflows']:
        sources = ['src/lens/V4Quoter.sol', 'src/base/BaseV4Quoter.sol', 'src/base/SafeCallback.sol', 'src/base/ImmutableState.sol', 'src/libraries/QuoterRevert.sol', 'src/libraries/Locker.sol', 'src/libraries/PathKey.sol', 'src/interfaces/IV4Quoter.sol', 'src/interfaces/IImmutableState.sol', 'src/interfaces/IMsgSender.sol']
    if args.suite == 'reserves_lens':
        sources = ['src/lens/ReservesLens.sol', 'src/interfaces/IReservesLens.sol', 'src/interfaces/external/IHookStats.sol']
    if args.suite == 'permit_foundations':
        sources = ['src/base/EIP712_v4.sol', 'src/base/UnorderedNonce.sol', 'src/libraries/ERC721PermitHash.sol', 'src/interfaces/IEIP712_v4.sol', 'src/interfaces/IUnorderedNonce.sol']
    if args.suite == 'signature_verification':
        sources = []
    if args.suite in ['permit2_forwarder', 'permit2_workflows']:
        sources = ['src/base/Permit2Forwarder.sol', 'src/interfaces/IPermit2Forwarder.sol']
    if args.suite == 'notifier':
        sources = ['src/base/Notifier.sol', 'src/interfaces/INotifier.sol', 'src/interfaces/ISubscriber.sol', 'src/libraries/PositionInfoLibrary.sol']
    if args.suite == 'pool_initializer':
        sources = ['src/base/PoolInitializer_v4.sol', 'src/base/ImmutableState.sol', 'src/interfaces/IImmutableState.sol', 'src/interfaces/IPoolInitializer_v4.sol']
    if args.suite == 'native_wrapper':
        sources = ['src/base/NativeWrapper.sol', 'src/base/ImmutableState.sol', 'src/interfaces/IImmutableState.sol', 'src/interfaces/external/IWETH9.sol', 'src/libraries/ActionConstants.sol']
    if args.suite == 'multicall':
        sources = ['src/base/Multicall_v4.sol', 'src/interfaces/IMulticall_v4.sol']
    if args.suite == 'erc721_permit':
        sources = ['src/base/ERC721Permit_v4.sol', 'src/base/EIP712_v4.sol', 'src/base/UnorderedNonce.sol', 'src/libraries/ERC721PermitHash.sol', 'src/interfaces/IEIP712_v4.sol', 'src/interfaces/IUnorderedNonce.sol', 'src/interfaces/IERC721Permit_v4.sol']
    if args.suite in ['position_manager', 'permissioned_position_manager']:
        sources = ['src/PositionManager.sol',
         'src/base/BaseActionsRouter.sol',
         'src/base/DeltaResolver.sol',
         'src/base/EIP712_v4.sol',
         'src/base/ERC721Permit_v4.sol',
         'src/base/ImmutableState.sol',
         'src/base/Multicall_v4.sol',
         'src/base/NativeWrapper.sol',
         'src/base/Notifier.sol',
         'src/base/Permit2Forwarder.sol',
         'src/base/PoolInitializer_v4.sol',
         'src/base/ReentrancyLock.sol',
         'src/base/SafeCallback.sol',
         'src/base/UnorderedNonce.sol',
         'src/interfaces/IEIP712_v4.sol',
         'src/interfaces/IERC721Permit_v4.sol',
         'src/interfaces/IImmutableState.sol',
         'src/interfaces/IMsgSender.sol',
         'src/interfaces/IMulticall_v4.sol',
         'src/interfaces/INotifier.sol',
         'src/interfaces/IPermit2Forwarder.sol',
         'src/interfaces/IPoolInitializer_v4.sol',
         'src/interfaces/IPositionDescriptor.sol',
         'src/interfaces/IPositionManager.sol',
         'src/interfaces/ISubscriber.sol',
         'src/interfaces/IUnorderedNonce.sol',
         'src/interfaces/IV4Router.sol',
         'src/interfaces/external/IWETH9.sol',
         'src/libraries/ActionConstants.sol',
         'src/libraries/Actions.sol',
         'src/libraries/CalldataDecoder.sol',
         'src/libraries/ERC721PermitHash.sol',
         'src/libraries/LiquidityAmounts.sol',
         'src/libraries/Locker.sol',
         'src/libraries/PathKey.sol',
         'src/libraries/PositionInfoLibrary.sol',
         'src/libraries/SlippageCheck.sol']
    if args.suite == 'permissioned_position_manager':
        sources += ['src/hooks/permissionedPools/' + name for name in ['PermissionedPositionManager.sol', 'PermissionsAdapter.sol', 'PermissionsAdapterFactory.sol', 'interfaces/IPermissionsAdapter.sol', 'interfaces/IPermissionsAdapterFactory.sol', 'interfaces/IAllowlistChecker.sol', 'libraries/PermissionFlags.sol']]
    for source in sources:
        if args.reference_periphery:
            data = (args.reference_periphery / source).read_bytes()
        else:
            with urllib.request.urlopen(f'https://raw.githubusercontent.com/Uniswap/v4-periphery/{periphery["revision"]}/{source}', timeout=60) as response:
                data = response.read()
        if hashlib.sha256(data).hexdigest() != periphery['sources'][source]['sha256']:
            raise ValueError(f'Reference hash mismatch: {source}')
        destination = work / 'test/periphery' / source
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)
shutil.copyfile(ROOT / 'tests/solidity' / test_file, work / 'test' / test_file)
for license_name in ['LICENSE-MIT', 'LICENSE-BUSL-1.1', 'LICENSE-AGPL-3.0-only']:
    shutil.copyfile(ROOT / license_name, work / license_name)
if args.suite in ['permissions_adapter', 'permissions_factory', 'permissioned_router_workflows', 'permissioned_position_manager']:
    dependency = json.loads((ROOT / 'reference_manifest.json').read_text())['solmate']
    if not args.reference_solmate:
        parser.error('--reference-solmate is required for permissions suites')
    for source in ['src/tokens/ERC20.sol', 'src/utils/SafeTransferLib.sol']:
        data = (args.reference_solmate / source).read_bytes()
        if hashlib.sha256(data).hexdigest() != dependency['sources'][source]['sha256']:
            raise ValueError('Reference hash mismatch: solmate ' + source)
        destination = work / 'test/reference/solmate' / source
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)
openzeppelin = None
if args.suite in ['permissioned_router', 'permissioned_router_workflows', 'reserves_lens', 'native_wrapper', 'position_manager', 'permissioned_position_manager', 'currency_metadata', 'descriptor_format', 'descriptor', 'position_descriptor', 'deployer_competition', 'permission_foundations', 'permissions_adapter', 'permissions_factory', 'svg']:
    openzeppelin = json.loads((ROOT / 'reference_manifest.json').read_text())['openzeppelin']
    if not args.reference_openzeppelin:
        parser.error('--reference-openzeppelin is required for this suite')
    for source, record in openzeppelin['sources'].items():
        data = (args.reference_openzeppelin / source).read_bytes()
        if hashlib.sha256(data).hexdigest() != record['sha256']:
            raise ValueError(f'OpenZeppelin reference source hash mismatch: {source}')
        destination = work / 'test/reference/openzeppelin' / source
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)
permit2 = None
if args.suite in ['position_descriptor', 'signature_verification', 'erc721_permit', 'permit2_forwarder', 'permit2_workflows', 'position_manager', 'permissioned_position_manager']:
    permit2 = json.loads((ROOT / 'reference_manifest.json').read_text())['permit2']
    if not args.reference_permit2:
        parser.error('--reference-permit2 is required for this suite')
    for source, record in permit2['sources'].items():
        data = (args.reference_permit2 / source).read_bytes()
        if hashlib.sha256(data).hexdigest() != record['sha256']:
            raise ValueError(f'Permit2 reference source hash mismatch: {source}')
        destination = work / 'test/permit2' / source
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)
permit2_reference = None
if args.suite in ['permit2_workflows', 'position_manager', 'permissioned_position_manager', 'permissioned_router_workflows', 'router_workflows']:
    if not args.permit2_artifact:
        parser.error('--permit2-artifact is required for this suite')
    raw = (args.permit2_artifact / 'validation.json').read_bytes()
    permit2_reference = json.loads(raw)
    dep_manifest = json.loads((ROOT / 'reference_manifest.json').read_text())
    reference = dep_manifest['permit2']
    reference_solmate = dep_manifest['permit2-solmate']
    expected_sources = {source: record['sha256'] for source, record in reference['runtime_sources'].items()}
    expected_sources.update({'vendor/solmate/' + source: record['sha256'] for source, record in reference_solmate['sources'].items()})
    if (permit2_reference['result'] != 'compiled'
        or permit2_reference['permit2_revision'] != reference['revision']
        or permit2_reference['solmate_revision'] != reference_solmate['revision']
        or permit2_reference['compiler_settings'] != reference['runtime_compiler']
        or permit2_reference['compiler_sha256'] != reference['runtime_compiler']['sha256']
        or permit2_reference['sources'] != expected_sources):
        raise ValueError('Permit2 reference artifact provenance mismatch')
    code = bytes.fromhex((args.permit2_artifact / 'permit2-bytecode.txt').read_text().strip().removeprefix('0x'))
    if hashlib.sha256(code).hexdigest() != permit2_reference['creation_bytecode_sha256']:
        raise ValueError('Permit2 reference bytecode hash mismatch')
    (work / 'permit2-bytecode.txt').write_text('0x' + code.hex())
    permit2_reference['validation_sha256'] = hashlib.sha256(raw).hexdigest()
solc_version = '0.8.26' if args.suite in ['manager', 'state_view', 'router', 'router_workflows', 'permissioned_router', 'permissioned_router_workflows', 'quoter', 'quoter_workflows', 'reserves_lens', 'permit_foundations', 'signature_verification', 'erc721_permit', 'multicall', 'native_wrapper', 'pool_initializer', 'notifier', 'permit2_forwarder', 'permit2_workflows', 'position_manager', 'permissioned_position_manager', 'periphery_aux', 'currency_metadata', 'descriptor_format', 'descriptor', 'position_descriptor', 'deployer_competition', 'permission_foundations', 'permissions_adapter', 'permissions_factory', 'svg'] else '0.8.30'
# The pinned SVG library exceeds solc 0.8.26's optimized Yul stack limit.
# Keep its sources unchanged and use unoptimized via-IR for this oracle.
solc_optimizer = args.suite not in ['svg', 'descriptor', 'position_descriptor']
solc_setting = args.solc or solc_version
(work / 'foundry.toml').write_text('''[profile.default]
src = "src"
test = "test"
remappings = ["permit2/=test/permit2/", "solmate/=test/reference/solmate/", "@uniswap/v4-core/=test/reference/"]
solc_version = "0.8.30"
evm_version = "cancun"
optimizer = true
optimizer_runs = 200
fs_permissions = [{ access = "read", path = "./permissions-factory-bytecode.txt" }, { access = "read", path = "./fe-bytecode.txt" }, { access = "read", path = "./manager-bytecode.txt" }, { access = "read", path = "./permit2-bytecode.txt" }, { access = "read", path = "./descriptor-bytecode.txt" }, { access = "read", path = "./descriptor-reference-bytecode.txt" }]
[profile.default.fuzz]
seed = "0x554e495634"
'''.replace('optimizer = true', 'optimizer = ' + str(solc_optimizer).lower()).replace('solc_version = "0.8.30"', 'solc = ' + json.dumps(solc_setting)).replace('optimizer_runs = 200', 'optimizer_runs = 200\nvia_ir = true' if args.suite in ['descriptor', 'position_descriptor', 'deployer_competition', 'permission_foundations', 'permissions_adapter', 'permissions_factory', 'svg', 'descriptor_format', 'currency_metadata', 'periphery_aux', 'pool', 'hooks', 'claims', 'owned', 'protocol_fees', 'manager', 'state_view', 'calldata_decoder', 'router', 'router_workflows', 'permissioned_router', 'permissioned_router_workflows', 'quoter', 'quoter_workflows', 'reserves_lens', 'permit_foundations', 'signature_verification', 'erc721_permit', 'multicall', 'native_wrapper', 'pool_initializer', 'notifier', 'permit2_forwarder', 'permit2_workflows', 'position_manager', 'permissioned_position_manager'] else 'optimizer_runs = 200'))
if openzeppelin is not None:
    config = (work / 'foundry.toml').read_text().replace('remappings = [', 'remappings = ["@openzeppelin/=test/reference/openzeppelin/", "openzeppelin-contracts/=test/reference/openzeppelin/", ')
    (work / 'foundry.toml').write_text(config)
if args.suite in ['permissioned_router_workflows', 'position_manager', 'permissioned_position_manager', 'descriptor', 'position_descriptor', 'deployer_competition', 'permission_foundations', 'permissions_adapter', 'permissions_factory', 'svg']:
    config = (work / 'foundry.toml').read_text().replace('[profile.default]\n', '[profile.default]\ncode_size_limit = 200000\n')
    (work / 'foundry.toml').write_text(config)
manager_evidence = None
if args.suite in ['router_workflows', 'permissioned_router_workflows', 'quoter_workflows', 'position_manager', 'permissioned_position_manager']:
    if not args.manager_artifact:
        parser.error('--manager-artifact is required for workflow suites')
    artifact = args.manager_artifact
    manager_raw = (artifact / 'validation.json').read_bytes()
    manager_evidence = json.loads(manager_raw)
    if manager_evidence['result'] != 'passed' or manager_evidence['compiler_sha256'] != compiler_hash:
        raise ValueError('PoolManager artifact is not validated with the current compiler')
    if manager_evidence['optimization'] != args.optimize:
        raise ValueError('PoolManager artifact optimization differs from workflow optimization')
    for path, digest in manager_evidence['sources'].items():
        if hashlib.sha256((ROOT / path).read_bytes()).hexdigest() != digest:
            raise ValueError(f'PoolManager artifact source changed: {path}')
    manager_code = (artifact / 'fe-bytecode.txt').read_text().strip()
    if hashlib.sha256(bytes.fromhex(manager_code.removeprefix('0x'))).hexdigest() != manager_evidence['creation_bytecode_sha256']:
        raise ValueError('PoolManager bytecode does not match its validation record')
    (work / 'manager-bytecode.txt').write_text(manager_code)
    (work / 'manager-validation.json').write_bytes(manager_raw)
factory_evidence = None
if args.suite in ['permissioned_router_workflows', 'permissioned_position_manager']:
    if not args.permissions_factory_artifact:
        parser.error('--permissions-factory-artifact is required for permissioned workflows')
    artifact = args.permissions_factory_artifact.resolve()
    factory_raw = (artifact / 'validation.json').read_bytes()
    factory_evidence = json.loads(factory_raw)
    if factory_evidence['result'] != 'passed' or factory_evidence['suite'] != 'permissions_factory':
        raise ValueError('Factory artifact is not a passed PermissionsAdapterFactory suite')
    if factory_evidence['compiler_sha256'] != compiler_hash or factory_evidence['optimization'] != args.optimize:
        raise ValueError('Factory compiler or optimization mismatch')
    for name, digest in factory_evidence['sources'].items():
        if hashlib.sha256((ROOT / name).read_bytes()).hexdigest() != digest:
            raise ValueError('Factory source changed: ' + name)
    code = (artifact / 'fe-bytecode.txt').read_text().strip()
    if hashlib.sha256(bytes.fromhex(code.removeprefix('0x'))).hexdigest() != factory_evidence['creation_bytecode_sha256']:
        raise ValueError('Factory creation bytecode hash mismatch')
    (work / 'permissions-factory-bytecode.txt').write_text(code)
    (work / 'permissions-factory-validation.json').write_bytes(factory_raw)
descriptor_evidence = None
if args.descriptor_artifact:
    if args.suite != 'position_manager':
        parser.error('--descriptor-artifact is only used by position_manager workflows')
    artifact = args.descriptor_artifact.resolve()
    raw = (artifact / 'validation.json').read_bytes()
    descriptor_evidence = json.loads(raw)
    if descriptor_evidence['result'] != 'passed' or descriptor_evidence['suite'] != 'position_descriptor':
        raise ValueError('Descriptor artifact is not a passed PositionDescriptor run')
    if descriptor_evidence['compiler_sha256'] != compiler_hash or descriptor_evidence['optimization'] != args.optimize:
        raise ValueError('Descriptor compiler or optimization differs from workflow build')
    for path, digest in descriptor_evidence['sources'].items():
        if hashlib.sha256((ROOT / path).read_bytes()).hexdigest() != digest:
            raise ValueError(f'Descriptor artifact source changed: {path}')
    # Check the original Solidity source hashes against both the manifest and
    # compiler metadata before retaining its creation bytecode for deployment.
    subprocess.run([sys.executable, str(ROOT / 'tests/record_descriptor_reference.py'), str(artifact)], check=True)
    reference = json.loads((artifact / 'descriptor-reference.json').read_text())
    descriptor_code = (artifact / 'fe-bytecode.txt').read_text().strip()
    if hashlib.sha256(bytes.fromhex(descriptor_code.removeprefix('0x'))).hexdigest() != descriptor_evidence['creation_bytecode_sha256']:
        raise ValueError('Descriptor bytecode hash mismatch')
    (work / 'descriptor-bytecode.txt').write_text(descriptor_code)
    shutil.copyfile(artifact / 'descriptor-reference-bytecode.txt', work / 'descriptor-reference-bytecode.txt')
    shutil.copyfile(artifact / 'descriptor-reference.json', work / 'descriptor-reference.json')
    descriptor_evidence = {'validation_sha256': hashlib.sha256(raw).hexdigest(),
                           'validation': descriptor_evidence, 'solidity_reference': reference}
command = ['forge', 'test', '--root', str(work), '--fuzz-runs', str(args.runs), '-vv']
result = subprocess.run(command, cwd=work, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
print(result.stdout, end='', flush=True)
(work / 'forge-test.log').write_text(result.stdout)
(work / 'validation.json').write_text(json.dumps({
    'suite': args.suite,
    'build_full_ingot': args.build_full_ingot,
    'timestamp_utc': datetime.now(timezone.utc).isoformat(),
    'compiler_version': compiler_version,
    'compiler_source_checkout': str(args.fe_repo),
    'compiler_revision': compiler_revision,
    'compiler_sha256': compiler_hash,
    'compiler_worktree_diff_sha256': hashlib.sha256(compiler_diff).hexdigest(),
    'forge_version': subprocess.check_output(['forge', '--version'], text=True).strip(),
    'solc_version': solc_version,
    'solc_setting': solc_setting,
    'solc_optimizer': solc_optimizer,
    'solc_optimizer_runs': 200,
    'solc_via_ir': args.suite in ['descriptor', 'position_descriptor', 'deployer_competition', 'permission_foundations', 'permissions_adapter', 'permissions_factory', 'svg', 'descriptor_format', 'currency_metadata', 'periphery_aux', 'pool', 'hooks', 'claims', 'owned', 'protocol_fees', 'manager', 'state_view', 'calldata_decoder', 'router', 'router_workflows', 'permissioned_router', 'permissioned_router_workflows', 'quoter', 'quoter_workflows', 'reserves_lens', 'permit_foundations', 'signature_verification', 'erc721_permit', 'multicall', 'native_wrapper', 'pool_initializer', 'notifier', 'permit2_forwarder', 'permit2_workflows', 'position_manager', 'permissioned_position_manager'],
    'evm_version': 'cancun',
    'optimization': args.optimize,
    'fuzz_runs_per_property': args.runs,
    'fuzz_seed': '0x554e495634',
    'reference_revision': manifest['revision'],
    'periphery_revision': periphery['revision'] if args.suite in PERIPHERY_SUITES else None,
    'dependency_revisions': {'solmate': dependency['revision']} if args.suite in ['permissions_adapter', 'permissions_factory', 'protocol_fees', 'manager', 'state_view', 'router_workflows', 'permissioned_router', 'permissioned_router_workflows', 'quoter', 'quoter_workflows', 'reserves_lens', 'permit_foundations', 'signature_verification', 'erc721_permit', 'multicall', 'native_wrapper', 'pool_initializer', 'notifier', 'permit2_forwarder', 'permit2_workflows', 'position_manager', 'permissioned_position_manager'] else {},
    'openzeppelin_revision': openzeppelin['revision'] if openzeppelin else None,
    'permit2_revision': permit2['revision'] if permit2 else None,
    'permit2_reference_validation': permit2_reference,
    'manager_artifact_validation': manager_evidence,
    'permissions_factory_artifact_validation': factory_evidence,
    'descriptor_artifact_validation': descriptor_evidence,
    'reused_fe_build': reused_build,
    'sources': source_hashes,
    'test_source_sha256': hashlib.sha256((work / 'test' / test_file).read_bytes()).hexdigest(),
    'creation_bytecode_sha256': hashlib.sha256(bytes.fromhex(bytecode.removeprefix('0x'))).hexdigest(),
    'runtime_result': 'passed' if result.returncode == 0 else 'failed',
    'result': 'runtime_passed_abi_pending' if result.returncode == 0 else 'failed',
}, indent=2) + '\n')

result.check_returncode()

complete_validation(work)
