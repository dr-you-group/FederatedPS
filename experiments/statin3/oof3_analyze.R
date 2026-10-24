source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
source(file.path(FP_EXP, "common/kit.R")); set.seed(2024)
meta <- readRDS(file.path(FP_OUT, "statin3/meta.rds")); PS <- readRDS(file.path(FP_OUT, "statin3/oof3_ps.rds"))
SITES <- names(PS); NB <- 300L
CAL <- c(0.02,0.05,0.075,0.1,0.15,0.2,0.3,0.5,0.75,1.0,1.5,2.0)
MODELS <- c(local="local", sharedGlobal="global, shared intercept", siteGlobal="global, site intercepts")

prep <- function(sn) {
  Z <- readRDS(sprintf(file.path(FP_OUT, "sitedata/tri/%s.rds"), sn))$x
  Z <- as(Z,"CsparseMatrix"); p <- colMeans(Z!=0); Z[, which(p>0 & p<1), drop=FALSE]
}
smdOf <- function(Zm, yy) { t1<-as.numeric(yy==1); t0<-as.numeric(yy==0)
  p1<-as.vector(Matrix::crossprod(Zm,t1))/sum(t1); p0<-as.vector(Matrix::crossprod(Zm,t0))/sum(t0)
  den<-sqrt((p1*(1-p1)+p0*(1-p0))/2); ifelse(den>1e-12, abs(p1-p0)/den, 0) }
matchAt <- function(ps, yy, cal) {
  pop <- data.frame(rowId=seq_along(yy), treatment=yy, propensityScore=ps)
  CohortMethod::matchOnPs(pop, matchOnPsArgs=CohortMethod::createMatchOnPsArgs(
    caliper=cal, caliperScale="standardized logit", maxRatio=1)) }

main <- list(); sweep <- list()
for (sn in SITES) {
  Zf <- prep(sn); yy <- PS[[sn]]$y; nT <- sum(yy==1)
  cat(sprintf("\n=== %s: n=%d, treated=%d, covariates=%d ===\n", sn, length(yy), nT, ncol(Zf)))
  for (mk in names(MODELS)) {
    m <- matchAt(PS[[sn]][[mk]], yy, 0.2)
    Zm <- Zf[m$rowId,,drop=FALSE]; ym <- yy[m$rowId]; st <- m$stratumId
    o <- smdOf(Zm, ym)
    ord <- order(st); i1 <- ord[seq(1,length(ord),2)]; i2 <- ord[seq(2,length(ord),2)]
    nul <- replicate(NB, { f <- sample(c(0L,1L), length(i1), TRUE)
      lab <- integer(length(st)); lab[i1] <- f; lab[i2] <- 1L-f; mean(smdOf(Zm, lab)) })
    main[[length(main)+1L]] <- data.frame(site=sn, model=MODELS[[mk]], caliper=0.2,
      pairs=sum(ym==1), retention=sum(ym==1)/nT, mean=mean(o), median=median(o),
      max=max(o), gt0.1=sum(o>0.1), gt0.2=sum(o>0.2),
      nullMean=mean(nul), nullHi95=unname(quantile(nul,.975)),
      overNoise=mean(o) > quantile(nul,.975))
  }
  for (mk in c("sharedGlobal","siteGlobal","local")) for (cal in CAL) {
    m <- matchAt(PS[[sn]][[mk]], yy, cal)
    Zm <- Zf[m$rowId,,drop=FALSE]; o <- smdOf(Zm, yy[m$rowId])
    sweep[[length(sweep)+1L]] <- data.frame(site=sn, model=MODELS[[mk]], caliper=cal,
      pairs=sum(yy[m$rowId]==1), retention=sum(yy[m$rowId]==1)/nT,
      mean=mean(o), max=max(o), gt0.1=sum(o>0.1), gt0.2=sum(o>0.2))
  }
}
M <- do.call(rbind, main); SW <- do.call(rbind, sweep); rownames(M) <- NULL; rownames(SW) <- NULL
write.csv(M, file.path(FP_OUT, "statin3/tables/table7_oof3_main.csv"), row.names=FALSE)
write.csv(SW, file.path(FP_OUT, "statin3/tables/table8_caliper_sweep.csv"), row.names=FALSE)
cat("\n########## caliper 0.2, out-of-fold ##########\n")
print(M[,c("site","model","pairs","retention","mean","median","max","gt0.1","gt0.2","nullHi95","overNoise")],
      row.names=FALSE, digits=4)
cat("\n########## local - global with site intercepts ##########\n")
for (sn in SITES) { a <- M[M$site==sn & M$model=="local",]; b <- M[M$site==sn & M$model=="global, site intercepts",]
  cat(sprintf("  %-8s mean %+.5f | median %+.5f | max %+.5f | >0.1 %+d | >0.2 %+d | pairs %+d\n",
      sn, a$mean-b$mean, a$median-b$median, a$max-b$max, a$gt0.1-b$gt0.1, a$gt0.2-b$gt0.2, a$pairs-b$pairs)) }
cat("\n########## at equal retention ##########\n")
for (sn in SITES) {
  s <- SW[SW$site==sn,]; b <- s[s$model=="global, site intercepts",]; a <- s[s$model=="global, shared intercept",]
  tgt <- M$pairs[M$site==sn & M$model=="global, site intercepts"]
  ai <- approx(a$pairs, a$mean, xout=tgt, rule=2)$y
  bi <- approx(b$pairs, b$mean, xout=tgt, rule=2)$y
  cat(sprintf("  %-8s at %d pairs: shared intercept mean=%.5f  site intercepts mean=%.5f  diff %+.5f\n",
      sn, tgt, ai, bi, ai-bi))
}
cat("\n########## caliper sweep (SMD-retention) ##########\n")
print(SW[,c("site","model","caliper","pairs","retention","mean","gt0.1","gt0.2")], row.names=FALSE, digits=4)
