#!/usr/bin/env python3
"""Audit the complete manager ABI; report metadata differences without hiding them."""
import argparse
import hashlib
import json
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('artifacts', type=Path)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--allow-metadata-differences', action='store_true')
args = parser.parse_args()
fe_path = args.artifacts / 'fe/PoolManager.abi.json'
sol_path = args.artifacts / 'out/PoolManager.sol/PoolManager.json'
fe = json.loads(fe_path.read_text())
sol = json.loads(sol_path.read_text())['abi']

def abi_type(value):
    if value['type'].startswith('tuple'):
        return '(' + ','.join(abi_type(c) for c in value['components']) + ')' + value['type'][5:]
    return value['type']

def signature(entry):
    return entry['type'] + ':' + entry.get('name', '') + '(' + ','.join(abi_type(p) for p in entry.get('inputs', [])) + ')'

def without_internal(value):
    if isinstance(value, dict):
        return {k: without_internal(v) for k, v in value.items() if k != 'internalType'}
    if isinstance(value, list):
        return [without_internal(v) for v in value]
    return value

a = {signature(e): e for e in fe}
b = {signature(e): e for e in sol}
missing = sorted(b.keys() - a.keys())
extra = sorted(a.keys() - b.keys())
surface_errors = list(missing) + [k for k in extra if not k.startswith('error:')]
metadata = []
for key in sorted(a.keys() & b.keys()):
    left, right = without_internal(a[key]), without_internal(b[key])
    if left != right:
        metadata.append({'entry': key, 'fe': left, 'solidity': right})
    if [abi_type(v) for v in left.get('outputs', [])] != [abi_type(v) for v in right.get('outputs', [])]:
        surface_errors.append(key + ': output type mismatch')
    if key.startswith('event:') and left != right:
        surface_errors.append(key + ': event fields/indexing mismatch')
report = {
    'fe_abi_sha256': hashlib.sha256(fe_path.read_bytes()).hexdigest(),
    'solidity_artifact_sha256': hashlib.sha256(sol_path.read_bytes()).hexdigest(),
    'function_count': sum(e['type'] == 'function' for e in fe),
    'abi_surface_matches': not surface_errors,
    'complete_metadata_matches_excluding_internal_type': not (metadata or missing or extra),
    'surface_errors': surface_errors,
    'missing_entries': missing,
    'additional_entries': extra,
    'metadata_differences': metadata,
}
args.output.write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps({k: report[k] for k in ['function_count', 'abi_surface_matches', 'complete_metadata_matches_excluding_internal_type']}))
if surface_errors or (not args.allow_metadata_differences and (metadata or missing or extra)):
    raise SystemExit(1)
