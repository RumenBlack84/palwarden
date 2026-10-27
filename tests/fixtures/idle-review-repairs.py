#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
"""Final idle/knock review regressions; no installed service/notify operations."""
import importlib.machinery
import importlib.util
import io
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from contextlib import redirect_stdout, redirect_stderr
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "lib"))
import palwarden_lifecycle as lc
import palwarden_presence as presence


def load(name, path):
    loader = importlib.machinery.SourceFileLoader(name, str(path))
    spec = importlib.util.spec_from_loader(name, loader)
    assert spec is not None
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    loader.exec_module(mod)
    return mod


class ReviewRepairs(unittest.TestCase):
    def setUp(self):
        # Honor an explicit scratch root, but TMPDIR is optional on CI/hosts.
        self.tmp = tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR") or None,
                                             prefix="idle-repairs-")
        self.addCleanup(self.tmp.cleanup)
        self.work = Path(self.tmp.name)
        env = patch.dict(os.environ, {
            "PYTHONPATH": str(ROOT / "lib"),
            "PALWARDEN_LIFECYCLE_LOCK": str(self.work / "lock"),
            "PALWARDEN_LIFECYCLE_STATE_DIR": str(self.work / "state"),
            "PALWORLD_KNOCK_COOLDOWN_FILE": str(self.work / "cooldown"),
            "PALWARDEN_PARSER_BIN": str(ROOT / "bin/palworld-config-parser"),
            "PALWARDEN_JOBS_DIR": str(self.work / "jobs"),
        })
        env.start()
        self.addCleanup(env.stop)
        # No inherited transaction from the test runner may bypass these cases.
        os.environ.pop(lc.FD_ENV, None)
        os.environ.pop(lc.TXN_ENV, None)
        self.before = lc.ensure_state()
        self.cfg = dict(IDLE_TIMEOUT=1, IDLE_CHECK_INTERVAL=60,
                        KNOCK_ENABLED=True, KNOCK_COOLDOWN=600, KNOCK_TOKEN="")

    def lock_free(self):
        # A different open file description, not the current holder's fd.
        fd = lc.acquire(timeout=0)
        lc.release(fd)

    def executable(self, name, body):
        p = self.work / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text("#!/bin/sh\n" + body)
        p.chmod(0o755)
        return p

    def test_bridge_refuses_failed_idle_publication(self):
        self.bridge_failure("idle")

    def test_bridge_refuses_failed_abandoned_escalation(self):
        self.bridge_failure("active")

    def bridge_failure(self, initial):
        lc.write_state(initial)
        before = lc.read_state()
        mutation = self.work / "mutated"
        # Run the real acquire/re-exec bridge. Inject only its state-write I/O.
        # Active escalation fails while active writes would succeed, detecting
        # the old best-effort escalate-then-overwrite path specifically.
        driver = '''import sys
import palwarden_lifecycle as lc
real = lc._atomic_write_state
def fail(path, state):
    if sys.argv[1] == 'idle' or state['status'] == 'unsafe':
        raise lc.LifecycleError('injected state storage failure')
    return real(path, state)
lc._atomic_write_state = fail
raise SystemExit(lc.main(['acquire', '--timeout', '0', '--', sys.executable,
    '-c', 'import pathlib,sys; pathlib.Path(sys.argv[1]).touch()', sys.argv[2]]))
'''
        r = subprocess.run([sys.executable, "-c", driver, initial, str(mutation)],
                           capture_output=True, text=True, timeout=10)
        self.assertFalse(mutation.exists(), r.stderr)
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(lc.read_state(), before)
        self.lock_free()

    def jobd(self):
        return load("final_jobd", ROOT / "sbin/palwarden-jobd")

    def test_begin_initializes_and_preserves_recovery_markers(self):
        (self.work / "state/state.json").unlink()
        fd = lc.acquire(timeout=0)
        try:
            self.assertTrue(lc.begin_transaction("maintenance"))
            self.assertEqual(lc.read_state()["status"], "active")
            self.assertFalse(lc.begin_transaction("restore"))
            self.assertEqual(lc.read_state()["status"], "unsafe")
            unsafe = lc.read_state()
            with patch.object(lc, "_atomic_write_state", side_effect=AssertionError("unsafe rewritten")):
                self.assertFalse(lc.begin_transaction("update"))
            self.assertEqual(lc.read_state(), unsafe)
        finally:
            lc.release(fd)

    def test_jobd_releases_on_begin_or_handoff_interrupt(self):
        mod = self.jobd()
        for point in ("begin_transaction", "ownership_env"):
            with self.subTest(point=point):
                lc.write_state("idle", force=True)
                job = mod.jobs.create_job("graceful_restart", {"confirm": True, "wait": 0})
                with patch.object(lc, point, side_effect=KeyboardInterrupt("fixture interrupt")), \
                     patch.object(mod, "_execute_job") as execute:
                    with self.assertRaises(KeyboardInterrupt):
                        mod.run_job(job)
                execute.assert_not_called()
                self.assertEqual(lc.read_state()["status"], "idle" if point == "begin_transaction" else "unsafe")
                self.lock_free()

    def test_jobd_publication_failure_runs_no_steps(self):
        mod = self.jobd()
        job = mod.jobs.create_job("graceful_restart", {"confirm": True, "wait": 0})
        with patch.object(lc, "_atomic_write_state", side_effect=lc.LifecycleError("write failed")), \
             patch.object(mod, "_execute_job", return_value=0) as execute:
            rc = mod.run_job(job)
        self.assertNotEqual(rc, 0)
        execute.assert_not_called()
        self.assertEqual(lc.read_state(), self.before)
        self.assertEqual(mod.jobs.read_job(job["id"])["state"], "failed")
        self.lock_free()

    def test_restore_publication_failure_does_not_stop_or_complete(self):
        mod = load("final_restore", ROOT / "sbin/palworld-restore")
        saved = self.work / "Saved"
        saved.mkdir()
        (saved / "world").write_text("original")
        src = self.work / "backup"
        src.write_bytes(b"fixture archive boundary")
        # Archive preflight and safety backup are isolated boundaries; retain
        # actual restore controller, lifecycle begin/release and scratch cleanup.
        with patch.multiple(mod, SAVED_DIR=saved), \
             patch.object(mod, "_require_answerable_service_state"), \
             patch.object(mod, "_backup_path", return_value=src), \
             patch.object(mod, "_open_scratch_dir", side_effect=lambda: os.open(self.work, os.O_RDONLY)), \
             patch.object(mod, "_scratch_copy", return_value=None), \
             patch.object(mod, "_validate_scratch", return_value=({"members": 1, "bytes": 1}, None)), \
             patch.object(mod, "_safety_backup", return_value="fixture-safety"), \
             patch.object(mod, "_graceful_stop", side_effect=RuntimeError("stop reached")) as stop, \
             patch.object(mod, "_run") as run, \
             patch.object(lc, "_atomic_write_state", side_effect=lc.LifecycleError("write failed")), \
             redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            with self.assertRaises((mod.archive.ArchiveError, RuntimeError)):
                mod.restore_archive("fixture")
        stop.assert_not_called()
        run.assert_not_called()
        self.assertEqual((saved / "world").read_text(), "original")
        self.assertEqual(lc.read_state(), self.before)
        self.assertIsNone(mod._lifecycle_fd)
        self.lock_free()

    def test_restore_releases_on_cleanup_and_completion_interrupt(self):
        mod = load("final_restore_cleanup", ROOT / "sbin/palworld-restore")
        saved = self.work / "Saved"
        saved.mkdir()
        scratch = self.work / "scratch-copy"
        scratch.touch()
        real_write = lc.write_state
        for point in ("cleanup", "completion"):
            with self.subTest(point=point):
                lc.write_state("idle", force=True)
                def write(status, *args, **kwargs):
                    if point == "completion" and status == "unsafe":
                        raise KeyboardInterrupt("fixture completion interrupt")
                    return real_write(status, *args, **kwargs)
                with patch.multiple(mod, SAVED_DIR=saved), \
                     patch.object(mod, "_require_answerable_service_state"), \
                     patch.object(mod, "_backup_path", return_value=scratch), \
                     patch.object(mod, "_open_scratch_dir", side_effect=lambda: os.open(self.work, os.O_RDONLY)), \
                     patch.object(mod, "_scratch_copy", return_value=scratch), \
                     patch.object(mod, "_validate_scratch", return_value=({"members": 1, "bytes": 1}, None)), \
                     patch.object(mod, "_safety_backup", return_value="fixture-safety"), \
                     patch.object(mod, "_graceful_stop", side_effect=RuntimeError("fixture stop failure")), \
                     patch.object(mod, "_unlink_quietly_at", side_effect=KeyboardInterrupt("fixture cleanup interrupt") if point == "cleanup" else None), \
                     patch.object(lc, "write_state", side_effect=write), \
                     redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                    with self.assertRaises(KeyboardInterrupt):
                        mod.restore_archive("fixture")
                self.assertIsNone(mod._lifecycle_fd)
                self.lock_free()

    def watcher(self):
        mod = load("final_idle", ROOT / "sbin/palworld-idle-watch")
        db = self.work / "metrics.sqlite3"
        con = sqlite3.connect(db)
        presence.create_schema(con)
        now = int(time.time() * 1000)
        for age in (180000, 120000, 60000, 1000):
            presence.apply_observation(con, presence.reserve_observation(con), True, [], now - age)
        con.close()
        deps = {"config": lambda: dict(self.cfg), "state": lambda: "running",
                "uptime_s": lambda: 3600, "db_path": str(db),
                "fetch_players": lambda: [], "notify": lambda *_: None,
                "event": lambda *_: None}
        return mod, deps

    def test_idle_cancel_preserves_existing_unsafe(self):
        mod, deps = self.watcher()
        lc.write_state("unsafe", operation="restore")
        before = lc.read_state()
        real_begin = lc.begin_transaction
        def begin(*args):
            result = real_begin(*args)
            self.cfg["IDLE_TIMEOUT"] = 0
            return result
        with patch.object(lc, "begin_transaction", side_effect=begin), \
             patch.object(mod, "_stop_server") as stop:
            self.assertEqual(mod.tick(deps), "abort final=config")
        stop.assert_not_called()
        self.assertEqual(lc.read_state(), before)
        self.lock_free()

    def test_idle_publication_failure_prevents_stop(self):
        mod, deps = self.watcher()
        with patch.object(lc, "_atomic_write_state", side_effect=lc.LifecycleError("write failed")), \
             patch.object(mod, "_stop_server", return_value=True) as stop:
            decision = mod.tick(deps)
        stop.assert_not_called()
        self.assertIn("abort", decision)
        self.assertEqual(lc.read_state(), self.before)
        self.lock_free()

    def test_idle_policy_change_during_publication(self):
        mod, deps = self.watcher()
        real = lc._atomic_write_state
        for new_timeout in (0, 120):
            with self.subTest(timeout=new_timeout):
                self.cfg["IDLE_TIMEOUT"] = 1
                lc.write_state("idle", force=True)
                def flip(path, state):
                    real(path, state)
                    if state["status"] == "active":
                        self.cfg["IDLE_TIMEOUT"] = new_timeout
                with patch.object(lc, "_atomic_write_state", side_effect=flip), \
                     patch.object(mod, "_stop_server", return_value=True) as stop:
                    decision = mod.tick(deps)
                stop.assert_not_called()
                self.assertIn("abort final=", decision)
                self.assertEqual(lc.read_state()["status"], "idle")
                self.lock_free()

    def test_update_check_never_changes_lifecycle(self):
        install = self.work / "server"
        manifest = install / "steamapps/appmanifest_2394010.acf"
        manifest.parent.mkdir(parents=True)
        manifest.write_text('"buildid" "99"\n')
        steam = self.executable("steamcmd", 'printf \'"branches"\\n"public"\\n"buildid" "100"\\n\'\n')
        for initial in ("idle", "unsafe"):
            for expected_rc in (10, 0, 1):
                with self.subTest(initial=initial, rc=expected_rc):
                    lc.write_state(initial, force=True)
                    before = lc.read_state()
                    manifest.write_text('"buildid" "%s"\n' % ("100" if expected_rc == 0 else "99"))
                    env = dict(os.environ, PALWORLD_INSTALL_DIR=str(install),
                               PALWORLD_STEAMCMD=str(steam if expected_rc != 1 else self.work / "missing-steamcmd"),
                               PALWORLD_DROP_PRIV="", PALWARDEN_LIB_DIR=str(ROOT / "lib"))
                    # --check in message text alone must NOT bypass enrollment;
                    # here it is also an actual flag, and original argv survives.
                    r = subprocess.run([str(ROOT / "sbin/palworld-update"), "--message", "check fixture", "--wait", "0", "--check"],
                                       env=env, capture_output=True, text=True, timeout=10)
                    self.assertEqual(r.returncode, expected_rc, r.stderr)
                    self.assertEqual(lc.read_state(), before)
                    self.lock_free()

        # A value spelling --check is not an option. Preserve original argv
        # through re-exec and still enroll this ordinary already-current run.
        lc.write_state("idle", force=True)
        before = lc.read_state()
        manifest.write_text('"buildid" "100"\n')
        env = dict(os.environ, PALWORLD_INSTALL_DIR=str(install), PALWORLD_STEAMCMD=str(steam),
                   PALWORLD_DROP_PRIV="", PALWARDEN_LIB_DIR=str(ROOT / "lib"))
        r = subprocess.run([str(ROOT / "sbin/palworld-update"), "--message", "--check", "--wait", "0"],
                           env=env, capture_output=True, text=True, timeout=10)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotEqual(lc.read_state()["generation"], before["generation"])

    def test_queued_check_does_not_publish_maintenance(self):
        mod = self.jobd()
        for initial in ("idle", "unsafe"):
            for code in (10, 1):
                with self.subTest(initial=initial, rc=code):
                    lc.write_state(initial, force=True)
                    before = lc.read_state()
                    job = mod.jobs.create_job("update_check", {"confirm": True})
                    with patch.object(mod, "_execute_job", return_value=code):
                        self.assertEqual(mod.run_job(job), code)
                    self.assertEqual(lc.read_state(), before)
                    self.lock_free()

    def test_unrelated_shim_does_not_change_game_marker(self):
        bins = self.work / "bin"
        self.executable("bin/s6-svc", "exit 0\n")
        game = self.work / "services/palworld-server"
        game.mkdir(parents=True)
        (game.parent / "aux").mkdir()
        env = dict(os.environ, PATH=str(bins) + ":" + os.environ["PATH"],
                   PALWARDEN_LIB_DIR=str(ROOT / "lib"), PALWARDEN_S6_SVC_DIR=str(game.parent))
        for stopped in (True, False):
            for cmd in ("start", "stop", "restart"):
                with self.subTest(stopped=stopped, cmd=cmd):
                    if stopped:
                        (game / "down").touch()
                    else:
                        (game / "down").unlink(missing_ok=True)
                    r = subprocess.run([str(ROOT / "docker/shims/systemctl"), cmd, "aux.service"],
                                       env=env, capture_output=True, text=True, timeout=10)
                    self.assertEqual(r.returncode, 0, r.stderr)
                    self.assertEqual((game / "down").exists(), stopped)

    def test_unverified_wake_requires_running_service(self):
        for final_state in ("crash-backoff", "unknown", "running"):
            with self.subTest(final_state=final_state):
                (self.work / "cooldown").unlink(missing_ok=True)
                state = {"value": "stopped"}
                def starter(*_):
                    state["value"] = "running"
                def readiness():
                    state["value"] = final_state
                    return "unverified"
                fd = lc.acquire(timeout=0)
                try:
                    with patch.object(lc, "service_state", side_effect=lambda *_: state["value"]), \
                         patch.object(lc, "_start_service", side_effect=starter), \
                         patch.object(lc, "_readiness", side_effect=readiness), \
                         patch.object(lc, "_notify") as notify:
                        result = lc.start_if_down(fd, config=self.cfg)
                finally:
                    lc.release(fd)
                self.assertEqual(notify.call_count, 1)
                if final_state == "running":
                    self.assertEqual(result["status"], "started")
                    self.assertEqual(result["readiness"], "unverified")
                else:
                    self.assertEqual(result["status"], "error")
                    self.assertNotIn("UNVERIFIED", notify.call_args.args[1])


if __name__ == "__main__":
    unittest.main(verbosity=2)
