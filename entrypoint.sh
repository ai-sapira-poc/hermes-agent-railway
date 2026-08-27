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

# === fleet seed === materialize one isolated Hermes profile per ROSTER ENTRY
# (~/.hermes/profiles/agent-<name>) BEFORE any gateway/service starts. Idempotent +
# self-correcting; non-fatal so a seed failure never blocks the box.
#
# The roster lives in sapira-agent-fleet (who the agents are). PRODUCTS_REGISTRY
# points at dev-brain-shared's product catalog, which a `kind: product-brain` entry
# references by product_ref for its credentials and source repos -- the two files
# are deliberately not merged, because the catalog has six other readers inside
# dev-brain-shared. See sapira-agent-fleet/FLEET-TOPOLOGY.md.
export PRODUCTS_REGISTRY="${PRODUCTS_REGISTRY:-/opt/dev-brain-shared/configs/products.registry.json}"
export FLEET_ROOT="${FLEET_ROOT:-/opt/sapira-agent-fleet}"
if [ -f "${FLEET_ROOT}/scripts/deploy/seed_profiles.sh" ]; then
  bash "${FLEET_ROOT}/scripts/deploy/seed_profiles.sh" || \
    echo "[seed] fleet seed failed (non-fatal); some agents may be unavailable" >&2
else
  echo "[seed] seed_profiles.sh not found under ${FLEET_ROOT}; skipping (no agents seeded)" >&2
fi

# Tell the in-process GitHub webhook receiver (auth_proxy.py -> webhook.app) to read its
# HMAC signing secret from the product-namespaced env vars, keeping per-product isolation.
# It used to read the bare GITHUB_WEBHOOK_SECRET, which is not set anywhere on this
# service (only the namespaced DEVBRAIN_GITHUB_WEBHOOK_SECRET is), so /webhook/github
# answered EVERY delivery `500 webhook secret not configured` — silently disabling the
# real-time merged-PR path and leaving the reconciliation cron to carry brain updates
# alone. Verified against production 2026-08-20.
#
# ONE NAME PER GITHUB APP, comma-separated: the receiver tries the signature against every
# secret that resolves and any match verifies. Each App therefore keeps its own key —
# sharing one across Apps would also work, and would mean compromising any one of them
# lets an attacker forge deliveries for all. A name whose variable is unset is skipped, so
# listing an App before its secret is provisioned costs nothing: that App's deliveries are
# rejected 401 until the value lands, and every other App keeps working. Only when NONE of
# the names resolve is it a 500 — the misconfiguration answer, distinct from a rejection.
#
# NOTE: this file is the IMAGE, so no DEVBRAIN_REF/FLEET_REF pin bump can deliver a change
# here. It ships when this repo redeploys, which is why the multi-secret receiver in
# dev-brain-shared and this line are two separate PRs that must both land.
: "${GITHUB_WEBHOOK_SECRET_ENV:=DEVBRAIN_GITHUB_WEBHOOK_SECRET,STANDARDS_GITHUB_WEBHOOK_SECRET}"
export GITHUB_WEBHOOK_SECRET_ENV
# own .env. Each gateway runs under that agent's OWN HERMES_HOME -> full memory
# isolation.
#
# A gateway starts for any agent carrying EITHER a Telegram or a Slack bot token.
# It used to gate on TELEGRAM_BOT_TOKEN alone, which quietly broke Slack-only
# agents in a way that looks like nothing at all: the cron scheduler lives IN the
# gateway process, so no gateway means the agent's scheduled jobs never fire -- no
# error, no log line, just absence. Most utility agents are Slack-first and
# cron-driven, so that gate would have made them dead on arrival.
# Agents with neither token still run headless (webhook-only).
#
# Their PIDs are collected so term_handler() below can hand each one a SIGTERM.
# Upstream `hermes gateway run` already installs a SIGTERM handler that refuses new
# work and drains in-flight cron runs (agent.cron_drain_timeout, default 30s) before
# exiting -- but only if the signal REACHES it. Railway signals PID 1 only, and PID 1
# used to be auth_proxy (this file ended in `exec`), so these gateways were never
# signalled at all: every redeploy amputated whatever cron run was mid-flight and the
# upstream drain never got to run. Collecting the PIDs is what makes it reachable.

