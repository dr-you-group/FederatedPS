# Diagnostics remain local to the role. They never enter the federated exchange.
# Callers outside the Windows launcher keep SQL logging and short-query guards off.
.fpsDbRuntimeRevision <- "jdbc-probe-5"

.fpsDiagnosticWrite <- function(name, text, append = FALSE) {
    directory <- getOption("FederatedPs.sqlDiagnosticsDirectory")
    if (is.null(directory) || !nzchar(directory)) return(invisible(FALSE))
    tryCatch({
        dir.create(directory, recursive = TRUE, showWarnings = FALSE)
        con <- file(file.path(directory, name), if (append) "at" else "wt", encoding = "UTF-8")
        on.exit(try(close(con), silent = TRUE))
        writeLines(text, con)
        flush(con)
        invisible(TRUE)
    }, error = function(e) {
        options(FederatedPs.sqlDiagnosticsDirectory = NULL)
        message("SQL diagnostic writing disabled; computation continues. Check the role output directory.")
        invisible(FALSE)
    })
}

.fpsDbOperation <- function(label, expr, sql = NULL, completed = NA_real_,
                            stage = "extract", total = 10, statement = NULL) {
    index <- getOption("FederatedPs.dbOperationIndex", 0L) + 1L
    options(FederatedPs.dbOperationIndex = index)
    operation <- sprintf("%04d-%s", index, gsub("[^A-Za-z0-9_-]+", "-", label))
    sqlFile <- NULL
    if (!is.null(sql) && .fpsDiagnosticWrite(paste0(operation, ".sql"), sql))
        sqlFile <- file.path(getOption("FederatedPs.sqlDiagnosticsDirectory"), paste0(operation, ".sql"))
    started <- proc.time()[["elapsed"]]
    startedUtc <- format(Sys.time(), "%Y-%m-%dT%H:%M:%OS3Z", tz = "UTC")
    unit <- if (stage == "extract") "extraction steps (not time)" else ""
    if (stage != "extract") total <- NA_real_
    emit <- function(status, result = NULL) {
        elapsed <- max(0, proc.time()[["elapsed"]] - started)
        detail <- if (status == "started") paste0(label, " [started]") else
            sprintf("%s [%s; %.3f s]", label, status, elapsed)
        rows <- if (is.data.frame(result)) nrow(result) else NA_real_
        affected <- if (!is.null(statement) && is.numeric(result) && length(result) == 1L &&
            is.finite(result) && result >= 0) as.numeric(result) else NA_real_
        info <- c(list(id = operation, status = status, startedUtc = startedUtc,
            elapsedSeconds = elapsed, sqlFile = sqlFile, rowsFetched = rows, rowsAffected = affected), statement)
        if (identical(stage, "sql-prepare")) {
            observer <- getOption("FederatedPs.sqlPreparationObserver")
            if (is.function(observer)) observer(c(info, list(label = label)))
        }
        if (!is.null(statement)) info$statementsCompleted <- statement$statementIndex - as.integer(status != "completed")
        .fpsProgress(stage, detail, completed, total, unit, operation = info)
        .fpsDiagnosticWrite("operations.tsv", paste(
            format(Sys.time(), "%Y-%m-%dT%H:%M:%OS3Z", tz = "UTC"), Sys.getpid(),
            operation, status, sprintf("%.3f", elapsed), sep = "\t"), append = TRUE)
    }
    emit("started")
    result <- tryCatch(force(expr), error = function(e) {
        # Keep the original error (including its class/call) for the role's stderr.
        # The event journal itself contains neither result rows nor credentials.
        emit("failed")
        stop(e)
    })
    emit("completed", result)
    result
}

.fpsSmallQueryTimeout <- function(value) {
    if (length(value) != 1L || is.na(value) || !is.numeric(value) ||
        !is.finite(value) || value != floor(value) || value < 1 || value > 86400)
        stop("Small-query timeout must be an integer from 1 to 86400 seconds")
    as.integer(value)
}

# The Windows process supervisor observes a separate startup marker. Keep this
# independent of the optional progress observer, which may disable itself.
.fpsDbStartupState <- function(phase, ready = FALSE) {
    observer <- getOption("FederatedPs.dbStartupObserver")
    if (is.function(observer)) observer(phase, ready)
    invisible(NULL)
}

