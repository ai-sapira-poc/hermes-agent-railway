FROM python:3.11-slim

RUN apt-get update && apt-get install -y \
    build-essential \
    python3-dev \
    && rm -rf /var/lib/apt/lists/*

RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates ripgrep ffmpeg \
    && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.local/bin:$PATH"

# --- upstream Hermes: the RUNTIME every agent on this box actually executes ----------
# PINNED, and it is the last of the three clones to become so. DEVBRAIN_REF 606502e8dbe324c1d58253106c6958472a66c095 FLEET_REF
# below were pinned for reproducible deploys; the runtime underneath them floated on
# whatever NousResearch had merged by build time -- so an unrelated DEVBRAIN_REF bump
# could change the agent runtime with nothing in the diff to say so. That is the same
# failure the FLEET_REF 64bc2c6adeff5b37c9226344418a6bd6e7143df3 note further down records having already been bitten by,
# one layer lower and harder to see.
#
# CHOSEN SHA: main's HEAD at the 2026-09-01 04:00Z build, which is what production has
# been running since. This pin is therefore a NO-OP at deploy time by construction -- it
# freezes the float, it does not perform an upgrade. Bump it deliberately, in its own PR.
#
# NOT a release tag, though upstream publishes them (vX.Y.Z) and a tag would build much
# faster -- see the fetch note below. The newest tag at time of writing, v2026.8.31, is 95
# commits BEHIND this SHA, so adopting it here would be a silent 95-commit rollback of a
# runtime that has been serving fine. A tag is the better pin the day upstream cuts one at
# or past what we are already running; it is not worth a rollback to get there.
ARG HERMES_REF=21b2095d00a98b8ad7b5c60b10587619c852cdb8

# SHALLOW, and FETCHED BY SHA rather than cloned. Upstream is ~810MB of history over an
# UNAUTHENTICATED connection: it took 5m37s and then earned an HTTP 429 from GitHub on
# 2026-09-01, failing a build for a reason that had no cause anywhere in this repo.
# `--depth 1` is the fix, and `git clone --depth 1` cannot take a SHA -- hence init +
# fetch, which GitHub serves for an arbitrary SHA.
#
# MEASURED 2026-09-01, and the shape of the win is worth knowing before someone "optimises"
# this: the shallow fetch moves 68MB against ~810MB for the full clone, a ~12x cut in bytes
# and so in rate-limit exposure, which is the failure this is here to prevent. Wall clock
# improves far less -- 2m23s against the 5m37s the failing clone had burned -- because
# almost all of it is GitHub computing a pack for a mid-history SHA, not transfer (68MB
# arrived in ~4s). The same shallow fetch of a TAG takes 18s, since a ref is served from a
# precomputed pack. That gap is the real argument for moving to tags later.
#
# `--recurse-submodules` is dropped with nothing lost: upstream carries no .gitmodules, so
# the flag has been a no-op. Restore it (and --shallow-submodules) if that ever changes.
#
# .git is deliberately KEPT, unlike the two private clones below, whose .git is removed to
# drop a token-bearing remote URL. There is no token here, and the method.env step reads
# rev-parse out of it.
RUN git init -q /opt/hermes-agent \
    && git -C /opt/hermes-agent remote add origin https://github.com/NousResearch/hermes-agent.git \
    && git -C /opt/hermes-agent fetch -q --depth 1 origin "$HERMES_REF" \
    && git -C /opt/hermes-agent checkout -q FETCH_HEAD

WORKDIR /opt/hermes-agent
RUN uv venv venv --python 3.11 \
    && VIRTUAL_ENV=/opt/hermes-agent/venv uv pip install -e ".[all]"

ENV PATH="/opt/hermes-agent/venv/bin:$PATH"

# --- dev-brain-shared (brain-factory service code: webhook receiver + pipeline) ------
# --- sapira-agent-fleet (the agent roster + the seeding plumbing) -------------------
# Both are PRIVATE repos. Railway's config-as-code schema does NOT support
# `build.secrets` (verified: build object has additionalProperties:false, no `secrets`),
# so BuildKit secret mounts can't be fed here. Instead we pass the GitHub App credentials
# as build ARGs -- Railway populates ARGs from service variables of the same name. The
# build mints a short-lived installation token, clones with it, then `rm -rf .git` to drop
# the token-bearing remote URL. The token lives only in a shell var inside this single RUN.
# NOTE: ARG values can appear in `docker history` of the intermediate layer; acceptable for
# a self-owned private repo + short-lived token. Both pinned for reproducible deploys (A1).
ARG DEVBRAIN_REF=fc498fdf8ff73e9a061f7adb62ae209627cd781f
# sapira-agent-fleet: the agent ROSTER (who the agents are) + the seeding plumbing.
# A SEPARATE pin from DEVBRAIN_REF on purpose -- a roster change (add an agent, move a
# channel) must deploy without dragging in every dev-brain-shared commit merged since,
# and vice versa. Both are bumped by the same guard in the same daily window.
# Cloned with the SAME installation token as dev-brain-shared, which requires the
# DEVBRAIN GitHub App to be installed on sapira-agent-fleet as well -- one token, two
# private repos, no second build credential to manage.
# HISTORY, kept because it explains why this ARG is watched at all. The pin first
# shipped on 2026-08-21 as the literal string `main`.
# That was on the theory that the pin guard would rewrite it to a SHA on its first
# run. It would not have: the guard only rewrites an ARG it finds
# DRIFTED, and a deployed FLEET_SHA taken from `main` at build time always equals
# `main` at compare time, so it reads as in-sync forever. The floating ref meant any
# rebuild -- a DEVBRAIN_REF bump, say -- silently picked up whatever roster had been
# merged since, deploying it without the bump PR that is supposed to record when a
# roster change goes live. From here normal drift handling applies.
ARG FLEET_REF=bbbf8d873eb605eace7d1fa87683c5da3fd14d8b
ARG INSTALLATION_ID=137054357
# Build-time GitHub App creds. Accept both the legacy bare names and the
# product-prefixed DEVBRAIN_* names (Railway populates ARGs from service
# vars of the same name). The RUN step below prefers DEVBRAIN_* and falls
# back to the legacy names, so the build is green during the rename migration
# regardless of which variable names currently exist in Railway.
ARG GITHUB_APP_ID
ARG GITHUB_APP_PRIVATE_KEY
ARG DEVBRAIN_GITHUB_APP_ID
ARG DEVBRAIN_GITHUB_APP_PRIVATE_KEY
ARG DEVBRAIN_INSTALLATION_ID
COPY mint_build_token.py /tmp/mint_build_token.py
RUN set -eu; \
    uv venv /tmp/minter --python 3.11; \
    VIRTUAL_ENV=/tmp/minter uv pip install --quiet "pyjwt[crypto]>=2.8"; \
    TOKEN="$(GITHUB_APP_ID="${DEVBRAIN_GITHUB_APP_ID:-$GITHUB_APP_ID}" GITHUB_APP_PRIVATE_KEY="${DEVBRAIN_GITHUB_APP_PRIVATE_KEY:-$GITHUB_APP_PRIVATE_KEY}" INSTALLATION_ID="${DEVBRAIN_INSTALLATION_ID:-$INSTALLATION_ID}" /tmp/minter/bin/python /tmp/mint_build_token.py)"; \
    git clone "https://x-access-token:${TOKEN}@github.com/ai-sapira-poc/dev-brain-shared.git" /opt/dev-brain-shared; \
    git -C /opt/dev-brain-shared checkout "$DEVBRAIN_REF"; \
    METHOD_SHA="$(git -C /opt/dev-brain-shared rev-parse HEAD)"; \
    METHOD_VERSION="$(git -C /opt/dev-brain-shared describe --tags --exact-match 2>/dev/null \
                      || git -C /opt/dev-brain-shared describe --tags 2>/dev/null \
                      || echo "$METHOD_SHA")"; \
    git clone "https://x-access-token:${TOKEN}@github.com/ai-sapira-poc/sapira-agent-fleet.git" /opt/sapira-agent-fleet; \
    git -C /opt/sapira-agent-fleet checkout "$FLEET_REF"; \
    FLEET_SHA="$(git -C /opt/sapira-agent-fleet rev-parse HEAD)"; \
    FLEET_VERSION="$(git -C /opt/sapira-agent-fleet describe --tags --exact-match 2>/dev/null \
                      || git -C /opt/sapira-agent-fleet describe --tags 2>/dev/null \
                      || echo "$FLEET_SHA")"; \
    HERMES_SHA="$(git -C /opt/hermes-agent rev-parse HEAD)"; \
    printf 'DEV_BRAIN_METHOD_VERSION=%s\nDEV_BRAIN_METHOD_SHA=%s\nFLEET_VERSION=%s\nFLEET_SHA=%s\nHERMES_SHA=%s\n' \
           "$METHOD_VERSION" "$METHOD_SHA" "$FLEET_VERSION" "$FLEET_SHA" "$HERMES_SHA" > /opt/method.env; \
    rm -rf /opt/dev-brain-shared/.git /opt/sapira-agent-fleet/.git; \
    unset TOKEN; \
    rm -rf /tmp/minter /tmp/mint_build_token.py; \
    VIRTUAL_ENV=/opt/hermes-agent/venv uv pip install -r /opt/dev-brain-shared/requirements-service.txt

# --- OpenTelemetry, zero-code ------------------------------------------------------
# Hermes is upstream's code, pinned by SHA above. We do not own a line of it, so the only
# instrumentation available is the kind that needs none: `opentelemetry-instrument` wraps
# the process, patches the libraries it finds, and emits spans with no import anywhere in
# the application -- which is also what ENG-STD-0018 §1 asks for, arrived at by necessity
# rather than discipline.
#
# openai-v2 is the one that matters. The HTTP instrumentations give span shapes; only the
# GenAI one gives `gen_ai.request.model` and token counts, and a dashboard without those
# is outlines with no cost or model in them.
#
# PINNED, all of them. opentelemetry-api 1.44.0 is ALREADY in this venv as a transitive
# dep, and the exporter below is pinned to exactly that version so this install adds
# packages rather than upgrading one the runtime is already importing.
RUN VIRTUAL_ENV=/opt/hermes-agent/venv uv pip install \
      "opentelemetry-distro==0.65b0" \
      "opentelemetry-exporter-otlp-proto-http==1.44.0" \
      "opentelemetry-instrumentation-openai-v2==2.4b0" \
      "opentelemetry-instrumentation-httpx==0.65b0" \
      "opentelemetry-instrumentation-requests==0.65b0" \
      "opentelemetry-instrumentation-aiohttp-client==0.65b0" \
      "opentelemetry-instrumentation-fastapi==0.65b0"

RUN mkdir -p /root/.hermes/{cron,sessions,logs,memories,skills,pairing,hooks,image_cache,audio_cache} \
    && cp cli-config.yaml.example /root/.hermes/config.yaml \
    && touch /root/.hermes/.env

COPY auth_proxy.py /auth_proxy.py
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
