## 0.0.10 preprocessing-first launcher hotfix (2026-10-26)

Default ExtractionWorkers is 1 again. The existing single R baseline worker prepares
all configured sites in order, validates all designs, and only then fits selected
models, matching the 0.0.8 execution order. Explicit 2/3 still select the prior parallel path.
No new startup recovery/retry scheduler is included. R package sources, SQL, DESCRIPTION
and all R runtime files remain byte-identical to b245ded; completed 0.0.10 cache keys
are preserved. The 180-second startup guard remains scoped to each site's actual DB start.

PowerShell checks cover default/explicit routing, all seven method selections,
completion barriers, monitor behavior and startup-clock isolation. Update tests
check apply/reapply, modified-file and tamper rejection, rollback, configuration
preservation and the bundle wrapper default. Actual Windows/HIWARE/SQL Server
integration and the cause of the reported startup delay remain unverified.

## 0.0.10 bounded parallel extraction and DB startup watchdog

Validated on 2026-10-26 with Linux R 4.3.3 and PowerShell 7.4.6:

- Default extraction concurrency 3; explicit 1/2/3 and configured-site count cap.
  Independent R/JDBC workers, same site limits, model barrier, exact checkpoint generation.
- `Test-SitePreparation.ps1` uses real child processes to check overlap at 1/2/3,
  early and late nonzero exits, invalid/missing/stale receipts, normal-exit gating,
  whole-run/shutdown timeouts, a hung DB startup, and owned-process cleanup.
- `Test-ConnectionWatchdog.ps1` checks the independent 180s startup deadline,
  run/PID/site identity, sequential/parallel roles, optional incomplete phase files,
  and exempting long clinical queries after validated startup. No progress monitor is required.
- `test-runtime-policy.R` checks immutable startup/ready markers and a clock that does
  not restart on a reconnect or a late disconnect. Existing TLS settings are preserved.
- `test-db-diagnostics.R` checks JDBC substep events through query/fetch/cleanup,
  scoped query/network timeout restoration, original error propagation and no row data in phase logs.
- `test-data-cache.R` checks pinned prepared generations, missing/tampered/foreign
  receipts, cache integrity and cache reuse across worker-count changes.
- Routing tests cover all seven method selections and prohibit model execution
  before successful preparation. Site monitor and read-only watcher tests cover parallel site roles.

No actual Windows/HIWARE/SQL Server or native Cyclops integration ran here. The
watchdog prevents an unbounded initial R/JDBC wait; it does not repair or diagnose
an unavailable proxy/DB without target-host logs. Clinical SQL/eligibility and
Cyclops versions are unchanged. Real speedup and peak memory remain unmeasured.
Version/source fingerprints intentionally invalidate 0.0.9-and-earlier extraction caches.

## 0.0.9 SQL progress, per-site status and sequential extraction

Validated on 2026-10-26 with Linux R 4.3.3 and PowerShell 7.4.6:

- `test-sql-progress.R`: before-send SQL files/events, statement order and counters,
  row-count bounds, one final commit callback, failed statement/commit propagation,
  matched historical timing estimates and independent site snapshots.
- `Test-SqlSiteMonitor.ps1`: numeric site IDs, queued/data-ready/fitting state,
  live operation elapsed time, no fabricated cold-start/overdue ETA, partial writes,
  and read-only attachment to selected-method runs.
- `test-site-partition.py`: old COUNT DISTINCT vs new MIN/MAX semantics on adversarial
  and randomized visits including null/nonpositive/unconfigured site IDs. Compare exact
  exclusive persons, required visit columns and whole-CDM multisite count using SQLite
  adaptations of the template. This is not a SQL Server performance benchmark.
- Existing patient-limit, cache, baseline, progress, DB diagnostics and launcher tests.

The SQL helper follows the SQL Server non-batched DatabaseConnector execution path:
SqlRender splitting, DBI execution in the original order, and a single final JDBC
commit when auto-commit is disabled. No per-statement executeSql commits or SQL retries.
Actual JDBC transaction behavior, SQL Server execution plans, Windows Server R 4.6.1,
HIWARE, Andromeda and native Cyclops end-to-end still require target-host validation.
No real YUHS speedup factor has been measured. Site extraction is sequential, with
numeric site IDs sorted by default and an explicit -Sites order respected.

## 0.0.8 method selection and extraction checkpoints

New base-R checks: `windows/tests/test-baseline-models.R`, `test-data-cache.R`.
New PowerShell checks: `Test-MethodsSelection.ps1`, `Test-BaselineRouting.ps1`.
These validate all seven selections, bounded candidate sampling, shared-row feature alignment,
patient disjointness, coefficient/prediction checks, completed-cache identity/integrity,
partial-write exclusion, and failure gating. Process and native model boundaries in routing
tests are stubbed. SQL Server LimitPatients.sql has structural checks and portable CTE semantics exercised in
SQLite (`test-patient-limit-sql.py`), not a live SQL Server test.
Native Cyclops/Windows/HIWARE integration remains a target-host test; see METHODS_KO.md.

