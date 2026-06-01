#!/usr/bin/env python3
"""Mint a GitHub App installation token at BUILD TIME for cloning a private repo.

Reads the App credentials from ENVIRONMENT VARIABLES (passed as Docker build ARGs,
which Railway populates from service variables). Railway's config-as-code schema does
NOT support `build.secrets` (verified against railway.schema.json: build has
additionalProperties:false and no `secrets` key), so BuildKit secret mounts can't be
fed by Railway here -- build ARGs are the supported channel.

Env (required):
    GITHUB_APP_ID            - numeric App ID
    GITHUB_APP_PRIVATE_KEY   - PEM private key (may contain literal \\n escapes)
    INSTALLATION_ID          - installation to mint for (ai-sapira-poc = 137054357)

Prints ONLY the token to stdout. All diagnostics go to stderr. Key material is
never printed or logged.
"""
import os
import sys
import time
import json
import urllib.request
import urllib.error


def _require_env(name: str) -> str:
    val = os.environ.get(name, "").strip()
    if not val:
        sys.stderr.write(f"[mint] required env not set: {name}\n")
        sys.exit(3)
    return val


def main() -> None:
    app_id = _require_env("GITHUB_APP_ID")
    priv = _require_env("GITHUB_APP_PRIVATE_KEY").replace("\\n", "\n")
    inst = _require_env("INSTALLATION_ID")

    try:
        import jwt  # pyjwt[crypto]
    except Exception as e:  # pragma: no cover
        sys.stderr.write(f"[mint] pyjwt import failed: {e}\n")
        sys.exit(4)

    now = int(time.time())
    assertion = jwt.encode(
        {"iat": now - 60, "exp": now + 540, "iss": app_id},
        priv,
        algorithm="RS256",
    )

    req = urllib.request.Request(
        f"https://api.github.com/app/installations/{inst}/access_tokens",
        method="POST",
    )
    req.add_header("Authorization", f"Bearer {assertion}")
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("User-Agent", "pharo-hermes-brain-factory-build")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            data = json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        body = ""
        try:
            body = json.loads(e.read().decode()).get("message", "")
        except Exception:
            pass
        sys.stderr.write(f"[mint] token mint failed: HTTP {e.code} {body!r}\n")
        sys.exit(5)

    token = data.get("token")
    if not token:
        sys.stderr.write("[mint] response had no token\n")
        sys.exit(6)
    sys.stdout.write(token)


if __name__ == "__main__":
    main()
