# Windows-only runtime policy. Keep connection creation in common.R so a local
# SSL choice is preserved by launcher updates. Never print connection details.
fp_timeout_value <- function(config, name, default) {
    value <- config[[name]]
    if (is.null(value)) value <- default
    if (!is.numeric(value) || length(value) != 1L || is.na(value) ||
        !is.finite(value) || value < 1 || value > 2147483647)
        stop("Invalid timeout: ", name)
    as.integer(value)
}

fp_configure_db_runtime <- function(config, out) {
    directory <- file.path(out, "sql-diagnostics")
    if (!dir.exists(directory) && !dir.create(directory, recursive = TRUE))
        stop("Cannot create role-local SQL diagnostic directory")
    options(FederatedPs.sqlDiagnosticsDirectory = directory,
            FederatedPs.smallQueryTimeoutSeconds = fp_timeout_value(config, "smallQueryTimeout", 60),
            errorReportFileLocation = directory)
    site <- basename(out)
    settings <- if (identical(config$dataset, "YUHS")) "yuhs.Renviron" else paste0(site, ".Renviron")
    settingsPath <- file.path(config$configDirectory, settings)
    options(FederatedPs.progressContext = list(site = site, study = config$study, scenario = config$scenario,
        patientLimit = config$patientLimits[[site]],
        connectionHash = unname(tools::md5sum(settingsPath)),
        package = as.character(utils::packageVersion("FederatedPs")),
        driver = as.character(utils::packageVersion("DatabaseConnector"))))
    invisible(directory)
}

fp_prepare_db_connection <- function(details, config) {
    if (!identical(details$dbms, "sql server")) return(details)
    settings <- details$extraSettings
    if (is.null(settings)) settings <- ""
    if (!is.character(settings) || length(settings) != 1L || is.na(settings))
        stop("Expected SQL Server JDBC settings as a string")
    parts <- strsplit(settings, ";", fixed = TRUE)[[1L]]
    # Only override timeout policy; preserve database, TLS and other settings.
    parts <- parts[nzchar(trimws(parts)) & !grepl(
        "^\\s*(loginTimeout|queryTimeout|cancelQueryTimeout)\\s*=", parts, ignore.case = TRUE)]
    details$extraSettings <- paste(c(parts, "loginTimeout=30", "cancelQueryTimeout=10",
        paste0("queryTimeout=", fp_timeout_value(config, "dbQueryTimeout", 7200))), collapse = ";")
    details
}

# This condition is raised ONLY by the tiny initial JDBC probes, before any
# cohort extraction/temp tables. Clinical SQL, validation and fitting never retry.
fp_get_db_study_data <- function(..., .get = FederatedPs::getDbStudyData) {
    attempt <- 1L
    repeat {
        result <- tryCatch(list(ok = TRUE, value = .get(...)),
            fps_small_query_error = function(e) list(ok = FALSE, error = e))
        if (result$ok) return(result$value)
        if (attempt >= 2L) stop(result$error)
        message("Initial read-only database probe failed; retrying once with a fresh connection. ",
                "No cohort extraction is retried. Cause: ", conditionMessage(result$error))
        attempt <- attempt + 1L
    }
}
