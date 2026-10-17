import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('collector', Path(__file__).with_name('collect_diagnostics.py'))
collector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(collector)


class CollectorTests(unittest.TestCase):
    def test_native_json_preserves_rejection_and_connection_without_raw_data(self):
        sample = {'items': [{'message': 'stage=rpc.authentication.rejected diagnostic=1111111111111111 code=clock_skew state=["connection": "2222222222222222", "authenticated": "false", "signature": "private-signature", "secret": "private-key", "address": "192.168.1.8"]'}]}
        events = collector.extract(sample)
        self.assertEqual(events[0]['code'], 'clock_skew')
        self.assertEqual(events[0]['state']['connection'], '2222222222222222')
        self.assertEqual(events[0]['state']['authenticated'], 'false')
        self.assertNotIn('private', str(events))
        self.assertNotIn('192.168', str(events))

    def test_empty_native_console_is_not_evidence_of_success(self):
        self.assertEqual(collector.extract({'items': [], 'title': 'Console'}), [])
        self.assertEqual(collector.extract({'message': 'other log private credential'}), [])

    def test_raw_ids_and_nonwhitelisted_or_freeform_state_are_dropped(self):
        events = collector.extract('stage=pairing.approved diagnostic=raw-request-id code=- state=["key_state": "unknown_client", "underlying_domain": "some private value", "device_name": "Private Device"]')
        self.assertNotIn('diagnostic', events[0])
        self.assertEqual(events[0]['state'], {'key_state': 'unknown_client'})


if __name__ == '__main__':
    unittest.main()
