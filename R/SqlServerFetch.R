# SQL Server only; callers provide one trusted, already prepared SELECT.
# Keep DatabaseConnector's fetching, numeric conversion, batch size and column
# naming, but do not invoke its render/split wrappers on an active connection.
.fpsSqlServerFetchApi <- function() {
    list(send = DBI::dbSendQuery, fetch = DBI::dbFetch, done = DBI::dbHasCompleted,
        clear = DBI::dbClearResult,
        batchSize = utils::getFromNamespace("DBFETCH_BATCH_SIZE", "DatabaseConnector"),
        normalize = function(data) {
            convert <- utils::getFromNamespace("convertAllInteger64ToNumeric", "DatabaseConnector")
            data <- convert(data, getOption("databaseConnectorIntegerAsNumeric", TRUE),
                getOption("databaseConnectorInteger64AsNumeric", TRUE))
            # This public naming function is pure R, with no JVM calls.
            names(data) <- SqlRender::snakeCaseToCamelCase(names(data))
            data
        })
}

.fpsFetchSqlServer <- function(connection, sql, consume = NULL, api = .fpsSqlServerFetchApi()) {
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
        # Preserve empty tables with typed columns, and keep the same bounded
        # JDBC batches as querySqlToAndromeda (never fetch all covariates in R).
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
