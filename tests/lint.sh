#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Brian Grant
#
# Lint the shell + python sources.
#   ./tests/lint.sh
#
# ShellCheck runs via the koalaman/shellcheck Docker image when shellcheck isn't
# installed locally, so no host install is required (CI uses the same image or a
# preinstalled shellcheck). Config lives in .shellcheckrc.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || exit 1

# Collect first-party shell scripts (by shebang), excluding python and vendored bits.
shell_files() {
  grep -rlE '^#!(/usr/bin/env bash|/bin/bash|/command/with-contenv bash|/usr/bin/env sh)' \
    sbin lib install.sh docker needrestart tests 2>/dev/null | grep -vE '\.py$'
}

# Pinned so a host/CI shellcheck version difference cannot change the result.
SHELLCHECK_IMAGE="koalaman/shellcheck:v0.10.0"

run_shellcheck() {
  if command -v docker >/dev/null 2>&1; then
    shell_files | xargs docker run --rm -i -v "$REPO":/mnt -w /mnt "$SHELLCHECK_IMAGE"
  elif command -v shellcheck >/dev/null 2>&1; then
    echo "  (using host shellcheck $(shellcheck --version | awk "/version:/{print \$2}"); pinned $SHELLCHECK_IMAGE preferred)" >&2
    shell_files | xargs shellcheck
  else
    echo "SKIP shellcheck: neither shellcheck nor docker available" >&2
    return 0
  fi
}

py_files() { grep -rlE '^#!.*python3' sbin lib 2>/dev/null; }
run_pycompile() {
  local rc=0 f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    python3 -m py_compile "$f" || rc=1
  done < <(py_files)
  return "$rc"
}

status=0
echo "== shellcheck =="
if run_shellcheck; then echo "  shellcheck OK"; else echo "  shellcheck FAILED"; status=1; fi
echo "== python syntax (py_compile) =="
if run_pycompile; then echo "  python OK"; else echo "  python FAILED"; status=1; fi

# tidy any bytecode py_compile produced
find sbin lib -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true

[ "$status" -eq 0 ] && echo "LINT PASSED" || echo "LINT FAILED"
exit "$status"
