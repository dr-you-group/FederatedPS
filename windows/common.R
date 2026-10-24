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
    if (!identical(getFromNamespace(".protocolVersion", "FederatedPs"), lock$protocol))
        stop("FederatedPs protocol differs from runtime-lock.json")
    jar <- Sys.getenv("DATABASECONNECTOR_JAR_FOLDER")
    if (!nzchar(jar) || !length(list.files(jar, "postgresql.*[.]jar$", ignore.case = TRUE)))
        stop("PostgreSQL JDBC driver missing from DATABASECONNECTOR_JAR_FOLDER")
    rJava::.jinit()
    if (!"ppi" %in% FederatedPs::listStudies()$study) stop("Study metadata missing")
    cat("PASS: offline R, block Cyclops, FederatedPs, JVM and JDBC\n")
    invisible(TRUE)
}

fp_read_connection <- function(path) {
    keys <- c("PGHOST", "PGPORT", "PGDATABASE", "PGUSER", "PGPASSWORD", "CDM_DATABASE_SCHEMA")
    # A process must not silently inherit another hospital's connection values.
    Sys.unsetenv(keys)
    if (!file.exists(path) || !readRenviron(path)) stop("Cannot read site settings: ", path)
    values <- Sys.getenv(keys)
    missing <- keys[!nzchar(values)]
    if (length(missing)) stop("Missing connection fields: ", paste(missing, collapse = ", "))
    if (identical(Sys.getenv("PGHOST"), "host.docker.internal"))
        stop("Replace the Docker host alias with a database IP/DNS reachable from Windows")
    port <- suppressWarnings(as.integer(Sys.getenv("PGPORT")))
    if (is.na(port) || port < 1L || port > 65535L) stop("Invalid PGPORT")
    DatabaseConnector::createConnectionDetails(dbms = "postgresql",
        server = paste(Sys.getenv("PGHOST"), Sys.getenv("PGDATABASE"), sep = "/"),
        port = port, user = Sys.getenv("PGUSER"), password = Sys.getenv("PGPASSWORD"))
}

fp_control <- function(config) {
    Cyclops::createControl(convergenceType = "lange", seed = 1L, threads = 1L,
        noiseLevel = "silent", maxIterations = 5000L, tolerance = config$tolerance,
        blockSize = config$blockSize, alpha = config$alpha)
}
