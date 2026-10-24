## Compare a federated run with a pooled fit from the unpatched Cyclops.
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
a <- commandArgs(trailingOnly = TRUE); scen <- a[1]; run <- a[2]; sites <- a[-(1:2)]

suppressPackageStartupMessages(library(Matrix))
lam <- sqrt(2)
res <- lapply(sites, function(s) readRDS(sprintf(file.path(FP_OUT, "fedruns/%s/%s.rds"), run, s)))
names(res) <- sites
agg <- readRDS(sprintf(file.path(FP_OUT, "fedruns/%s/agg.rds"), run))
D <- lapply(sites, function(s) readRDS(sprintf(file.path(FP_OUT, "sitedata/%s/%s.rds"), scen, s)))
feat <- as.character(sort(unique(as.numeric(unlist(lapply(D, function(d) colnames(d$x)))))))
expand <- function(d) { j <- match(colnames(d$x), feat)
  t <- Matrix::summary(as(d$x, "TsparseMatrix"))
  sparseMatrix(i=t$i, j=j[t$j], x=t$x, dims=c(nrow(d$x), length(feat))) }
X <- do.call(rbind, lapply(D, expand)); y <- unlist(lapply(D, `[[`, "treatment"))
keep <- res[[1]]$keep
X <- cbind(Matrix(1, nrow(X), 1, sparse=TRUE), X)[, c(TRUE, keep), drop=FALSE]
X <- as(X, "CsparseMatrix")
cat(sprintf("pooled: %d x %d ; sites %s\n", nrow(X), ncol(X),
            paste(sprintf("%s=%d", sites, sapply(D, function(d) nrow(d$x))), collapse=", ")))

## ---- pooled reference, unpatched Cyclops ----
.libPaths(setdiff(.libPaths(), strsplit(FP_LIB, ":", fixed = TRUE)[[1]]))   # drop the patched library
detach("package:Matrix", unload=TRUE); suppressPackageStartupMessages(library(Matrix))
suppressPackageStartupMessages(library(Cyclops))
sx <- X[,-1,drop=FALSE]; colnames(sx) <- paste0("v", seq_len(ncol(sx)))
cd <- createCyclopsData(treatment~1, data=data.frame(treatment=y), sx=sx,
                        modelType="lr", floatingPoint=64)
cd$coefficientNames <- c("(Intercept)", colnames(sx))
fit <- fitCyclopsModel(cd, prior=createPrior("laplace", variance=1,
        exclude="(Intercept)", useCrossValidation=FALSE),
      control=createControl(convergenceType="lange", seed=1L, noiseLevel="silent",
                            tolerance=1e-6, maxIterations=1000L),
      startingCoefficients=rep(0, ncol(X)))
ref <- unname(stats::coef(fit))
stat <- function(b){ e<-as.vector(X%*%b); p<-1/(1+exp(-e))
  g<-as.vector(crossprod(X,p-y)); nz<-which(b!=0); nz<-nz[nz!=1]; z<-setdiff(seq_along(b)[-1],nz)
  list(obj=sum(log1p(exp(e))-y*e)+lam*sum(abs(b[-1])),
       kkt=max(abs(g[1]), if(length(nz)) max(abs(g[nz]+lam*sign(b[nz]))) else 0,
               if(length(z)) max(pmax(0,abs(g[z]))-lam) else 0),
       gn=sqrt(sum(g^2)), nnz=sum(b!=0), p=p) }
bf <- unname(agg$coefficients); sf <- stat(bf); sr <- stat(ref)
cat(sprintf("\nstock pooled : iterations=%d nnz=%d obj=%.9f kkt=%.4e\n", fit$iterations, sr$nnz, sr$obj, sr$kkt))
cat(sprintf("federated    : passes=%-4d nnz=%d obj=%.9f kkt=%.4e\n", res[[1]]$iterations, sf$nnz, sf$obj, sf$kkt))
cat(sprintf("  max|coef diff| = %.3e   relerr = %.3e   support identical = %s\n",
    max(abs(bf-ref)), sqrt(sum((bf-ref)^2))/sqrt(sum(ref^2)), identical(which(bf!=0),which(ref!=0))))
cat(sprintf("  rel objective gap = %.3e\n", (sf$obj-sr$obj)/abs(sr$obj)))
idc <- sapply(res, function(r) identical(unname(r$coefficients), bf))
cat(sprintf("  all %d sites identical to the aggregator's vector : %s\n", length(sites), all(idc)))
d <- ncol(X); S <- res[[1]]$iterations; P <- res[[1]]$P
cat(sprintf("\n  d=%d P=%d alpha=%s S=%d blocks/pass=%d\n", d, P, res[[1]]$alpha, S, ceiling(d/P)))
cat(sprintf("  R_loop formula (ceil(d/P)+1)*S = %d ; measured loop rounds = %d ; R_overhead = %d\n",
    (ceiling(d/P)+1)*S, res[[1]]$loopRounds, res[[1]]$overheadRounds))
cat(sprintf("  convergence exchanges = %d (= S+1)\n", res[[1]]$convRounds))
saveRDS(list(ref=ref, fed=bf, stat_ref=sr, stat_fed=sf, res=res, agg=agg, X=NULL),
        sprintf(file.path(FP_OUT, "fedruns/%s/verify.rds"), run))
