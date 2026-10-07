# Public OMOP tasks and virtual-site preparation

This extension prepares propensity-score comparison tasks. It does not reproduce
the publications' outcome analyses. There are 18 public-source candidates in
addition to the 13 existing presets. A candidate is not a clinically validated
cohort or an automatically selected primary experiment.

## Data and sites

The primary simulation uses MIMIC-IV, SynPUF-A and SynPUF-B. Internal site IDs
are `mimic`, `synpufA`, `synpufB`; display labels include the hyphens. The two
SynPUF sites have disjoint patients, but come from the same synthetic source.
Case-mix partitioning does not create independent hospitals or change the
underlying treatment mechanism conditional on the assignment covariates.

`PrepareSites.py` selects the first native observation period that lasts at least
365 days. It uses only its first 365 days to compute age at landmark, Romano
Charlson category score and log(1 + visit count). The three variables are
standardized using the eligible population's mean and population SD, then
equally weighted. Assignment probability is
`0.2 + 0.6 * logistic(intercept + score)`, with intercept calibrated to mean 0.5.
Seed 20261007 and a deterministic MD5-based uniform value assign each person
once. An independently hashed random 1:1 partition is also saved. Neither rule
uses treatment, outcome, study-specific eligibility or fitted model performance.

The index must be on or after the person's landmark in **both scenarios**.
This is a virtual-site eligibility restriction, separate from a study's own
prior-observation requirement. Public cohorts select each arm's first-recorded
exposure before the landmark restriction; a later episode of that arm is not
relabeled as first use. A later first comparator can remain if washout permits it.
Legacy study-specific presets retain their first eligible person-level event.
A person's entire history remains in one view schema. Age uses the
available OMOP birth fields; missing month/day are represented by January/1.

Analysis schemas are `fps_sim` (mapping), `fps_sim_a` / `fps_sim_b` (case-mix
views), and `fps_sim_a_random` / `fps_sim_b_random` (random-control views).
Vocabulary, provider and care-site tables remain shared views. Tables without
person linkage outside the documented shared-table list are omitted. These are
simulation views, not separate database security boundaries. Source CDM tables
are never rewritten. Replacing a partition requires a new analysis schema.

## Definitions and clinical interpretation

The registry and executable JSON live in `inst/studies`. Original public files,
repository commits and SHA-256 checksums are preserved in `inst/studies/source`.
`FetchDefinitions.py` retrieves only those pinned public files. `BuildDefinitions.py`
reads vocabulary metadata and reconstructs the applied JSON deterministically.

| Design | Public `default` | Public `studySpecific` |
|---|---|---|
| Population | Age ≥18, first recorded drug era | Source-inspired clinical eligibility |
| Prior observation | No minimum beyond index in native OP | 365 days; antiseizure comparison 183 days |
| Baseline features | −90 to −1 days | −365 to −1, plus −30 to −1; antiseizure −183 to −1 |
| Indication / washout | None | Defined explicitly in each JSON |
| Pair handling | Exclude same-day target/comparator ties; earliest eligible arm | Same |
| SynPUF site landmark | Required | Required |

Original legacy R/SQL definitions are retained. Their study-specific policy
excludes the linked acute episode; the new public definitions use pre-index-day
records. This difference is explicit in the study metadata. Neither policy can
guarantee that a date assigned by a source ETL represents when information first
became clinically available. In particular, MIMIC admission-date billing diagnoses
may describe conditions discovered later in that admission. Observation-period
length also does not establish complete outpatient drug capture.

Applied changes from published designs include removal of outcome-dependent
follow-up requirements, symmetric pair washout in selected comparisons, and
replacement of LEGEND's post-index 7-day ingredient-monotherapy rule with an
index-day restriction. The original LEGEND era reconstruction is not reproduced;
within-class co-initiation remains possible. The osteoporosis cohort retains
women older than 45 and its original clinical exclusions, but removes the
absolute pre-2012 date limit and 90-day post-index observation requirement.
All exact changes are in each registry record. These are **adapted PS benchmarks**;
do not label them exact clinical-study replications.

