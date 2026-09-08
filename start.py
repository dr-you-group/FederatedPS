#!/usr/bin/env python3
"""Start the aggregator, MIMIC and SynPUF RStudio environments."""
import os
from pathlib import Path
import subprocess
import sys
from uuid import uuid4

project = Path(__file__).resolve().parent
run_id = sys.argv[1] if len(sys.argv) > 1 else uuid4().hex
for directory in ["work/aggregator", "work/mimic", "work/synpuf"]:
    (project / directory).mkdir(parents=True, exist_ok=True, mode=0o700)
environment = dict(os.environ, FEDERATEDPS_RUN=run_id)
subprocess.run(["docker", "compose", "-p", "federatedps-slides", "up", "--build",
                "-d", "--remove-orphans"], cwd=project, env=environment, check=True)
subprocess.run(["docker", "compose", "-p", "federatedps-slides", "exec", "-T",
                "-u", "root", "aggregator", "sh", "-c",
                'chown "$USERID:$GROUPID" /exchange && chmod 700 /exchange'],
               cwd=project, env=environment, check=True)
print(f"Run: {run_id}")
for site, port in [("aggregator", 38787), ("mimic", 38788), ("synpuf", 38789)]:
    print(f"{site}: http://localhost:{port}")
