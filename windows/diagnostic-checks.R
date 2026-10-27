# Read-only diagnostic work is separate from process shutdown. A completion
# receipt means these checks and explicit disconnect returned successfully; only
# the launcher can confirm that the R process has actually exited.
fp_diagnostic_checks <- function(details, careSites, schema, connect, disconnect,
                                 smallQuery, operation,
                                 report = function(...) { cat(...); flush(stdout()) }) {
    ids <- unlist(careSites, use.names = FALSE)
    if (!length(ids) || is.null(names(careSites)) || any(!nzchar(names(careSites))) ||
        anyDuplicated(names(careSites)) || !is.numeric(ids) || anyNA(ids) ||
        any(!is.finite(ids)) || any(ids < 1 | ids > .Machine$integer.max | ids != floor(ids)) ||
        anyDuplicated(ids)) stop("Distinct named positive CARE_SITE IDs are required")
    if (!is.character(schema) || length(schema) != 1L || is.na(schema) ||
        !grepl("^[A-Za-z_][A-Za-z0-9_]*[.][A-Za-z_][A-Za-z0-9_]*$", schema))
        stop("Expected a database.schema CDM schema")
    ids <- as.integer(ids)
    connection <- operation("Opening diagnostic connection", connect(details), stage = "diagnostic")
    disconnectAttempted <- FALSE
    on.exit({
        # A query/validation error remains primary, even if cleanup also fails.
        # An explicit close error below is never swallowed or labeled success.
        if (!disconnectAttempted)
            try(operation("Closing diagnostic connection after failure", disconnect(connection),
                          stage = "diagnostic"), silent = TRUE)
    }, add = TRUE)
    sql <- "SELECT 1 AS ok, @@SPID AS session_id"
    answer <- operation("Testing SELECT 1 and session ID", smallQuery(connection, sql,
        c(ok = "integer", sessionId = "integer")), sql = sql, stage = "diagnostic")
    if (nrow(answer) != 1L || !isTRUE(answer$ok == 1L) ||
        length(answer$sessionId) != 1L || is.na(answer$sessionId))
        stop("Expected SELECT 1 and one SQL Server session ID")
    report("CHECK OK: SELECT 1; SQL Server session ID:", answer$sessionId, "\n")
    for (i in seq_along(ids)) {
        role <- names(careSites)[[i]]
        id <- ids[[i]]
        sql <- sprintf(paste("SELECT TOP (2) care_site_id",
            "FROM %s.CARE_SITE WHERE care_site_id = %d"), schema, id)
        answer <- operation(paste("CARE_SITE lookup:", role), smallQuery(connection, sql,
            c(careSiteId = "integer")),
            sql = sql, stage = "diagnostic")
        returnedId <- if (is.data.frame(answer)) answer[["careSiteId"]] else NULL
        if (!is.data.frame(answer) || nrow(answer) != 1L || !is.numeric(returnedId) ||
            length(returnedId) != 1L || is.na(returnedId) ||
            !is.finite(returnedId) || returnedId != id)
            stop("Expected one non-NULL matching numeric CARE_SITE row for ", role)
        report("CHECK OK:", role, "CARE_SITE", id, "returned one row\n")
    }
    disconnectAttempted <- TRUE
    operation("Closing diagnostic connection", disconnect(connection), stage = "diagnostic")
    list(select1 = TRUE, careSites = ids, disconnectComplete = TRUE)
}

fp_write_diagnostic_status <- function(output, token, checks,
                                       writeJson = jsonlite::write_json,
                                       rename = file.rename) {
    if (!is.character(token) || length(token) != 1L || is.na(token) ||
        !nzchar(token) || nchar(token) > 128L) stop("Missing diagnostic run token")
    if (!isTRUE(checks$select1) || !isTRUE(checks$disconnectComplete) ||
        !length(checks$careSites)) stop("Cannot record incomplete diagnostic checks")
    path <- file.path(output, "diagnostic-status.json")
    if (file.exists(path)) stop("Diagnostic status already exists; use a fresh diagnostic directory")
    pending <- tempfile(".diagnostic-status-", tmpdir = output, fileext = ".json")
    on.exit(unlink(pending), add = TRUE)
    status <- list(schema = 1L, state = "checks-complete", token = token, pid = Sys.getpid(),
        checks = list(select1 = TRUE, careSites = as.list(checks$careSites)),
        disconnectComplete = TRUE)
    writeJson(status, pending, auto_unbox = TRUE, pretty = TRUE)
    if (!isTRUE(rename(pending, path))) stop("Could not publish diagnostic completion status")
    invisible(path)
}
