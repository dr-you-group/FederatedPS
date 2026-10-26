## Separate completed JDBC checks from JVM shutdown (2026-10-26)

The 19:42 KST independent-Java receipt contained all three ID checks and an
explicit Connection.close completion, followed by no native process exit for
195 seconds. This is evidence of successful bounded queries and a subsequent
shutdown failure in that execution; it does not resolve the earlier R/rJava
mid-call stalls. No clinical SQL, package runtime, driver, TLS policy or retry
policy changes are made in this diagnostic revision.

The JDBC launcher records checksComplete, processExited, normalExitObserved,
forcedTermination, outputDrained and the actual javaExecutable independently.
Completed checks followed by a deadline become shutdown-timeout, never PASS.
The Java source logs an explicit System.exit boundary. The no-DB lifecycle tool
compares normal main return and System.exit with the same default Temurin 17
selection, while preserving existing JVM/security settings.

Validation on Linux with Java 17 and PowerShell 7.4 (not the live Windows host):

- Actual Microsoft 7.4.1 loopback TDS: ID-only full/adaptive, Korean NVARCHAR
  and CP949 VARCHAR, synthetic text, terminal SQL error and missing response.
- Real PowerShell/base-R/private-input/Java pipeline: normal and synthetic
  success, SQL failure, and an injected shutdown hook stall. The last case
  completes JDBC checks, is killed at the external deadline, and reports
  shutdown-timeout/checksComplete=true/normalExitObserved=false. No secret or
  private configuration packet is present in the result logs.
- Real no-DB lifecycle launcher: normal return and System.exit(0) pass; a
  nonzero native exit after completed body/hooks fails; an injected non-daemon
  shutdown stall times out, and a hanging owned jcmd is bounded and cleaned up.
  Multiline inherited JVM-option echo values are absent from the packaged logs.
- PowerShell parsing and git diff whitespace checks pass. Native Windows 5.1,
  HIWARE and the user's JDK shutdown behavior require the target-host results.

## Study-first extraction revision 4 (2026-10-26)

Remove the per-site whole-CDM VISIT_OCCURRENCE membership aggregation. Resolve
study drug concepts first, find dated/site-linked exposure candidates, and
exclude people with ANY other positive care_site_id via NOT EXISTS. For default,
apply the identical first-arm/person-id interleaving cap before materializing
visits; retain all visits and drug history for selected persons. studySpecific
keeps its cap after eligibility. CohortMethod and feature criteria are unchanged.
Whole-CDM audit counts are explicitly NA; prepared-patient audit scope is recorded.
In-flight SQL is indeterminate in the UI, with completed-statement counts intact.

Validation in this environment (Linux, not live SQL Server):

- 49 old/new pipeline comparisons using parsed T-SQL adapted to DuckDB 1.4.3
  by sqlglot 28.3.0. Exact exposure rows, selected-person visits and drug history
  match. Includes two scenarios, capped/unlimited, 2,000 randomized additional
  persons, arm ties/crossovers, null dates, invalid/mismatched visits and positive
  site IDs outside 1/2/3. Index DDL omitted; no timing claim is made from DuckDB.
- Existing clinical fixture covers site separation, binary covariates, washout,
  age, observation periods, concurrent arms and acute-episode cutoff.
- SQLite membership test compares the candidate anti-join with original
  whole-CDM membership for exposed patients, including null/nonpositive sites.
- Actual SqlRender 1.19.7/CohortMethod 6.0.3 resources render 104 plans. Untouched
  eligibility, cap, cohort and covariate SQL matches the archived recipe.
- Production R extraction order (default/specific, capped/unlimited), runtime
  revision rejection, R parsing, SQL progress/error cleanup and pure-R updater.
- PowerShell monitor/site-state/ETA behavior and Fresh/method-routing regressions.

This eliminates confirmed unnecessary work; it does not establish whether the
user's live wait is a scan, lock, I/O, poor plan or driver/proxy stall. Candidate
search and exclusivity still require database work. Index metadata diagnostics
are provided without performance DMVs. No persistent CDM indexes, NOLOCK hints,
clinical criteria, Cyclops, TLS policy, or timeout/retry policy are changed.
Existing cache files remain, but extraction source changes invalidate old keys.

## SQL preparation revision 3 (2026-10-26)

