#!/usr/bin/env python3
"""Start a dedicated localhost-only ATLAS stack; preserve existing credentials."""
import os
from pathlib import Path
import secrets
import subprocess

root = Path(__file__).resolve().parents[2]
env = root / ".env.atlas"
if not env.exists():
    descriptor = os.open(env, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(descriptor, "w") as stream:
        stream.write("ATLAS_DB_PASSWORD=" + secrets.token_urlsafe(32) + "\n")
subprocess.run(["docker", "compose", "--env-file", str(env), "-p", "federatedps-atlas",
                "-f", str(root / "atlas/compose.yaml"), "up", "-d"], check=True)
print("ATLAS: http://localhost:18081/atlas/; WebAPI: http://localhost:18080/WebAPI")
