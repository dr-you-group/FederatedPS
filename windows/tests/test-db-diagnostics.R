# Base-R checks of JDBC call sequencing and diagnostics. No DB / Java required.
source("R/Progress.R")
source("R/CareSiteData.R")
source("R/DbDiagnostics.R")

expect_error <- function(expr, pattern = "") {
    error <- tryCatch({ force(expr); NULL }, error = identity)
    stopifnot(inherits(error, "error"), grepl(pattern, conditionMessage(error)))
    error
}
for (value in list(NULL, NA_real_, 0, -1, 1.5, Inf, 86401, "60"))
    expect_error(.fpsSmallQueryTimeout(value), "integer")

make_java <- function(rows, fail = "", failRestore = FALSE) {
    state <- new.env(parent = emptyenv())
    state$calls <- list(); state$row <- 0L; state$wasNull <- FALSE; state$network <- 180000L
    state$call <- function(object, type, method, ...) {
        args <- list(...)
        state$calls[[length(state$calls) + 1L]] <- list(object = object, method = method, args = args)
        if (method == fail) stop(paste("Fixture failure:", method))
        if (method == "getNetworkTimeout") return(state$network)
        if (method == "setNetworkTimeout") {
            if (failRestore && args[[2]] == 180000L) stop("Fixture restore failure")
            state$network <- args[[2]]; return(invisible(NULL))
        }
        if (method == "createStatement") return("statement")
        if (method == "executeQuery") return("result")
        if (method == "getUpdateCount") return(-1L)
        if (method == "getMoreResults" || method == "isClosed") return(FALSE)
        if (method == "next") { state$row <- state$row + 1L; return(state$row <= nrow(rows)) }
        if (method %in% c("getInt", "getString")) {
            value <- rows[state$row, args[[1]]]
            state$wasNull <- is.na(value)
            return(if (state$wasNull) { if (method == "getInt") 0L else NULL } else value)
        }
        if (method == "wasNull") return(state$wasNull)
        invisible(NULL)
    }
    state
}
columns <- c(careSiteId = "integer", careSiteName = "character", careSiteSourceValue = "character")
rows <- data.frame(id = 2L, name = "Synthetic Hospital", source = NA_character_)
java <- make_java(rows)
sql <- "SELECT TOP (2) care_site_id, care_site_name, care_site_source_value FROM CDM.CARE_SITE WHERE care_site_id = 2"
got <- .fpsJdbcSmallQuery("connection", sql, columns, 60, java$call, "null-executor", function(object, ...) object)
stopifnot(identical(names(got), names(columns)), got$careSiteId == 2L,
          got$careSiteName == "Synthetic Hospital", is.na(got$careSiteSourceValue),
          java$network == 180000L)
methods <- vapply(java$calls, `[[`, "", "method")
stopifnot(identical(methods[1:6], c("getNetworkTimeout", "setNetworkTimeout", "createStatement",
                                  "setResponseBuffering", "setQueryTimeout", "executeQuery")),
          !"setMaxRows" %in% methods)
stopifnot(java$calls[[2]]$args[[2]] == 75000L, identical(java$calls[[3]]$args, list(2003L,1007L)),
          java$calls[[4]]$args[[1]] == "full", java$calls[[5]]$args[[1]] == 60L,
          java$calls[[6]]$args[[1]] == sql)
stopifnot(identical(tail(methods, 4), c("close", "close", "setNetworkTimeout", "isClosed")))

for (fail in c("createStatement", "setResponseBuffering", "setQueryTimeout", "executeQuery", "next", "getString", "getMoreResults")) {
    java <- make_java(rows, fail)
    expect_error(.fpsJdbcSmallQuery("connection", sql, columns, 60, java$call, "null-executor", function(object, ...) object), fail)
    stopifnot(java$network == 180000L)
    if (fail != "createStatement")
        stopifnot(any(vapply(java$calls, function(x) x$object == "statement" && x$method == "close", TRUE)))
    if (fail %in% c("next", "getString", "getMoreResults"))
        stopifnot(any(vapply(java$calls, function(x) x$object == "result" && x$method == "close", TRUE)))
}
for (count in c(0, 2)) {
    java <- make_java(rows[rep(1, count), , drop = FALSE])
    got <- .fpsJdbcSmallQuery("connection", sql, columns, 1, java$call, "null-executor", function(object, ...) object)
    stopifnot(nrow(got) == count, java$network == 180000L, java$row == count + 1L)
}
java <- make_java(rows[rep(1, 4),,drop=FALSE])
invisible(expect_error(.fpsJdbcSmallQuery("connection", sql, columns, 60, java$call, "null-executor", function(object, ...) object), "more than two"))
java <- make_java(rows, failRestore = TRUE)
invisible(expect_error(.fpsJdbcSmallQuery("connection", sql, columns, 60, java$call, "null-executor", function(object, ...) object), "restore failure"))
java <- make_java(rows, fail = "executeQuery", failRestore = TRUE)
invisible(expect_error(.fpsJdbcSmallQuery("connection", sql, columns, 60, java$call, "null-executor", function(object, ...) object), "executeQuery"))

# Only the small-query JDBC boundary gets the probe error classification.
methods::setClass("DatabaseConnectorJdbcConnection", slots = c(jConnection = "ANY"))
connection <- methods::new("DatabaseConnectorJdbcConnection", jConnection = "fixture")
java <- make_java(rows)
options(FederatedPs.clinicalNetworkTimeoutMillis = 7215000L)
.fpsSetClinicalNetworkTimeout(connection, java$call, "null-executor")
stopifnot(java$network == 7215000L,
          identical(vapply(java$calls, `[[`, "", "method"), "setNetworkTimeout"))
