# Read-only connectivity checks on a NEW connection, never a cohort extraction.
args <- commandArgs(trailingOnly = TRUE)
stopifnot(length(args) == 1L)
config <- jsonlite::fromJSON(args[1])
source(file.path(config$project, "windows", "common.R"))
source(file.path(config$project, "windows", "progress.R"))
source(file.path(config$project, "windows", "db-runtime.R"))
source(file.path(config$project, "windows", "diagnostic-checks.R"))
options(FederatedPs.progress = fp_start_progress(config$output, "diagnostic"))
fp_verify_runtime(config$project, config$configDirectory, config$dbBackend)
fp_configure_db_runtime(config, config$output)
operation <- utils::getFromNamespace(".fpsDbOperation", "FederatedPs")
smallQuery <- utils::getFromNamespace(".fpsSmallSqlQuery", "FederatedPs")
details <- fp_prepare_db_connection(fp_read_yuhs_connection(
    file.path(config$configDirectory, "yuhs.Renviron"), dbBackend = config$dbBackend), config)
checks <- fp_diagnostic_checks(details, config$careSites, Sys.getenv("CDM_DATABASE_SCHEMA"),
    connect = DatabaseConnector::connect, disconnect = DatabaseConnector::disconnect,
    smallQuery = smallQuery, operation = operation)
fp_write_diagnostic_status(config$output, config$diagnosticToken, checks)
getOption("FederatedPs.progress")(list(stage = "exiting",
    detail = "Read-only checks and disconnect complete; requesting R process shutdown",
    completed = NA_real_, total = NA_real_, unit = "", etaSeconds = NA_real_, kind = "stage"))
cat("CHECKS COMPLETE: SELECT 1 and configured CARE_SITE lookups; connection closed. Waiting for process shutdown.\n")
cat("These checks do not certify other live sessions or cohort SQL.\n")
flush(stdout())
flush(stderr())
quit(save = "no", status = 0L, runLast = FALSE)
