## Plasmode simulation: real covariates and treatment, simulated outcomes with a known effect.
## Sites as in sweep_size.R: partner A (treatment-stratified 60% of MIMIC, fixed) + site B.
## Methods: local (B only), partner (A only), shared (A + B, equal to FL), crude.
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))

source(file.path(FP_EXP, "common/kit.R"))
suppressPackageStartupMessages({ library(Matrix); library(survival) })
a <- commandArgs(TRUE); study <- a[1]; size <- as.integer(a[2])
CV <- isTRUE(a[3] == "cv")   # "cv": choose the prior variance by cross-validation
source(file.path(FP_EXP, "common/kitcv.R"))
NREP <- 20L; NDRAW <- 10L; SEED <- 20261002L     # same seed as sweep_size.R, so the same A
GAMMA <- 0.7; NCONF <- 50L; EVRATE <- 0.40
BETAS <- c(null = 0, hr2 = log(2))

dd <- readRDS(sprintf(file.path(FP_DATA, "design/%s__mimiciv.rds"), study))
rows <- sort(dd$rowId); feat <- dd$covariateIds
i <- match(dd$cov$rowId, rows); j <- match(dd$cov$covariateId, feat)
ok <- !is.na(i) & !is.na(j)
X <- sparseMatrix(i=i[ok], j=j[ok], x=dd$cov$covariateValue[ok], dims=c(length(rows), length(feat)))
y <- dd$treatment[match(rows, dd$rowId)]
rm(dd); invisible(gc())

## Confounder z: signed sum of the NCONF covariates with the largest |SMD| against treatment.
m1 <- colMeans(X[y==1, , drop=FALSE]); m0 <- colMeans(X[y==0, , drop=FALSE])
v1 <- colMeans(X[y==1, , drop=FALSE]^2) - m1^2; v0 <- colMeans(X[y==0, , drop=FALSE]^2) - m0^2
smd <- (m1 - m0) / sqrt(pmax((v1 + v0)/2, 1e-12))
prev <- colMeans(X != 0); smd[prev < 0.01] <- 0
top <- order(-abs(smd))[1:NCONF]
z <- as.vector(X[, top, drop=FALSE] %*% sign(smd[top])); z <- (z - mean(z)) / sd(z)

## Baseline hazard giving an event rate of EVRATE over follow-up H = 1 under the null.
lam0 <- uniroot(function(l) mean(1 - exp(-l * exp(GAMMA*z))) - EVRATE, c(1e-6, 100))$root

## Truth: marginal ATT log HR over all treated patients, from paired potential outcomes.
trueATT <- sapply(BETAS, function(b) { if (b == 0) return(0)
  t1 <- which(y == 1); set.seed(SEED + 7L)
  mean(replicate(5, { u <- rexp(length(t1))
    T1 <- u / (lam0*exp(b + GAMMA*z[t1])); T0 <- u / (lam0*exp(GAMMA*z[t1]))
    d <- data.frame(time = pmin(c(T1, T0), 1), ev = as.integer(c(T1, T0) <= 1), tr = rep(1:0, each = length(t1)))
    coef(coxph(Surv(time, ev) ~ tr, data = d)) })) })

set.seed(SEED)
iA <- unlist(lapply(c(0,1), function(g) { ix <- which(y==g); sort(sample(ix, round(0.6*length(ix)))) }))
iA <- sort(iA); pool <- setdiff(seq_along(y), iA)
if (size > length(pool)) { cat(sprintf("%s size=%d exceeds the pool, skipped\n", study, size)); quit(status=0) }

fit1 <- function(Xs, ys) {
  pres <- which(colSums(Xs != 0) > 0)
  if (!length(pres) || length(unique(ys)) < 2) return(NULL)
  r <- try(runCfg(cbind(Matrix(1, nrow(Xs), 1, sparse=TRUE), Xs[, pres, drop=FALSE]), ys, P=1L, alpha=1), silent=TRUE)
  if (inherits(r,"try-error") || r$diverged) return(NULL)
  list(b0=r$beta[1], bj=r$beta[-1], idx=pres) }
