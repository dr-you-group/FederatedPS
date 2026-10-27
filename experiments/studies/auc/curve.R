## Learning curve: OOF AUC on a site's own data at increasing sample sizes.
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
source(file.path(FP_EXP, "common/kit.R"))
suppressPackageStartupMessages(library(Matrix))
a <- commandArgs(TRUE); study <- a[1]; site <- a[2]
NREP <- 3L; NFOLD <- 5L; SEED <- 20261005L
SIZES <- c(250, 500, 1000, 2000, 5000, 10000, 20000)

dd <- readRDS(sprintf(file.path(FP_DATA, "design/%s__%s.rds"), study, site))
rows <- sort(dd$rowId); feat <- dd$covariateIds
i <- match(dd$cov$rowId, rows); j <- match(dd$cov$covariateId, feat); ok <- !is.na(i)&!is.na(j)
X <- sparseMatrix(i=i[ok], j=j[ok], x=dd$cov$covariateValue[ok], dims=c(length(rows), length(feat)))
y <- dd$treatment[match(rows, dd$rowId)]; rm(dd); invisible(gc())
pr <- mean(y)
f1 <- function(Xs, ys) { p <- which(colSums(Xs!=0)>0)
  if (!length(p) || length(unique(ys))<2) return(NULL)
  r <- try(runCfg(cbind(Matrix(1,nrow(Xs),1,sparse=TRUE), Xs[,p,drop=FALSE]), ys, P=1L, alpha=1), silent=TRUE)
  if (inherits(r,"try-error") || r$diverged) return(NULL)
  list(b0=r$beta[1], bj=r$beta[-1], idx=p, nnz=sum(r$beta[-1]!=0)) }
pd <- function(m, Xs) if (is.null(m)) rep(NA_real_, nrow(Xs)) else
  1/(1+exp(-(m$b0 + as.vector(Xs[,m$idx,drop=FALSE] %*% m$bj))))
au <- function(p, yy) { o<-is.finite(p); p<-p[o]; yy<-yy[o]
  if (length(unique(yy))<2) return(NA_real_)
  r<-rank(p); n1<-as.numeric(sum(yy==1)); n0<-as.numeric(sum(yy==0))
  (sum(r[yy==1])-n1*(n1+1)/2)/(n1*n0) }

out <- list()
for (n in SIZES) {
  nT <- max(2L, round(n*pr)); nC <- max(2L, n-nT)
  if (nT > sum(y==1) || nC > sum(y==0)) next
  for (rep in 1:NREP) {
    set.seed(SEED + 997L*rep + n)
    ix <- sort(c(sample(which(y==1), nT), sample(which(y==0), nC)))
    Xs <- X[ix,,drop=FALSE]; ys <- y[ix]
    fold <- integer(length(ys))
    for (g in c(0,1)) { q <- which(ys==g); fold[q] <- sample(rep_len(1:NFOLD, length(q))) }
    p <- rep(NA_real_, length(ys)); nz <- 0
    for (f in 1:NFOLD) { tr <- which(fold!=f); te <- which(fold==f)
      m <- f1(Xs[tr,,drop=FALSE], ys[tr]); p[te] <- pd(m, Xs[te,,drop=FALSE])
      nz <- nz + ifelse(is.null(m), 0, m$nnz)/NFOLD }
    out[[length(out)+1L]] <- data.frame(study=study, site=site, n=n, rep=rep,
      nT=nT, nC=nC, eff=4*nT*nC/n, nnz=nz, auc=au(p, ys))
  }
}
R <- do.call(rbind, out)
dir.create(file.path(FP_OUT, "curve"), showWarnings=FALSE)
write.csv(R, sprintf(file.path(FP_OUT, "curve/%s__%s.csv"), study, site), row.names=FALSE)
m <- aggregate(cbind(auc,nnz,eff)~n, R, mean)
cat(sprintf("\n[%s / %s]  prevalence %.2f\n", study, site, pr))
cat(sprintf("%8s %9s %8s %8s\n","n","effN","nonzero","OOF AUC"))
for (i in 1:nrow(m)) cat(sprintf("%8d %9.0f %8.0f %8.3f\n", m$n[i], m$eff[i], m$nnz[i], m$auc[i]))
