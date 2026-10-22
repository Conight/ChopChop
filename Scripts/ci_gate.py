#!/usr/bin/env python3
"""Reuse only complete, successful push-to-main verification of the exact source SHA.

No CI build artifact, executable, cache, or PR output is consumed by the signer.
"""
import argparse
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request

LANES = {'policy', 'native', 'keyboard-a', 'keyboard-b', 'integration', 'test'}


class GateError(RuntimeError):
    pass


def trusted_run(run, repository, sha):
    return (run.get('head_sha') == sha and run.get('event') == 'push'
            and run.get('head_branch') == 'main'
            and run.get('path', '').split('@')[0] == '.github/workflows/ci.yml'
            and run.get('repository', {}).get('full_name') == repository
            and run.get('head_repository', {}).get('full_name') == repository)


def latest_run(runs, repository, sha):
    candidates = [run for run in runs if trusted_run(run, repository, sha)]
    return max(candidates, key=lambda run: int(run['id']), default=None)


def complete_jobs(payload):
    jobs = payload.get('jobs', [])
    latest = {}
    for job in jobs:
        name = job.get('name', '')
        if name not in latest or int(job['id']) > int(latest[name]['id']):
            latest[name] = job
    return (payload.get('total_count') == len(jobs)
            and LANES <= {name.rsplit(' / ', 1)[-1] for name in latest}
            and all(job.get('status') == 'completed' and job.get('conclusion') == 'success' for job in latest.values()))


def all_jobs(client, repository, run_id):
    jobs = []
    total = None
    for page in range(1, 21):
        payload = client(f'/repos/{repository}/actions/runs/{int(run_id)}/jobs?filter=all&per_page=100&page={page}')
        count = payload['total_count']
        if total is not None and count != total:
            raise GateError('CI job history changed during verification')
        total = count
        jobs.extend(payload['jobs'])
        if len(jobs) >= total:
            return {'total_count': total, 'jobs': jobs}
        if not payload['jobs']:
            break
    raise GateError('Could not read the complete CI job history')


def wait_for_ci(client, repository, sha, timeout=1800, grace=60, clock=time.monotonic, sleep=time.sleep):
    started = clock()
    query = urllib.parse.urlencode({'head_sha': sha, 'event': 'push', 'branch': 'main', 'per_page': 100})
    previous = None
    while True:
        runs = client(f'/repos/{repository}/actions/workflows/ci.yml/runs?{query}')['workflow_runs']
        run = latest_run(runs, repository, sha)
        if run is None:
            state = 'Waiting briefly for a push-to-main CI run for this exact SHA'
            if clock() - started >= grace:
                return None
        else:
            # Refresh the selected record: a rerun may have started after the list was read.
            run = client(f'/repos/{repository}/actions/runs/{int(run["id"])}')
            if not trusted_run(run, repository, sha):
                raise GateError('CI identity changed while checking verification')
            state = f'CI run {run["id"]}: {run["status"]} / {run.get("conclusion")}'
            if run['status'] == 'completed':
                conclusion = run.get('conclusion')
                if conclusion in ('cancelled', 'skipped'):
                    return None  # A newer main push may cancel this SHA; verify it independently.
                if conclusion != 'success':
                    raise GateError(f'Exact-SHA CI did not pass: {conclusion}')
                jobs = all_jobs(client, repository, run['id'])
                if not complete_jobs(jobs):
                    raise GateError('CI is missing a successful required lane or final test check')
                confirmed = client(f'/repos/{repository}/actions/runs/{int(run["id"])}')
                if (not trusted_run(confirmed, repository, sha) or confirmed.get('status') != 'completed'
                        or confirmed.get('conclusion') != 'success' or confirmed.get('run_attempt') != run.get('run_attempt')):
                    raise GateError('CI attempt changed while checking verification')
                return confirmed
        if state != previous:
            print(state, flush=True)
            previous = state
        if clock() - started >= timeout:
            raise GateError('Timed out waiting for exact-SHA CI; release remains blocked')
        sleep(min(15, max(1, timeout - (clock() - started))))


def api_client(path):
    base = os.environ.get('GITHUB_API_URL', 'https://api.github.com')
    token = os.environ.get('GH_TOKEN') or os.environ.get('GITHUB_TOKEN')
    if not token:
        raise GateError('A read-only Actions token is required')
    request = urllib.request.Request(base + path, headers={
        'Authorization': f'Bearer {token}', 'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2026-03-10', 'User-Agent': 'ChopChop-release-gate'})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repository', required=True)
    parser.add_argument('--sha', required=True)
    parser.add_argument('--timeout', type=int, default=1800)
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', args.repository) or not re.fullmatch(r'[a-f0-9]{40}', args.sha) or args.timeout < 60:
        parser.error('Expected a repository, full commit SHA, and timeout of at least 60 seconds')
    try:
        run = wait_for_ci(api_client, args.repository, args.sha, timeout=args.timeout)
    except (GateError, OSError, ValueError, KeyError) as error:
        sys.exit(f'Verification gate refused release: {error}')
    reused = run is not None
    source = f'https://github.com/{args.repository}/actions/runs/{run["id"]}' if reused else ''
    message = f'Reuse exact-SHA CI: {source}' if reused else 'No reusable CI result; run all verification lanes'
    print(message)
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        output.write(f'reuse={str(reused).lower()}\nci_run_url={source}\n')
    if summary := os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(summary, 'a') as output:
            output.write(f'### Release verification\n\nSource commit: `{args.sha}`\n\n{message}\n')


if __name__ == '__main__':
    main()
