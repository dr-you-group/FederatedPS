# Deterministic DBI protocol tests: no SQL Server, Java or native ODBC needed.
source("R/Progress.R")
source("R/DbDiagnostics.R")
source("R/SqlServerFetch.R")

expect_error <- function(expr, pattern = "") {
    error <- tryCatch({ force(expr); NULL }, error = identity)
    stopifnot(inherits(error, "error"), grepl(pattern, conditionMessage(error)))
    error
}

fixture <- function(batches = list(data.frame(id = 2L)), fail = "", done = NULL,
                    clearValue = TRUE, validValue = TRUE) {
    e <- new.env(parent = emptyenv())
    e$calls <- character(); e$sizes <- integer(); e$i <- 0L; e$clears <- 0L
    record <- function(method) {
        e$calls <- c(e$calls, method)
        if (method %in% fail) stop(paste("fixture", method, "failure"))
    }
    e$api <- list(
        send = function(connection, sql) { record("send"); stopifnot(connection == "connection"); "result" },
        fetch = function(result, n) {
            record("fetch"); stopifnot(result == "result"); e$sizes <- c(e$sizes, n)
            e$i <- e$i + 1L; batches[[e$i]]
        },
        done = function(result) { record("done"); if (is.null(done)) e$i >= length(batches) else done[[e$i]] },
        clear = function(result) { e$clears <- e$clears + 1L; record("clear"); clearValue },
        valid = function(connection) { record("valid"); validValue })
    e
}

sql <- "SELECT TOP (2) care_site_id FROM CDM.CARE_SITE WHERE care_site_id = 2"
columns <- c(careSiteId = "integer")
probe <- function(e, cols = columns) .fpsDbiSmallQuery("connection", sql, cols, 30L, e$api)

e <- fixture()
stopifnot(identical(probe(e), data.frame(careSiteId = 2L)),
    identical(e$calls, c("send", "fetch", "done", "clear", "valid")),
    identical(e$sizes, 3L), e$clears == 1L)
# Drivers may require a final fetch to report EOF after exactly two rows.
e <- fixture(list(data.frame(id = c(2, 2)), data.frame(id = numeric())))
stopifnot(nrow(probe(e)) == 2L, identical(e$sizes, c(3L, 1L)),
    identical(e$calls, c("send", "fetch", "done", "fetch", "done", "clear", "valid")))
e <- fixture(list(data.frame(id = integer())))
stopifnot(identical(probe(e), data.frame(careSiteId = integer())), e$clears == 1L)
e <- fixture(list(data.frame(id = NA_integer_, label = "\uc5f0\uc138", missing = NA_character_)))
got <- probe(e, c(careSiteId = "integer", label = "character", missing = "character"))
stopifnot(is.na(got$careSiteId), identical(got$label, "\uc5f0\uc138"), is.na(got$missing))

for (method in c("send", "fetch", "done", "clear", "valid")) {
    e <- fixture(fail = method)
    invisible(expect_error(probe(e), paste("fixture", method, "failure")))
    stopifnot(e$clears == as.integer(method != "send"),
        sum(e$calls == "send") == 1L)
}
# The original failure survives a second exception during cleanup.
e <- fixture(fail = c("fetch", "clear"))
invisible(expect_error(probe(e), "fetch failure"))
stopifnot(e$clears == 1L, !"valid" %in% e$calls)
for (value in list(2.5, Inf, .Machine$integer.max + 1, "2", TRUE)) {
    e <- fixture(list(data.frame(id = value)))
    invisible(expect_error(probe(e), "query"))
    stopifnot(e$clears == 1L)
}
e <- fixture(list(data.frame(id = 1:3)))
invisible(expect_error(probe(e), "more than two"))
e <- fixture(list(data.frame(id = integer())), done = list(FALSE))
invisible(expect_error(probe(e), "empty batch"))
e <- fixture(list(data.frame(id = 2L, unexpected = 1L)))
invisible(expect_error(probe(e), "Unexpected columns"))
e <- fixture(clearValue = FALSE)
invisible(expect_error(probe(e), "cleanup did not succeed"))
e <- fixture(validValue = FALSE)
invisible(expect_error(probe(e), "closed during probe cleanup"))

# Native wrapper routing cannot force JDBC lazy defaults or access @jConnection.
if (!methods::isClass("DatabaseConnectorDbiConnection"))
    methods::setClass("DatabaseConnectorDbiConnection", slots = c(connection = "ANY"))
connection <- methods::new("DatabaseConnectorDbiConnection", connection = "connection")
stopifnot(identical(.fpsSqlServerFetchBatchSize(connection,
    jdbcSize = stop("JDBC batch-size default evaluated")), 50000L),
    identical(.fpsSqlServerFetchBatchSize(NULL, jdbcSize = -2L), -2L))
