## Convergence tolerance: full-data fit at the selected v, cold start vs warm start
## (from the next smaller grid value), tol in {1e-6, 1e-8, 1e-10}.
## Reports passes, rounds, KKT violation, objective and PS differences.
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
source(file.path(FP_EXP, "common/kit.R"))
a <- commandArgs(TRUE); study <- a[1]; vstar <- as.numeric(a[2])
GRID <- 10^seq(-2.5, 0, by = 0.25); vprev <- max(GRID[GRID < vstar * 0.999])
TOLS <- c(1e-6, 1e-8, 1e-10)
dd <- readRDS(sprintf(file.path(FP_DATA, "design/%s__mimiciv.rds"), study))
rows <- sort(dd$rowId); feat <- dd$covariateIds
i <- match(dd$cov$rowId, rows); j <- match(dd$cov$covariateId, feat); ok <- !is.na(i) & !is.na(j)
X <- sparseMatrix(i=i[ok], j=j[ok], x=dd$cov$covariateValue[ok], dims=c(length(rows), length(feat)))
y <- dd$treatment[match(rows, dd$rowId)]; rm(dd); invisible(gc())
X <- X[, colSums(X != 0) > 0]; X1 <- as(cbind(Matrix(1, nrow(X), 1, sparse = TRUE), X), "CsparseMatrix"); rm(X)
lam <- function(v) sqrt(2 / v)
diag1 <- function(b, v) { eta <- as.vector(X1 %*% b); p <- plogis(eta)
  g <- as.vector(crossprod(X1, y - p))[-1]; bj <- b[-1]; L <- lam(v)
  kkt <- ifelse(bj == 0, pmax(abs(g) - L, 0), abs(g - L * sign(bj)))
  ll <- sum(y * eta - log1p(exp(eta)))
  list(p = p, kkt = max(kkt), kktRel = max(kkt) / L, obj = -ll + L * sum(abs(bj)), nnz = sum(bj != 0), int = abs(sum(y - p))) }
fit <- function(v, tol, start = NULL) tryCatch(runCfg(X1, y, P = 1L, variance = v, tol = tol, maxIterations = 20000L,
  startingCoefficients = start), error = function(e) NULL)
pre <- fit(vprev, 1e-6)                       # warm-start point
out <- list(); ref <- NULL
for (tol in TOLS) for (sch in c("cold","warm")) {
  r <- fit(vstar, tol, if (sch == "warm") pre$beta else NULL)
  if (is.null(r)) { out[[length(out)+1]] <- data.frame(study=study, v=vstar, tol=tol, scheme=sch, ok=FALSE); next }
  dg <- diag1(r$beta, vstar)
  out[[length(out)+1]] <- data.frame(study=study, v=vstar, tol=tol, scheme=sch, ok=TRUE, passes=r$passes, rounds=r$R_total,
    nnz=dg$nnz, obj=dg$obj, kkt=dg$kkt, kktRel=dg$kktRel, intGrad=dg$int)
  assign(sprintf("p_%s_%g", sch, tol), dg$p) }
R <- do.call(rbind, out)
## PS differences: warm vs cold, and vs the cold 1e-10 solution
best <- get("p_cold_1e-10")
R$maxPSdiffWarmCold <- sapply(seq_len(nrow(R)), function(k) max(abs(get(sprintf("p_warm_%g", R$tol[k])) - get(sprintf("p_cold_%g", R$tol[k])))))
R$maxPSvsRef <- sapply(seq_len(nrow(R)), function(k) max(abs(get(sprintf("p_%s_%g", R$scheme[k], R$tol[k])) - best)))
R$objGapVsBest <- R$obj - min(R$obj)
dir.create(file.path(FP_OUT, "tolsens"), showWarnings = FALSE)
write.csv(R, sprintf(file.path(FP_OUT, "tolsens/%s.csv"), study), row.names = FALSE)
for (k in seq_len(nrow(R))) cat(sprintf("%-28s tol %.0e %-4s passes %5d kktRel %.1e PSdiff(w-c) %.1e PSvsRef %.1e objGap %.2e\n",
  study, R$tol[k], R$scheme[k], R$passes[k], R$kktRel[k], R$maxPSdiffWarmCold[k], R$maxPSvsRef[k], R$objGapVsBest[k]))
