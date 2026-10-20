## Transfer matrix: local models of 3 MIMIC and 3 SynPUF sites (1,000 patients each)
## applied to each other's data. Diagonal = 5-fold OOF.
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))

source(file.path(FP_EXP, "common/kit.R"))
suppressPackageStartupMessages(library(Matrix))
study <- commandArgs(TRUE)[1]
NREP <- 5L; NFOLD <- 5L; NSITE <- 3L; NN <- 1000L; SEED <- 20261005L

load1 <- function(site) {
  dd <- readRDS(sprintf(file.path(FP_DATA, "design/%s__%s.rds"), study, site))
  rows <- sort(dd$rowId); feat <- dd$covariateIds
  i <- match(dd$cov$rowId, rows); j <- match(dd$cov$covariateId, feat)
  ok <- !is.na(i) & !is.na(j)
  list(X=sparseMatrix(i=i[ok], j=j[ok], x=dd$cov$covariateValue[ok],
                      dims=c(length(rows), length(feat))),
       feat=feat, y=dd$treatment[match(rows, dd$rowId)]) }
M <- load1("mimiciv"); S <- load1("synpuf")
axis <- sort(unique(c(M$feat, S$feat)))
onAx <- function(D, ix) { t <- summary(as(D$X[ix,,drop=FALSE],"TsparseMatrix")); j <- match(D$feat, axis)
  sparseMatrix(i=t$i, j=j[t$j], x=t$x, dims=c(length(ix), length(axis))) }
fit1 <- function(Xs, ys) { pres <- which(colSums(Xs!=0)>0)
  if (!length(pres) || length(unique(ys))<2) return(NULL)
  r <- try(runCfg(cbind(Matrix(1,nrow(Xs),1,sparse=TRUE), Xs[,pres,drop=FALSE]), ys, P=1L, alpha=1), silent=TRUE)
  if (inherits(r,"try-error") || r$diverged) return(NULL)
  list(b0=r$beta[1], bj=r$beta[-1], idx=pres) }
pred1 <- function(m, Xs) if (is.null(m)) rep(NA_real_, nrow(Xs)) else
  1/(1+exp(-(m$b0 + as.vector(Xs[,m$idx,drop=FALSE] %*% m$bj))))
auc1 <- function(p, yy) { ok <- is.finite(p); p<-p[ok]; yy<-yy[ok]
  if (length(unique(yy))<2) return(NA_real_)
  r <- rank(p); n1<-as.numeric(sum(yy==1)); n0<-as.numeric(sum(yy==0))
  (sum(r[yy==1]) - n1*(n1+1)/2)/(n1*n0) }
draw <- function(D, used) { pr <- mean(D$y); nT <- max(2L, round(NN*pr)); nC <- max(2L, NN-nT)
  c1 <- setdiff(which(D$y==1), used); c0 <- setdiff(which(D$y==0), used)
  if (nT>length(c1) || nC>length(c0)) return(NULL)
  sort(c(sample(c1,nT), sample(c0,nC))) }

nm <- c(paste0("M",1:NSITE), paste0("S",1:NSITE))
acc <- array(NA_real_, c(2*NSITE, 2*NSITE, NREP), dimnames=list(nm, nm, NULL))
for (rep in 1:NREP) {
  set.seed(SEED + 1000L*rep)
  sites <- list(); uM <- integer(0); uS <- integer(0); bad <- FALSE
  for (k in 1:NSITE) { ix <- draw(M, uM); if (is.null(ix)) { bad<-TRUE; break }
    uM <- c(uM, ix); sites[[k]] <- list(X=onAx(M,ix), y=M$y[ix]) }
  if (bad) next
  for (k in 1:NSITE) { iy <- draw(S, uS); if (is.null(iy)) { bad<-TRUE; break }
    uS <- c(uS, iy); sites[[NSITE+k]] <- list(X=onAx(S,iy), y=S$y[iy]) }
  if (bad) next
  mods <- lapply(sites, function(z) fit1(z$X, z$y))           # local model per site, all rows
  for (i in seq_along(sites)) for (j in seq_along(sites)) {
    if (i == j) {                                             # diagonal: OOF
      z <- sites[[i]]; fold <- integer(length(z$y))
      for (g in c(0,1)) { q <- which(z$y==g); fold[q] <- sample(rep_len(1:NFOLD, length(q))) }
      p <- rep(NA_real_, length(z$y))
      for (f in 1:NFOLD) { tr <- which(fold!=f); te <- which(fold==f)
        p[te] <- pred1(fit1(z$X[tr,,drop=FALSE], z$y[tr]), z$X[te,,drop=FALSE]) }
      acc[i,j,rep] <- auc1(p, z$y)
    } else acc[i,j,rep] <- auc1(pred1(mods[[i]], sites[[j]]$X), sites[[j]]$y)
  }
}
Amean <- apply(acc, c(1,2), mean, na.rm=TRUE)
dir.create(file.path(FP_OUT, "transfer"), showWarnings=FALSE)
write.csv(Amean, sprintf(file.path(FP_OUT, "transfer/%s.csv"), study))
cat(sprintf("\n[%s] transfer matrix (row = model source, column = target)\n", study))
cat(sprintf("%6s %s\n", "", paste(sprintf("%6s", nm), collapse="")))
for (i in 1:nrow(Amean)) cat(sprintf("%6s %s\n", nm[i], paste(sprintf("%6.3f", Amean[i,]), collapse="")))
off <- Amean; diag(off) <- NA
cat(sprintf("row means, off-diagonal: %s\n", paste(sprintf("%s=%.3f", nm, rowMeans(off, na.rm=TRUE)), collapse=" ")))
