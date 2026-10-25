# Base-R regression: validate the JDBC settings without any live database.
args <- commandArgs(trailingOnly = TRUE)
stopifnot(length(args) == 1L)
project <- normalizePath(args[1], mustWork = TRUE)
source(file.path(project, "windows", "common.R"))
temp <- tempfile("fps-tls-")
dir.create(temp)
driver <- file.path(temp, "sqlserver")
dir.create(driver)
invisible(file.create(file.path(driver, "mssql-jdbc-fixture.jar")))
saved <- Sys.getenv(c(fp_connection_keys(), "DATABASECONNECTOR_JAR_FOLDER"), unset = NA_character_)
restore <- function() {
    Sys.unsetenv(names(saved))
    present <- saved[!is.na(saved)]
    if (length(present)) do.call(Sys.setenv, as.list(present))
    unlink(temp, recursive = TRUE)
}
Sys.setenv(DATABASECONNECTOR_JAR_FOLDER = temp)
base <- c('DBMS="sql server"', "DB_SERVER=localhost", "DB_PORT=1433",
          "DB_DATABASE=CDM54_2601", "DB_USER=fixture", "DB_PASSWORD=fixture",
          "CDM_DATABASE_SCHEMA=CDM54_2601.CDM")
settings <- file.path(temp, "connection.Renviron")
# Replace only the external constructor in this isolated test environment.
mock_constructor <- function(...) list(...)
replace_constructor <- function(expr) {
    if (!is.call(expr)) return(expr)
    if (identical(expr, quote(DatabaseConnector::createConnectionDetails))) return(as.name("mock_constructor"))
    as.call(lapply(as.list(expr), replace_constructor))
}
body(fp_read_yuhs_connection) <- replace_constructor(body(fp_read_yuhs_connection))
tryCatch({
    writeLines(base, settings)
    Sys.setenv(DB_ENCRYPT = "false", DB_TRUST_SERVER_CERTIFICATE = "true")
    result <- fp_read_yuhs_connection(settings)
    stopifnot(identical(result$extraSettings,
        "databaseName=CDM54_2601;encrypt=true;trustServerCertificate=false"))
    writeLines(c(base, "DB_ENCRYPT=false", "DB_TRUST_SERVER_CERTIFICATE=false"), settings)
    result <- fp_read_yuhs_connection(settings)
    stopifnot(identical(result$extraSettings,
        "databaseName=CDM54_2601;encrypt=false;trustServerCertificate=false"))
    for (invalid in c("yes", "false;other=value")) {
        writeLines(c(base, paste0("DB_ENCRYPT=", invalid)), settings)
        failed <- inherits(try(fp_read_yuhs_connection(settings), silent = TRUE), "try-error")
        stopifnot(failed)
    }
    cat("PASS: SSL-off setting, secure defaults, environment isolation, invalid values rejected.\n")
}, finally = restore())
