## Heterogeneous partners: MIMIC split into two covariate clusters; the focal site comes
## from one cluster and the partners from the other (mode = hetero) or the same one (homo).
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
source(file.path(FP_EXP, "common/kit.R"))
suppressPackageStartupMessages(library(Matrix))
a <- commandArgs(TRUE); study <- a[1]; mode <- a[2]   # mode: hetero | homo
CV <- "cv" %in% a   # "cv": choose the prior variance by cross-validation
source(file.path(FP_EXP, "common/kitcv.R"))
NREP <- 5L; NFOLD <- 5L; KSITE <- 3L; NN <- 1000L; SEED <- 20261005L

dd <- readRDS(sprintf(file.path(FP_DATA, "design/%s__mimiciv.rds"), study))
rows <- sort(dd$rowId); feat <- dd$covariateIds
i <- match(dd$cov$rowId, rows); j <- match(dd$cov$covariateId, feat); ok <- !is.na(i)&!is.na(j)
X <- sparseMatrix(i=i[ok], j=j[ok], x=dd$cov$covariateValue[ok], dims=c(length(rows), length(feat)))
y <- dd$treatment[match(rows, dd$rowId)]; rm(dd); invisible(gc())

## Clusters: k-means (k = 2) on the 200 most prevalent covariates; treatment is not used.
set.seed(SEED)
pv <- colMeans(X != 0); top <- order(-pv)[1:min(200L, ncol(X))]
Z <- as.matrix(X[, top, drop=FALSE])
km <- kmeans(Z, centers=2L, nstart=5L, iter.max=50L)
cl <- km$cluster
rm(Z); invisible(gc())
cat(sprintf("[%s] cluster sizes %d / %d, prevalence %.3f / %.3f\n",
    study, sum(cl==1), sum(cl==2), mean(y[cl==1]), mean(y[cl==2])))
## standardised difference between clusters on those covariates
p1 <- colMeans(X[cl==1, top, drop=FALSE] != 0); p2 <- colMeans(X[cl==2, top, drop=FALSE] != 0)
den <- sqrt((p1*(1-p1)+p2*(1-p2))/2); sd0 <- ifelse(den>1e-8, abs(p1-p2)/den, 0)
cat(sprintf("  between-cluster SMD: mean %.3f, max %.3f, >0.1 for %d/200\n",
    mean(sd0), max(sd0), sum(sd0>0.1)))

f1 <- function(Xs, ys) { p <- which(colSums(Xs!=0)>0)
  if (!length(p) || length(unique(ys))<2) return(NULL)
  r <- try(runCfg(cbind(Matrix(1,nrow(Xs),1,sparse=TRUE), Xs[,p,drop=FALSE]), ys, P=1L, alpha=1), silent=TRUE)
  if (inherits(r,"try-error") || r$diverged) return(NULL)
  list(b0=r$beta[1], bj=r$beta[-1], idx=p) }
if (CV) f1 <- function(Xs, ys) fitCV(Xs, ys)
pd <- function(m, Xs) if (is.null(m)) rep(NA_real_, nrow(Xs)) else
  1/(1+exp(-(m$b0 + as.vector(Xs[,m$idx,drop=FALSE] %*% m$bj))))
au <- function(p, yy) { o<-is.finite(p); p<-p[o]; yy<-yy[o]
  if (length(unique(yy))<2) return(NA_real_)
  r<-rank(p); n1<-as.numeric(sum(yy==1)); n0<-as.numeric(sum(yy==0))
  (sum(r[yy==1])-n1*(n1+1)/2)/(n1*n0) }
draw <- function(pool, used) { yy <- y[pool]; pr <- mean(yy)
  nT <- max(2L, round(NN*pr)); nC <- max(2L, NN-nT)
  c1 <- setdiff(pool[yy==1], used); c0 <- setdiff(pool[yy==0], used)
  if (nT>length(c1) || nC>length(c0)) return(NULL)
  sort(c(sample(c1,nT), sample(c0,nC))) }

P1 <- which(cl==1); P2 <- which(cl==2)
if (length(P2) > length(P1)) { t <- P1; P1 <- P2; P2 <- t }   # focal site from the larger cluster
out <- list()
for (rep in 1:NREP) {
  set.seed(SEED + 1000L*rep)
  used <- integer(0)
  ix <- draw(P1, used); if (is.null(ix)) next; used <- c(used, ix)
  partners <- list(); bad <- FALSE
  for (k in 2:KSITE) { pool <- if (mode=="hetero") P2 else P1
    iy <- draw(pool, used); if (is.null(iy)) { bad<-TRUE; break }
    used <- c(used, iy); partners[[length(partners)+1L]] <- iy }
  if (bad) next
  io <- unlist(partners)
  X1 <- X[ix,,drop=FALSE]; y1 <- y[ix]; Xo <- X[io,,drop=FALSE]; yo <- y[io]
  fold <- integer(length(y1))
  for (g in c(0,1)) { q <- which(y1==g); fold[q] <- sample(rep_len(1:NFOLD, length(q))) }
  ps <- matrix(NA_real_, length(y1), 3, dimnames=list(NULL,c("local","others","shared")))
  mO <- f1(Xo, yo)
  ## partner model on held-out rows of its own cluster
  iv <- draw(if (mode=="hetero") P2 else P1, used)
  selfO <- if (is.null(iv)) NA_real_ else au(pd(mO, X[iv,,drop=FALSE]), y[iv])
  for (f in 1:NFOLD) { tr <- which(fold!=f); te <- which(fold==f)
    ps[te,"local"]  <- pd(f1(X1[tr,,drop=FALSE], y1[tr]), X1[te,,drop=FALSE])
    ps[te,"others"] <- pd(mO, X1[te,,drop=FALSE])
    ps[te,"shared"] <- pd(f1(rbind(Xo, X1[tr,,drop=FALSE]), c(yo, y1[tr])), X1[te,,drop=FALSE]) }
  out[[length(out)+1L]] <- data.frame(study=study, mode=mode, rep=rep,
    local=au(ps[,"local"],y1), others=au(ps[,"others"],y1), shared=au(ps[,"shared"],y1),
    partnerSelf=selfO, meanSMD=mean(sd0), nGt01=sum(sd0>0.1))
}
R <- do.call(rbind, out)
OUT <- sprintf(file.path(FP_OUT, "hetero%s"), if (CV) "_cv" else ""); dir.create(OUT, showWarnings=FALSE)
write.csv(R, sprintf(paste0(OUT, "/%s__%s.csv"), study, mode), row.names=FALSE)
cat(sprintf("  %-7s local %.3f | others %.3f | shared %.3f | partnerSelf %.3f | sh-lo %+.3f sh-ot %+.4f\n",
  mode, mean(R$local), mean(R$others), mean(R$shared), mean(R$partnerSelf,na.rm=TRUE),
  mean(R$shared)-mean(R$local), mean(R$shared)-mean(R$others)))
