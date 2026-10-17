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

    def test_control_recovery_keeps_background_evidence_without_private_failure_text(self):
        events = collector.extract('stage=control.connection_wait diagnostic=- run=1111111111111111 code=- state=["control_ready": "false", "control_route": "localDevVPN", "background_enabled": "true", "background_selected": "audio+location", "background_desired": "audio", "background_effective": "audio", "background_continuity": "true", "control_failure": "Private network address"]')
        self.assertEqual(events[0]['run'], '1111111111111111')
        self.assertEqual(events[0]['state']['background_effective'], 'audio')
        self.assertEqual(events[0]['state']['background_selected'], 'audio+location')
        self.assertEqual(events[0]['state']['control_ready'], 'false')
        self.assertNotIn('Private', str(events))
        self.assertNotIn('control_failure', events[0]['state'])
        empty = collector.extract('stage=control.connection_wait code=- state=["background_effective": ""]')
        self.assertEqual(empty[0]['state']['background_effective'], '')
        released = collector.extract('stage=run.release_complete run=1111111111111111 code=- state=["release_elapsed_ms": "135", "draining": "false"]')
        self.assertEqual(released[0]['state']['release_elapsed_ms'], '135')

    def test_empty_native_console_is_not_evidence_of_success(self):
        self.assertEqual(collector.extract({'items': [], 'title': 'Console'}), [])
        self.assertEqual(collector.extract({'message': 'other log private credential'}), [])

    def test_raw_ids_and_nonwhitelisted_or_freeform_state_are_dropped(self):
        events = collector.extract('stage=pairing.approved diagnostic=raw-request-id code=- state=["key_state": "unknown_client", "underlying_domain": "some private value", "device_name": "Private Device"]')
        self.assertNotIn('diagnostic', events[0])
        self.assertEqual(events[0]['state'], {'key_state': 'unknown_client'})


if __name__ == '__main__':
    unittest.main()
