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
        files += list((ROOT / 'ios-app/RemoteTests').glob('Remote*.swift'))
        files += list((ROOT / 'ios-app/RemoteTests').glob('SimpleLAN*.swift'))
        files += [ROOT / 'ios-app/PhoneAgent/Muse/MuseCompanionProtocol.swift',
                  ROOT / 'ios-app/RemoteTests/MuseCompanionAuthorizationTests.swift']
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
        swift_tests = (ROOT / 'ios-app/RemoteTests/RemoteTransportSecurityTests.swift').read_text()
        self.assertIn(actual, swift_tests)
        # This tests Python's independent vector, not CryptoKit execution.

if __name__ == '__main__':
    unittest.main(verbosity=2)
