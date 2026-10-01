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

Two cohort scenarios
--------------------

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
