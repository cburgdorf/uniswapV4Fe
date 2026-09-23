"""Finish artifact validation only after its required protocol ABI audit passes."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

PROTOCOL_CONTRACTS = {
    'router_workflows': 'V4Router',
    'permissioned_router_workflows': 'PermissionedV4Router',
    'permissions_adapter': 'PermissionsAdapter',
    'permissions_factory': 'PermissionsAdapterFactory',
    'deployer_competition': 'UniswapV4DeployerCompetition',
    'position_descriptor': 'PositionDescriptor',
    'manager': 'PoolManager',
    'state_view': 'StateView',
    'quoter': 'V4Quoter',
    'quoter_workflows': 'V4Quoter',
    'reserves_lens': 'ReservesLens',
    'position_manager': 'PositionManager',
    'permissioned_position_manager': 'PermissionedPositionManager',
}


def complete_validation(work):
    work = Path(work)
    path = work / 'validation.json'
    metadata = json.loads(path.read_text())
    if metadata.get('runtime_result', metadata['result']) != 'passed':
        raise ValueError('Protocol ABI audit requires a passed runtime suite')
    suite = metadata['suite']
    metadata['runtime_result'] = 'passed'
    metadata['protocol_abi_gate_sha256'] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    if suite not in PROTOCOL_CONTRACTS:
        metadata.update(result='passed', protocol_abi_result='not_applicable')
        path.write_text(json.dumps(metadata, indent=2) + '\n')
        return
    harness = PROTOCOL_CONTRACTS[suite]
    reference_file, reference_contract = harness + '.sol', harness
    if suite == 'router_workflows':
        reference_file, reference_contract = 'RouterWorkflows.t.sol', 'SolidityWorkflowRouter'
    if suite == 'permissioned_router_workflows':
        reference_file, reference_contract = 'PermissionedRouterWorkflows.t.sol', 'SolidityPermissionedRouter'
    command = [sys.executable, str(Path(__file__).with_name('export_protocol_abi.py')),
               str(work / 'fe' / (harness + '.abi.json')),
               str(work / 'out' / reference_file / (reference_contract + '.json')),
               '--output', str(work / 'fe' / (harness + '.protocol.abi.json'))]
    if suite in ['router_workflows', 'permissioned_router_workflows']:
        command += ['--fallback-receive']
    if suite in ['position_manager', 'permissioned_position_manager']:
        command += ['--fallback-receive', '--lazy-multicall']
    if suite == 'reserves_lens':
        for signature in [
            'function:getPoolTVLPaged(address,(address,address,uint24,int24,address),bytes)',
            'function:getPoolTVLPaged(address,(address,address,uint24,int24,address),address,bytes,uint32)',
        ]:
            command += ['--flatten-dynamic-output', signature]
    metadata.update(result='runtime_passed_abi_pending', protocol_abi_result='pending', protocol_abi_command=command)
    path.write_text(json.dumps(metadata, indent=2) + '\n')
    try:
        result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    except Exception as error:
        metadata.update(result='failed', protocol_abi_result='failed', protocol_abi_error=str(error))
        path.write_text(json.dumps(metadata, indent=2) + '\n')
        raise
    print(result.stdout, end='')
    (work / 'protocol-abi.log').write_text(result.stdout)
    status = 'passed' if result.returncode == 0 else 'failed'
    metadata.update(result=status, protocol_abi_result=status)
    path.write_text(json.dumps(metadata, indent=2) + '\n')
    result.check_returncode()
