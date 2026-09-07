# FederatedPs

Small synthetic checks of fixed-input propensity score learning, site-local
OHDSI matching, and covariate balance. `preparePsData()` validates two sites and
constructs one sparse training matrix per site. `fitPs(method = "local")` and
`fitPs(method = "pooled")` use normal Cyclops fitting; `method = "simulation"`
jointly updates two Cyclops states in the same R process.

Supported model: CPU float64 unweighted binary logistic regression, one
unpenalized intercept, independent fixed-variance Laplace priors, and Lange
convergence. Feature order and scale divisors are supplied explicitly. Only
global zero columns are excluded before training; their IDs are retained in
`excludedIds`. Original covariates are kept for balance regardless of fitted
coefficients. IDs are exact integer-valued R numeric vectors, not `integer64`.

The synthetic `CohortMethodData` follows CohortMethod 6.0.3's
`simulateCohortMethodData()` construction: a real Andromeda object containing
`cohorts`, `covariates`, `covariateRef`, `analysisRef`, and a typed empty `outcomes`
table. It uses no clinical events. Population requires `rowId`, `treatment`, and
`personSeqId`; feature references require names and analysis IDs; analysis
references describe domain, binary status, and missing-as-zero semantics.
Close every site's object with `Andromeda::close()` after use.

## Pinned Cyclops patch

Base commit: `89dd48b18fcaa8cc4d88f235b1da38459ab912a3` (version 3.7.1).
`patches/cyclops-coordinate-descent.patch` contains all nine changed files,
including three new files. The A patch remains unchanged. The separate Lange
termination patch used by D is described below. Do not identify the required installation by version alone:
`fitPs(method = "simulation")` checks the five required exports and errors on an
unmodified installation. It never installs dependencies or falls back silently.

In an existing R/build environment, use a clean checkout at the exact commit,
install the reference first, then apply the patch and install to another library:

```sh
git -C /path/to/clean-Cyclops rev-parse HEAD
R CMD INSTALL --library=/path/to/reference-library /path/to/clean-Cyclops
git -C /path/to/clean-Cyclops apply --check /path/to/ps-model/patches/cyclops-coordinate-descent.patch
git -C /path/to/clean-Cyclops apply /path/to/ps-model/patches/cyclops-coordinate-descent.patch
R CMD INSTALL --library=/path/to/modified-library /path/to/clean-Cyclops
```

Keep these source checkouts and libraries outside this package. The preserved
patch was reapplied to a clean checkout and all nine resulting files compared
byte-for-byte. No index staging, commit, or upstream fork is required.

## Verification in the existing container

Executed in `feature-extraction-v2-rstudio` with R 4.6.1, Cyclops 3.7.1,
CohortMethod 6.0.3, Matrix 1.7.6, and Andromeda 1.2.1. No global library changes.
Container paths used below:

```sh
A=/tmp/cyclops-ccd-feasibility.p6a0pI
W=/tmp/federatedps-b1.rxeS6e
R_LIBS="$A/modified-library" R CMD INSTALL --library="$W/library" "$W/source"
```

Run the following in separate `Rscript --vanilla` processes inside that container.
The reference exchange contains only generated synthetic inputs and plain R
results, never native pointers.

```r
W <- "/tmp/federatedps-b1.rxeS6e"
A <- "/tmp/cyclops-ccd-feasibility.p6a0pI"
.libPaths(c(file.path(W, "library"), file.path(A, "reference-library"), .libPaths()))
library(FederatedPs)
stopifnot(find.package("Cyclops") == file.path(A, "reference-library/Cyclops"))
Sys.setenv(FEDERATEDPS_REFERENCE_OUTPUT = file.path(W, "reference.rds"))
source(file.path(W, "source/tests/testthat/test-federatedPs.R"))
```

```r
W <- "/tmp/federatedps-b1.rxeS6e"
A <- "/tmp/cyclops-ccd-feasibility.p6a0pI"
.libPaths(c(file.path(W, "library"), file.path(A, "modified-library"), .libPaths()))
library(FederatedPs)
stopifnot(find.package("Cyclops") == file.path(A, "modified-library/Cyclops"))
Sys.setenv(FEDERATEDPS_REFERENCE_INPUT = file.path(W, "reference.rds"))
testthat::test_file(file.path(W, "source/tests/testthat/test-federatedPs.R"),
                    reporter = "summary", stop_on_failure = TRUE)
```

The fixed test settings live in `tests/testthat/test-federatedPs.R`: seed,
site sizes, overlapping local row IDs, feature order, scales, prior, controls,
and 1:1 matching with caliper 0.2 on the standardized-logit scale. Numerical
comparison uses `abs(a-b) <= 1e-7 + 1e-7 * max(abs(a), abs(b))`; state agreement
and raw balance-mean checks use absolute/relative `1e-10`. Neither SMD < 0.1 nor
superiority over local-only fitting is a correctness criterion.

The A focused test remains in the Cyclops patch and is not duplicated here.
Its existing independent-reference test was also rerun. Running these package
tests without `FEDERATEDPS_REFERENCE_INPUT` skips only the separate-reference
check; it does not establish unmodified-build agreement.

Build and check, from the container working directory above:

```sh
cd "$W"
R CMD build --no-build-vignettes source
R_LIBS="$W/library:$A/modified-library" \
  FEDERATEDPS_REFERENCE_INPUT="$W/reference.rds" \
  R CMD check --no-manual --no-build-vignettes FederatedPs_0.0.1.tar.gz
tar -tzf FederatedPs_0.0.1.tar.gz
```

