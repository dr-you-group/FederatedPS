## Balance at each site, including the 511-patient EHRSHOT site, for local, pooled and block FL.
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
source(file.path(FP_EXP, "common/kit.R"))
meta <- readRDS(file.path(FP_OUT, "statin3/meta.rds")); MM <- readRDS(file.path(FP_OUT, "statin3/models.rds"))
SW <- readRDS(file.path(FP_OUT, "statin3/sweep.rds")); axis <- meta$axis; SITES <- meta$sites
S <- lapply(SITES, function(nm){ dd <- readRDS(sprintf(file.path(FP_OUT, "sitedata/tri/%s.rds"), nm))
  j <- match(as.numeric(colnames(dd$x)), axis); t <- Matrix::summary(as(dd$x,"TsparseMatrix"))
  Xg <- sparseMatrix(i=t$i, j=j[t$j], x=t$x, dims=c(nrow(dd$x), length(axis)))
  list(Xg=as(cbind(Matrix(1,nrow(Xg),1,sparse=TRUE),Xg),"CsparseMatrix"), y=dd$treatment) })
names(S) <- SITES
X <- do.call(rbind, lapply(S,`[[`,"Xg")); y <- SW$y; site <- SW$site
psPooled <- SW$psRef; bP <- SW$refBeta

## block run with P = 50, alpha = 0.5
rb <- runCfg(X, y, P=50L, alpha=0.5); mb <- metrics(rb$beta, X, y)
cat(sprintf("block P=50 a=0.5: passes=%d R_loop=%d nnz=%d\n", rb$passes, rb$R_loop, mb$nnz))

## per site: matching within the site on a fixed covariate set
per <- function(sn) {
  ii <- which(site==sn); Zi <- X[ii, -1, drop=FALSE]; yi <- y[ii]
  p <- colMeans(Zi != 0); fixed <- which(p > 0 & p < 1); Zf <- Zi[, fixed, drop=FALSE]
  smdF <- function(idx=NULL){ Z <- if(is.null(idx)) Zf else Zf[idx,,drop=FALSE]
    yy <- if(is.null(idx)) yi else yi[idx]
    t1 <- as.numeric(yy==1); t0 <- as.numeric(yy==0); n1 <- sum(t1); n0 <- sum(t0)
    p1 <- as.vector(crossprod(Z,t1))/n1; p0 <- as.vector(crossprod(Z,t0))/n0
    den <- sqrt((p1*(1-p1)+p0*(1-p0))/2); dd <- ifelse(den>1e-12, abs(p1-p0)/den, 0)
    c(mean=mean(dd), median=median(dd), p90=unname(quantile(dd,.9)), max=max(dd),
      n_gt_0.1=sum(dd>0.1), n_gt_0.2=sum(dd>0.2), nCov=length(dd)) }
  add <- function(ps, lab){ mm <- matchPs(ps, yi)
    data.frame(site=sn, analysis=lab, pairs=mm$pairs,
               retainedTreated=sprintf("%.0f%%", 100*mm$pairs/sum(yi==1)), t(smdF(mm$idx))) }
  rbind(data.frame(site=sn, analysis="unmatched", pairs=NA, retainedTreated=NA, t(smdF())),
        add(MM$locals[[sn]]$psSite, sprintf("%s local model", sn)),
        add(psPooled[ii], "pooled model"),
        add(mb$ps[ii], "proximal block FL (P=50, a=0.5)"))
}
tab <- do.call(rbind, lapply(SITES, per)); rownames(tab) <- NULL
write.csv(tab, file.path(FP_OUT, "statin3/tables/table3_site_balance.csv"), row.names=FALSE)
for (sn in SITES) { cat(sprintf("\n=== %s ===\n", sn)); print(tab[tab$site==sn,-1], row.names=FALSE, digits=4) }

## PS agreement
cat("\n=== PS agreement with pooled ===\n")
for (sn in SITES) { ii <- which(site==sn)
  cat(sprintf("  %-8s local vs pooled: cor=%.4f  maxdiff=%.4f | blockFL vs pooled: cor=%.6f maxdiff=%.4f\n",
     sn, cor(MM$locals[[sn]]$psSite, psPooled[ii]), max(abs(MM$locals[[sn]]$psSite-psPooled[ii])),
     cor(mb$ps[ii], psPooled[ii]), max(abs(mb$ps[ii]-psPooled[ii])))) }
cat("\n=== model size ===\n")
for (sn in SITES) cat(sprintf("  %-8s local nnz=%-6d (d_local=%d)   pooled nnz=%d\n",
  sn, sum(MM$locals[[sn]]$beta!=0), MM$locals[[sn]]$nfeat, sum(bP!=0)))
saveRDS(list(tab=tab, blockBeta=rb$beta, psBlock=mb$ps), file.path(FP_OUT, "statin3/smallsite.rds"))
