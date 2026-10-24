## 5-fold cross-fitting: each fold's PS comes from local and global models fitted without that fold.
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
source(file.path(FP_EXP, "common/kit.R"))
set.seed(777)
meta <- readRDS(file.path(FP_OUT, "statin3/meta.rds")); axis <- meta$axis; SITES <- meta$sites
S <- lapply(SITES, function(nm){ dd <- readRDS(sprintf(file.path(FP_OUT, "sitedata/tri/%s.rds"), nm))
  j <- match(as.numeric(colnames(dd$x)), axis); t <- Matrix::summary(as(dd$x,"TsparseMatrix"))
  Xg <- sparseMatrix(i=t$i, j=j[t$j], x=t$x, dims=c(nrow(dd$x), length(axis)))
  list(Xg=as(cbind(Matrix(1,nrow(Xg),1,sparse=TRUE),Xg),"CsparseMatrix"),
       Xl=as(cbind(Matrix(1,nrow(dd$x),1,sparse=TRUE), dd$x),"CsparseMatrix"),
       y=dd$treatment, feat=as.numeric(colnames(dd$x))) })
names(S) <- SITES
X <- do.call(rbind, lapply(S,`[[`,"Xg")); y <- unlist(lapply(S,`[[`,"y"))
site <- rep(SITES, sapply(S, function(s) nrow(s$Xg)))
NF <- 5L
## Drop columns that are all zero in the training rows (h_j = 0 is rejected by the aggregator).
fitDrop <- function(Xtr, ytr, Xte) {
  keep <- as.vector(Matrix::colSums(Xtr != 0) > 0); keep[1] <- TRUE   # keep the intercept
  r <- runCfg(Xtr[, keep, drop = FALSE], ytr, P = 1L, alpha = 1)
  list(ps = 1/(1+exp(-as.vector(Xte[, keep, drop = FALSE] %*% r$beta))),
       nnz = sum(r$beta != 0), d = sum(keep))
}
run1 <- function(sn) {
  ii <- which(site==sn); n <- length(ii); s <- S[[sn]]
  fold <- sample(rep(1:NF, length.out=n))
  psLocalOOF <- numeric(n); psGlobalOOF <- numeric(n)
  for (k in 1:NF) {
    tr <- which(fold!=k); te <- which(fold==k)
    ## local: this site without fold k
    if (length(unique(s$y[tr]))==2) {
      psLocalOOF[te] <- fitDrop(s$Xl[tr,,drop=FALSE], s$y[tr], s$Xl[te,,drop=FALSE])$ps
    } else psLocalOOF[te] <- mean(s$y[tr])
    ## global: all sites without the fold-k patients
    drop <- ii[te]; keepRows <- setdiff(seq_along(y), drop)
    psGlobalOOF[te] <- fitDrop(X[keepRows,,drop=FALSE], y[keepRows], X[drop,,drop=FALSE])$ps
  }
  Zi <- s$Xl[,-1,drop=FALSE]; yi <- s$y
  p <- colMeans(Zi!=0); fx <- which(p>0 & p<1); Zf <- Zi[,fx,drop=FALSE]
  smdF <- function(idx){ Z <- Zf[idx,,drop=FALSE]; yy <- yi[idx]
    t1 <- as.numeric(yy==1); t0 <- as.numeric(yy==0)
    p1 <- as.vector(crossprod(Z,t1))/sum(t1); p0 <- as.vector(crossprod(Z,t0))/sum(t0)
    den <- sqrt((p1*(1-p1)+p0*(1-p0))/2); dd <- ifelse(den>1e-12, abs(p1-p0)/den, 0)
    c(mean=mean(dd), median=median(dd), p90=unname(quantile(dd,.9)), max=max(dd),
      n_gt_0.1=sum(dd>0.1), n_gt_0.2=sum(dd>0.2)) }
  out <- list()
  for (nm2 in c("local","global")) {
    ps <- if (nm2=="local") psLocalOOF else psGlobalOOF
    mm <- matchPs(ps, yi)
    out[[nm2]] <- data.frame(site=sn, model=nm2, pairs=mm$pairs,
      retained=sprintf("%.0f%%", 100*mm$pairs/sum(yi==1)), t(smdF(mm$idx)))
  }
  rbind(data.frame(site=sn, model="unmatched", pairs=NA, retained=NA, t(smdF(seq_len(n)))),
        out$local, out$global)
}
res <- do.call(rbind, lapply(c("ehrshot","mimic"), run1)); rownames(res) <- NULL
write.csv(res, file.path(FP_OUT, "statin3/tables/table4_crossfit.csv"), row.names=FALSE)
cat("=== 5-fold cross-fitting, out-of-fold PS ===\n")
print(res, row.names=FALSE, digits=4)
