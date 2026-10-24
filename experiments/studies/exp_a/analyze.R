## Out-of-fold local / pooled / FL propensity scores for one study, then matching and SMD.
## Sites: SynPUF-A (large states, 2x), MIMIC (1x), SynPUF-B (small states, 0.5x).
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))

source(file.path(FP_EXP, "common/kit.R"))
suppressPackageStartupMessages(library(Matrix))
study <- commandArgs(TRUE)[1]
NFOLD <- 5L; SEED <- 20261001L

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

## ---- fits (all-zero columns are dropped so that h_j > 0) ---------------------
fit <- function(X, yy, aggregate = TRUE) {
  pres <- which(colSums(X[, -1, drop = FALSE] != 0) > 0)
  r <- runCfg(cbind(X[, 1, drop = FALSE], X[, pres + 1L, drop = FALSE]), yy, P = 1L, alpha = 1)
  b <- numeric(ncol(X)); b[1] <- r$beta[1]; b[pres + 1L] <- r$beta[-1]
  list(beta = b, r = r) }
predPs <- function(b, X) 1 / (1 + exp(-as.vector(X %*% b)))

## Check: the sum of per-site (gradient, Hessian) equals the pooled statistics.
ghOf <- function(X, yy, b, j) { p <- 1/(1+exp(-as.vector(X %*% b)))
  Xj <- X[, j, drop = FALSE]
  c(as.vector(crossprod(Xj, p - yy)), as.vector(crossprod(Xj^2, p*(1-p)))) }

PS <- lapply(nm, function(k) matrix(NA_real_, length(y[[k]]), 3,
       dimnames = list(NULL, c("local", "pooled", "fl")))); names(PS) <- nm
flCheck <- NULL
for (f in 1:NFOLD) {
  trG <- do.call(rbind, lapply(nm, function(k) Xg[[k]][fold[[k]] != f, , drop = FALSE]))
  trY <- unlist(lapply(nm, function(k) y[[k]][fold[[k]] != f]), use.names = FALSE)
  gp <- fit(trG, trY); rm(trG); invisible(gc())
  if (f == 1L) {
    jj <- sort(sample(2:ncol(Xg[[1]]), min(200L, ncol(Xg[[1]]) - 1L)))
    tr <- lapply(nm, function(k) Xg[[k]][fold[[k]] != f, , drop = FALSE])
    tY <- lapply(nm, function(k) y[[k]][fold[[k]] != f])
    cen <- ghOf(do.call(rbind, tr), unlist(tY, use.names = FALSE), gp$beta, jj)
    fed <- Reduce(`+`, lapply(seq_along(tr), function(k) ghOf(tr[[k]], tY[[k]], gp$beta, jj)))
    flCheck <- list(r = gp$r, maxRelErr = max(abs(cen - fed) / pmax(abs(cen), 1e-10)))
    cat(sprintf("  site sum vs pooled statistics, max relative error = %.3e (%d coordinates)\n",
                flCheck$maxRelErr, length(jj)))
    rm(tr, tY); invisible(gc())
  }
  for (k in nm) {
    te <- which(fold[[k]] == f)
    PS[[k]][te, "pooled"] <- predPs(gp$beta, Xg[[k]][te, , drop = FALSE])
    PS[[k]][te, "fl"]     <- PS[[k]][te, "pooled"]     # FL = pooled, checked above
    lp <- fit(Xg[[k]][fold[[k]] != f, , drop = FALSE], y[[k]][fold[[k]] != f])
    PS[[k]][te, "local"]  <- predPs(lp$beta, Xg[[k]][te, , drop = FALSE])
  }
  cat(sprintf("  fold %d/%d done\n", f, NFOLD))
}

## ---- matching, SMD and the permutation noise floor -------------------------
## Rows are ordered by stratum so that each pair occupies two consecutive rows.
matchPaired <- function(ps, yy, caliper = 0.2) {
  pop <- data.frame(rowId = seq_along(yy), treatment = yy, propensityScore = ps)
  m <- CohortMethod::matchOnPs(pop, matchOnPsArgs = CohortMethod::createMatchOnPsArgs(
         caliper = caliper, caliperScale = "standardized logit", maxRatio = 1))
  m <- m[order(m$stratumId, -m$treatment), ]
  stopifnot(nrow(m) %% 2L == 0L, all(table(m$stratumId) == 2L))
  list(idx = m$rowId, pairs = sum(m$treatment == 1)) }
noiseFloor <- function(Z, yy, idx, B = 200L) {
  s <- numeric(B); ym <- yy[idx]
  for (b in 1:B) { yp <- ym
    ## flip labels within pairs
    flip <- rep(sample(c(TRUE, FALSE), length(ym) / 2, TRUE), each = 2)
    yp[flip] <- 1 - ym[flip]
    s[b] <- mean(smdStats(Z, yp)$smd) }
  unname(quantile(s, 0.95)) }

res <- list()
for (k in nm) {
  Z <- Xg[[k]][, -1, drop = FALSE]
  Z <- Z[, colSums(Z != 0) > 0, drop = FALSE]
  for (mo in c("local", "pooled", "fl")) {
    ps <- PS[[k]][, mo]; mm <- matchPaired(ps, y[[k]])
    ss <- smdStats(Z, y[[k]], mm$idx)$summary
    nf <- noiseFloor(Z[mm$idx, , drop = FALSE], y[[k]], mm$idx)
    res[[length(res) + 1L]] <- data.frame(study = study, site = k, model = mo,
      n = length(y[[k]]), nT = sum(y[[k]] == 1), nC = sum(y[[k]] == 0),
      pairs = mm$pairs, retention = mm$pairs / min(sum(y[[k]] == 1), sum(y[[k]] == 0)),
      meanSMD = ss[["mean"]], maxSMD = ss[["max"]], nGt0.1 = ss[["n_gt_0.1"]],
      nCov = ss[["nCov"]], noise95 = nf, overNoise = ss[["mean"]] > nf)
  }
}
out <- do.call(rbind, res)
out$auc <- NA_real_
for (i in seq_len(nrow(out))) { k <- out$site[i]; p <- PS[[k]][, out$model[i]]; yy <- y[[k]]
  r <- rank(p); n1 <- as.numeric(sum(yy == 1)); n0 <- as.numeric(sum(yy == 0))
  out$auc[i] <- (sum(r[yy == 1]) - n1 * (n1 + 1) / 2) / (n1 * n0) }
dir.create(file.path(FP_OUT, "results"), showWarnings = FALSE)
write.csv(out, sprintf(file.path(FP_OUT, "results/%s.csv"), study), row.names = FALSE)
saveRDS(list(ps = PS, y = y, fold = fold, sites = sapply(Xg, nrow), stA = stA, stB = stB,
             flCheck = flCheck), sprintf(file.path(FP_OUT, "results/%s_ps.rds"), study))
cat(sprintf("\n[%s] results\n", study)); print(out, row.names = FALSE, digits = 4)