options(FederatedPs.clinicalNetworkTimeoutMillis = NULL)
.fpsSetClinicalNetworkTimeout(connection, function(...) stop("Unexpected timeout change"))
real_small_query <- .fpsJdbcSmallQuery
.fpsJdbcSmallQuery <- function(...) stop("fixture JDBC timeout")
options(FederatedPs.smallQueryTimeoutSeconds = 60)
error <- expect_error(.fpsSmallSqlQuery(connection, sql, columns), "JDBC timeout")
stopifnot(inherits(error, "fps_small_query_error"), inherits(error$cause, "error"))
options(FederatedPs.smallQueryTimeoutSeconds = 0)
error <- expect_error(.fpsSmallSqlQuery(connection, sql, columns), "integer")
stopifnot(!inherits(error, "fps_small_query_error"))
.fpsJdbcSmallQuery <- real_small_query
options(FederatedPs.smallQueryTimeoutSeconds = NULL)

# Substeps are visible even when progress logging is disabled, and disclose no
# SQL literal/row value. They also expose hangs during JDBC cleanup/restoration.
phases <- character()
options(FederatedPs.progress=NULL,FederatedPs.dbStartupObserver=function(phase,ready) phases <<- c(phases,phase))
java <- make_java(rows)
invisible(.fpsJdbcSmallQuery("connection",sql,columns,60,java$call,"null-executor", function(object, ...) object))
stopifnot(any(grepl("JDBC Statement.executeQuery",phases)),any(grepl("JDBC ResultSet.next",phases)),
    any(grepl("resource cleanup",phases)),grepl("isClosed",tail(phases,1)),
    !any(grepl("Synthetic Hospital|SELECT|CDM.CARE_SITE",phases)))
options(FederatedPs.dbStartupObserver=NULL)

directory <- tempfile("fps-diagnostics-")
events <- list()
options(FederatedPs.sqlDiagnosticsDirectory = directory, FederatedPs.dbOperationIndex = 0L,
        FederatedPs.progress = function(event) events[[length(events) + 1L]] <<- event)
value <- .fpsDbOperation("Cohort SQL", 42L, sql = "SELECT 1;", completed = 6)
stopifnot(value == 42L, length(events) == 2L,
          grepl("started", events[[1]]$detail), grepl("completed", events[[2]]$detail),
          identical(readLines(file.path(directory, "0001-Cohort-SQL.sql")), "SELECT 1;"))
original <- simpleError("fixture original SQL error")
error <- expect_error(.fpsDbOperation("Fetch", stop(original), completed = 6), "original SQL")
stopifnot(identical(error, original), grepl("failed", tail(events, 1)[[1]]$detail),
          length(readLines(file.path(directory, "operations.tsv"))) == 4L)
options(FederatedPs.sqlDiagnosticsDirectory = tempfile())
writeLines("fixture blocking file", getOption("FederatedPs.sqlDiagnosticsDirectory"))
stopifnot(suppressWarnings(suppressMessages(.fpsDbOperation("Cannot log", 99L))) == 99L,
          is.null(getOption("FederatedPs.sqlDiagnosticsDirectory")))

# Preserve the unaliased upstream person.person_id qualifier on CS databases;
# leave SQL that already has an alias unchanged except for the table case.
raw <- paste("SELECT cohorts.subject_id FROM cohorts INNER JOIN CDM.CDM.person",
             "ON cohorts.subject_id = person.person_id INNER JOIN CDM.CDM.observation_period",
             "ON subject_id = person_id")
fixed <- .fpsUppercaseCohortTables(raw, "CDM.CDM")
stopifnot(grepl("JOIN CDM.CDM.PERSON person ON", fixed, fixed = TRUE),
          grepl("JOIN CDM.CDM.OBSERVATION_PERIOD", fixed, fixed = TRUE),
          identical(fixed, .fpsUppercaseCohortTables(fixed, "CDM.CDM")))
aliased <- "INNER JOIN CDM.CDM.person AS p ON cohorts.subject_id = p.person_id"
stopifnot(identical(.fpsUppercaseCohortTables(aliased, "CDM.CDM"),
    "INNER JOIN CDM.CDM.PERSON AS p ON cohorts.subject_id = p.person_id"))
options(FederatedPs.progress = NULL)
unlink(directory, recursive = TRUE)
# A late server error must be seen by getMoreResults, not discarded by close.
logDir <- tempfile(); dir.create(logDir)
options(FederatedPs.sqlDiagnosticsDirectory=logDir)
java <- make_java(rows, fail="getMoreResults")
error <- suppressMessages(expect_error(.fpsJdbcSmallQuery("connection",sql,columns,60,java$call,
    "null-executor",function(object,...) object),"getMoreResults"))
journal <- readLines(file.path(logDir,"probe-events.tsv"))
stopifnot(any(grepl("first-failure",journal)), any(grepl("Statement.getMoreResults",journal)),
    any(grepl("ResultSet.close",journal)), any(grepl("Statement.close",journal)),
    !any(grepl("Synthetic Hospital|CDM.CARE_SITE",journal)))
first <- which(grepl("first-failure",journal))
stopifnot(first < which(grepl("ResultSet.close.*started",journal))[1])
unlink(logDir,recursive=TRUE)
options(FederatedPs.sqlDiagnosticsDirectory=NULL)
cat("PASS: full bounded response, EOF/terminal errors, explicit cleanup phases, first-failure journal; no hidden SET ROWCOUNT; scoped/clinical socket deadlines; fetch bounds; cleanup; probe errors; SQL diagnostics\n")