The reported last event is a local SqlRender call after successful DB startup.
The previous startup watchdog did not cover it. Prepare and split all site SQL
before the first JDBC connection in sequential runs (before each worker's
connection in parallel runs). Reuse those immutable, settings-checked plans
through extraction. Use one direct JDBC executeLargeUpdate per prepared
statement, the original final commit, and DatabaseConnector DBI fetch batches
and numeric conversion without its extra SqlRender wrappers. No retries.

The optional progress observer is separate from a 60-second PowerShell local
preparation watchdog. Preserve per-site state, partial-snapshot continuity,
prepared SQL and timeout evidence; the owner captures threads and stops its
workers. Fresh preflight uses the same full preparation function. The installed
sql-plan-3 revision is required, even when the package version is still 0.0.10.

Validated with Linux R 4.3.3, OpenJDK 17 and PowerShell 7.4.6:

- Actual bundled SqlRender 1.19.7 and CohortMethod 6.0.3 SQL: all generated SQL
  and split statements match the archived 3c215a2 recipe in 104 combinations
  (13 studies, 2 scenarios, 2 schemas, unlimited/capped, numeric site IDs).
- Settings mismatch rejection; preparation before connect; local preparation
  failure causes no DB call; all sequential sites get their own cap/plan.
- Streaming batch sizes, typed empty tables, NULL rows, single-fetch queries,
  resource cleanup and original errors; statement execution and final commit.
- Actual pinned JDBC 9.2.0 + production R against a loopback TDS fixture: SELECT
  probe then a prepared statement exactly once; 64-bit affected row count.
- Independent SQL preparation deadlines before DB markers and after DB ready,
  completed/partial/foreign-PID states; real hung child cleanup with queued
  sites cancelled; existing sequential/parallel and all method routes.
- R/PowerShell parsing, SSL-off preservation, Fresh RUN defaults and updater gates.

This does not establish the JNI/JVM root cause on the user's Windows host and
is not a live Windows/HIWARE/YUHS integration test. It removes the reported
post-connection rendering path and bounds local preparation. No clinical SQL
criteria, Cyclops, installer or TLS policy changes. Completed cache files are
retained, but changed source fingerprints can prevent reuse. SitePartition's
actual first aggregation still scans all positive-site visits before the
patient cap; this patch does not claim to optimize that SQL Server operation.

## JDBC probe revision 2 (2026-10-26)

The initial SELECT used Statement.setMaxRows(2). In the pinned Microsoft JDBC
9.2.0 driver this sends a separate SET ROWCOUNT 2 connection command before the
SELECT; that command does not use the statement query timer. The small-query
network timeout and the outer startup watchdog already existed, but the hidden
command was unnecessary. Remove it and use TOP (2) on CARE_SITE, retaining
one-row/duplicate validation. Start the JDBC connection with a bounded socket
policy and switch to the clinical socket deadline only after successful probes.

The first probe failure is preserved without reconnect/retry. The supervisor
records phase elapsed/deadline independently of the optional progress observer
and bounds each startup call in addition to the existing per-site total limit.
A package runtime revision check rejects a stale installed 0.0.10 package; the
fresh bundle includes 10_UPDATE_PACKAGE.ps1 to install the changed R code.

Validated with Linux R 4.3.3, OpenJDK 17 and PowerShell 7.4.6:

- JDBC call sequence, fetch/NULL/duplicate bounds, failure cleanup, startup and
  clinical socket deadlines, TLS preservation, no retry and stale revision rejection.
- Per-call and total watchdog clocks, partial phase reads, independent site IDs,
  real owned-process cleanup, sequential/parallel scheduling and method routing.
- The actual pinned JDBC 9.2.0 driver against a local TDS fixture that withholds
  replies to SET ROWCOUNT: the old setting sends only SET ROWCOUNT 2 and fails;
  the corrected sequence sends SELECT 1 directly and reads its result.
- Fresh RUN option forwarding, installation order and diagnostic allowlists.

This is NOT a Windows/HIWARE/live YUHS SQL Server integration test. Without the
new target-host trace, the hidden command is a confirmed code-path issue and
reproduction mechanism, not a confirmed diagnosis of the user's live stall.
Earlier post-connection SQL rendering stalls remain unverified. Existing cache
files are preserved; source changes may invalidate their extraction fingerprints.
Clinical extraction SQL (apart from bounding CARE_SITE), cohort criteria, models,
Cyclops provenance and runtime installers are unchanged.

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