PDF manual compilation is excluded because this container has no `pdflatex`.
Its existing site configuration defaults `R_LIBS` to global libraries, so
`R_LIBS_USER` alone selected unmodified Cyclops in the first check (one error,
one warning). Set `R_LIBS` explicitly as above for installation/check; no global
configuration change is needed.

## C1: two DataSHIELD worker sessions

`fitPsDataShield(connections, inputSymbol, runId)` uses two active DSOpal
connections and existing server-local input symbols. It sends coordinate
statistics and updates through public DSI assign/aggregate APIs. Inputs, native
states, raw PS and matched populations remain on each worker. The integration
script has separate setup, training and evaluation processes; only setup and
the synthetic evaluator read pooled/reference data. `fitPs()` remains the B1
same-process interface.

The isolated test uses one Opal 5.7.6, two Rock 2.2.1/R 4.6.1 containers, and a
separate coordinator container. Release image digests are fixed in
`extras/datashield/compose.yaml` and `Dockerfile`. Tested client packages are
DSI 1.8.0, DSOpal 1.5.0 and opalr 3.6.1. Both Cyclops builds use the pinned
commit above, with the patch applied only to the modified build. The image
builds native packages from source; it does not copy the old RStudio library.
The initial dependency build (including DuckDB) took about 54 minutes; later
R-only changes reused the dependency cache.

Prepare an external build context containing exactly
`Cyclops-reference.tar.gz`, `Cyclops-patched.tar.gz` (each with a `Cyclops/`
top-level directory), and the `R CMD build` output renamed `FederatedPs.tar.gz`.
Create the Cyclops archives from the pinned commit and the preserved patch,
following the checks above. Build FederatedPs with the approved package files
in a temporary directory using the pinned Rock image's R, for example:

```sh
docker create --name c1-package-build --label org.federatedps.stage=C1 \
  --entrypoint sh obiba/rock:2.2.1-R4.6.1@sha256:16ddfcb9efeda78d9731c4252651345e2ac33bb681d5b7a15e11c6545da07939 \
  -c 'cd /tmp && R CMD build --no-build-vignettes /tmp/FederatedPs'
docker cp /path/to/temporary-package-source c1-package-build:/tmp/FederatedPs
docker start -a c1-package-build
docker cp c1-package-build:/tmp/FederatedPs_0.0.1.tar.gz /path/to/context/FederatedPs.tar.gz
docker rm -v c1-package-build
```

The temporary package source needs only `DESCRIPTION`, `NAMESPACE`,
`.Rbuildignore`, `README.md`, `R/`, `man/`, `tests/` and
`extras/TestDistributedPs.R`. Never copy the workspace, `.env`, credentials,
patch checkout, or installed libraries into it.

Use a new Compose project and a mode-0600 environment file outside the source
tree. Required keys are `C1_BUILD_CONTEXT`, `C1_DOCKERFILE` (absolute paths),
`C1_OPAL_PASSWORD`, `C1_ROCK_PASSWORD` and `C1_RESEARCH_PASSWORD`. Generate
independent temporary secrets; `secrets.token_urlsafe(21) + "aA7!"` in Python
gives a 32-character value satisfying the tested password policy. Longer
values can cause line wrapping in opalr's authentication header. Do not print
the environment file or use project DB credentials.

```sh
docker compose --env-file "$C1_ENV" -p "$C1_PROJECT" -f extras/datashield/compose.yaml build rock1
docker compose --env-file "$C1_ENV" -p "$C1_PROJECT" -f extras/datashield/compose.yaml --profile test up -d rock1 rock2 coordinator
# Start Opal after the Rock services have completed startup.
docker compose --env-file "$C1_ENV" -p "$C1_PROJECT" -f extras/datashield/compose.yaml up -d opal
```

There are no host ports or CDM mounts/networks. Rock's `R_LIBS_SITE` includes
`/opt/federatedps/library`; its session startup otherwise omits `R_LIBS`.
The reference library is `/opt/federatedps/reference-library`. Within the
coordinator, extract `/opt/federatedps/sources/FederatedPs.tar.gz` into
`/tmp/source` and create `/tmp/c1`. Execute these in separate R processes:

```sh
R_LIBS=/opt/federatedps/reference-library:/opt/federatedps/library \
  Rscript --vanilla /tmp/source/extras/TestDistributedPs.R reference /tmp/c1 /tmp/source
Rscript --vanilla /tmp/source/extras/TestDistributedPs.R setup /tmp/c1 /tmp/source
```

Copy only `/tmp/c1/site1.rds` to rock1 and `site2.rds` to rock2, each at
`/opt/federatedps/input/site.rds`. These are plain synthetic tables/settings,
not native pointers or Andromeda connections. Obtain the new test Opal's public
certificate inside the coordinator:

```sh
openssl s_client -connect opal:8443 -servername localhost </dev/null 2>/dev/null |
  openssl x509 -out /tmp/c1/opal-public.pem
Rscript --vanilla /tmp/source/extras/TestDistributedPs.R register /tmp/c1 /tmp/source
Rscript --vanilla /tmp/source/extras/TestDistributedPs.R probe /tmp/c1 /tmp/source
Rscript --vanilla /tmp/source/extras/TestDistributedPs.R train /tmp/c1 /tmp/source
Rscript --vanilla /tmp/source/extras/TestDistributedPs.R compare /tmp/c1 /tmp/source
Rscript --vanilla /tmp/source/extras/TestDistributedPs.R failures /tmp/c1 /tmp/source
Rscript --vanilla /tmp/source/extras/TestDistributedPs.R audit /tmp/c1 /tmp/source
```

