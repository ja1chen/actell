#!/usr/bin/env python3
"""Offline source/packaging checks only. This does NOT compile or execute Swift."""
from pathlib import Path
import hashlib
import hmac
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]

class PackagingChecks(unittest.TestCase):
    def test_xcode_registers_every_new_swift_source_and_test(self):
        project = (ROOT / 'ios-app/PhoneAgent.xcodeproj/project.pbxproj').read_text()
        files = list((ROOT / 'ios-app/PhoneAgent/Remote').glob('*.swift'))
        files += list((ROOT / 'ios-app/PhoneAgentTests').glob('Remote*.swift'))
        files += list((ROOT / 'ios-app/PhoneAgentTests').glob('SimpleLAN*.swift'))
        files += [ROOT / 'ios-app/PhoneAgent/Muse/MuseCompanionProtocol.swift',
                  ROOT / 'ios-app/PhoneAgentTests/MuseCompanionAuthorizationTests.swift']
        required = {'RemoteStrictJSON.swift', 'RemoteTransport.swift',
                    'RemoteConnectionController.swift', 'RemoteConnectionStore.swift',
                    'RemoteToolsService.swift', 'RemoteAuthentication.swift',
                    'RemoteStrictJSONTests.swift', 'RemoteConnectionStoreTests.swift',
                    'RemoteTransportSecurityTests.swift', 'RemoteImageGeometry.swift',
                    'RemoteImageGeometryTests.swift', 'RemoteGeneratedIdentityProvider.swift',
                    'RemoteGeneratedIdentityProviderTests.swift', 'MuseCompanionProtocol.swift',
                    'MuseCompanionAuthorizationTests.swift', 'SimpleLANPairing.swift',
                    'SimpleLANPairingTests.swift', 'SimpleLANRPCTests.swift'}
        self.assertTrue(required.issubset({path.name for path in files}))
        self.assertTrue(all(path.is_file() for path in files))
        self.assertNotIn('PhoneAgent/Muse/MusePairingProtocol.swift', project)
        self.assertTrue((ROOT / 'docs/muse-remote/experiments/MusePairingProtocol.swift.txt').is_file())
        self.assertIn('https://github.com/apple/swift-certificates.git', project)
        self.assertRegex(project, r'\bversion"? = "?1\.10\.0"?;')
        # Verify the PBX reference/build/source-phase graph, accepting both the
        # original commented project and the canonical stdlib generator output.
        blocks = re.findall(r'^\s*"?([A-F0-9]{24})"?(?: /\*.*?\*/)? = \{(.*?)\};', project, re.M | re.S)
        def has_isa(body, name):
            return re.search(r'\bisa"? = "?' + name + r'"?;', body)
        phases = [body for _, body in blocks if has_isa(body, 'PBXSourcesBuildPhase')]
        for path in files:
            relative = str(path.relative_to(ROOT / 'ios-app'))
            refs = [uid for uid, body in blocks if has_isa(body, 'PBXFileReference') and
                    re.search(r'\bpath"? = "?' + re.escape(relative) + r'"?;', body)]
            self.assertEqual(len(refs), 1, relative)
            builds = [uid for uid, body in blocks if has_isa(body, 'PBXBuildFile') and
                      re.search(r'\bfileRef"? = "?' + refs[0] + r'"?(?: /\*.*?\*/)?;', body)]
            self.assertEqual(len(builds), 1, relative)
            self.assertEqual(sum(builds[0] in body for body in phases), 1, relative)
        declared = re.findall(r'^\s*"?([A-F0-9]{24})"?(?: /\*.*?\*/)? = \{', project, re.M)
        self.assertEqual(len(declared), len(set(declared)))

    def test_model_free_entry_uses_lifecycle_approval_and_bridge(self):
        model = (ROOT / 'ios-app/PhoneAgent/Agent/AgentViewModel.swift').read_text()
        entry = model.split('// MARK: - Explicit, model-free Muse tools entry point', 1)[1]
        self.assertNotRegex(entry, r'\b(?:Agent|AgentConfig|PrivateVisionProvider|DemoProvider|ChatGPTSubscriptionProvider)\(')
        runtime = (ROOT / 'ios-app/PhoneAgent/Remote/RemoteToolRuntime.swift').read_text()
        self.assertIn('lifecycle: lifecycle', runtime)
        self.assertIn('approvalRecords.claimExecution', runtime)
        self.assertIn('authorizationMode: MuseCompanionAuthorization.inputMode', runtime)
        self.assertNotRegex(entry, r'createConversation\(|sessions\.begin\(|executionModel\(')
        self.assertNotRegex(runtime, r'sessions\.|ConversationStore\(|AgentViewModel\(|TaskRecord\(')
        self.assertIn('NCMDeviceBridge(remoteExclusive: true)', entry)
        self.assertIn('guard appOwner.remoteLeaseID == nil', model)

    def test_security_critical_fences_are_present(self):
        service = (ROOT / 'ios-app/PhoneAgent/Remote/RemoteToolsService.swift').read_text()
        self.assertIn('try RemoteStrictJSON.validate(body)', service)
        self.assertIn('guard activated else', service)
        self.assertIn('try persist() // Accepted identity', service)
        self.assertIn('App restarted before a confirmed terminal result', service)
        self.assertIn('callExpiry = Task', service)
        self.assertIn('await oldExecution?.value', service)
        self.assertIn('await oldWorker?.waitForRemoteRelease()', service)
        self.assertIn('metadata?["image_id"]', service)
        self.assertNotIn('base64EncodedString()', service)
        app = (ROOT / 'ios-app/PhoneAgent/App/PhoneAgentApp.swift').read_text()
        self.assertNotIn('if phase != .active { PhoneAgentRuntime.shared.remoteTools.stop()', app)
        self.assertIn('museConnection.setScene(active: phase == .active, background: phase == .background)', app)
        transport = (ROOT / 'ios-app/PhoneAgent/Remote/RemoteTransport.swift').read_text()
        self.assertIn('enabled: Bool = false', transport)
        self.assertIn('sec_protocol_options_set_local_identity', transport)
        self.assertIn('RemoteSourceAddress(endpoint: connection.endpoint)', transport)
        self.assertIn('1_024 * 1_024', transport)

    def test_shared_slan_contract_hash(self):
        expected = 'd1ecce424490d4f8e7ea3dc927619f04b7c3fe8b9b522ee2dcacd286c23cee75'
        contract = ROOT / 'docs/muse-remote/SLAN-1.md'
        self.assertEqual(hashlib.sha256(contract.read_bytes()).hexdigest(), expected)
        self.assertIn(expected, (ROOT / 'docs/muse-remote/COMPANION-PAIRING.md').read_text())

    def test_shared_hmac_fixture_independently(self):
        body = b'{"v":1,"client_id":"test-client","request_id":"00000000-0000-4000-8000-000000000001","op":"capabilities","params":{}}'
        prefix = b'ACTELL1\ntest-client\n00000000-0000-4000-8000-000000000001\n1791789900\n00000000-0000-4000-8000-000000000002\n'
        actual = hmac.new(b'test-only-never-use-in-production-0000', prefix + body, hashlib.sha256).hexdigest()
        self.assertEqual(actual, '918badaa9bb84dfe44661830d7c746a12c2ce57ee256b3f65af00d91dae06f38')
        swift_tests = (ROOT / 'ios-app/PhoneAgentTests/RemoteTransportSecurityTests.swift').read_text()
        self.assertIn(actual, swift_tests)
        # This tests Python's independent vector, not CryptoKit execution.

    def test_scope_consent_discloses_muse_service_and_model_destination(self):
        view = (ROOT / 'ios-app/PhoneAgent/App/MuseConnectionView.swift').read_text()
        sheet = view.split('private struct MuseDevicePermissionsSheet: View {', 1)[1].split('private struct MuseLANPairingSheet', 1)[0]
        self.assertIn('museCapabilityDataDisclosure', sheet)
        self.assertIn('截图和应用信息可能经 Muse 发送给其服务或模型', sheet)
        self.assertIn('已开放的操作直接执行，无需逐次确认', sheet)
        self.assertIn('@State private var scopes: Set<MuseCompanionScope> = []', sheet)

    def test_original_licenses_exist(self):
        self.assertTrue((ROOT / 'LICENSE').is_file())
        self.assertTrue((ROOT / 'ios-app/Licenses').is_dir())
        self.assertTrue((ROOT / 'ios-app/SOURCE_MANIFEST.json').is_file())

if __name__ == '__main__':
    unittest.main(verbosity=2)
