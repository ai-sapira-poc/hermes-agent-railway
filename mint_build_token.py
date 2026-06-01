#!/usr/bin/env python3
"""Mint a GitHub App installation token at BUILD TIME for cloning a private repo.

Reads secrets from BuildKit secret mounts (/run/secrets/...), never from argv,
so nothing sensitive lands in image layers or `docker history`.

Required mounted secrets (files):
    /run/secrets/GITHUB_APP_ID
    /run/secrets/GITHUB_APP_PRIVATE_KEY   (PEM; may contain literal \\n escapes)
Env:
    INSTALLATION_ID   - installation to mint for (ai-sapira-poc = 137054357)

Prints ONLY the token to stdout. All diagnostics go to stderr. Key material is
never printed or logged.
"""
import os
import sys
import time
import json
import urllib.request
import urllib.error


def _read_secret(name: str) -> str:
    path = f"/run/secrets/{name}"
    try:
        with open(path, "r") as f:
            return f.read().strip()
    except FileNotFoundError:
        sys.stderr.write(f"[mint] missing build secret: {path}\n")
        sys.exit(3)


def main() -> None:
    app_id = _read_secret("GITHUB_APP_ID")
    priv = _read_secret("GITHUB_APP_PRIVATE_KEY").replace("\\n", "\n")
    inst = os.environ.get("INSTALLATION_ID", "").strip()
    if not inst:
        sys.stderr.write("[mint] INSTALLATION_ID env not set\n")
        sys.exit(3)

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
        # never echo key/jwt; only status + safe message
        sys.stderr.write(f"[mint] token mint failed: HTTP {e.code} {body!r}\n")
        sys.exit(5)

    token = data.get("token")
    if not token:
        sys.stderr.write("[mint] response had no token\n")
        sys.exit(6)
    # ONLY the token to stdout
    sys.stdout.write(token)


if __name__ == "__main__":
    main()
