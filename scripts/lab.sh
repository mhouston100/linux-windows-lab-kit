#!/usr/bin/env bash
# Entry point. The menu is Python. Each stage is still a Bash script.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PYTHONPATH="${ROOT}/python${PYTHONPATH:+:${PYTHONPATH}}"

if [[ -x "${ROOT}/.venv/bin/python3" ]]; then
  PY="${ROOT}/.venv/bin/python3"
elif command -v python3 >/dev/null 2>&1; then
  PY="python3"
else
  printf 'python3 is required. Install it, then: python3 -m venv .venv && .venv/bin/pip install -r requirements.txt\n' >&2
  exit 1
fi

exec "$PY" -m labkit "$@"