| Public study-specific group | Index / indication | Prior drug exclusion | Covariates |
|---|---|---|---|
| Hypertension (7 comparisons) | First recorded exposure; hypertension −365…0 | Any recorded earlier exposure to the source-defined antihypertensive set; no other specified antihypertensive starts on index | −365…−1 and −30…−1 |
| Depression (5 comparisons) | First drug era; prior/on-index MDD; exclude prior bipolar disorder/schizophrenia | Target/comparator eras overlapping −365…−1 | −365…−1 and −30…−1 |
| Levetiracetam/phenytoin | First drug era; prior/on-index seizure diagnosis | Target/comparator eras overlapping −183…−1 | −183…−1 and −30…−1 |
| Alendronate/raloxifene | First exposure; women >45; osteoporosis −365…0 | Original JSON's previous therapy, fracture and hip-procedure exclusions | −365…−1 and −30…−1 |
| Library antibiotic tasks | First exposure; indication −30…0 | Target/comparator eras overlapping −365…−1 | −365…−1 and −30…−1 |

Phenotype Library cohorts are reusable computational definitions, not a warranty
of validity in these CDMs. Selected antibiotic definitions have pending peer
review. Their ingredient sets need a systemic-route/formulation review, and the
UTI indication uses MedDRA exclusions 36102152 and 36102938. These IDs are absent
from the locally loaded reference vocabulary. Preparation fails on missing seeds,
including excluded seeds, instead of silently dropping the exclusion. Do not
substitute a guessed concept or adopt these strict UTI tasks as primary analyses
until vocabulary and formulation review are complete.

## Reproducible preparation

Configure `.Renviron.mimic` and `.Renviron.synpuf` using the existing examples.
Keep credentials and all patient-level outputs out of Git. The R environment
needs the normal package dependencies plus CirceR, CohortGenerator and
ROhdsiWebApi. The supplied Docker image installs these optional study tools.

```sh
uv run --with 'psycopg[binary]' --with python-dotenv python extras/studies/PrepareSites.py
Rscript extras/studies/PrepareStudies.R cohorts mimic
Rscript extras/studies/PrepareStudies.R cohorts synpuf
Rscript extras/studies/PrepareBalance.R mimic
Rscript extras/studies/PrepareBalance.R synpuf
uv run --with 'psycopg[binary]' --with python-dotenv python extras/studies/CollectDiagnostics.py
```

`PrepareBalance.R` uses official FeatureExtraction `aggregated = TRUE` to prepare
selection diagnostics efficiently. It groups studies sharing a baseline window,
then excludes each comparison's exposure concepts and descendants. Binary
prevalences and their SMDs use the same populations/windows as the patient-level
helper. Its timing markers identify shared batches; do not sum those times over
study rows. To additionally materialize fitting matrices later, run:

```sh
Rscript extras/studies/PrepareStudies.R features mimic
Rscript extras/studies/PrepareStudies.R features synpufA
Rscript extras/studies/PrepareStudies.R features synpufB
```

Supply a study ID as the third R-script argument to prepare just one comparison.
Markers record definition hash, status and elapsed time. They resume a fixed CDM
snapshot; after changing data or vocabulary, use a fresh output directory and
regenerate cohorts. Changes to feature settings or extraction code also require
fresh feature outputs. Do not replace an installed package or edit a running
R script while its preparation processes are active. Feature extraction must
follow completed cohort generation.

The random-control membership/views and cohort counts are prepared with the
case-mix partition. Its feature matrices can be prepared separately with
`FEDERATEDPS_PARTITION=random Rscript extras/studies/PrepareStudies.R features synpufA`
(and `synpufB`); these go to distinct `synpufA_random` / `synpufB_random` directories.
The aggregate runner prepares the case-mix design only. No random-control PS
experiment has been run.

The source-level cohort tables are separate analysis tables in
`fps_studies_mimic` and `fps_studies_synpuf`. SynPUF-A/B reuse the same source-level
definitions and filter by membership and landmark. `getDbStudyData()` accepts a
public study ID and these prepared cohort tables:

```r
data <- FederatedPs::getDbStudyData(
  connectionDetails, cdmDatabaseSchema = "fps_sim_a",
  study = "ohdsi_htn_acei_arb", scenario = "studySpecific",
  cohortDatabaseSchema = "fps_studies_synpuf", generateCohorts = FALSE
)
diagnostics <- FederatedPs::describeStudyData(data)
Andromeda::close(data)
```

The source cohort and extracted features follow the same bundled Circe JSON.
Reusing a prepared cohort also checks its recorded JSON hash in the analysis
schema. An unknown or changed definition must be regenerated.
Source SQL studies are transcribed adaptations; parity with their original SQL
has not been established. Site landmark and pair-selection steps are performed
after JSON cohort generation and are documented here rather than hidden in ATLAS.

