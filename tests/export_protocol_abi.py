#!/usr/bin/env python3
"""Export the pinned protocol interface after checking Fe's callable ABI shapes.

Fe currently groups multiple static return values into one tuple and drops return
names. Static tuple outputs have the same wire layout as separate outputs. This
adapter permits only that equivalence and pure-to-view strengthening; dynamic
return differences and missing/changed callable signatures are rejected. An
explicit per-function option is reserved for manually encoded flat dynamic
returns whose wire layout is checked by the differential runtime suite.
Explicit adapters also cover the native receive fallback and the numerically
selected lazy Multicall handler, which Fe omits from generated ABI metadata.
Reference error declarations may be unreachable (and absent from Fe's reachable
error inventory). They describe the interface, not a claim of runtime reachability.
"""
import argparse
from copy import deepcopy
import hashlib
import json
from pathlib import Path


def abi_type(value):
    if value['type'].startswith('tuple'):
        return '(' + ','.join(abi_type(c) for c in value['components']) + ')' + value['type'][5:]
    return value['type']


def signature(entry):
    return entry['type'] + ':' + entry.get('name', '') + '(' + ','.join(abi_type(v) for v in entry.get('inputs', [])) + ')'


def static(value):
    kind = value['type']
    if kind.endswith(']'):
        base, length = kind.rsplit('[', 1)
        return length != ']' and static({**value, 'type': base})
    if kind in ['bytes', 'string']:
        return False
    return kind != 'tuple' or all(static(c) for c in value['components'])


def outputs_match(fe, reference, flat_dynamic=False):
    if [abi_type(x) for x in fe] == [abi_type(x) for x in reference]:
        return True
    if len(fe) == 1 and fe[0]['type'] == 'tuple' and (static(fe[0]) or flat_dynamic):
        return [abi_type(x) for x in fe[0]['components']] == [abi_type(x) for x in reference]
    return False


def export(fe, reference, flat_dynamic=(), fallback_receive=False, lazy_multicall=False):
    fe = deepcopy(fe)
    input_adaptations = []
    if lazy_multicall:
        # Fe omits numerically selected handlers from its generated ABI.
        # The demo uses 0xac9650d8 with a custom lazy calldata codec. Require
        # explicit opt-in backed by its runtime differential tests.
        if any(e['type'] == 'function' and e.get('name') == 'multicall' for e in fe):
            raise ValueError('Lazy multicall adapter requires an omitted numeric handler')
        candidates = [e for e in reference if e['type'] == 'function' and e.get('name') == 'multicall']
        if len(candidates) != 1 or signature(candidates[0]) != 'function:multicall(bytes[])':
            raise ValueError('Lazy multicall adapter requires the exact reference signature')
        call = candidates[0]
        if call.get('stateMutability') != 'payable' or [abi_type(x) for x in call.get('outputs', [])] != ['bytes[]']:
            raise ValueError('Lazy multicall adapter requires payable bytes[] output')
        fe.append(deepcopy(call))
        input_adaptations.append('numeric handler 0xac9650d8 -> multicall(bytes[]) (explicit lazy calldata codec)')
    left = {signature(e): e for e in fe if e['type'] != 'error'}
    right = {signature(e): e for e in reference if e['type'] != 'error'}
    if len(left) != sum(e['type'] != 'error' for e in fe) or len(right) != sum(e['type'] != 'error' for e in reference):
        raise ValueError('Duplicate ABI signatures')
    receive_adaptations = []
    if fallback_receive:
        fallback, receive = 'fallback:()', 'receive:()'
        if (fallback not in left or receive in left or receive not in right or fallback in right
            or left[fallback].get('stateMutability') != 'payable'
            or right[receive].get('stateMutability') != 'payable'
            or left[fallback].get('inputs') or left[fallback].get('outputs')):
            raise ValueError('Receive adapter requires a lone payable fallback and reference receive')
        left[receive] = {**left.pop(fallback), 'type': 'receive'}
        receive_adaptations.append('fallback:() -> receive:()')
    if left.keys() != right.keys():
        raise ValueError(f'Callable/event signatures differ: {sorted(left.keys() ^ right.keys())}')
    flat_dynamic = set(flat_dynamic)
    if not flat_dynamic <= right.keys():
        raise ValueError(f'Unknown explicit flat-return signatures: {sorted(flat_dynamic - right.keys())}')
    for key in flat_dynamic:
        outputs = left[key].get('outputs', [])
        if left[key]['type'] != 'function' or len(outputs) != 1 or outputs[0]['type'] != 'tuple' or static(outputs[0]):
            raise ValueError(f'Explicit flat return must identify a dynamic tuple: {key}')
    adaptations = input_adaptations + receive_adaptations
    for key, expected in right.items():
        actual = left[key]
        if not outputs_match(actual.get('outputs', []), expected.get('outputs', []), key in flat_dynamic):
            raise ValueError(f'Incompatible return layout: {key}')
        am, em = actual.get('stateMutability'), expected.get('stateMutability')
        if am != em and (am, em) != ('pure', 'view'):
            raise ValueError(f'Incompatible mutability: {key}: {am} / {em}')
        if expected['type'] == 'event':
            if actual.get('anonymous', False) != expected.get('anonymous', False):
                raise ValueError(f'Event anonymity differs: {key}')
            if [v.get('indexed', False) for v in actual['inputs']] != [v.get('indexed', False) for v in expected['inputs']]:
                raise ValueError(f'Event indexing differs: {key}')
        if actual != expected:
            adaptations.append(key)
    return deepcopy(reference), adaptations


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('fe_abi', type=Path)
    parser.add_argument('reference_artifact', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--flatten-dynamic-output', action='append', default=[], help='Exact function signature with an explicit flat return encoder; requires runtime parity evidence')
    parser.add_argument('--fallback-receive', action='store_true', help='Fallback explicitly rejects nonempty calldata; requires receive/unknown-selector runtime parity evidence')
    parser.add_argument('--lazy-multicall', action='store_true', help='Use the demo Calls calldata codec; requires malformed-element ordering runtime parity evidence')
    args = parser.parse_args()
    fe = json.loads(args.fe_abi.read_text())
    artifact = json.loads(args.reference_artifact.read_text())
    reference = artifact['abi'] if isinstance(artifact, dict) else artifact
    result, adaptations = export(fe, reference, args.flatten_dynamic_output, args.fallback_receive, args.lazy_multicall)
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    record = {
        'fe_abi_sha256': hashlib.sha256(args.fe_abi.read_bytes()).hexdigest(),
        'reference_artifact_sha256': hashlib.sha256(args.reference_artifact.read_bytes()).hexdigest(),
        'protocol_abi_sha256': hashlib.sha256(args.output.read_bytes()).hexdigest(),
        'adapter_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        'callable_and_event_layouts': 'compatible',
        'reference_metadata_applied': adaptations,
        'explicit_fallback_receive': args.fallback_receive,
        'explicit_lazy_multicall': args.lazy_multicall,
        'explicit_flat_dynamic_returns': sorted(args.flatten_dynamic_output),
        'fe_error_signatures': sorted(signature(e) for e in fe if e['type'] == 'error'),
        'reference_error_signatures': sorted(signature(e) for e in reference if e['type'] == 'error'),
    }
    args.output.with_suffix('.audit.json').write_text(json.dumps(record, indent=2) + '\n')
    print('Verified protocol ABI:', args.output)


if __name__ == '__main__':
    main()