TLS certificate/hostname checks stay enabled. The localhost certificate is
routed to the Opal service with the public `connect_to` option. Functions are
published from DESCRIPTION into restricted profiles; the parser is unchanged.
Coordinate positions resolve to fixed names on the worker because the parser
rejects parentheses in the `"(Intercept)"` string. Numeric requests use 17
decimal digits and binary R responses; opalr retries are disabled. Session
existence is checked with `opal.session_exists()`, since `dsHasSession()` only
checks whether the client holds an ID.

General package tests/check do not contact a server. In the isolated coordinator:

```sh
R CMD build --no-build-vignettes /tmp/source
R_LIBS=/opt/federatedps/library FEDERATEDPS_REFERENCE_INPUT=/tmp/c1/reference.rds \
  R CMD check --no-manual --no-build-vignettes FederatedPs_0.0.1.tar.gz
```

The real-server stages above are separate from this check. Logs and RDS result
summaries stay outside the source tree; HTTP request counts come from Opal's
audit log and exclude login/session-creation endpoints. Network bytes are not
measured. Preserve nonsecret summaries, then stop/remove only this test project:

```sh
docker compose --env-file "$C1_ENV" -p "$C1_PROJECT" -f extras/datashield/compose.yaml --profile test down --volumes
```

Delete the temporary credentials after teardown. Deployment files, patches,
credentials and archived responses are excluded from the built R package.

## C2: bounded sparse scale measurements

The existing C1 image `sha256:c4949e2c4b0438fc708b20aabb1009cac98d2f159d096cd4497fa3300953ba21`
was reused without rebuilding native code or dependencies. Recreate only the
isolated C1 Compose services, with fresh temporary credentials and
`up --no-build --pull never`. The fixed Opal digest can be pulled again if its
local reference is absent. Reproduce the C1 reference/setup/probe/train/compare
stages before starting C2. Production R code, public APIs and the Cyclops patch
are unchanged by C2.

`extras/TestDistributedPs.R` accepts an optional fourth argument of 100, 1000,
or 10000. Its C2 settings are fixed before execution: seed 20260907, n=3000
(1800/1200), binary density target 0.01, scale 1, variance 1, zero starting
coefficients and Lange tolerance 1e-12. It first generates all 10000 sparse
columns by binomial column counts and sampling distinct rows per column, then
labels from intercept -0.3 and coefficients (1.1, -0.9, 0.8, -0.7, 0.6) on the
first five columns. Nested inputs share the same people and labels. Global zero
filtering is the existing setup rule, not distributed preprocessing.

Within the reused coordinator, create `/tmp/c2` and generate the fixture once:

```sh
Rscript --vanilla /tmp/source/extras/TestDistributedPs.R scaleFixture /tmp/c2 /tmp/source
R_LIBS=/opt/federatedps/reference-library:/opt/federatedps/library \
  timeout --signal=TERM --kill-after=15s 600s Rscript --vanilla \
  /tmp/source/extras/TestDistributedPs.R reference /tmp/c2/p100 /tmp/source 100
timeout --signal=TERM --kill-after=15s 600s Rscript --vanilla \
  /tmp/source/extras/TestDistributedPs.R setup /tmp/c2/p100 /tmp/source 100
```

Copy that scenario's `site1.rds` and `site2.rds` to their respective workers at
the existing fixed input path; copy the current Opal public certificate into
the scenario directory. Run `train`, `compare` and `audit` with the same last
three arguments. Training reads only server symbols and aggregate metadata.
The original C2 evaluator used prediction at returned coefficients. The
follow-up below instead validates the live worker native cache against a
same-sweep oracle. No C2 matching is performed.

Executed S1 (p=100) converged in eight sweeps for reference, simulation and
remote fitting. Remote training took 78.567 seconds; objective and PS comparisons
passed the unchanged absolute/relative 1e-7 criterion, and coordinate traces
passed 1e-10. S2 (p=1000) reference/simulation converged in 28 sweeps. For S2,
repeat reference/setup with 1000 and run train with a 300-second outer timeout;
worker control limits the run to two sweeps. It completed 2002 updates in
164.883 seconds including initialization, then returned MAX_ITERATIONS.

The original C2 server wrapper marked this expected iteration-limit outcome as
failed and refused subsequent status queries. The coordinator also lost its
partial timing/coordinate result on that error. Therefore that run left S2
intermediate numerical agreement unverified and did not run S3. The
planned S3 cap is one sweep/1500 seconds; each local fit is capped at 600 seconds,
and accumulated model execution must remain within 3600 seconds. These are test
budgets, not performance acceptance thresholds or convergence guarantees.

`audit` records actual session-addressed HTTP counts and consecutive update-log
timestamp spacing. That spacing is distinct from the coordinator's measured
coordinate-cycle duration. Network bytes and Docker memory are unmeasured:
Docker returned invalid 0B counters. RSS samples are process snapshots, not peak
memory or R object sizes. `scaleSummary /tmp/c2 /tmp/source` writes the one
`scale-summary.csv`; optional `memory-samples.csv` supplies the raw RSS samples.
Copy the summary and minimal nonsecret logs to `output/c2`. Original C1 summaries
and its check log are preserved in `output/c1`; both paths are excluded from Git
and R package builds. Keep full synthetic inputs and native state out of output.
Use the existing package check command with `/tmp/c1/reference.rds`, then tear
down only the current Compose project and remove its temporary credentials.

## C2 follow-up: consistent iteration-limit results

