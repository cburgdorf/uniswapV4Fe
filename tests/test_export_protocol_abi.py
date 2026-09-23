"""Ensure manual return-codec exceptions cannot relax other interface checks."""
import unittest
from copy import deepcopy
from export_protocol_abi import export


class FlatDynamicReturnTests(unittest.TestCase):
    def setUp(self):
        self.outputs = [{'type': 'uint256'}, {'type': 'bytes'}, {'type': 'bool'}]
        self.reference = [{'type': 'function', 'name': 'page', 'inputs': [],
                           'outputs': self.outputs, 'stateMutability': 'view'}]
        self.fe = deepcopy(self.reference)
        self.fe[0]['outputs'] = [{'type': 'tuple', 'components': self.outputs}]
        self.signature = 'function:page()'

    def test_default_rejects_extra_dynamic_tuple_root(self):
        with self.assertRaisesRegex(ValueError, 'Incompatible return'):
            export(self.fe, self.reference)

    def test_explicit_manual_codec_permits_only_matching_flat_components(self):
        abi, _ = export(self.fe, self.reference, [self.signature])
        self.assertEqual(abi, self.reference)
        self.fe[0]['outputs'][0]['components'] = [{'type': 'address'}]
        with self.assertRaises(ValueError):
            export(self.fe, self.reference, [self.signature])

    def test_unknown_exception_fails(self):
        with self.assertRaisesRegex(ValueError, 'Unknown explicit'):
            export(self.fe, self.reference, ['function:typo()'])

    def test_exception_does_not_permit_changed_mutability(self):
        self.fe[0]['stateMutability'] = 'nonpayable'
        with self.assertRaisesRegex(ValueError, 'Incompatible mutability'):
            export(self.fe, self.reference, [self.signature])

    def test_exception_does_not_permit_changed_inputs(self):
        self.fe[0]['inputs'] = [{'type': 'address'}]
        with self.assertRaisesRegex(ValueError, 'signatures differ'):
            export(self.fe, self.reference, [self.signature])

    def test_existing_static_flattening_needs_no_exception(self):
        self.fe[0]['outputs'][0]['components'] = [{'type': 'uint256'}, {'type': 'bool'}]
        self.reference[0]['outputs'] = [{'type': 'uint256'}, {'type': 'bool'}]
        abi, _ = export(self.fe, self.reference)
        self.assertEqual(abi, self.reference)
        with self.assertRaisesRegex(ValueError, 'dynamic tuple'):
            export(self.fe, self.reference, [self.signature])


class ReceiveAdapterTests(unittest.TestCase):
    def test_receive_adapter_is_explicit_and_payable_only(self):
        fe = [{'type': 'fallback', 'stateMutability': 'payable'}]
        reference = [{'type': 'receive', 'stateMutability': 'payable'}]
        with self.assertRaisesRegex(ValueError, 'signatures differ'):
            export(fe, reference)
        self.assertEqual(export(fe, reference, fallback_receive=True)[0], reference)
        fe[0]['stateMutability'] = 'nonpayable'
        with self.assertRaisesRegex(ValueError, 'lone payable fallback'):
            export(fe, reference, fallback_receive=True)

    def test_receive_adapter_does_not_hide_other_signatures(self):
        fe = [{'type': 'fallback', 'stateMutability': 'payable'},
              {'type': 'function', 'name': 'extra', 'inputs': [], 'outputs': [], 'stateMutability': 'view'}]
        reference = [{'type': 'receive', 'stateMutability': 'payable'}]
        with self.assertRaisesRegex(ValueError, 'signatures differ'):
            export(fe, reference, fallback_receive=True)
        with self.assertRaisesRegex(ValueError, 'lone payable fallback'):
            export(reference, reference, fallback_receive=True)


class LazyMulticallAdapterTests(unittest.TestCase):
    def setUp(self):
        self.fe = []
        self.reference = [{'type': 'function', 'name': 'multicall', 'stateMutability': 'payable',
                           'inputs': [{'type': 'bytes[]'}], 'outputs': [{'type': 'bytes[]'}]}]

    def test_custom_codec_requires_explicit_opt_in(self):
        with self.assertRaisesRegex(ValueError, 'signatures differ'):
            export(self.fe, self.reference)
        self.assertEqual(export(self.fe, self.reference, lazy_multicall=True)[0], self.reference)

    def test_custom_codec_rejects_wrong_reference(self):
        self.reference[0]['inputs'][0]['type'] = 'address'
        with self.assertRaisesRegex(ValueError, 'exact reference signature'):
            export(self.fe, self.reference, lazy_multicall=True)

    def test_custom_codec_does_not_hide_other_signatures(self):
        self.fe.append({'type': 'function', 'name': 'extra', 'inputs': [], 'outputs': []})
        with self.assertRaisesRegex(ValueError, 'signatures differ'):
            export(self.fe, self.reference, lazy_multicall=True)

    def test_custom_codec_rejects_changed_output_or_mutability(self):
        for field, value in [('outputs', [{'type': 'bytes'}]), ('stateMutability', 'nonpayable')]:
            altered = deepcopy(self.reference)
            altered[0][field] = value
            with self.assertRaisesRegex(ValueError, 'payable bytes'):
                export(self.fe, altered, lazy_multicall=True)

    def test_custom_codec_rejects_existing_handler(self):
        with self.assertRaisesRegex(ValueError, 'omitted numeric handler'):
            export(self.reference, self.reference, lazy_multicall=True)


if __name__ == '__main__':
    unittest.main()
