# SQL Server only; callers provide one trusted, already prepared SELECT.
# Keep DatabaseConnector's fetching, numeric conversion, batch size and column
# naming, but do not invoke its render/split wrappers on an active connection.
.fpsCheckExactInteger64 <- function(data) {
    # DatabaseConnector's historical normalization uses doubles. Preserve that
    # schema only where conversion is exact, rather than silently rounding an
    # ODBC bigint patient/visit/covariate key (2^53 + 1 rounds to 2^53).
    for (value in data) {
        if (!inherits(value, "integer64")) next
        digits <- sub("^-", "", as.character(value))
        digits <- digits[!is.na(digits)]
        tooLarge <- nchar(digits) > 16L |
            (nchar(digits) == 16L & digits > "9007199254740992")
        if (any(tooLarge))
            stop("SQL Server bigint exceeds the exact numeric range of this analysis; extraction stopped before ID conversion")
    }
    invisible(data)
}

.fpsSqlServerFetchBatchSize <- function(connection, jdbcSize =
        utils::getFromNamespace("DBFETCH_BATCH_SIZE", "DatabaseConnector")) {
    # DatabaseConnector's -2 sentinel means "a JVM-sized batch" only on its
    # JDBC result class. Native DBI drivers require a positive row count.
    if (methods::is(connection, "DatabaseConnectorDbiConnection")) return(50000L)
    jdbcSize
}

.fpsSqlServerFetchApi <- function(connection = NULL) {
    list(send = DBI::dbSendQuery, fetch = DBI::dbFetch, done = DBI::dbHasCompleted,
        clear = DBI::dbClearResult,
        batchSize = .fpsSqlServerFetchBatchSize(connection),
        normalize = function(data) {
            if (isTRUE(getOption("databaseConnectorInteger64AsNumeric", TRUE)))
                .fpsCheckExactInteger64(data)
            convert <- utils::getFromNamespace("convertAllInteger64ToNumeric", "DatabaseConnector")
            data <- convert(data, getOption("databaseConnectorIntegerAsNumeric", TRUE),
                getOption("databaseConnectorInteger64AsNumeric", TRUE))
            # This public naming function is pure R, with no JVM calls.
            names(data) <- SqlRender::snakeCaseToCamelCase(names(data))
            data
        })
}

.fpsFetchSqlServer <- function(connection, sql, consume = NULL, api = .fpsSqlServerFetchApi(connection)) {
    if (!is.character(sql) || length(sql) != 1L || is.na(sql) || !nzchar(trimws(sql)))
        stop("Expected one prepared SQL Server SELECT")
    result <- api$send(connection, sql)
    completed <- FALSE
    on.exit({
        if (completed) api$clear(result) else try(api$clear(result), silent = TRUE)
    })
    if (is.null(consume)) {
        answer <- api$normalize(api$fetch(result, n = -1L))
    } else {
        first <- TRUE
        # Preserve typed empty tables and bounded batches: JDBC uses its VM
        # batch sentinel; ODBC uses 50,000 rows. Never fetch all covariates in R.
        while (first || !api$done(result)) {
            batch <- api$normalize(api$fetch(result, n = api$batchSize))
            consume(batch, first)
            first <- FALSE
        }
        answer <- NULL
    }
    completed <- TRUE
    answer
}

.fpsQuerySqlServer <- function(connection, sql) .fpsFetchSqlServer(connection, sql)

.fpsCopySqlServerToAndromeda <- function(connection, sql, andromeda, table) {
    if (!inherits(andromeda, "Andromeda")) stop("Expected a local Andromeda object")
    .fpsFetchSqlServer(connection, sql, consume = function(batch, first) {
        if (first) andromeda[[table]] <<- batch
        else Andromeda::appendToTable(andromeda[[table]], batch)
    })
    invisible(andromeda)
}
