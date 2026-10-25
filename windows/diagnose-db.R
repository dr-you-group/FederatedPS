# Read-only connectivity checks on a NEW connection, never a cohort extraction.
args <- commandArgs(trailingOnly = TRUE)
stopifnot(length(args) == 1L)
config <- jsonlite::fromJSON(args[1])
source(file.path(config$project, "windows", "common.R"))
source(file.path(config$project, "windows", "progress.R"))
source(file.path(config$project, "windows", "db-runtime.R"))
options(FederatedPs.progress = fp_start_progress(config$output, "diagnostic"))
fp_verify_runtime(config$project)
fp_configure_db_runtime(config, config$output)
operation <- utils::getFromNamespace(".fpsDbOperation", "FederatedPs")
smallQuery <- utils::getFromNamespace(".fpsSmallSqlQuery", "FederatedPs")
local({
    details <- fp_prepare_db_connection(fp_read_yuhs_connection(
        file.path(config$configDirectory, "yuhs.Renviron")), config)
    connection <- operation("Opening diagnostic connection", DatabaseConnector::connect(details), stage = "diagnostic")
    on.exit(try(DatabaseConnector::disconnect(connection), silent = TRUE), add = TRUE)
    sql <- "SELECT 1 AS ok, @@SPID AS session_id"
    answer <- operation("Testing SELECT 1 and session ID", smallQuery(connection, sql,
        c(ok = "integer", sessionId = "integer")), sql = sql, stage = "diagnostic")
    stopifnot(nrow(answer) == 1L, answer$ok == 1L)
    cat("PASS: SELECT 1; SQL Server session ID:", answer$sessionId, "\n")
    for (role in names(config$careSites)) {
        id <- as.integer(config$careSites[[role]])
        sql <- sprintf(paste("SELECT care_site_id, care_site_name, care_site_source_value",
            "FROM %s.CARE_SITE WHERE care_site_id = %d"), Sys.getenv("CDM_DATABASE_SCHEMA"), id)
        answer <- operation(paste("CARE_SITE lookup:", role), smallQuery(connection, sql,
            c(careSiteId = "integer", careSiteName = "character", careSiteSourceValue = "character")),
            sql = sql, stage = "diagnostic")
        if (nrow(answer) != 1L || answer$careSiteId != id) stop("Expected one CARE_SITE row for ", role)
        cat("PASS:", role, "CARE_SITE", id, "returned one row\n")
        flush(stdout())
    }
})
cat("PASS: new R/JDBC connection and all configured CARE_SITE lookups. This does not certify other live sessions or cohort SQL.\n")
