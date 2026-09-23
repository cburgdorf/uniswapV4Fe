#!/usr/bin/env python3
"""Compare ERC6909 event JSON, including parameter names/order and indexed flags."""
import argparse
import hashlib
import json
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('parity_dir', type=Path)
args = parser.parse_args()
work = args.parity_dir
fe_path = work / 'fe/ClaimsHarness.abi.json'
sol_path = work / 'out/ClaimsParity.t.sol/SolidityClaimsHarness.json'
fe = json.loads(fe_path.read_text())
sol = json.loads(sol_path.read_text())['abi']

def clean(value):
    if isinstance(value, list):
        return [clean(item) for item in value]
    if isinstance(value, dict):
        return {key: clean(item) for key, item in value.items() if key != 'internalType'}
    return value

expected = {e['name']: clean(e) for e in sol if e['type'] == 'event'}
actual = {e['name']: clean(e) for e in fe if e['type'] == 'event'}
assert actual == expected, (actual, expected)
assert set(actual) == {'Transfer', 'Approval', 'OperatorSet'}
reference_functions = {e['name']: clean(e) for e in sol if e['type'] == 'function'}
function_differences = []
for entry in fe:
    if entry['type'] != 'function':
        continue
    reference = reference_functions[entry['name']]
    if clean(entry) != reference:
        function_differences.append({'name': entry['name'], 'fe': clean(entry), 'solidity': reference})
record = {
    'event_abi': 'passed', 'event_names': sorted(actual),
    'full_abi_parity': False, 'remaining_function_metadata_differences': function_differences,
    'fe_abi_sha256': hashlib.sha256(fe_path.read_bytes()).hexdigest(),
    'solidity_artifact_sha256': hashlib.sha256(sol_path.read_bytes()).hexdigest(),
    'checker_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
}
(work / 'event-abi-audit.json').write_text(json.dumps(record, indent=2) + '\n')
print('PASS: all three ERC6909 event ABI entries match; function metadata differences recorded separately')
