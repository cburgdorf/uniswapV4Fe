"""Exercise the real ABI exporter at the artifact acceptance boundary."""
import contextlib
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from protocol_abi_gate import complete_validation


class ProtocolAbiGateTest(unittest.TestCase):
    def test_runtime_success_cannot_hide_abi_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            (work / 'fe').mkdir()
            (work / 'out/PoolManager.sol').mkdir(parents=True)
            path = work / 'validation.json'
            path.write_text(json.dumps({'suite': 'manager', 'runtime_result': 'passed', 'result': 'runtime_passed_abi_pending'}))
            function = {'type': 'function', 'name': 'transferFrom', 'inputs': [], 'outputs': [], 'stateMutability': 'nonpayable'}
            reference = [function]
            fe_abi = work / 'fe/PoolManager.abi.json'
            fe_abi.write_text(json.dumps([{**function, 'stateMutability': 'view'}]))
            (work / 'out/PoolManager.sol/PoolManager.json').write_text(json.dumps({'abi': reference}))
            with contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaises(subprocess.CalledProcessError):
                    complete_validation(work)
            failed = json.loads(path.read_text())
            self.assertEqual(failed['runtime_result'], 'passed')
            self.assertEqual(failed['protocol_abi_result'], 'failed')
            self.assertEqual(failed['result'], 'failed')
            self.assertIn('view / nonpayable', (work / 'protocol-abi.log').read_text())
            fe_abi.write_text(json.dumps(reference))
            with contextlib.redirect_stdout(io.StringIO()):
                complete_validation(work)
            passed = json.loads(path.read_text())
            self.assertEqual(passed['protocol_abi_result'], 'passed')
            self.assertEqual(passed['result'], 'passed')
            self.assertEqual(json.loads((work / 'fe/PoolManager.protocol.abi.json').read_text()), reference)

    def test_failed_runtime_cannot_be_promoted(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            path = work / 'validation.json'
            path.write_text(json.dumps({'suite': 'manager', 'runtime_result': 'failed', 'result': 'failed'}))
            with self.assertRaisesRegex(ValueError, 'passed runtime'):
                complete_validation(work)
            self.assertEqual(json.loads(path.read_text())['result'], 'failed')


if __name__ == '__main__':
    unittest.main()
