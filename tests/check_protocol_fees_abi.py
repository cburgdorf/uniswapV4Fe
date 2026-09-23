#!/usr/bin/env python3
"""Check protocol fee ABI shapes/events; record remaining metadata differences."""
import argparse
import hashlib
import json
from pathlib import Path
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('parity_dir', type=Path)
work = parser.parse_args().parity_dir
fe_path = work / 'fe/ProtocolFeesHarness.abi.json'
sol_path = work / 'out/ProtocolFeesParity.t.sol/SolidityProtocolFeesHarness.json'
def clean(value):
    if isinstance(value, list): return [clean(item) for item in value]
    if isinstance(value, dict): return {k: clean(v) for k, v in value.items() if k != 'internalType'}
    return value
fe = {(v['type'], v.get('name', '')): clean(v) for v in json.loads(fe_path.read_text())}
sol = {(v['type'], v.get('name', '')): clean(v) for v in json.loads(sol_path.read_text())['abi']}
missing = sorted(set(sol) - set(fe))
assert missing == [('error', 'InvalidCaller'), ('error', 'ProtocolFeeCurrencySynced'), ('error', 'ProtocolFeeTooLarge')], missing
assert not set(fe) - set(sol)
differences = []
for key, actual in fe.items():
    expected = sol[key]
    if actual != expected:
        differences.append({'entry': key, 'fe': actual, 'solidity': expected})
        if key == ('function', 'protocolFeesAccrued'):
            assert actual['stateMutability'] == 'nonpayable' and expected['stateMutability'] == 'view'
            actual['stateMutability'] = 'view'
            assert actual['outputs'][0]['name'] == '' and expected['outputs'][0]['name'] == 'amount'
            actual['outputs'][0]['name'] = 'amount'
        elif key == ('function', 'collectProtocolFees'):
            assert actual['outputs'][0]['name'] == '' and expected['outputs'][0]['name'] == 'amountCollected'
            actual['outputs'][0]['name'] = 'amountCollected'
        else:
            raise AssertionError((key, actual, expected))
        assert actual == expected, (key, actual, expected)
# Reload originals for an unmodified diagnostic record.
original = {(v['type'], v.get('name', '')): clean(v) for v in json.loads(fe_path.read_text())}
for d in differences: d['fe'] = original[tuple(d['entry'])]
(work / 'abi-audit.json').write_text(json.dumps({
    'result': 'shapes_and_events_pass_with_known_metadata_gaps',
    'missing_errors': [key[1] for key in missing],
    'metadata_differences': differences,
    'fe_abi_sha256': hashlib.sha256(fe_path.read_bytes()).hexdigest(),
    'solidity_artifact_sha256': hashlib.sha256(sol_path.read_bytes()).hexdigest(),
    'checker_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
}, indent=2) + '\n')
print('PASS: protocol fee shapes/events; recorded missing errors, getter mutability and return names')
