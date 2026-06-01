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
# Pinned to a specific commit on main for reproducible deploys (A1). Bump DEVBRAIN_REF to
# roll forward after merging changes to dev-brain-shared. The webhook mount in
# auth_proxy.py imports webhook.app from /opt/dev-brain-shared/scripts; its runtime deps
# (psycopg, pyjwt, cryptography, requests) are installed into the hermes venv below.
ARG DEVBRAIN_REF=4777f9133159b74132a2ffd85703e4fb7a0686f7
RUN git clone https://github.com/ai-sapira-poc/dev-brain-shared.git /opt/dev-brain-shared \
    && git -C /opt/dev-brain-shared checkout "$DEVBRAIN_REF" \
    && VIRTUAL_ENV=/opt/hermes-agent/venv uv pip install -r /opt/dev-brain-shared/requirements-service.txt

RUN mkdir -p /root/.hermes/{cron,sessions,logs,memories,skills,pairing,hooks,image_cache,audio_cache} \
    && cp cli-config.yaml.example /root/.hermes/config.yaml \
    && touch /root/.hermes/.env

COPY auth_proxy.py /auth_proxy.py
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
