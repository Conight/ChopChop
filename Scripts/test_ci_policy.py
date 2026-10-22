"""Pure CI/release policy regressions; no app, test host, or network is launched."""
import json
from pathlib import Path
import re
import unittest

from ci_gate import GateError, LANES, all_jobs, complete_jobs, latest_run, trusted_run, wait_for_ci

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = 'Conight/ChopChop'
SHA = 'a' * 40


def run_record(**updates):
    value = dict(id=20, run_attempt=1, head_sha=SHA, event='push', head_branch='main',
                 path='.github/workflows/ci.yml', status='completed', conclusion='success',
                 repository={'full_name': REPOSITORY}, head_repository={'full_name': REPOSITORY})
    value.update(updates)
    return value


def job_records():
    jobs = [dict(id=index + 1, name='verification / ' + name if name != 'test' else name,
                 status='completed', conclusion='success') for index, name in enumerate(sorted(LANES))]
    return dict(total_count=len(jobs), jobs=jobs)


class FakeClock:
    def __init__(self): self.time = 0
    def now(self): return self.time
    def sleep(self, seconds): self.time += seconds


class CIGateTests(unittest.TestCase):
    def client(self, listed=None, fresh=None, jobs=None):
        def fetch(path):
            if '/workflows/ci.yml/runs?' in path:
                self.assertIn('head_sha=' + SHA, path)
                self.assertIn('event=push', path)
                self.assertIn('branch=main', path)
                return {'workflow_runs': listed if listed is not None else [run_record()]}
            if '/jobs?' in path:
                self.assertIn('filter=all', path)
                return jobs if jobs is not None else job_records()
            return fresh if fresh is not None else run_record()
        return fetch

    def test_reuses_exact_sha_main_push_only(self):
        self.assertEqual(wait_for_ci(self.client(), REPOSITORY, SHA)['id'], 20)
        for change in ({'head_sha': 'b' * 40}, {'event': 'pull_request'}, {'event': 'workflow_dispatch'},
                       {'head_branch': 'feature'}, {'path': '.github/workflows/other.yml'},
                       {'repository': {'full_name': 'other/repo'}}, {'head_repository': {'full_name': 'fork/repo'}}):
            with self.subTest(change=change):
                self.assertFalse(trusted_run(run_record(**change), REPOSITORY, SHA))
                self.assertIsNone(latest_run([run_record(**change)], REPOSITORY, SHA))

    def test_latest_run_wins_over_older_success(self):
        newer = run_record(id=30, status='in_progress', conclusion=None)
        self.assertEqual(latest_run([run_record(), newer], REPOSITORY, SHA), newer)

    def test_failed_ci_blocks_instead_of_retrying_bad_source(self):
        for conclusion in ('failure', 'timed_out', 'action_required', None):
            with self.subTest(conclusion=conclusion), self.assertRaises(GateError):
                wait_for_ci(self.client(fresh=run_record(conclusion=conclusion)), REPOSITORY, SHA)

    def test_cancelled_ci_falls_back_to_full_independent_verification(self):
        for conclusion in ('cancelled', 'skipped'):
            self.assertIsNone(wait_for_ci(self.client(fresh=run_record(conclusion=conclusion)), REPOSITORY, SHA))

    def test_jobs_require_all_successful_lanes_and_rollup(self):
        self.assertTrue(complete_jobs(job_records()))
        for name in LANES:
            missing = job_records()
            missing['jobs'] = [job for job in missing['jobs'] if job['name'].rsplit(' / ', 1)[-1] != name]
            missing['total_count'] -= 1
            self.assertFalse(complete_jobs(missing), name)
        for conclusion in ('failure', 'skipped', 'cancelled', None):
            failed = job_records()
            failed['jobs'][0]['conclusion'] = conclusion
            self.assertFalse(complete_jobs(failed))
        truncated = job_records()
        truncated['total_count'] += 1
        self.assertFalse(complete_jobs(truncated))

    def test_partial_rerun_uses_the_newest_execution_of_each_job(self):
        history = job_records()
        previous = dict(history['jobs'][0], id=0, conclusion='failure')
        history['jobs'].append(previous)
        history['total_count'] += 1
        self.assertTrue(complete_jobs(history))
        newer = dict(previous, id=100)
        history['jobs'].append(newer)
        history['total_count'] += 1
        self.assertFalse(complete_jobs(history), 'A newer failure must shadow an older pass')

    def test_job_history_is_paginated_without_losing_required_lanes(self):
        history = job_records()
        def fetch(path):
            page = int(path.rsplit('=', 1)[1])
            return {'total_count': history['total_count'], 'jobs': history['jobs'][:3] if page == 1 else history['jobs'][3:]}
        self.assertTrue(complete_jobs(all_jobs(fetch, REPOSITORY, 20)))
        with self.assertRaises(GateError):
            all_jobs(lambda _: {'total_count': 20, 'jobs': []}, REPOSITORY, 20)

    def test_success_without_complete_jobs_cannot_release(self):
        with self.assertRaises(GateError):
            wait_for_ci(self.client(jobs={'total_count': 0, 'jobs': []}), REPOSITORY, SHA)

    def test_refresh_rejects_changed_commit_identity(self):
        with self.assertRaises(GateError):
            wait_for_ci(self.client(fresh=run_record(head_sha='b' * 40)), REPOSITORY, SHA)

    def test_waits_for_fresh_attempt_instead_of_stale_success(self):
        clock = FakeClock()
        client = self.client()
        calls = []
        def fetch(path):
            if path.endswith('/runs/20'):
                calls.append(path)
                if len(calls) == 1:
                    return run_record(status='in_progress', conclusion=None)
            return client(path)
        self.assertEqual(wait_for_ci(fetch, REPOSITORY, SHA, clock=clock.now, sleep=clock.sleep)['id'], 20)
        self.assertEqual(clock.time, 15)

    def test_absent_ci_has_bounded_grace_then_runs_full_gate(self):
        clock = FakeClock()
        result = wait_for_ci(self.client(listed=[]), REPOSITORY, SHA, grace=30, clock=clock.now, sleep=clock.sleep)
        self.assertIsNone(result)
        self.assertEqual(clock.time, 30)

    def test_wait_timeout_and_api_failure_block_release(self):
        clock = FakeClock()
        with self.assertRaises(GateError):
            wait_for_ci(self.client(fresh=run_record(status='in_progress', conclusion=None)), REPOSITORY, SHA,
                        timeout=30, clock=clock.now, sleep=clock.sleep)
        def offline(_): raise OSError('API unavailable')
        with self.assertRaises(OSError): wait_for_ci(offline, REPOSITORY, SHA)

    def test_shards_preserve_every_existing_keyboard_regression(self):
        plan = json.loads((ROOT / 'Scripts/keyboard-tests.json').read_text())
        original = {
            'testCommandDeleteUsesConfirmationAndRemovesOnlySelectedTask',
            'testCommandSelectAllAndDeleteRespectFilteredTaskList',
            'testCommandFindAndTextDeletionDoNotRemoveSelectedDownload',
            'testCommandPasteInTaskListOpensImportAndSheetKeepsTextShortcuts',
            'testCommandNewFromSettingsUsesOneDownloadWindow',
            'testLaunchPresentsDownloadsWithoutAutomaticWindowAndAfterRelaunch',
            'testShowDownloadsRestoresClosedAndMinimizedMainWindow',
            'testDoubleClickOpensDetailsWithoutPausingOrResuming',
            'testCommandFindSearchesSettingsAndSelectsExistingQuery',
            'testPasteDownloadFromSettingsReturnsToMainWindow',
            'testEmptyClipboardShowsFeedbackInAboutWindow',
        }
        self.assertEqual(set(plan), {'a', 'b'})
        self.assertFalse(set(plan['a']) & set(plan['b']))
        self.assertEqual(set(plan['a'] + plan['b']), original)
        self.assertEqual(len(plan['a'] + plan['b']), len(original))
        source = (ROOT / 'ChopChopUITests/ChopChopUITests.swift').read_text()
        for name in original: self.assertRegex(source, r'func ' + re.escape(name) + r'\(')


if __name__ == '__main__':
    unittest.main()
