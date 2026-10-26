# ODBC release validation — 2026-10-27

FederatedPs 0.0.11 adds an explicit native ODBC database transport. The supplied
Windows payload targets R 4.6.1 x64. Local development checks ran with R 4.3.3
and PowerShell 7.4.6 on Linux; PowerShell scripts target Windows PowerShell 5.1.

The following 22 focused scripts passed after integration:

```text
windows/tests/test-odbc-core.R
windows/tests/test-odbc-runtime.R
windows/tests/test-odbc-probe.R
windows/tests/test-runtime-policy.R
windows/tests/test-db-diagnostics.R
windows/tests/test-sql-server-fetch.R
windows/tests/test-care-site-id-startup.R
windows/tests/test-sql-preparation-order.R
windows/tests/test-sql-progress.R
windows/tests/test-data-cache.R
windows/tests/test-yuhs.R
windows/tests/Test-OdbcProbe.ps1
windows/tests/Test-OdbcRunRouting.ps1
windows/tests/Test-ClinicalSqlWatchdog.ps1
windows/tests/Test-OdbcDiagnosticCollection.ps1
windows/tests/Test-ConnectionWatchdog.ps1
windows/tests/Test-RunDiagnostics.ps1
windows/tests/Test-SitePreparation.ps1
windows/tests/Test-MethodsSelection.ps1
windows/tests/Test-BaselineRouting.ps1
windows/tests/Test-Launcher.ps1
windows/odbc/test-install-packages.R
```

Coverage includes endpoint/TLS/backend routing; typed result iteration and
cleanup; integer64 boundary protection; positive native streaming batch sizes;
independent startup/SQL/disconnect deadlines; invalid or incomplete process
receipts; exit failures and post-check hangs; credential-safe diagnostic
classification; native/production probe gates; sequential and parallel worker
routing; local package installation order, version reuse, failure detection,
and stale overlay repair. Fake database APIs and owned local test processes
exercise failure branches; these are not live SQL Server tests.

All R/PowerShell files parse. `git diff --check` passed. `R CMD build
--no-build-vignettes --no-manual --no-resave-data` produced the source package.
The full OHDSI dependency stack was not installed in the development runtime,
so a full R CMD check or complete model run was not performed here.

Offline dependency ZIPs were inspected for Windows x64 R 4.6.1 metadata and
download hashes. Microsoft installers are pinned by source/version/hash;
their Authenticode signatures are checked by the installer on the Windows
target. Existing Cyclops pin remains
`taseong/Cyclops@a08a9a8317a8ded49db77f6ff0394ab918b02a94`.

Windows installation, the HIWARE interaction, live YUHS SQL Server execution,
and end-to-end clinical/model results remain unverified. CHECK_ODBC must pass
both native and production modes through normal R process exit on that host.
The probe checks transport and data types, not clinical cohort correctness.
