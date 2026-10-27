## Extract one (study, CDM schema) design as sparse triplets, using getDbStudyData().
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))

suppressPackageStartupMessages({library(FederatedPs); library(dplyr)})
a <- commandArgs(TRUE); study <- a[1]; schema <- a[2]
out <- sprintf(file.path(FP_DATA, "design/%s__%s.rds"), study, schema)
if (file.exists(out)) { cat("exists:", out, "\n"); quit(status = 0) }

## Connection from the environment: FP_DB_SERVER ("host/database"), FP_DB_PORT, FP_DB_USER, PGPASSWORD.
cd <- DatabaseConnector::createConnectionDetails(
    dbms = "postgresql", server = Sys.getenv("FP_DB_SERVER", "localhost/ohdsi"),
    port = as.integer(Sys.getenv("FP_DB_PORT", "5432")),
    user = Sys.getenv("FP_DB_USER", "ohdsi_reader"), password = Sys.getenv("PGPASSWORD"))
t0 <- Sys.time()
d <- getDbStudyData(cd, cdmDatabaseSchema = schema, study = study, scenario = "default")
on.exit(Andromeda::close(d), add = TRUE)

## No outcome restriction: the population is the full cohort.
coh <- as.data.frame(collect(d$cohorts))
cov <- as.data.frame(collect(d$covariates))
ref <- sort(unique(pull(collect(d$covariateRef), covariateId)))
saveRDS(list(study = study, site = schema,
             rowId = coh$rowId, personId = coh$personId, treatment = coh$treatment,
             cov = cov, covariateIds = ref,
             attrition = attr(d, "metaData")$attrition),
        out, compress = FALSE)
cat(sprintf("%-28s %-9s rows=%7d  T=%7d  C=%7d  nnz=%10d  feat=%6d  %.1f min\n",
    study, schema, nrow(coh), sum(coh$treatment == 1), sum(coh$treatment == 0),
    nrow(cov), length(ref), as.numeric(difftime(Sys.time(), t0, units = "mins"))))
