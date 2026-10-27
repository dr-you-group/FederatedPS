source("R/Progress.R")
source("R/DbDiagnostics.R")
source("R/SqlProgress.R")
source("windows/progress.R")
root <- tempfile("sql-progress-"); dir.create(root)
events <- list()
options(FederatedPs.sqlDiagnosticsDirectory = file.path(root, "sql"),
    FederatedPs.dbOperationIndex = 0L,
    FederatedPs.progress = function(x) events[[length(events) + 1L]] <<- x)
statements <- c("SELECT 1 AS person_id INTO #fps_membership", "CREATE UNIQUE CLUSTERED INDEX ix_membership ON #fps_membership(person_id)")
calls <- character(); commits <- 0L
answer <- .fpsRunSqlStatements(statements, "fixture", 1,
    execute = function(sql) {
        event <- tail(events, 1)[[1]]
        stopifnot(event$operation$status == "started", file.exists(event$operation$sqlFile),
            identical(paste(readLines(event$operation$sqlFile), collapse = "\n"), sql))
        calls <<- c(calls, sql)
        if (length(calls) == 1) 123 else -1
    }, finish = function() { commits <<- commits + 1L })
stopifnot(identical(calls, statements), commits == 1L, identical(answer, c(123, -1)),
    events[[1]]$operation$statementsCompleted == 0,
    events[[2]]$operation$statementsCompleted == 1, events[[2]]$operation$rowsAffected == 123,
    events[[3]]$operation$statementsCompleted == 1,
    is.na(events[[4]]$operation$rowsAffected), events[[4]]$operation$statementsCompleted == 2)
original <- simpleError("real driver failure")
calls <- character(); commits <- 0L
error <- tryCatch(.fpsRunSqlStatements(c(statements,"DROP TABLE #fps_membership"), "failure", 1,
    execute = function(sql) {calls <<- c(calls,sql); if(length(calls) == 2L) stop(original); 1},
    finish = function() {commits <<- commits + 1L}), error = identity)
stopifnot(identical(error, original), length(calls) == 2L, commits == 0L,
    tail(events,1)[[1]]$operation$status == "failed",
    tail(events,1)[[1]]$operation$statementsCompleted == 1)
error <- tryCatch(.fpsRunSqlStatements(statements, "commit-failure", 1,
    execute = function(sql) 1, finish = function() stop(original)), error = identity)
stopifnot(identical(error, original), tail(events,1)[[1]]$operation$status == "failed")
stopifnot(.fpsSqlStatementLabel("SELECT x INTO #fps_exposure FROM x") == "Populate #fps_exposure",
    .fpsSqlStatementLabel("CREATE UNIQUE CLUSTERED INDEX ix_v ON #v(id)") == "Create index ix_v")
invisible(.fpsRunSqlStatements(rep("SELECT 1",4),"SitePartition.sql",1,function(sql) 1))
stopifnot(any(vapply(events, function(x) grepl("Find study-exposed patients",x$detail), TRUE)))
options(FederatedPs.progressContext = list(site="17",databaseHash="invented",limit=200))
historyDir <- file.path(root,"history")
h <- fp_progress_history(historyDir)
start <- events[[1]]; start$operation$elapsedSeconds <- 0
stopifnot(is.null(h(start)$operation$historyEstimate))
done <- start; done$operation$status <- "completed"; done$operation$elapsedSeconds <- 120
invisible(h(done))
again <- start; again$operation$id <- "new-request"
estimated <- h(again)
stopifnot(estimated$operation$historyEstimate$seconds == 120, estimated$operation$historyEstimate$samples == 1)
failed <- again; failed$operation$status <- "failed"; failed$operation$elapsedSeconds <- 900
invisible(h(failed))
stopifnot(length(list.files(historyDir,recursive=TRUE,pattern="[.]rds$")) == 1)
options(FederatedPs.progressContext = list(site="42",databaseHash="invented",limit=200))
stopifnot(is.null(h(again)$operation$historyEstimate))
options(FederatedPs.progressContext = list(site="17",databaseHash="invented",limit=100))
stopifnot(is.null(h(again)$operation$historyEstimate))
options(FederatedPs.progressContext = list(site="17",databaseHash="invented",limit=200))
bad <- file.path(dirname(list.files(historyDir,recursive=TRUE,full.names=TRUE)[1]),"corrupt.rds")
writeLines("incomplete timing file",bad)
stopifnot(h(again)$operation$historyEstimate$seconds == 120)
# Streaming JSON and site snapshots survive history failure and contain counts,
# not SQL text or returned clinical rows.
out <- file.path(root,"baselines");dir.create(out)
observer <- fp_start_progress(out,"baselines",historyDirectory=historyDir)
again$siteId <- "17";again$siteState <- "extracting"
observer(again)
line <- jsonlite::fromJSON(readLines(file.path(out,"progress.jsonl"))[1])
snap <- jsonlite::fromJSON(file.path(out,"sites/17.json"))
stopifnot(line$siteId == "17",snap$operation$id == "new-request",
    line$operation$historyEstimate$seconds == 120,
    !grepl("SELECT 1 AS", readLines(file.path(out,"progress.jsonl"))[1], fixed=TRUE))
blocked <- file.path(root,"not-a-directory");writeLines("x",blocked)
h <- fp_progress_history(blocked)
stopifnot(is.list(h(start)),is.list(suppressWarnings(suppressMessages(h(done)))))
options(FederatedPs.progress=NULL,FederatedPs.progressContext=NULL)
unlink(root,recursive=TRUE)
cat("PASS: SQL order, before-send events, affected-row bounds, single final commit, failure preservation, matched timing history, site snapshots\n")
