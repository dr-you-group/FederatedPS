## Site-size sweep: MIMIC split into a partner A (fixed 60%) and a small site B of varying size.
## Evaluation is on B only, so the shared model may use all of A.
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))

source(file.path(FP_EXP, "common/kit.R"))
suppressPackageStartupMessages(library(Matrix))
a <- commandArgs(TRUE); study <- a[1]; size <- as.integer(a[2])
CV <- "cv" %in% a   # "cv": choose the prior variance by cross-validation
source(file.path(FP_EXP, "common/kitcv.R"))
NREP <- 5L; NFOLD <- 5L; SEED <- 20261002L

dd <- readRDS(sprintf(file.path(FP_DATA, "design/%s__mimiciv.rds"), study))
rows <- sort(dd$rowId); feat <- dd$covariateIds
i <- match(dd$cov$rowId, rows); j <- match(dd$cov$covariateId, feat)
ok <- !is.na(i) & !is.na(j)
X <- sparseMatrix(i=i[ok], j=j[ok], x=dd$cov$covariateValue[ok], dims=c(length(rows), length(feat)))
y <- dd$treatment[match(rows, dd$rowId)]
rm(dd); invisible(gc())

## A: treatment-stratified 60%, fixed. B is drawn from the remaining 40%.
set.seed(SEED)
iA <- unlist(lapply(c(0,1), function(g) { ix <- which(y==g); sort(sample(ix, round(0.6*length(ix)))) }))
iA <- sort(iA); pool <- setdiff(seq_along(y), iA)
if (size > length(pool)) { cat(sprintf("%s size=%d exceeds the pool (%d), skipped\n", study, size, length(pool))); quit(status=0) }

fit1 <- function(Xs, ys) {
  pres <- which(colSums(Xs != 0) > 0)
  if (!length(pres) || length(unique(ys)) < 2) return(NULL)
  r <- try(runCfg(cbind(Matrix(1, nrow(Xs), 1, sparse=TRUE), Xs[, pres, drop=FALSE]), ys,
                  P=1L, alpha=1), silent=TRUE)
  if (inherits(r,"try-error") || r$diverged) return(NULL)
  list(b0=r$beta[1], bj=r$beta[-1], idx=pres) }
if (CV) fit1 <- function(Xs, ys) fitCV(Xs, ys)
pred1 <- function(m, Xs) if (is.null(m)) rep(NA_real_, nrow(Xs)) else
  1/(1+exp(-(m$b0 + as.vector(Xs[, m$idx, drop=FALSE] %*% m$bj))))
auc1 <- function(p, yy) { ok <- is.finite(p); p <- p[ok]; yy <- yy[ok]
  if (length(unique(yy)) < 2) return(NA_real_)
  r <- rank(p); n1 <- as.numeric(sum(yy==1)); n0 <- as.numeric(sum(yy==0))
  (sum(r[yy==1]) - n1*(n1+1)/2)/(n1*n0) }

XA <- X[iA, , drop=FALSE]; yA <- y[iA]
mPartner <- fit1(XA, yA)                       # partner-only model, once per study

out <- list()
for (rep in 1:NREP) {
  set.seed(SEED + 1000L*rep + size)
  pr <- mean(y[pool])
  nT <- max(2L, round(size*pr)); nC <- max(2L, size - nT)
  cand1 <- pool[y[pool]==1]; cand0 <- pool[y[pool]==0]
  if (nT > length(cand1) || nC > length(cand0)) next
  iB <- sort(c(sample(cand1, nT), sample(cand0, nC)))
  XB <- X[iB, , drop=FALSE]; yB <- y[iB]
  fold <- integer(length(yB))
  for (g in c(0,1)) { ix <- which(yB==g); fold[ix] <- sample(rep_len(1:NFOLD, length(ix))) }
  ps <- matrix(NA_real_, length(yB), 3, dimnames=list(NULL, c("local","partner","shared")))
  for (f in 1:NFOLD) {
    tr <- which(fold != f); te <- which(fold == f)
    ps[te,"local"]   <- pred1(fit1(XB[tr,,drop=FALSE], yB[tr]), XB[te,,drop=FALSE])
    ps[te,"partner"] <- pred1(mPartner, XB[te,,drop=FALSE])
    ps[te,"shared"]  <- pred1(fit1(rbind(XA, XB[tr,,drop=FALSE]), c(yA, yB[tr])), XB[te,,drop=FALSE])
  }
  for (m in colnames(ps)) out[[length(out)+1L]] <- data.frame(
    study=study, size=size, rep=rep, model=m, nT=sum(yB==1), nC=sum(yB==0),
    nA=length(yA), eff=4*sum(yB==1)*sum(yB==0)/length(yB), auc=auc1(ps[,m], yB))
}
res <- do.call(rbind, out)
OUT <- sprintf(file.path(FP_OUT, "sweep%s"), if (CV) "_cv" else ""); dir.create(OUT, showWarnings=FALSE)
write.csv(res, sprintf(paste0(OUT, "/%s_%d.csv"), study, size), row.names=FALSE)
cat(sprintf("%-29s size=%6d  A=%6d  AUC local %.3f / partner %.3f / shared %.3f\n", study, size,
    length(yA), mean(res$auc[res$model=="local"], na.rm=TRUE),
    mean(res$auc[res$model=="partner"], na.rm=TRUE), mean(res$auc[res$model=="shared"], na.rm=TRUE)))
