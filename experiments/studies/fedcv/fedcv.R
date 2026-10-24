## Federated cross-validation of the prior variance v (plaintext aggregation).
## One MIMIC study split into K = 3 sites (50/30/20%, treatment-stratified), 5 folds per site.
## For every (v, fold) the model is fitted without that fold (runCfg, P = 1); each site scores its
## held-out rows, the scores are summed over sites and folds, and the argmax is taken.
## Both cold starts and a warm-started path over v are run and their round counts recorded.
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
source(file.path(FP_EXP, "common/kit.R"))
a <- commandArgs(TRUE); study <- a[1]
K <- 3L; FR <- c(0.5, 0.3, 0.2); NF <- 5L; SEED <- 20261008L
GRID <- 10^seq(-2.5, 0, by = 0.25)

dd <- readRDS(sprintf(file.path(FP_DATA, "design/%s__mimiciv.rds"), study))
rows <- sort(dd$rowId); feat <- dd$covariateIds
i <- match(dd$cov$rowId, rows); j <- match(dd$cov$covariateId, feat); ok <- !is.na(i) & !is.na(j)
X <- sparseMatrix(i=i[ok], j=j[ok], x=dd$cov$covariateValue[ok], dims=c(length(rows), length(feat)))
y <- dd$treatment[match(rows, dd$rowId)]; rm(dd); invisible(gc())
X <- X[, colSums(X != 0) > 0]
X1 <- as(cbind(Matrix(1, nrow(X), 1, sparse = TRUE), X), "CsparseMatrix"); rm(X)

set.seed(SEED)
site <- integer(length(y)); fold <- integer(length(y))
for (g in 0:1) { ix <- sample(which(y == g)); cut <- round(cumsum(FR) * length(ix))
  site[ix] <- findInterval(seq_along(ix) - 1, c(0, cut[-K])) }
for (k in 1:K) for (g in 0:1) { ix <- which(site == k & y == g); fold[ix] <- sample(rep_len(1:NF, length(ix))) }

llRows <- function(beta, ix) { eta <- as.vector(X1[ix, , drop = FALSE] %*% beta); p <- plogis(eta)
  p <- pmin(pmax(p, 1e-15), 1 - 1e-15); y[ix] * log(p) + (1 - y[ix]) * log(1 - p) }
siteScores <- function(beta, te) { l <- llRows(beta, te); c(sapply(1:K, function(k) sum(l[site[te] == k])), pooled = sum(l)) }

## Columns that are all zero in the training rows are dropped (zero curvature) and restored as 0.
fitFL <- function(rowsIx, v, start = NULL) {
  keep <- c(1L, 1L + which(colSums(X1[rowsIx, -1, drop = FALSE] != 0) > 0))
  go <- function(mi) tryCatch(runCfg(X1[rowsIx, keep, drop = FALSE], y[rowsIx], P = 1L, variance = v, maxIterations = mi,
              startingCoefficients = if (is.null(start)) NULL else start[keep]), error = function(e) NULL)
  ## Retry with 5,000 passes if 1,000 are not enough; the retry is counted.
  r <- go(1000L); retried <- is.null(r); if (retried) r <- go(5000L)
  if (is.null(r)) stop(sprintf("v=%g: no convergence in 5,000 passes", v))
  r$retried <- retried
  b <- numeric(ncol(X1)); b[keep] <- r$beta; r$beta <- b; r }
out <- list(); betas <- list()
run1 <- function(scheme, v, f, start = NULL) {
  tr <- which(fold != f); te <- which(fold == f)
  r <- fitFL(tr, v, start)
  s <- siteScores(r$beta, te)
  out[[length(out) + 1L]] <<- data.frame(study = study, scheme = scheme, v = v, fold = f, passes = r$passes,
    rounds = r$R_total, nnz = sum(r$beta[-1] != 0), flag = r$flag, retried = r$retried, s1 = s[1], s2 = s[2], s3 = s[3], pooled = s[["pooled"]],
    sec = r$localSeconds)
  r$beta }
## cold: every (v, fold) starts from zero
for (v in GRID) for (f in 1:NF) betas[[sprintf("cold_%g_%d", v, f)]] <- run1("cold", v, f)
## warm: per fold, v from small to large, each fit starting from the previous solution
for (f in 1:NF) { b <- NULL; for (v in GRID) { b <- run1("warm", v, f, b); betas[[sprintf("warm_%g_%d", v, f)]] <- b } }
R <- do.call(rbind, out); rownames(R) <- NULL

