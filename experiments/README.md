# Proximal block CCD experiments

Code for the proximal block coordinate descent (block CCD) variant of the federated
propensity-score fit and for the experiments run with it. The package changes on this
branch are the block packet layout (`R/Pda.R`, `R/BlockDesign.R`, protocol `fedps/2-block`);
the algorithm itself is in the Cyclops fork pinned in `DESCRIPTION`
(`taseong/Cyclops@snu_proximal_ccd`).

Only code is included. Designs, propensity scores and results are not, and have to be
regenerated from an OMOP CDM.

## Layout

| Directory | Contents |
|---|---|
| `common/` | `config.R` / `env.sh` (paths), `kit.R` (Cyclops runs, matching, SMD), `kitcv.R` (CV-tuned prior), `balrct.R` (balance with a randomisation reference), `dsl.R` (data-shared lasso) |
| `validation/` | correctness tests of the block CCD and of the packet layout, and the multi-process federation driver `run_fed.sh` |
| `phases/` | statin study: balance, P / alpha sensitivity, non-IID partitions, CKKS aggregation, network latency, Cox analysis |
| `statin3/` | statin study on MIMIC-IV, SynPUF and EHRSHOT: site-local vs global models, cross-fitting, noise floor, bias |
| `studies/` | twelve benchmark comparisons on MIMIC-IV and SynPUF (see below) |

## Environment

| Component | Version used |
|---|---|
| R | 4.6.1 (`rocker/rstudio:4.6.1`, see `DockerImage/Dockerfile`) |
| Cyclops | 3.7.1, `taseong/Cyclops@snu_proximal_ccd` (`dr-you-group/Cyclops@1c265564` plus one commit), installed through `Remotes` in `DESCRIPTION` |
| CohortMethod / FeatureExtraction | 6.0.3 / 3.14.0 |
| Other R packages | `Matrix`, `survival`, `pda` (>= 1.3.0), `dplyr`, `ggplot2` (phase 1), `reticulate` (phase 4) |
| Python (phase 4 only) | Python 3 with `numpy` and `tenseal` |
| Database | PostgreSQL with OMOP CDM schemas `mimiciv` and `synpuf` (and EHRSHOT for `statin3/`) |

The block CCD needs that Cyclops build: other builds do not accept `blockSize` in
`createControl()`.

## Setup

Install the Cyclops fork, then the package:

```r
remotes::install_github("taseong/Cyclops@snu_proximal_ccd")
remotes::install_github("taseong/FederatedPS@snu_proximal_ccd")   # or remotes::install_local(".")
```

An existing Cyclops 3.7.1 counts as up to date, so the pin in `DESCRIPTION` alone does not
replace it. The Docker image in `DockerImage/` installs the pinned Cyclops directly. Then, from
the repository root:

```sh
export FP_DATA=$PWD/data            # inputs: design/, statin/, synpuf_state.csv
export FP_OUT=$PWD/data/out         # results (default: $FP_DATA/out)
export JOBS=8                       # parallel jobs for the runners
```

All scripts are run from the repository root. `FP_LIB` prepends a library path if the packages
are installed outside the default library, `FP_EXP` (default `experiments`) points to this
directory, `RSCRIPT` (default `Rscript`) is the R front end used by the shell runners, and
`STUDIES` restricts the runners to a subset, e.g. `STUDIES="ppi opioid"`.

To use the block CCD in `fitPs()` or `fitPsDesign()`, pass the block settings in the control,
identically at every hospital:

```r
control <- Cyclops::createControl(convergenceType = "lange", blockSize = 50, alpha = 0.5)
```

`blockSize = 1, alpha = 1` is the original exact CCD.

## Data

**Benchmark studies** (`studies/`). The twelve comparisons are the presets of
`getStudySettings()`; `studies/data/extract.R` stores each design as sparse triplets in
`$FP_DATA/design/<study>__<schema>.rds`.

```sh
export FP_DB_SERVER=host/database FP_DB_PORT=5432 FP_DB_USER=ohdsi_reader PGPASSWORD=...
experiments/studies/data/run_extract.sh            # all studies, or pass study names
```

The three-site experiments split SynPUF by state and need `$FP_DATA/synpuf_state.csv`
(person_id, state; no header), produced by `studies/data/synpuf_state.sql`.

**Statin study** (`phases/`, `statin3/`). At each site, with that site's connection settings
(`extras/ConnectionDetails.R`, `FEDERATEDPS_SITE`):

```sh
Rscript experiments/statin3/data/export_design.R     # $FP_DATA/statin/<site>/design.rds, population.rds
```

then, once the MIMIC and SynPUF designs are in place,

```sh
Rscript experiments/statin3/data/exact_reference.R   # exact P = 1 coefficients, psModelCoef.rds
```

## Benchmark studies

Each runner skips jobs whose output already exists. Pass `cv` to the runners marked so to
choose the Laplace prior variance by cross-validation instead of fixing it at 1; their
outputs go to `<name>_cv/`.

