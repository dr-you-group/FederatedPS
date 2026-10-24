## How often the trust region binds, and at what size.
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
source(file.path(FP_EXP, "validation/common.R")); useCyclops("patched")
lam <- lambdaOf(1)
dd <- readRDS(file.path(FP_DATA, "statin/mimic/design.rds"))
rows <- sort(dd$rowId); feat <- dd$covariateIds
i <- match(dd$cov$rowId, rows); j <- match(dd$cov$covariateId, feat); ok <- !is.na(i)&!is.na(j)
Xs <- sparseMatrix(i=i[ok], j=j[ok], x=dd$cov$covariateValue[ok], dims=c(length(rows),length(feat)))
Xs <- as(cbind(Matrix(1,length(rows),1,sparse=TRUE), Xs), "CsparseMatrix")
y  <- dd$treatment[match(rows, dd$rowId)]
set.seed(20260921); grp <- sample(rep(1:2, length.out=nrow(Xs)))
present <- Reduce(`|`, lapply(1:2, function(k) colSums(Xs[grp==k,,drop=FALSE]!=0)>0)); present[1] <- TRUE
X <- Xs[, present, drop=FALSE]; d <- ncol(X)

rawDelta <- function(g,h,b,pen){
  if(!is.finite(h)||h<=0) return(0)
  if(!pen) return(-g/h)
  nu <- -(g-lam)/h; pu <- -(g+lam)/h; s <- sign(b)
  if(s==0){ if(nu<0) nu else if(pu>0) pu else 0
  } else { dl <- if(s<0) nu else pu; if(sign(b+dl)!=s) -b else dl } }

probe <- function(P, alpha) {
  st <- new.env()
  st$nUpd <- 0; st$nClip <- 0; st$nFloor <- 0; st$nZeroStep <- 0
  st$sumRaw <- 0; st$sumApplied <- 0; st$maxRaw <- 0
  st$lastBeta <- rep(NA_real_, d); st$appliedAbs <- 0; st$nApplied <- 0
  cb <- function(coordinate, statistics) {
    if (coordinate > 0L) {
      w <- length(statistics) %/% 4L
      g <- statistics[1:w]; h <- statistics[(w+1):(2*w)]
      b <- statistics[(2*w+1):(3*w)]; bd <- statistics[(3*w+1):(4*w)]
      idx <- coordinate + seq_len(w) - 1L
      for (k in seq_len(w)) {
        rd <- rawDelta(g[k], h[k]/alpha, b[k], idx[k] != 1L)   # step before the bound
        st$nUpd <- st$nUpd + 1
        if (abs(rd) > bd[k]) st$nClip <- st$nClip + 1
        if (bd[k] <= 1e-3 + 1e-12) st$nFloor <- st$nFloor + 1
        if (rd == 0) st$nZeroStep <- st$nZeroStep + 1
        st$sumRaw <- st$sumRaw + abs(rd); st$maxRaw <- max(st$maxRaw, abs(rd))
        st$sumApplied <- st$sumApplied + min(abs(rd), bd[k])
        if (!is.na(st$lastBeta[idx[k]])) {
          st$appliedAbs <- st$appliedAbs + abs(b[k] - st$lastBeta[idx[k]]); st$nApplied <- st$nApplied + 1 }
        st$lastBeta[idx[k]] <- b[k]
      }
    }
    statistics
  }
  cd <- buildCyclops(X, y)
  fit <- Cyclops::fitCyclopsModel(cd,
    prior = Cyclops::createPrior("laplace", variance=1, exclude="(Intercept)", useCrossValidation=FALSE),
    control = Cyclops::createControl(convergenceType="lange", seed=1L, noiseLevel="silent",
              tolerance=1e-6, maxIterations=1000L, aggregate=cb, blockSize=P, alpha=alpha),
    startingCoefficients = rep(0, d))
  data.frame(P=P, alpha=alpha, passes=fit$iterations, coordUpdates=st$nUpd,
    pctClipped = 100*st$nClip/st$nUpd,
    pctBoundAtFloor = 100*st$nFloor/st$nUpd,
    pctZeroRawStep = 100*st$nZeroStep/st$nUpd,
    meanRawStep = st$sumRaw/st$nUpd,
    meanStepAfterBound = st$sumApplied/st$nUpd,
    maxRawStep = st$maxRaw,
    meanRealisedBetaChange = st$appliedAbs/max(1,st$nApplied))
}
out <- do.call(rbind, lapply(list(c(1,1), c(20,0.52), c(20,0.05), c(100,0.17)),
                             function(c) suppressWarnings(probe(as.integer(c[1]), c[2]))))
print(out, row.names=FALSE, digits=4)
write.csv(out, file.path(FP_OUT, "validation/test5_bound.csv"), row.names=FALSE)
