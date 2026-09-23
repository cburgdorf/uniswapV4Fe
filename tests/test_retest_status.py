"""A retest must withdraw old success before replacing/running its fixture."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


class RetestStatusTest(unittest.TestCase):
    def test_runtime_observes_pending_and_failure_cannot_reuse_old_success(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            work = root / 'artifact'
            (work / 'test').mkdir(parents=True)
            (work / 'fe-bytecode.txt').write_text('0x00')
            (work / 'forge-test.log').write_text('old passing result')
            (work / 'test/Example.t.sol').write_text('old fixture')
            fixture = root / 'Example.t.sol'
            fixture.write_text('new fixture')
            metadata = {'sources': {}, 'creation_bytecode_sha256': hashlib.sha256(b'\x00').hexdigest(),
                        'result': 'passed', 'runtime_result': 'passed', 'protocol_abi_result': 'passed',
                        'suite': 'manager', 'fuzz_runs_per_property': 1}
            (work / 'validation.json').write_text(json.dumps(metadata))
            executable = root / 'forge'
            executable.write_text('#!' + sys.executable + '\nfrom pathlib import Path\n'
                                  'Path("observed.json").write_bytes(Path("validation.json").read_bytes())\n'
                                  'raise SystemExit(1)\n')
            executable.chmod(0o755)
            env = {**os.environ, 'PATH': str(root) + os.pathsep + os.environ['PATH']}
            result = subprocess.run([sys.executable, str(Path(__file__).with_name('retest_parity.py')),
                                     str(work), str(fixture)], env=env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            observed = json.loads((work / 'observed.json').read_text())
            self.assertEqual(observed['result'], 'runtime_pending')
            self.assertEqual(observed['runtime_result'], 'pending')
            self.assertEqual(observed['protocol_abi_result'], 'pending')
            self.assertEqual(observed['test_source_sha256'], hashlib.sha256(fixture.read_bytes()).hexdigest())
            final = json.loads((work / 'validation.json').read_text())
            self.assertEqual(final['result'], 'failed')
            self.assertEqual(final['runtime_result'], 'failed')
            backup = next(work.glob('before-retest-*'))
            self.assertEqual(json.loads((backup / 'validation.json').read_text()), metadata)
            self.assertEqual((backup / fixture.name).read_text(), 'old fixture')


if __name__ == '__main__':
    unittest.main()
