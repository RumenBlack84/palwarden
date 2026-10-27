#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
# Harness idioms this file uses deliberately (pinned by ./tests/lint.sh):
#  - SC2015: `cmd && pass ... || fail ...` assertion chains
#  - SC2016: single-quoted python bodies where $VARS expand in the INNER shell
#  - SC2030/SC2031: PALWARDEN_LIFECYCLE_LOCK is re-pointed around subshell
#    harness helpers; the flagged "lost" modifications are not relied on
#    across the subshell boundary (each case re-exports what it needs)
#  - SC2181: helper functions report through markers; $? is the contract
# shellcheck disable=SC2015,SC2016,SC2030,SC2031,SC2181
# Task 2 (idle-shutdown/knock-wake): cross-language lifecycle lock + state/generation.
#
# Spec:  docs/superpowers/specs/2026-10-18-idle-shutdown-knock-wake.md  §4.1, §4.4
# Plan:  docs/superpowers/plans/2026-10-18-idle-shutdown-knock-wake.md (Task 2)
#
# Covers: real-process cross-language exclusion (Python owner vs shell flock and
# vice versa), safe open of the root-owned lock, the inherited-descriptor
# ownership protocol (fd carried in an internal env var, never a bool), the
# CLI re-exec bridge with argv/exit-code/signal preservation, nested
# Python->shell and shell->Python->shell chains without deadlock or LOCK_UN
# from borrowers, and the root-owned state/generation file with
# acknowledge-maintenance recovery.
#
# Coordination uses fifos/pipes/files with deadlines — no guessed sleeps for
# readiness and no mocked lock success.

set -u

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$TEST_DIR/../.." && pwd)"
LIB="$REPO/lib"
source "$REPO/tests/lib/assert.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Exported for python holders/probes that read them from os.environ.
export LIB="$LIB"
export WORK="$WORK"
export PYTHONPATH="$LIB"
export PALWARDEN_LIFECYCLE_LOCK="$WORK/lifecycle.lock"
export PALWARDEN_LIFECYCLE_STATE_DIR="$WORK/lifecycle-state"
export READY_1A="$WORK/ready_1a" GO_1A="$WORK/go_1a"
export READY_2D="$WORK/ready_2d" GO_2D="$WORK/go_2d"
export READY_3C="$WORK/ready_3c" GO_3C="$WORK/go_3c"
export RACE_DIR="$WORK/race" RACE_PY_WON="$WORK/race_py_won"

# A per-case systemctl stub must be installed explicitly; the default must
# never be reached by a test (guards against accidental real service queries).
export PALWARDEN_SYSTEMCTL_BIN="$WORK/no-such-systemctl"

cli() {
    env PYTHONPATH="$LIB" \
        PALWARDEN_LIFECYCLE_LOCK="$PALWARDEN_LIFECYCLE_LOCK" \
        PALWARDEN_LIFECYCLE_STATE_DIR="$PALWARDEN_LIFECYCLE_STATE_DIR" \
        PALWARDEN_SYSTEMCTL_BIN="$PALWARDEN_SYSTEMCTL_BIN" \
        python3 -m palwarden_lifecycle "$@"
}

# wait_file PATH DEADLINE_S — poll with a hard deadline (deadline, not guess)
wait_file() {
    local start now
    start="$(date +%s%N)"
    while [ ! -e "$1" ]; do
        now="$(date +%s%N)"
        if [ $(( (now - start) / 1000000 )) -ge $(( $2 * 1000 )) ]; then
            return 1
        fi
        sleep 0.05
    done
    return 0
}

# run_deadline NAME DEADLINE_S RESULT_FILE -- CMD...
# Run a command in the background; fail the assertion set with a deadlock
# report if it does not finish by the deadline.
run_deadline() {
    local name="$1" deadline="$2" result="$3"
    shift 3
    [ "$1" = "--" ] && shift
    local start now
    "$@" >"$WORK/dl_${name}.log" 2>&1 &
    local pid=$!
    start="$(date +%s%N)"
    while kill -0 "$pid" 2>/dev/null; do
        now="$(date +%s%N)"
        if [ $(( (now - start) / 1000000 )) -ge $(( deadline * 1000 )) ]; then
            kill -9 "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            fail "$name: timed out after ${deadline}s (possible deadlock)"
            return 1
        fi
        sleep 0.05
    done
    wait "$pid"
    local rc=$?
    echo "$rc" >"$result"
    return 0
}

# ---------------------------------------------------------------------------
# 1. Cross-language exclusion (plan step 1): Python owner vs shell flock(1).

# 1a. A Python owner excludes a concurrent shell flock(1) contender.
(
    python3 - <<'EOF'
import os, sys
sys.path.insert(0, os.environ["LIB"])
import palwarden_lifecycle as lc
fd = lc.acquire(timeout=10.0)
with open(os.environ["READY_1A"], "w") as f:
    f.write(str(os.getpid()))
# Hold until the parent signals via the go file.
import time
while not os.path.exists(os.environ["GO_1A"]):
    time.sleep(0.01)
lc.release(fd)
EOF
) &
HOLDER_1A=$!
wait_file "$READY_1A" 10 || fail "1a: python owner never became ready"
# Contender: shell flock(1), non-blocking, must be refused while python holds.
if flock -n "$PALWARDEN_LIFECYCLE_LOCK" true 2>/dev/null; then
    fail "1a: shell flock(1) acquired the lock held by a python owner"
else
    pass "1a: shell flock(1) excluded while python owner holds the lock"
fi
touch "$GO_1A"
rc_h=0
wait "$HOLDER_1A" 2>/dev/null || rc_h=$?
[ "$rc_h" = "0" ] || fail "1a: holder exited non-zero (rc=$rc_h)"
# Lock must be free again after the owner released.
cli acquire >/dev/null 2>&1 && pass "1a: lock free after python owner released" \
    || fail "1a: lock still held after python owner released"

# 1b. A shell flock(1) holder excludes a concurrent python acquire.
(
    exec flock "$PALWARDEN_LIFECYCLE_LOCK" -c "
        touch '$WORK/ready_1b'
        while [ ! -e '$WORK/go_1b' ]; do sleep 0.05; done
    "
) &
HOLDER_1B=$!
wait_file "$WORK/ready_1b" 10 || fail "1b: shell flock holder never became ready"
rc=0
err="$(cli acquire --timeout 2 2>&1 >/dev/null)" || rc=$?
[ "$rc" -ne 0 ] && pass "1b: python acquire refused while shell flock(1) holds (rc=$rc)" \
    || fail "1b: python acquire succeeded while shell flock(1) holds"
assert_contains "$err" "held" "1b: stderr should report the lock is held"
touch "$WORK/go_1b"
wait "$HOLDER_1B" 2>/dev/null

# 1c. Barrier race: exactly one of a python contender and a shell flock
# contender wins the same lock file from a simultaneous start.
RACE="$WORK/race"; rm -rf "$RACE"; mkdir "$RACE"
BARRIER="$RACE/barrier"
mkfifo "$BARRIER"
(
    read -r _ <"$BARRIER"
    # Single-shot: if the lock is taken, give up immediately.
    RACE="$RACE" flock -n "$PALWARDEN_LIFECYCLE_LOCK" -c 'echo shell > "$RACE/winner"' \
        2>/dev/null
    echo shell_attempt_done >>"$RACE/attempts"
) &
SHELL_RACER=$!
(
    read -r _ <"$BARRIER"
    if python3 - <<'EOF'
import os, sys, time
sys.path.insert(0, os.environ["LIB"])
import palwarden_lifecycle as lc
try:
    fd = lc.acquire(timeout=0.3)
except lc.LifecycleError:
    sys.exit(75)
with open(os.environ["RACE_PY_WON"], "w") as f:
    f.write("python")
# Hold a beat so the other single-shot contender cannot win after us.
time.sleep(0.4)
lc.release(fd)
EOF
    then
        echo python >"$RACE/winner"
    else
        echo python_attempt_done >>"$RACE/attempts"
    fi
) &
PY_RACER=$!
# Release the barrier: one writer subshell per reader. A single write end
# writing both lines closes before the second reader's open, and the kernel
# then makes that open wait for a writer that never comes (verified hang).
for _ in 1 2; do
    echo go >"$BARRIER" &
done
wait "$SHELL_RACER" 2>/dev/null
wait "$PY_RACER" 2>/dev/null
[ -f "$RACE/winner" ] && pass "1c: race produced a winner" \
    || fail "1c: race produced no winner"
nwinners=$(grep -c . "$RACE/winner" 2>/dev/null || echo 0)
assert_eq "$nwinners" "1" "1c: exactly one winner"