For the later three-site RStudio workflow, use
`python start.py --virtual-sites --study ohdsi_htn_acei_arb --scenario studySpecific`.
Set `FEDERATEDPS_PARTITION=random` for the random-control views. This starts the
existing services; run IDs keep their exchanges separate. Preparing source
cohorts is a prerequisite; do not regenerate each virtual site's subset into
the shared source-level cohort tables.

## ATLAS

```sh
python3 extras/studies/StartAtlas.py
uv run --with 'psycopg[binary]' --with python-dotenv python extras/studies/RegisterAtlasVocabulary.py
docker compose --env-file .env.atlas -p federatedps-atlas -f atlas/compose.yaml restart webapi
Rscript extras/studies/PublishDefinitions.R
```

Open <http://localhost:18081/atlas/>. WebAPI is at
<http://localhost:18080/WebAPI>. Wait for WebAPI startup before publishing. In a
container, set `FEDERATEDPS_WEBAPI` to the reachable local WebAPI address.
The stack binds only to localhost and uses a dedicated metadata volume. It
registers a **vocabulary-only** source: inspect cohorts/concept sets here and
generate cohorts with the R runner. Patient profiles and patient-level data are
not published to ATLAS.

`publishStudyDefinitions()` publishes version/hash-named cohorts and standalone
concept sets, preserves prior versions, and compares stored executable SQL to
the bundled definitions. `output/studies/atlas_ids.csv` maps each registry ID to
its server-assigned ATLAS ID and records concept-resolution problems. Internal
JSON codeset IDs, registry cohort IDs and ATLAS IDs are different identifiers.
Concept sets needing a vocabulary update remain flagged; a cohort being present
in ATLAS does not mean its concepts can resolve on every source.

## Diagnostics and later ablation

Preparation outputs contain counts after landmark, same-day ties, one-person
selection and native OP; CohortGenerator inclusion-rule statistics; binary
covariate prevalence and prematch absolute SMD; feature count and nnz; pairwise
and three-site intersection/union/Jaccard; and actual preparation times. Missing
domains must be interpreted as capture gaps, not zero disease prevalence.
The feature union is retained. No artificial feature-overlap percentage or
automatic frequency filter is imposed. Fitting checks resolved concept hashes
for public studies in addition to the existing common feature contract.
When combining patient-level data for any later pooled baseline, identify rows
by source/site plus local row ID; raw numeric IDs can collide across sources.

Choosing primary comparisons requires review of both arm sizes, baseline
coverage, timing, vocabulary and formulation capture. Neither a fixed total N
nor a single Jaccard threshold guarantees an adequate PS task. Related studies
can share patients and are not independent replications. Study selection must
be fixed before inspecting local versus federated results.
The UTI and pneumonia fluoroquinolone/cephalosporin defaults deliberately share
the same exposure-only population; only their indication-specific scenarios
define different questions. Do not count those default runs as independent tasks.

Later local-only / pooled / federated models must use identical eligible
populations, covariate definitions and within-site matching settings. Planned
reporting per study and site:

| Output | Contents |
|---|---|
| Table 1 | Prematch target/comparator N, overlap, common support, postmatch N, retained/excluded percentages by arm and method; trimming separate from matching |
| Figure 1 | Preference-score densities, target red / comparator blue, methods × before/after panels, shared axes, N labels and 0.3/0.7 reference lines |
| Figure 2 | One point per original covariate: prematch versus postmatch absolute SMD, diagonal and 0.1 line; common axes, max SMD and fraction >0.1 |
| Supplement S1 | Every covariateId, name, time window, prematch and three postmatch SMDs, fixed prematch standardization denominator |

Preference-score overlap is the fraction of prematch patients with preference
score in [0.3,0.7], not the area under overlapping densities. Its conversion
uses the prematch site-specific treatment fraction and retains that fraction
after matching. Common support is reported separately, with its exact rule
specified before fitting (for example the intersection of both arms' PS ranges).
Retention denominators are the original arm-specific counts; report support
restriction losses separately. The reference images in `figure_reference` guide
styling, but no model-result figure is generated during preparation.

Local-only, pooled and federated fitting times are **unmeasured**. Preparation
times do not estimate optimizer runtime: feature dimension, nnz, iterations,
hardware and communication rounds all matter. This workflow does not launch
fitting, matching or ablation experiments.
