## Full scale: the K = 3, P = 20 block run against the exact federated baseline coefficients.
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
a <- commandArgs(trailingOnly=TRUE); run <- a[1]; sites <- a[-1]

suppressPackageStartupMessages({library(Matrix); library(CohortMethod)})
lam <- sqrt(2)
res <- lapply(sites, function(s) readRDS(sprintf(file.path(FP_OUT, "fedruns/%s/%s.rds"), run, s)))
names(res) <- sites
agg <- readRDS(sprintf(file.path(FP_OUT, "fedruns/%s/agg.rds"), run))
bf <- agg$coefficients                                   # named, character-sorted order
cat(sprintf("run %s : %d coefficients from the aggregator\n", run, length(bf)))
cat(sprintf("all %d sites identical to the aggregator's vector : %s\n", length(sites),
    all(sapply(res, function(r) identical(r$coefficients, bf)))))

base <- readRDS(file.path(FP_DATA, "statin/mimic/psModelCoef.rds"))   # production, numeric order
stopifnot(setequal(names(base), names(bf)))
bf <- bf[names(base)]                                    # align by feature id
cat(sprintf("coefficient names align with the production baseline : TRUE (n = %d)\n", length(bf)))

## ---- pooled design in the production (numeric) feature order ----
loadDesign <- function(nm) {
  dd <- readRDS(sprintf(file.path(FP_DATA, "statin/%s/design.rds"), nm))
  rows <- sort(dd$rowId); feat <- as.character(dd$covariateIds)
  i <- match(dd$cov$rowId, rows); j <- match(as.character(dd$cov$covariateId), feat)
  ok <- !is.na(i) & !is.na(j)
  list(X=sparseMatrix(i=i[ok], j=j[ok], x=dd$cov$covariateValue[ok],
                      dims=c(length(rows), length(feat))),
       feat=feat, y=dd$treatment[match(rows, dd$rowId)], rows=rows)
}
target <- names(base)[-1]
mk <- function(D) { j <- match(D$feat, target)
  t <- Matrix::summary(as(D$X,"TsparseMatrix"))
  cbind(Matrix(1,nrow(D$X),1,sparse=TRUE),
        sparseMatrix(i=t$i, j=j[t$j], x=t$x, dims=c(nrow(D$X), length(target)))) }
M <- loadDesign("mimic"); S <- loadDesign("synpuf")
Xm <- as(mk(M),"CsparseMatrix"); Xs <- as(mk(S),"CsparseMatrix")
X <- rbind(Xm, Xs); y <- c(M$y, S$y); rowIds <- c(M$rows, S$rows)
cat(sprintf("pooled design %d x %d nnz %d\n", nrow(X), ncol(X), length(X@x)))

stat <- function(b){ e<-as.vector(X%*%b); p<-1/(1+exp(-e))
  g<-as.vector(crossprod(X,p-y)); nz<-which(b!=0); nz<-nz[nz!=1]; z<-setdiff(seq_along(b)[-1],nz)
  list(obj=sum(log1p(exp(e))-y*e)+lam*sum(abs(b[-1])), gn=sqrt(sum(g^2)),
       kkt=max(abs(g[1]), if(length(nz)) max(abs(g[nz]+lam*sign(b[nz]))) else 0,
               if(length(z)) max(pmax(0,abs(g[z])-lam)) else 0),
       nnz=sum(b!=0), p=p) }
sb <- stat(unname(base)); sf <- stat(unname(bf))
cat(sprintf("\n%-24s %14s %10s %12s %8s\n","","objective","nnz","KKT","|grad|"))
cat(sprintf("%-24s %14.4f %10d %12.4f %8.2f\n","production baseline", sb$obj, sb$nnz, sb$kkt, sb$gn))
cat(sprintf("%-24s %14.4f %10d %12.4f %8.2f\n","P=20 proximal block",  sf$obj, sf$nnz, sf$kkt, sf$gn))
cat(sprintf("\nrelative objective gap      : %.4e\n", (sf$obj-sb$obj)/abs(sb$obj)))
cat(sprintf("production-vs-converged gap : %.4e   (608816.9087 vs 608787.7506, tol 1e-8)\n",
            (608816.9087-608787.7506)/608816.9087))
cat(sprintf("max|coefficient difference| : %.4e\n", max(abs(bf-base))))
cat(sprintf("L2 relative coefficient err : %.4e\n", sqrt(sum((bf-base)^2))/sqrt(sum(base^2))))
cat(sprintf("support: baseline %d, block %d, differing %d\n", sb$nnz, sf$nnz,
            length(union(setdiff(which(base!=0),which(bf!=0)), setdiff(which(bf!=0),which(base!=0))))))
cat(sprintf("propensity score: max|diff| = %.5f  mean|diff| = %.6f  cor = %.6f\n",
            max(abs(sf$p-sb$p)), mean(abs(sf$p-sb$p)), cor(sf$p, sb$p)))

## ---- covariate balance after 1:1 PS matching (OHDSI matchOnPs) ----
Z <- X[,-1,drop=FALSE]; Z2 <- Z; Z2@x <- Z2@x^2
balance <- function(ps, tag) {
  pop <- data.frame(rowId = seq_along(y), treatment = y, propensityScore = ps,
                    personSeqId = seq_along(y), stratumId = NA)
  m <- CohortMethod::matchOnPs(pop, matchOnPsArgs = CohortMethod::createMatchOnPsArgs(
         caliper = 0.2, caliperScale = "standardized logit", maxRatio = 1))
  idx <- m$rowId; yy <- y[idx]; Zi <- Z[idx,,drop=FALSE]; Zi2 <- Z2[idx,,drop=FALSE]
  n1 <- sum(yy==1); n0 <- sum(yy==0)
  m1 <- as.vector(crossprod(Zi, as.numeric(yy==1)))/n1
  m0 <- as.vector(crossprod(Zi, as.numeric(yy==0)))/n0
  v1 <- as.vector(crossprod(Zi2, as.numeric(yy==1)))/n1 - m1^2
  v0 <- as.vector(crossprod(Zi2, as.numeric(yy==0)))/n0 - m0^2
  sd <- sqrt(pmax((v1+v0)/2,0)); k <- sd > 1e-8; d <- abs(m1-m0)[k]/sd[k]
  cat(sprintf("  %-22s matched pairs=%d  mean|SMD|=%.5f  max|SMD|=%.4f  >0.1: %d/%d\n",
              tag, n1, mean(d), max(d), sum(d>0.1), length(d)))
  out <- rep(NA_real_, ncol(Z)); out[k] <- d          # keep full length for comparison
  invisible(out)
}
cat("\ncovariate balance after 1:1 PS matching (caliper 0.2 standardized logit):\n")
db <- balance(sb$p, "production baseline"); dq <- balance(sf$p, "P=20 proximal block")
ok <- is.finite(db) & is.finite(dq)
cat(sprintf("  correlation of per-covariate SMD (%d covariates in both) : %.5f\n",
            sum(ok), cor(db[ok], dq[ok])))
saveRDS(list(base=base, block=bf, sb=sb[setdiff(names(sb),"p")], sf=sf[setdiff(names(sf),"p")],
             res=res, agg=agg[setdiff(names(agg),"coefficients")]),
        sprintf(file.path(FP_OUT, "fedruns/%s/full_verify.rds"), run))
