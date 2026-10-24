## Bias and RMSE of the effect estimate for local and global PS, using the saved out-of-fold
## PS and simulated outcomes with a known effect.
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
source(file.path(FP_EXP, "common/kit.R"))
suppressPackageStartupMessages(library(survival))
set.seed(31337)
PS <- readRDS(file.path(FP_OUT, "statin3/oof3_ps.rds"))
TRUE_LOG_HR <- log(1.5); NREP <- 300L
MODELS <- c(local="local", sharedGlobal="global, shared intercept", siteGlobal="global, site intercepts")

for (sn in c("ehrshot","mimic")) {
  dd <- readRDS(sprintf(file.path(FP_OUT, "sitedata/tri/%s.rds"), sn))
  Z <- as(dd$x,"CsparseMatrix"); y <- dd$treatment; n <- length(y)
  ## Confounder: sparse random combination of covariates.
  nsel <- min(150L, ncol(Z)); w <- numeric(ncol(Z))
  w[sample(ncol(Z), nsel)] <- rnorm(nsel, 0, 0.4)
  zc <- as.vector(Z %*% w); zc <- (zc - mean(zc))/sd(zc)
  ## confounding strength: SMD of z between treatment groups
  cat(sprintf("\n=== %s (n=%d) ===\n  SMD of z between treatment groups = %.3f\n",
      sn, n, abs(mean(zc[y==1])-mean(zc[y==0]))/sqrt((var(zc[y==1])+var(zc[y==0]))/2)))
  matched <- lapply(names(MODELS), function(mk) matchPs(PS[[sn]][[mk]], y))
  names(matched) <- names(MODELS)
  acc <- list()
  for (rep in 1:NREP) {
    lp <- TRUE_LOG_HR*y + 0.9*zc
    tt <- rexp(n, rate = 0.02*exp(lp)); fu <- rep(30, n)
    ev <- as.integer(tt <= fu); tm <- pmin(tt, fu)
    est <- function(idx) { d <- data.frame(t=tm[idx], e=ev[idx], a=y[idx])
      if (sum(d$e)<5 || length(unique(d$a))<2) return(NA_real_)
      tryCatch(unname(coef(coxph(Surv(t,e)~a, data=d))[1]), error=function(x) NA_real_) }
    acc[[rep]] <- c(unadj=est(seq_len(n)), sapply(names(MODELS), function(mk) est(matched[[mk]]$idx)))
  }
  A <- do.call(rbind, acc)
  out <- data.frame(analysis=c("unadjusted", unname(MODELS)),
    n_ok=apply(A,2,function(v) sum(is.finite(v))),
    meanLogHR=apply(A,2,function(v) mean(v,na.rm=TRUE)),
    bias=apply(A,2,function(v) mean(v,na.rm=TRUE))-TRUE_LOG_HR,
    sd=apply(A,2,function(v) sd(v,na.rm=TRUE)),
    rmse=apply(A,2,function(v) sqrt(mean((v-TRUE_LOG_HR)^2,na.rm=TRUE))),
    pairs=c(NA, sapply(names(MODELS), function(mk) matched[[mk]]$pairs)))
  rownames(out) <- NULL
  print(out, row.names=FALSE, digits=4)
  write.csv(out, sprintf(file.path(FP_OUT, "statin3/tables/table11_bias_%s.csv"), sn), row.names=FALSE)
}
cat(sprintf("\ntrue log HR = %.4f (HR = %.2f), %d replicates\n", TRUE_LOG_HR, exp(TRUE_LOG_HR), NREP))
