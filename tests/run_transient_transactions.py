#!/usr/bin/env python3
"""Verify EIP-1153 transaction reset on an isolated Anvil node.

First run run_math_parity.py --suite transient --work-dir PATH. This consumes
that successful run's Fe and Solidity artifacts without rebuilding them. Only
local test accounts and a newly spawned localhost node are used.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import urllib.request

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('parity_dir', type=Path)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
work = args.parity_dir.resolve()
validation = json.loads((work / 'validation.json').read_text())
assert validation['suite'] == 'transient' and validation['result'] == 'passed'
fe_code = (work / 'fe-bytecode.txt').read_text().strip()
assert hashlib.sha256(bytes.fromhex(fe_code.removeprefix('0x'))).hexdigest() == validation['creation_bytecode_sha256']
sol_artifact = work / 'out/TransientParity.t.sol/SolidityTransientHarness.json'
sol_code = json.loads(sol_artifact.read_text())['bytecode']['object']
with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0))
    port = sock.getsockname()[1]
url = f'http://127.0.0.1:{port}'

def rpc(method, params):
    request = urllib.request.Request(url, json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params}).encode(), {'Content-Type': 'application/json'})
    with urllib.request.urlopen(request, timeout=10) as response:
        result = json.load(response)
    if 'error' in result:
        raise RuntimeError(result['error'])
    return result['result']

def calldata(signature, *values):
    return subprocess.check_output(['cast', 'calldata', signature, *map(str, values)], text=True).strip()

def send(sender, data, target=None):
    tx = {'from': sender, 'data': data, 'gas': '0x989680'}
    if target:
        tx['to'] = target
    tx_hash = rpc('eth_sendTransaction', [tx])
    for attempt in range(200):
        receipt = rpc('eth_getTransactionReceipt', [tx_hash])
        if receipt is not None:
            break
        time.sleep(0.025)
    else:
        raise RuntimeError(f'Transaction was not mined: {tx_hash}')
    assert int(receipt['status'], 16) == 1, receipt
    return tx_hash, receipt

cases = [
    ('lock', 'setUnlocked(bool)', ('true',), 'unlocked()', (), 1),
    ('counter', 'bump(bool)', ('true',), 'count()', (), 1),
    ('reserves', 'sync(address,uint256)', ('0x0000000000000000000000000000000000000001', 123), 'synced()', (), 2),
    ('delta_and_counter', 'account(address,address,int128)', ('0x0000000000000000000000000000000000000001', '0x0000000000000000000000000000000000000002', -17), 'delta(address,address)', ('0x0000000000000000000000000000000000000001', '0x0000000000000000000000000000000000000002'), 2),
    ('arbitrary_slot', 'rawWrite(uint256,uint256)', (42, 999), 'rawRead(uint256)', (42,), 1),
]
records = []
with tempfile.TemporaryFile() as log:
    node = subprocess.Popen(['anvil', '--host', '127.0.0.1', '--port', str(port), '--hardfork', 'cancun', '--steps-tracing', '--silent'], stdout=log, stderr=log)
    try:
        for attempt in range(100):
            if node.poll() is not None:
                log.seek(0)
                raise RuntimeError(log.read().decode())
            try:
                accounts = rpc('eth_accounts', [])
                break
            except OSError:
                time.sleep(0.05)
        else:
            raise RuntimeError('Anvil startup timeout')
        for implementation, code in [('fe', fe_code), ('solidity', sol_code)]:
            _, deployment = send(accounts[0], code)
            target = deployment['contractAddress']
            for label, signature, values, getter, getter_values, expected_stores in cases:
                tx_hash, receipt = send(accounts[0], calldata(signature, *values), target)
                trace = rpc('debug_traceTransaction', [tx_hash, {'disableMemory': True, 'disableStorage': True}])
                stores = [step for step in trace['structLogs'] if step['op'] == 'TSTORE']
                assert len(stores) == expected_stores, (implementation, label, len(stores))
                assert any(int(step['stack'][-2], 16) != 0 for step in stores), 'must actually write nonzero transient state'
                out = rpc('eth_call', [{'to': target, 'data': calldata(getter, *getter_values)}, 'latest'])
                expected_words = 2 if getter == 'synced()' else 1
                assert out == '0x' + '00' * (32 * expected_words), (implementation, label, out)
                count = rpc('eth_call', [{'to': target, 'data': calldata('count()')}, 'latest'])
                assert int(count, 16) == 0, 'delta counter must also reset'
                records.append({'implementation': implementation, 'case': label, 'transaction': tx_hash,
                                'block': int(receipt['blockNumber'], 16), 'executed_tstores': len(stores), 'next_call': out})
    finally:
        node.terminate()
        try:
            node.wait(timeout=5)
        except subprocess.TimeoutExpired:
            node.kill()
            node.wait()
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(json.dumps({
    'result': 'passed', 'timestamp_utc': datetime.now(timezone.utc).isoformat(),
    'anvil_version': subprocess.check_output(['anvil', '--version'], text=True).strip(),
    'hardfork': 'cancun', 'parity_validation_sha256': hashlib.sha256((work / 'validation.json').read_bytes()).hexdigest(),
    'fe_creation_bytecode_sha256': validation['creation_bytecode_sha256'],
    'solidity_creation_bytecode_sha256': hashlib.sha256(bytes.fromhex(sol_code.removeprefix('0x'))).hexdigest(),
    'test_script_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
    'cases': records,
}, indent=2) + '\n')
print(f'PASS: {len(records)} mined transactions, nonzero TSTORE traces and zero state in subsequent calls; {args.output}')
