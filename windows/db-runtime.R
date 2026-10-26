# Windows-only runtime policy. Keep connection creation in common.R so a local
# SSL choice is preserved by launcher updates. Never print connection details.
fp_timeout_value <- function(config, name, default) {
    value <- config[[name]]
    if (is.null(value)) value <- default
    if (!is.numeric(value) || length(value) != 1L || is.na(value) ||
        !is.finite(value) || value != floor(value) || value < 1 || value > 2147483647)
        stop("Invalid timeout: ", name)
    as.integer(value)
}

fp_socket_timeout_millis <- function(seconds) {
    # JDBC socketTimeout is a signed int in milliseconds, unlike queryTimeout.
    as.integer(min(.Machine$integer.max, (as.double(seconds) + 15) * 1000))
}

fp_configure_db_runtime <- function(config, out) {
    directory <- file.path(out, "sql-diagnostics")
    if (!dir.exists(directory) && !dir.create(directory, recursive = TRUE))
        stop("Cannot create role-local SQL diagnostic directory")
    options(FederatedPs.sqlDiagnosticsDirectory = directory,
            FederatedPs.smallQueryTimeoutSeconds = fp_timeout_value(config, "smallQueryTimeout", 60),
            FederatedPs.clinicalNetworkTimeoutMillis = fp_socket_timeout_millis(
                fp_timeout_value(config, "dbQueryTimeout", 7200)),
            errorReportFileLocation = directory)
    site <- basename(out)
    settings <- if (identical(config$dataset, "YUHS")) "yuhs.Renviron" else paste0(site, ".Renviron")
    settingsPath <- file.path(config$configDirectory, settings)
    options(FederatedPs.progressContext = list(site = site, study = config$study, scenario = config$scenario,
        patientLimit = config$patientLimits[[site]],
        extractionWorkers = config$extractionWorkers,
        connectionHash = unname(tools::md5sum(settingsPath)),
        package = as.character(utils::packageVersion("FederatedPs")),
        driver = as.character(utils::packageVersion("DatabaseConnector"))))
    options(FederatedPs.dbStartupObserver = fp_db_startup_reporter(config, out, site))
    options(FederatedPs.sqlPreparationObserver = fp_sql_preparation_reporter(config, out, site))
    invisible(directory)
}

fp_sql_preparation_reporter <- function(config, out, site) {
    function(operation) {
        record <- c(list(runId=config$runId, site=site, pid=Sys.getpid()), operation)
        jsonlite::write_json(record, file.path(out,"sql-prepare-state.json"), auto_unbox=TRUE, pretty=TRUE)
        invisible(NULL)
    }
}

fp_prepare_sql_plans <- function(config, sites, setContext = function(site) NULL,
        prepare = utils::getFromNamespace(".fpsPrepareCareSiteSqlPlan", "FederatedPs")) {
    # Only read configuration here. No driver/DB connection is created. In a
    # sequential run ALL site plans precede the first connection, including
    # when the second/third site would otherwise render in a used JDBC JVM.
    values <- fp_read_connection_values(file.path(config$configDirectory,"yuhs.Renviron"), yuhs=TRUE)
    settings <- FederatedPs::getStudySettings(config$study, config$scenario)
    plans <- list()
    for (site in sites) {
        setContext(site)
        out <- file.path(config$output,"extraction",site)
        dir.create(out,recursive=TRUE,showWarnings=FALSE)
        fp_configure_db_runtime(config,out)
        id <- config$careSites[[site]]
        plans[[as.character(id)]] <- prepare(values$CDM_DATABASE_SCHEMA,settings,id,config$patientLimits[[site]])
    }
    options(FederatedPs.careSiteSqlPlans=plans)
    invisible(NULL)
}

fp_db_startup_reporter <- function(config, out, site) {
    started <- NULL
    readyWritten <- FALSE
    lastPhase <- NULL
    phaseStartedUtc <- NULL
    publish <- function(value, name) {
        destination <- file.path(out, name)
        jsonlite::write_json(value, paste0(destination, ".partial"), auto_unbox=TRUE, pretty=TRUE)
        if (!file.rename(paste0(destination, ".partial"), destination))
            stop("Cannot publish DB startup watchdog marker")
    }
    function(phase, ready = FALSE) {
        # After successful checks the long clinical queries have their own
        # timeout. A late disconnect must not restart the startup clock.
        if (readyWritten) return(invisible(NULL))
        now <- format(Sys.time(), "%Y-%m-%dT%H:%M:%OS3Z", tz="UTC")
        if (is.null(started)) {
            started <<- list(runId=config$runId, site=site, pid=Sys.getpid(), startedUtc=now)
            publish(started, "db-startup-start.json")
        }
        if (!identical(lastPhase, phase)) {
            lastPhase <<- phase
            phaseStartedUtc <<- now
        }
        jsonlite::write_json(c(started, list(phase=phase, phaseStartedUtc=phaseStartedUtc, updatedUtc=now)),
            file.path(out,"db-startup-phase.json"),auto_unbox=TRUE,pretty=TRUE)
        if (isTRUE(ready)) {
            publish(c(started,list(state="checks-passed",completedUtc=now)), "db-startup-ready.json")
            readyWritten <<- TRUE
        }
        invisible(NULL)
    }
}

fp_prepare_db_connection <- function(details, config) {
    if (!identical(details$dbms, "sql server")) return(details)
    settings <- details$extraSettings
    if (is.null(settings)) settings <- ""
    if (!is.character(settings) || length(settings) != 1L || is.na(settings))
        stop("Expected SQL Server JDBC settings as a string")
    parts <- strsplit(settings, ";", fixed = TRUE)[[1L]]
    # Direct/adaptive is the bulk default; only the two-row probe statement
    # overrides buffering to full. Preserve database, TLS and other settings.
    parts <- parts[nzchar(trimws(parts)) & !grepl(
        "^\\s*(loginTimeout|queryTimeout|cancelQueryTimeout|socketTimeout|selectMethod|responseBuffering)\\s*=", parts, ignore.case = TRUE)]
    details$extraSettings <- paste(c(parts, "selectMethod=direct", "responseBuffering=adaptive",
        "loginTimeout=30", "cancelQueryTimeout=10",
        paste0("queryTimeout=", fp_timeout_value(config, "dbQueryTimeout", 7200)),
        paste0("socketTimeout=", fp_socket_timeout_millis(
            fp_timeout_value(config, "smallQueryTimeout", 60)))), collapse = ";")
    details
}

# Preserve the FIRST failure and its diagnostic phase. Reconnecting used to
# repeat an identical blocked probe and obscure which connection had failed.
# Neither initial probes nor clinical SQL are automatically replayed.
fp_get_db_study_data <- function(..., .get = FederatedPs::getDbStudyData) {
    .get(...)
}