pick <- function(sch) { r <- R[R$scheme == sch, ]
  fed <- tapply(r$s1 + r$s2 + r$s3, r$v, sum); cen <- tapply(r$pooled, r$v, sum)
  list(fed = fed, cen = cen, vFed = as.numeric(names(which.max(fed))), vCen = as.numeric(names(which.max(cen)))) }
pc <- pick("cold"); pw <- pick("warm")

## final fit: cold vs warm (from the mean of the fold solutions)
allr <- seq_along(y)
fc <- fitFL(allr, pc$vFed)
st <- Reduce(`+`, lapply(1:NF, function(f) betas[[sprintf("warm_%g_%d", pw$vFed, f)]])) / NF
fw <- fitFL(allr, pw$vFed, st)

## Reference: relative held-out score difference to a plain Cyclops fit (fold 1, every v).
cenDiff <- sapply(GRID, function(v) { tr <- which(fold != 1); te <- which(fold == 1)
  keep <- c(1L, 1L + which(colSums(X1[tr, -1, drop = FALSE] != 0) > 0))
  sx <- X1[tr, keep[-1], drop = FALSE]; colnames(sx) <- paste0("v", seq_len(ncol(sx)))
  cd <- createCyclopsData(treatment ~ 1, data = data.frame(treatment = y[tr]), sx = sx, modelType = "lr", floatingPoint = 64)
  cfit <- function(mi) tryCatch({ fit <- fitCyclopsModel(cd, prior = createPrior("laplace", variance = v, exclude = "(Intercept)", useCrossValidation = FALSE),
    control = createControl(convergenceType = "lange", seed = 1L, noiseLevel = "silent", tolerance = 1e-6, maxIterations = mi)); unname(coef(fit)) },
    error = function(e) NULL)
  cb <- cfit(1000L); if (is.null(cb)) cb <- cfit(5000L); if (is.null(cb)) return(NA_real_)   # NA if the reference fit fails
  b <- numeric(ncol(X1)); b[keep] <- cb
  sC <- sum(llRows(b, te)); sF <- sum(llRows(betas[[sprintf("cold_%g_%d", v, 1L)]], te)); abs(sC - sF) / abs(sF) })
## v chosen by the Cyclops built-in CV, for reference
source(file.path(FP_EXP, "common/kitcv.R")); auto <- fitCV(X1[, -1], y)

sc <- sort(pc$fed, decreasing = TRUE)
summ <- data.frame(study = study, n = length(y), d = ncol(X1) - 1, nGrid = length(GRID),
  vFedCold = pc$vFed, vCenCold = pc$vCen, vFedWarm = pw$vFed, vAutoCyclops = auto$variance,
  maxAbsDecomp = max(abs(pc$fed - pc$cen)), gapTop2 = unname(sc[1] - sc[2]), maxScore = max(abs(pc$fed)),
  maxRelScoreCentral = max(cenDiff, na.rm = TRUE), nCentralFail = sum(is.na(cenDiff)),
  maxRelScoreWarmCold = max(abs(pw$fed - pc$fed) / abs(pc$fed)),
  roundsCV_cold = sum(R$rounds[R$scheme == "cold"]), roundsCV_warm = sum(R$rounds[R$scheme == "warm"]),
  roundsFinal_cold = fc$R_total, roundsFinal_warm = fw$R_total, roundsSingleFL = fc$R_total,
  passesCV_cold = sum(R$passes[R$scheme == "cold"]), passesCV_warm = sum(R$passes[R$scheme == "warm"]),
  passesFinal_cold = fc$passes, passesFinal_warm = fw$passes,
  maxAbsPSFinalWarmCold = max(abs(plogis(as.vector(X1 %*% fw$beta)) - plogis(as.vector(X1 %*% fc$beta)))),
  corPSFinalWarmCold = cor(as.vector(X1 %*% fw$beta), as.vector(X1 %*% fc$beta)))
dir.create(file.path(FP_OUT, "fedcv"), showWarnings = FALSE)
write.csv(R, sprintf(file.path(FP_OUT, "fedcv/%s_runs.csv"), study), row.names = FALSE)
write.csv(summ, sprintf(file.path(FP_OUT, "fedcv/%s_summary.csv"), study), row.names = FALSE)
cat(sprintf("%-29s v*(fed/cen/warm/auto) %.4g/%.4g/%.4g/%.4g  decomp %.1e  gap %.3f  CV cost cold %.1fx warm %.1fx\n",
  study, pc$vFed, pc$vCen, pw$vFed, auto$variance, summ$maxAbsDecomp, summ$gapTop2,
  (summ$roundsCV_cold + summ$roundsFinal_cold) / summ$roundsSingleFL, (summ$roundsCV_warm + summ$roundsFinal_warm) / summ$roundsSingleFL))