`fitPsDataShield(connections, inputSymbol, runId, returnPartial = FALSE)` keeps
the default nonconvergence error. Explicit `returnPartial = TRUE` returns a
diagnostic result only when both workers stop at the same full sweep with
`MAX_ITERATIONS`, finite coefficients/objective, and matching update states.
`model$returnFlag` remains `MAX_ITERATIONS`, and `model$converged` is `FALSE`.
The existing `model$iterations`, `step`, `coordinates`, `sweepSeconds` and timing
fields retain the completed work. SUCCESS results keep their previous shape.
No partial result can resume or automatically enter matching; real errors
still terminate the run. Local and pooled fit nonconvergence rules are unchanged.

Reuse the C1 image and install only the current FederatedPs source archive into
`/opt/federatedps/library` in a new image layer. Set `C1_FEDERATEDPS_IMAGE` in the
external Compose environment to that new image tag. The default image remains
unchanged, as do the pinned Opal/Rock/Cyclops versions and restricted profiles.
Build and check with the commands above; do not rebuild the native libraries.

The existing script accepts `partial` as its fourth argument for a one-sweep
small-fixture contract test: run `reference`, `setup`, `train`, and `compare`
in a separate working directory, copying its two input files to their workers
after setup. It tests the strict default, explicit partial return, repeated
terminal queries, stale/wrong symbols and rejected post-limit updates. Run the
existing C1 `failures` stage on fresh test sessions as well.

Then use the unchanged `scaleFixture` generator and the existing C2 stages for
100, 1000, and 10000. S2 uses exactly two sweeps (300-second cap); S3 uses one
(1500-second cap), starting at zero in new runs. Setup reuses the pooled native
coordinate API as a same-sweep oracle. S3 skips full simulation convergence.
The worker evaluator reads the actual native prediction, checks it against
local sparse X times beta and the oracle, and returns error summaries only.
The cached linear predictor is checked through `qlogis()` of finite native PS;
the public accessor returns response-scale predictions. Terminal bounds are
the values already returned by the last complete sweep's native updates, not
a new native snapshot interface. No partial-fit matching is performed.

Final comparisons retain absolute/relative 1e-7, coordinate comparisons 1e-10;
summaries include the maximum error divided by its applicable tolerance.
End-of-run validation requests are separated from training requests/timing.
Preserve this run's `scale-summary.csv`, validation summaries and minimal logs
in ignored `output/c2-followup`; leave `output/c1` and `output/c2` unchanged.
The model-execution budget is 3600 seconds, excluding build/check/startup.

The follow-up completed S2's two sweeps/2002 cycles and S3's one sweep/10001
cycles as `MAX_ITERATIONS`, with all same-sweep checks passing. Training took
166.910 and 827.293 seconds respectively; the measured S3 sweep took 827.174
seconds (13.79 minutes). This is one measured sweep, not remote convergence or
CV validation. It used R-only image
`sha256:117eb8ec8219483d5cdacafa6033350419c1e0a89db4f59413b88f599b79f0e6`.
The pinned unmodified S3 pooled fit separately converged in 121 sweeps; the
remote run was not extended to that point. Existing output/c2 results remain
unchanged. New results are in `output/c2-followup`.

## D: training-only preprocessing and fixed-grid CV (remote API blocker)

`combinePsSummaries(summaries, minFraction)` combines only site training counts,
nonzero counts and maxima. It retains `count > 0 && count / N >= minFraction`
and divides by the common training maximum. It does not center, clip validation
values, detect duplicate features, or infer vocabulary/collection coverage.
The manual `preparePsData()` path keeps its existing behavior.

`fitPsDataShieldCv(connections, inputSymbol, runId, priorVariances = c(0.1, 1),
folds = 2L, minFraction = 0.05, seed = 20260907L, maxFitSeconds = 300)` reuses
the existing strict fixed-prior remote fit. Registered assign methods
`preparePsCvDS`, `applyPsPreprocessingDS` and `setPsPriorDS` retain local folds
and reuse transformed sparse input with fresh native states per candidate.
Aggregate methods `getPsPreprocessingDS` and `getPsValidationDS` disclose
training summaries or summed validation loss/count only. These research
disclosures require security review before sensitive-data use.

Automatic input requires finite nonnegative values and references declaring
`timeWindow`, `valueType` and `isCollected = TRUE`, in addition to the existing
missing-as-zero metadata. Rows are sorted by local rowId; comparator and then
target groups are independently permuted using the fixed seed and assigned
cyclically to folds. Validation-only features stay excluded, and validation
values above the training maximum remain above one after scaling. Each
candidate uses the same fold preprocessing. The score is total unpenalized
validation loss divided by total validation n; candidates within `1e-10` of
the minimum select the smaller variance. All fits must return SUCCESS. Final
preprocessing and refitting use all training rows, followed by site matching.
This is an explicitly defined fold-wise procedure, not Cyclops' internal CV.
FeatureExtraction 3.14.0 uses `floor(minFraction * N)` for its frequency cutoff;
its public maximum-scaling comparison is separately configured with
`minFraction = 0, normalize = TRUE, removeRedundancy = FALSE`.

The fixed D fixture has 120/96 rows and 12 candidate features. Its settings and
independent pooled/local oracle are in `test-preprocessing-cv.R`; the existing
driver adds `dReference`, `dSetup`, `dTrain`, and `dCompare`. In the existing
isolated image with `/tmp/source` and an empty `/tmp/d` directory:

```sh
R_LIBS=/opt/federatedps/corrected-reference-library:/opt/federatedps/library \
  Rscript --vanilla /tmp/source/extras/TestDistributedPs.R dReference /tmp/d /tmp/source
```

