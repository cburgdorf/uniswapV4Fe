#!/usr/bin/env python3
"""Rerun an edited Solidity test against unchanged, hash-verified Fe artifacts."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
from protocol_abi_gate import complete_validation

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('artifacts', type=Path)
parser.add_argument('test', type=Path)
args = parser.parse_args()
work = args.artifacts.resolve()
root = Path(__file__).resolve().parents[1]
metadata_path = work / 'validation.json'
metadata = json.loads(metadata_path.read_text())
for source, expected in metadata['sources'].items():
    if hashlib.sha256((root / source).read_bytes()).hexdigest() != expected:
        raise ValueError(f'Fe source changed; rebuild required: {source}')
bytecode = bytes.fromhex((work / 'fe-bytecode.txt').read_text().strip().removeprefix('0x'))
if hashlib.sha256(bytecode).hexdigest() != metadata['creation_bytecode_sha256']:
    raise ValueError('Creation bytecode changed; rebuild required')
manager = metadata.get('manager_artifact_validation')
if manager is not None:
    for source, expected in manager['sources'].items():
        if hashlib.sha256((root / source).read_bytes()).hexdigest() != expected:
            raise ValueError(f'PoolManager source changed; rebuild required: {source}')
    code = bytes.fromhex((work / 'manager-bytecode.txt').read_text().strip().removeprefix('0x'))
    if hashlib.sha256(code).hexdigest() != manager['creation_bytecode_sha256']:
        raise ValueError('PoolManager bytecode changed; rebuild required')
factory = metadata.get('permissions_factory_artifact_validation')
if factory is not None:
    for source, expected in factory['sources'].items():
        if hashlib.sha256((root / source).read_bytes()).hexdigest() != expected:
            raise ValueError(f'Factory source changed; rebuild required: {source}')
    code = bytes.fromhex((work / 'permissions-factory-bytecode.txt').read_text().strip().removeprefix('0x'))
    if hashlib.sha256(code).hexdigest() != factory['creation_bytecode_sha256']:
        raise ValueError('Factory bytecode changed; rebuild required')
permit2 = metadata.get('permit2_reference_validation')
if permit2 is not None:
    code = bytes.fromhex((work / 'permit2-bytecode.txt').read_text().strip().removeprefix('0x'))
    if hashlib.sha256(code).hexdigest() != permit2['creation_bytecode_sha256']:
        raise ValueError('Permit2 reference bytecode changed; rebuild required')
descriptor = metadata.get('descriptor_artifact_validation')
if descriptor is not None:
    for source, expected in descriptor['validation']['sources'].items():
        if hashlib.sha256((root / source).read_bytes()).hexdigest() != expected:
            raise ValueError(f'Descriptor source changed; rebuild required: {source}')
    for name, expected in [
        ('descriptor-bytecode.txt', descriptor['validation']['creation_bytecode_sha256']),
        ('descriptor-reference-bytecode.txt', descriptor['solidity_reference']['creation_bytecode_sha256']),
    ]:
        code = bytes.fromhex((work / name).read_text().strip().removeprefix('0x'))
        if hashlib.sha256(code).hexdigest() != expected:
            raise ValueError(f'Descriptor bytecode changed; rebuild required: {name}')
# Preserve the previous result and test; never overwrite the only failure evidence.
stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
previous = work / ('before-retest-' + stamp)
previous.mkdir()
for name in ['validation.json', 'forge-test.log']:
    shutil.copyfile(work / name, previous / name)
shutil.copyfile(work / 'test' / args.test.name, previous / args.test.name)
# Invalidate the old success before changing the frozen fixture. A killed or
# failed-to-start retest must never leave a reusable-looking passed artifact.
metadata.update(result='runtime_pending', runtime_result='pending', protocol_abi_result='pending',
                timestamp_utc=datetime.now(timezone.utc).isoformat(), retested_existing_build=True)
metadata['test_source_sha256'] = hashlib.sha256(args.test.read_bytes()).hexdigest()
metadata_path.write_text(json.dumps(metadata, indent=2) + '\n')
shutil.copyfile(args.test, work / 'test' / args.test.name)
result = subprocess.run(['forge', 'test', '--root', str(work), '--fuzz-runs', str(metadata['fuzz_runs_per_property']), '-vv'], cwd=work, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
print(result.stdout, end='')
(work / 'forge-test.log').write_text(result.stdout)
metadata['test_source_sha256'] = hashlib.sha256((work / 'test' / args.test.name).read_bytes()).hexdigest()
metadata['timestamp_utc'] = datetime.now(timezone.utc).isoformat()
metadata['runtime_result'] = 'passed' if result.returncode == 0 else 'failed'
metadata['result'] = 'runtime_passed_abi_pending' if result.returncode == 0 else 'failed'
metadata['retested_existing_build'] = True
metadata_path.write_text(json.dumps(metadata, indent=2) + '\n')
result.check_returncode()

complete_validation(work)