# ---------------------------------------------------------------------------
# 2. Safe open of the lock (plan step 2).

# 2a. Symlink lock path is refused.
LN="$WORK/ln.lock"
ln -s "$WORK/target.lock" "$LN"
rc=0
err="$(
    export PALWARDEN_LIFECYCLE_LOCK="$LN"
    cli acquire 2>&1 >/dev/null
)" || rc=$?
[ "$rc" -ne 0 ] && pass "2a: symlink lock path refused (rc=$rc)" \
    || fail "2a: symlink lock path was accepted"
assert_contains "$err" "symlink" "2a: error should name the symlink refusal"

# 2b. Non-regular lock path (fifo) is refused.
FIFO_LOCK="$WORK/fifo.lock"
mkfifo "$FIFO_LOCK"
rc=0
err="$(
    export PALWARDEN_LIFECYCLE_LOCK="$FIFO_LOCK"
    cli acquire 2>&1 >/dev/null
)" || rc=$?
[ "$rc" -ne 0 ] && pass "2b: fifo lock path refused (rc=$rc)" \
    || fail "2b: fifo lock path was accepted"

# 2c. Trust check runs even with a test override: a symlinked parent dir is
# untrusted; a fixture-owned (euid-owned) parent is trusted.
SYMPARENT="$WORK/symparent"
ln -s "$WORK" "$SYMPARENT"
rc=0
err="$(
    export PALWARDEN_LIFECYCLE_LOCK="$SYMPARENT/x.lock"
    cli acquire 2>&1 >/dev/null
)" || rc=$?
[ "$rc" -ne 0 ] && pass "2c: symlinked parent dir untrusted even under test override" \
    || fail "2c: symlinked parent dir accepted"
TRUSTED="$WORK/trusted"; mkdir -p "$TRUSTED"
(
    export PALWARDEN_LIFECYCLE_LOCK="$TRUSTED/lock"
    cli acquire >/dev/null 2>&1
) && pass "2c: fixture-owned trusted parent accepted under override" \
    || fail "2c: fixture-owned parent refused"

# 2d. Non-blocking (timeout 0) and bounded wait (measured deadline).
(
    python3 - <<'EOF'
import os, sys, time
sys.path.insert(0, os.environ["LIB"])
import palwarden_lifecycle as lc
fd = lc.acquire(timeout=10.0)
with open(os.environ["READY_2D"], "w") as f:
    f.write(str(os.getpid()))
while not os.path.exists(os.environ["GO_2D"]):
    time.sleep(0.01)
lc.release(fd)
EOF
) &
HOLDER_2D=$!
wait_file "$READY_2D" 10 || fail "2d: holder never became ready"
rc=0
cli acquire --timeout 0 2>/dev/null || rc=$?
[ "$rc" -eq 75 ] && pass "2d: non-blocking acquire returns 75 immediately when held" \
    || fail "2d: non-blocking acquire rc=$rc (want 75)"
t0="$(date +%s%N)"
rc=0
cli acquire --timeout 2 2>/dev/null || rc=$?
t1="$(date +%s%N)"
elapsed_ms=$(( (t1 - t0) / 1000000 ))
[ "$rc" -eq 75 ] && pass "2d: bounded wait timed out (rc=75)" \
    || fail "2d: bounded wait rc=$rc (want 75)"
[ "$elapsed_ms" -ge 1200 ] && [ "$elapsed_ms" -lt 10000 ] \
    && pass "2d: bounded wait honored ~2s deadline (${elapsed_ms}ms)" \
    || fail "2d: elapsed ${elapsed_ms}ms outside [1200,10000)ms"
touch "$GO_2D"
wait "$HOLDER_2D" 2>/dev/null

# 2e. Lock file is created 0600 regardless of umask.
rm -f "$WORK/umask.lock"
(
    umask 077
    export PALWARDEN_LIFECYCLE_LOCK="$WORK/umask.lock"
    cli acquire >/dev/null 2>&1
)
mode="$(stat -c %a "$WORK/umask.lock" 2>/dev/null || echo missing)"
assert_eq "$mode" "600" "2e: lock file mode is 0600 under umask 077"

# ---------------------------------------------------------------------------
# 3. Inherited descriptor protocol (plan step 3).

# 3a. A child with the inherited fd validates ownership (same owner identity).
python3 - <<'EOF'
import os, sys
sys.path.insert(0, os.environ["LIB"])
import palwarden_lifecycle as lc
fd = lc.acquire(timeout=5.0)
env = lc.ownership_env(fd)
code = (
    "import os, sys; sys.path.insert(0, os.environ['LIB']);\n"
    "import palwarden_lifecycle as lc\n"
    "kind, fd2 = lc.ownership_from_env()\n"
    "print(kind); print(fd2)\n"
)
import subprocess
r = subprocess.run(
    [sys.executable, "-c", code],
    env={**os.environ, **env, "LIB": os.environ["LIB"]},
    capture_output=True, text=True, pass_fds=(fd,),
)
out = r.stdout.split()
assert r.returncode == 0, r.stderr
assert out[0] == "borrowed", out
assert int(out[1]) == fd, out
lc.release(fd)
print("ok")
EOF
[ $? -eq 0 ] && pass "3a: child with inherited fd validates as borrower" \
    || fail "3a: inherited-fd validation failed"

# 3b. A flag alone is not ownership: garbage fd number or fd to another file
# must not be treated as borrowed.
python3 - <<'EOF'
import os, sys
sys.path.insert(0, os.environ["LIB"])
import palwarden_lifecycle as lc
import palwarden_lifecycle as _  # noqa
import subprocess
def probe(extra_env, open_other=False):
    base = {k: v for k, v in os.environ.items()
            if k.startswith(("LIB", "PALWARDEN_", "PATH"))}
    env = dict(base)
    env.update(extra_env)
    code = (
        "import os, sys\n"
        "sys.path.insert(0, os.environ['LIB'])\n"
        "import palwarden_lifecycle as lc\n"
        "kind, fd = lc.ownership_from_env()\n"
        "print(kind)\n"
    )
    fds = None
    if open_other:
        f = open(os.path.join(os.environ["WORK"], "other.bin"), "a+")
        env[lc.FD_ENV] = str(f.fileno())
        fds = (f.fileno(),)
        r = subprocess.run([sys.executable, "-c", code], env=env,
                           capture_output=True, text=True, pass_fds=fds)
        f.close()
    else:
        r = subprocess.run([sys.executable, "-c", code], env=env,
                           capture_output=True, text=True)
    return r.stdout.strip()
assert probe({lc.FD_ENV: "99"}) == "none", "garbage fd number must be 'none'"
assert probe({}, open_other=True) == "none", "fd to another file must be 'none'"
print("ok")
EOF
[ $? -eq 0 ] && pass "3b: fake ownership flag never grants borrowed status" \
    || fail "3b: fake ownership flag was honored"

# 3c. Killed owner: kernel releases the lock; a new acquire succeeds.
(
    python3 - <<'EOF'
import os, sys
sys.path.insert(0, os.environ["LIB"])
import palwarden_lifecycle as lc
fd = lc.acquire(timeout=10.0)
with open(os.environ["READY_3C"], "w") as f:
    f.write(str(os.getpid()))
import time
while not os.path.exists(os.environ["GO_3C"]):
    time.sleep(0.02)
EOF
) &
HOLDER_3C=$!
wait_file "$WORK/ready_3c" 10 || fail "3c: owner never became ready"
kill -9 "$HOLDER_3C"
wait "$HOLDER_3C" 2>/dev/null  # reap; kernel closed the fd on -9
cli acquire >/dev/null 2>&1 \
    && pass "3c: lock released automatically when owner was killed" \
    || fail "3c: lock still held after owner killed -9"

# 3d. Unrelated subprocesses must not retain the descriptor.
python3 - <<'EOF'
import os, sys, subprocess
sys.path.insert(0, os.environ["LIB"])
import palwarden_lifecycle as lc
fd = lc.acquire(timeout=5.0)
code = (
    "import os\n"
    f"fd = os.environ.get('{lc.FD_ENV}')\n"
    "try:\n"
    "    os.fstat(int(fd))\n"
    "    print('retained')\n"
    "except (OSError, ValueError, TypeError):\n"
    "    print('closed')\n"
)
env = {**os.environ, lc.FD_ENV: str(fd)}
r = subprocess.run([sys.executable, "-c", code], env=env,
                   capture_output=True, text=True)
assert r.stdout.strip() == "closed", r.stdout
lc.release(fd)
print("ok")
EOF
[ $? -eq 0 ] && pass "3d: unrelated child does not retain the lock descriptor" \
    || fail "3d: unrelated child retained the descriptor"