The original D attempt failed in the unmodified pinned Cyclops at
site1, fold 1, variance 0.1, training n=60/p=8: `POOR_BLR_STEP`, iteration 1.
The existing `performCheckConvergence()` branch assigns this status when the
first sweep's objective-change criterion is exactly zero, including Lange.
It is not MAX_ITERATIONS. No candidate was omitted and no successful D CV
result was returned. The fixture, tolerance, prior grid, iteration limit,
Cyclops source and preserved patch were not changed to bypass it.

That attempt did not reach real-worker D integration. Its failure/check logs
remain unchanged in `output/d`. The follow-up below uses a separate corrected
reference and records a different, real DataSHIELD API blocker.

### D follow-up: independent termination correction

`patches/cyclops-lange-initial-convergence.patch` changes only the first-sweep
special failure condition to exclude LANGE, and adds one public-fit native test.
The failing training input has 30 target/30 comparator rows, eight slopes and
explicit zero starts. Lambda is `sqrt(20)`; the largest absolute slope gradient
is 4 and the intercept gradient is zero. Independent initial/final KKT residuals
are zero under `1e-8 + 1e-8 * max(1, abs(g), lambda)`. Every coordinate increment,
native objective change and prediction-cache error is zero. This diagnostic
does not replace Lange stopping. GRADIENT's special branch/R recovery, other
termination types, update/prior/bounds/cache and actual failure checks remain.

Use separate checkouts at the pinned commit: **U** unchanged; **L** with the
termination patch only; **F** with A followed by the termination patch. U is
preserved and still returns POOR_BLR_STEP. L and F return SUCCESS at the verified
optimum. Both patches retain independent provenance (SHA-256):

```text
A e9fecf025158798352db88f150c8602762b625f5708e35080f7387c7c7ee15bd
L d580087e0cac376aa7c462601740dfb3867628b76ff5b885c8511ae7925cae20
```

```sh
git -C "$L_CHECKOUT" apply --check "$PS_SOURCE/patches/cyclops-lange-initial-convergence.patch"
git -C "$L_CHECKOUT" apply "$PS_SOURCE/patches/cyclops-lange-initial-convergence.patch"
git -C "$F_CHECKOUT" apply "$PS_SOURCE/patches/cyclops-coordinate-descent.patch"
git -C "$F_CHECKOUT" apply --check "$PS_SOURCE/patches/cyclops-lange-initial-convergence.patch"
git -C "$F_CHECKOUT" apply "$PS_SOURCE/patches/cyclops-lange-initial-convergence.patch"
```

Both clean-U and U+A application/content checks were executed, including the
new test. Archive L/F outside the project as `Cyclops-lange.tar.gz` and
`Cyclops-federated.tar.gz`, rooted at `Cyclops/` without Git. A new layer on
the existing D image `sha256:43967e124273973ddb8339485cfe561c56dfc0ee867b229ad620982be957a708`
copies these archives into `/opt/federatedps/sources` and runs:

```sh
mkdir -p /opt/federatedps/corrected-reference-library
R CMD INSTALL --library=/opt/federatedps/corrected-reference-library /opt/federatedps/sources/Cyclops-lange.tar.gz
R CMD INSTALL --library=/opt/federatedps/library /opt/federatedps/sources/Cyclops-federated.tar.gz
R CMD INSTALL --library=/opt/federatedps/library /opt/federatedps/sources/FederatedPs.tar.gz
```

The tested image is `sha256:83ed0d606943b72d7ca1d0fbf1d870e3250181b8d43b63d02fff93860ab996d1`.
It preserves U in `/opt/federatedps/reference-library`; L and F use the two
libraries above. Separate R processes ran the initial-convergence test in L/F,
the existing A public-fit reference in U/L, and the A coordinate test in F.
Two worker processes additionally ran the new native test, and their loaded
DLL paths/hashes match F. No dependency or Opal/Rock release changed.

The existing driver stages `convergenceInput`, `convergenceCheck` and
`convergenceCompare` reproduce the failed input and independent KKT diagnostics.
For `convergenceCheck`, set `CYCLOPS_LANGE_BUILD=U`, `L` or `F` and the matching
`R_LIBS`; `A` uses the prior D image before this correction. The comparison also
reads the A test's ordinary reference outputs `coordinate-U.rds` and
`coordinate-L.rds`. All three original SUCCESS fixtures have zero U-L errors.

The corrected independent D oracle completed pooled and both local-only CVs:
selected variances are 1, 1 and 0.1 respectively. FeatureExtraction 3.14.0's
configured maximum/scaling comparison had zero error. Then the real two-worker
C1 SUCCESS, MAX_ITERATIONS, duplicate/nonfinite-update and session-loss
regressions passed on F. `dSetup` reused the unchanged D fixture and settings.

Real `dTrain` stopped before its first fit: the restricted profile rejects
`c(...)` in `applyPsPreprocessingDS(...)` with
`No such DataSHIELD 'ASSIGN' method with name: c`. No extra function was
registered and no parser rule was weakened in that attempt.
`output/d-followup` preserves those native/reference summaries and the failed
remote execution. Its successful ordinary check is not evidence of remote CV.

### D integration: restricted preprocessing arguments

Reuse the L/F image above; this change does not rebuild it or modify production
R, native code, either Cyclops patch, dependencies or public APIs. With opalr
3.6.1, the existing driver's administrator-only `dRegister` stage calls
`dsadmin.set_method(opal, "c", func = "base::c", type = "assign", profile = profile)`
only for `c1-site1` and `c1-site2`. It checks existing mappings before registration
and refuses to overwrite a different one. Existing ASSIGN mappings and all
AGGREGATE mappings remain unchanged; `c` is not an aggregate method. The learner
does not register functions or use administrator credentials.

After creating the isolated C1 services and copying the current source and the
Opal public certificate as above, generate the independent L reference and
site-local plain synthetic inputs:

