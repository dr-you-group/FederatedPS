## EHRSHOT: paired local vs global comparison on the same simulated outcomes.
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
source(file.path(FP_EXP, "common/kit.R")); suppressPackageStartupMessages(library(survival))
set.seed(987654)
TRUE_LHR <- log(1.5); NREP <- 1000L
makeZ <- function(Z, y, topK=200L) {
  t1<-as.numeric(y==1); t0<-as.numeric(y==0)
  p1<-as.vector(Matrix::crossprod(Z,t1))/sum(t1); p0<-as.vector(Matrix::crossprod(Z,t0))/sum(t0)
  den<-sqrt((p1*(1-p1)+p0*(1-p0))/2); s<-ifelse(den>1e-12,(p1-p0)/den,0)
  sel<-order(-abs(s))[1:min(topK,length(s))]; w<-numeric(ncol(Z)); w[sel]<-s[sel]
  z<-as.vector(Z%*%w); (z-mean(z))/sd(z) }
go <- function(tag, dir, psL, psG, y, gamma=1.0) {
  Z <- as(readRDS(sprintf(file.path(FP_OUT, "sitedata/%s/ehrshot.rds"), dir))$x, "CsparseMatrix")
  z <- makeZ(Z, y)
  mL <- matchPs(psL, y); mG <- matchPs(psG, y)
  L <- G <- numeric(NREP)
  for (r in 1:NREP) {
    lp <- TRUE_LHR*y + gamma*z
    tt <- rexp(length(y), rate=0.02*exp(lp)); ev <- as.integer(tt<=30); tm <- pmin(tt,30)
    est <- function(idx){ dd<-data.frame(t=tm[idx],e=ev[idx],a=y[idx])
      if(sum(dd$e)<5||length(unique(dd$a))<2) return(NA_real_)
      tryCatch(unname(coef(coxph(Surv(t,e)~a,data=dd))[1]), error=function(x) NA_real_) }
    L[r] <- est(mL$idx); G[r] <- est(mG$idx)
  }
  ok <- is.finite(L) & is.finite(G); L <- L[ok]; G <- G[ok]
  dif <- L - G; n <- length(dif)
  cat(sprintf("\n=== %s (pairs: local %d / global %d, replicates %d) ===\n", tag, mL$pairs, mG$pairs, n))
  cat(sprintf("  local   bias %+.4f   RMSE %.4f\n", mean(L)-TRUE_LHR, sqrt(mean((L-TRUE_LHR)^2))))
  cat(sprintf("  global  bias %+.4f   RMSE %.4f\n", mean(G)-TRUE_LHR, sqrt(mean((G-TRUE_LHR)^2))))
  cat(sprintf("  paired difference (local - global) = %+.5f +/- %.5f (MC SE)\n", mean(dif), sd(dif)/sqrt(n)))
  cat(sprintf("  t = %.2f ,  p = %.2g  ->  %s\n", mean(dif)/(sd(dif)/sqrt(n)),
      2*pt(-abs(mean(dif)/(sd(dif)/sqrt(n))), n-1),
      if (2*pt(-abs(mean(dif)/(sd(dif)/sqrt(n))), n-1) < 0.05) "significant" else "not significant"))
  cat(sprintf("  SD of a single estimate = %.4f\n", sd(G)))
  cat(sprintf("  difference as %% of that SD: %.1f%%\n", 100*abs(mean(dif))/sd(G)))
  invisible(NULL)
}
P1 <- readRDS(file.path(FP_OUT, "statin3/oof3_ps.rds"))
go("EHRSHOT, full consortium", "tri", P1$ehrshot$local, P1$ehrshot$sharedGlobal, P1$ehrshot$y)
P2 <- readRDS(file.path(FP_OUT, "statin3/small_oof_ps.rds"))
go("EHRSHOT, small consortium", "small", P2$ehrshot$local, P2$ehrshot$global, P2$ehrshot$y)
