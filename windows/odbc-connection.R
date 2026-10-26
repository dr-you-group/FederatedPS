# Native SQL Server connection helpers. Sourcing this file does not load Java,
# DatabaseConnector, odbc, or a database connection. The standalone ODBC probe
# and the analysis launcher use the same endpoint/TLS/credential mapping.
fp_odbc_settings_keys <- function() c("DBMS", "DB_SERVER", "DB_PORT", "DB_DATABASE",
    "DB_USER", "DB_PASSWORD", "CDM_DATABASE_SCHEMA", "DB_BACKEND", "DB_ODBC_DRIVER",
    "DB_ENCRYPT", "DB_TRUST_SERVER_CERTIFICATE", "DB_JDBC_JAR", "DATABASECONNECTOR_JAR_FOLDER")

fp_odbc_file_values <- function(path) {
    keys <- fp_odbc_settings_keys()
    previous <- Sys.getenv(keys, unset = NA_character_)
    on.exit({
        Sys.unsetenv(keys)
        present <- !is.na(previous)
        if (any(present)) do.call(Sys.setenv, as.list(previous[present]))
    })
    Sys.unsetenv(keys)
    if (!file.exists(path) || !readRenviron(path)) stop("Cannot read YUHS settings file", call. = FALSE)
    as.list(Sys.getenv(keys))
}

fp_resolve_db_backend <- function(path = NULL, override = NULL) {
    value <- override
    if (is.null(value) || identical(value, ""))
        value <- Sys.getenv("FEDERATEDPS_DB_BACKEND", unset = "")
    if (identical(value, "") && !is.null(path) && file.exists(path))
        value <- fp_odbc_file_values(path)$DB_BACKEND
    if (is.null(value) || identical(value, "")) value <- "jdbc"
    if (!is.character(value) || length(value) != 1L || is.na(value) ||
        !tolower(trimws(value)) %in% c("jdbc", "odbc"))
        stop("DB backend must be jdbc or odbc", call. = FALSE)
    tolower(trimws(value))
}

fp_odbc_validate_settings <- function(values) {
    required <- c("DBMS", "DB_SERVER", "DB_PORT", "DB_DATABASE", "DB_USER", "DB_PASSWORD", "CDM_DATABASE_SCHEMA")
    valid <- vapply(required, function(key) {
        x <- values[[key]]
        is.character(x) && length(x) == 1L && !is.na(x) && nzchar(x)
    }, TRUE)
    if (!all(valid)) stop("Missing connection fields: ", paste(required[!valid], collapse = ", "), call. = FALSE)
    if (!identical(values$DBMS, "sql server")) stop("YUHS requires DBMS='sql server'", call. = FALSE)
    if (!grepl("^[A-Za-z0-9_.-]+$", values$DB_SERVER) || identical(values$DB_SERVER, "host.docker.internal"))
        stop("DB_SERVER must be a reachable host/IP without a JDBC URL, port or properties", call. = FALSE)
    if (!grepl("^[0-9]+$", values$DB_PORT) || as.numeric(values$DB_PORT) < 1 || as.numeric(values$DB_PORT) > 65535)
        stop("Invalid database port", call. = FALSE)
    if (!grepl("^[A-Za-z_][A-Za-z0-9_]*$", values$DB_DATABASE) ||
        !grepl("^[A-Za-z_][A-Za-z0-9_]*[.][A-Za-z_][A-Za-z0-9_]*$", values$CDM_DATABASE_SCHEMA) ||
        strsplit(values$CDM_DATABASE_SCHEMA, ".", fixed = TRUE)[[1L]][1L] != values$DB_DATABASE)
        stop("YUHS requires database.schema CDM_DATABASE_SCHEMA in DB_DATABASE", call. = FALSE)
    for (key in c("DB_ENCRYPT", "DB_TRUST_SERVER_CERTIFICATE")) {
        value <- values[[key]]
        if (is.null(value) || identical(value, "")) value <- if (key == "DB_ENCRYPT") "true" else "false"
        if (!is.character(value) || length(value) != 1L || is.na(value) || !tolower(trimws(value)) %in% c("true", "false"))
            stop(key, " must be true or false", call. = FALSE)
        values[[key]] <- tolower(trimws(value))
    }
    driver <- values$DB_ODBC_DRIVER
    if (is.null(driver) || identical(driver, "")) driver <- "ODBC Driver 18 for SQL Server"
    if (!is.character(driver) || length(driver) != 1L || is.na(driver) ||
        !driver %in% c("ODBC Driver 17 for SQL Server", "ODBC Driver 18 for SQL Server"))
        stop("DB_ODBC_DRIVER must name Microsoft ODBC Driver 17 or 18 for SQL Server", call. = FALSE)
    values$DB_ODBC_DRIVER <- driver
    values
}

