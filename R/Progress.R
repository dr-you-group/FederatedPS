# Optional, process-local observer. Never send telemetry over the model exchange
# and never allow an observer failure to change numerical results.
.fpsProgress <- function(stage, detail = "", completed = NA_real_, total = NA_real_,
                         unit = "", etaSeconds = NA_real_, kind = "stage", operation = NULL) {
    observer <- getOption("FederatedPs.progress")
    if (is.function(observer)) tryCatch(observer(list(stage = stage, detail = detail,
        completed = completed, total = total, unit = unit, etaSeconds = etaSeconds,
        kind = kind, operation = operation)), error = function(e) {
            options(FederatedPs.progress = NULL)
            message("Progress observer disabled after an error; computation continues.")
        })
    invisible(NULL)
}

# Estimate only the current complete coordinate sweep. The number of sweeps
# until convergence is unknown; maxIterations is a limit, not a progress total.
.newPsSweepProgress <- function(nCoefficients, blockSize, clock = function() as.numeric(Sys.time())) {
    sweep <- 0L
    started <- last <- clock()
    previous <- 0L
    function(coordinate) {
        now <- clock()
        if (coordinate == 0L) {
            .fpsProgress("convergence", paste("Checking convergence after sweep", sweep))
        } else if (coordinate > 0L) {
            if (coordinate == 1L || coordinate <= previous) {
                sweep <<- sweep + 1L
                started <<- last
            }
            done <- min(nCoefficients, coordinate + blockSize - 1L)
            elapsed <- max(0, now - started)
            eta <- if (done == nCoefficients) 0 else if (elapsed > 0 && done > 0)
                elapsed * (nCoefficients - done) / done else NA_real_
            .fpsProgress("fitting", paste("CCD sweep", sweep, "(total run ETA unknown)"),
                done, nCoefficients, "coordinates in this sweep", eta, kind = "progress")
            previous <<- coordinate
        }
        last <<- now
        invisible(NULL)
    }
}
