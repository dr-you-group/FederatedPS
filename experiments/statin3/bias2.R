## Bias and RMSE of the effect estimate at each site, using the saved out-of-fold PS and
## NREP simulated outcomes with a known effect and real confounding.
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
source(file.path(FP_EXP, "common/kit.R")); suppressPackageStartupMessages(library(survival))
set.seed(987654)
TRUE_LHR <- log(1.5); NREP <- 500L; GAMMAS <- c(0.5, 1.0, 2.0)

## Confounder: combination of covariates that differ between treatment groups at that site
## (derived from the data, not from any fitted model).
makeZ <- function(Z, y, topK = 200L) {
  t1 <- as.numeric(y==1); t0 <- as.numeric(y==0)
  p1 <- as.vector(Matrix::crossprod(Z,t1))/sum(t1); p0 <- as.vector(Matrix::crossprod(Z,t0))/sum(t0)
  den <- sqrt((p1*(1-p1)+p0*(1-p0))/2); sd0 <- ifelse(den>1e-12, (p1-p0)/den, 0)
  sel <- order(-abs(sd0))[1:min(topK, length(sd0))]
  w <- numeric(ncol(Z)); w[sel] <- sd0[sel]
  z <- as.vector(Z %*% w); (z - mean(z))/sd(z)
}
run <- function(tag, psList, y, Z) {
  z <- makeZ(Z, y)
  conf <- abs(mean(z[y==1])-mean(z[y==0]))/sqrt((var(z[y==1])+var(z[y==0]))/2)
  mm <- lapply(psList, function(p) matchPs(p, y))
  cat(sprintf("\n=== %s (n=%d): confounder SMD = %.3f ===\n", tag, length(y), conf))
  out <- list()
  for (g in GAMMAS) {
    A <- matrix(NA_real_, NREP, length(psList)+1L)
    for (r in 1:NREP) {
      lp <- TRUE_LHR*y + g*z
      tt <- rexp(length(y), rate=0.02*exp(lp)); ev <- as.integer(tt<=30); tm <- pmin(tt,30)
      est <- function(idx){ dd <- data.frame(t=tm[idx], e=ev[idx], a=y[idx])
        if (sum(dd$e)<5 || length(unique(dd$a))<2) return(NA_real_)
        tryCatch(unname(coef(coxph(Surv(t,e)~a, data=dd))[1]), error=function(x) NA_real_) }
      A[r,] <- c(est(seq_along(y)), sapply(mm, function(m) est(m$idx)))
    }
    colnames(A) <- c("unadjusted", names(psList))
    out[[length(out)+1L]] <- data.frame(setting=tag, gamma=g, confSMD=round(conf,3),
      analysis=colnames(A), pairs=c(NA, sapply(mm, `[[`, "pairs")),
      bias=apply(A,2,function(v) mean(v,na.rm=TRUE))-TRUE_LHR,
      sd=apply(A,2,function(v) sd(v,na.rm=TRUE)),
      rmse=apply(A,2,function(v) sqrt(mean((v-TRUE_LHR)^2,na.rm=TRUE))))
  }
  o <- do.call(rbind, out); rownames(o) <- NULL; print(o, row.names=FALSE, digits=4); o
}
res <- list()
## full-size sites
P1 <- readRDS(file.path(FP_OUT, "statin3/oof3_ps.rds"))
for (sn in names(P1)) {
  Z <- as(readRDS(sprintf(file.path(FP_OUT, "sitedata/tri/%s.rds"), sn))$x, "CsparseMatrix")
  res[[length(res)+1L]] <- run(sprintf("full/%s", sn),
    list(local=P1[[sn]]$local, global=P1[[sn]]$sharedGlobal), P1[[sn]]$y, Z)
}
## reduced consortium
P2 <- readRDS(file.path(FP_OUT, "statin3/small_oof_ps.rds"))
for (sn in names(P2)) {
  Z <- as(readRDS(sprintf(file.path(FP_OUT, "sitedata/small/%s.rds"), sn))$x, "CsparseMatrix")
  res[[length(res)+1L]] <- run(sprintf("small/%s", sn),
    list(local=P2[[sn]]$local, global=P2[[sn]]$global), P2[[sn]]$y, Z)
}
tab <- do.call(rbind, res)
write.csv(tab, file.path(FP_OUT, "statin3/tables/table14_bias.csv"), row.names=FALSE)
cat(sprintf("\ntrue log HR = %.4f (HR 1.5), %d replicates\n", TRUE_LHR, NREP))
