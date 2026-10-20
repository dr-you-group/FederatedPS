## Packet-layout checks: inconsistent packets have to raise an error instead of being summed.
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))

suppressPackageStartupMessages(library(FederatedPs))
put <- FederatedPs:::.putPs
PV  <- FederatedPs:::.protocolVersion
cat("protocol version:", PV, "\n\n")

spec <- function(P, protocol = PV, nfeat = 4L)
  list(coordinate = -1L, statistics = list(
    specification = list(protocol = protocol, features = as.character(seq_len(nfeat)),
      scales = rep(1, nfeat), priorVariance = 1,
      control = list(blockSize = P, alpha = 0.5),
      startingCoefficients = rep(0, nfeat + 1L),
      cohorts = list(targetId = 0, comparatorId = 0)),
    reference = data.frame(covariateId = as.character(seq_len(nfeat)), analysisId = 1L),
    present = rep(TRUE, nfeat)))

trial <- function(label, packets, expect) {
  dir <- tempfile("neg-"); dir.create(dir)
  cfg <- pda::getCloudConfig("aggregator", dir = dir)
  run <- "neg"
  for (k in seq_along(packets)) {
    rc <- cfg; if (k > 1L) { rc$dir <- file.path(dir, run, k - 1L)
                             dir.create(rc$dir, recursive = TRUE, showWarnings = FALSE) }
    for (s in names(packets[[k]])) put(packets[[k]][[s]], paste0(run, "_", k - 1L, "_", s), rc)
  }
  e <- tryCatch({ aggregatePs(cfg, c("s1","s2"), run, timeout = 1); "NO ERROR" },
                error = function(e) conditionMessage(e))
  ok <- grepl(expect, e, fixed = TRUE)
  cat(sprintf("  [%s] %-46s -> %s\n", if (ok) "PASS" else "FAIL", label, substr(e, 1, 80)))
  unlink(dir, recursive = TRUE); ok
}

ok <- c()
## 1. both sites agree, block of 2 over 5 coordinates -> accepted and summed
ok <- c(ok, trial("valid block packet accepted (then times out)",
  list(list(s1 = spec(2L), s2 = spec(2L)),
       list(s1 = list(coordinate = 1L, statistics = c(1,2, 10,10, 0,0, 2,2)),
            s2 = list(coordinate = 1L, statistics = c(3,4, 20,20, 0,0, 2,2)))),
  "Timed out"))
## 2. scalar packet while the run is in block mode
ok <- c(ok, trial("scalar packet in block mode rejected",
  list(list(s1 = spec(2L), s2 = spec(2L)),
       list(s1 = list(coordinate = 1L, statistics = c(1,2,0,2)),
            s2 = list(coordinate = 1L, statistics = c(1,2,0,2)))),
  "Expected a 2-coordinate packet"))
## 3. block not starting on a block boundary
ok <- c(ok, trial("misaligned block start rejected",
  list(list(s1 = spec(2L), s2 = spec(2L)),
       list(s1 = list(coordinate = 2L, statistics = c(1,2,10,10,0,0,2,2)),
            s2 = list(coordinate = 2L, statistics = c(1,2,10,10,0,0,2,2)))),
  "does not start a block of 2"))
## 4. sites disagree on packet length
ok <- c(ok, trial("differing packet lengths rejected",
  list(list(s1 = spec(2L), s2 = spec(2L)),
       list(s1 = list(coordinate = 1L, statistics = c(1,2,10,10,0,0,2,2)),
            s2 = list(coordinate = 1L, statistics = c(1,2,0,2)))),
  "Hospital packet layouts differ"))
## 5. sites disagree on blockSize (caught by the specification check)
ok <- c(ok, trial("differing blockSize rejected",
  list(list(s1 = spec(2L), s2 = spec(4L))), "features, scales or fitting settings differ"))
## 6. wrong / missing protocol version
ok <- c(ok, trial("wrong protocol version rejected",
  list(list(s1 = spec(2L, protocol = "fedps/1"), s2 = spec(2L, protocol = "fedps/1"))),
  "protocol version differs"))
## 7. coordinate beyond the model
ok <- c(ok, trial("coordinate outside the model rejected",
  list(list(s1 = spec(2L), s2 = spec(2L)),
       list(s1 = list(coordinate = 99L, statistics = c(1,2,10,10,0,0,2,2)),
            s2 = list(coordinate = 99L, statistics = c(1,2,10,10,0,0,2,2)))),
  "outside the agreed model"))
cat(sprintf("\n%d / %d negative tests passed\n", sum(ok), length(ok)))
if (!all(ok)) quit(status = 1)
