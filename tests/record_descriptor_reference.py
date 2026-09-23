#!/usr/bin/env python3
"""Record the pinned Solidity Descriptor build for workflow artifact reuse."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('artifacts', type=Path)
args = parser.parse_args()
work = args.artifacts.resolve()
root = Path(__file__).resolve().parents[1]
validation_bytes = (work / 'validation.json').read_bytes()
validation = json.loads(validation_bytes)
if validation['suite'] != 'position_descriptor' or validation['result'] != 'passed':
    raise ValueError('A passed PositionDescriptor run is required')
manifest = json.loads((root / 'reference_manifest.json').read_text())
artifact = json.loads((work / 'out/PositionDescriptor.sol/PositionDescriptor.json').read_text())
# Forge normalizes remappings and drops some documentation fields in its
# parsed metadata view; use solc's original metadata as the source of truth.
metadata = json.loads(artifact['rawMetadata'])
if artifact['metadata']['compiler'] != metadata['compiler']:
    raise ValueError('Solidity compiler identities disagree')
if metadata['compiler']['version'] != '0.8.26+commit.8a97fa7a':
    raise ValueError('Unexpected reference compiler')
settings = metadata['settings']
if settings['optimizer']['enabled'] or not settings['viaIR'] or settings['evmVersion'] != 'cancun':
    raise ValueError('Unexpected reference compiler settings')
prefixes = {'test/periphery/': 'v4-periphery', 'test/reference/openzeppelin/': 'openzeppelin',
            'test/permit2/': 'permit2', 'test/reference/': 'v4-core'}
sources = {}
for path, record in metadata['sources'].items():
    repo, relative = next((repo, path[len(prefix):]) for prefix, repo in prefixes.items() if path.startswith(prefix))
    expected = manifest[repo]['sources'][relative]['sha256']
    source = (work / path).read_bytes()
    digest = hashlib.sha256(source).hexdigest()
    if digest != expected:
        raise ValueError(f'Unpinned source: {path}')
    if subprocess.check_output(['cast', 'keccak'], input=source).decode().strip() != record['keccak256']:
        raise ValueError(f'Compiler source hash mismatch: {path}')
    sources[path] = digest
# Source metadata alone cannot authenticate a mutated bytecode object. Rebuild
# the hash-checked reference input and require the artifact to reproduce exactly.
if hashlib.sha256((work / 'test/PositionDescriptorParity.t.sol').read_bytes()).hexdigest() != validation['test_source_sha256']:
    raise ValueError('Descriptor oracle changed since the passed run')
build = subprocess.run(['forge', 'build', '--force', '--root', str(work)],
                       cwd=work, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
(work / 'descriptor-reference-build.log').write_text(build.stdout)
build.check_returncode()
rebuilt = json.loads((work / 'out/PositionDescriptor.sol/PositionDescriptor.json').read_text())
if rebuilt['bytecode']['object'] != artifact['bytecode']['object']:
    raise ValueError('Solidity Descriptor bytecode does not reproduce from its pinned inputs')
code = artifact['bytecode']['object'].removeprefix('0x')
record = {'validation_sha256': hashlib.sha256(validation_bytes).hexdigest(),
          'periphery_revision': manifest['v4-periphery']['revision'],
          'compiler': metadata['compiler'], 'settings': settings, 'sources': sources,
          'creation_bytecode_sha256': hashlib.sha256(bytes.fromhex(code)).hexdigest()}
(work / 'descriptor-reference-bytecode.txt').write_text('0x' + code)
(work / 'descriptor-reference.json').write_text(json.dumps(record, indent=2) + '\n')
print(f'Verified {len(sources)} pinned reference sources; recorded Solidity Descriptor creation bytecode')
