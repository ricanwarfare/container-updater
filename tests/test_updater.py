"""Behavioral regression tests; never invoke a real Docker daemon."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'updater.sh'
FAKE_DOCKER = r'''#!/usr/bin/env python3
import json, os, sys, time
from pathlib import Path
args = sys.argv[1:]
with open(os.environ['CALLS'], 'a') as f:
    f.write(json.dumps({'cwd': os.getcwd(), 'args': args}) + '\n')
mode = os.environ.get('MODE', '')
if args == ['info']:
    if mode == 'hold': time.sleep(2)
    sys.exit(1 if mode == 'daemon_fail' else 0)
if args == ['compose', 'version']: sys.exit(1 if mode == 'compose_fail' else 0)
if args[:2] == ['compose', 'ps']:
    if mode == 'ps_fail': sys.exit(1)
    status = args[args.index('--status')+1]
    if status == 'exited': print('opted\nunlabelled')
    elif status == 'running' and mode != 'empty':
        print('web')
        print('a warning on stderr', file=sys.stderr)
    elif status == 'restarting' and mode == 'duplicates': print('web\nworker')
    sys.exit(0)
if args[0] == 'inspect':
    print('always|true' if args[-1] == 'opted' else 'always|<no value>')
    sys.exit(0)
if args[0] == 'start': sys.exit(1 if mode == 'start_fail' else 0)
if args[:2] == ['compose', 'pull']:
    counter = Path(os.environ['CALLS'] + '.counter')
    n = int(counter.read_text()) + 1 if counter.exists() else 1
    counter.write_text(str(n))
    sys.exit(1 if mode == 'pull_fail' or (mode == 'retry' and n == 1) else 0)
if args[:2] == ['compose', 'up']: sys.exit(1 if mode == 'up_fail' else 0)
if args[:2] == ['image', 'prune']: sys.exit(1 if mode == 'prune_fail' else 0)
print('unexpected arguments', args, file=sys.stderr)
sys.exit(2)
'''


class UpdaterTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='updater test ')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        shutil.copy2(SCRIPT, self.root / 'updater.sh')
        self.base = self.root / 'stacks'
        self.stack = self.base / 'app'
        self.stack.mkdir(parents=True)
        (self.stack / 'compose.yaml').write_text('services: {}\n')
        self.docker = self.root / 'docker'
        self.docker.write_text(FAKE_DOCKER)
        self.docker.chmod(0o755)
        self.env = {k: v for k, v in os.environ.items() if k in ('PATH', 'HOME', 'LANG')}
        self.env.update(BASE_DIR=str(self.base), DOCKER_BIN=str(self.docker),
                        LOG_FILE='logs/run.log', LOCK_FILE='locks/run.lock',
                        PULL_RETRY_DELAY='0', AUTOSTART_RETRY_DELAY='0',
                        CALLS=str(self.root / 'calls'))

    def run_updater(self, args=(), **env):
        return subprocess.run(['bash', str(self.root / 'updater.sh'), *args],
                              env={**self.env, **env}, cwd=self.root,
                              capture_output=True, text=True, timeout=10)

    def calls(self, prefix=()):
        path = self.root / 'calls'
        calls = [json.loads(s) for s in path.read_text().splitlines()] if path.exists() else []
        return [c for c in calls if c['args'][:len(prefix)] == list(prefix)]

    def test_updates_only_active_services_with_bounded_wait(self):
        result = self.run_updater(MODE='duplicates')
        self.assertEqual(result.returncode, 0, result.stderr)
        up = self.calls(('compose', 'up'))[0]
        self.assertEqual(up['cwd'], str(self.stack))
        self.assertEqual(up['args'], ['compose', 'up', '-d', '--no-deps', '--wait',
                                     '--wait-timeout', '300', 'web', 'worker'])
        self.assertEqual(self.calls(('compose', 'pull'))[0]['args'], ['compose', 'pull', 'web', 'worker'])
        self.assertTrue((self.root / 'logs/run.log').exists())
        self.assertFalse((self.stack / 'logs').exists())

    def test_inline_dry_run_overrides_config_and_does_not_mutate(self):
        (self.root / '.env').write_text('DRY_RUN=false\nBASE_DIR=/does/not/exist\n')
        result = self.run_updater(DRY_RUN='true', AUTOSTART='true')
        self.assertEqual(result.returncode, 0, result.stderr)
        for prefix in [('start',), ('compose', 'pull'), ('compose', 'up'), ('image',)]:
            self.assertFalse(self.calls(prefix))

    def test_failures_are_nonzero_and_continue_to_next_stack(self):
        other = self.base / 'second'
        other.mkdir()
        (other / 'docker-compose.yml').touch()
        result = self.run_updater(MODE='up_fail')
        self.assertEqual(result.returncode, 1)
        self.assertEqual(len(self.calls(('compose', 'up'))), 2)
        self.assertFalse(self.calls(('image',)))

    def test_pull_failure_retries_without_up_or_prune(self):
        self.assertEqual(self.run_updater(MODE='pull_fail', PULL_RETRIES='2').returncode, 1)
        self.assertEqual(len(self.calls(('compose', 'pull'))), 2)
        self.assertFalse(self.calls(('compose', 'up')))
        self.assertFalse(self.calls(('image',)))

    def test_transient_pull_failure_recovers(self):
        self.assertEqual(self.run_updater(MODE='retry').returncode, 0)
        self.assertEqual(len(self.calls(('compose', 'pull'))), 2)
        self.assertEqual(len(self.calls(('compose', 'up'))), 1)

    def test_status_failure_is_nonzero(self):
        self.assertEqual(self.run_updater(MODE='ps_fail').returncode, 1)
        self.assertFalse(self.calls(('compose', 'pull')))

    def test_daemon_failure_is_nonzero(self):
        self.assertEqual(self.run_updater(MODE='daemon_fail').returncode, 1)
        self.assertEqual(len(self.calls()), 1)

    def test_prune_failure_is_nonzero(self):
        self.assertEqual(self.run_updater(MODE='prune_fail').returncode, 1)

    def test_no_active_services_are_not_started(self):
        self.assertEqual(self.run_updater(MODE='empty').returncode, 0)
        self.assertFalse(self.calls(('compose', 'pull')))
        self.assertFalse(self.calls(('compose', 'up')))
        self.assertFalse(self.calls(('start',)))

    def test_exclusion_also_applies_to_autostart(self):
        self.assertEqual(self.run_updater(EXCLUDE_DIRS='app', AUTOSTART='true').returncode, 0)
        self.assertFalse(self.calls(('compose', 'ps')))
        self.assertFalse(self.calls(('start',)))
        self.assertFalse(self.calls(('image',)))

    def test_autostart_requires_explicit_label(self):
        self.assertEqual(self.run_updater(AUTOSTART='true').returncode, 0)
        self.assertEqual([c['args'] for c in self.calls(('start',))], [['start', 'opted']])

    def test_autostart_failure_retries_and_is_nonzero(self):
        self.assertEqual(self.run_updater(AUTOSTART='true', MODE='start_fail').returncode, 1)
        self.assertEqual(len(self.calls(('start',))), 2)

    def test_invalid_configuration_fails_before_docker(self):
        for key, value in [('DRY_RUN', 'yes'), ('PULL_RETRIES', '0'),
                           ('PULL_RETRIES', '08'), ('WAIT_TIMEOUT', '-1'),
                           ('LOG_MAX_SIZE_KB', 'abc')]:
            with self.subTest(key=key, value=value):
                self.assertEqual(self.run_updater(**{key: value}).returncode, 1)
                self.assertFalse(self.calls())

    def test_lock_recovers_from_stale_contents(self):
        (self.root / 'locks').mkdir()
        (self.root / 'locks/run.lock').write_text('99999999\n')
        (self.root / 'locks/run.lock.d').mkdir()
        self.assertEqual(self.run_updater().returncode, 0)
        self.assertEqual(self.run_updater().returncode, 0)

    def test_concurrent_run_is_rejected(self):
        process = subprocess.Popen(['bash', str(self.root / 'updater.sh')],
                                   env={**self.env, 'MODE': 'hold'}, cwd=self.root,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 3
            while not self.calls() and time.monotonic() < deadline:
                time.sleep(.02)
            self.assertTrue(self.calls())
            result = self.run_updater()
            self.assertEqual(result.returncode, 1)
            self.assertIn('already running', result.stderr)
            self.assertEqual(process.wait(timeout=6), 0)
        finally:
            if process.poll() is None: process.kill()
            process.communicate()

    def test_killed_run_releases_lock_after_children_exit(self):
        process = subprocess.Popen(['bash', str(self.root / 'updater.sh')],
                                   env={**self.env, 'MODE': 'hold'}, cwd=self.root,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 3
            while not self.calls() and time.monotonic() < deadline:
                time.sleep(.02)
            self.assertTrue(self.calls())
            process.kill()
            process.communicate(timeout=5)
            # The in-flight Docker child intentionally retains the lock until exit.
            released = subprocess.run(['flock', '-w', '5',
                                       str(self.root / 'locks/run.lock'), 'true'],
                                      timeout=6)
            self.assertEqual(released.returncode, 0)
            self.assertEqual(self.run_updater().returncode, 0)
        finally:
            if process.poll() is None: process.kill()
            process.communicate()

    def test_missing_compose_fails_before_updates(self):
        self.assertEqual(self.run_updater(MODE='compose_fail').returncode, 1)
        self.assertFalse(self.calls(('compose', 'ps')))

    def test_dry_run_failure_does_not_send_webhook(self):
        bindir = self.root / 'bin'
        bindir.mkdir()
        curl = bindir / 'curl'
        curl.write_text('#!/bin/bash\ntouch "$CALLS.webhook"\n')
        curl.chmod(0o755)
        result = self.run_updater(DRY_RUN='true', MODE='ps_fail',
                                  NOTIFY_FAILURE_WEBHOOK='https://example.invalid',
                                  PATH=str(bindir) + ':' + self.env['PATH'])
        self.assertEqual(result.returncode, 1)
        self.assertFalse((self.root / 'calls.webhook').exists())

    def test_log_and_lock_cannot_share_path(self):
        result = self.run_updater(LOG_FILE='shared', LOCK_FILE='shared')
        self.assertEqual(result.returncode, 1)
        self.assertIn('must be different', result.stderr)
        self.assertFalse(self.calls())

    def test_cli_overrides_configuration(self):
        result = self.run_updater(args=['--dry-run', '--no-prune', '--wait-timeout', '45'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.calls(('compose', 'pull')))
        self.assertIn('--wait-timeout 45', (self.root / 'logs/run.log').read_text())

    def test_cli_help_and_errors_need_no_docker(self):
        self.assertEqual(self.run_updater(args=['--help'], BASE_DIR='/missing').returncode, 0)
        for args in [['--unknown'], ['--base-dir'], ['--wait-timeout', 'no']]:
            self.assertEqual(self.run_updater(args=args).returncode, 1)
        self.assertFalse(self.calls())

    def test_ignore_file_excludes_autostart_and_updates(self):
        (self.stack / '.updaterignore').touch()
        self.assertEqual(self.run_updater(AUTOSTART='true').returncode, 0)
        self.assertFalse(self.calls(('compose', 'ps')))

    def test_hooks_run_and_pre_hook_failure_aborts_update(self):
        (self.stack / 'pre-update.sh').write_text('touch pre-ran\n')
        (self.stack / 'post-update.sh').write_text('touch post-ran\n')
        self.assertEqual(self.run_updater().returncode, 0)
        self.assertTrue((self.stack / 'pre-ran').exists())
        self.assertTrue((self.stack / 'post-ran').exists())
        (self.stack / 'pre-update.sh').write_text('exit 1\n')
        before = len(self.calls(('compose', 'pull')))
        self.assertEqual(self.run_updater().returncode, 1)
        self.assertEqual(len(self.calls(('compose', 'pull'))), before)

    def test_dry_run_and_no_hooks_do_not_execute_hooks(self):
        (self.stack / 'pre-update.sh').write_text('exit 1\n')
        (self.stack / 'post-update.sh').write_text('exit 1\n')
        self.assertEqual(self.run_updater(DRY_RUN='true').returncode, 0)
        self.assertEqual(self.run_updater(args=['--no-hooks']).returncode, 0)

    def test_post_hook_failure_is_reported(self):
        (self.stack / 'post-update.sh').write_text('exit 1\n')
        self.assertEqual(self.run_updater().returncode, 1)
        self.assertFalse(self.calls(('image',)))

    def test_crlf_config_and_legacy_wait_setting(self):
        (self.root / '.env').write_bytes(b'COMPOSE_WAIT_TIMEOUT=45\r\n')
        self.assertEqual(self.run_updater().returncode, 0)
        args = self.calls(('compose', 'up'))[0]['args']
        self.assertEqual(args[args.index('--wait-timeout') + 1], '45')

    def test_success_webhook_summary_and_dry_run_suppression(self):
        bindir = self.root / 'bin'
        bindir.mkdir()
        curl = bindir / 'curl'
        curl.write_text('#!/usr/bin/env python3\nimport os, json, sys\n'
                        'from pathlib import Path\n'
                        'Path(os.environ["CALLS"]+".success").write_text(json.dumps(sys.argv[1:]))\n')
        curl.chmod(0o755)
        config = dict(NOTIFY_SUCCESS_WEBHOOK='https://example.invalid',
                      PATH=str(bindir) + ':' + self.env['PATH'])
        self.assertEqual(self.run_updater(DRY_RUN='true', **config).returncode, 0)
        capture = self.root / 'calls.success'
        self.assertFalse(capture.exists())
        self.assertEqual(self.run_updater(**config).returncode, 0)
        args = json.loads(capture.read_text())
        payload = json.loads(args[args.index('--data') + 1])
        self.assertEqual(payload['updated'], 1)
        self.assertEqual(payload['status'], 'success')
        self.assertEqual(payload['text'], payload['content'])

    def test_rotation_with_spaces_keeps_five_archives(self):
        logs = self.root / 'logs'
        logs.mkdir()
        (logs / 'run.log').write_text('x' * 2048)
        for n in range(7): (logs / f'run.log.2020010100000{n}.gz').touch()
        self.assertEqual(self.run_updater(LOG_MAX_SIZE_KB='1').returncode, 0)
        self.assertEqual(len(list(logs.glob('run.log.*.gz'))), 5)

    def test_webhook_escapes_controls_and_has_timeout(self):
        special = self.base / 'quote"slash\\tab\tline\n'
        self.stack.rename(special)
        bindir = self.root / 'bin'
        bindir.mkdir()
        curl = bindir / 'curl'
        curl.write_text('#!/usr/bin/env python3\nimport os, json, sys\n'
                        'from pathlib import Path\n'
                        'Path(os.environ["CALLS"]+".curl").write_text(json.dumps(sys.argv[1:]))\n')
        curl.chmod(0o755)
        result = self.run_updater(MODE='up_fail', NOTIFY_FAILURE_WEBHOOK='https://example.invalid',
                                  PATH=str(bindir) + ':' + self.env['PATH'])
        self.assertEqual(result.returncode, 1, result.stderr)
        args = json.loads((self.root / 'calls.curl').read_text())
        payload = json.loads(args[args.index('--data') + 1])
        self.assertEqual(payload['service'], str(special))
        self.assertIn('--max-time', args)
        self.assertIn('--fail', args)


if __name__ == '__main__':
    unittest.main()
