#!/usr/bin/env python3
"""Vendor the public, version-pinned cohort sources used by FederatedPs.

Only public GitHub files are downloaded. No patient data or credentials are read.
Run from any directory; existing files must have the same content.
"""
import hashlib
import json
from pathlib import Path
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[2]
DEST = ROOT / "inst" / "studies" / "source"
SOURCES = {
    "Legend": ("OHDSI/Legend", "4e7867fc3fc9ce902f2fb5274252484d7f38060b", [
        "DESCRIPTION", "inst/settings/ExposuresOfInterest.csv",
        "inst/sql/sql_server/CreateExposureCohortsHypertension.sql",
        "inst/sql/sql_server/CreateCohortPairs.sql",
        "R/CreateExposureCohorts.R"]),
    "StudyProtocols": ("OHDSI/StudyProtocols", "8de0454c6be4c120ba97d7376907d651327573a4", [
        "LargeScalePopEst/DESCRIPTION", "LargeScalePopEst/inst/settings/ExposuresOfInterest.csv",
        "LargeScalePopEst/inst/sql/sql_server/ExposureCohorts.sql",
        "LargeScalePopEst/inst/sql/sql_server/CreateCohortPairs.sql",
        "KeppraAngioedema/DESCRIPTION", "KeppraAngioedema/inst/circe/Treatment.json",
        "KeppraAngioedema/inst/circe/Comparator.json",
        "AlendronateVsRaloxifene/DESCRIPTION", "AlendronateVsRaloxifene/inst/cohorts/Alendronate.json",
        "AlendronateVsRaloxifene/inst/cohorts/Raloxifene.json"]),
    "PhenotypeLibrary": ("OHDSI/PhenotypeLibrary", "40106e4e2892d883c208b9df10ad56711da3e21d", [
        "DESCRIPTION", "inst/Cohorts.csv", *[f"inst/cohorts/{n}.json" for n in
                                       (1046, 1047, 1060, 1061, 1062, 1063, 1064)]])
}


def main():
    manifest = []
    for name, (repo, commit, paths) in SOURCES.items():
        for path in paths:
            url = f"https://raw.githubusercontent.com/{repo}/{commit}/{path}"
            with urlopen(Request(url, headers={"User-Agent": "FederatedPs"}), timeout=60) as response:
                data = response.read()
            target = DEST / name / path
            target.parent.mkdir(parents=True, exist_ok=True)
            if target.exists() and target.read_bytes() != data:
                raise RuntimeError(f"Refusing to replace changed source: {target}")
            target.write_bytes(data)
            manifest.append(dict(repository=repo, commit=commit, path=path,
                                 file=str(target.relative_to(ROOT / "inst" / "studies")),
                                 url=url, sha256=hashlib.sha256(data).hexdigest()))
            print(f"Fetched {name}/{path}", flush=True)
    (DEST / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()