# ---------------------------------------------------------------------------
# 4. CLI re-exec bridge (plan step 4): argv/exit code/signal preservation.

# 4a. Exit code and argv are preserved through the re-exec.
out="$(cli acquire -- /bin/sh -c 'echo argv:$0:$1; exit 7' hello world 2>&1)"
rc=$?
assert_eq "$rc" "7" "4a: exit code preserved"
assert_contains "$out" "argv:hello:world" "4a: argv preserved"

# 4b. The lock is held during the command and released after; a competitor
# is excluded inside the window.
(
    cli acquire -- /bin/sh -c "
        touch '$WORK/ready_4b'
        while [ ! -e '$WORK/go_4b' ]; do sleep 0.05; done
        exit 5
    " 2>/dev/null
) &
HOLDER_4B=$!
wait_file "$WORK/ready_4b" 10 || fail "4b: command never started under lock"
rc=0
cli acquire --timeout 1 2>/dev/null || rc=$?
[ "$rc" -eq 75 ] && pass "4b: competitor excluded while re-exec command runs" \
    || fail "4b: competitor acquired during command (rc=$rc)"
touch "$WORK/go_4b"
wait "$HOLDER_4B" 2>/dev/null
rc4b=$?
assert_eq "$rc4b" "5" "4b: non-zero exit code of command preserved"
cli acquire >/dev/null 2>&1 \
    && pass "4b: lock released after command exited" \
    || fail "4b: lock still held after command exited"

# 4c. A signal to the re-exec command releases the lock (kernel close).
(
    cli acquire -- /bin/sh -c "
        touch '$WORK/ready_4c'
        while [ ! -e '$WORK/go_4c' ]; do sleep 0.05; done
    " 2>/dev/null
) &
HOLDER_4C=$!
wait_file "$WORK/ready_4c" 10 || fail "4c: command never started under lock"
# The re-exec'd command replaced the CLI process: exactly one pid matches.
n4c="$(pgrep -fc 'ready_4c' || true)"
[ "$n4c" = "1" ] || fail "4c: expected exactly one matching pid, got '$n4c'"
kill -TERM "$(pgrep -f 'ready_4c' | tr -d ' ')" 2>/dev/null
wait "$HOLDER_4C" 2>/dev/null
cli acquire >/dev/null 2>&1 \
    && pass "4c: lock released after re-exec command was signalled" \
    || fail "4c: lock held after signalled command"

# ---------------------------------------------------------------------------
# 5. Nested chains (plan step 5): no deadlock, no LOCK_UN from borrowers.

# 5a. Python -> shell -> python: outer python owner re-execs a shell that
# runs a nested python borrower; competitor stays excluded until the outer
# owner finishes; the borrower never releases the outer lock.
run_deadline "5a" 15 "$WORK/rc_5a" -- python3 - <<'EOF'
import os, sys, subprocess
sys.path.insert(0, os.environ["LIB"])
import palwarden_lifecycle as lc

outer = lc.acquire(timeout=5.0)
env = {**os.environ, **lc.ownership_env(outer)}
script = os.path.join(os.environ["WORK"], "nested_5a.sh")
with open(script, "w") as f:
    f.write(
        "echo shell-layer\n"
        f"LIB={os.environ['LIB']} PYTHONPATH={os.environ['LIB']} "
        f"python3 - <<'PY'\n"
        "import os, sys\n"
        "sys.path.insert(0, os.environ['LIB'])\n"
        "import palwarden_lifecycle as lc\n"
        "kind, fd = lc.ownership_from_env()\n"
        "print('nested-borrowed:' + kind)\n"
        "PY\n"
    )
r = subprocess.run(["/bin/sh", script], env=env, capture_output=True, text=True)
assert r.returncode == 0, r.stderr
assert "nested-borrowed:borrowed" in r.stdout, r.stdout
# Borrower must not have unlocked: a fresh competitor is still excluded.
comp = subprocess.run(
    [sys.executable, "-c",
     "import os,sys; sys.path.insert(0, os.environ['LIB']);\n"
     "import palwarden_lifecycle as lc\n"
     "try:\n"
     "    lc.acquire(timeout=1.0)\n"
     "    print('comp-won')\n"
     "except lc.LifecycleError:\n"
     "    print('comp-held')\n"],
    env=os.environ, capture_output=True, text=True)
assert comp.stdout.strip() == "comp-held", comp.stdout
lc.release(outer)
# After the outer owner ends, the lock is available.
free = subprocess.run(
    [sys.executable, "-c",
     "import os,sys; sys.path.insert(0, os.environ['LIB']);\n"
     "import palwarden_lifecycle as lc\n"
     "fd = lc.acquire(timeout=2.0); lc.release(fd); print('free')\n"],
    env=os.environ, capture_output=True, text=True)
assert free.stdout.strip() == "free", free.stdout
print("ok")
EOF
[ "$(cat "$WORK/rc_5a" 2>/dev/null)" = "0" ] \
    && pass "5a: python->shell->python nested chain, no deadlock, borrower locked out-free" \
    || fail "5a: nested chain failed (rc=$(cat "$WORK/rc_5a" 2>/dev/null))"

# 5b. Shell -> python -> shell: a shell owner (via the CLI re-exec) runs a
# python borrower that spawns a shell child; the innermost shell sees the
# borrowed descriptor and the outer holder continues.
run_deadline "5b" 15 "$WORK/rc_5b" -- cli acquire -- /bin/sh -c '
    set -e
    inner=$(cat <<INNER
import os, sys
sys.path.insert(0, os.environ["LIB"])
import palwarden_lifecycle as lc
kind, fd = lc.ownership_from_env()
assert kind == "borrowed", kind
import subprocess
r = subprocess.run(["/bin/sh", "-c", "echo innermost-shell"],
                   env=os.environ, capture_output=True, text=True)
print("innermost:" + r.stdout.strip())
INNER
    )
    LIB=$LIB PYTHONPATH=$LIB python3 -c "$inner"
'
[ "$(cat "$WORK/rc_5b" 2>/dev/null)" = "0" ] \
    && pass "5b: shell->python->shell nested chain completes" \
    || fail "5b: shell->python->shell chain failed (rc=$(cat "$WORK/rc_5b" 2>/dev/null))"

# 5c. Release by a non-owner is refused; release by the owner succeeds.
python3 - <<'EOF'
import os, sys, subprocess
sys.path.insert(0, os.environ["LIB"])
import palwarden_lifecycle as lc
fd = lc.acquire(timeout=5.0, owner_pid=os.getpid(), owner_comm="owner-5c")
env = {**os.environ, **lc.ownership_env(fd)}
# Non-owner: same fd, different claimed identity.
r = subprocess.run(
    [sys.executable, "-c",
     "import os,sys; sys.path.insert(0, os.environ['LIB'])\n"
     "import palwarden_lifecycle as lc\n"
     "kind, fd = lc.ownership_from_env()\n"
     "try:\n"
     "    lc.release(fd, owner_pid=999999, owner_comm='intruder')\n"
     "    print('released')\n"
     "except lc.LifecycleError:\n"
     "    print('refused')\n"],
    env=env, capture_output=True, text=True, pass_fds=(fd,))
assert r.stdout.strip() == "refused", r.stdout
# Owner release works.
lc.release(fd, owner_pid=os.getpid(), owner_comm="owner-5c")
free = subprocess.run(
    [sys.executable, "-c",
     "import os,sys; sys.path.insert(0, os.environ['LIB']);\n"
     "import palwarden_lifecycle as lc\n"
     "fd = lc.acquire(timeout=2.0); lc.release(fd); print('free')\n"],
    env=os.environ, capture_output=True, text=True)
assert free.stdout.strip() == "free", free.stdout
print("ok")
EOF
[ $? -eq 0 ] && pass "5c: non-owner release refused, owner release succeeds" \
    || fail "5c: release identity handling broken"

# 5d. CLI release without an inherited descriptor is refused (rc 66).
rc=0
err="$(cli release 2>&1 >/dev/null)" || rc=$?
[ "$rc" -eq 66 ] && pass "5d: release without descriptor refused (rc=66)" \
    || fail "5d: release without descriptor rc=$rc (want 66)"

# ---------------------------------------------------------------------------
# 6. State/generation file (plan step 6, spec §4.4).

