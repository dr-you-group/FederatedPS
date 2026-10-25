# Diagnostics remain local to the role. They never enter the federated exchange.
# Callers outside the Windows launcher keep SQL logging and short-query guards off.
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

# Standard JDBC interfaces only. This intentionally reads at most two small
# rows, sufficient to validate SELECT 1 / @@SPID and uniqueness of CARE_SITE.
# Network timeout is scoped to this operation and restored before bulk work.
.fpsJdbcSmallQuery <- function(jConnection, sql, columns, timeout,
                               jcall = rJava::.jcall,
                               nullExecutor = rJava::.jnull("java/util/concurrent/Executor")) {
    timeout <- .fpsSmallQueryTimeout(timeout)
    label <- if (identical(names(columns), c("ok", "sessionId"))) "Connection self-check" else "CARE_SITE lookup"
    call <- function(object, type, method, ...) {
        phase <- paste0(label, ": JDBC ", method,
            if (identical(method, "close")) " (resource cleanup)" else "")
        .fpsDbStartupState(phase)
        .fpsDbOperation(phase, jcall(object, type, method, ...), completed = 0)
    }
    statement <- result <- NULL
    originalNetworkTimeout <- call(jConnection, "I", "getNetworkTimeout")
    changedNetworkTimeout <- FALSE
    completed <- FALSE
    on.exit({
        cleanupError <- NULL
        cleanup <- function(expr) tryCatch(force(expr), error = function(e) {
            if (is.null(cleanupError)) cleanupError <<- e
        })
        if (!is.null(result)) cleanup(call(result, "V", "close"))
        if (!is.null(statement)) cleanup(call(statement, "V", "close"))
        if (changedNetworkTimeout)
            cleanup(call(jConnection, "V", "setNetworkTimeout", nullExecutor,
                          as.integer(originalNetworkTimeout)))
        # Never leave a short socket timeout on a healthy connection used for
        # bulk extraction. On failure preserve the original query exception.
        if (completed && !is.null(cleanupError)) stop(cleanupError)
    })
    call(jConnection, "V", "setNetworkTimeout", nullExecutor, as.integer((timeout + 15L) * 1000L))
    changedNetworkTimeout <- TRUE
    statement <- call(jConnection, "Ljava/sql/Statement;", "createStatement")
    call(statement, "V", "setQueryTimeout", timeout)
    call(statement, "V", "setMaxRows", 2L)
    result <- call(statement, "Ljava/sql/ResultSet;", "executeQuery", sql)
    values <- lapply(columns, function(type) if (type == "integer") integer() else character())
    while (isTRUE(call(result, "Z", "next"))) {
        for (i in seq_along(columns)) {
            value <- if (columns[[i]] == "integer") call(result, "I", "getInt", as.integer(i)) else
                call(result, "S", "getString", as.integer(i))
            if (isTRUE(call(result, "Z", "wasNull"))) value <- if (columns[[i]] == "integer") NA_integer_ else NA_character_
            values[[i]] <- c(values[[i]], value)
        }
        # JDBC setMaxRows enforces the bound; this also guards unusual drivers.
        if (length(values[[1L]]) >= 2L) break
    }
    answer <- as.data.frame(values, stringsAsFactors = FALSE)
    completed <- TRUE
    answer
}

.fpsSmallSqlQuery <- function(connection, sql, columns) {
    timeout <- getOption("FederatedPs.smallQueryTimeoutSeconds")
    if (is.null(timeout))
        return(DatabaseConnector::querySql(connection, sql, snakeCaseToCamelCase = TRUE))
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
