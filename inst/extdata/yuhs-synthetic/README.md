# Invented YUHS-shaped CDM sample (synthetic-yuhs-v1)

No patient record, database address or credential was copied from YUHS. Only
institution IDs 1/2/3 and source labels 10/20/30 mirror the configured mapping.
Hospital names in this fixture explicitly say Synthetic. These are reduced
OMOP-shaped tables, not a complete conformant OMOP CDM or a local SQL Server.

- 120 eligible invented people per institution, both PPI treatment arms.
- One additional invented person with visits to sites 1 and 2 is excluded.
- Four clinical domains include duplicate, NULL/unknown/wrong-person visit
  links and an out-of-window event to exercise filtering.
- `ppi / default` only: pantoprazole vs omeprazole, first linked exposure,
  age >=18, observation period, -90 through -1 day binary clinical features.
- Large feature concepts beginning 20000000xx are invented test identifiers;
  no clinical interpretation is intended. No outcomes are simulated.

The package prepares these small tables in R and runs the same CohortMethod
population / FederatedPs::fitPs / Cyclops / aggregator path as database runs.
It does not run production T-SQL, validate vocabulary coverage, HIWARE, TLS,
credentials, the SQL Server engine, or the clinical validity of a study.
`studySpecific` deliberately fails in sample mode rather than pretending that
this fixture exercises those criteria. Real-data feature metadata is distinct.

Reproducible generator (for maintainers, base R; run in repository root):

```r
source('R/SyntheticYuhs.R')
x <- .syntheticYuhsCdm()
for (table in names(x)) write.csv(x[[table]],
    file.path('inst/extdata/yuhs-synthetic', paste0(table, '.csv')),
    row.names = FALSE, na = '')
```
