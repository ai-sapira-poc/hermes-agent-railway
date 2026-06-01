# syntax=docker/dockerfile:1.7
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
# dev-brain-shared is a PRIVATE repo, so the build mints a short-lived GitHub App
# installation token from build secrets and clones with it. The token only ever lives
# in the BuildKit secret tmpfs (/run/secrets) and a shell var inside this single RUN --
# it is never written to an image layer, and `.git` (which would hold the token in the
# remote URL) is stripped immediately after checkout.
#
# Build secrets are supplied via railway.json `build.secrets` (GITHUB_APP_ID,
# GITHUB_APP_PRIVATE_KEY). INSTALLATION_ID is the ai-sapira-poc install that owns the repo.
# Pinned to a specific commit on main for reproducible deploys (A1); bump DEVBRAIN_REF to roll forward.
ARG DEVBRAIN_REF=4777f9133159b74132a2ffd85703e4fb7a0686f7
ARG INSTALLATION_ID=137054357
COPY mint_build_token.py /tmp/mint_build_token.py
RUN --mount=type=secret,id=GITHUB_APP_ID \
    --mount=type=secret,id=GITHUB_APP_PRIVATE_KEY \
    set -eu; \
    uv venv /tmp/minter --python 3.11; \
    VIRTUAL_ENV=/tmp/minter uv pip install --quiet "pyjwt[crypto]>=2.8"; \
    TOKEN="$(INSTALLATION_ID=$INSTALLATION_ID /tmp/minter/bin/python /tmp/mint_build_token.py)"; \
    git clone "https://x-access-token:${TOKEN}@github.com/ai-sapira-poc/dev-brain-shared.git" /opt/dev-brain-shared; \
    git -C /opt/dev-brain-shared checkout "$DEVBRAIN_REF"; \
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
