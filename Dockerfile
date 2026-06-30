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

# --- dev-brain-shared: the brain-factory service code (webhook receiver + pipeline). ---
# dev-brain-shared is a PRIVATE repo. Railway's config-as-code schema does NOT support
# `build.secrets` (verified: build object has additionalProperties:false, no `secrets`),
# so BuildKit secret mounts can't be fed here. Instead we pass the GitHub App credentials
# as build ARGs -- Railway populates ARGs from service variables of the same name. The
# build mints a short-lived installation token, clones with it, then `rm -rf .git` to drop
# the token-bearing remote URL. The token lives only in a shell var inside this single RUN.
# NOTE: ARG values can appear in `docker history` of the intermediate layer; acceptable for
# a self-owned private repo + short-lived token. Pinned for reproducible deploys (A1).
ARG DEVBRAIN_REF=601b68eaec4834af5cbce5b2963ff904389609d9
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
    printf 'DEV_BRAIN_METHOD_VERSION=%s\nDEV_BRAIN_METHOD_SHA=%s\n' "$METHOD_VERSION" "$METHOD_SHA" > /opt/method.env; \
    rm -rf /opt/dev-brain-shared/.git; \
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
