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
including three new files. This is the A patch, preserved without further C++
changes. Do not identify the required installation by version alone:
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

## Outside this stage

No CDM extraction, clinical outcomes, FeatureExtraction preprocessing, global
normalization/CV, site effects, cross-site matching, DataSHIELD, remote workers,
network execution, HE, or large-scale performance validation. The typed
synthetic object does not establish `getDbCohortMethodData()`, `getPsModel()`, or
`runCmAnalyses()` compatibility. Patch files, credentials, local instructions,
and archived responses are excluded from the built R package.
