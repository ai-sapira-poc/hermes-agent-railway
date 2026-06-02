#!/usr/bin/env bash
set -e

AUTO_UPDATE="${AUTO_UPDATE:-true}"

# Method-version stamp (5.4): the build wrote the resolved dev-brain-shared
# tag/SHA here BEFORE `rm -rf .git`, because the deployed image has no .git.
# Export them so the in-process pipeline (auth_proxy.py -> ledger.start_run)
# stamps every run with the exact method version that produced it.
# Runtime override still wins: only set from the file if not already in env.
if [ -f /opt/method.env ]; then
  while IFS='=' read -r k v; do
    [ -n "$k" ] || continue
    if [ -z "$(eval "echo \${$k:-}")" ]; then
      export "$k=$v"
    fi
  done < /opt/method.env
fi

if [ "$AUTO_UPDATE" = "true" ]; then
  echo "Checking for Hermes updates..."
  cd /opt/hermes-agent
  if git pull --recurse-submodules 2>&1 | grep -v 'Already up to date'; then
    echo "Updating dependencies..."
    VIRTUAL_ENV=/opt/hermes-agent/venv uv pip install -e ".[all]" --quiet
    echo "Update complete."
  else
    echo "Already up to date."
  fi
fi

hermes dashboard --host 127.0.0.1 --port 9119 --no-open &

exec python /auth_proxy.py
