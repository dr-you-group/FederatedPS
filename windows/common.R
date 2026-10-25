fp_check_names <- function(run_id, sites) {
    if (length(run_id) != 1L || is.na(run_id) || !grepl("^[A-Za-z0-9]+$", run_id))
        stop("Run ID must be alphanumeric")
    if (length(sites) < 2L || anyNA(sites) || anyDuplicated(tolower(sites)) ||
        any(!grepl("^[A-Za-z0-9]+$", sites)) || any(tolower(sites) %in% c("aggregator", "total")))
        stop("Provide distinct alphanumeric sites; aggregator and total are reserved")
}

fp_verify_runtime <- function(project) {
    lock <- jsonlite::fromJSON(file.path(project, "windows", "runtime-lock.json"))
    if (.Platform$OS.type != "windows" || .Machine$sizeof.pointer != 8L ||
        as.character(getRversion()) != lock$rVersion)
        stop("This deployment requires Windows x64 R ", lock$rVersion)
    lib <- Sys.getenv("FEDERATEDPS_LIBRARY")
    if (!nzchar(lib) || !dir.exists(lib)) stop("Start through the Windows launcher to configure the offline library")
    packages <- c("FederatedPs", "Cyclops", "CohortMethod", "Andromeda", "DatabaseConnector",
                  "FeatureExtraction", "dplyr", "Matrix", "pda", "rlang", "SqlRender", "rJava")
    for (pkg in packages) {
        if (!requireNamespace(pkg, quietly = TRUE)) stop("Missing/unloadable package: ", pkg)
    }
    for (pkg in c("FederatedPs", "Cyclops")) {
        expected <- normalizePath(file.path(lib, pkg), winslash = "/", mustWork = TRUE)
        loaded <- normalizePath(getNamespaceInfo(asNamespace(pkg), "path"), winslash = "/", mustWork = TRUE)
        if (tolower(expected) != tolower(loaded)) stop("Wrong ", pkg, " loaded; restart R using the Windows launcher")
    }
    expected_version <- read.dcf(file.path(project, "DESCRIPTION"))[1, "Version"]
    if (as.character(utils::packageVersion("FederatedPs")) != expected_version)
        stop("FederatedPs version differs from the checkout; rerun Install-Offline.ps1")
    if (!identical(utils::packageDescription("Cyclops")$RemoteSha, lock$cyclopsCommit) ||
        !all(c("aggregate", "blockSize", "alpha") %in% names(formals(Cyclops::createControl))))
        stop("Old Cyclops detected. Run Install-Offline.ps1 to build the pinned block CCD fork")
    # Rprofile runs before default packages (including utils) are attached.
    if (!identical(utils::getFromNamespace(".protocolVersion", "FederatedPs"), lock$protocol))
        stop("FederatedPs protocol differs from runtime-lock.json")
    jar <- Sys.getenv("DATABASECONNECTOR_JAR_FOLDER")
    if (!nzchar(jar) || !dir.exists(jar)) stop("DATABASECONNECTOR_JAR_FOLDER is missing")
    if (!file.exists(file.path(jar, "sqlserver", lock$sqlServerJar)))
        stop("SQL Server JDBC missing; transfer the new payload and run Install-Offline.ps1")
    rJava::.jinit()
    if (!"ppi" %in% FederatedPs::listStudies()$study) stop("Study metadata missing")
    cat("PASS: offline R, block Cyclops, FederatedPs, JVM and JDBC\n")
    invisible(TRUE)
}

fp_connection_keys <- function() c("PGHOST", "PGPORT", "PGDATABASE", "PGUSER", "PGPASSWORD",
    "CDM_DATABASE_SCHEMA", "DBMS", "DB_SERVER", "DB_PORT", "DB_DATABASE", "DB_USER", "DB_PASSWORD",
    "DB_ENCRYPT", "DB_TRUST_SERVER_CERTIFICATE")