# === "back online" notice ============================================================
# The channels already get "⚠️ Gateway shutting down — Your current task will be
# interrupted." on every redeploy, and then silence. The half that says it came back was
# never reached, and the absence reads exactly like an agent that did not survive.
#
# Upstream already knows how to say it. `gateway/run.py` sends
#     ♻️ Gateway online — Hermes is back and ready.
# to every platform's home channel during startup -- but only when it finds
# <HERMES_HOME>/.restart_pending.json, a marker the gateway writes for ITSELF, on its way
# out, when it planned its own restart (`_restart_requested`: a /restart command, say).
#
# A Railway redeploy is not that. The platform SIGTERMs this container and starts a NEW
# one; the process that boots never planned anything and has nothing on disk saying so.
# The notice is not missing, it is unreachable — which is why enabling a setting was never
# going to fix it.
#
# So we drop the marker ourselves, per profile, before that profile's gateway starts.
# Everything after that is upstream's: it honours each platform's `home_channel` and its
# `gateway_restart_notification` flag, covers Slack and Telegram alike without this file
# knowing either API or holding either token, and unlinks the marker in a `finally` once
# the send is attempted -- so a failed send cannot leave a box that announces itself on
# every boot forever.
#
# Turn it off with GATEWAY_ONLINE_NOTICE=off.
: "${GATEWAY_ONLINE_NOTICE:=on}"

arm_online_notice() {  # arm_online_notice <profile-dir>
  [ "${GATEWAY_ONLINE_NOTICE}" = "on" ] || return 0
  _home="${1%/}"
  [ -d "$_home" ] || return 0
  # The same shape upstream writes (atomic_json_write, compact, no indent). Only the
  # file's EXISTENCE is read today -- `_planned_restart_notification_pending()` is an
  # `.exists()` check and nothing parses the body -- but valid JSON costs one printf and
  # survives upstream deciding to read a field out of it.
  # The braces matter. `printf ... > file 2>/dev/null` does NOT silence a failing
  # redirect: redirections are set up left to right, so `> file` has already failed and
  # printed to the real stderr by the time `2>/dev/null` is applied. On a read-only
  # profile that put a bare "Permission denied" in the boot log, which is a line somebody
  # investigates. Grouping puts the redirect inside the silenced region.
  { printf '{"requested_at":%s,"via_service":true,"detached":false}' "$(date +%s)" \
      > "${_home}/.restart_pending.json"; } 2>/dev/null || true
}

GATEWAY_PIDS=()
for agent_dir in /root/.hermes/profiles/agent-*/; do
  [ -d "$agent_dir" ] || continue
  agent_env="${agent_dir}.env"
  if [ -f "$agent_env" ] && grep -qE '^(TELEGRAM|SLACK)_BOT_TOKEN=.+' "$agent_env"; then
    agent_name="$(basename "$agent_dir")"
    arm_online_notice "$agent_dir"
    echo "Starting gateway for ${agent_name}..."
    HERMES_HOME="${agent_dir%/}" \
      hermes gateway run >"/tmp/${agent_name}-gateway.log" 2>&1 &
    GATEWAY_PIDS+=("$!")
  fi
done

hermes dashboard --host 127.0.0.1 --port 9119 --no-open &

