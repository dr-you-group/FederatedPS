# Base-R regression tests: no SQL Server, Java or installed R packages needed.
source("windows/diagnostic-checks.R")
expect_error <- function(expr, text) {
    error <- tryCatch({ force(expr); NULL }, error = identity)
    stopifnot(inherits(error, "error"), grepl(text, conditionMessage(error), fixed = TRUE))
    error
}
sites <- list(severance = 1L, gangnam = 2L, yongin = 3L)
make_fixture <- function(failConnect = FALSE, failQuery = 0L, failClose = FALSE,
                         invalidQuery = 0L) {
    state <- new.env(parent = emptyenv())
    state$queries <- 0L; state$closes <- 0L; state$events <- character(); state$messages <- character()
    state$connect <- function(details) {
        if (failConnect) stop("fixture connect error")
        "fixture connection"
    }
    state$disconnect <- function(connection) {
        stopifnot(identical(connection, "fixture connection"))
        state$closes <- state$closes + 1L
        if (failClose) stop("fixture close error")
        invisible(TRUE)
    }
    state$query <- function(connection, sql, columns) {
        state$queries <- state$queries + 1L
        if (state$queries == failQuery) stop("fixture query error")
        if (state$queries == invalidQuery) return(data.frame())
        if (state$queries == 1L) return(data.frame(ok = 1L, sessionId = 70L))
        id <- state$queries - 1L
        stopifnot(grepl(paste0("WHERE care_site_id = ", id), sql, fixed = TRUE))
        data.frame(careSiteId = id, careSiteName = "fixture name", careSiteSourceValue = "fixture source")
    }
    state$operation <- function(label, expr, ...) {
        state$events <- c(state$events, paste(label, "started"))
        value <- force(expr)
        state$events <- c(state$events, paste(label, "completed"))
        value
    }
    state$run <- function() fp_diagnostic_checks(list(), sites, "FIXTURE.CDM", state$connect,
        state$disconnect, state$query, state$operation,
        report = function(...) state$messages <- c(state$messages, paste(...)))
    state
}
fixture <- make_fixture()
checks <- fixture$run()
stopifnot(identical(checks, list(select1 = TRUE, careSites = 1:3, disconnectComplete = TRUE)),
          fixture$queries == 4L, fixture$closes == 1L,
          tail(fixture$events, 1L) == "Closing diagnostic connection completed",
          length(fixture$messages) == 4L, !any(grepl("PASS", fixture$messages)))
fixture <- make_fixture(failConnect = TRUE)
invisible(expect_error(fixture$run(), "connect error"))
stopifnot(fixture$closes == 0L)
for (query in 1:4) {
    fixture <- make_fixture(failQuery = query)
    invisible(expect_error(fixture$run(), "query error"))
    stopifnot(fixture$queries == query, fixture$closes == 1L,
              tail(fixture$events, 1L) == "Closing diagnostic connection after failure completed")
    fixture <- make_fixture(invalidQuery = query)
    invisible(expect_error(fixture$run(), "Expected"))
    stopifnot(fixture$closes == 1L)
}
fixture <- make_fixture(failClose = TRUE)
invisible(expect_error(fixture$run(), "close error"))
stopifnot(fixture$closes == 1L,
          tail(fixture$events, 1L) == "Closing diagnostic connection started")
fixture <- make_fixture(failQuery = 3L, failClose = TRUE)
invisible(expect_error(fixture$run(), "query error"))
stopifnot(fixture$closes == 1L)

# Use an injected serializer so the atomic receipt contract can be tested in
# bare R. The production serializer is jsonlite::write_json(auto_unbox=TRUE).
out <- tempfile("diagnostic-checks-")
dir.create(out)
write_json <- function(value, path, auto_unbox, pretty) {
    stopifnot(isTRUE(auto_unbox), isTRUE(pretty))
    dput(value, file = path)
}
token <- "0123456789abcdef0123456789abcdef"
path <- fp_write_diagnostic_status(out, token, checks, writeJson = write_json,
    rename = function(from, to) {
        stopifnot(file.exists(from), !file.exists(to), dirname(from) == dirname(to))
        file.rename(from, to)
    })
status <- dget(path)
stopifnot(identical(status, list(schema = 1L, state = "checks-complete", token = token,
    pid = Sys.getpid(), checks = list(select1 = TRUE, careSites = as.list(1:3)),
    disconnectComplete = TRUE)),
    identical(basename(path), "diagnostic-status.json"),
    !any(grepl("fixture name|fixture source", readLines(path))))
invisible(expect_error(fp_write_diagnostic_status(out, token, checks, writeJson = write_json), "already exists"))
unlink(path)
for (tokenValue in list(NULL, "", NA_character_, c("a", "b")))
    invisible(expect_error(fp_write_diagnostic_status(out, tokenValue, checks, writeJson = write_json), "token"))
incomplete <- checks; incomplete$disconnectComplete <- FALSE
invisible(expect_error(fp_write_diagnostic_status(out, token, incomplete, writeJson = write_json), "incomplete"))
invisible(expect_error(fp_write_diagnostic_status(out, token, checks,
    writeJson = function(...) stop("fixture write error")), "write error"))
invisible(expect_error(fp_write_diagnostic_status(out, token, checks, writeJson = write_json,
    rename = function(...) FALSE), "publish"))
stopifnot(!file.exists(path), length(list.files(out, all.files = TRUE, no.. = TRUE)) == 0L)
for (failure in list(list(failQuery = 2L), list(failClose = TRUE))) {
    fixture <- do.call(make_fixture, failure)
    invisible(try({
        result <- fixture$run()
        fp_write_diagnostic_status(out, token, result, writeJson = write_json)
    }, silent = TRUE))
    stopifnot(!file.exists(path))
}
unlink(out, recursive = TRUE)
cat("PASS: explicit disconnect, primary errors preserved, atomic completion receipt, no success receipt on failure\n")
