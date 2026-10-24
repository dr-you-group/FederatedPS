source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
source(file.path(FP_EXP, "common/kit.R"))
meta <- readRDS(file.path(FP_OUT, "statin3/meta.rds")); axis <- meta$axis; d <- meta$d; om <- meta$omega_global
S <- lapply(meta$sites, function(nm){ dd <- readRDS(sprintf(file.path(FP_OUT, "sitedata/tri/%s.rds"), nm))
  j <- match(as.numeric(colnames(dd$x)), axis); t <- Matrix::summary(as(dd$x,"TsparseMatrix"))
  Xg <- sparseMatrix(i=t$i, j=j[t$j], x=t$x, dims=c(nrow(dd$x), length(axis)))
  list(Xg=as(cbind(Matrix(1,nrow(Xg),1,sparse=TRUE),Xg),"CsparseMatrix"), y=dd$treatment) })
X <- do.call(rbind, lapply(S,`[[`,"Xg")); y <- unlist(lapply(S,`[[`,"y"))
sx <- X[,-1,drop=FALSE]; colnames(sx) <- paste0("v", seq_len(ncol(sx)))
cd <- Cyclops::createCyclopsData(treatment~1, data=data.frame(treatment=y), sx=sx,
                                 modelType="lr", floatingPoint=64)
cd$coefficientNames <- c("(Intercept)", colnames(sx))
eso <- function(P) 1/(1 + (P-1)*(om-1)/(d-1))
cat(sprintf("min nonzeros per global column: %d\n", min(Matrix::colSums(X != 0))))
for (cf in list(c(100, eso(100)), c(100, 0.2), c(100, 0.05))) {
  P <- as.integer(cf[1]); a <- cf[2]
  st <- new.env(); st$minh <- Inf; st$nneg <- 0L; st$nzero <- 0L; st$n <- 0L; st$first <- NA
  cb <- function(coordinate, statistics) { st$n <- st$n + 1L
    if (coordinate > 0L) { w <- length(statistics) %/% 4L; h <- statistics[(w+1):(2*w)]
      st$minh <- min(st$minh, min(h)); st$nneg <- st$nneg + sum(h<0); st$nzero <- st$nzero + sum(h==0)
      if (any(h<=0) && is.na(st$first)) st$first <- st$n }
    statistics }
  f <- tryCatch(Cyclops::fitCyclopsModel(cd,
        prior=Cyclops::createPrior("laplace",variance=1,exclude="(Intercept)",useCrossValidation=FALSE),
        control=Cyclops::createControl(convergenceType="lange", seed=1L, noiseLevel="silent",
          tolerance=1e-6, maxIterations=200L, aggregate=cb, blockSize=P, alpha=a),
        startingCoefficients=rep(0,d)), error=function(e) conditionMessage(e))
  cat(sprintf("P=%d a=%.4f: %d exchanges, first non-positive curvature at %s, min h = %.4e, h<0: %d, h==0: %d -> %s\n",
    P, a, st$n, ifelse(is.na(st$first),"none",st$first), st$minh, st$nneg, st$nzero,
    if (is.character(f)) substr(f,1,40) else paste("ok, passes", f$iterations)))
}
