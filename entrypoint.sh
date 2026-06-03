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

# === per-product agent seed === materialize one isolated Hermes profile per
# product (~/.hermes/profiles/agent-<product>) from dev-brain-shared's product
# registry, BEFORE any gateway/service starts. Idempotent + only-if-absent;
# non-fatal so a seed failure never blocks the box. Symmetric model: no
# architect/operator — see dev-brain-shared/AGENTS-TOPOLOGY.md.
if [ -f /opt/dev-brain-shared/scripts/deploy/seed_profiles.sh ]; then
  bash /opt/dev-brain-shared/scripts/deploy/seed_profiles.sh || \
    echo "[seed] agent seed failed (non-fatal); some product agents may be unavailable" >&2
else
  echo "[seed] seed_profiles.sh not found; skipping (no product agents seeded)" >&2
fi

# Start an interactive gateway for EACH seeded agent that has a bot token in its
# own .env. Agents without a TELEGRAM_BOT_TOKEN run headless (webhook/cron only).
# Each gateway runs under that agent's OWN HERMES_HOME -> full memory isolation.
for agent_dir in /root/.hermes/profiles/agent-*/; do
  [ -d "$agent_dir" ] || continue
  agent_env="${agent_dir}.env"
  if [ -f "$agent_env" ] && grep -q '^TELEGRAM_BOT_TOKEN=.\+' "$agent_env"; then
    agent_name="$(basename "$agent_dir")"
    echo "Starting gateway for ${agent_name}..."
    HERMES_HOME="${agent_dir%/}" \
      hermes gateway run >"/tmp/${agent_name}-gateway.log" 2>&1 &
  fi
done

hermes dashboard --host 127.0.0.1 --port 9119 --no-open &

# === infra pin-drift guard (hourly) === runs INSIDE this service so it inherits
# the DEVBRAIN_* GitHub App creds, the script, and the right working dir, and
# survives redeploys (it is baked into the image). It compares the deployed
# dev-brain-shared pin (DEV_BRAIN_METHOD_SHA) against main HEAD and, when behind,
# opens a reviewable DEVBRAIN_REF bump PR on hermes-agent-railway. It NEVER merges
# or redeploys. Disable with PIN_DRIFT_GUARD=off (or =false). Self-contained: a guard
# failure is swallowed so it can never affect the loop or the main service.
if [ "${PIN_DRIFT_GUARD:-on}" != "off" ] && [ "${PIN_DRIFT_GUARD:-on}" != "false" ] && \
   [ -f /opt/dev-brain-shared/scripts/ops/pin_drift_guard.py ]; then
  echo "Starting hourly pin-drift guard..."
  (
    sleep 120   # let boot churn settle before the first check
    while true; do
      ( cd /opt/dev-brain-shared && \
        /opt/hermes-agent/venv/bin/python scripts/ops/pin_drift_guard.py ) \
        >/tmp/pin-drift-guard.log 2>&1 || true
      sleep "${PIN_DRIFT_GUARD_INTERVAL:-3600}"
    done
  ) &
else
  echo "[pin-drift-guard] disabled or script missing; skipping" >&2
fi

exec python /auth_proxy.py
