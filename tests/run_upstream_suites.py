#!/usr/bin/env python3
"""Run the unmodified upstream v4-core and v4-periphery Foundry suites against Fe.

The pinned upstream repositories are cloned (or reused), minimally patched so
that their deployment helpers take creation bytecode from $FE_ARTIFACTS when a
`<Contract>.bin` file exists (tests/upstream/*.patch), and then run with every
production contract replaced by its Fe build. Test logic is not modified.

The abstract V4Router and PermissionedV4Router are exercised through Fe ports
of the upstream concrete test mocks (src/upstream_test_mocks.fe). Other
test-only contracts stay Solidity (test routers, hooks, tokens, MockMulticall).
The Fe PoolManager backs every suite.

Each suite also runs once with the original Solidity contracts. The Fe run
passes only if every test has the same outcome as that baseline; tests that
already fail upstream are reported separately.

Requires Fe, forge (solc 0.8.26 is installed by forge) and git.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import os
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
PATCHES = ROOT / 'tests' / 'upstream'
CONTRACTS = [
    'PoolManager', 'PositionManager', 'PermissionedPositionManager', 'V4Router',
    'PermissionedV4Router', 'V4Quoter', 'StateView', 'ReservesLens', 'PositionDescriptor',
    'PermissionsAdapter', 'PermissionsAdapterFactory', 'UniswapV4DeployerCompetition',
    'MockV4Router', 'MockPermissionedRouter',
]
# Contracts the upstream suites deploy through the patched helpers.
DEPLOYED = {
    'v4-core': ['PoolManager'],
    'v4-periphery': ['PoolManager', 'PositionManager', 'PermissionedPositionManager', 'V4Quoter',
                     'StateView', 'ReservesLens', 'PositionDescriptor', 'PermissionsAdapter',
                     'PermissionsAdapterFactory', 'UniswapV4DeployerCompetition', 'MockV4Router',
                     'MockPermissionedRouter'],
}
# Fork tests need a live RPC endpoint.
EXCLUDED = {'v4-core': [], 'v4-periphery': ['test/ReservesLens.fork.t.sol']}

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--fe-repo', type=Path, default=ROOT.parent / 'fe')
parser.add_argument('--fe', type=Path, help='Compiler binary (default: <fe-repo>/target/release/fe)')
parser.add_argument('--work-dir', type=Path, required=True, help='New directory for clones, builds and logs')
parser.add_argument('--core', type=Path, help='Existing clean pinned v4-core clone with submodules')
parser.add_argument('--periphery', type=Path, help='Existing clean pinned v4-periphery clone with submodules')
parser.add_argument('--fe-artifacts', type=Path, help='Reuse a directory of Fe creation bytecode (<Contract>.bin)')
parser.add_argument('--fuzz-runs', type=int, default=1000)
parser.add_argument('--suite', choices=['v4-core', 'v4-periphery'], action='append')
args = parser.parse_args()
fe = (args.fe or args.fe_repo / 'target/release/fe').resolve()
work = args.work_dir.resolve()
work.mkdir(parents=True)
suites = args.suite or ['v4-core', 'v4-periphery']
manifest = json.loads((ROOT / 'reference_manifest.json').read_text())


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def run(cmd, **kw):
    print('+', ' '.join(map(str, cmd)), flush=True)
    return subprocess.run(cmd, check=True, **kw)


def checkout(name, existing):
    revision = manifest[name]['revision']
    target = work / name
    if existing:
        shutil.copytree(existing.resolve(), target, symlinks=True)
    else:
        run(['git', 'clone', '-q', f'https://github.com/Uniswap/{name}.git', target])
        run(['git', 'checkout', '-q', revision], cwd=target)
        run(['git', 'submodule', 'update', '--init', '--recursive', '-q'], cwd=target)
    head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=target, text=True).strip()
    if head != revision:
        raise SystemExit(f'{name}: HEAD {head} does not match pinned {revision}')
    return target


def apply(repo, patch):
    run(['git', 'apply', '--check', patch], cwd=repo)
    run(['git', 'apply', patch], cwd=repo)


# Fe build: production sources only (no harnesses or generated vectors).
if args.fe_artifacts:
    fe_out = args.fe_artifacts.resolve()
else:
    build_root = work / 'fe-production'
    (build_root / 'src').mkdir(parents=True)
    shutil.copy(ROOT / 'fe.toml', build_root)
    for source in sorted((ROOT / 'src').glob('*.fe')):
        if source.stem.endswith('_harness') or source.name in ['math_vectors.fe', 'math_reverts.fe']:
            continue
        shutil.copy(source, build_root / 'src')
    fe_out = work / 'fe-out'
    run([fe, 'build', build_root, '-O', '1', '--out-dir', fe_out])
sources = {str(p.relative_to(ROOT)): sha256(p) for p in sorted((ROOT / 'src').glob('*.fe'))}
creation = {}
for name in CONTRACTS:
    code = (fe_out / f'{name}.bin').read_text().strip().removeprefix('0x')
    bytes.fromhex(code)
    creation[name] = code

repos = {}
for name in suites:
    repo = checkout(name, args.core if name == 'v4-core' else args.periphery)
    apply(repo, PATCHES / f'{name}.patch')
    if name == 'v4-periphery':
        apply(repo / 'lib' / 'v4-core', PATCHES / 'v4-periphery-core-submodule.patch')
    artifacts = repo / 'fe-artifacts'
    artifacts.mkdir()
    for contract, code in creation.items():
        (artifacts / f'{contract}.bin').write_text('0x' + code)
    repos[name] = repo

# Guard against silently testing Solidity: every deployed contract must resolve to Fe bytecode.
probe_core = '''// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {Deployers} from "./utils/Deployers.sol";
contract FeArtifactProbeTest is Test, Deployers {
    function test_feArtifactsSelected() public {
        assertEq(keccak256(feCode("PoolManager")), keccak256(vm.parseBytes(vm.readFile("./fe-artifacts/PoolManager.bin"))));
        assertGt(feCode("PoolManager").length, 0);
    }
}
'''
probe_periphery_checks = '\n'.join(
    f'        assertEq(keccak256(Deploy.getCode("{c}.sol:{c}")), keccak256(vm.parseBytes(vm.readFile("./fe-artifacts/{c}.bin"))));'
    for c in DEPLOYED['v4-periphery'])
probe_periphery = f'''// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;
import {{Test}} from "forge-std/Test.sol";
import {{Deploy}} from "./shared/Deploy.sol";
contract FeArtifactProbeTest is Test {{
    function test_feArtifactsSelected() public {{
{probe_periphery_checks}
    }}
}}
'''
if 'v4-core' in repos:
    (repos['v4-core'] / 'test' / 'FeArtifactProbe.t.sol').write_text(probe_core)
if 'v4-periphery' in repos:
    (repos['v4-periphery'] / 'test' / 'FeArtifactProbe.t.sol').write_text(probe_periphery)

def forge(repo, name, label, fe_enabled):
    cmd = ['forge', 'test', '--fuzz-runs', str(args.fuzz_runs), '--json']
    for path in EXCLUDED[name]:
        cmd += ['--no-match-path', path]
    env = dict(os.environ)
    env.pop('FE_ARTIFACTS', None)
    if fe_enabled:
        env['FE_ARTIFACTS'] = './fe-artifacts'
    else:
        cmd += ['--no-match-contract', 'FeArtifactProbeTest']
    log = work / f'{name}-{label}.json'
    print('+', ' '.join(cmd), f'({label})', flush=True)
    with open(log, 'w') as out:
        proc = subprocess.run(cmd, cwd=repo, env=env, stdout=out, stderr=subprocess.PIPE, text=True)
    text = log.read_text()
    start = text.find('{')
    report = json.loads(text[start:]) if start >= 0 else {}
    outcomes = {}
    for suite, data in report.items():
        for test, result in data['test_results'].items():
            status = {'Success': 'passed', 'Failure': 'failed', 'Skipped': 'skipped'}[result['status']]
            outcomes[f'{suite}::{test}'] = {'status': status, 'reason': result.get('reason')}
    return proc, outcomes


def tally(outcomes):
    counts = {'passed': 0, 'failed': 0, 'skipped': 0}
    for outcome in outcomes.values():
        counts[outcome['status']] += 1
    return counts


results = {}
for name, repo in repos.items():
    base_proc, baseline = forge(repo, name, 'solidity', False)
    fe_proc, fe_outcomes = forge(repo, name, 'fe', True)
    probe = [k for k in fe_outcomes if ':FeArtifactProbeTest::' in k]
    probe_passed = len(probe) == 1 and fe_outcomes[probe[0]]['status'] == 'passed'
    compared = {k: v for k, v in fe_outcomes.items() if k not in probe}
    missing = sorted(set(baseline) - set(compared))
    extra = sorted(set(compared) - set(baseline))
    mismatches = [{'test': k, 'solidity': baseline[k], 'fe': v} for k, v in sorted(compared.items())
                  if k in baseline and v['status'] != baseline[k]['status']]
    # Fuzz dictionaries include deployed bytecode constants, so counterexamples may differ.
    upstream_failures = [{'test': k, 'solidity_reason': v['reason'], 'fe_reason': compared[k]['reason']}
                         for k, v in sorted(baseline.items())
                         if v['status'] == 'failed' and k in compared and compared[k]['status'] == 'failed']
    results[name] = {
        'revision': manifest[name]['revision'],
        'patches_sha256': {p.name: sha256(p) for p in sorted(PATCHES.glob('*.patch'))
                           if p.name.startswith(name)},
        'excluded_paths': EXCLUDED[name],
        'fe_contracts_deployed': DEPLOYED[name],
        'fe_artifact_probe_passed': probe_passed,
        'solidity_counts': tally(baseline),
        'fe_counts': tally(compared),
        'outcome_mismatches': mismatches,
        'missing_in_fe_run': missing,
        'extra_in_fe_run': extra,
        'upstream_failures_in_both': upstream_failures,
        'forge_stderr_tail': {'solidity': base_proc.stderr[-2000:], 'fe': fe_proc.stderr[-2000:]},
    }
    print(f"{name}: solidity={tally(baseline)} fe={tally(compared)} mismatches={len(mismatches)} "
          f"probe={probe_passed}", flush=True)

passed = all(r['fe_artifact_probe_passed'] and r['fe_counts']['passed'] > 0 and not r['outcome_mismatches']
             and not r['missing_in_fe_run'] and not r['extra_in_fe_run'] for r in results.values())
fe_repo = args.fe_repo.resolve()
validation = {
    'result': 'passed' if passed else 'failed',
    'completed_at': datetime.now(timezone.utc).isoformat(),
    'fuzz_runs': args.fuzz_runs,
    'optimization': '1',
    'compiler_version': subprocess.check_output([fe, '--version'], text=True).strip(),
    'compiler_sha256': sha256(fe),
    'compiler_revision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=fe_repo, text=True).strip(),
    'compiler_worktree_dirty': bool(subprocess.check_output(['git', 'status', '--porcelain', '--', 'crates', 'ingots'],
                                                             cwd=fe_repo, text=True).strip()),
    'fe_sources': sources,
    'creation_bytecode_sha256': {c: hashlib.sha256(bytes.fromhex(code)).hexdigest() for c, code in creation.items()},
    'runner_sha256': sha256(__file__),
    'forge_version': subprocess.check_output(['forge', '--version'], text=True).splitlines()[0],
    'upstream': results,
}
(work / 'validation.json').write_text(json.dumps(validation, indent=1) + '\n')
print(f"Result: {validation['result']} ({work / 'validation.json'})")
sys.exit(0 if passed else 1)