# 6a. ensure_state creates 0755 dir + 0644 file under umask 077; idle start.
# Earlier bridge cases now initialize persistent state; isolate this fixture.
export PALWARDEN_LIFECYCLE_STATE_DIR="$WORK/state-section6"
(
    umask 077
    python3 - <<'EOF'
import os, sys, json
sys.path.insert(0, os.environ["LIB"])
import palwarden_lifecycle as lc
st = lc.ensure_state()
assert st["status"] == "idle", st
assert st["generation"], st
print("ok")
EOF
)
[ $? -eq 0 ] && pass "6a: ensure_state creates idle state" \
    || fail "6a: ensure_state failed"
dmode="$(stat -c %a "$PALWARDEN_LIFECYCLE_STATE_DIR" 2>/dev/null || echo missing)"
fmode="$(stat -c %a "$PALWARDEN_LIFECYCLE_STATE_DIR/state.json" 2>/dev/null || echo missing)"
assert_eq "$dmode" "755" "6a: state dir mode 0755 under umask 077"
assert_eq "$fmode" "644" "6a: state file mode 0644 under umask 077"

# 6b. ensure_state is idempotent: it never rotates an existing generation.
gen1="$(python3 -c 'import os,sys; sys.path.insert(0, os.environ["LIB"]); import palwarden_lifecycle as lc; print(lc.read_state()["generation"])')"
gen2="$(python3 -c 'import os,sys; sys.path.insert(0, os.environ["LIB"]); import palwarden_lifecycle as lc; print(lc.ensure_state()["generation"])')"
assert_eq "$gen1" "$gen2" "6b: ensure_state does not rotate generation"

# 6c. Outer transaction rotates generation and publishes active; operation
# class is validated.
python3 - <<'EOF'
import os, sys
sys.path.insert(0, os.environ["LIB"])
import palwarden_lifecycle as lc
before = lc.read_state()["generation"]
st = lc.write_state("active", operation="update", rotate=True)
assert st["status"] == "active", st
assert st["operation"] == "update", st
assert st["generation"] != before, "rotation must change generation"
try:
    lc.write_state("active", operation="not-a-class")
    raise SystemExit("invalid operation class accepted")
except lc.LifecycleError:
    pass
print("ok")
EOF
[ $? -eq 0 ] && pass "6c: rotate+active publish; invalid operation class rejected" \
    || fail "6c: state publish/validate failed"

# 6d. The marker outlives the lock: release the lock and kill the owner; the
# unsafe/active state must remain until explicit recovery.
python3 - <<'EOF'
import os, sys
sys.path.insert(0, os.environ["LIB"])
import palwarden_lifecycle as lc
fd = lc.acquire(timeout=5.0)
st = lc.write_state("unsafe", operation="restore", rotate=True)
assert st["status"] == "unsafe", st
lc.release(fd)
# Lock is gone; the marker must remain.
st = lc.read_state()
assert st["status"] == "unsafe", st
assert st["operation"] == "restore", st
print("ok")
EOF
[ $? -eq 0 ] && pass "6d: unsafe marker survives lock release and owner death" \
    || fail "6d: marker did not survive lock release"

# 6e. Missing state file reads as unknown; corrupt file is a data error (65).
MISSING="$WORK/state-missing"
out="$(
    export PALWARDEN_LIFECYCLE_STATE_DIR="$MISSING"
    cli state --json
)"
assert_contains "$out" '"status": "unknown"' "6e: missing state file reports unknown"
CORRUPT="$WORK/state-corrupt"; mkdir -p "$CORRUPT"
echo 'not json' > "$CORRUPT/state.json"
rc=0
err="$(
    export PALWARDEN_LIFECYCLE_STATE_DIR="$CORRUPT"
    cli state --json 2>&1 >/dev/null
)" || rc=$?
[ "$rc" -eq 65 ] && pass "6e: corrupt state file is a data error (rc=65)" \
    || fail "6e: corrupt state rc=$rc (want 65)"

# 6f. acknowledge-maintenance (spec §4.4).
rc=0
err="$(cli acknowledge-maintenance 2>&1 >/dev/null)" || rc=$?
[ "$rc" -eq 64 ] && pass "6f: acknowledge-maintenance without --confirm is a usage error" \
    || fail "6f: missing --confirm rc=$rc (want 64)"

if [ "$(id -u)" = "0" ]; then
    # Root harness: full happy path with a stub systemctl reporting a
    # CONFIRMED wanted-down service (inactive + disabled — F7: plain
    # "inactive" is crash-backoff for an enabled unit and must NOT ack).
    cat > "$WORK/systemctl-stub" <<'STUB'
#!/bin/sh
case "$1" in
    is-active)  echo inactive; exit 3 ;;
    is-enabled) echo disabled; exit 1 ;;
    *) exit 2 ;;
esac
STUB
    chmod +x "$WORK/systemctl-stub"
    palwarden_lifecycle_ensure_unsafe() {
        python3 -c 'import os,sys; sys.path.insert(0, os.environ["LIB"]); import palwarden_lifecycle as lc; lc.write_state("unsafe", operation="restore", rotate=True); print("set")'
    }
    palwarden_lifecycle_ensure_unsafe >/dev/null
    gen_before="$(python3 -c 'import os,sys; sys.path.insert(0, os.environ["LIB"]); import palwarden_lifecycle as lc; print(lc.read_state()["generation"])')"
    rc=0
    err="$(
        export PALWARDEN_SYSTEMCTL_BIN="$WORK/systemctl-stub"
        cli acknowledge-maintenance --confirm 2>&1 >/dev/null
    )" || rc=$?
    [ "$rc" -eq 0 ] && pass "6f: root acknowledge-maintenance clears unsafe state" \
        || fail "6f: root acknowledge rc=$rc"
    st_out="$(cli state --json)"
    assert_contains "$st_out" '"status": "idle"' "6f: status idle after acknowledge"
    gen_after="$(python3 -c 'import os,sys; sys.path.insert(0, os.environ["LIB"]); import palwarden_lifecycle as lc; print(lc.read_state()["generation"])')"
    [ "$gen_before" != "$gen_after" ] \
        && pass "6f: generation rotated by acknowledge" \
        || fail "6f: generation not rotated"
    # A live (active) service must be refused even for root.
    cat > "$WORK/systemctl-stub-active" <<'STUB'
#!/bin/sh
case "$1" in
    is-active) echo active; exit 0 ;;
    *) exit 2 ;;
esac
STUB
    chmod +x "$WORK/systemctl-stub-active"
    python3 -c 'import os,sys; sys.path.insert(0, os.environ["LIB"]); import palwarden_lifecycle as lc; lc.write_state("unsafe", operation="restore", rotate=True)' >/dev/null
    rc=0
    err="$(
        export PALWARDEN_SYSTEMCTL_BIN="$WORK/systemctl-stub-active"
        cli acknowledge-maintenance --confirm 2>&1 >/dev/null
    )" || rc=$?
    [ "$rc" -ne 0 ] && pass "6f: acknowledge refused while service is active" \
        || fail "6f: acknowledge succeeded against an active service"
    # F2 regression: the refused path must release the lock it opened. If the
    # fd leaked, a fresh acquire would block and time out (EX_BUSY=75).
    rc=0
    cli acquire --timeout 2.0 >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 0 ] && pass "6f: lock released after refused acknowledge (fresh acquire ok)" \
        || fail "6f: lock leaked after refused acknowledge (fresh acquire rc=$rc, want 0)"
else
    # Non-root harness: root-only refusal is observable; the happy path is not.
    rc=0
    err="$(cli acknowledge-maintenance --confirm 2>&1 >/dev/null)" || rc=$?
    [ "$rc" -ne 0 ] && pass "6f: non-root acknowledge-maintenance refused (rc=$rc)" \
        || fail "6f: non-root acknowledge-maintenance succeeded"
    echo "UNAVAILABLE: root-only acknowledge happy path (harness is not root)"
fi

# 6g. Usage errors.
rc=0; cli bogus-verb >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 64 ] && pass "6g: unknown verb is a usage error (rc=64)" || fail "6g: unknown verb rc=$rc"

# 7. Serialization under contention: N acquirers launched simultaneously must
#    each hold the lock in a window that does not overlap any other's. Each
#    holder records (monotonic start, monotonic end) bracketing a 0.15 s hold
#    — overlapping holds would show as overlapping windows.
SER_DIR="$WORK/serial"
mkdir -p "$SER_DIR"
ser_pids=()
for _i in 1 2 3 4 5 6; do
    env PYTHONPATH="$LIB" PALWARDEN_LIFECYCLE_LOCK="$PALWARDEN_LIFECYCLE_LOCK" \
        python3 - "$SER_DIR" <<'PY' &
import os
import sys
import time

import palwarden_lifecycle as lc

fd = lc.acquire(timeout=30)
start = time.monotonic_ns()
time.sleep(0.15)
end = time.monotonic_ns()
lc.release(fd)
with open(os.path.join(sys.argv[1], str(os.getpid())), "w") as f:
    f.write(f"{start} {end}\n")
