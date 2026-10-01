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
- PostgreSQL OMOP CDM datasets, with read access to their clinical and vocabulary
  tables and permission to create session temporary tables. The study helpers
  use the layout produced by [CDM-loader](https://github.com/dr-you-group/CDM-loader):
  `mimiciv`, `synpuf` and `ehrshot` schemas by default. Set the actual schema name
  in each site's configuration if it differs (for example, `synpuf23`).

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

   To include the third hospital, also copy `.Renviron.ehrshot.example` to
   `.Renviron.ehrshot`, set its database settings and `EHRSHOT_RSTUDIO_PASSWORD`
   in `.env`, and restrict the new file's permissions with `chmod 600`.
   If that password is empty, the optional EHRSHOT environment uses the
   aggregator's RStudio password.

2. Build the image and start the three RStudio environments:

   ```sh
   python3 start.py
   ```

   Choose the study and scenario once for all hospitals. Add `--ehrshot` for
   the three-hospital setup:

   ```sh
   python3 start.py --study ppi --scenario default --ehrshot
   # For a separate run using the study's eligibility and time windows:
   python3 start.py --study ppi --scenario studySpecific --ehrshot
   ```

   These commands start RStudio; fitting starts when the R scripts below run.
   The original optional positional run ID remains supported. Every fit needs
   a fresh alphanumeric run ID; omitting it generates one automatically.

   | Role | RStudio | Example CDM | Connection settings |
   | --- | --- | --- | --- |
   | Aggregator | http://localhost:38787 | None | None |
   | MIMIC | http://localhost:38788 | `ohdsi.mimiciv` | `.Renviron.mimic` |
   | SynPUF | http://localhost:38789 | `ohdsi.synpuf` | `.Renviron.synpuf` |
   | EHRSHOT (optional) | http://localhost:38790 | `ohdsi.ehrshot` | `.Renviron.ehrshot` |

   Each role has its own container, Docker network and `work/<role>` folder.
   Each hospital receives its own connection settings; database permissions
   determine its access. pda messages use a shared Docker volume.

3. Log in as `rstudio` with the password for that environment and open
   `/home/rstudio/FederatedPs/FederatedPs.Rproj`.

4. Run the aggregator script in the aggregator session:

   ```r
   source("extras/RunAggregator.R")
   ```

   While it waits for the hospitals, run the site script in each hospital
   sessions:

   ```r
   source("extras/CodeToRun.R")
   ```

   All sessions use the run ID assigned by `start.py`. Run `start.py` again
   with the desired study, scenario and hospital options before a new fit.

Switching studies
=================

Installed-package users can use the same helper without the Docker launcher:

```r
library(FederatedPs)
listStudies()
getStudySettings("ppi", "studySpecific")

# connectionDetails uses DatabaseConnector and the site's CDM-loader PG* values.
# Change only study/scenario, identically at every hospital, then use a new runId.
cohortMethodData <- getDbStudyData(
    connectionDetails = connectionDetails,
    cdmDatabaseSchema = cdmDatabaseSchema,
    study = "ppi", scenario = "default"
)
# Existing population preparation and fitPs() calls consume this object.
# Close it with Andromeda::close(cohortMethodData) when finished.
```

In RStudio, `extras/CodeToRun.R` reads `FEDERATEDPS_STUDY` (default `opioid`)
and `FEDERATEDPS_SCENARIO` (default `default`). `extras/RunAggregator.R` reads
the comma-separated `FEDERATEDPS_SITES` (default `mimic,synpuf`). `start.py`
sets these for the selected hospitals. All hospitals must use the same package
version and study definition. The existing specification exchange also checks
the study and scenario before optimization.

Available presets
-----------------

The twelve selected comparisons and the original statin reference are below.
Days are **prior continuous observation / class drug-free washout / indication
lookback** in `studySpecific`; these restrictions do not apply in `default`.
The rationale column describes the comparison's role in this benchmark.

| Study | Target / comparator | Study-specific indication | Days | Product restriction | Rationale |
| --- | --- | --- | --- | --- | --- |
| `opioid` | oxycodone / hydrocodone | Pain | 365 / 365 / 30 | Oral immediate release | Oral opioid choice |
| `oxycodone_hydromorphone` | oxycodone / hydromorphone | Pain | 365 / 365 / 30 | Oral immediate release | Another oral opioid comparator |
| `laxative` | PEG 3350 / sennosides, USP | Constipation | 90 / 30 / 30 | Oral single ingredient | Osmotic versus stimulant laxative |
| `morphine_hydromorphone` | morphine / hydromorphone | Pain | 90 / 30 / 7 | Injectable single ingredient | Acute parenteral opioid choice |
| `acid_suppression` | pantoprazole / famotidine | GERD | 180 / 180 / 180 | Oral single ingredient | PPI versus H2RA choice |
| `class_ppi_h2ra` | PPI / H2RA classes | GERD | 180 / 180 / 180 | Oral single ingredient | Broader class-level comparison |
| `ppi` | pantoprazole / omeprazole | GERD | 180 / 180 / 180 | Oral single ingredient | Same-class ingredient choice |
| `acetaminophen_ibuprofen` | acetaminophen / ibuprofen | Musculoskeletal pain | 90 / 30 / 30 | Oral single ingredient | Nonopioid analgesic choice |
| `antiemetic` | ondansetron / metoclopramide | Nausea/vomiting | 90 / 7 / 7 | Oral single ingredient | Oral antiemetic choice |
| `ondansetron_promethazine` | ondansetron / promethazine | Nausea/vomiting | 90 / 7 / 7 | Injectable single ingredient | Antiemetic class choice |
| `ondansetron_prochlorperazine` | ondansetron / prochlorperazine | Nausea/vomiting | 90 / 7 / 7 | Injectable single ingredient | Another parenteral comparator |
| `pantoprazole_lansoprazole` | pantoprazole / lansoprazole | GERD | 180 / 180 / 180 | Oral single ingredient | Another PPI comparator |
| `statin` (reference) | atorvastatin / simvastatin | Dyslipidemia | 365 / 365 / 365 | Oral single ingredient | Original example's drug pair |

These definitions adapt clinical comparisons to a computational benchmark.
For example, the [PEG/sennosides study](https://pubmed.ncbi.nlm.nih.gov/31321524/)
concerned opioid-induced constipation in cancer care, and the
[ondansetron/metoclopramide trial](https://pubmed.ncbi.nlm.nih.gov/24818542/)
used intravenous treatment. Those eligibility criteria and routes are not
fully reproduced by the corresponding oral presets. The
[ondansetron/prochlorperazine trial](https://pubmed.ncbi.nlm.nih.gov/21691464/)
also used IV treatment; an injectable OMOP dose form alone does not establish
IV administration. Dose, severity, external medication use and treatment
intent can remain unmeasured. Related presets may contain the same patients.

Two cohort scenarios
--------------------

- **`default`**: age **18 or older**, first recorded `drug_era` for either arm,
  all forms and record types, no indication restriction, no prior-observation
  minimum and no drug-free washout. CohortMethod selects the first raw record
  before age/observation filters and excludes same-day first use of both arms;
  an excluded patient does not re-enter at a later date. Covariates cover
  **-90 through -1 days**. This is a first-recorded-use methods cohort.
- **`studySpecific`**: age **18 or older**, first *eligible* `drug_exposure`
  after the study's observation, indication, drug-free and product filters;
  one patient per study. Drug-free washout excludes any relevant `drug_era`
  overlapping `[index - washout, index - 1]`. It is separate from CohortMethod's
  `washoutPeriod`, which represents prior observation. Same-day records from
  both arms exclude that candidate date, including opposite-arm records whose
  product form fails eligibility. A later eligible date may be selected.

Both scenarios require the index to be within a **native observation period**.
The helper neither removes this join nor invents missing observation periods.
Default age uses CohortMethod's days/365.25 rule; study-specific age uses
completed calendar years. Both use recorded birth month/day, defaulting missing
values to January/1. No common calendar period is imposed across shifted dates.

Study-specific covariates use the prior-observation window and a 30-day window,
both ending on day -1, with an additional upper bound **strictly before the
linked inpatient/ER episode starts**. A linked preceding ER visit ending no
earlier than the day before admission also bounds the window. Indications use
the same upper bound. When there is no linked acute visit, the bound is index;
this cannot detect unlinked encounters. Clinical records must start within the
long window. Session-local views enforce this bound while retaining the true
exposure index for demographics and window anchors. The study-specific exposure
cohort ends at index; no outcome follow-up is defined.

RxNorm ingredients/products, ATC classes, diagnosis descendants and dose forms
are resolved from the site's own vocabulary. Oral opioid presets allow
acetaminophen/ibuprofen combinations and exclude extended-release dose forms;
other presets require a single ingredient. Ingredient-only records without an
eligible dose form fail the study-specific product filter. The allowed record
types, concept IDs and exact windows are visible in `getStudySettings()`.

The two scenario cohorts need not be nested. A difference in their sizes is not
a matching retention rate. The twelve selected comparisons met the previously
audited **default** criterion of at least 1,000 distinct target-plus-comparator
patients in EHRSHOT; this is snapshot-specific, not an enforced or guaranteed
property of a new CDM load. Reassess sizes at all hospitals before fitting.
Study-specific cohorts can be much smaller: the earlier audit had an empty
EHRSHOT comparator for `ondansetron_promethazine` and
`ondansetron_prochlorperazine`. The helper reports both counts and stops if an
arm is empty. SynPUF is synthetic; this
benchmark does not establish real-world treatment effects.

Covariates and model
--------------------

Covariates include age group, sex, and binary condition, drug, procedure and
measurement occurrence. Treatment concepts and their descendants are excluded.
Calendar-year features are omitted because MIMIC dates are shifted.

Hospitals use the sorted union of feature IDs with common definitions. Only
features that are zero at every hospital are removed. The example uses binary
features, unit scales, a fixed Laplace variance of 1 and an unpenalized intercept.
It performs no cross-validation or outcome analysis.

`getDbStudyData()` uses CohortMethod's installed cohort SQL and FeatureExtraction
on one PostgreSQL connection so that the temporary study cohorts and filtered
views remain visible. No CohortMethod or FeatureExtraction package patch,
permanent cohort table, Python selection script or cached research result is
required. `fitPs()` still accepts caller-supplied CohortMethodData, including
custom non-drug cohorts prepared through CohortMethod's cohort-table pathway.

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

The study data's metadata stores the canonical `studyDefinition`, the local
`resolvedIngredients` and final eligible target/comparator counts. The single
attrition row is a final count, not a full eligibility flow or matching report.
Matching, SMD, overlap and local-only/pooled/federated ablations are separate
analyses and are not automatically run by the data helper.

Project structure
=================

```text
FederatedPS/
├── R/
│   ├── FederatedPs.R          # Hospital model fitting
│   ├── Pda.R                  # Aggregation and pda exchange
│   ├── StudySettings.R        # Named studies and two cohort scenarios
│   └── StudyData.R            # Temporary cohorts and covariate extraction
├── inst/sql/postgresql/       # Study selection and covariate time restrictions
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
