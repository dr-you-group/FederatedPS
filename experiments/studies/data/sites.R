## Site construction shared with analyze.R (same RNG call order).
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
suppressPackageStartupMessages(library(Matrix))
NFOLD <- 5L; SEED <- 20261001L
buildSites <- function(study) {
  ## ---- design ------------------------------------------------------------------
  loadStudy <- function(site) {
    dd <- readRDS(sprintf(file.path(FP_DATA, "design/%s__%s.rds"), study, site))
    rows <- sort(dd$rowId); feat <- dd$covariateIds
    i <- match(dd$cov$rowId, rows); j <- match(dd$cov$covariateId, feat)
    ok <- !is.na(i) & !is.na(j)
    k <- match(rows, dd$rowId)
    list(X = sparseMatrix(i = i[ok], j = j[ok], x = dd$cov$covariateValue[ok],
                          dims = c(length(rows), length(feat))),
         feat = feat, y = dd$treatment[k], person = dd$personId[k])
  }
  M <- loadStudy("mimiciv"); S <- loadStudy("synpuf")

  ## ---- split SynPUF by state ----------------------------------------------------
  st <- read.csv(file.path(FP_DATA, "synpuf_state.csv"), header = FALSE,
                 col.names = c("personId", "state"), colClasses = c("numeric", "character"))
  stateOf <- st$state[match(S$person, st$personId)]
  pool <- table(st$state)                                  # state sizes over all of SynPUF
  big <- names(sort(pool, decreasing = TRUE)); small <- rev(big)

  set.seed(SEED)
  nM <- nrow(M$X)
  if (nrow(S$X) < 2.5 * nM) nM <- floor(nrow(S$X) / 2.5)   # shrink MIMIC if SynPUF is too small
  tA <- round(2.0 * nM); tB <- round(0.5 * nM)
  fill <- function(order, target, taken) {                 # add states until the target size is reached
    sel <- character(); n <- 0L
    for (s in order) { if (s %in% taken) next
      m <- sum(stateOf == s, na.rm = TRUE); if (m == 0L) next
      sel <- c(sel, s); n <- n + m; if (n >= target) break }
    sel
  }
  stA <- fill(big, tA, character()); stB <- fill(small, tB, stA)
  sub <- function(states, target) { ix <- which(stateOf %in% states)
    if (length(ix) > target) sort(sample(ix, target)) else sort(ix) }
  iA <- sub(stA, tA); iB <- sub(stB, tB)
  iM <- if (nM < nrow(M$X)) sort(sample(nrow(M$X), nM)) else seq_len(nrow(M$X))

  sites <- list(
    synpufA = list(X = S$X[iA, , drop = FALSE], feat = S$feat, y = S$y[iA]),
    mimic   = list(X = M$X[iM, , drop = FALSE], feat = M$feat, y = M$y[iM]),
    synpufB = list(X = S$X[iB, , drop = FALSE], feat = S$feat, y = S$y[iB]))
  rm(S, M, st); invisible(gc())

  axis <- sort(unique(unlist(lapply(sites, function(s) s$feat[colSums(s$X != 0) > 0]))))
  onAx <- function(s) { j <- match(s$feat, axis); t <- summary(as(s$X, "TsparseMatrix"))
    keep <- !is.na(j[t$j])
    as(cbind(Matrix(1, nrow(s$X), 1, sparse = TRUE),
             sparseMatrix(i = t$i[keep], j = j[t$j][keep], x = t$x[keep],
                          dims = c(nrow(s$X), length(axis)))), "CsparseMatrix") }
  Xg <- lapply(sites, onAx)                                # common axis, intercept first
  y  <- lapply(sites, `[[`, "y")
  nm <- names(sites)
  cat(sprintf("\n[%s] common axis d = %d\n", study, length(axis) + 1L))
  for (k in nm) cat(sprintf("  %-8s n=%7d  T=%7d  C=%7d  prevalence %.3f  features %6d\n",
    k, nrow(Xg[[k]]), sum(y[[k]] == 1), sum(y[[k]] == 0), mean(y[[k]]),
    sum(colSums(Xg[[k]][, -1, drop = FALSE] != 0) > 0)))

  ## ---- cross-fitting folds, stratified by site and treatment -----------------
  set.seed(SEED + 1L)
  fold <- lapply(y, function(yy) { f <- integer(length(yy))
    for (g in c(0, 1)) { ix <- which(yy == g); f[ix] <- sample(rep_len(1:NFOLD, length(ix))) }; f })

  list(Xg = Xg, y = y, nm = nm, fold = fold, axis = axis, sites = sites)
}