## 2026-10-26 JDBC probe revision 3

Bounded startup statements now use direct/full buffering, consume EOF and terminal results before cleanup, identify ResultSet vs Statement close, and persist the first JDBC failure before cleanup. Bulk fetching remains adaptive. RUN accepts per-site PatientLimits and defaults to 2/2/2 for the requested smoke run.

Validation: production R/rJava against the pinned Microsoft 9.2.0 JAR and a loopback TDS fault server (no clinical DB): 0/1/2 rows including Unicode and NULL, split response packets, late SQL error, missing terminal response. Legacy swallowed late-error behavior reproduced; revised code rejects it. Subsequent statements retain adaptive buffering; no hidden SET ROWCOUNT or cursor RPC sent. Unit fixtures cover resource cleanup, error precedence, deadline/TLS policy, runtime revision gates and diagnostic export. Windows PowerShell scripts parsed with PowerShell 7.4 and launcher/monitor regressions exercised on Linux. Live Windows/HIWARE/YUHS execution remains unverified.

To reproduce the wire test, set `FPS_TEST_R` to the R executable (accepts --file) and `FPS_TEST_JDBC` to the pinned mssql-jdbc-9.2.0.jre8.jar, configure R/rJava, then run `python3 windows/tests/test-jdbc-probe-response-wire.py` from the repository. The server binds only 127.0.0.1; it uses synthetic results and fixture credentials.


Fresh integrity policy now reports local script/package-source edits instead of treating them as damaged installation payloads. `00_VERIFY.ps1 -StrictSource` retains pristine-source checks. Immutable installers, dependency archives/locks, runtime-lock, provenance and git bundle still fail on mismatches. RUN -UpdatePackage applies package edits before preflight/analysis and stops if update fails. PowerShell fixtures cover local R/SQL/RUN edits and deletion, unchanged manifest, immutable tampering, required files, unsafe paths and update-order/failure gates.


## Overwrite update / automatic package reinstall

Apply-FreshPatch.ps1 is distributed as APPLY_FIX.ps1. It overwrites supplied release files, including locally edited RUN/R/SQL files, without comparing existing file hashes, base-release fingerprints or old manifests. It backs up old files and invokes Update-FederatedPs.ps1 directly to reinstall the pure-R package. 10_UPDATE_PACKAGE no longer calls Test-FreshManifest. Local DB settings and analysis-data paths remain outside patch payloads.

PowerShell filesystem fixtures exercised arbitrary edits, an invalid old manifest and deliberately wrong checksum fields (accepted), repeat overwrite, automatic installer invocation, installer failure propagation, missing payload refusal before writes, mid-copy rollback, and path/data boundaries. Fresh launcher regressions verify no bundle-integrity call from package updates. Actual Windows R installation and HIWARE execution remain environment-side validation.

## Renviron JDBC selection (jdbc-probe-4, 2026-10-26)

- `test-renviron-jdbc.R`: Renviron overrides the PowerShell fallback; explicit JAR,
  direct folder and conventional root/sqlserver layout; missing/ambiguous paths;
  relative and Unicode/space-containing paths; changed setting requires a new JVM.
- `test-jdbc-driver-load.R`: actual Microsoft 7.4.1 and 9.2 JARs, each in a fresh
  R/rJava/JVM process. The selected code-source path is retained when the other
  JAR is later added. Switching an already loaded driver is rejected with a
  restart instruction, rather than silently using the previous class.
- Actual 7.4.1 loopback TDS probes: 0/1/2 rows, Korean text, NULL, split packets,
  trailing SQL error and missing terminal response. No hidden SET ROWCOUNT.
  No reproduced normal-response getString hang in this controlled fixture.
- PowerShell isolated driver installation/replacement test, overwrite updater
  regression and Fresh bundle routing checks pass. Existing custom configuration
  and results are not part of the patch payload. No old-source hash gate added.
- Validation runtime: Linux R 4.3.3 / rJava 1.0.11 / Java 17. This does not certify
  the Windows R 4.6.1 / HIWARE / actual YUHS SQL Server combination. The previous
  code's fixed-driver/path behavior is verified; a JDBC 9.2 defect is not proven
  by the user's last-phase watchdog message alone.