# === infra pin-drift guard (hourly) === runs INSIDE this service so it inherits
# the DEVBRAIN_* GitHub App creds, the script, and the right working dir, and
# survives redeploys (it is baked into the image). It compares the deployed
# dev-brain-shared pin (DEV_BRAIN_METHOD_SHA) against main HEAD and, when behind,
# opens a DEVBRAIN_REF bump PR on hermes-agent-railway.
#
# AUTO-MERGE (this deployment opts in): the guard merges its own bump PR, so an
# already-reviewed dev-brain-shared main advance deploys without a manual click —
# Railway redeploys on the resulting push. Safe because the bump PR only changes the
# one DEVBRAIN_REF line and the content was already reviewed at the dev-brain-shared
# PR that merged it to main. Turn it back to propose-only with PIN_DRIFT_AUTOMERGE=off.
# Disable the guard entirely with PIN_DRIFT_GUARD=off. Self-contained: a guard failure
# is swallowed so it can never affect the loop or the main service.
: "${PIN_DRIFT_AUTOMERGE:=on}"
export PIN_DRIFT_AUTOMERGE

# CADENCE. The guard used to poll hourly, so every dev-brain-shared merge redeployed
# this container within the hour: 4-5 full restarts on an active day, each one taking
# down every agent in the box at an unpredictable moment. Restarts are now BATCHED to
# one predictable window a day. The cost is stated plainly: the fleet can run up to a
# day behind dev-brain-shared main. To ship something sooner, run the guard by hand
# (see docs) or drop PIN_DRIFT_DEPLOY_HOUR for the old interval behaviour.
#
#   PIN_DRIFT_DEPLOY_HOUR     UTC hour (0-23) to check+bump at. Empty -> interval mode.
#   PIN_DRIFT_GUARD_INTERVAL  seconds between checks in interval mode (default 24h).
#   PIN_DRIFT_BUSY_RETRY      seconds to wait when the guard DEFERRED the bump because
#                             an agent was mid-run (guard exits 75). Short on purpose:
#                             a deferred bump must not be parked until tomorrow.
#
# Note the window is a wall-clock UTC hour, not "24h since boot": the old interval
# restarted its clock on every boot, so "hourly" silently meant "hourly since the last
# redeploy" and the bump time wandered. Anchoring to a UTC hour keeps it where you put it.
: "${PIN_DRIFT_DEPLOY_HOUR:=4}"
: "${PIN_DRIFT_GUARD_INTERVAL:=86400}"
: "${PIN_DRIFT_BUSY_RETRY:=600}"