PY
    ser_pids+=("$!")
done
ser_rc=0
for _p in "${ser_pids[@]}"; do wait "$_p" || ser_rc=1; done
n_win=$(find "$SER_DIR" -type f | wc -l)
if [ "$ser_rc" -ne 0 ]; then
    fail "7: a concurrent acquirer exited non-zero"
elif [ "$n_win" -ne 6 ]; then
    fail "7: only $n_win/6 hold windows recorded"
elif env SER_DIR="$SER_DIR" python3 - <<'PY'
import os
import sys

wins = []
for name in os.listdir(os.environ["SER_DIR"]):
    a, b = (int(x) for x in
            open(os.path.join(os.environ["SER_DIR"], name)).read().split())
    wins.append((a, b))
wins.sort()
sys.exit(1 if any(s2 < e1 for (s1, e1), (s2, e2) in zip(wins, wins[1:])) else 0)
PY
then
    pass "7: 6 concurrent acquirers serialized (non-overlapping hold windows)"
else
    fail "7: overlapping hold windows detected"
fi

# 8. F1 decision C (2026-10-21): shipped defaults — lock on /run, state on
# the persistent palwarden-ops volume. Pin them so a future refactor cannot
# silently move the safety marker back onto a tmpfs or into an uncreated tree.
defaults_out="$(PYTHONPATH="$LIB" python3 - <<'PY'
import palwarden_lifecycle as lc
assert lc.DEFAULT_LOCK_PATH == "/run/palworld-lifecycle.lock", lc.DEFAULT_LOCK_PATH
assert lc.DEFAULT_STATE_DIR == "/var/lib/palwarden-ops/lifecycle", lc.DEFAULT_STATE_DIR
print("DEFAULTS_OK")
PY
)"
[ "$defaults_out" = "DEFAULTS_OK" ] \
    && pass "8: F1-C default paths (lock /run, state palwarden-ops volume)" \
    || fail "8: default paths drifted: $defaults_out"

# 9. Task 6 (spec §4.2): the knock daemon's bounded lease cycle must not
# starve an explicit controller, and the daemon must close its UDP socket
# BEFORE releasing the lock (so a manual start that wins the lock can bind
# the game socket immediately).  Fixture port 18212; stubbed s6 state.
KD="$WORK/kd"
mkdir -p "$KD/bin" "$KD/svc/palworld-server" "$KD/state"
cat > "$KD/bin/s6-svstat" <<EOF
#!/usr/bin/env bash
echo "down: status 111, 100 seconds"; exit 1
EOF
chmod +x "$KD/bin/s6-svstat"
touch "$KD/svc/palworld-server/down"
PYTHONPATH="$LIB" python3 -c '
import sys
import palwarden_ops as ops
sys.stdout.write(ops.render({
    "IDLE_TIMEOUT": 0, "IDLE_CHECK_INTERVAL": 60,
    "KNOCK_ENABLED": True, "KNOCK_COOLDOWN": 600,
    "KNOCK_TOKEN": "locktest-synthetic-token"}))' > "$KD/ops.env"
env -i PATH="$KD/bin:/usr/bin:/bin" HOME="$HOME" \
    PALWARDEN_CONTAINER=1 \
    PALWARDEN_LIFECYCLE_LOCK="$WORK/lifecycle.lock" \
    PALWARDEN_LIFECYCLE_STATE_DIR="$KD/state" \
    PALWARDEN_S6_SVC_DIR="$KD/svc" \
    PALWARDEN_OPS_FILE="$KD/ops.env" \
    PALWORLD_KNOCK_COOLDOWN_FILE="$KD/knock.cooldown" \
    python3 "$REPO/sbin/palworld-knock" daemon --port 18212 \
    > "$KD/daemon.log" 2>&1 &
KD_PID=$!
kd_ok=1
for _i in 1 2 3; do
    out="$(env -i PATH="/usr/bin:/bin" HOME="$HOME" \
        PALWARDEN_LIFECYCLE_LOCK="$WORK/lifecycle.lock" PYTHONPATH="$LIB" \
        python3 -c 'import sys, time
import palwarden_lifecycle as lc
t0 = time.monotonic()
try:
    fd = lc.acquire(timeout=5.0)
except lc.LifecycleError:
    print("BUSY"); sys.exit(0)
# Under our ownership the daemon must NOT hold the game socket: it closes
# the socket before releasing the lock.
import subprocess
listening = subprocess.run(
    ["ss", "-lun"], capture_output=True, text=True
).stdout.split()
holds_port = any(p.endswith(":18212") for p in listening)
lc.release(fd)
print("ACQUIRED %d %s" % (int((time.monotonic() - t0) * 1000),
                          "PORT-HELD" if holds_port else "PORT-FREE"))' 2>/dev/null)"
    case "$out" in
        ACQUIRED\ *) ms="${out#ACQUIRED }"; ms="${ms%% *}" ;;
        *) ms=99999 ;;
    esac
    [ "${ms:-99999}" -lt 5000 ] || kd_ok=0
    case "$out" in *"PORT-FREE"*) ;; *) kd_ok=0 ;; esac
done
kill -TERM "$KD_PID" 2>/dev/null
wait "$KD_PID" 2>/dev/null || true
if [ "$kd_ok" = 1 ]; then
    pass "9: knock-daemon leases never starve a controller (3 acquisitions <5s each; socket closed before every release)"
else
    fail "9: lease discipline violated (last probe: $out; daemon log: $(tr '\n' '|' < "$KD/daemon.log"))"
fi

# ---------------------------------------------------------------------------
# 10: init_runtime — an old-runtime generation must not survive a runtime
# restart (spec §4.4, plan Task 8). Idle state rotates to a fresh generation;
# active/unsafe markers survive untouched (they inhibit wake until an
# operator acknowledges them).
# ---------------------------------------------------------------------------
rt="$WORK/rt-state"; mkdir -p "$rt"
rtgen() { env PYTHONPATH="$LIB" PALWARDEN_LIFECYCLE_STATE_DIR="$rt" python3 -c \
    'import palwarden_lifecycle as lc; print(lc.read_state()["generation"])'; }

# missing state: init_runtime creates it idle with a generation
out="$(env PYTHONPATH="$LIB" PALWARDEN_LIFECYCLE_STATE_DIR="$rt" python3 -c '
import palwarden_lifecycle as lc
st = lc.init_runtime()
print(st["status"], st["generation"] is not None)')"
assert_eq "$out" "idle True" "10a: init_runtime seeds missing state as idle with a generation"

# idle state: the generation rotates (old wakes cannot survive the restart)
old_gen="$(rtgen)"
out="$(env PYTHONPATH="$LIB" PALWARDEN_LIFECYCLE_STATE_DIR="$rt" python3 -c '
import palwarden_lifecycle as lc
old = lc.read_state()["generation"]
st = lc.init_runtime()
print("rotated" if st["generation"] != old and st["status"] == "idle" else "SAME %r" % st)')"
assert_eq "$out" "rotated" "10b: init_runtime rotates an idle generation"
new_gen="$(rtgen)"
[ -n "$old_gen" ] && [ "$old_gen" != "$new_gen" ] \
    && pass "10c: the pre-restart generation is gone from the state file" \
    || fail "10c: generation survived init_runtime ($old_gen == $new_gen)"

# active marker: never cleared by a mere restart. R2 (Sol review) tightened
# this: init_runtime now serializes under lifecycle ownership, so an
# `active` found on a freshly acquired lock is a corpse (R1 semantics) and
# escalates to sticky `unsafe` — strictly safer: the wake fence survives,
# and the marker can only be cleared by acknowledge-maintenance.
env PYTHONPATH="$LIB" PALWARDEN_LIFECYCLE_STATE_DIR="$rt" python3 -c \
    'import palwarden_lifecycle as lc; lc.write_state("active", "update", rotate=True, force=True)' >/dev/null
out="$(env PYTHONPATH="$LIB" PALWARDEN_LIFECYCLE_STATE_DIR="$rt" python3 -c '
import palwarden_lifecycle as lc
old = lc.read_state()
st = lc.init_runtime()
ok = (st["status"] == "unsafe"
      and st["generation"] == old["generation"])
print("escalated" if ok else "MUTATED %r" % st)')"
assert_eq "$out" "escalated" \
    "10d: init_runtime never idles an active marker (abandoned -> unsafe)"

# unsafe marker: survives too
env PYTHONPATH="$LIB" PALWARDEN_LIFECYCLE_STATE_DIR="$rt" python3 -c \
    'import palwarden_lifecycle as lc; lc.write_state("unsafe", "restore")' >/dev/null
