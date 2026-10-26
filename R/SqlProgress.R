# Execute the same SqlRender statements as DatabaseConnector::executeSql's
# default (runAsBatch=FALSE) path. Keep its single final JDBC commit when
# auto-commit is off; calling executeSql once per statement would change that.
.fpsSqlStatementLabel <- function(sql) {
    marker <- regmatches(sql, regexec("-- fps-step: ([^\r\n]+)", sql))[[1L]]
    if (length(marker) > 1L) return(trimws(marker[2]))
    plain <- gsub("/\\*.*?\\*/", " ", sql, perl = TRUE)
    plain <- gsub("--[^\r\n]*", " ", plain)
    temp <- function(pattern) {
        match <- regmatches(plain, regexec(pattern, plain, ignore.case = TRUE, perl = TRUE))[[1L]]
        if (length(match) > 1L) match[2] else NULL
    }
    name <- temp("\\bCREATE\\s+(?:UNIQUE\\s+)?(?:CLUSTERED\\s+|NONCLUSTERED\\s+)?INDEX\\s+([A-Za-z0-9_]+)")
    if (!is.null(name)) return(paste("Create index", name))
    name <- temp("\\bINTO\\s+(#[A-Za-z0-9_]+)")
    if (!is.null(name)) return(paste("Populate", name))
    name <- temp("\\b(?:UPDATE|DELETE\\s+FROM|TRUNCATE\\s+TABLE|DROP\\s+TABLE)\\s+(#[A-Za-z0-9_]+)")
    if (!is.null(name)) return(paste("Modify temporary table", name))
    # No arbitrary SQL/literals in console events. The full SQL stays local.
    "Execute rendered cohort statement (see SQL file)"
}

.fpsRunSqlStatements <- function(statements, label, completed, execute, finish = function() NULL) {
    if (!length(statements)) return(invisible(numeric()))
    labels <- vapply(statements, .fpsSqlStatementLabel, "")
    # Keep meaningful labels when SqlRender strips template comments.
    if (identical(label, "SitePartition.sql") && length(statements) == 4L)
        labels <- c("Find study-exposed patients at this site (drug and visit join)",
            "Index study-exposed candidates", "Exclude visits to every other positive institution",
            "Index exclusive study candidates")
    if (identical(label, "SiteVisits.sql") && length(statements) == 3L)
        labels <- c("Copy all visits of prepared patients (after early default cap)",
            "Index visits by visit_occurrence_id", "Index visits by person_id")
    batchId <- sprintf("%04d-%s", getOption("FederatedPs.dbOperationIndex", 0L) + 1L,
        gsub("[^A-Za-z0-9_-]+", "-", label))
    batchStartedUtc <- format(Sys.time(), "%Y-%m-%dT%H:%M:%OS3Z", tz = "UTC")
    .fpsDiagnosticWrite(paste0(batchId, "-plan.tsv"), c("statement\ttotal\twork",
        paste(seq_along(statements), length(statements), labels, sep = "\t")))
    result <- numeric()
    for (i in seq_along(statements)) {
        info <- list(batch = label, batchId = batchId, batchStartedUtc = batchStartedUtc,
            statementIndex = i, statementCount = length(statements), statementLabel = labels[i])
        value <- .fpsDbOperation(sprintf("%s SQL %d/%d: %s", label, i, length(statements), labels[i]),
            execute(statements[i]), sql = statements[i], completed = completed, statement = info)
        result <- c(result, value)
    }
    .fpsDbOperation(paste(label, "finalize SQL batch"), finish(), completed = completed)
    invisible(result)
}

.fpsJdbcExecutePrepared <- function(jConnection, sql, jcall = rJava::.jcall) {
    statement <- jcall(jConnection, "Ljava/sql/Statement;", "createStatement")
    completed <- FALSE
    on.exit({
        if (completed) jcall(statement, "V", "close") else try(jcall(statement, "V", "close"), silent = TRUE)
    })
    # This is one already-split statement. DatabaseConnector's dbExecute would
    # call SqlRender::splitSql again inside the live JDBC process.
    result <- jcall(statement, "J", "executeLargeUpdate", as.character(sql))
    completed <- TRUE
    result
}

.fpsExecuteSql <- function(connection, sql, label, completed, statements = NULL) {
    if (!DBI::dbIsValid(connection)) stop("Connection is closed")
    if (is.null(statements)) statements <- SqlRender::splitSql(sql)
    .fpsRunSqlStatements(statements, label, completed,
        execute = function(statement) {
            if (inherits(connection, "DatabaseConnectorJdbcConnection"))
                .fpsJdbcExecutePrepared(connection@jConnection, statement)
            else DBI::dbExecute(connection, statement)
        },
        finish = function() {
            if (inherits(connection, "DatabaseConnectorJdbcConnection") &&
                !rJava::.jcall(connection@jConnection, "Z", "getAutoCommit"))
                rJava::.jcall(connection@jConnection, "V", "commit")
            invisible(NULL)
        })
}
