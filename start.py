#!/usr/bin/env python3
"""Start the aggregator and hospital RStudio environments for one study."""
import argparse
import os
from pathlib import Path
import subprocess
from uuid import uuid4

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("run_id", nargs="?", default=uuid4().hex)
parser.add_argument("--study", default=os.environ.get("FEDERATEDPS_STUDY", "opioid"))
parser.add_argument("--scenario", choices=["default", "studySpecific"],
                    default=os.environ.get("FEDERATEDPS_SCENARIO", "default"))
parser.add_argument("--ehrshot", action="store_true", help="Include EHRSHOT as the third hospital")
args = parser.parse_args()
project = Path(__file__).resolve().parent
sites = ["mimic", "synpuf"] + (["ehrshot"] if args.ehrshot else [])
for site in ["aggregator"] + sites:
    (project / "work" / site).mkdir(parents=True, exist_ok=True, mode=0o700)
environment = dict(os.environ, FEDERATEDPS_RUN=args.run_id,
                   FEDERATEDPS_STUDY=args.study, FEDERATEDPS_SCENARIO=args.scenario,
                   FEDERATEDPS_SITES=",".join(sites),
                   COMPOSE_PROFILES="ehrshot" if args.ehrshot else "")
subprocess.run(["docker", "compose", "-p", "federatedps-slides", "up", "--build",
                "-d", "--remove-orphans"], cwd=project, env=environment, check=True)
subprocess.run(["docker", "compose", "-p", "federatedps-slides", "exec", "-T",
                "-u", "root", "aggregator", "sh", "-c",
                'chown "$USERID:$GROUPID" /exchange && chmod 700 /exchange'],
               cwd=project, env=environment, check=True)
print(f"Run: {args.run_id}; study: {args.study}; scenario: {args.scenario}")
for site, port in [("aggregator", 38787), ("mimic", 38788), ("synpuf", 38789), ("ehrshot", 38790)]:
    if site == "aggregator" or site in sites:
        print(f"{site}: http://localhost:{port}")
