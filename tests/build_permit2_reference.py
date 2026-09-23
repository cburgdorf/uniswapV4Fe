#!/usr/bin/env python3
"""Build the pinned, unmodified Permit2 dependency with its Solidity 0.8.17 compiler."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--reference-permit2', required=True, type=Path)
p.add_argument('--reference-solmate', required=True, type=Path)
p.add_argument('--solc', required=True, type=Path)
p.add_argument('--work-dir', required=True, type=Path)
a = p.parse_args()
manifest = json.loads((ROOT / 'reference_manifest.json').read_text())
permit2, solmate = manifest['permit2'], manifest['permit2-solmate']
settings = permit2['runtime_compiler']
compiler_hash = hashlib.sha256(a.solc.read_bytes()).hexdigest()
if compiler_hash != settings['sha256']:
    raise ValueError('Pinned Permit2 solc binary hash mismatch')
work = a.work_dir.resolve()
work.mkdir(parents=True)
source_hashes = {}
for origin, records, prefix in [(a.reference_permit2, permit2['runtime_sources'], Path('.')),
                                (a.reference_solmate, solmate['sources'], Path('vendor/solmate'))]:
    for source, record in records.items():
        data = (origin / source).read_bytes()
        digest = hashlib.sha256(data).hexdigest()
        if digest != record['sha256']:
            raise ValueError(f'Reference source hash mismatch: {source}')
        target = work / prefix / source
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        source_hashes[str(prefix / source)] = digest
config = f'''[profile.default]
src = "src"
solc = {json.dumps(str(a.solc.resolve()))}
remappings = ["solmate/=vendor/solmate/"]
optimizer = true
optimizer_runs = 1000000
via_ir = true
evm_version = "london"
bytecode_hash = "none"
'''
(work / 'foundry.toml').write_text(config)
result = subprocess.run(['forge', 'build', '--root', str(work)], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
(work / 'build.log').write_text(result.stdout)
print(result.stdout, end='')
result.check_returncode()
artifact = json.loads((work / 'out/Permit2.sol/Permit2.json').read_text())
code = bytes.fromhex(artifact['bytecode']['object'].removeprefix('0x'))
(work / 'permit2-bytecode.txt').write_text('0x' + code.hex())
record = {'result': 'compiled', 'timestamp_utc': datetime.now(timezone.utc).isoformat(),
          'permit2_revision': permit2['revision'], 'solmate_revision': solmate['revision'],
          'compiler_settings': settings, 'compiler_sha256': compiler_hash,
          'compiler_version': subprocess.check_output([str(a.solc.resolve()), '--version'], text=True).strip(),
          'forge_version': subprocess.check_output(['forge', '--version'], text=True).strip(),
          'sources': source_hashes, 'creation_bytecode_sha256': hashlib.sha256(code).hexdigest(),
          'runtime_bytes': len(bytes.fromhex(artifact['deployedBytecode']['object'].removeprefix('0x')))}
(work / 'validation.json').write_text(json.dumps(record, indent=2) + '\n')
print(f'Pinned Permit2 runtime: {record["runtime_bytes"]} bytes; artifacts: {work}')