stream <- new.env(); stream$i <- 0L; stream$sizes <- integer(); stream$clears <- 0L
batches <- list(data.frame(rowId = 1:2, value = c(NA_real_, 4)), data.frame(rowId = 3L, value = 5))
streamApi <- list(batchSize = .fpsSqlServerFetchBatchSize(connection),
    send = function(conn, sql) { stopifnot(identical(conn, connection)); stream },
    fetch = function(result, n) {
        stopifnot(n > 0L); stream$sizes <- c(stream$sizes, n); stream$i <- stream$i + 1L
        batches[[stream$i]]
    }, done = function(result) stream$i == length(batches),
    clear = function(result) { stream$clears <- stream$clears + 1L; TRUE },
    normalize = identity)
seen <- list(); flags <- logical()
.fpsFetchSqlServer(connection, "SELECT row_id, value FROM #fixture",
    consume = function(batch, first) { seen[[length(seen) + 1L]] <<- batch; flags <<- c(flags, first) },
    api = streamApi)
stopifnot(identical(seen, batches), identical(flags, c(TRUE, FALSE)),
    identical(stream$sizes, c(50000L, 50000L)), stream$clears == 1L)
options(FederatedPs.clinicalNetworkTimeoutMillis = 7215000L)
.fpsSetClinicalNetworkTimeout(connection, jcall = stop("Java default evaluated"),
    nullExecutor = stop("Java default evaluated"))
realQuery <- .fpsDbiSmallQuery
.fpsDbiSmallQuery <- function(connection, sql, columns, timeout) {
    stopifnot(methods::is(connection, "DatabaseConnectorDbiConnection"), timeout == 30L)
    stop("fixture native failure")
}
options(FederatedPs.smallQueryTimeoutSeconds = 30L)
error <- expect_error(.fpsSmallSqlQuery(connection, sql, columns), "native failure")
stopifnot(inherits(error, "fps_small_query_error"), inherits(error$cause, "error"))
.fpsDbiSmallQuery <- realQuery
options(FederatedPs.smallQueryTimeoutSeconds = NULL, FederatedPs.clinicalNetworkTimeoutMillis = NULL)

# Phase and event logs show the blocking native call without exposing SQL/rows.
directory <- tempfile(); dir.create(directory); phases <- character()
options(FederatedPs.sqlDiagnosticsDirectory = directory,
    FederatedPs.dbStartupObserver = function(phase, ready) phases <<- c(phases, phase))
e <- fixture(fail = c("fetch", "clear"))
invisible(expect_error(probe(e), "fetch failure"))
events <- readLines(file.path(directory, "probe-events.tsv"))
stopifnot(any(grepl("DBI dbFetch", phases)), any(grepl("DBI dbClearResult", phases)),
    any(grepl("first-failure", events)), any(grepl("cleanup-failure", events)),
    which(grepl("first-failure", events))[1] < which(grepl("dbClearResult", events))[1],
    !any(grepl("CDM.CARE_SITE|SELECT TOP", events)))
options(FederatedPs.sqlDiagnosticsDirectory = NULL, FederatedPs.dbStartupObserver = NULL)
unlink(directory, recursive = TRUE)

# Synthetic integer64 display method makes the precision guard testable in base R.
# Real bit64 objects provide this S3 method in production.
as.character.integer64 <- function(x, ...) unclass(x)
values <- function(x) list(structure(x, class = "integer64"))
.fpsCheckExactInteger64(values(c(NA_character_, "0", "9007199254740992", "-9007199254740992")))
for (value in c("9007199254740993", "-9007199254740993", "9223372036854775807"))
    invisible(expect_error(.fpsCheckExactInteger64(values(value)), "exact numeric range"))
rm(as.character.integer64)
if (requireNamespace("bit64", quietly = TRUE)) {
    .fpsCheckExactInteger64(list(bit64::as.integer64(c(NA_character_, "9007199254740992", "-9007199254740992"))))
    invisible(expect_error(.fpsCheckExactInteger64(list(bit64::as.integer64("9007199254740993"))), "exact numeric range"))
    e <- fixture(list(data.frame(id = bit64::as.integer64(c("2", NA_character_)))))
    stopifnot(identical(probe(e), data.frame(careSiteId = c(2L, NA_integer_))))
}

