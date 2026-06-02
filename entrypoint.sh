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

# === 5.6 profile seed === materialize operator (/root/.hermes) + architect
# (/root/.hermes/profiles/architect) .env files from Railway service vars,
# BEFORE any gateway/service starts. Idempotent + only-if-absent; non-fatal so a
# seed failure never blocks the operator (it just means the architect bot is
# unavailable). See dev-brain-shared/docs/5.6-RAILWAY-BOOT-SEED.md.
if [ -f /opt/dev-brain-shared/scripts/deploy/seed_profiles.sh ]; then
  bash /opt/dev-brain-shared/scripts/deploy/seed_profiles.sh || \
    echo "[seed] profile seed failed (non-fatal); architect bot may be unavailable" >&2
else
  echo "[seed] seed_profiles.sh not found; skipping (architect bot unavailable)" >&2
fi

# Architect gateway: the operator's service is auth_proxy (below); the architect
# is an interactive profile that needs its OWN gateway under its OWN HERMES_HOME.
# Only started when its bot token is present (we won't run a tokenless gateway).
if [ -n "${ARCHITECT_TELEGRAM_BOT_TOKEN:-}" ]; then
  echo "Starting architect gateway..."
  HERMES_HOME=/root/.hermes/profiles/architect \
    hermes gateway run >/tmp/architect-gateway.log 2>&1 &
else
  echo "[architect] ARCHITECT_TELEGRAM_BOT_TOKEN unset; architect gateway not started" >&2
fi

hermes dashboard --host 127.0.0.1 --port 9119 --no-open &

exec python /auth_proxy.py