| Step | Runner | Script(s) | Output in `$FP_OUT` |
|---|---|---|---|
| Three large sites (SynPUF-A, MIMIC, SynPUF-B): local vs pooled, out of fold | `studies/exp_a/run_all.sh` | `analyze.R` | `results/` |
| Same sites, multi-process federation with the block CCD | `studies/exp_a/fed_prep_all.sh`, then `fed_run_all.sh` | `fed_prep.R`, `fed_alpha.R`, `validation/run_fed.sh` | `sitedata/`, `fedruns/` |
| Collect the federated runs; compare with pooled | `Rscript …/exp_a/fed_collect.R <study>`, `fed_compare.R` | | `fedresults/` |
| Site-size sweep: partner A = 60% of MIMIC, site B of 500 to 20,000 | `studies/auc/sweep_all.sh [cv]` | `sweep_size.R`, `sweep_report.R` | `sweep/` |
| Consortia of 1,000-patient sites, K = 3 / 5 / 10, MIMIC or SynPUF partners | `studies/auc/consortium_all.sh [cv]` | `consortium.R` | `consortium/` |
| Partners from another covariate cluster | `studies/auc/hetero_all.sh [cv]` | `hetero.R` | `hetero/` |
| Transfer matrix and learning curves | `studies/auc/transfer_all.sh`, `Rscript …/curve.R <study> <site>` | `transfer.R`, `curve.R` | `transfer/`, `curve/` |
| Rules predicting the AUC gain | `Rscript …/auc/predict_loso.R [_cv]` | | `predict/` |
| Effect estimation on simulated outcomes, size sweep | `studies/effect/plasmode_all.sh [cv]` | `plasmode.R`, `plasmode_report.R` | `plasmode/` |
| Effect estimation, small consortia | `studies/effect/plasmode_cons_all.sh [cv]` | `plasmode_cons.R`, `plasmode_cons_report.R` | `plasmode_cons/` |
| Fixed vs CV-tuned prior, bootstrap intervals | `Rscript …/effect/compare_cv.R`, `boot_cv.R` | | |
| Data-shared lasso | `studies/effect/dsl_cons_all.sh` | `dsl_cons.R`, `dsl_report.R` | `dsl_cons/` |
| Federated cross-validation of the prior variance; convergence tolerance | `studies/fedcv/fedcv_all.sh`; `Rscript …/fedcv/tolsens.R <study> <v>` | `fedcv.R`, `fedcv_report.R` | `fedcv/`, `tolsens/` |
| Balance with a within-pair randomisation reference | `studies/balance/smd_rct_all.sh` | `smd_rct.R`, `expA_rct.R`, `smd_rct_report.R` | `smd_rct/` |

The report scripts (`*_report.R`, `*_compare.R`) read the outputs above and print summaries.

## Statin study

`phases/` (MIMIC and SynPUF; SynPUF is split into two sites where three are needed):

| Script | Purpose |
|---|---|
| `phase1.R` | matching and balance at full scale, exact vs block CCD (needs `fedruns/fullP20`, see `validation/full_verify.R`) |
| `phase2.R` | sensitivity to P and alpha |
| `phase3_prep.R`, `phase3_run.sh <P> <alpha>`, `phase3_verify.R` | five three-site partitions (IID, unbalanced, covariate shift, prevalence shift, combined) |
| `phase4.R` | CKKS aggregation of the block packets (`ckks.py`, TenSEAL) |
| `phase5.R` | wall time under network latency |
| `phase6.R` | Cox analysis on simulated events |
| `verify_fix.R <lib>` | P = 1 path unchanged by the patch |

`statin3/` (MIMIC, SynPUF and EHRSHOT): run `prep.R` first (site files and common axis), then
`models.R`, `sweep.R` and `oof3.R`, whose outputs the other scripts read. For the reduced
consortium run `prep_small.R`, then `small_run.R`; `bias2.R` and `paired.R` use both.

## Validation

| Script | Checks |
|---|---|
| `test1_legacy.R stock` / `patched` | identical P = 1 fits and exchange counts with and without the patch |
| `test2_sparsity.R` | proximal damping reproduces the exact lasso support; damping after the step leaves spurious nonzeros |
| `test3_mimic.R`, `test5_bound.R`, `test6_boundab.R <lib>` | block runs on MIMIC, trust-region behaviour |
| `test4_run.R` | three site processes over the file exchange vs the pooled fit |
| `negative_tests.R` | inconsistent packets (length, block boundary, blockSize, protocol version, coordinate range) are rejected |
| `mismatch_live.R` | site processes with different settings stop with an error |
| `prep_data.R <b1/b2/b3/full>`, `run_fed.sh`, `verify.R`, `verify_same.R` | multi-process federation on prepared site files vs pooled and same-configuration fits |
| `full_verify.R`, `full_same.R`, `collect_D.R`, `localtime.R` | full-scale block run (`full` scenario) |

`validation/run_fed.sh <scenario> <runId> <P> <alpha> <site...>` starts an aggregator and one
process per site; site files are read from `$FP_OUT/sitedata/<scenario>/`.

## Notes

- Fits use the convergence settings of the package (`convergenceType = "lange"`,
  `tolerance = 1e-6`) unless a script sets them; `studies/fedcv/tolsens.R` compares tighter
  tolerances.
- `studies/data/sites.R` reproduces the three-site construction of `analyze.R`; the
  federated and balance scripts check the treatment labels against the saved results.