```sh
R_LIBS=/opt/federatedps/corrected-reference-library:/opt/federatedps/library \
  Rscript --vanilla /tmp/source/extras/TestDistributedPs.R dReference /tmp/d /tmp/source
R_LIBS=/opt/federatedps/library \
  Rscript --vanilla /tmp/source/extras/TestDistributedPs.R dSetup /tmp/d /tmp/source
```

Copy only each `site1.rds`/`site2.rds` to its corresponding Rock's fixed
`/opt/federatedps/input/site.rds`. Then, in separate coordinator R processes:

```sh
for stage in register dProbeBefore dRegister dProbe dTrain dCompare audit; do
  R_LIBS=/opt/federatedps/library \
    Rscript --vanilla /tmp/source/extras/TestDistributedPs.R "$stage" /tmp/d /tmp/source || break
done
```

`dProbeBefore` requires fresh profiles without `c` and reproduces the original
nested-call error in both sessions. After registration, `dProbe` checks the
actual fold/final masks and scales, singleton/nonadjacent vectors, float64
round trips, invalid and empty masks/scales, and rejection of unregistered
top-level/nested `abs` and aggregate `c`. D sends numeric positional vectors;
the receiver reconstructs scale names from the ordered integer-valued IDs.
Probe native states are initialized only, without fitting, and are separate
from the five D fits. The audit counts only D's own session requests.

The actual restricted two-worker run completed all four CV fits and the final
refit with SUCCESS in 108.736 seconds including preprocessing and validation.
The independent L and remote scores were 0.6677441116890556 (variance 0.1) and
0.6434768967423643 (variance 1), selecting 1. Counts, IDs, masks, maxima and scales
matched exactly. DSI returned integer counts while the sparse pooled oracle
used doubles; the evaluator checks exact numeric values and named order.
The final objective error was 2.84e-14 and live worker raw-PS error 7.22e-16,
within the unchanged absolute/relative 1e-7 limits. Sparse transformation
errors were at most 1.11e-16, within the separate 1e-12 limits.

All six site/method matching, balance and plotting paths executed. Matched pairs
were 41/39/39 at site1 and 35/31/31 at site2 for local/L-pooled/remote. Pooled
and remote pair identities differed with repeated PS and sub-1e-15 prediction
differences. At site2 their maximum post-match absolute SMDs were 0.46291005
and 0.37139068; neither pair identity nor SMD improvement is an accuracy gate.
No rounding, jitter, caliper change or candidate substitution was used.
`output/d-integration` preserves the preprocessing/CV/comparison CSVs, final
OHDSI plots and minimal registration, probe, provenance, execution/check logs.
The separate native states were initialized five times per site, once per D
fit, with 1,019 coordinate cycles and 3,304 actual session HTTP requests per
site, including 11 requests after training. Network bytes were not measured.

## E1: matching diagnosis and read-only cohort feasibility

`dMatching` reuses the archived full-precision D reference and aggregate remote
result, and verifies the current deterministic fixture, folds, rows and labels.
With identical L PS, both existing OHDSI object paths give identical member
pairs, selected membership and balance. A single final simulation replay
(no CV or remote fitting) reproduces the archived coefficients and maximum SMDs.
Site1 changes pairs only. At site2, one comparator is replaced; both changed
comparators have nearly equal nearest distances (gap <= 1e-12). Fixing members,
1:1 weights and original covariates gives exactly identical balance. The matcher
sorts raw PS and then uses standardized logits; no rounding/jitter is added.
The actual historical remote PS/membership was not saved: the replay supports
the numerical-sensitivity explanation but does not recover those identities.
The diagnostic ran in 11.326 seconds on the existing F image, with unchanged R
RNG state through matching. Counts below the balance sampling limit are not
sampled. CohortMethod 6.0.3 uses the two matched-group SDs for post-match SMD;
undefined SMDs remain undefined. Results are in `output/e1/matching-diagnostic.csv`.

```sh
R_LIBS=/opt/federatedps/library Rscript --vanilla \
  /tmp/source/extras/TestDistributedPs.R dMatching /tmp /tmp/source
```

The existing `feature-extraction-v2-rstudio` has DBI 1.3.0 and RPostgres 1.4.10.
These public APIs perform E1 queries; no new driver/dependency was installed.
The installed DatabaseConnector 7.2.0 currently lacks a PostgreSQL JDBC driver,
so this DBI connection does not establish a working FeatureExtraction connection.
Private existing PG environment variables are passed only to the R child process.
Database `ohdsi` (PostgreSQL 18.1) contains `mimiciv`, `synpuf23`, and a separate
`synpuf1k`; the loader's SynPUF23 corresponds to `synpuf23`, not `synpuf` or the
1k schema. Both selected schemas permit SELECT on the needed domains. The original E1
transactions verified read-only mode and a 180-second limit. The followup uses
the separately authorized temporary-workspace transaction described below.

`extras/CheckCohortFeasibility.R` has metadata, synthetic and aggregate stages.
Its single SQL file runs each site separately; patient rows remain in PostgreSQL.
The aggregate stage uses session-local temporary tables, never permanent cohorts. Metadata verified the same vocabulary (v5.0 27-AUG-25), RxNorm
20250602, standard ingredients atorvastatin 1545958 and simvastatin 1539403.
All standard ingredient ancestors plus valid drug-strength ingredients determine
single-ingredient definitions: 5,207 and 6,415 concepts, identical across sites.
These are vocabulary counts, not cohort sizes or extracted feature counts.
MIMIC records CDM 5.3.1; SynPUF23's CDM/ETL metadata fields are mostly missing.

