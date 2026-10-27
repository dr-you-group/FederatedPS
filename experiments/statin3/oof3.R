## Out-of-fold PS for local, global with a shared intercept and global with site intercepts.
## Folds, prior and preprocessing are identical across the three models.
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
source(file.path(FP_EXP, "common/kit.R"))
meta <- readRDS(file.path(FP_OUT, "statin3/meta.rds")); axis <- meta$axis; SITES <- meta$sites
S <- lapply(SITES, function(nm){ dd <- readRDS(sprintf(file.path(FP_OUT, "sitedata/tri/%s.rds"), nm))
  j <- match(as.numeric(colnames(dd$x)), axis); t <- Matrix::summary(as(dd$x,"TsparseMatrix"))
  Xg <- sparseMatrix(i=t$i, j=j[t$j], x=t$x, dims=c(nrow(dd$x), length(axis)))
  list(Xg=as(Xg,"CsparseMatrix"), Xl=as(dd$x,"CsparseMatrix"), y=dd$treatment) })
names(S) <- SITES
Xc <- do.call(rbind, lapply(S,`[[`,"Xg")); y <- unlist(lapply(S,`[[`,"y"))
site <- rep(SITES, sapply(S, function(s) nrow(s$Xg)))
dmM <- as.numeric(site=="mimic"); dmE <- as.numeric(site=="ehrshot")
NF <- 5L; EVAL <- c("ehrshot","mimic")
set.seed(777)                                  # draw all folds first
folds <- lapply(EVAL, function(sn) sample(rep(1:NF, length.out=sum(site==sn))))
names(folds) <- EVAL
saveRDS(folds, file.path(FP_OUT, "statin3/oof_folds.rds"))

## Fit helper: drop columns that are all zero in the training rows.
fitPred <- function(sxTr, yTr, sxTe, excl) {
  keep <- as.vector(Matrix::colSums(sxTr != 0) > 0)
  keep[colnames(sxTr) %in% setdiff(excl, "(Intercept)")] <- TRUE   # keep the site dummies
  sxTr <- sxTr[, keep, drop=FALSE]; sxTe <- sxTe[, keep, drop=FALSE]
  cd <- Cyclops::createCyclopsData(treatment ~ 1, data=data.frame(treatment=yTr), sx=sxTr,
                                   modelType="lr", floatingPoint=64)
  cd$coefficientNames <- c("(Intercept)", colnames(sxTr))
  f <- Cyclops::fitCyclopsModel(cd,
    prior=Cyclops::createPrior("laplace", variance=1, exclude=intersect(excl, c("(Intercept)", colnames(sxTr))),
                               useCrossValidation=FALSE),
    control=Cyclops::createControl(convergenceType="lange", seed=1L, noiseLevel="silent",
                                   tolerance=1e-6, maxIterations=1000L),
    startingCoefficients=rep(0, ncol(sxTr)+1L))
  b <- unname(stats::coef(f))
  1/(1+exp(-(b[1] + as.vector(sxTe %*% b[-1]))))
}
sxA <- Xc; colnames(sxA) <- paste0("v", seq_len(ncol(Xc)))
sxB <- cbind(Matrix(dmM, ncol=1, sparse=TRUE), Matrix(dmE, ncol=1, sparse=TRUE), Xc)
colnames(sxB) <- c("site_mimic","site_ehrshot", paste0("v", seq_len(ncol(Xc))))

PS <- list()
for (sn in EVAL) {
  ii <- which(site==sn); fo <- folds[[sn]]; n <- length(ii)
  psL <- numeric(n); psA <- numeric(n); psB <- numeric(n)
  for (k in 1:NF) {
    tr <- which(fo!=k); te <- which(fo==k); drop <- ii[te]; keepR <- setdiff(seq_along(y), drop)
    sl <- S[[sn]]$Xl; colnames(sl) <- paste0("v", seq_len(ncol(sl)))
    psL[te] <- fitPred(sl[tr,,drop=FALSE], S[[sn]]$y[tr], sl[te,,drop=FALSE], "(Intercept)")
    psA[te] <- fitPred(sxA[keepR,,drop=FALSE], y[keepR], sxA[drop,,drop=FALSE], "(Intercept)")
    psB[te] <- fitPred(sxB[keepR,,drop=FALSE], y[keepR], sxB[drop,,drop=FALSE],
                       c("(Intercept)","site_mimic","site_ehrshot"))
    cat(sprintf("  %s fold %d done\n", sn, k)); flush(stdout())
  }
  PS[[sn]] <- list(local=psL, sharedGlobal=psA, siteGlobal=psB, y=S[[sn]]$y)
}
saveRDS(PS, file.path(FP_OUT, "statin3/oof3_ps.rds"))
cat("\nOOF propensity scores done\n")