# Only SELECT 1 / @@SPID and SELECT TOP (2) CARE_SITE use this path. Buffer the
# complete, bounded response before exposing rows. Bulk SELECTs remain adaptive.
# Explicitly consume EOF and the statement's terminal result: close() is not a
# substitute for reading a response and may silently discard late SQL errors.
.fpsJdbcSmallQuery <- function(jConnection, sql, columns, timeout,
                               jcall = rJava::.jcall,
                               nullExecutor = rJava::.jnull("java/util/concurrent/Executor"),
                               jcast = rJava::.jcast) {
    timeout <- .fpsSmallQueryTimeout(timeout)
    label <- if (identical(names(columns), c("ok", "sessionId"))) "Connection self-check" else "CARE_SITE lookup"
    statement <- result <- NULL
    fetched <- 0L
    exhausted <- FALSE
    firstFailure <- NULL
    journal <- function(phase, status) {
        # No SQL, connection URL, credentials or returned cell values. Record
        # the first failure BEFORE on.exit cleanup can block or change phase.
        .fpsDiagnosticWrite("probe-events.tsv", paste(
            format(Sys.time(), "%Y-%m-%dT%H:%M:%OS3Z", tz = "UTC"), Sys.getpid(),
            phase, status, fetched, exhausted,
            if (is.null(firstFailure)) "" else firstFailure, sep = "\t"), append = TRUE)
    }
    call <- function(object, type, method, ..., resource = "Connection", cell = "") {
        phase <- paste0(label, ": JDBC ", resource, ".", method,
            if (identical(method, "close")) " (resource cleanup)" else "", cell)
        .fpsDbStartupState(phase)
        journal(phase, "started")
        value <- tryCatch(.fpsDbOperation(phase, jcall(object, type, method, ...), completed = 0),
            error = function(e) {
                if (is.null(firstFailure)) {
                    firstFailure <<- phase
                    journal(phase, "first-failure")
                    message("JDBC probe FIRST FAILURE: ", phase, "\n", conditionMessage(e))
                    flush(stderr())
                } else journal(phase, "cleanup-failure")
                stop(e)
            })
        journal(phase, "completed")
        value
    }
    originalNetworkTimeout <- call(jConnection, "I", "getNetworkTimeout")
    changedNetworkTimeout <- FALSE
    completed <- FALSE
    on.exit({
        cleanupError <- NULL
        cleanup <- function(expr) tryCatch(force(expr), error = function(e) {
            if (is.null(cleanupError)) cleanupError <<- e
        })
        if (!is.null(result)) cleanup(call(result, "V", "close", resource = "ResultSet"))
        if (!is.null(statement)) cleanup(call(statement, "V", "close", resource = "Statement"))
        if (changedNetworkTimeout)
            cleanup(call(jConnection, "V", "setNetworkTimeout", nullExecutor,
                          as.integer(originalNetworkTimeout)))
        # The pinned driver's close() can suppress I/O errors. A closed
        # connection is never a successful startup check.
        if (completed && is.null(cleanupError))
            cleanup(if (isTRUE(call(jConnection, "Z", "isClosed"))) stop("JDBC connection closed during probe cleanup"))
        if (completed && !is.null(cleanupError)) stop(cleanupError)
    })
    call(jConnection, "V", "setNetworkTimeout", nullExecutor, as.integer((timeout + 15L) * 1000L))
    changedNetworkTimeout <- TRUE
    # Microsoft TYPE_SS_DIRECT_FORWARD_ONLY = 2003, CONCUR_READ_ONLY = 1007.
    # Explicit direct mode avoids a server cursor even on a cursor connection.
    statement <- call(jConnection, "Ljava/sql/Statement;", "createStatement", 2003L, 1007L)
    statement <- jcast(statement, "com/microsoft/sqlserver/jdbc/SQLServerStatement")
    call(statement, "V", "setResponseBuffering", "full", resource = "Statement")
    call(statement, "V", "setQueryTimeout", timeout, resource = "Statement")
    # Never setMaxRows: the pinned driver emits a hidden SET ROWCOUNT command.
    result <- call(statement, "Ljava/sql/ResultSet;", "executeQuery", sql, resource = "Statement")
    values <- lapply(columns, function(type) if (type == "integer") integer() else character())
    while (isTRUE(call(result, "Z", "next", resource = "ResultSet"))) {
        fetched <- fetched + 1L
        if (fetched > 2L) stop("Small JDBC probe returned more than two rows; expected server-bounded SQL")
        for (i in seq_along(columns)) {
            cell <- sprintf(" [row=%d column=%d %s]", fetched, i, names(columns)[i])
            value <- if (columns[[i]] == "integer")
                call(result, "I", "getInt", as.integer(i), resource = "ResultSet", cell = cell) else
                call(result, "S", "getString", as.integer(i), resource = "ResultSet", cell = cell)
            if (isTRUE(call(result, "Z", "wasNull", resource = "ResultSet")))
                value <- if (columns[[i]] == "integer") NA_integer_ else NA_character_
            values[[i]] <- c(values[[i]], value)
        }
        # Even when TOP (2) returned two rows, read next() == FALSE. Do not
        # leave the result's completion/error tokens for ResultSet.close().
    }
    exhausted <- TRUE
    journal(paste0(label, ": response rows exhausted"), "completed")
    # JDBC next() == FALSE ends the rowset, not necessarily the entire batch.
    # getMoreResults processes its completion/error tokens before cleanup.
    if (isTRUE(call(statement, "Z", "getMoreResults", resource = "Statement")) ||
        call(statement, "I", "getUpdateCount", resource = "Statement") != -1L)
        stop("Unexpected additional result from small JDBC probe")
    answer <- as.data.frame(values, stringsAsFactors = FALSE)
    completed <- TRUE
    answer
}

