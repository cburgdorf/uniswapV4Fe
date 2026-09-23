#!/usr/bin/env python3
"""Verify the complete external storage harness ABI, including all overloads and mutability."""
import argparse
import hashlib
import json
from pathlib import Path
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('parity_dir',type=Path)
args=parser.parse_args()
work=args.parity_dir
fe_path=work/'fe/ExtloadHarness.abi.json'
sol_path=work/'out/ExtloadParity.t.sol/SolidityExtloadHarness.json'
def clean(value):
    if isinstance(value,list): return [clean(item) for item in value]
    if isinstance(value,dict): return {key:clean(item) for key,item in value.items() if key!='internalType'}
    return value
fe=clean(json.loads(fe_path.read_text()))
sol=clean(json.loads(sol_path.read_text())['abi'])
order=lambda entry:(entry['type'],entry.get('name',''),json.dumps(entry.get('inputs',[]),sort_keys=True))
assert sorted(fe,key=order)==sorted(sol,key=order),(fe,sol)
(work/'abi-audit.json').write_text(json.dumps({'result':'passed','entries':len(fe),'fe_abi_sha256':hashlib.sha256(fe_path.read_bytes()).hexdigest(),'solidity_artifact_sha256':hashlib.sha256(sol_path.read_bytes()).hexdigest(),'checker_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest()},indent=2)+'\n')
print('PASS: complete Extload ABI matches after ignoring Solidity internalType annotations and entry order')