fp_read_connection_values <- function(path, yuhs = FALSE) {
    keys <- if (yuhs) c("DBMS", "DB_SERVER", "DB_PORT", "DB_DATABASE", "DB_USER", "DB_PASSWORD", "CDM_DATABASE_SCHEMA") else
        c("PGHOST", "PGPORT", "PGDATABASE", "PGUSER", "PGPASSWORD", "CDM_DATABASE_SCHEMA")
    # A process must not silently inherit another hospital's connection values.
    Sys.unsetenv(fp_connection_keys())
    if (!file.exists(path) || !readRenviron(path)) stop("Cannot read site settings: ", path)
    values <- as.list(Sys.getenv(keys))
    names(values) <- keys
    missing <- keys[!nzchar(unlist(values))]
    if (length(missing)) stop("Missing connection fields: ", paste(missing, collapse = ", "))
    host <- values[[if (yuhs) "DB_SERVER" else "PGHOST"]]
    if (identical(host, "host.docker.internal"))
        stop("Replace the Docker host alias with a database IP/DNS reachable from Windows")
    port <- values[[if (yuhs) "DB_PORT" else "PGPORT"]]
    if (!grepl("^[0-9]+$", port) || as.numeric(port) < 1 || as.numeric(port) > 65535)
        stop("Invalid database port")
    if (yuhs) {
        if (values$DBMS != "sql server") stop("YUHS requires DBMS='sql server'")
        if (!grepl("^[A-Za-z0-9_.-]+$", host)) stop("DB_SERVER must be a host/IP without JDBC properties or a port")
        if (!grepl("^[A-Za-z_][A-Za-z0-9_]*$", values$DB_DATABASE) ||
            !grepl("^[A-Za-z_][A-Za-z0-9_]*[.][A-Za-z_][A-Za-z0-9_]*$", values$CDM_DATABASE_SCHEMA))
            stop("YUHS requires DB_DATABASE and a database.schema CDM_DATABASE_SCHEMA")
        if (strsplit(values$CDM_DATABASE_SCHEMA, ".", fixed = TRUE)[[1]][1] != values$DB_DATABASE)
            stop("CDM_DATABASE_SCHEMA must be in DB_DATABASE")
    }
    values
}

fp_read_connection <- function(path) {
    values <- fp_read_connection_values(path)
    # Capture literal values: DatabaseConnector stores lazy credential closures.
    DatabaseConnector::createConnectionDetails(dbms = "postgresql",
        server = paste(values$PGHOST, values$PGDATABASE, sep = "/"),
        port = as.integer(values$PGPORT), user = values$PGUSER, password = values$PGPASSWORD)
}

fp_read_yuhs_connection <- function(path) {
    values <- fp_read_connection_values(path, yuhs = TRUE)
    tls_value <- function(name, default) {
        value <- tolower(trimws(Sys.getenv(name, unset = default)))
        if (!value %in% c("true", "false")) stop(name, " must be true or false")
        value
    }
    encrypt <- tls_value("DB_ENCRYPT", "true")
    trust <- tls_value("DB_TRUST_SERVER_CERTIFICATE", "false")
    driver <- file.path(Sys.getenv("DATABASECONNECTOR_JAR_FOLDER"), "sqlserver")
    if (!length(list.files(driver, "^mssql-jdbc.*[.]jar$"))) stop("Offline SQL Server JDBC missing")
    DatabaseConnector::createConnectionDetails(dbms = "sql server", server = values$DB_SERVER,
        port = as.integer(values$DB_PORT), user = values$DB_USER, password = values$DB_PASSWORD,
        extraSettings = paste0("databaseName=", values$DB_DATABASE,
            ";encrypt=", encrypt, ";trustServerCertificate=", trust), pathToDriver = driver)
}

fp_check_yuhs_sites <- function(config) {
    ids <- unlist(config$careSites[config$sites], use.names = FALSE)
    if (length(ids) != length(config$sites) || anyNA(ids) || anyDuplicated(ids) ||
        any(!grepl("^[0-9]+$", as.character(ids))) || any(as.numeric(ids) < 1) ||
        any(as.numeric(ids) > .Machine$integer.max)) stop("Distinct positive CARE_SITE_IDs are required for every YUHS site")
    invisible(ids)
}

fp_attach_person_ids <- function(population, cohorts) {
    # CohortMethod::createStudyPopulation deliberately removes personId.
    # Restore it only in the hospital-local result, using rowId (never row order).
    if (!all(c("rowId", "personId") %in% names(cohorts)) || anyNA(cohorts$rowId) ||
        anyDuplicated(cohorts$rowId)) stop("Invalid local cohort/person mapping")
    index <- match(population$rowId, cohorts$rowId)
    if (anyNA(index) || anyNA(cohorts$personId[index]) || anyDuplicated(cohorts$personId[index]))
        stop("Missing or duplicate local PERSON_ID mapping")
    population$personId <- as.character(cohorts$personId[index])
    population
}

fp_check_synthetic_yuhs <- function(config) {
    if (!identical(config$dataset, "YUHS") || !identical(config$study, "ppi") ||
        !identical(config$scenario, "default") ||
        !setequal(config$sites, c("severance", "gangnam", "yongin")) || length(config$sites) != 3L)
        stop("Synthetic YUHS requires three default sites, Study=ppi and Scenario=default")
    fp_check_yuhs_sites(config)
    for (site in c("severance", "gangnam", "yongin"))
        if (config$careSites[[site]] != match(site, c("severance", "gangnam", "yongin")))
            stop("Synthetic YUHS requires CARE_SITE_IDs 1, 2, 3")
    invisible(TRUE)
}

fp_control <- function(config) {
    Cyclops::createControl(convergenceType = "lange", seed = 1L, threads = 1L,
        noiseLevel = "silent", maxIterations = 5000L, tolerance = config$tolerance,
        blockSize = config$blockSize, alpha = config$alpha)
}
