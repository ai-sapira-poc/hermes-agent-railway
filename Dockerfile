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

RUN git clone --recurse-submodules https://github.com/NousResearch/hermes-agent.git /opt/hermes-agent

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
ARG DEVBRAIN_REF=eb7f6eadbeb87fabcd745bd2fc1805a0d3dfcad3
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
ARG FLEET_REF=73bb120988991dabec187c699350605fc532dff1
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
    printf 'DEV_BRAIN_METHOD_VERSION=%s\nDEV_BRAIN_METHOD_SHA=%s\nFLEET_VERSION=%s\nFLEET_SHA=%s\n' \
           "$METHOD_VERSION" "$METHOD_SHA" "$FLEET_VERSION" "$FLEET_SHA" > /opt/method.env; \
    rm -rf /opt/dev-brain-shared/.git /opt/sapira-agent-fleet/.git; \
    unset TOKEN; \
    rm -rf /tmp/minter /tmp/mint_build_token.py; \
    VIRTUAL_ENV=/opt/hermes-agent/venv uv pip install -r /opt/dev-brain-shared/requirements-service.txt

RUN mkdir -p /root/.hermes/{cron,sessions,logs,memories,skills,pairing,hooks,image_cache,audio_cache} \
    && cp cli-config.yaml.example /root/.hermes/config.yaml \
    && touch /root/.hermes/.env

COPY auth_proxy.py /auth_proxy.py
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
