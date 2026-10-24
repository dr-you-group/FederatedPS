## Proximal local CCD: each site runs T local sweeps and sends its model.
## Local objective: sum_i loss_i + lambda |b|_1 + mu/2 ||b - b_g||^2,
## coordinate update (g, h) -> (g + mu (b_j - b_g,j), h + mu) through the aggregate hook.
## Aggregation: sum_k w_k b_k (model averaging).
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
source(file.path(FP_EXP, "common/kit.R"))
meta <- readRDS(file.path(FP_OUT, "statin3/meta.rds")); axis <- meta$axis; d <- meta$d; SITES <- meta$sites
S <- lapply(SITES, function(nm){ dd <- readRDS(sprintf(file.path(FP_OUT, "sitedata/tri/%s.rds"), nm))
  j <- match(as.numeric(colnames(dd$x)), axis)
  t <- Matrix::summary(as(dd$x,"TsparseMatrix"))
  Xg <- sparseMatrix(i=t$i, j=j[t$j], x=t$x, dims=c(nrow(dd$x), length(axis)))
  sx <- as(dd$x, "CsparseMatrix"); colnames(sx) <- paste0("v", seq_len(ncol(sx)))
  cd <- Cyclops::createCyclopsData(treatment ~ 1, data=data.frame(treatment=dd$treatment),
                                   sx=sx, modelType="lr", floatingPoint=64)
  cd$coefficientNames <- c("(Intercept)", colnames(sx))
  list(cd=cd, cols=1L + j, n=nrow(sx), y=dd$treatment,     # cols: positions on the common axis, intercept excluded
       Xg=as(cbind(Matrix(1,nrow(Xg),1,sparse=TRUE),Xg),"CsparseMatrix")) })
names(S) <- SITES
Xall <- do.call(rbind, lapply(S,`[[`,"Xg")); yall <- unlist(lapply(S,`[[`,"y"))
nk <- sapply(S, `[[`, "n")
POOLED <- readRDS(file.path(FP_OUT, "statin3/sweep.rds")); bPool <- POOLED$refBeta
mPool <- metrics(bPool, Xall, yall)
cat(sprintf("reference (pooled / exact FL): obj=%.4f KKT=%.2f nnz=%d  exchanges=1,929,868\n",
            mPool$obj, mPool$kkt, mPool$nnz))

localFit <- function(k, bg, mu, T, scaleN=FALSE) {
  s <- S[[k]]; idx <- c(1L, s$cols)
  if (scaleN) mu <- mu * s$n / mean(nk)   # anchor strength proportional to local n
  bgl <- bg[idx]                                     # anchor, local part
  st <- new.env(); st$pass <- 0L; st$last <- NULL
  cb <- function(coordinate, statistics) {
    if (coordinate == 0L) { st$pass <- st$pass + 1L
      if (st$pass > T && !is.null(st$last)) return(st$last)
      st$last <- statistics; return(statistics) }
    v <- statistics
    v[1] <- v[1] + mu * (v[3] - bgl[coordinate]); v[2] <- v[2] + mu
    v }
  f <- Cyclops::fitCyclopsModel(s$cd,
    prior=Cyclops::createPrior("laplace", variance=1, exclude="(Intercept)", useCrossValidation=FALSE),
    control=Cyclops::createControl(convergenceType="lange", seed=1L, noiseLevel="silent",
      tolerance=1e-8, maxIterations=1000L, aggregate=cb),
    startingCoefficients=bgl)
  out <- bg; out[idx] <- unname(stats::coef(f)); out
}

runPL <- function(T, mu, weight=c("n","uniform"), R=120L, tol=1e-6, verbose=FALSE, scaleN=FALSE) {
  weight <- match.arg(weight)
  w <- if (weight=="n") nk/sum(nk) else rep(1/length(nk), length(nk))
  bg <- numeric(d); prev <- NULL; hist <- list(); t0 <- Sys.time(); rounds <- 0L
  for (r in 1:R) {
    bs <- lapply(SITES, function(k) localFit(k, bg, mu, T, scaleN))
    bg <- Reduce(`+`, Map(function(b,ww) b*ww, bs, w))
    rounds <- r
    o <- metrics(bg, Xall, yall)$obj
    hist[[r]] <- c(round=r, obj=o)
    if (verbose) cat(sprintf("    r=%-3d obj=%.4f\n", r, o))
    if (!is.null(prev) && abs(o-prev)/(abs(o)+1) < tol) break
    prev <- o
  }
  m <- metrics(bg, Xall, yall)
  list(beta=bg, rounds=rounds, T=T, mu=mu, weight=weight, scaleN=scaleN,
       secs=as.numeric(difftime(Sys.time(),t0,units="secs")), m=m, hist=do.call(rbind,hist))
}
BYTES_PER_DOUBLE <- 20.5; K <- 3L
summarise <- function(r) data.frame(T=r$T, mu=r$mu, scaleN=r$scaleN, weight=r$weight, rounds=r$rounds,
  modelExchanges=2L*r$rounds, GB=K*2*r$rounds*d*BYTES_PER_DOUBLE/1e9, secs=round(r$secs,1),
  objective=r$m$obj, relObjGap=(r$m$obj-mPool$obj)/abs(mPool$obj), kkt=r$m$kkt, nnz=r$m$nnz,
  supportDiff=length(union(setdiff(which(bPool!=0),which(r$beta!=0)),
                           setdiff(which(r$beta!=0),which(bPool!=0)))),
  maxCoefDiff=max(abs(r$beta-bPool)), psCor=cor(r$m$ps, mPool$ps),
  maxPSdiff=max(abs(r$m$ps-mPool$ps)))
args <- commandArgs(trailingOnly=TRUE)
## (T, mu, scaleN)
GRID <- list(c(5,0,0), c(5,100,0), c(5,1000,0), c(5,10000,0),
             c(5,0.1,1), c(5,1,1), c(5,10,1), c(5,100,1),
             c(1,10,1), c(2,10,1), c(10,10,1), c(20,10,1))
res <- list()
for (g in GRID) {
  r <- runPL(as.integer(g[1]), g[2], scaleN = as.logical(g[3]))
  res[[length(res)+1L]] <- summarise(r)
  cat(sprintf("T=%-3d mu=%-7g scaleN=%d rounds=%-4d GB=%.3f objGap=%+.3e kkt=%9.2f nnz=%-6d psCor=%.5f %.0fs\n",
      g[1], g[2], as.integer(g[3]), r$rounds, tail(res,1)[[1]]$GB, tail(res,1)[[1]]$relObjGap,
      r$m$kkt, r$m$nnz, tail(res,1)[[1]]$psCor, r$secs)); flush(stdout())
}
tab <- do.call(rbind, res); rownames(tab) <- NULL
write.csv(tab, file.path(FP_OUT, "statin3/tables/table9_proxlocal.csv"), row.names=FALSE)
print(tab, row.names=FALSE, digits=4)
