"""Verify test entry points stop before creating apps or network permission records."""
import os
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / 'Scripts'


class LocalTestPolicyTests(unittest.TestCase):
    def run_command(self, command, additions=None):
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(('CHOPCHOP_', 'TEST_RUNNER_CHOPCHOP_'))
               and k not in ('CI', 'GITHUB_ACTIONS', 'XCODE_XCCONFIG_FILE')}
        env.update(additions or {})
        return subprocess.run(command, cwd=ROOT, env=env, capture_output=True, text=True, timeout=15)

    def test_hosted_tests_and_full_gate_reject_personal_mac(self):
        commands = [[str(SCRIPTS / 'check.sh'), mode] for mode in ('unit', 'layout', 'release-unit', 'ui', 'keyboard', 'keyboard-a', 'keyboard-b', 'all')]
        commands += [[str(SCRIPTS / name)] for name in ('verify.sh', 'verify-engine-installation.sh')]
        for command in commands:
            with self.subTest(command=command):
                result = self.run_command(command)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn('disposable CI host or VM', result.stderr)

    def test_standalone_smoke_entry_points_reject_before_launch(self):
        for name in ('smoke-aria2-next.py', 'smoke-media.py', 'smoke-app-update.py'):
            with self.subTest(name=name):
                result = self.run_command([sys.executable, str(SCRIPTS / name)])
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn('disposable CI host or VM', result.stderr)

    def test_ci_flag_alone_is_not_a_disposable_host(self):
        result = self.run_command(['sh', str(SCRIPTS / 'test-host-policy.sh'), '--require-disposable-host'], {'CI': 'true'})
        self.assertEqual(result.returncode, 2)
        result = self.run_command(['sh', str(SCRIPTS / 'local-signing.sh'), '--print-identity'], {'CI': 'true'})
        self.assertNotEqual(result.returncode, 0)

    def test_github_actions_and_explicit_vm_can_use_policy(self):
        for additions in ({'CI': 'true', 'GITHUB_ACTIONS': 'true'}, {'CHOPCHOP_DISPOSABLE_TEST_HOST': '1'}):
            with self.subTest(additions=additions):
                result = self.run_command(['sh', str(SCRIPTS / 'test-host-policy.sh'), '--require-disposable-host'], additions)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_release_arguments_cannot_move_or_resign_local_app(self):
        arguments = [('-derivedDataPath', '/tmp/other'), ('-configuration', 'Debug'), ('-xcconfig', '/tmp/other'),
                     ('CODE_SIGN_IDENTITY=-',), ('CODE_SIGNING_ALLOWED=NO',), ('DEVELOPMENT_TEAM=OTHER',),
                     ('CONFIGURATION_BUILD_DIR=/tmp/other',), ('SYMROOT=/tmp/other',), ('BUILD_DIR=/tmp/other',),
                     ('PRODUCT_NAME=Other',), ('CHOPCHOP_APP_IDENTIFIER=org.other.app',), ('test',)]
        for args in arguments:
            with self.subTest(args=args):
                result = self.run_command([str(SCRIPTS / 'check.sh'), 'release', *args])
                self.assertEqual(result.returncode, 2, result.stderr)

    def test_release_environment_cannot_move_local_app(self):
        for additions in ({'CHOPCHOP_DERIVED_DATA': '/tmp/other'}, {'XCODE_XCCONFIG_FILE': '/tmp/other'}):
            with self.subTest(additions=additions):
                result = self.run_command([str(SCRIPTS / 'check.sh'), 'release'], additions)
                self.assertEqual(result.returncode, 2, result.stderr)

    def test_normal_local_signing_keeps_apple_development(self):
        result = self.run_command(['sh', str(SCRIPTS / 'local-signing.sh'), '--print-identity'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'Apple Development')


if __name__ == '__main__':
    unittest.main()
