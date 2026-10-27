# Private configuration export for Test-JavaConnection.ps1. This process must
# never initialize rJava. stdout is an ASCII hex packet captured only in memory;
# the launcher feeds it to Java stdin and never saves it in diagnostic logs.
args <- commandArgs(TRUE)
result <- tryCatch(suppressWarnings(suppressMessages({
    if (length(args) != 2L) stop("Expected project and settings paths")
    project <- normalizePath(args[1], winslash = "/", mustWork = TRUE)
    settings <- normalizePath(args[2], winslash = "/", mustWork = TRUE)
    source(file.path(project, "windows", "common.R"))
    source(file.path(project, "windows", "jdbc-driver.R"))
    values <- fp_read_connection_values(settings, yuhs = TRUE)
    tls <- function(name, default) {
        value <- tolower(trimws(Sys.getenv(name, unset = default)))
        if (!value %in% c("true", "false")) stop("Invalid TLS setting")
        value
    }
    packet <- c(fp_resolve_jdbc(project, settings), values$DB_SERVER,
        values$DB_PORT, values$DB_DATABASE, values$DB_USER, values$DB_PASSWORD,
        values$CDM_DATABASE_SCHEMA, tls("DB_ENCRYPT", "true"),
        tls("DB_TRUST_SERVER_CERTIFICATE", "false"))
    if ("rJava" %in% loadedNamespaces()) stop("Configuration export loaded rJava")
    if (length(packet) != 9L || anyNA(packet) || any(!nzchar(packet))) stop("Incomplete configuration")
    vapply(enc2utf8(packet), function(value) paste(as.character(charToRaw(value)), collapse = ""), "")
})), error = function(e) NULL)
if (is.null(result)) {
    # Do not print conditions: readRenviron errors can contain the rejected line.
    cat("Configuration export failed; check the selected Renviron and JDBC path.\n", file = stderr())
    quit(save = "no", status = 2L, runLast = FALSE)
}
writeLines(c("FPS_JAVA_PROBE_V1", result), stdout(), useBytes = TRUE)
flush(stdout())