if (CV) fit1 <- function(Xs, ys) fitCV(Xs, ys)
pred1 <- function(m, Xs) if (is.null(m)) NULL else
  1/(1+exp(-(m$b0 + as.vector(Xs[, m$idx, drop=FALSE] %*% m$bj))))
match1 <- function(ps, yy) {
  if (is.null(ps)) return(NULL)
  ps <- pmin(pmax(ps, 1e-8), 1 - 1e-8)
  m <- try(CohortMethod::matchOnPs(data.frame(rowId = seq_along(yy), treatment = yy, propensityScore = ps),
         matchOnPsArgs = CohortMethod::createMatchOnPsArgs(caliper = 0.2, caliperScale = "standardized logit",
         maxRatio = 1)), silent = TRUE)
  if (inherits(m, "try-error") || sum(m$treatment == 1) < 2) return(NULL)
  list(idx = m$rowId, stratum = m$stratumId) }
cox1 <- function(time, ev, tr, cl) {
  if (sum(ev) < 2 || length(unique(tr[ev == 1])) < 2) return(c(NA, NA))
  f <- try(coxph(Surv(time, ev) ~ tr + cluster(cl)), silent = TRUE)
  if (inherits(f, "try-error")) return(c(NA, NA))
  c(coef(f), sqrt(diag(vcov(f)))) }
smdz <- function(zz, tt) (mean(zz[tt==1]) - mean(zz[tt==0])) / sqrt((var(zz[tt==1]) + var(zz[tt==0]))/2)

XA <- X[iA, , drop=FALSE]; yA <- y[iA]
mPartner <- fit1(XA, yA)

out <- list()
for (rep in 1:NREP) {
  set.seed(SEED + 1000L*rep + size)
  pr <- mean(y[pool]); nT <- max(2L, round(size*pr)); nC <- max(2L, size - nT)
  cand1 <- pool[y[pool]==1]; cand0 <- pool[y[pool]==0]
  if (nT > length(cand1) || nC > length(cand0)) next
  iB <- sort(c(sample(cand1, nT), sample(cand0, nC)))
  XB <- X[iB, , drop=FALSE]; yB <- y[iB]; zB <- z[iB]
  PS <- list(local   = pred1(fit1(XB, yB), XB),
             partner = pred1(mPartner, XB),
             shared  = pred1(fit1(rbind(XA, XB), c(yA, yB)), XB))
  M <- lapply(PS, match1, yy = yB)
  M$crude <- list(idx = seq_along(yB), stratum = seq_along(yB))
  for (k in 1:NDRAW) {
    u <- rexp(length(yB))
    for (sc in names(BETAS)) {
      Tm <- u / (lam0 * exp(BETAS[[sc]]*yB + GAMMA*zB)); ev <- as.integer(Tm <= 1); tm <- pmin(Tm, 1)
      for (meth in names(M)) { mm <- M[[meth]]
        if (is.null(mm)) { est <- c(NA, NA); np <- 0L; ne <- 0L; sz <- NA } else {
          ix <- mm$idx; est <- cox1(tm[ix], ev[ix], yB[ix], mm$stratum)
          np <- if (meth == "crude") NA_integer_ else sum(yB[ix] == 1); ne <- sum(ev[ix]); sz <- smdz(zB[ix], yB[ix]) }
        out[[length(out)+1L]] <- data.frame(study=study, size=size, rep=rep, draw=k, scenario=sc,
          truth=trueATT[[sc]], method=meth, nT=nT, nC=nC, pairs=np, events=ne, smdZ=sz,
          logHR=est[1], se=est[2])
      } } } }
res <- do.call(rbind, out)
OUT <- sprintf(file.path(FP_OUT, "plasmode%s"), if (CV) "_cv" else ""); dir.create(OUT, showWarnings=FALSE)
write.csv(res, sprintf(paste0(OUT, "/%s_%d.csv"), study, size), row.names=FALSE)
s <- aggregate(cbind(bias = logHR - truth, smdZ) ~ method, data = res[res$scenario=="null", ], FUN = function(v) mean(abs(v)))
cat(sprintf("%-29s n=%5d  |bias| null: %s\n", study, size,
    paste(sprintf("%s %.3f", s$method, s$bias), collapse = " / ")))
