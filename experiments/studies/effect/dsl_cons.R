## Data-shared lasso (common/dsl.R) next to local, transfer and pooled, in the settings of
## plasmode_cons.R. All prior variances chosen by CV. setting:
##   homo    = partners from MIMIC
##   cluster = partners from the other MIMIC covariate cluster (as in hetero.R)
##   synpuf  = partners from SynPUF
## Per replicate: 5-fold OOF AUC of each method, then full-data PS fits, 1:1 matching and a Cox
## model on simulated outcomes (bias, RMSE, coverage).
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
source(file.path(FP_EXP, "common/kit.R"))
suppressPackageStartupMessages({ library(Matrix); library(survival) })
a <- commandArgs(TRUE); study <- a[1]; setting <- a[2]
CV <- TRUE
source(file.path(FP_EXP, "common/kitcv.R")); source(file.path(FP_EXP, "common/dsl.R"))
NREP <- 20L; NDRAW <- 10L; NFOLD <- 5L; KSITE <- 3L; NN <- 1000L; SEED <- 20261007L
GAMMA <- 0.7; NCONF <- 50L; EVRATE <- 0.40; BETAS <- c(null = 0, hr2 = log(2))

load1 <- function(site) {
  dd <- readRDS(sprintf(file.path(FP_DATA, "design/%s__%s.rds"), study, site))
  rows <- sort(dd$rowId); feat <- dd$covariateIds
  i <- match(dd$cov$rowId, rows); j <- match(dd$cov$covariateId, feat); ok <- !is.na(i) & !is.na(j)
  list(X = sparseMatrix(i=i[ok], j=j[ok], x=dd$cov$covariateValue[ok], dims=c(length(rows), length(feat))),
       feat = feat, y = dd$treatment[match(rows, dd$rowId)]) }
M <- load1("mimiciv"); X <- M$X; y <- M$y
S <- if (setting == "synpuf") load1("synpuf") else NULL
axis <- sort(unique(c(M$feat, if (!is.null(S)) S$feat)))
onAx <- function(D, ix) { t <- summary(as(D$X[ix,,drop=FALSE], "TsparseMatrix")); j <- match(D$feat, axis)
  sparseMatrix(i=t$i, j=j[t$j], x=t$x, dims=c(length(ix), length(axis))) }

## Confounder z and baseline hazard as in plasmode.R (computed on all of MIMIC).
m1 <- colMeans(X[y==1,,drop=FALSE]); m0 <- colMeans(X[y==0,,drop=FALSE])
v1 <- colMeans(X[y==1,,drop=FALSE]^2) - m1^2; v0 <- colMeans(X[y==0,,drop=FALSE]^2) - m0^2
smd <- (m1 - m0) / sqrt(pmax((v1 + v0)/2, 1e-12)); smd[colMeans(X != 0) < 0.01] <- 0
top <- order(-abs(smd))[1:NCONF]
z <- as.vector(X[, top, drop=FALSE] %*% sign(smd[top])); z <- (z - mean(z)) / sd(z)
lam0 <- uniroot(function(l) mean(1 - exp(-l * exp(GAMMA*z))) - EVRATE, c(1e-6, 100))$root
trueATT <- sapply(BETAS, function(b) { if (b == 0) return(0)
  t1 <- which(y == 1); set.seed(SEED + 7L)
  mean(replicate(5, { u <- rexp(length(t1))
    T1 <- u / (lam0*exp(b + GAMMA*z[t1])); T0 <- u / (lam0*exp(GAMMA*z[t1]))
    d <- data.frame(time = pmin(c(T1, T0), 1), ev = as.integer(c(T1, T0) <= 1), tr = rep(1:0, each = length(t1)))
    coef(coxph(Surv(time, ev) ~ tr, data = d)) })) })