out="$(env PYTHONPATH="$LIB" PALWARDEN_LIFECYCLE_STATE_DIR="$rt" python3 -c '
import palwarden_lifecycle as lc
old = lc.read_state()
st = lc.init_runtime()
print("kept" if st["status"] == "unsafe" and st["generation"] == old["generation"] else "MUTATED %r" % st)')"
assert_eq "$out" "kept" "10e: init_runtime leaves an unsafe marker untouched"

# CLI surface (task 10 will wire it into the runtime start-up)
out="$(env PYTHONPATH="$LIB" PALWARDEN_LIFECYCLE_LOCK="$WORK/rt.lock" \
    PALWARDEN_LIFECYCLE_STATE_DIR="$rt" python3 -m palwarden_lifecycle init-runtime --json 2>&1)"
rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q '"status": "unsafe"'; then
    pass "10f: CLI init-runtime reports the surviving state"
else
    fail "10f: CLI init-runtime (rc=$rc): $out"
fi

# ==============================================================================
# 11. F1/F7 (review follow-ups): direct controllers publish outer-transaction
#     state under ownership; acknowledgement requires confirmed wanted-down.
#     Contract (repair plan 1b, revised): the re-exec bridge marks
#     active+rotate BEFORE execing the command and exports
#     PALWARDEN_LIFECYCLE_TXN=1; the owner script (which sources
#     lib/palwarden-lifecycle-bash) marks completion via `complete <rc>` on
#     EXIT. A raw command that never completes leaves `active` — fail closed
#     until an explicit acknowledgement.
# ==============================================================================

# Reset helper that works BEFORE and AFTER the force= parameter exists (the
# sticky-unsafe tests below pin force itself; resets must not depend on it).
lc_reset_idle() {
    python3 - <<'RST'
import palwarden_lifecycle as lc
try:
    lc.write_state("idle", force=True)
except TypeError:
    lc.write_state("idle")
RST
}

lc_reset_idle
python3 -c 'import palwarden_lifecycle as lc; lc.ensure_state()' >/dev/null
gen11="$(python3 -c 'import palwarden_lifecycle as lc; print(lc.read_state()["generation"])')"

# 11a. The bridge publishes active + a rotated generation while the command
#      runs, and the command sees the TXN ownership marker.
( cli acquire -- /bin/sh -c "echo \"txn=\$PALWARDEN_LIFECYCLE_TXN\" > '$WORK/txn_11a'; touch '$WORK/ready_11a'; while [ ! -e '$WORK/go_11a' ]; do sleep 0.05; done" 2>/dev/null ) &
H11A=$!
wait_file "$WORK/ready_11a" 10 || fail "11a: bridge command never started"
st11a="$(cli state --json)"
assert_contains "$st11a" '"status": "active"' \
    "11a: outer transaction marks active before any service change"
gen11b="$(python3 -c 'import palwarden_lifecycle as lc; print(lc.read_state()["generation"])')"
[ "$gen11b" != "$gen11" ] \
    && pass "11a: generation rotated before the mutation" \
    || fail "11a: generation unchanged ($gen11)"
touch "$WORK/go_11a"; wait "$H11A" 2>/dev/null
assert_contains "$(cat "$WORK/txn_11a")" "txn=1" "11a: TXN marker exported to the owner script"

# 11b. `complete <rc>` closes the transaction the sourced library's EXIT trap
#      would call: 0 -> idle, non-zero -> unsafe. A raw command that exits
#      without completing leaves `active` (fail closed) — pinned first.
st11c="$(cli state --json)"
assert_contains "$st11c" '"status": "active"' \
    "11b: an owner that never completes leaves active (wake stays fenced)"
rc=0; cli complete 0 >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] && pass "11b: complete 0 accepted" || fail "11b: complete 0 rc=$rc"
assert_contains "$(cli state --json)" '"status": "idle"' "11b: complete 0 records idle"
python3 -c 'import palwarden_lifecycle as lc; lc.write_state("active", rotate=True)' >/dev/null
cli complete 3 >/dev/null 2>&1
assert_contains "$(cli state --json)" '"status": "unsafe"' \
    "11b: a failed transaction records unsafe"

# 11c. Sticky unsafe: no ordinary writer may clear it — only ack (root, 11f).
cli complete 0 >/dev/null 2>&1
assert_contains "$(cli state --json)" '"status": "unsafe"' \
    "11c: complete 0 cannot clear unsafe (recovery stays explicit)"
python3 - <<'PY'
import palwarden_lifecycle as lc

try:
    lc.write_state("active", rotate=True)
except lc.UnsafeMaintenanceError:
    pass
else:
    raise AssertionError("an ordinary active writer did not reject unsafe state")
PY
[ $? -eq 0 ] && pass "11c: active write raises UnsafeMaintenanceError" \
    || fail "11c: active write did not raise the expected unsafe-state error"
assert_contains "$(cli state --json)" '"status": "unsafe"' \
    "11c: a new active mark cannot erase unsafe either"
# unsafe -> unsafe (escalation) and force (ack path) remain available.
python3 -c 'import palwarden_lifecycle as lc; lc.write_state("unsafe", operation="update")' >/dev/null \
    && pass "11c: unsafe -> unsafe escalation allowed" \
    || fail "11c: escalation write was refused"
lc_reset_idle \
    && pass "11c: force=True (the ack path) may leave unsafe" \
    || fail "11c: forced write was refused"

# 11d. An interrupted owner leaves `active` (fail closed), never idle.
( cli acquire -- /bin/sh -c "touch '$WORK/ready_11d'; while :; do sleep 0.05; done" 2>/dev/null ) &
H11D=$!
wait_file "$WORK/ready_11d" 10 || fail "11d: command never started"
pkill -9 -f 'ready_11d' 2>/dev/null
wait "$H11D" 2>/dev/null
assert_contains "$(cli state --json)" '"status": "active"' \
    "11d: SIGKILL of the owner leaves active (interrupted maintenance fences wake)"
cli acquire --timeout 2 >/dev/null 2>&1 \
    && pass "11d: the kernel still released the lock on death" \
    || fail "11d: lock leaked after SIGKILL"
lc_reset_idle

# 11e. F7 basis: service_state distinguishes crash-backoff from stopped on the
#      s6 branch (down + NO wanted-down marker is crash-backoff: the supervisor
#      still wants the game up).
mkdir -p "$WORK/svc/palworld-server" "$WORK/bin"
cat > "$WORK/bin/s6-svstat" <<'S6'
#!/bin/sh
echo 'down (no pid)'
exit 1
S6
chmod +x "$WORK/bin/s6-svstat"
st11e="$(env PATH="$WORK/bin:/usr/bin:/bin" PALWARDEN_CONTAINER=1 \
    PALWARDEN_S6_SVC_DIR="$WORK/svc" \
    python3 -c 'import palwarden_lifecycle as lc; print(lc.service_state())')"
assert_eq "$st11e" "crash-backoff" "11e: down-without-wanted-down is crash-backoff, not stopped"
touch "$WORK/svc/palworld-server/down"
st11f="$(env PATH="$WORK/bin:/usr/bin:/bin" PALWARDEN_CONTAINER=1 \
    PALWARDEN_S6_SVC_DIR="$WORK/svc" \
    python3 -c 'import palwarden_lifecycle as lc; print(lc.service_state())')"
assert_eq "$st11f" "stopped" "11e: down + wanted-down marker is stopped"

# 11f. F7: acknowledgement accepts ONLY confirmed stopped/wanted-down and
#      never starts the game. Root-gated (ack is root-only by design); the
#      non-root harness labels it explicitly.
if [ "$(id -u)" = "0" ]; then
    ack_env=(env PATH="$WORK/bin:/usr/bin:/bin" PALWARDEN_CONTAINER=1
             PALWARDEN_S6_SVC_DIR="$WORK/svc"
             PALWARDEN_SYSTEMCTL_BIN="$WORK/no-such-systemctl")
    # crash-backoff (no wanted-down marker): refuse, marker/generation intact.
    rm -f "$WORK/svc/palworld-server/down"
    python3 -c 'import palwarden_lifecycle as lc; lc.write_state("unsafe", operation="restore", rotate=True)' >/dev/null
    gen_before="$(python3 -c 'import palwarden_lifecycle as lc; print(lc.read_state()["generation"])')"
    rc=0; "${ack_env[@]}" python3 -m palwarden_lifecycle acknowledge-maintenance --confirm >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 0 ] && pass "11f: ack refuses crash-backoff (supervisor still wants it up)" \
        || fail "11f: ack cleared unsafe against crash-backoff"
    st="$(cli state --json)"
    assert_contains "$st" '"status": "unsafe"' "11f: refused ack left the marker untouched"
    gen_after="$(python3 -c 'import palwarden_lifecycle as lc; print(lc.read_state()["generation"])')"
    assert_eq "$gen_before" "$gen_after" "11f: refused ack did not rotate the generation"
    # stopped + wanted-down: succeed without starting anything (no systemctl
    # binary exists on the stub PATH; s6-svstat is read-only).
    touch "$WORK/svc/palworld-server/down"
    rc=0; "${ack_env[@]}" python3 -m palwarden_lifecycle acknowledge-maintenance --confirm >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 0 ] && pass "11f: ack succeeds on confirmed stopped+wanted-down" \
        || fail "11f: ack against stopped+wanted-down rc=$rc"
    assert_contains "$(cli state --json)" '"status": "idle"' "11f: ack cleared unsafe to idle"
