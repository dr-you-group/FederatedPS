## Noise floor of post-matching SMD: flip treatment labels at random within matched pairs.
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
source(file.path(FP_EXP, "common/kit.R")); set.seed(99)
meta <- readRDS(file.path(FP_OUT, "statin3/meta.rds")); SW <- readRDS(file.path(FP_OUT, "statin3/sweep.rds")); axis <- meta$axis
SITES <- meta$sites
S <- lapply(SITES, function(nm){ dd <- readRDS(sprintf(file.path(FP_OUT, "sitedata/tri/%s.rds"), nm))
  list(Xl=as(dd$x,"CsparseMatrix"), y=dd$treatment) }); names(S) <- SITES
site <- SW$site; psP <- SW$psRef
B <- 200L
for (sn in SITES) {
  ii <- which(site==sn); Z <- S[[sn]]$Xl; yi <- S[[sn]]$y
  p <- colMeans(Z!=0); fx <- which(p>0 & p<1); Zf <- Z[,fx,drop=FALSE]
  pop <- data.frame(rowId=seq_along(yi), treatment=yi, propensityScore=psP[ii])
  m <- CohortMethod::matchOnPs(pop, matchOnPsArgs=CohortMethod::createMatchOnPsArgs(
         caliper=0.2, caliperScale="standardized logit", maxRatio=1))
  idx <- m$rowId; st <- m$stratumId; Zm <- Zf[idx,,drop=FALSE]; ym <- yi[idx]
  smd <- function(yy){ t1<-as.numeric(yy==1); t0<-as.numeric(yy==0)
    p1<-as.vector(Matrix::crossprod(Zm,t1))/sum(t1); p0<-as.vector(Matrix::crossprod(Zm,t0))/sum(t0)
    den<-sqrt((p1*(1-p1)+p0*(1-p0))/2); ifelse(den>1e-12, abs(p1-p0)/den, 0) }
  obs <- smd(ym)
  nullMean <- numeric(B); nullGt1 <- numeric(B)
  for (b in 1:B) {                       # random swap within each pair
    flip <- ave(seq_along(st), st, FUN=function(z) sample(c(0,1), length(z)))
    d <- smd(flip); nullMean[b] <- mean(d); nullGt1[b] <- sum(d>0.1)
  }
  cat(sprintf("\n=== %s: %d pairs, %d covariates ===\n", sn, sum(ym==1), ncol(Zm)))
  cat(sprintf("  observed mean|SMD| = %.5f      | randomisation reference = %.5f [%.5f, %.5f]\n",
      mean(obs), mean(nullMean), quantile(nullMean,.025), quantile(nullMean,.975)))
  cat(sprintf("  observed >0.1 count = %-6d     | randomisation reference = %.0f [%.0f, %.0f]\n",
      sum(obs>0.1), mean(nullGt1), quantile(nullGt1,.025), quantile(nullGt1,.975)))
  cat(sprintf("  -> observed is %s\n",
      if (mean(obs) <= quantile(nullMean,.975)) "within the reference" else "above the reference"))
}
