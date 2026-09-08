FederatedPs
===========

FederatedPs is an R package for plaintext federated propensity score estimation
from CohortMethod data. Hospitals fit a shared Bayesian lasso logistic regression
model using Cyclops coordinate descent and pda. Feature metadata
and coordinate statistics are shared; patient rows and propensity scores remain
at each hospital.

Requirements
============

- R 4.1.0 or newer. Package dependencies are declared in `DESCRIPTION`, including
  the required [Cyclops fork](https://github.com/dr-you-group/Cyclops) pinned to
  a specific commit.
- Docker with Docker Compose and Python 3 for the included Web RStudio setup.
- PostgreSQL OMOP CDM datasets for the MIMIC and SynPUF example, with read access
  to their CDM and vocabulary tables.

The Docker image provides R 4.6.1, Java, the PostgreSQL JDBC driver and the
required R packages.

Installation
============

To install the R package:

```r
install.packages("remotes")
remotes::install_github("dr-you-group/FederatedPS")
```

Access to a private repository requires a `GITHUB_PAT` with read permission.
The Docker workflow below builds and installs the package from a local checkout.

How to run
==========

1. From the repository root, copy the example settings:

   ```sh
   cp .env.example .env
   cp .Renviron.mimic.example .Renviron.mimic
   cp .Renviron.synpuf.example .Renviron.synpuf
   chmod 600 .env .Renviron.mimic .Renviron.synpuf
   ```

   Set the three RStudio passwords in `.env` and each site's database settings
   in its `.Renviron` file. Set `PGHOST` to a database address reachable from
   that site's container. Local settings are excluded from Git.

2. Build the image and start the three RStudio environments:

   ```sh
   python3 start.py
   ```

   | Role | RStudio | Example CDM | Connection settings |
   | --- | --- | --- | --- |
   | Aggregator | http://localhost:38787 | None | None |
   | MIMIC | http://localhost:38788 | `ohdsi.mimiciv` | `.Renviron.mimic` |
   | SynPUF | http://localhost:38789 | `ohdsi.synpuf23` | `.Renviron.synpuf` |

   Each role has its own container, Docker network and `work/<role>` folder.
   Each hospital receives its own connection settings; database permissions
   determine its access. pda messages use a shared Docker volume.

3. Log in as `rstudio` with the password for that environment and open
   `/home/rstudio/FederatedPs/FederatedPs.Rproj`.

4. Run the aggregator script in the aggregator session:

   ```r
   source("extras/RunAggregator.R")
   ```

   While it waits for the hospitals, run the site script in both hospital
   sessions:

   ```r
   source("extras/CodeToRun.R")
   ```

   All three sessions use the run ID assigned by `start.py`. Run
   `python3 start.py` again before starting a new fit.

Example cohort and model
========================

`extras/CodeToRun.R` uses CohortMethod's `drug_era` pathway to select patients
aged 65 or older at their first recorded use of atorvastatin (1545958) or
simvastatin (1539403). CohortMethod excludes same-day use of both drugs. A
separate cohort table is not required.

Covariates include age group, sex, and condition, drug, procedure and measurement
occurrence during days -90 through -1 before exposure. Treatment concepts and
their descendants are excluded. Calendar-year features are omitted because
MIMIC dates are shifted. No 90-day observation history is required, so this is a
first-recorded-use cohort rather than a confirmed new-user cohort. The example
is intended for implementation testing with MIMIC's limited observation history
and synthetic SynPUF data.

Hospitals use the sorted union of feature IDs with common definitions. Only
features that are zero at every hospital are removed. The example uses binary
features, unit scales, a fixed Laplace variance of 1 and an unpenalized intercept.
It performs no cross-validation or outcome analysis.

Output
======

Each hospital script leaves a `population` data frame in its R session, with a
`propensityScore` column in the original row order. Model coefficients are
stored in `attr(population, "metaData")$psModelCoef`. The population can be used
with CohortMethod's propensity score matching functions.

`aggregatePs()` invisibly returns the common named coefficient vector. The
example site script closes its Andromeda object after fitting. When calling
`fitPs()` directly, the caller owns the supplied `CohortMethodData` object and
closes it when finished.

Project structure
=================

```text
FederatedPS/
├── R/
│   ├── FederatedPs.R          # Hospital model fitting
│   └── Pda.R                  # Aggregation and pda exchange
├── extras/
│   ├── CodeToRun.R            # Hospital example
│   ├── ConnectionDetails.R    # Site database settings
│   └── RunAggregator.R        # Aggregator example
├── DockerImage/Dockerfile
├── compose.yaml
├── start.py
└── tests/testthat/
```

Local settings, work folders, experiments and reference documents are excluded
from Git.

Development
===========

Experimental (version 0.0.1). Tests use synthetic data in separate R processes
to compare two- and three-site federated fits with pooled Cyclops, including
row and feature alignment, matching, covariate balance and convergence handling.

```sh
R CMD build .
R CMD check FederatedPs_0.0.1.tar.gz
```

Building the PDF manual requires LaTeX. Use `R CMD check --no-manual` when it is
unavailable.

License
========

FederatedPs is licensed under the Apache License 2.0.