# Open the connection with a short socket deadline, covering driver-internal
# setup as well as our probes. Only after the checks pass may bulk extraction
# use its longer deadline. No timeout change is sent as SQL.
.fpsSetClinicalNetworkTimeout <- function(connection, jcall = rJava::.jcall,
        nullExecutor = rJava::.jnull("java/util/concurrent/Executor")) {
    timeout <- getOption("FederatedPs.clinicalNetworkTimeoutMillis")
    if (is.null(timeout)) return(invisible(NULL))
    if (length(timeout) != 1L || !is.numeric(timeout) || is.na(timeout) ||
        timeout < 1 || timeout > .Machine$integer.max || timeout != floor(timeout))
        stop("Invalid clinical network timeout")
    .fpsDbStartupState("JDBC setNetworkTimeout for clinical extraction")
    .fpsDbOperation("JDBC setNetworkTimeout for clinical extraction",
        jcall(connection@jConnection, "V", "setNetworkTimeout", nullExecutor, as.integer(timeout)),
        completed = 0)
    invisible(NULL)
}

.fpsSmallSqlQuery <- function(connection, sql, columns) {
    timeout <- getOption("FederatedPs.smallQueryTimeoutSeconds")
    if (is.null(timeout))
        return(.fpsQuerySqlServer(connection, sql))
    if (!methods::is(connection, "DatabaseConnectorJdbcConnection"))
        stop("Bounded SQL Server checks require DatabaseConnector's JDBC connection")
    timeout <- .fpsSmallQueryTimeout(timeout)
    tryCatch(.fpsJdbcSmallQuery(connection@jConnection, sql, columns, timeout),
        error = function(e) stop(structure(list(message = conditionMessage(e),
            call = conditionCall(e), cause = e),
            class = c("fps_small_query_error", "error", "condition"))))
}

# CohortMethod SQL refers to person.person_id without an explicit alias. Keep
# that qualifier valid on case-sensitive databases after uppercasing PERSON.
.fpsUppercaseCohortTables <- function(sql, schema) {
    .validateCdmSchema(schema)
    sql <- gsub(paste0(schema, ".person"), paste0(schema, ".PERSON"), sql, fixed = TRUE)
    sql <- gsub(paste0(schema, ".observation_period"), paste0(schema, ".OBSERVATION_PERIOD"), sql, fixed = TRUE)
    escapedSchema <- gsub(".", "\\.", schema, fixed = TRUE)
    gsub(paste0("(?i)(\\bJOIN\\s+", escapedSchema, "\\.PERSON)(\\s+ON\\b)"),
         "\\1 person\\2", sql, perl = TRUE)
}
