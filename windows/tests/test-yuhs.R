# Dependency-free checks: Rscript --vanilla windows/tests/test-yuhs.R
source("windows/common.R")
source("R/StudySettings.R")
source("R/CareSiteData.R")
expect_error <- function(expr, pattern) {
    e <- tryCatch({ force(expr); NULL }, error = identity)
    stopifnot(inherits(e, "error"), grepl(pattern, conditionMessage(e)))
}
for (schema in c("CDM", "CDM54_2601.CDM")) .validateCdmSchema(schema)
for (schema in c("x; DROP TABLE person", "db..CDM", "a.b.c", "[CDM]", ""))
    expect_error(.validateCdmSchema(schema), "identifier")
for (id in list(NULL, NA, 0, -1, 1.5, "1 OR 1=1", c(1, 2), 2147483648))
    expect_error(.validateCareSiteId(id), "positive integer")
stopifnot(.validateCareSiteId("3") == 3L)
config <- list(sites = c("severance", "gangnam", "yongin"),
               careSites = list(severance = 1, gangnam = 2, yongin = 3))
fp_check_yuhs_sites(config)
config$careSites$yongin <- 2
expect_error(fp_check_yuhs_sites(config), "Distinct")
config$careSites$yongin <- NULL
expect_error(fp_check_yuhs_sites(config), "Distinct")

path <- tempfile()
settings <- c('DBMS="sql server"', 'DB_SERVER=cdm.example.internal', 'DB_PORT=1433',
              'DB_DATABASE=CDM54_2601', 'DB_USER=fixture_reader',
              'DB_PASSWORD="synthetic value with spaces"', 'CDM_DATABASE_SCHEMA=CDM54_2601.CDM')
writeLines(settings, path)
Sys.setenv(PGPASSWORD = "must-not-leak")
values <- fp_read_connection_values(path, yuhs = TRUE)
stopifnot(values$DB_PASSWORD == "synthetic value with spaces", !nzchar(Sys.getenv("PGPASSWORD")))
writeLines(settings[-6], path)
expect_error(fp_read_connection_values(path, yuhs = TRUE), "DB_PASSWORD")
stopifnot(!nzchar(Sys.getenv("DB_PASSWORD")))
writeLines(sub("DB_PORT=1433", "DB_PORT=1433.9", settings), path)
expect_error(fp_read_connection_values(path, yuhs = TRUE), "port")
writeLines(sub("DB_SERVER=cdm.example.internal", "DB_SERVER=host;encrypt=false", settings), path)
expect_error(fp_read_connection_values(path, yuhs = TRUE), "DB_SERVER")
writeLines(sub("CDM_DATABASE_SCHEMA=CDM54_2601.CDM", "CDM_DATABASE_SCHEMA=OTHER.CDM", settings), path)
expect_error(fp_read_connection_values(path, yuhs = TRUE), "DB_DATABASE")
unlink(path)
Sys.unsetenv(fp_connection_keys())

for (study in listStudies()$study) for (scenario in c("default", "studySpecific")) {
    settings <- getStudySettings(study, scenario)
    a <- .careSiteAnalysis(settings)
    stopifnot(!anyDuplicated(a$analysisId), all(a$analysisId > 0 & a$analysisId < 1000),
              nrow(a) == if (scenario == "default") 6L else 10L)
    sql <- .careSiteClinicalSql("CDM54_2601.CDM", settings)
    stopifnot(nzchar(sql), !grepl("DRUG_ERA", sql))
}

# SUCCESS must not survive an overlap detected on a rerun of verification.
mapped <- fp_attach_person_ids(data.frame(rowId = c(3, 1)),
    data.frame(rowId = 1:3, personId = c("9007199254740999", "12", "13")))
stopifnot(identical(mapped$personId, c("13", "9007199254740999")))
expect_error(fp_attach_person_ids(data.frame(rowId = 4), data.frame(rowId = 1, personId = "10")), "mapping")
source("windows/verify-results.R")
out <- tempfile()
for (site in c("aggregator", "severance", "gangnam", "yongin")) dir.create(file.path(out, site), recursive = TRUE)
coefficients <- c("(Intercept)" = 0.1, "1001" = 0.3)
saveRDS(coefficients, file.path(out, "aggregator", "result.rds"))
config <- list(mode = "Database", dataset = "YUHS", sites = c("severance", "gangnam", "yongin"),
    careSites = list(severance = 1, gangnam = 2, yongin = 3), runId = "fixture", output = out)
for (i in seq_along(config$sites)) {
    population <- data.frame(rowId = 1:2, personId = as.character(i * 10 + 1:2), propensityScore = c(0.3, 0.7))
    attr(population, "metaData") <- list(psModelCoef = coefficients, careSiteId = i)
    saveRDS(population, file.path(out, config$sites[i], "result.rds"))
}
fp_verify_results(config)
stopifnot(file.exists(file.path(out, "SUCCESS.txt")))
population$personId[1] <- "11"
saveRDS(population, file.path(out, "yongin", "result.rds"))
expect_error(fp_verify_results(config), "overlap")
stopifnot(!file.exists(file.path(out, "SUCCESS.txt")))
unlink(out, recursive = TRUE)
cat("PASS: YUHS settings, SQL inputs, feature contracts, credentials and cross-site overlap\n")