_seconds_until_hour() {   # seconds from now until the next occurrence of UTC hour $1
  local target="$1" now secs
  now=$(( 10#$(date -u +%H) * 3600 + 10#$(date -u +%M) * 60 + 10#$(date -u +%S) ))
  secs=$(( target * 3600 - now ))
  if [ "$secs" -le 0 ]; then secs=$(( secs + 86400 )); fi
  echo "$secs"
}

if [ "${PIN_DRIFT_GUARD:-on}" != "off" ] && [ "${PIN_DRIFT_GUARD:-on}" != "false" ] && \
   [ -f /opt/dev-brain-shared/scripts/ops/pin_drift_guard.py ]; then
  if [ -n "$PIN_DRIFT_DEPLOY_HOUR" ]; then
    echo "Starting pin-drift guard (daily at ${PIN_DRIFT_DEPLOY_HOUR}:00 UTC, auto-merge=${PIN_DRIFT_AUTOMERGE})..."
  else
    echo "Starting pin-drift guard (every ${PIN_DRIFT_GUARD_INTERVAL}s, auto-merge=${PIN_DRIFT_AUTOMERGE})..."
  fi
  (
    sleep 120   # let boot churn settle before the first check
    while true; do
      if [ -n "$PIN_DRIFT_DEPLOY_HOUR" ]; then
        _nap="$(_seconds_until_hour "$PIN_DRIFT_DEPLOY_HOUR")"
        echo "[pin-drift-guard] next check in ${_nap}s"
        sleep "$_nap"
      fi
      if ( cd /opt/dev-brain-shared && \
           /opt/hermes-agent/venv/bin/python scripts/ops/pin_drift_guard.py ) \
           >/tmp/pin-drift-guard.log 2>&1; then
        _rc=0
      else
        _rc=$?
      fi
      if [ "$_rc" -eq 75 ]; then
        # EX_TEMPFAIL: the guard found agents mid-run and declined to deploy on top of
        # live work. Come back soon rather than waiting for the next daily window.
        echo "[pin-drift-guard] bump deferred (agents busy); retrying in ${PIN_DRIFT_BUSY_RETRY}s"
        sleep "$PIN_DRIFT_BUSY_RETRY"
      elif [ -z "$PIN_DRIFT_DEPLOY_HOUR" ]; then
        sleep "$PIN_DRIFT_GUARD_INTERVAL"
      fi
    done
  ) &
  GUARD_PID=$!
else
  echo "[pin-drift-guard] disabled or script missing; skipping" >&2
fi

# === graceful shutdown ===============================================================
# auth_proxy runs as a CHILD (it used to be `exec`d) so this shell stays PID 1 and can
# fan the platform's stop signal out to everything else in the box. Order matters:
# the pin-drift guard dies first (a container on its way out must never open or merge
# a bump PR), then the gateways get the SIGTERM that lets them run their own in-flight
# cron drain, and only then does the web tier go.
#
# HERMES_DRAIN_TIMEOUT bounds how long we wait for the gateways. The gateway's own cron
# drain is ~30s (agent.cron_drain_timeout, itself clamped by hermes's shutdown watchdog),
# so waiting much past that buys nothing. Be clear-eyed about what this does and does
# not do: the whole handler runs inside the PLATFORM's stop grace period, so if Railway
# SIGKILLs first the drain is simply cut short. Draining is what saves SHORT jobs. A
# brain update runs for minutes and will still be interrupted -- what protects THAT is
# being resumable (dev-brain-shared reconcile advances its watermark only after the
# brain-update PR is settled), not being waited for.
: "${HERMES_DRAIN_TIMEOUT:=25}"

term_handler() {
  trap '' TERM INT          # ignore repeat signals while draining
  echo "[drain] stop requested -- draining ${#GATEWAY_PIDS[@]} gateway(s), budget ${HERMES_DRAIN_TIMEOUT}s"
  if [ -n "${GUARD_PID:-}" ]; then
    kill "$GUARD_PID" 2>/dev/null || true
  fi
  # Every array expansion is guarded by a count check: a headless box (no profile
  # carries a platform bot token) leaves GATEWAY_PIDS empty, and an empty "${a[@]}"
  # is an unbound-variable error under `set -u`. The drain must not be the thing
  # that breaks a shutdown.
  if [ "${#GATEWAY_PIDS[@]}" -gt 0 ]; then
    for _pid in "${GATEWAY_PIDS[@]}"; do
      if [ -n "$_pid" ]; then kill -TERM "$_pid" 2>/dev/null || true; fi
    done
  fi
  _waited=0
  _alive=0
  while [ "$_waited" -lt "$HERMES_DRAIN_TIMEOUT" ]; do
    _alive=0
    if [ "${#GATEWAY_PIDS[@]}" -gt 0 ]; then
      for _pid in "${GATEWAY_PIDS[@]}"; do
        if [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null; then _alive=$(( _alive + 1 )); fi
      done
    fi
    if [ "$_alive" -eq 0 ]; then break; fi
    sleep 1
    _waited=$(( _waited + 1 ))
  done
  if [ "$_alive" -gt 0 ]; then
    echo "[drain] ${_alive} gateway(s) still busy after ${_waited}s -- the container stop will kill them" >&2
  else
    echo "[drain] gateways exited cleanly after ${_waited}s"
  fi
  kill -TERM "$MAIN_PID" 2>/dev/null || true
  wait "$MAIN_PID" 2>/dev/null || true
  exit 0
}
trap term_handler TERM INT

python /auth_proxy.py &
MAIN_PID=$!
wait "$MAIN_PID" || MAIN_RC=$?
exit "${MAIN_RC:-0}"
