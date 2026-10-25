# Base-R observer and current-sweep ETA checks; no database or Cyclops required.
source("R/Progress.R")
events <- list()
options(FederatedPs.progress = function(x) events[[length(events) + 1L]] <<- x)
t <- 0
tracker <- .newPsSweepProgress(10, 4, clock = function() t)
t <- 4; tracker(1)
stopifnot(events[[1]]$completed == 4, events[[1]]$total == 10,
          events[[1]]$etaSeconds == 6)
t <- 8; tracker(5)
stopifnot(tail(events, 1)[[1]]$etaSeconds == 2)
t <- 10; tracker(9)
stopifnot(tail(events, 1)[[1]]$completed == 10, tail(events, 1)[[1]]$etaSeconds == 0)
t <- 11; tracker(0)
stopifnot(tail(events, 1)[[1]]$stage == "convergence", is.na(tail(events, 1)[[1]]$etaSeconds))
t <- 15; tracker(1)
stopifnot(grepl("sweep 2", tail(events, 1)[[1]]$detail), tail(events, 1)[[1]]$completed == 4,
          tail(events, 1)[[1]]$etaSeconds == 6)
.fpsProgress("extract", "partition", 1, 10, "extraction steps (not time)")
stopifnot(is.na(tail(events, 1)[[1]]$etaSeconds))
.fpsProgress("waiting-exchange", "Waiting for fixture", kind = "wait")
stopifnot(is.na(tail(events, 1)[[1]]$completed), is.na(tail(events, 1)[[1]]$total))
options(FederatedPs.progress = function(x) stop("observer failure"))
suppressWarnings(.fpsProgress("test"))
stopifnot(is.null(getOption("FederatedPs.progress")))
.fpsProgress("test") # No observer remains a no-op.
cat("PASS: partial blocks, sweep reset, ETA scope, unknown duration, observer failure isolation\n")