## Clusters: same procedure and seed as hetero.R.
if (setting == "cluster") {
  set.seed(20261005L)
  pv <- colMeans(X != 0); tp <- order(-pv)[1:min(200L, ncol(X))]
  cl <- kmeans(as.matrix(X[, tp, drop=FALSE]), centers = 2L, nstart = 5L, iter.max = 50L)$cluster
  P1 <- which(cl == 1); P2 <- which(cl == 2); if (length(P2) > length(P1)) { t <- P1; P1 <- P2; P2 <- t }
} else { P1 <- P2 <- seq_along(y) }

fit1 <- function(Xs, ys) { pres <- which(colSums(Xs != 0) > 0)
  if (!length(pres) || length(unique(ys)) < 2) return(NULL)
  r <- try(runCfg(cbind(Matrix(1, nrow(Xs), 1, sparse=TRUE), Xs[, pres, drop=FALSE]), ys, P=1L, alpha=1), silent=TRUE)
  if (inherits(r,"try-error") || r$diverged) return(NULL)
  list(b0=r$beta[1], bj=r$beta[-1], idx=pres) }
if (CV) fit1 <- function(Xs, ys) fitCV(Xs, ys)
pred1 <- function(m, Xs) if (is.null(m)) rep(NA_real_, nrow(Xs)) else
  1/(1+exp(-(m$b0 + as.vector(Xs[, m$idx, drop=FALSE] %*% m$bj))))
auc1 <- function(p, yy) { ok <- is.finite(p); p <- p[ok]; yy <- yy[ok]; if (length(unique(yy)) < 2) return(NA_real_)
  r <- rank(p); n1 <- as.numeric(sum(yy==1)); n0 <- as.numeric(sum(yy==0)); (sum(r[yy==1]) - n1*(n1+1)/2)/(n1*n0) }
match1 <- function(ps, yy) { if (is.null(ps) || any(!is.finite(ps))) return(NULL)
  ps <- pmin(pmax(ps, 1e-8), 1 - 1e-8)
  m <- try(CohortMethod::matchOnPs(data.frame(rowId = seq_along(yy), treatment = yy, propensityScore = ps),
         matchOnPsArgs = CohortMethod::createMatchOnPsArgs(caliper = 0.2, caliperScale = "standardized logit", maxRatio = 1)), silent = TRUE)
  if (inherits(m, "try-error") || sum(m$treatment == 1) < 2) return(NULL)
  list(idx = m$rowId, stratum = m$stratumId) }
cox1 <- function(time, ev, tr, cl) { if (sum(ev) < 2 || length(unique(tr[ev == 1])) < 2) return(c(NA, NA))
  f <- try(coxph(Surv(time, ev) ~ tr + cluster(cl)), silent = TRUE)
  if (inherits(f, "try-error")) return(c(NA, NA)); c(coef(f), sqrt(diag(vcov(f)))) }
drawM <- function(pool, used) { yy <- y[pool]; pr <- mean(y); nT <- max(2L, round(NN*pr)); nC <- max(2L, NN-nT)
  c1 <- setdiff(pool[yy==1], used); c0 <- setdiff(pool[yy==0], used)
  if (nT > length(c1) || nC > length(c0)) return(NULL); sort(c(sample(c1, nT), sample(c0, nC))) }
drawS <- function() { pr <- mean(S$y); nT <- max(2L, round(NN*pr)); nC <- max(2L, NN-nT)
  sort(c(sample(which(S$y==1), nT), sample(which(S$y==0), nC))) }