The user-approved feasibility candidate is first-recorded eligible exposure,
one index/person, age >=65, excluding both drugs on the first eligible date
without selecting a later date. Eligible exposures require finite start/end
dates, end >= start, and agreement with any recorded timestamps. Fully recorded,
valid DOB uses calendar age; incomplete DOB uses the installed OHDSI year
subtraction convention, with an approximate 65-year boundary and no imputation.
A valid visit must end in [-90,-1]; this is not continuous 90-day observation
or a drug washout. Prior-observation and domain availability are separate
diagnostics. No outcome, later-switch exclusion or sampling is applied.

E1-followup preserves the cohort/date/age rules above. It replaces the
first-date-to-all-eligible-records join with per-person minima for both
ingredients and an explicit equal-date exclusion. Restricted exposures and
index/age/visit/final intermediates are reused in `pg_temp`, with unique keys
where appropriate and ANALYZE only on these temporary tables. Source tables
remain SELECT-only. Separate repeatable-read READ WRITE transactions allow
TEMP creation; each is rolled back and disconnected after its summaries.
Both sites' mandatory attrition is computed before the additional domain
queries. No source index, ANALYZE, permission or planner setting is changed.

The aggregate command now takes the previous nonpatient metadata directory
as its third argument. For a fresh run, create empty `sql`, `metadata`, and
`output` directories inside the existing analysis container's internal `/tmp`;
copy only the R/SQL files and E1's `product-definitions.csv` and
`vocabulary-metadata.csv`. Exact candidate IDs/definitions and vocabulary
versions are verified before reusing the original ingredient classification.
The execution command used for this followup was:

```sh
docker exec --env-file /workspace/he-cdm/ps-model/.env \
  feature-extraction-v2-rstudio Rscript --vanilla \
  /tmp/federatedps-e1-followup-ij7_96e0/CheckCohortFeasibility.R \
  /tmp/federatedps-e1-followup-ij7_96e0/output aggregate \
  /tmp/federatedps-e1-followup-ij7_96e0/metadata
```

Use a new empty output directory for a repetition. The script first checks
old/new SQL equivalence against fixed SELECT/VALUES cases (including full
index/treatment/eligibility correspondence), then performs the two sites'
large queries sequentially. Limits are 30 seconds for metadata/EXPLAIN,
600 seconds per materialization/aggregate, 5 seconds for locks and 45 minutes
for the run. EXPLAIN does not execute the query; full plans stay private.

`output/e1` retains the original two 180-second timeouts. Followup shared
results in `output/e1-followup` contain only steps, status, duration and
synthetic checks. Exact aggregate tables are withheld in their entirety,
including denominators, differences and ratios: the disclosure policy remains
unconfirmed. They are saved only inside the existing analysis container at
`/tmp/federatedps-e1-private/<run-id>/cohort-aggregates.rds`, under directories
0700 and a file 0600, after checking that the path is not a shared mount.
Do not copy or preview that file in shared output, logs, Git or a package.
This temporary internal handling is not an institutional privacy certification.
Both sites completed mandatory attrition, observation/baseline availability,
all three domain summaries and drug-type aggregation within the 45-minute
budget, without an aggregate timeout. Session rollback/disconnect verified
removal of the temporary objects. Fixed synthetic equivalence, R syntax,
package build and archive-exclusion checks passed; models were not rerun.
`completed` with `withheld_pending_policy`, `timeout` and `not_computed` are
distinct execution states; absent public counts do not mean zero or not run.

