# Validation of native Windows entry points

Validation performed on 2026-10-24:

- All PowerShell scripts parse using PowerShell 7.4.6 on Linux. Scripts target
  Windows PowerShell 5.1 and avoid PowerShell 7-only process/environment APIs.
- `windows/tests/Test-Launcher.ps1` passes with real child processes: names,
  arguments with spaces/quotes/trailing backslashes, nonzero exit propagation,
  cleanup of launched workers, and wall-clock timeout.
- 98 R files under `R`, `windows`, and `experiments` parse using R 4.3.3 on Linux.
- `windows/tests/test-validation.R` passes: run/site identifiers, block packet
  dimensions/order, design input dimensions, missing credential isolation,
  result agreement, and invalidation of an earlier success marker.
- The exact Cyclops source archive in `runtime-lock.json` was downloaded,
  SHA-256 checked, and checked for ZIP CRC errors. `Prepare-Offline.ps1` accepts
  that cached archive and verifies its expected source root.
- `git diff --check` passes.

Not executed in this development environment: Windows R 4.6.1/Rtools45
compilation or installation, RStudio GUI, the complete numerical synthetic
federation, the existing dependency-heavy testthat suite, and CDM database
extraction. No claim of an end-to-end Windows pass is made here.

Target-host acceptance commands (run from the source root after bringing in the
payload; close R/RStudio before installation):

```powershell
.\windows\Install-Offline.ps1
.\windows\tests\Test-Launcher.ps1
.\windows\Run-FederatedPS.ps1 -Mode Synthetic
.\windows\Run-FederatedPS.ps1 -Mode Synthetic -BlockSize 4 -Alpha 0.5
```

Only after both synthetic runs finish with `SUCCESS.txt`, configure site
connections and run Database mode as described in `README_KO.md`.
