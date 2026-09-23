#!/usr/bin/env python3
"""Audit pinned action constants and the remaining periphery consumer interfaces.

This is a source/ABI/evidence audit, not a substitute for runtime parity tests.
WETH9 is an external dependency in the reference, not a periphery implementation.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def integer(value):
    value = value.strip()
    address = re.fullmatch(r'address\((\d+)\)', value)
    if address:
        return int(address[1])
    if not re.fullmatch(r'(?:0x[0-9a-fA-F]+|\d+)(?:\s*<<\s*\d+)?', value):
        raise ValueError('Unsupported constant expression: ' + value)
    parts = re.split(r'\s*<<\s*', value)
    first = int(parts[0], 16 if parts[0].startswith('0x') else 10)
    return first << int(parts[1]) if len(parts) == 2 else first


def evidence(work, suite, test, modules):
    raw = (work / 'validation.json').read_bytes()
    record = json.loads(raw)
    if record['result'] != 'passed' or record['suite'] != suite or record['optimization'] != '1':
        raise ValueError('Expected a passed O1 ' + suite + ' artifact')
    if record['test_source_sha256'] != sha(ROOT / 'tests/solidity' / test):
        raise ValueError('Current test source differs from tested artifact: ' + test)
    for name in modules:
        if record['sources'].get(name) != sha(ROOT / name):
            raise ValueError('Current Fe source differs from tested artifact: ' + name)
    return {'artifact': str(work), 'validation_sha256': hashlib.sha256(raw).hexdigest(),
            'compiler_sha256': record['compiler_sha256'], 'test_source_sha256': record['test_source_sha256'],
            'current_sources_checked': {name: sha(ROOT / name) for name in modules}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference-periphery', type=Path, required=True)
    parser.add_argument('--router-artifact', type=Path, required=True)
    parser.add_argument('--wrapper-artifact', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    manifest = json.loads((ROOT / 'reference_manifest.json').read_text())['v4-periphery']
    references = {}

    def reference(name):
        path = args.reference_periphery / name
        if sha(path) != manifest['sources'][name]['sha256']:
            raise ValueError('Unpinned reference: ' + name)
        references[name] = sha(path)
        return path.read_text()

    constants = {}
    for name in ['src/libraries/Actions.sol', 'src/libraries/ActionConstants.sol']:
        for typ, key, value in re.findall(r'(uint\d+|address) internal constant (\w+)\s*=\s*([^;]+);', reference(name)):
            if key in constants:
                raise ValueError('Duplicate reference constant: ' + key)
            constants[key] = {'type': typ, 'value': integer(value)}
    fe_constants = {key: (typ, integer(value)) for key, typ, value in
                    re.findall(r'pub const (\w+): (u\d+) = ([^\n]+)', (ROOT / 'src/actions.fe').read_text())}
    if constants.keys() != fe_constants.keys():
        raise ValueError('Action constant inventory differs')
    for key, expected in constants.items():
        # Address sentinels are numeric routing tags compared with Address.inner.
        typ = 'u256' if expected['type'] == 'address' else expected['type'].replace('uint', 'u')
        if fe_constants[key] != (typ, expected['value']):
            raise ValueError('Action constant differs: ' + key)

    router = reference('src/interfaces/IV4Router.sol')
    errors = []
    for name, params in re.findall(r'error (\w+)\(([^)]*)\);', router):
        types = [field.strip().split()[0] for field in params.split(',') if field.strip()]
        errors.append('error:' + name + '(' + ','.join(types) + ')')
    abi = json.loads((args.router_artifact / 'fe/RouterHarness.abi.json').read_text())
    actual = {'error:' + e['name'] + '(' + ','.join(p['type'] for p in e['inputs']) + ')'
              for e in abi if e['type'] == 'error'}
    if not set(errors) <= actual:
        raise ValueError('Router error ABI missing or changed: ' + str(set(errors) - actual))
    tests = (ROOT / 'tests/solidity/RouterParity.t.sol').read_text()
    matrix = tests.split('function test_interfaceErrorMatrix()', 1)[1].split('function test_shortParameters', 1)[0]
    for error in errors:
        name = error.split(':')[1].split('(')[0]
        if 'IV4Router.' + name + '.selector' not in matrix:
            raise ValueError('Missing explicit runtime error case: ' + name)
    structs = {name: re.findall(r'(\w+(?:\[\])?)\s+\w+;', body)
               for name, body in re.findall(r'struct (\w+)\s*\{([^}]+)\}', router)}
    expected = {
        'ExactInputSingleParams': ['PoolKey', 'bool', 'uint128', 'uint128', 'uint256', 'bytes'],
        'ExactOutputSingleParams': ['PoolKey', 'bool', 'uint128', 'uint128', 'uint256', 'bytes'],
        'ExactInputParams': ['Currency', 'PathKey[]', 'uint256[]', 'uint128', 'uint128'],
        'ExactOutputParams': ['Currency', 'PathKey[]', 'uint256[]', 'uint128', 'uint128'],
    }
    if structs != expected or any('IV4Router.' + name not in tests for name in structs):
        raise ValueError('Router tuple schema or runtime fixture coverage changed')

    weth = reference('src/interfaces/external/IWETH9.sol')
    if 'interface IWETH9 is IERC20' not in weth or 'function deposit() external payable;' not in weth or 'function withdraw(uint256) external;' not in weth:
        raise ValueError('External WETH9 consumer interface changed')
    wrapper = (ROOT / 'src/native_wrapper.fe').read_text()
    for signature in ['deposit()', 'withdraw(uint256)']:
        if 'sol("' + signature + '")' not in wrapper:
            raise ValueError('Missing WETH9 consumer selector: ' + signature)
    proofs = {
        'router': evidence(args.router_artifact, 'router', 'RouterParity.t.sol', ['src/actions.fe', 'src/router.fe', 'src/router_params.fe', 'src/calldata_decoder.fe']),
        'native_wrapper': evidence(args.wrapper_artifact, 'native_wrapper', 'NativeWrapperParity.t.sol', ['src/native_wrapper.fe']),
    }
    result = {'result': 'passed', 'scope': 'Periphery action constants, IV4Router schemas/errors, and IWETH9 consumer interactions',
              'reference_revision': manifest['revision'], 'reference_sources': references,
              'audit_script_sha256': sha(Path(__file__)), 'constant_count': len(constants), 'constants': constants,
              'router_error_signatures': errors, 'router_struct_types': structs, 'evidence': proofs,
              'notes': ['Router structs use lazy typed calldata views to preserve pinned Solidity validation order.',
                        'IWETH9 is an external dependency interface. NativeWrapper supplies deposit/withdraw interaction; ERC20 interactions use the shared currency/payment paths. No WETH9 token implementation is claimed.',
                        'Reserved actions remain subject to each reference dispatcher; declaring a constant does not enable it everywhere.']}
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(f'Passed: {len(constants)} constants, {len(errors)} router errors, {len(structs)} swap schemas and WETH9 consumer evidence')


if __name__ == '__main__':
    main()