else
    echo "UNAVAILABLE: F7 ack matrix requires root (harness is not root)"
fi

# 11g. F1 acceptance: a generation rotated by a direct transaction invalidates
#      an already-admitted wake inside its 15-second lifetime.
lc_reset_idle
fence_gen="$(python3 -c 'import palwarden_lifecycle as lc; print(lc.read_state()["generation"])')"
out="$(env PYTHONPATH="$LIB" OLDGEN="$fence_gen" PALWARDEN_JOBS_DIR="$WORK/fence-jobs" PALWARDEN_PARSER_BIN="$REPO/bin/palworld-config-parser" \
    python3 - "$REPO/sbin/palwarden-jobd" <<'PY' 2>&1
import importlib.machinery, importlib.util, os, sys, time
loader = importlib.machinery.SourceFileLoader("jobd_fence", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
mod = importlib.util.module_from_spec(spec)
sys.modules[loader.name] = mod
loader.exec_module(mod)
fence = {"wake_generation": os.environ["OLDGEN"],
         "wake_expires_at": int(time.time() * 1000) + 15000}
print("ADMITTED" if mod._wake_fence_refusal(fence) is None else "REFUSED")
PY
)"
assert_contains "$out" "ADMITTED" "11g: the wake is admitted against the current generation"
# A direct transaction runs (bridge + owner completion) ...
cli acquire -- /bin/true >/dev/null 2>&1
cli complete 0 >/dev/null 2>&1
# ... and the SAME already-admitted wake must now be refused, inside its life.
out="$(env PYTHONPATH="$LIB" OLDGEN="$fence_gen" PALWARDEN_JOBS_DIR="$WORK/fence-jobs" PALWARDEN_PARSER_BIN="$REPO/bin/palworld-config-parser" \
    python3 - "$REPO/sbin/palwarden-jobd" <<'PY' 2>&1
import importlib.machinery, importlib.util, os, sys, time
loader = importlib.machinery.SourceFileLoader("jobd_fence2", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
mod = importlib.util.module_from_spec(spec)
sys.modules[loader.name] = mod
loader.exec_module(mod)
fence = {"wake_generation": os.environ["OLDGEN"],
         "wake_expires_at": int(time.time() * 1000) + 15000}
print("REFUSED" if mod._wake_fence_refusal(fence) is not None else "STILL-ADMITTED")
PY
)"
assert_contains "$out" "REFUSED" \
    "11g: a wake admitted against the old generation is refused after a direct transaction"

# ==============================================================================
# 12. Sol 6.1 review round (R1/R4/R5b/R6): abandoned-active escalation,
#     help-bypass scoping, wake generation rotation, ack service identity.
# ==============================================================================

# 12a (R1). An interrupted owner leaves `active`; the NEXT transaction to
#     acquire the (kernel-released) lock proves the previous holder died
#     without completing. That abandoned marker must escalate to `unsafe`
#     and survive the new transaction's completion — never silently idle.
lc_reset_idle
cli acquire -- /bin/true >/dev/null 2>&1          # raw owner: leaves active
assert_contains "$(cli state --json)" '"status": "active"' \
    "12a: fixture leaves an abandoned active marker"
cli acquire -- /bin/true >/dev/null 2>&1          # next owner sees the corpse
cli complete 0 >/dev/null 2>&1                    # ... and "succeeds"
st12="$(cli state --json)"
assert_contains "$st12" '"status": "unsafe"' \
    "12a: abandoned active escalates to unsafe and survives a later success"

# 12b (R4). The help bypass must cover ONLY a bare help invocation; a
#     mutating command that merely contains --help must still enroll.
cat > "$WORK/help_probe.sh" <<'EOS'
#!/usr/bin/env bash
source "$LC_LIB/palwarden-lifecycle-bash"
palworld_lifecycle_maybe_acquire "$@" || exit 1
if [[ -n "${PALWARDEN_LIFECYCLE_LOCK_FD:-}" ]]; then echo enrolled; else echo bypassed; fi
EOS
chmod +x "$WORK/help_probe.sh"
out="$(env LC_LIB="$LIB" "$WORK/help_probe.sh" --help 2>/dev/null)"
assert_eq "$out" "bypassed" "12b: bare --help still bypasses enrollment"
out="$(env LC_LIB="$LIB" "$WORK/help_probe.sh" mutate --help 2>/dev/null)"
assert_eq "$out" "enrolled" \
    "12b: --help among mutating args must NOT skip the lock (shim discards it)"

# 12c (R6). Ack must check the SAME service it names in its refusal —
#     service_state(service), not the module default. Scoped to the
#     acknowledge function (another call site already passes it correctly).
if sed -n '/def acknowledge_maintenance/,/^def _cmd_acknowledge/p' \
        lib/palwarden_lifecycle.py | grep -q 'service_state(service)'; then
    pass "12c: acknowledge checks the configured service identity"
else
    fail "12c: acknowledge calls service_state() without the configured service"
fi

# 12d (R5b). A successful wake must rotate the generation so sibling wakes
#     fenced against the old generation die at their own fence check.
cat > "$WORK/systemctl-wake" <<STUB
#!/bin/sh
# start flips the unit to active so start_if_down's confirmation loop
# (service_state must report running) can succeed.
FLAG="$WORK/up12d.flag"
case "\$1" in
    is-active)  if [ -f "\$FLAG" ]; then echo active; exit 0;
                else echo inactive; exit 3; fi ;;
    is-enabled) echo disabled; exit 1 ;;
    start)      touch "\$FLAG"; echo ok; exit 0 ;;
    *) exit 2 ;;
esac
STUB
chmod +x "$WORK/systemctl-wake"
rm -f "$WORK/up12d.flag"
# REST unconfigured (exit 2) -> readiness UNVERIFIED, status still started.
printf '#!/bin/sh\nexit 2\n' > "$WORK/palworld-api-12d"
chmod +x "$WORK/palworld-api-12d"
out="$(env PATH="$WORK/bin:/usr/bin:/bin" \
    PALWARDEN_SYSTEMCTL_BIN="$WORK/systemctl-wake" \
    PALWORLD_API_BIN="$WORK/palworld-api-12d" \
    PALWARDEN_WAKE_READY_TIMEOUT_S=0 \
    PALWORLD_KNOCK_COOLDOWN_FILE="$WORK/cooldown-12d" \
    python3 - <<'PY' 2>&1
import palwarden_lifecycle as lc
lc.write_state("idle", rotate=True, force=True)
gen0 = lc.read_state()["generation"]
fd = lc.acquire(timeout=5)
r = lc.start_if_down(fd, reason="test-12d", config={})
gen1 = lc.read_state()["generation"]
lc.release(fd)
print(r.get("status"), r.get("message", ""), "rotated" if gen0 != gen1 else "same-gen")
PY
)"
case "$out" in
    *started*rotated*) pass "12d: successful wake rotates the generation" ;;
    *) fail "12d: successful wake must rotate the generation (output: $out)" ;;
esac

# ==============================================================================
# 13. Sol round-2 (R2/R9): init_runtime serialization under ownership;
#     truthful failure notification on early wake failures.
# ==============================================================================

# 13a (R2). The fixed init_runtime performs its read-modify-write UNDER the
#     lifecycle lock: while it is paused between its read and its write, a
#     competitor must be EXCLUDED from acquiring the lock. The old code
#     held nothing during that window, so the competitor won (the
#     read-modify-write race Sol reproduced). Deterministic via a patched
#     read_state that pauses init mid-transaction.
out="$(env PYTHONPATH="$LIB" \
    PALWARDEN_LIFECYCLE_LOCK="$WORK/r2.lock" \
    PALWARDEN_LIFECYCLE_STATE_DIR="$WORK/r2-state" \
    READY_13A="$WORK/r2.ready" RESUME_13A="$WORK/r2.resume" \
    python3 - <<'PY' 2>&1