out <- list()
for (rep in 1:NREP) {
  set.seed(SEED + 1000L*rep + nchar(setting))
  ix <- drawM(P1, integer(0)); if (is.null(ix)) next
  used <- ix; Xo <- list(); yo <- list(); bad <- FALSE
  for (k in 2:KSITE) {
    if (setting == "synpuf") { iy <- drawS(); Xo[[k-1]] <- onAx(S, iy); yo[[k-1]] <- S$y[iy] }
    else { iy <- drawM(if (setting == "cluster") P2 else P1, used); if (is.null(iy)) { bad <- TRUE; break }
      used <- c(used, iy); Xo[[k-1]] <- onAx(M, iy); yo[[k-1]] <- y[iy] } }
  if (bad) next
  siteO <- rep(seq_along(yo) + 1L, lengths(yo)); Xo <- do.call(rbind, Xo); yo <- unlist(yo)
  X1 <- onAx(M, ix); y1 <- y[ix]; z1 <- z[ix]
  ## OOF AUC per method
  fold <- integer(length(y1)); for (g in c(0,1)) { q <- which(y1==g); fold[q] <- sample(rep_len(1:NFOLD, length(q))) }
  mO <- fit1(Xo, yo)
  oof <- matrix(NA_real_, length(y1), 4, dimnames = list(NULL, c("local","others","shared","dsl")))
  for (f in 1:NFOLD) { tr <- which(fold != f); te <- which(fold == f)
    oof[te,"local"]  <- pred1(fit1(X1[tr,,drop=FALSE], y1[tr]), X1[te,,drop=FALSE])
    oof[te,"others"] <- pred1(mO, X1[te,,drop=FALSE])
    oof[te,"shared"] <- pred1(fit1(rbind(Xo, X1[tr,,drop=FALSE]), c(yo, y1[tr])), X1[te,,drop=FALSE])
    oof[te,"dsl"]    <- predDSL(fitDSL(rbind(X1[tr,,drop=FALSE], Xo), c(y1[tr], yo), c(rep(1L, length(tr)), siteO), KSITE), X1[te,,drop=FALSE], 1L) }
  oofAuc <- apply(oof, 2, auc1, yy = y1)
  ## full-data PS fits, matching and outcome models
  mD <- fitDSL(rbind(X1, Xo), c(y1, yo), c(rep(1L, length(y1)), siteO), KSITE)
  PS <- list(local = pred1(fit1(X1, y1), X1), others = pred1(mO, X1), shared = pred1(fit1(rbind(Xo, X1), c(yo, y1)), X1),
             dsl = predDSL(mD, X1, 1L))
  Mt <- lapply(PS, match1, yy = y1); Mt$crude <- list(idx = seq_along(y1), stratum = seq_along(y1))
  for (k in 1:NDRAW) { u <- rexp(length(y1))
    for (sc in names(BETAS)) {
      Tm <- u / (lam0 * exp(BETAS[[sc]]*y1 + GAMMA*z1)); ev <- as.integer(Tm <= 1); tm <- pmin(Tm, 1)
      for (meth in names(Mt)) { mm <- Mt[[meth]]
        est <- if (is.null(mm)) c(NA, NA) else cox1(tm[mm$idx], ev[mm$idx], y1[mm$idx], mm$stratum)
        sz <- if (is.null(mm)) NA else { zz <- z1[mm$idx]; tt <- y1[mm$idx]
          (mean(zz[tt==1]) - mean(zz[tt==0])) / sqrt((var(zz[tt==1]) + var(zz[tt==0]))/2) }
        out[[length(out)+1L]] <- data.frame(study=study, setting=setting, rep=rep, draw=k, scenario=sc,
          truth=trueATT[[sc]], method=meth, pairs=if (is.null(mm) || meth=="crude") NA else sum(y1[mm$idx]==1),
          smdZ=sz, logHR=est[1], se=est[2],
          oofLocal=oofAuc[["local"]], oofOthers=oofAuc[["others"]], oofShared=oofAuc[["shared"]], oofDsl=oofAuc[["dsl"]],
          dslR=if (is.null(mD)) NA else mD$r) } } } }
res <- do.call(rbind, out)
OUT <- file.path(FP_OUT, "dsl_cons"); dir.create(OUT, showWarnings=FALSE)
write.csv(res, sprintf(paste0(OUT, "/%s__%s.csv"), study, setting), row.names=FALSE)
s <- aggregate(e ~ method, data = transform(res[res$scenario=="null",], e = logHR - truth), FUN = function(v) sqrt(mean(v^2, na.rm=TRUE)))
cat(sprintf("%-29s %-7s RMSE null: %s\n", study, setting, paste(sprintf("%s %.3f", s$method, s$e), collapse=" / ")))
