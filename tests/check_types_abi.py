#!/usr/bin/env python3
"""Check structured Pool type ABI shapes; record the known mutability limitation."""
import argparse
import hashlib
import json
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('parity_dir', type=Path)
args = parser.parse_args()
work = args.parity_dir
fe_path = work / 'fe/TypesHarness.abi.json'
sol_path = work / 'out/TypesParity.t.sol/SolidityTypesHarness.json'
fe = json.loads(fe_path.read_text())
sol = json.loads(sol_path.read_text())['abi']

def clean(value):
    if isinstance(value, list):
        return [clean(item) for item in value]
    if isinstance(value, dict):
        return {key: clean(item) for key, item in value.items() if key != 'internalType'}
    return value

expected = {entry['name']: clean(entry) for entry in sol if entry['type'] == 'function'}
actual = {entry['name']: clean(entry) for entry in fe if entry['type'] == 'function'}
assert actual.keys() == expected.keys()
differences = []
for name, reference in expected.items():
    emitted = actual[name]
    assert emitted['inputs'] == reference['inputs'], (name, 'inputs')
    assert emitted['outputs'] == reference['outputs'], (name, 'outputs')
    if emitted['stateMutability'] != reference['stateMutability']:
        differences.append({'name': name, 'fe': emitted['stateMutability'], 'solidity': reference['stateMutability']})
assert differences == [{'name': 'poolId', 'fe': 'nonpayable', 'solidity': 'pure'}], differences
record = {
    'parameter_and_return_shapes': 'passed',
    'full_abi_parity': False,
    'remaining_mutability_differences': differences,
    'fe_abi_sha256': hashlib.sha256(fe_path.read_bytes()).hexdigest(),
    'solidity_artifact_sha256': hashlib.sha256(sol_path.read_bytes()).hexdigest(),
    'checker_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
}
(work / 'abi-audit.json').write_text(json.dumps(record, indent=2) + '\n')
print('PASS: all parameter/return names, types and components match; known poolId mutability mismatch retained')