Next extraction requires an approved final protocol, a separate authorized
cohort/analysis schema and output location, and the PostgreSQL JDBC driver.
FeatureExtraction 3.14.0's `getDbCovariateData()` takes cohort-definition IDs,
subject/start/end fields and an explicit `rowIdField`; an analysis-local row ID
must map back to each site's one person/index, never across sites. Explicit
condition/drug/procedure settings, start=-90/end=-1 and study-drug exclusions
remain subject to domain-timing review. The referenced MIMIC ETL
[`lk_cond_diagnoses.sql`](https://github.com/OHDSI/MIMIC/blob/d209ed37bcc533a69923dfd413fb15d53a6dad58/etl/etl/lk_cond_diagnoses.sql)
dates billing diagnoses at admission, a potential index-episode leakage path;
this reference commit is not proven to be the deployed export's exact ETL.
The raw covariate/ref/analysis tables can reuse the existing sparse boundary,
but the real population adapter and outcome-free CohortMethod extraction are
not validated. `loadPsSyntheticDS()` and `preparePsCvDS()` explicitly require
synthetic input; real data must not be relabelled synthetic to pass these checks.
No real-data pooled environment or cross-site row transfer is
approved. D's minFraction/grid/folds remain synthetic test settings.

## Outside this stage

No CDM extraction, clinical outcomes, full FeatureExtraction preprocessing,
site effects, cross-site matching, HE, or high-dimensional
remote convergence validation. C1 verifies two real worker sessions on one host; it
does not establish hospital-network deployment or privacy guarantees. D adds
only the fixed small synthetic preprocessing/CV procedure described above.
The gradient and preprocessing-summary functions require separate security
review before sensitive-data use. The typed
synthetic object does not establish `getDbCohortMethodData()`, `getPsModel()`, or
`runCmAnalyses()` compatibility. Patch files, credentials, local instructions,
and archived responses are excluded from the built R package.


## Protected actual-CDM fixed-prior execution

The restrictions in the preceding E1 sections describe that earlier stage.
The subsequent authorization permits the protected actual-CDM execution below,
including a separate pooled evaluator; public disclosure remains withheld.

`extras/RunCdmPs.R` is the explicit research driver; database access is not part
of package checks. It uses `ohdsi.mimiciv` and `ohdsi.synpuf23`, with separate
`fps_mimiciv`/`fps_synpuf23` research tables. Source CDM/vocabulary objects remain
SELECT-only. The frozen E1 product definitions and unchanged
`extras/sql/CohortFeasibility.sql` determine the cohort. The full cohort and the
site-local analysis sample are retained separately. The sample cap is 1,500
per site, with proportional deterministic allocation and ordering by
`md5(subject_id || ':20260907')`; original identifiers stay character and map
to explicit local row IDs.

The driver uses FeatureExtraction 3.14.0 age/gender and binary condition, drug,
and procedure histories in [-90,-1] and [-30,-1]. A documented custom-builder
wrapper invokes the public default builder on connection-local views of
pre-filtered research records. These views represent events as points at the
original start date, so interval-overlap SQL cannot include records starting
outside the window. Condition/procedure require a valid linked visit ending
before index. Unlinked drug start records are allowed; linked drug records
require the same pre-index visit rule. Date/datetime disagreement is excluded.
Study-ingredient descendants, including combination products, are excluded
from drug predictors. These are record exclusions, not new cohort exclusions.
The original, unscaled extracted covariates are kept for balance.

FE NULL `missingMeansZero` metadata is preserved. The explicit collected binary
history contract supplies absent-event-as-zero semantics. Gender requires one
explicit known category for every analysis row; unknown gender is not imputed.
Whole-domain availability and the common dictionary are checked before sparse
construction. This does not prove complete source observation or vocabulary
harmonization in arbitrary CDMs.

The real-data settings are minFraction=0.001, variance=1, zero initial
coefficients, one unpenalized intercept, Lange tolerance=1e-12 and at most 500
sweeps. Local reference preprocessing uses only local rows. The independent L
pooled reference recomputes pooled preprocessing; F workers derive their common
specification from site summaries. Actual-data CV is not run. The earlier D
minFraction=0.05 and two-variance grid remain synthetic test settings.

`loadPsCdmDS()` is a registered ASSIGN function, disabled unless the server has
`FEDERATEDPS_DATA_MODE=cdm`. It accepts no path argument and reads only
`/opt/federatedps/input/cdm-site.rds`, requiring a 0700 directory, 0600 file and
matching worker identity. Each worker receives only its own input volume. The
coordinator has no source-data volume. A network-isolated evaluator has both
inputs solely for the authorized pooled reference. Files contain plain R data,
never an open Andromeda connection or native pointer.

Driver stages, executed inside their respective protected environments:

```sh
# Analysis container: existing connection variables supplied privately, not
# printed or embedded in scripts/images. code/metadata contains the frozen
# nonpatient product-definitions.csv and vocabulary-metadata.csv from E1.
Rscript --vanilla code/extras/RunCdmPs.R "$private_run" extract code
Rscript --vanilla code/extras/RunCdmPs.R "$private_run" verify code
# Isolated evaluator, L library selected explicitly by the reference stage:
Rscript --vanilla /opt/federatedps/code/extras/RunCdmPs.R /opt/federatedps/private/run reference /opt/federatedps/code
# Restricted two-worker session, F library; no raw data on coordinator:
Rscript --vanilla /opt/federatedps/code/extras/RunCdmPs.R /opt/federatedps/private/run train /opt/federatedps/code
# Evaluator: SUCCESS-only matching/balance and a private final report:
Rscript --vanilla /opt/federatedps/code/extras/RunCdmPs.R /opt/federatedps/private/run report /opt/federatedps/code
```

Use the existing `register` and `dRegister` steps of `TestDistributedPs.R` to
register FederatedPs and ASSIGN `c -> base::c` on the two restricted profiles.
Do not enable `c` as an aggregate method. Temporary bootstrap passwords must
meet Opal's complexity requirements. Keep them short enough that opalr 3.6.1's
base64 authorization header contains no line break (for example, 28 random
URL-safe characters plus `Aa1!`; never store the resulting secret in source).
Registration belongs to setup, not the learning function.

Reuse the verified U/L/F dependency image with the existing Dockerfile's
`package-update` target to install only the new FederatedPs archive. Pin the
actual image ID and verify its native DLL hashes; version 3.7.1 alone cannot
identify U/L/F. No native patch is changed by the actual-CDM driver.

Budgets: cohort/extraction two hours, ordinary DB statements 600 seconds
(necessary extraction stages up to 1,800), local/pooled fits one hour each,
one remote fit at most 36 hours, total model/validation at most 48 hours.
`returnPartial=TRUE` in the research driver retains a consistent iteration-limit
diagnostic; it does not make it SUCCESS or permit matching. A same-sweep L/F
partial comparison is distinct from a converged model comparison.

All actual cohort counts, feature dimensions, model values, error magnitudes,
CSV/RDS/PDF results and `final-report.md` remain in protected local paths or
private volumes. Only execution statuses/times are emitted. Exact disclosure
is withheld pending the institution's policy; no small-cell threshold is
invented. Gradients, preprocessing summaries and intermediate models are
visible within the approved coordinator protocol; this is not HE or a privacy
guarantee. SynPUF is synthetic claims data, not an observed second hospital.

Actual execution: both cohort/feature inputs and the independent local-only
fits with OHDSI matching/balance completed. The independent L pooled fit
returned MAX_ITERATIONS at the prescribed 500 sweeps. The user stopped the
actual two-worker fit before a terminal model was returned. Remote full
convergence, final PS comparison and remote matching are therefore incomplete;
training-only pooled/worker preprocessing checks passed. Private inputs and
completed results are preserved. The package check completed with Status OK.
