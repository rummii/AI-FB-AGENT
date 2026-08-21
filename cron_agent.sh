#!/bin/bash
# ------------------------------------------------------------------
# cron_agent.sh — cron-friendly wrapper for the AI Facebook Agent.
#
# Usage (in cPanel -> Cron Jobs -> Command):
#   /bin/bash /home/USERNAME/fb-agent/cron_agent.sh
#
# This script:
#   1. Changes into the directory where it lives.
#   2. Picks the best available Python 3 (3.10+ is REQUIRED), preferring:
#        - AGENT_PYTHON env var if set
#        - venv/bin/python  (project-local virtualenv)
#        - ../virtualenv/*/*/bin/python   (cPanel "Setup Python App")
#        - system python3.12 / 3.11 / 3.10 / python3
#   3. Runs the agent, appending its log to data/agent.log.
# ------------------------------------------------------------------
set -u

cd "$(dirname "$0")" || exit 1

mkdir -p data

# 1) Explicitly configured interpreter wins.
PYTHON="${AGENT_PYTHON:-}"

# 2) Project-local virtualenv.
if [ -z "$PYTHON" ] && [ -x "venv/bin/python" ]; then
  PYTHON="venv/bin/python"
elif [ -z "$PYTHON" ] && [ -x ".venv/bin/python" ]; then
  PYTHON=".venv/bin/python"
fi

# 3) cPanel "Setup Python App" virtualenv:
#    app at /home/USER/fb-agent  ->  venv at /home/USER/virtualenv/fb-agent/3.11
if [ -z "$PYTHON" ]; then
  for candidate in ../virtualenv/*/*/bin/python; do
    if [ -x "$candidate" ]; then
      PYTHON="$candidate"
      break
    fi
  done
fi

# 4) Fall back to system interpreters.
if [ -z "$PYTHON" ]; then
  for candidate in python3.12 python3.11 python3.10 python3; do
    if command -v "$candidate" >/dev/null 2>&1; then
      PYTHON="$(command -v "$candidate")"
      break
    fi
  done
fi

if [ -z "${PYTHON:-}" ]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: No Python 3 interpreter found." >> data/agent.log
  exit 1
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Using $($PYTHON --version 2>&1) from $PYTHON" >> data/agent.log

exec "$PYTHON" -m app.main >> data/agent.log 2>&1
