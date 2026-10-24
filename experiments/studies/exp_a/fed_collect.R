## Collect the federated runs into fl_real rows (same matching, SMD and noise floor as analyze.R).
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
source(file.path(FP_EXP, "studies/data/sites.R"))
source(file.path(FP_EXP, "common/kit.R"))
study <- commandArgs(TRUE)[1]
B <- buildSites(study)
J <- read.table(file.path(FP_OUT, "fedjobs.txt"), col.names = c("study","fold","alpha","rid"),
                stringsAsFactors = FALSE)
J <- J[J$study == study, ]
if (nrow(J) != NFOLD) stop("unexpected number of folds")

PS <- lapply(B$nm, function(k) rep(NA_real_, length(B$y[[k]]))); names(PS) <- B$nm
rounds <- data.frame()
for (i in seq_len(nrow(J))) {
  f <- J$fold[i]; rid <- J$rid[i]
  r <- readRDS(sprintf(file.path(FP_OUT, "fedruns/%s/synpufA.rds"), rid))   # coefficients are identical at every site
  co <- r$coefficients
  b0 <- co[["(Intercept)"]]; nmc <- setdiff(names(co), "(Intercept)")
  cid <- as.numeric(nmc); bj <- as.numeric(co[nmc])
  for (k in B$nm) {
    te <- which(B$fold[[k]] == f)
    j <- match(cid, B$sites[[k]]$feat); ok <- !is.na(j)
    eta <- b0 + as.vector(B$sites[[k]]$X[te, j[ok], drop = FALSE] %*% bj[ok])
    PS[[k]][te] <- 1/(1 + exp(-eta))
  }
  for (k in B$nm) { rk <- readRDS(sprintf(file.path(FP_OUT, "fedruns/%s/%s.rds"), rid, k))
    rounds <- rbind(rounds, data.frame(study = study, fold = f, site = k,
      passes = rk$iterations, loopRounds = rk$loopRounds, convRounds = rk$convRounds,
      overheadRounds = rk$overheadRounds, payloadDoubles = rk$payloadDoubles,
      wall = rk$wall)) }
}
stopifnot(!any(sapply(PS, function(p) any(is.na(p)))))

matchPaired <- function(ps, yy, caliper = 0.2) {
  pop <- data.frame(rowId = seq_along(yy), treatment = yy, propensityScore = ps)
  m <- CohortMethod::matchOnPs(pop, matchOnPsArgs = CohortMethod::createMatchOnPsArgs(
         caliper = caliper, caliperScale = "standardized logit", maxRatio = 1))
  m <- m[order(m$stratumId, -m$treatment), ]
  list(idx = m$rowId, pairs = sum(m$treatment == 1)) }
noiseFloor <- function(Z, ym, B2 = 200L) { s <- numeric(B2)
  for (b in 1:B2) { yp <- ym
    flip <- rep(sample(c(TRUE, FALSE), length(ym)/2, TRUE), each = 2)
    yp[flip] <- 1 - ym[flip]; s[b] <- mean(smdStats(Z, yp)$smd) }
  unname(quantile(s, 0.95)) }

res <- list()
for (k in B$nm) {
  Z <- B$Xg[[k]][, -1, drop = FALSE]; Z <- Z[, colSums(Z != 0) > 0, drop = FALSE]
  yy <- B$y[[k]]; mm <- matchPaired(PS[[k]], yy)
  ss <- smdStats(Z, yy, mm$idx)$summary
  nf <- noiseFloor(Z[mm$idx, , drop = FALSE], yy[mm$idx])
  r <- rank(PS[[k]]); n1 <- as.numeric(sum(yy == 1)); n0 <- as.numeric(sum(yy == 0))
  res[[length(res)+1L]] <- data.frame(study = study, site = k, model = "fl_real",
    n = length(yy), nT = n1, nC = n0, pairs = mm$pairs, retention = mm$pairs/min(n1,n0),
    meanSMD = ss[["mean"]], maxSMD = ss[["max"]], nGt0.1 = ss[["n_gt_0.1"]],
    nCov = ss[["nCov"]], noise95 = nf, overNoise = ss[["mean"]] > nf,
    auc = (sum(r[yy == 1]) - n1*(n1+1)/2)/(n1*n0))
}
out <- do.call(rbind, res)
dir.create(file.path(FP_OUT, "fedresults"), showWarnings = FALSE)
write.csv(out, sprintf(file.path(FP_OUT, "fedresults/%s.csv"), study), row.names = FALSE)
write.csv(rounds, sprintf(file.path(FP_OUT, "fedresults/%s_rounds.csv"), study), row.names = FALSE)
saveRDS(PS, sprintf(file.path(FP_OUT, "fedresults/%s_ps.rds"), study))
cat(sprintf("\n[%s] federated runs\n", study)); print(out, row.names = FALSE, digits = 4)
cat(sprintf("rounds per fold: loop %.0f, overhead %.0f, wall %.0f s\n",
    mean(rounds$loopRounds), mean(rounds$overheadRounds), mean(rounds$wall)))