# Validation of native Windows entry points

Validation performed on 2026-10-24:

- All PowerShell scripts parse using PowerShell 7.4.6 on Linux. Scripts target
  Windows PowerShell 5.1 and avoid PowerShell 7-only process/environment APIs.
- `windows/tests/Test-Launcher.ps1` passes with real child processes: names,
  arguments with spaces/quotes/trailing backslashes, nonzero exit propagation,
  cleanup of launched workers, and wall-clock timeout.
- All repository R files (107, excluding local payload/build folders) parse using R 4.3.3 on Linux.
- `windows/tests/test-validation.R` passes: run/site identifiers, block packet
  dimensions/order, design input dimensions, missing credential isolation,
  result agreement, and invalidation of an earlier success marker.
- The exact Cyclops source archive in `runtime-lock.json` was downloaded,
  SHA-256 checked, and checked for ZIP CRC errors. `Prepare-Offline.ps1` accepts
  that cached archive and verifies its expected source root.
- `git diff --check` passes.

YUHS care-site change:

- `windows/tests/test-yuhs.R` passes with base R: schema/ID validation, distinct
  institution mapping, SQL Server settings, credential isolation, all study
  feature definitions, restoring PERSON_ID by rowId after CohortMethod drops
  it, cross-institution overlap rejection, and stale-success removal.
- `tests/test_care_site_sql.py` executes the SQL Server templates after parsing
  T-SQL with sqlglot and translating to DuckDB. Synthetic fixtures cover all
  three institutions, visits to an additional institution, cross-site patients,
  NULL/unknown/wrong-person visit links, duplicate binary records, excluded
  treatment features, observation/age/washout/indication restrictions, same-day
  opposite arms, and an acute episode beginning on index with a preceding ER
  visit. It uses the clinical SQL generated by the actual R code. No index DDL
  or upstream CohortMethod cohort SQL is executed in this test.
- The OHDSI SQL Server JDBC archive and its JAR were downloaded and SHA-256/ZIP
  integrity checked; the updated online preparer accepts both cached archives.

The SQL test verifies relational logic through translation, not SQL Server
driver/engine compatibility. The runtime extraction uses native T-SQL, not
DuckDB/Python. YUHS source tables and credentials were not accessed. Clinical
records in the test are invented and no real server address is committed.

Not executed in this development environment: Windows R 4.6.1/Rtools45
compilation or installation, RStudio GUI, the complete numerical synthetic
federation, the existing dependency-heavy testthat suite, and CDM database
extraction (including YUHS). No claim of an end-to-end Windows pass is made here.

Target-host acceptance commands (run from the source root after bringing in the
payload; close R/RStudio before installation):

```powershell
.\windows\Install-Offline.ps1
.\windows\tests\Test-Launcher.ps1
.\windows\Run-FederatedPS.ps1 -Mode Synthetic
.\windows\Run-FederatedPS.ps1 -Mode Synthetic -BlockSize 4 -Alpha 0.5
```

Only after both synthetic runs finish with `SUCCESS.txt`, configure
`windows/config/yuhs.Renviron` and run Database mode as described in `README_KO.md`.
Confirm `careSite.csv` matches 1/2/3 and review partition/linkage/attrition CSVs.
All three sites need both treatment arms; `SUCCESS.txt` also requires disjoint
PERSON_IDs and matching model coefficients. These runs do not establish clinical
validity of a preset or eliminate the selection effect of excluding multisite patients.

Synthetic YUHS sample update (2026-10-25):

- `windows/tests/test-synthetic-yuhs.R` validates the ten packaged CSVs against
  the deterministic generator, 120 people per site, disjoint IDs, both arms,
  binary deduplication, bad/missing/wrong-person visit links, window filtering,
  exclusion after an added fourth-site visit, RNG preservation and sample-only
  parameter restrictions. It uses base R and no database.
- `windows/tests/Test-YUHS-Routing.ps1` executes the actual launchers with
  isolated runtime/process stubs: omitted Test and explicit Test=true choose
  SyntheticCDM without a DB config (even with an invalid config present);
  Test=false requires the real config and never falls back to the sample.
- Sample preparation occurs in R, not production T-SQL. The normal population,
  fitPs and aggregator paths are selected for SyntheticCDM. It checks pooled
  prediction agreement rather than pooled coefficient uniqueness because age
  and gender indicators contain redundant columns.
- `Test-SyntheticYuhsRuntime.R` is an additional target-host integration check
  of the installed Andromeda/CohortMethod sample and forbidden DB calls.
  The full Windows numerical acceptance runs remain necessary:

```powershell
.\windows\Install-Offline.ps1
.\windows\Run-RScript.ps1 -Script windows\tests\Test-SyntheticYuhsRuntime.R
.\windows\Run-YUHS.ps1 -Test $true
.\windows\Run-YUHS.ps1 -Test $true -BlockSize 4 -Alpha 0.5
```

No real YUHS DB, HIWARE session or credentials were used during development.

Windows PowerShell 5.1 exit-code hotfix (2026-10-25):

- User-provided target-host output showed both the launcher roundtrip test and
  an aggregator reported `failed (exit )` despite passing R/runtime preflight.
  The old Start-Process/redirected-stream path can lose the native process
  handle on Windows PowerShell 5.1 (PowerShell/PowerShell issue #5421).
- Start workers using System.Diagnostics.Process directly; retain its original
  handle, drain stdout/stderr concurrently through .NET tasks, and flush logs
  before interpreting the actual exit code. Missing codes remain failures
  with an explicit indeterminate-status message; they are never coerced to 0.
- Test-Launcher now covers children that already exited before waiting, exact
  exit codes 0/7/23, an intentionally missing code, and 256 KiB on each output
  pipe, in addition to argument quoting, timeout and owned-process cleanup.
- Executed these child-process tests on Linux PowerShell 7.4.6; Windows
  PowerShell 5.1 acceptance and the user's R role stderr remain unobserved.
  The screenshot alone does not establish that the R aggregator succeeded.
- This is a launcher-only hotfix. FederatedPs remains 0.0.5 and no R package
  or dependency reinstallation is needed when updating the previous bundle.

Log-close follow-up (2026-10-25): the first exit-code hotfix left completed
log FileStreams open until Stop-FederatedWorkers. On Windows, ReadAllText's
FileShare.Read conflicts with that existing write handle even if the writer
itself permits readers. Wait-FederatedWorkers now flushes AND disposes both
writers before reporting completion or a nonzero exit. Test-Launcher asserts
that both streams have CanWrite=false before reading the large logs, so the
lifecycle regression is detectable on Linux as well. Target Windows execution
still needs verification; no R package reinstall is required.

RStudio startup / real YUHS entry-point follow-up (2026-10-25):

- A target-host screenshot showed an unqualified `getFromNamespace` call failed
  in the startup profile, before utils was attached. `fp_verify_runtime` now
  uses `utils::getFromNamespace`; all other checks remain in place. Reproduced
  the lookup failure and confirmed qualified access with R 4.3.3 on Linux and
  R_DEFAULT_PACKAGES=NULL. This is a namespace/startup check, not a test of the
  installed Windows packages or RStudio GUI.
- The same screenshot ran `extras/ConnectionDetails.R` without a legacy site
  environment, so it tried to read `.Renviron.` before any DB connection. These
  PostgreSQL examples now give an explicit Windows/YUHS entry-point message.
  Checked both early guards without DatabaseConnector or any DB credentials;
  the affected R source parses on R 4.3.3.
- `Test-YUHS-Routing.ps1` additionally checks that explicit Test=false plus a
  configuration file selects Database/YUHS with test=false and four workers.
  The complete routing suite passes on Linux PowerShell 7.4.6 with the R/DB
  boundary stubbed. Test=true continues to ignore DB settings.
- Documented the PowerShell Terminal commands for RStudio and the distinct
  repository/bundle roots. HIWARE login alone does not populate the JDBC
  settings. Actual YUHS connectivity, SQL execution and Windows acceptance
  remain to be verified on the target host. No package reinstall is required.

Live progress update, FederatedPs 0.0.6 (2026-10-25):

- Optional process-local R observers report connection/extraction/model stages;
  observer errors disable telemetry without changing fit results. No model wire
  payload, protocol, cohort SQL, convergence rule or input definition changed.
- Base-R test-progress.R checks partial final coordinate blocks, sweep reset,
  per-sweep ETA math, unknown SQL/convergence duration and observer isolation.
- Test-Monitor.ps1 uses real child processes and live shared log files: short
  lines are visible BEFORE exit, split UTF-8 and partial JSON survive incremental
  reads, monitoring preserves exit 7, and the watcher leaves run files unchanged.
  CPU/start time may be unavailable on the Linux harness and remain unknown.
- The full launcher regression suite and updated routing fixtures run on Linux
  PowerShell 7.4.6. PowerShell parse checks and R 4.3.3 parse/base tests are used.
  The routing fixtures mock database execution; they do not demonstrate a YUHS
  connection. Native Windows 5.1/RStudio, installed OHDSI numerical execution
  and real YUHS SQL timing/ETA accuracy still require target-host acceptance.
- Stage percentages are completed extraction milestones, not time-weighted SQL
  progress. Coordinate ETA covers only the current sweep; overall ETA remains
  unknown. A live PID or quiet log does not prove SQL is advancing or deadlocked.
