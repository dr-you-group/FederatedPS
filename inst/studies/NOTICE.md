# Public definition provenance

Bundled originals are from OHDSI Legend, OHDSI StudyProtocols and OHDSI
PhenotypeLibrary at the commits and SHA-256 hashes in `source/manifest.json`.
Original copyright notices and package DESCRIPTION license declarations are
retained. Their upstream packages declare Apache License 2.0. Applied cohort
JSON is a modified PS-only benchmark definition, as recorded in `registry.json`.
No source patients, clinical outcomes, passwords or fitted results are bundled.

The SynPUF split uses the Romano category roots/weights from FeatureExtraction
3.14.0 `sql/sql_server/CharlsonIndex.sql`, restricted here to the first 365 days.
This is a simulation covariate, not a validation of clinical comorbidity coding.