# Watchdog reporting is independent from optional console progress. Failure to
# publish a start marker prevents SQL; completed-marker failure cannot be PASS.
records <- list()
options(FederatedPs.dbOperationObserver = function(record) records[[length(records) + 1L]] <<- record)
stopifnot(.fpsDbOperation("native statement", 17L) == 17L,
    identical(vapply(records, `[[`, "", "status"), c("started", "completed")),
    records[[1]]$id == records[[2]]$id,
    records[[1]]$startedUtc == records[[2]]$startedUtc,
    records[[1]]$stage == "extract")
executed <- FALSE
options(FederatedPs.dbOperationObserver = function(record) stop("marker failure"))
invisible(expect_error(.fpsDbOperation("native statement", { executed <- TRUE }), "marker failure"))
stopifnot(!executed)
options(FederatedPs.dbOperationObserver = function(record) {
    if (record$status == "completed") stop("completed marker failure")
})
invisible(expect_error(.fpsDbOperation("native statement", { executed <- TRUE }), "completed marker failure"))
stopifnot(executed)
original <- simpleError("original native SQL error")
options(FederatedPs.dbOperationObserver = function(record) {
    if (record$status == "failed") stop("failed marker failure")
})
error <- suppressMessages(expect_error(.fpsDbOperation("native statement", stop(original)), "original native SQL error"))
stopifnot(identical(error, original))
options(FederatedPs.dbOperationObserver = NULL)

details <- structure(list(uid = I("{fixture-user}"), pwd = I("{pw}}secret}")),
    class = "DbiConnectionDetails")
error <- .fpsNativeConnectionError(simpleError(
    "SQLSTATE 08001 fixture-user {fixture-user} pw}secret {pw}}secret}",
    call = quote(dbConnect(uid = "fixture-user", pwd = "pw}secret"))), details)
stopifnot(is.null(conditionCall(error)), grepl("SQLSTATE 08001", conditionMessage(error)),
    !grepl("fixture-user|secret", conditionMessage(error)))

# Exercise production connection cleanup: successful extraction must not mask
# close failure, and cleanup after SQL failure must preserve the first error.
source("R/CareSiteData.R")
source("R/StudySettings.R")
source("R/StudyData.R")
rewrite <- function(x) {
    if (missing(x)) return(quote(expr = ))
    if (!is.call(x)) return(x)
    if (identical(x[[1]], as.name("::")) && as.character(x[[3]]) %in% c("connect", "disconnect", "dbms", "dbIsValid"))
        return(as.name(paste0("fixture_", as.character(x[[3]]))))
    as.call(lapply(as.list(x), rewrite))
}
scope <- new.env(parent = environment()); calls <- character()
scope$fixture_connect <- function(details) { calls <<- c(calls, "connect"); "connection" }
scope$fixture_disconnect <- function(connection) { calls <<- c(calls, "disconnect"); stop("fixture close error") }
scope$fixture_dbms <- function(connection) "sql server"
scope$.fpsGetCareSiteSqlPlan <- function(...) list()
scope$.getCareSiteStudyData <- function(...) 42
fn <- getDbStudyData; body(fn) <- rewrite(body(fn)); environment(fn) <- scope
invisible(expect_error(fn(list(dbms = "sql server"), "fixture.cdm", "ppi", "default", 2L, 2L), "close error"))
stopifnot(identical(calls, c("connect", "disconnect")))
original <- simpleError("fixture original SQL failure")
scope$.getCareSiteStudyData <- function(...) stop(original); calls <- character()
error <- expect_error(fn(list(dbms = "sql server"), "fixture.cdm", "ppi", "default", 2L, 2L), "original SQL failure")
stopifnot(identical(error, original), identical(calls, c("connect", "disconnect")))
scope$fixture_connect <- function(details) stop(simpleError("SQLSTATE 08001 pw}secret", call = quote(dbConnect(pwd = "pw}secret"))))
details$dbms <- "sql server"
error <- expect_error(fn(details, "fixture.cdm", "ppi", "default", 2L, 2L), "SQLSTATE 08001")
stopifnot(is.null(conditionCall(error)), !grepl("secret", conditionMessage(error)))
scope$fixture_connect <- function(details) connection
scope$fixture_disconnect <- function(conn) TRUE
scope$fixture_dbIsValid <- function(conn) TRUE
scope$.getCareSiteStudyData <- function(...) 42
invisible(expect_error(fn(details, "fixture.cdm", "ppi", "default", 2L, 2L), "remained valid"))
scope$fixture_dbIsValid <- function(conn) FALSE
stopifnot(fn(details, "fixture.cdm", "ppi", "default", 2L, 2L) == 42)

cat("PASS: native DBI bounded fetch/EOF, typed IDs and NULLs, cleanup and original failures, no Java timeout calls, phase journaling, bigint precision\n")