fp_odbc_read_settings <- function(path) fp_odbc_validate_settings(fp_odbc_file_values(path))

fp_odbc_require <- function(driver, .require = requireNamespace, .drivers = NULL) {
    for (pkg in c("DBI", "odbc", "bit64"))
        if (!.require(pkg, quietly = TRUE)) stop("Missing/unloadable package ", pkg,
            "; run APPLY_ODBC.ps1 from the offline ODBC update", call. = FALSE)
    if (is.null(.drivers)) .drivers <- odbc::odbcListDrivers
    available <- .drivers()
    if (!"name" %in% names(available) || !driver %in% available$name)
        stop("Required x64 SQL Server ODBC driver is missing; run APPLY_ODBC.ps1", call. = FALSE)
    invisible(TRUE)
}

fp_odbc_quote <- function(value, .quote = odbc::quote_value) {
    # SQL Server supports braced values. Avoid the ambiguous closing-brace
    # case using odbc's documented quote helper; never concatenate raw secrets.
    if (!grepl("}", value, fixed = TRUE)) return(I(paste0("{", value, "}")))
    if (grepl("'", value, fixed = TRUE) && grepl('"', value, fixed = TRUE))
        stop("A connection value has an unsupported combination of closing brace and quote characters", call. = FALSE)
    .quote(value)
}

fp_odbc_connect_args <- function(values, loginTimeout = 30, .quote = fp_odbc_quote) {
    values <- fp_odbc_validate_settings(values)
    if (!is.numeric(loginTimeout) || length(loginTimeout) != 1L || is.na(loginTimeout) ||
        !is.finite(loginTimeout) || loginTimeout < 1 || loginTimeout != floor(loginTimeout) || loginTimeout > 2147483647)
        stop("ODBC login timeout must be a positive integer", call. = FALSE)
    list(driver = .quote(values$DB_ODBC_DRIVER),
        server = .quote(paste0("tcp:", values$DB_SERVER, ",", values$DB_PORT)),
        database = .quote(values$DB_DATABASE), uid = .quote(values$DB_USER), pwd = .quote(values$DB_PASSWORD),
        Encrypt = if (values$DB_ENCRYPT == "true") "yes" else "no",
        TrustServerCertificate = if (values$DB_TRUST_SERVER_CERTIFICATE == "true") "yes" else "no",
        # Keep one physical session for all #temporary tables. Report the first
        # connection failure instead of the driver's default idle reconnect.
        ConnectRetryCount = "0", APP = "FederatedPS", bigint = "integer64", timeout = as.integer(loginTimeout),
        # Wide SQL Server strings are converted by the native driver; odbc
        # returns UTF-8. Do not reinterpret arbitrary ANSI columns as UTF-8.
        interruptible = FALSE)
}

fp_odbc_connect <- function(values, loginTimeout = 30) {
    values <- fp_odbc_validate_settings(values)
    fp_odbc_require(values$DB_ODBC_DRIVER)
    do.call(DBI::dbConnect, c(list(drv = odbc::odbc()), fp_odbc_connect_args(values, loginTimeout)))
}

fp_odbc_connection_details <- function(values, loginTimeout = 30) {
    values <- fp_odbc_validate_settings(values)
    fp_odbc_require(values$DB_ODBC_DRIVER)
    details <- do.call(DatabaseConnector::createDbiConnectionDetails,
        c(list(dbms = "sql server", drv = odbc::odbc()), fp_odbc_connect_args(values, loginTimeout)))
    attr(details, "FederatedPs.dbBackend") <- "odbc"
    details
}
