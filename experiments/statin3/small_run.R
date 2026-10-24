## Reduced statin consortium of similar-size sites: (a) pooled and local fits,
## (b) 5-fold OOF balance, (c) bias and RMSE by confounding strength.
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
source(file.path(FP_EXP, "common/kit.R")); suppressPackageStartupMessages(library(survival))
set.seed(4242)
meta <- readRDS(file.path(FP_OUT, "statin3/meta_small.rds")); axis <- meta$axis; d <- meta$d; SITES <- meta$sites
S <- lapply(SITES, function(nm){ dd <- readRDS(sprintf(file.path(FP_OUT, "sitedata/small/%s.rds"), nm))
  j <- match(as.numeric(colnames(dd$x)), axis); t <- Matrix::summary(as(dd$x,"TsparseMatrix"))
  Xg <- sparseMatrix(i=t$i, j=j[t$j], x=t$x, dims=c(nrow(dd$x), length(axis)))
  list(Xg=as(cbind(Matrix(1,nrow(Xg),1,sparse=TRUE),Xg),"CsparseMatrix"),
       Xl=as(cbind(Matrix(1,nrow(dd$x),1,sparse=TRUE), dd$x),"CsparseMatrix"),
       y=dd$treatment, n=nrow(dd$x)) }); names(S) <- SITES
X <- do.call(rbind, lapply(S,`[[`,"Xg")); y <- unlist(lapply(S,`[[`,"y"))
site <- rep(SITES, sapply(S,`[[`,"n"))
cat(sprintf("pooled %d x %d, nnz %d\n", nrow(X), ncol(X), length(X@x)))

fitDrop <- function(Xtr, ytr, Xte) {
  keep <- as.vector(Matrix::colSums(Xtr!=0)>0); keep[1] <- TRUE
  r <- runCfg(Xtr[,keep,drop=FALSE], ytr, P=1L, alpha=1)
  list(ps=1/(1+exp(-as.vector(Xte[,keep,drop=FALSE] %*% r$beta))), nnz=sum(r$beta!=0), passes=r$passes)
}
## (a) full fits
pool <- runCfg(X, y, P=1L, alpha=1); mP <- metrics(pool$beta, X, y)
cat(sprintf("\n[a] pooled: passes=%d nnz=%d kkt=%.2f  (exact FL exchanges = %d)\n",
            pool$passes, mP$nnz, mP$kkt, pool$R_loop))
for (nm in SITES) { r <- runCfg(S[[nm]]$Xl, S[[nm]]$y, P=1L, alpha=1)
  cat(sprintf("    %-8s local: n=%-5d d_local=%-5d nnz=%-5d passes=%d\n",
      nm, S[[nm]]$n, ncol(S[[nm]]$Xl), sum(r$beta!=0), r$passes)) }

## (b) 5-fold OOF, local vs global at each site
NF <- 5L; PSoof <- list()
for (nm in SITES) {
  ii <- which(site==nm); n <- length(ii); fo <- sample(rep(1:NF, length.out=n))
  pl <- numeric(n); pg <- numeric(n); nnzL <- c(); nnzG <- c()
  for (k in 1:NF) {
    tr <- which(fo!=k); te <- which(fo==k); drop <- ii[te]; kr <- setdiff(seq_along(y), drop)
    a <- fitDrop(S[[nm]]$Xl[tr,,drop=FALSE], S[[nm]]$y[tr], S[[nm]]$Xl[te,,drop=FALSE])
    b <- fitDrop(X[kr,,drop=FALSE], y[kr], X[drop,,drop=FALSE])
    pl[te] <- a$ps; pg[te] <- b$ps; nnzL <- c(nnzL,a$nnz); nnzG <- c(nnzG,b$nnz)
  }
  PSoof[[nm]] <- list(local=pl, global=pg, y=S[[nm]]$y, nnzL=mean(nnzL), nnzG=mean(nnzG))
  cat(sprintf("    %-8s OOF done (mean nnz local %.0f, global %.0f)\n", nm, mean(nnzL), mean(nnzG)))
}
saveRDS(PSoof, file.path(FP_OUT, "statin3/small_oof_ps.rds"))

cat("\n[b] OOF balance and noise floor\n")
rows <- list()
for (nm in SITES) {
  Zl <- S[[nm]]$Xl[,-1,drop=FALSE]; p <- colMeans(Zl!=0); Zf <- Zl[,which(p>0&p<1),drop=FALSE]
  yy <- PSoof[[nm]]$y
  smd <- function(Zm, lab){ t1<-as.numeric(lab==1); t0<-as.numeric(lab==0)
    p1<-as.vector(Matrix::crossprod(Zm,t1))/sum(t1); p0<-as.vector(Matrix::crossprod(Zm,t0))/sum(t0)
    den<-sqrt((p1*(1-p1)+p0*(1-p0))/2); ifelse(den>1e-12, abs(p1-p0)/den, 0) }
  for (mk in c("local","global")) {
    pop <- data.frame(rowId=seq_along(yy), treatment=yy, propensityScore=PSoof[[nm]][[mk]])
    m <- CohortMethod::matchOnPs(pop, matchOnPsArgs=CohortMethod::createMatchOnPsArgs(
           caliper=0.2, caliperScale="standardized logit", maxRatio=1))
    Zm <- Zf[m$rowId,,drop=FALSE]; o <- smd(Zm, yy[m$rowId]); st <- m$stratumId
    ord <- order(st); i1 <- ord[seq(1,length(ord),2)]; i2 <- ord[seq(2,length(ord),2)]
    nul <- replicate(300, { f <- sample(c(0L,1L), length(i1), TRUE)
      lab <- integer(length(st)); lab[i1] <- f; lab[i2] <- 1L-f; mean(smd(Zm, lab)) })
    rows[[length(rows)+1L]] <- data.frame(site=nm, model=mk, pairs=sum(yy[m$rowId]==1),
      mean=mean(o), max=max(o), gt0.1=sum(o>0.1), nullHi=unname(quantile(nul,.975)),
      overNoise=mean(o)>quantile(nul,.975))
  }
}
B <- do.call(rbind, rows); rownames(B) <- NULL
print(B, row.names=FALSE, digits=4); write.csv(B, file.path(FP_OUT, "statin3/tables/table13_small_oof.csv"), row.names=FALSE)
saveRDS(list(X=NULL, site=site, y=y), file.path(FP_OUT, "statin3/small_meta2.rds"))
cat("\nsmall_run done\n")
