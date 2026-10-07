FederatedPs
===========

FederatedPs is an R package for plaintext federated propensity score estimation
from CohortMethod data. Hospitals fit a shared Bayesian lasso logistic regression
model using Cyclops coordinate descent and pda. Feature metadata
and coordinate statistics are shared; patient rows and propensity scores remain
at each hospital.

<!-- BEGIN PUBLIC STUDY CATALOG -->
## Public OMOP and Phenotype Library tasks (dev)

The `dev` extension retains 13 legacy presets and adds **18 public-source comparison tasks**.
The primary simulation uses **MIMIC-IV / SynPUF-A / SynPUF-B**.
These are adapted PS benchmarks, not replications of the publications’ effect estimates.
A registry entry is a candidate; successful cohort generation alone does not establish clinical validity.
See the [preparation and ATLAS workflow](docs/study-workflow.md), [registry](inst/studies/registry.json)
and [pinned source manifest](inst/studies/source/manifest.json). No PS fitting or matching is launched by the preparation scripts.

### Study questions, references and selection reasons

| Study ID | Target / comparator | Source journal · year · DOI | Original study question / benchmark reason |
|---|---|---|---|
| `ohdsi_htn_acei_arb` | ACE inhibitors / ARBs | The Lancet · 2019 · [10.1016/S0140-6736(19)32317-7](https://doi.org/10.1016/S0140-6736(19)32317-7) | Comparative effectiveness and safety of first-line antihypertensive therapies. Common indication with differences in initial drug-class choice. |
| `ohdsi_htn_acei_dccb` | ACE inhibitors / dihydropyridine CCBs | The Lancet · 2019 · [10.1016/S0140-6736(19)32317-7](https://doi.org/10.1016/S0140-6736(19)32317-7) | Comparative effectiveness and safety of first-line antihypertensive therapies. Common indication with differences in initial drug-class choice. |
| `ohdsi_htn_acei_thiazide` | ACE inhibitors / thiazide / thiazide-like diuretics | The Lancet · 2019 · [10.1016/S0140-6736(19)32317-7](https://doi.org/10.1016/S0140-6736(19)32317-7) | Comparative effectiveness and safety of first-line antihypertensive therapies. Common indication with differences in initial drug-class choice. |
| `ohdsi_htn_arb_dccb` | ARBs / dihydropyridine CCBs | The Lancet · 2019 · [10.1016/S0140-6736(19)32317-7](https://doi.org/10.1016/S0140-6736(19)32317-7) | Comparative effectiveness and safety of first-line antihypertensive therapies. Common indication with differences in initial drug-class choice. |
| `ohdsi_htn_arb_thiazide` | ARBs / thiazide / thiazide-like diuretics | The Lancet · 2019 · [10.1016/S0140-6736(19)32317-7](https://doi.org/10.1016/S0140-6736(19)32317-7) | Comparative effectiveness and safety of first-line antihypertensive therapies. Common indication with differences in initial drug-class choice. |
| `ohdsi_htn_dccb_thiazide` | dihydropyridine CCBs / thiazide / thiazide-like diuretics | The Lancet · 2019 · [10.1016/S0140-6736(19)32317-7](https://doi.org/10.1016/S0140-6736(19)32317-7) | Comparative effectiveness and safety of first-line antihypertensive therapies. Common indication with differences in initial drug-class choice. |
| `ohdsi_htn_chlorthalidone_hctz` | chlorthalidone / hydrochlorothiazide | JAMA Internal Medicine · 2020 · [10.1001/jamainternmed.2019.7454](https://doi.org/10.1001/jamainternmed.2019.7454) | Cardiovascular and safety outcomes of first-line chlorthalidone versus hydrochlorothiazide. Within-class ingredient choice complements the class-level comparisons. |
| `ohdsi_depression_sertraline_citalopram` | sertraline / citalopram | Philosophical Transactions of the Royal Society A · 2018 · [10.1098/rsta.2017.0356](https://doi.org/10.1098/rsta.2017.0356) | Large-scale comparative effectiveness of depression treatments across observational databases. Psychiatric indication; SSRI and SSRI/SNRI treatment-choice tasks. |
| `ohdsi_depression_sertraline_escitalopram` | sertraline / escitalopram | Philosophical Transactions of the Royal Society A · 2018 · [10.1098/rsta.2017.0356](https://doi.org/10.1098/rsta.2017.0356) | Large-scale comparative effectiveness of depression treatments across observational databases. Psychiatric indication; SSRI and SSRI/SNRI treatment-choice tasks. |
| `ohdsi_depression_sertraline_fluoxetine` | sertraline / fluoxetine | Philosophical Transactions of the Royal Society A · 2018 · [10.1098/rsta.2017.0356](https://doi.org/10.1098/rsta.2017.0356) | Large-scale comparative effectiveness of depression treatments across observational databases. Psychiatric indication; SSRI and SSRI/SNRI treatment-choice tasks. |
| `ohdsi_depression_sertraline_venlafaxine` | sertraline / venlafaxine | Philosophical Transactions of the Royal Society A · 2018 · [10.1098/rsta.2017.0356](https://doi.org/10.1098/rsta.2017.0356) | Large-scale comparative effectiveness of depression treatments across observational databases. Psychiatric indication; SSRI and SSRI/SNRI treatment-choice tasks. |
| `ohdsi_depression_sertraline_duloxetine` | sertraline / duloxetine | Philosophical Transactions of the Royal Society A · 2018 · [10.1098/rsta.2017.0356](https://doi.org/10.1098/rsta.2017.0356) | Large-scale comparative effectiveness of depression treatments across observational databases. Psychiatric indication; SSRI and SSRI/SNRI treatment-choice tasks. |
| `ohdsi_levetiracetam_phenytoin` | levetiracetam / phenytoin | Epilepsia · 2017 · [10.1111/epi.13828](https://doi.org/10.1111/epi.13828) | Angioedema risk among new users of levetiracetam compared with phenytoin. Antiseizure treatment choice and a 183-day observation requirement. |
| `ohdsi_alendronate_raloxifene` | alendronate / raloxifene | Scientific Reports · 2020 · [10.1038/s41598-020-68037-8](https://doi.org/10.1038/s41598-020-68037-8) | Fracture effectiveness and safety of alendronate compared with raloxifene in women with osteoporosis. Sex-, age- and indication-restricted treatment choice. |
| `pl_uti_fluoroquinolone_cephalosporin` | fluoroquinolone / cephalosporin | OHDSI Phenotype Library 1060/1061; no comparative-paper DOI/journal/year assigned | Antibiotic-class choice in patients with urinary tract infection. Acute infection indication using a pair of public treatment phenotypes; not a published comparative-effect replication. |
| `pl_uti_fluoroquinolone_trimethoprim` | fluoroquinolone / trimethoprim | OHDSI Phenotype Library 1060/1062; no comparative-paper DOI/journal/year assigned | Antibiotic-class choice in patients with urinary tract infection. Acute infection indication using a pair of public treatment phenotypes; not a published comparative-effect replication. |
| `pl_uti_cephalosporin_trimethoprim` | cephalosporin / trimethoprim | OHDSI Phenotype Library 1061/1062; no comparative-paper DOI/journal/year assigned | Antibiotic-class choice in patients with urinary tract infection. Acute infection indication using a pair of public treatment phenotypes; not a published comparative-effect replication. |
| `pl_pneumonia_fluoroquinolone_cephalosporin` | fluoroquinolone / cephalosporin | OHDSI Phenotype Library 1063/1064; no comparative-paper DOI/journal/year assigned | Antibiotic-class choice in patients with acute typical pneumonia. Acute infection indication using a pair of public treatment phenotypes; not a published comparative-effect replication. |

These are 18 treatment comparisons from several source studies, not 18 independent publications.
The default scenario uses adults ≥18, first recorded drug era and −90…−1-day covariates.
Study-specific windows and source modifications are recorded in the registry and executable ATLAS JSON.
The osteoporosis design retains the original female and >45-year restrictions.
All virtual-site analyses additionally require index on/after the first 365-day baseline landmark.
The selected antibiotic phenotypes have pending library peer review and require formulation review.
UTI strict definitions are blocked on the current vocabulary because excluded MedDRA seeds 36102152 and 36102938 are missing.
Other invalid/deprecated seeds are retained transparently for review in the concept audit; a familiar drug name alone does not validate the resolved cohort.

### Cohort preparation counts

Values are **Target / Comparator persons before matching**, after pair selection, site landmark and native OP.
V1 = `default`; V2 = `studySpecific`. `pending` means no completed count is available; it is not zero.
`blocked` identifies a failed vocabulary prerequisite. These counts come from cohort-generation diagnostics,
not from a completed local/pooled/federated analysis. The [aggregate snapshot](docs/study-feasibility.csv)
also records feature counts and prematch SMD summaries; local `output/studies/cohort_counts.csv` retains all attrition stages.

Snapshot refreshed (UTC): 2026-10-07 08:47.

| Study | V1 MIMIC-IV | V1 SynPUF-A | V1 SynPUF-B | V2 MIMIC-IV | V2 SynPUF-A | V2 SynPUF-B |
|---|---:|---:|---:|---:|---:|---:|
| `ohdsi_htn_acei_arb` | 42,399 / 15,547 | 145,534 / 143,533 | 147,102 / 145,825 | 1,172 / 407 | 2,971 / 1,021 | 2,231 / 786 |
| `ohdsi_htn_acei_dccb` | 33,559 / 26,615 | 141,693 / 170,679 | 143,163 / 175,309 | 1,172 / 1,039 | 2,971 / 1,278 | 2,231 / 991 |
| `ohdsi_htn_acei_thiazide` | 35,993 / 14,501 | 135,087 / 136,975 | 136,297 / 141,865 | 1,172 / 476 | 2,971 / 1,250 | 2,231 / 947 |
| `ohdsi_htn_arb_dccb` | 12,751 / 31,870 | 135,467 / 167,983 | 137,717 / 172,583 | 407 / 1,039 | 1,021 / 1,278 | 786 / 991 |
| `ohdsi_htn_arb_thiazide` | 13,956 / 19,115 | 133,910 / 140,972 | 135,431 / 146,090 | 407 / 476 | 1,021 / 1,250 | 786 / 947 |
| `ohdsi_htn_dccb_thiazide` | 30,759 / 16,880 | 171,235 / 143,926 | 175,245 / 148,994 | 1,039 / 476 | 1,278 / 1,250 | 991 / 947 |
| `ohdsi_htn_chlorthalidone_hctz` | 1,929 / 18,064 | 101,167 / 163,362 | 103,257 / 169,474 | 86 / 388 | 241 / 780 | 167 / 606 |
| `ohdsi_depression_sertraline_citalopram` | 10,472 / 11,368 | 86,097 / 80,401 | 85,012 / 79,969 | 1,204 / 719 | 3,802 / 3,478 | 3,010 / 2,796 |
| `ohdsi_depression_sertraline_escitalopram` | 10,765 / 4,626 | 92,427 / 17,169 | 91,330 / 16,430 | 1,236 / 617 | 4,397 / 757 | 3,463 / 632 |
| `ohdsi_depression_sertraline_fluoxetine` | 10,718 / 6,998 | 84,827 / 92,673 | 83,941 / 90,602 | 1,230 / 562 | 3,627 / 3,953 | 2,891 / 3,250 |
| `ohdsi_depression_sertraline_venlafaxine` | 10,772 / 4,451 | 86,450 / 79,277 | 85,252 / 78,387 | 1,245 / 485 | 3,832 / 3,381 | 3,037 / 2,773 |
| `ohdsi_depression_sertraline_duloxetine` | 10,730 / 5,211 | 91,457 / 27,016 | 90,231 / 26,232 | 1,229 / 719 | 4,325 / 1,141 | 3,417 / 925 |
| `ohdsi_levetiracetam_phenytoin` | 11,901 / 3,063 | 32,359 / 25,652 | 32,084 / 24,569 | 1,124 / 261 | 4,618 / 4,473 | 3,591 / 3,598 |
| `ohdsi_alendronate_raloxifene` | 2,085 / 251 | 53,615 / 11,914 | 52,638 / 11,796 | 325 / 15 | 4,292 / 852 | 3,450 / 737 |
| `pl_uti_fluoroquinolone_cephalosporin` | 29,359 / 66,934 | 131,624 / 169,444 | 131,630 / 164,726 | blocked | blocked | blocked |
| `pl_uti_fluoroquinolone_trimethoprim` | 40,451 / 10,009 | 141,210 / 79,849 | 140,738 / 80,033 | blocked | blocked | blocked |
| `pl_uti_cephalosporin_trimethoprim` | 74,135 / 8,050 | 177,914 / 78,633 | 172,740 / 78,771 | blocked | blocked | blocked |
| `pl_pneumonia_fluoroquinolone_cephalosporin` | 29,359 / 66,934 | 131,624 / 169,444 | 131,630 / 164,726 | 235 / 516 | 651 / 1,125 | 458 / 825 |

Source-level patients can appear in several studies; do not add counts across rows.
The UTI and pneumonia fluoroquinolone/cephalosporin tasks share the same default exposure definition;
their indication-specific scenario differs. The identical default rows are not independent PS tasks.

### Observed feature overlap before fitting

Each cell is **three-site intersection / union of nonzero covariateIds (Jaccard %)**.
The same feature definition and window are required for an ID to count as shared.
These counts do not measure PS overlap, common support or matching retention; those require fitted scores.
See the [domain and site-pair breakdown](docs/study-feature-overlap.csv). A small intersection alone is not
a rejection threshold, and a large intersection does not establish clinical comparability.
In particular, zero measurement capture in a claims source is a recording difference, not an absence of disease.

| Study | V1 shared / union (Jaccard) | V2 shared / union (Jaccard) |
|---|---:|---:|
| `ohdsi_htn_acei_arb` | 5,113 / 41,245 (12.4%) | 1,779 / 28,117 (6.3%) |
| `ohdsi_htn_acei_dccb` | 5,258 / 41,669 (12.6%) | 2,026 / 29,851 (6.8%) |
| `ohdsi_htn_acei_thiazide` | 5,107 / 41,002 (12.5%) | 1,834 / 28,715 (6.4%) |
| `ohdsi_htn_arb_dccb` | 4,902 / 41,289 (11.9%) | 1,508 / 25,225 (6.0%) |
| `ohdsi_htn_arb_thiazide` | 4,666 / 40,255 (11.6%) | 1,249 / 23,745 (5.3%) |
| `ohdsi_htn_dccb_thiazide` | 5,127 / 41,406 (12.4%) | 1,580 / 25,956 (6.1%) |
| `ohdsi_htn_chlorthalidone_hctz` | 4,105 / 38,952 (10.5%) | 761 / 18,396 (4.1%) |
| `ohdsi_depression_sertraline_citalopram` | 4,347 / 39,274 (11.1%) | 3,313 / 49,140 (6.7%) |
| `ohdsi_depression_sertraline_escitalopram` | 3,851 / 37,952 (10.1%) | 3,194 / 46,185 (6.9%) |
| `ohdsi_depression_sertraline_fluoxetine` | 3,975 / 38,917 (10.2%) | 3,260 / 49,377 (6.6%) |
| `ohdsi_depression_sertraline_venlafaxine` | 3,913 / 38,597 (10.1%) | 3,286 / 49,092 (6.7%) |
| `ohdsi_depression_sertraline_duloxetine` | 3,958 / 38,189 (10.4%) | 3,375 / 46,979 (7.2%) |
| `ohdsi_levetiracetam_phenytoin` | 3,753 / 36,154 (10.4%) | 3,099 / 49,302 (6.3%) |
| `ohdsi_alendronate_raloxifene` | 2,716 / 34,020 (8.0%) | 2,285 / 43,030 (5.3%) |
| `pl_uti_fluoroquinolone_cephalosporin` | 6,118 / 43,867 (13.9%) | blocked |
| `pl_uti_fluoroquinolone_trimethoprim` | 5,820 / 43,219 (13.5%) | blocked |
| `pl_uti_cephalosporin_trimethoprim` | 6,053 / 43,801 (13.8%) | blocked |
| `pl_pneumonia_fluoroquinolone_cephalosporin` | 6,118 / 43,867 (13.9%) | 2,189 / 33,552 (6.5%) |

Individual covariate prevalences and prematch absolute SMDs remain in local `output/studies/<site>/<study>/<scenario>/covariates.csv`.
No local-only / pooled / federated result or postmatch metric is included in this preparation snapshot.

### Recorded site and ATLAS preparation

SynPUF partition eligibility: **2,024,335 persons**; seed 20261007.
The recorded partition preparation took 527 seconds on this environment.
These are site populations, not per-study N. The two virtual sites share one synthetic data source.

| Partition | Site | Persons | Mean age | Mean Charlson | Mean baseline visits |
|---|---|---:|---:|---:|---:|
| caseMix | SynPUF-A | 1,011,871 | 73.47 | 4.88 | 25.69 |
| caseMix | SynPUF-B | 1,012,464 | 71.05 | 3.63 | 19.68 |
| random | SynPUF-A | 1,011,936 | 72.25 | 4.25 | 22.67 |
| random | SynPUF-B | 1,012,399 | 72.27 | 4.25 | 22.70 |

Duplicate persons: 0; invalid assignments: 0.

Local ATLAS: 72 cohort definitions; 6 entries flag an unresolved concept-set review.

Local-only, pooled and federated fitting times remain unmeasured.
Open `http://localhost:18081/atlas/` and search cohort names beginning with `FPS /`.
The legacy feasibility counts below describe the earlier MIMIC/SynPUF/EHRSHOT setup and are not these new virtual-site results.

<!-- END PUBLIC STUDY CATALOG -->

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

Legacy presets
--------------

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

Clinical references and research questions
-----------------------------------------

Each preset represents a treatment-choice question for PS benchmarking. The
table below identifies a published clinical comparison supporting that question
and describes what the publication actually investigated. These are adapted
benchmark cohorts: the package does not reproduce the publications' outcome
analyses. Publication year refers to the journal issue; an earlier online
publication year is shown when applicable. Bibliographic records were checked
against publisher and PubMed/Europe PMC records on **2026-10-01**.

| Study preset | Journal | Publication year | DOI / article record | What the cited study investigated |
| --- | --- | --- | --- | --- |
| `opioid` | PLOS ONE | 2022 | [10.1371/journal.pone.0266561](https://doi.org/10.1371/journal.pone.0266561) | Retrospective cohort study of adults initially prescribed hydrocodone or oxycodone after a year without recorded opioid exposure. Compared subsequent chronic opioid use and overdose. |
| `oxycodone_hydromorphone` | Japanese Journal of Clinical Oncology | 2018 | [10.1093/jjco/hyy038](https://doi.org/10.1093/jjco/hyy038) | Randomized, double-blind non-inferiority trial in opioid-naive Japanese cancer patients. Compared analgesia and safety over five days with oral immediate-release hydromorphone tablets versus oxycodone powder. |
| `laxative` | Supportive Care in Cancer | 2020; online 2019 | [10.1007/s00520-019-04944-5](https://doi.org/10.1007/s00520-019-04944-5) | Randomized crossover trial in cancer outpatients at risk of, or experiencing, opioid-induced constipation. Compared bowel function, tolerability and preference during successive three-week periods of PEG and sennosides. |
| `morphine_hydromorphone` | Annals of Emergency Medicine | 2006 | [10.1016/j.annemergmed.2006.03.005](https://doi.org/10.1016/j.annemergmed.2006.03.005) | Randomized, double-blind trial in adults with severe acute pain in the emergency department. Compared IV hydromorphone and morphine for pain reduction at 30 minutes and adverse effects. |
| `acid_suppression` | Gastroenterology | 2010; online 2009 | [10.1053/j.gastro.2009.09.063](https://doi.org/10.1053/j.gastro.2009.09.063) | Randomized, double-blind trial in patients with aspirin-related ulcers or erosions who continued aspirin. Compared pantoprazole with high-dose famotidine for recurrent symptomatic or bleeding lesions over 48 weeks. |
| `class_ppi_h2ra` | World Journal of Gastroenterology | 2005 | [10.3748/wjg.v11.i26.4067](https://doi.org/10.3748/wjg.v11.i26.4067) | Meta-analysis of randomized comparative trials evaluating healing of erosive esophagitis with PPIs and H2 receptor antagonists, including dose and disease-severity comparisons. Evidence is pooled across trials and ingredients. |
| `ppi` | Alimentary Pharmacology & Therapeutics | 1995 | [10.1111/j.1365-2036.1995.tb00388.x](https://doi.org/10.1111/j.1365-2036.1995.tb00388.x) | Randomized, double-blind multicentre trial of pantoprazole 40 mg versus omeprazole 20 mg for reflux esophagitis. Assessed endoscopic healing and symptom relief over four to eight weeks. |
| `acetaminophen_ibuprofen` | The American Journal of Emergency Medicine | 2013 | [10.1016/j.ajem.2013.06.007](https://doi.org/10.1016/j.ajem.2013.06.007) | Randomized, double-blind trial in adults with acute musculoskeletal pain in the emergency department. Compared oral acetaminophen, ibuprofen and their combination for pain reduction over one hour and rescue analgesia. |
| `antiemetic` | Annals of Emergency Medicine | 2014 | [10.1016/j.annemergmed.2014.03.017](https://doi.org/10.1016/j.annemergmed.2014.03.017) | Randomized trial of IV ondansetron, IV metoclopramide and placebo in adults with undifferentiated emergency-department nausea/vomiting. Evaluated nausea reduction at 30 minutes, satisfaction and rescue treatment. |
| `ondansetron_promethazine` | Academic Emergency Medicine | 2008 | [10.1111/j.1553-2712.2008.00060.x](https://doi.org/10.1111/j.1553-2712.2008.00060.x) | Randomized, double-blind non-inferiority trial of IV ondansetron versus promethazine for undifferentiated nausea in the emergency department. Compared nausea relief at 30 minutes, anxiety, sedation and other adverse effects. |
| `ondansetron_prochlorperazine` | Western Journal of Emergency Medicine | 2011 | DOI not identified in the checked records; [PMID 21691464](https://pubmed.ncbi.nlm.nih.gov/21691464/), [publisher record](https://escholarship.org/uc/item/7d93s2j7) | Randomized, double-blind trial of IV ondansetron versus prochlorperazine in adults with emergency-department nausea/vomiting. Compared vomiting during the first two hours, nausea severity and tolerability. |
| `pantoprazole_lansoprazole` | World Journal of Gastroenterology | 2009 | [10.3748/wjg.15.990](https://doi.org/10.3748/wjg.15.990) | Four-arm randomized trial of omeprazole, lansoprazole, pantoprazole and esomeprazole in erosive reflux esophagitis. Assessed early heartburn/acid-reflux relief and endoscopic healing after eight weeks. |
| `statin` (reference) | Clinical Drug Investigation | 1998 | [10.2165/00044011-199816030-00006](https://doi.org/10.2165/00044011-199816030-00006) | Randomized, double-blind pilot trial of atorvastatin versus simvastatin in hypercholesterolaemia. Compared lipid profiles and plasma fibrinogen during initial treatment and subsequent dose titration. |

The following differences determine how these references should be interpreted:

- `oxycodone_hydromorphone` uses a broader pain indication; it does not require
  cancer. `laxative` requires constipation but does not require cancer or opioid
  use. Their cited trials studied more specific patient groups.
- `acid_suppression` uses **GERD**, while the direct pantoprazole/famotidine trial
  studied aspirin-related ulcer recurrence. `class_ppi_h2ra` also uses GERD
  without confirming erosive esophagitis or its severity. The GERD indication
  is additionally informed by the **2022 ACG guideline**, published in
  *The American Journal of Gastroenterology*,
  [DOI 10.14309/ajg.0000000000001538](https://doi.org/10.14309/ajg.0000000000001538).
  A guideline provides clinical context; it is not a separate trial reproduced
  by the benchmark.
- `ppi` and `pantoprazole_lansoprazole` do not enforce the publications'
  endoscopic eligibility or doses. The latter retains two of the four trial
  treatments. `acetaminophen_ibuprofen` retains the two single-agent groups;
  it does not include the trial's combination-treatment arm.
- `antiemetic` uses oral products although its cited trial used IV treatment,
  and excludes the placebo comparison. The injectable presets
  `morphine_hydromorphone`, `ondansetron_promethazine` and
  `ondansetron_prochlorperazine` do not establish IV route or equivalent doses
  from dose form alone.
- `opioid` does not reproduce the reference's overdose/chronic-use outcomes,
  and `statin` does not reproduce its trial's placebo run-in or dose titration.
  The observation, washout and covariate windows above are explicit benchmark
  design choices. Dose, severity, external use and treatment intent can remain
  unmeasured, and related presets may contain the same patients.

Two legacy cohort scenarios
---------------------------

- **Version 1 (`default`)**: age **18 or older**, first recorded `drug_era` for either arm,
  all forms and record types, no indication restriction, no prior-observation
  minimum and no drug-free washout. CohortMethod selects the first raw record
  before age/observation filters and excludes same-day first use of both arms;
  an excluded patient does not re-enter at a later date. Covariates cover
  **-90 through -1 days**. This is a first-recorded-use methods cohort.
- **Version 2 (`studySpecific`)**: age **18 or older**, first *eligible* `drug_exposure`
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
a matching retention rate. Reassess sizes at all hospitals before fitting; the
helper reports both counts and stops if an arm is empty. SynPUF is synthetic;
this benchmark does not establish real-world treatment effects.

Cohort-size estimates by dataset and version
-------------------------------------------

The following are **pre-matching patient counts from the completed feasibility
audit dated 2026-10-01 (Asia/Seoul)**, whose summary was generated at
2026-09-30 22:34:07 UTC. They are exact saved aggregate counts for that local CDM
snapshot and serve as size estimates for subsequent package runs. They have
**not been reproduced by running the newly added `getDbStudyData()` helper**.
Full covariate matrices, PS, matching, overlap and SMD were not computed in that
audit.

Each cell is **Target / Comparator (Total)**, using the arm order in the preset
table. Each patient contributes once within a study/version, so Total is the
distinct target-plus-comparator count after eligibility selection. Patients
may recur across different studies; totals must not be summed to obtain a
unique population across studies.

The audited schemas were `mimiciv`, `synpuf23` and `ehrshot`. The SynPUF column
therefore describes that local `synpuf23` load, not a guarantee about any new
CDM-loader `synpuf` load. Both versions use age **18 or older**. Version 1 is
the revised adult default, not the historical 65-or-older example.

### Version 1: common defaults (`default`)

First recorded drug era, native observation period containing index, no
indication or prior-observation minimum, no drug-free washout, all forms and
record types; planned covariates on days **-90 through -1**.

| Study preset | MIMIC-IV: T / C (Total) | SynPUF: T / C (Total) | EHRSHOT: T / C (Total) |
| --- | ---: | ---: | ---: |
| `opioid` | 109,592 / 4,241 (**113,833**) | 219,953 / 680,402 (**900,355**) | 736 / 1,024 (**1,760**) |
| `oxycodone_hydromorphone` | 73,672 / 30,551 (**104,223**) | 338,443 / 129,688 (**468,131**) | 641 / 756 (**1,397**) |
| `laxative` | 11,827 / 96,989 (**108,816**) | 36,454 / 47,468 (**83,922**) | 497 / 555 (**1,052**) |
| `morphine_hydromorphone` | 47,267 / 49,486 (**96,753**) | 281,941 / 130,457 (**412,398**) | 479 / 929 (**1,408**) |
| `acid_suppression` | 46,840 / 29,719 (**76,559**) | 222,175 / 155,418 (**377,593**) | 1,043 / 441 (**1,484**) |
| `class_ppi_h2ra` | 67,941 / 37,681 (**105,622**) | 724,998 / 319,813 (**1,044,811**) | 1,204 / 409 (**1,613**) |
| `ppi` | 45,784 / 33,939 (**79,723**) | 148,431 / 575,925 (**724,356**) | 1,040 / 327 (**1,367**) |
| `acetaminophen_ibuprofen` | 158,051 / 2,675 (**160,726**) | 1,026,127 / 195,726 (**1,221,853**) | 1,848 / 211 (**2,059**) |
| `antiemetic` | 97,558 / 6,917 (**104,475**) | 310,291 / 149,527 (**459,818**) | 1,380 / 152 (**1,532**) |
| `ondansetron_promethazine` | 104,449 / 651 (**105,100**) | 296,693 / 234,954 (**531,647**) | 1,544 / 79 (**1,623**) |
| `ondansetron_prochlorperazine` | 99,289 / 3,046 (**102,335**) | 331,207 / 49,250 (**380,457**) | 1,489 / 70 (**1,559**) |
| `pantoprazole_lansoprazole` | 52,951 / 3,439 (**56,390**) | 189,404 / 328,077 (**517,481**) | 1,219 / 64 (**1,283**) |
| `statin` (reference) | 41,964 / 22,362 (**64,326**) | 376,071 / 770,395 (**1,146,466**) | 510 / 314 (**824**) |

### Version 2: study-specific criteria (`studySpecific`)

First eligible drug exposure after the preset's indication, prior-observation,
class washout, product and record-type restrictions. The covariate plan uses
the study's baseline and 30-day windows, additionally ending before the linked
acute episode as described above.

| Study preset | MIMIC-IV: T / C (Total) | SynPUF: T / C (Total) | EHRSHOT: T / C (Total) |
| --- | ---: | ---: | ---: |
| `opioid` | 4,333 / 158 (**4,491**) | 7,332 / 28,810 (**36,142**) | 32 / 43 (**75**) |
| `oxycodone_hydromorphone` | 3,618 / 403 (**4,021**) | 7,353 / 1,128 (**8,481**) | 42 / 2 (**44**) |
| `laxative` | 596 / 2,567 (**3,163**) | 228 / 356 (**584**) | 8 / 4 (**12**) |
| `morphine_hydromorphone` | 1,639 / 175 (**1,814**) | 1,590 / 936 (**2,526**) | 4 / 27 (**31**) |
| `acid_suppression` | 3,151 / 1,099 (**4,250**) | 15,733 / 9,288 (**25,021**) | 26 / 1 (**27**) |
| `class_ppi_h2ra` | 9,306 / 1,865 (**11,171**) | 122,024 / 47,006 (**169,030**) | 34 / 2 (**36**) |
| `ppi` | 3,332 / 7,306 (**10,638**) | 18,313 / 70,634 (**88,947**) | 34 / 11 (**45**) |
| `acetaminophen_ibuprofen` | 4,645 / 93 (**4,738**) | 31,377 / 29,370 (**60,747**) | 45 / 8 (**53**) |
| `antiemetic` | 990 / 69 (**1,059**) | 352 / 740 (**1,092**) | 9 / 2 (**11**) |
| `ondansetron_promethazine` | 2,778 / 25 (**2,803**) | 102 / 290 (**392**) | 24 / 0 (**24**) |
| `ondansetron_prochlorperazine` | 2,491 / 84 (**2,575**) | 102 / 121 (**223**) | 22 / 0 (**22**) |
| `pantoprazole_lansoprazole` | 3,642 / 317 (**3,959**) | 18,684 / 33,726 (**52,410**) | 32 / 2 (**34**) |
| `statin` (reference) | 7,418 / 3,183 (**10,601**) | 37,649 / 74,298 (**111,947**) | 48 / 7 (**55**) |

**Interpretation:** the twelve selected presets meet the Version 1 EHRSHOT
threshold of 1,000 patients in this audit. The additional `statin` reference
does not (824 patients). In Version 2, `ondansetron_promethazine` and
`ondansetron_prochlorperazine` have no EHRSHOT comparator patients, preventing
a three-hospital fit with the current implementation. Other very small arms
also require feasibility assessment; nonzero counts alone do not establish
adequate overlap or matching retention. Version 2 can select a later eligible
index, so changes between versions are not patient-level attrition or matching
losses. No matched patient counts are available yet.

Local audit provenance: the twelve selected rows come from
`experiment/study-scenarios-20261001/report/selected-studies.csv`; the statin
reference comes from `all-study-comparison.csv` in the same directory. The
saved `status.json`, `protocol.json` and `report/query-provenance.json` record
the audit status, definitions and query provenance. These local research files
remain excluded from Git; the aggregate tables above are included here for
readers of the installed/published package.

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