import os, threading, time
import palwarden_lifecycle as lc
lc.ensure_state()
gen0 = lc.read_state()["generation"]
orig = lc.read_state
calls = {"n": 0}
def patched(*a, **k):
    st = orig(*a, **k)
    calls["n"] += 1
    if calls["n"] == 2:  # escalate/read inside init_runtime's body
        open(os.environ["READY_13A"], "w").close()
        t = time.time()
        while not os.path.exists(os.environ["RESUME_13A"]) and time.time() - t < 10:
            time.sleep(0.02)
    return st
lc.read_state = patched
res = {}
def initializer():
    try:
        res["st"] = lc.init_runtime()
    except Exception as e:
        res["err"] = repr(e)
t = threading.Thread(target=initializer)
t.start()
t0 = time.time()
while not os.path.exists(os.environ["READY_13A"]) and time.time() - t0 < 10:
    time.sleep(0.02)
busy = "acquired"
try:
    fd = lc.acquire(timeout=0.3)
    lc.release(fd)
except Exception:
    busy = "busy"
open(os.environ["RESUME_13A"], "w").close()
t.join(15)
final = lc.read_state()
ok = (busy == "busy" and "err" not in res
      and final["status"] == "idle" and final["generation"] != gen0)
print("PASS" if ok else "FAIL busy=%r final=%r res=%r" % (busy, final, res))
PY
)"
assert_contains "$out" "PASS" "13a (R2): init_runtime's read-modify-write excludes lock competitors"

# 13b (R2). Busy lock at boot: init-runtime must SKIP the rotation — the
#     generation and marker of the live holder survive untouched.
lc_reset_idle
cat > "$WORK/holder13b.py" <<'EOS'
import os, sys, time
sys.path.insert(0, os.environ["LIB"])
import palwarden_lifecycle as lc
fd = lc.acquire(timeout=5)
open(os.environ["HOLD_READY"], "w").close()
t = time.time()
while time.time() - t < 20 and not os.path.exists(os.environ["HOLD_GO"]):
    time.sleep(0.05)
lc.release(fd)
EOS
rm -f "$WORK/hold13b.ready" "$WORK/hold13b.go"
env LIB="$LIB" PYTHONPATH="$LIB" \
  PALWARDEN_LIFECYCLE_LOCK="$PALWARDEN_LIFECYCLE_LOCK" \
  PALWARDEN_LIFECYCLE_STATE_DIR="$PALWARDEN_LIFECYCLE_STATE_DIR" \
  HOLD_READY="$WORK/hold13b.ready" HOLD_GO="$WORK/hold13b.go" \
  python3 "$WORK/holder13b.py" &
HOLDER13B_PID=$!
ok=0
for _ in $(seq 1 100); do [ -e "$WORK/hold13b.ready" ] && { ok=1; break; }; sleep 0.05; done
assert_eq "$ok" "1" "13b: holder owns the lifecycle lock"
gen_held="$(cli state --json | sed -n 's/.*"generation": "\([0-9a-f]*\)".*/\1/p')"
cli init-runtime --json >/dev/null 2>&1
gen_after="$(cli state --json | sed -n 's/.*"generation": "\([0-9a-f]*\)".*/\1/p')"
assert_eq "$gen_after" "$gen_held" \
  "13b: init-runtime skips the rotation while the lock is held"
touch "$WORK/hold13b.go"
wait "$HOLDER13B_PID" 2>/dev/null || true

# 13c (R9). A starter failure must post exactly ONE truthful wake failure
#     notification (spec §6.3) — the early returns used to be silent.
cat > "$WORK/systemctl-13c" <<STUB
#!/bin/sh
case "\$1" in
    is-active)  echo inactive; exit 3 ;;
    is-enabled) echo disabled; exit 1 ;;
    start)      echo "boom" >&2; exit 1 ;;
    *) exit 2 ;;
esac
STUB
chmod +x "$WORK/systemctl-13c"
printf '#!/bin/sh\nexit 2\n' > "$WORK/palworld-api-13c"
chmod +x "$WORK/palworld-api-13c"
out="$(env PYTHONPATH="$LIB" \
    PALWARDEN_LIFECYCLE_LOCK="$WORK/r9c.lock" \
    PALWARDEN_LIFECYCLE_STATE_DIR="$WORK/r9c-state" \
    PALWARDEN_SYSTEMCTL_BIN="$WORK/systemctl-13c" \
    PALWORLD_KNOCK_COOLDOWN_FILE="$WORK/cooldown-13c" \
    python3 - <<'PY' 2>&1
import palwarden_lifecycle as lc
posts = []
lc._notify = lambda kind, text: posts.append((kind, text))
lc.ensure_state()
lc.write_state("idle", rotate=True, force=True)
fd = lc.acquire(timeout=5)
r = lc.start_if_down(fd, reason="t13c", config={})
lc.release(fd)
ok = r["status"] == "error" and len(posts) == 1 and "start failed" in posts[0][1]
print("PASS" if ok else "FAIL %r posts=%r" % (r, posts))
PY
)"
assert_contains "$out" "PASS" "13c (R9): starter failure posts exactly one failure notification"

# 13d (R9). Start accepted but the service never reaches running within the
#     bound: also exactly one truthful failure post.
rm -f "$WORK/up13d.flag"
cat > "$WORK/systemctl-13d" <<STUB
#!/bin/sh
# start ACCEPTS (exit 0) but the unit never reaches active: exercises the
# "start issued but the service is not running" bound.
case "\$1" in
    is-active)  echo inactive; exit 3 ;;
    is-enabled) echo disabled; exit 1 ;;
    start)      exit 0 ;;
    *) exit 2 ;;
esac
STUB
chmod +x "$WORK/systemctl-13d"
printf '#!/bin/sh\nexit 2\n' > "$WORK/palworld-api-13d"
chmod +x "$WORK/palworld-api-13d"
out="$(env PYTHONPATH="$LIB" \
    PALWARDEN_LIFECYCLE_LOCK="$WORK/r9d.lock" \
    PALWARDEN_LIFECYCLE_STATE_DIR="$WORK/r9d-state" \
    PALWARDEN_SYSTEMCTL_BIN="$WORK/systemctl-13d" \
    PALWORLD_KNOCK_COOLDOWN_FILE="$WORK/cooldown-13d" \
    PALWARDEN_WAKE_START_TIMEOUT_S=0.5 \
    PALWARDEN_WAKE_READY_TIMEOUT_S=0 \
    python3 - <<'PY' 2>&1
import palwarden_lifecycle as lc
posts = []
lc._notify = lambda kind, text: posts.append((kind, text))
lc.ensure_state()
lc.write_state("idle", rotate=True, force=True)
fd = lc.acquire(timeout=5)
r = lc.start_if_down(fd, reason="t13d", config={})
lc.release(fd)
ok = r["status"] == "error" and len(posts) == 1 and "not running" in posts[0][1]
print("PASS" if ok else "FAIL %r posts=%r" % (r, posts))
PY
)"
assert_contains "$out" "PASS" "13d (R9): never-running wake posts exactly one failure notification"

# 13e (R9). Quiet no-ops stay silent: already-running returns without any
#     Discord post (spec §6.3).
cat > "$WORK/systemctl-13e" <<STUB
#!/bin/sh
case "\$1" in
    is-active)  echo active; exit 0 ;;
    is-enabled) echo enabled; exit 0 ;;
    *) exit 2 ;;
esac
STUB
chmod +x "$WORK/systemctl-13e"
out="$(env PYTHONPATH="$LIB" \
    PALWARDEN_LIFECYCLE_LOCK="$WORK/r9e.lock" \
    PALWARDEN_LIFECYCLE_STATE_DIR="$WORK/r9e-state" \
    PALWARDEN_SYSTEMCTL_BIN="$WORK/systemctl-13e" \
    PALWORLD_KNOCK_COOLDOWN_FILE="$WORK/cooldown-13e" \
    python3 - <<'PY' 2>&1
import palwarden_lifecycle as lc
posts = []
lc._notify = lambda kind, text: posts.append((kind, text))
lc.ensure_state()
lc.write_state("idle", rotate=True, force=True)
fd = lc.acquire(timeout=5)
r = lc.start_if_down(fd, reason="t13e", config={})
lc.release(fd)
ok = r["status"] == "already-running" and posts == []
print("PASS" if ok else "FAIL %r posts=%r" % (r, posts))
PY
)"
assert_contains "$out" "PASS" "13e (R9): already-running wake stays silent"

assert_report
