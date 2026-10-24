## Model A: one shared intercept.
## Model B: site intercepts (SynPUF baseline, unpenalised MIMIC and EHRSHOT dummies).
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
source(file.path(FP_EXP, "common/kit.R")); set.seed(5)
meta <- readRDS(file.path(FP_OUT, "statin3/meta.rds")); axis <- meta$axis; SITES <- meta$sites
S <- lapply(SITES, function(nm){ dd <- readRDS(sprintf(file.path(FP_OUT, "sitedata/tri/%s.rds"), nm))
  j <- match(as.numeric(colnames(dd$x)), axis); t <- Matrix::summary(as(dd$x,"TsparseMatrix"))
  Xg <- sparseMatrix(i=t$i, j=j[t$j], x=t$x, dims=c(nrow(dd$x), length(axis)))
  list(Xg=as(Xg,"CsparseMatrix"), Xl=as(dd$x,"CsparseMatrix"), y=dd$treatment) })
names(S) <- SITES
Xc <- do.call(rbind, lapply(S,`[[`,"Xg")); y <- unlist(lapply(S,`[[`,"y"))
site <- rep(SITES, sapply(S, function(s) nrow(s$Xg)))
dm <- sparseMatrix(i=which(site=="mimic"),   j=rep(1,sum(site=="mimic")),   dims=c(length(y),1))
de <- sparseMatrix(i=which(site=="ehrshot"), j=rep(1,sum(site=="ehrshot")), dims=c(length(y),1))

fitPooled <- function(sx, excl) {
  cd <- Cyclops::createCyclopsData(treatment ~ 1, data=data.frame(treatment=y), sx=sx,
                                   modelType="lr", floatingPoint=64)
  cd$coefficientNames <- c("(Intercept)", colnames(sx))
  f <- Cyclops::fitCyclopsModel(cd,
    prior=Cyclops::createPrior("laplace", variance=1, exclude=excl, useCrossValidation=FALSE),
    control=Cyclops::createControl(convergenceType="lange", seed=1L, noiseLevel="silent",
                                   tolerance=1e-6, maxIterations=1000L),
    startingCoefficients=rep(0, ncol(sx)+1L))
  list(beta=unname(stats::coef(f)), nm=names(stats::coef(f)), flag=f$return_flag, passes=f$iterations)
}
sxA <- Xc; colnames(sxA) <- paste0("v", seq_len(ncol(sxA)))
A <- fitPooled(sxA, "(Intercept)")
sxB <- cbind(dm, de, Xc); colnames(sxB) <- c("site_mimic","site_ehrshot", paste0("v", seq_len(ncol(Xc))))
B <- fitPooled(sxB, c("(Intercept)","site_mimic","site_ehrshot"))
cat(sprintf("A (shared intercept): flag=%s passes=%d nnz=%d  intercept=%.4f\n", A$flag, A$passes, sum(A$beta!=0), A$beta[1]))
cat(sprintf("B (site intercepts): flag=%s passes=%d nnz=%d  intercept(synpuf)=%.4f  +mimic=%.4f  +ehrshot=%.4f\n",
    B$flag, B$passes, sum(B$beta!=0), B$beta[1], B$beta[2], B$beta[3]))
betaA <- A$beta[-1]; betaB <- B$beta[-(1:3)]
cat(sprintf("slopes: max|dbeta|=%.4f  cor=%.5f  support difference=%d\n",
    max(abs(betaA-betaB)), cor(betaA,betaB),
    length(union(setdiff(which(betaA!=0),which(betaB!=0)), setdiff(which(betaB!=0),which(betaA!=0))))))
psA <- 1/(1+exp(-(A$beta[1] + as.vector(Xc %*% betaA))))
lpB <- B$beta[1] + as.numeric(dm)*B$beta[2] + as.numeric(de)*B$beta[3] + as.vector(Xc %*% betaB)
psB <- 1/(1+exp(-lpB))
NB <- 200L
for (sn in SITES) {
  ii <- which(site==sn); Z <- S[[sn]]$Xl; yi <- S[[sn]]$y
  p <- colMeans(Z!=0); fx <- which(p>0 & p<1); Zf <- Z[,fx,drop=FALSE]
  row <- function(ps, lab) {
    pop <- data.frame(rowId=seq_along(yi), treatment=yi, propensityScore=ps)
    m <- CohortMethod::matchOnPs(pop, matchOnPsArgs=CohortMethod::createMatchOnPsArgs(
           caliper=0.2, caliperScale="standardized logit", maxRatio=1))
    Zm <- Zf[m$rowId,,drop=FALSE]; ym <- yi[m$rowId]; st <- m$stratumId
    smd <- function(yy){ t1<-as.numeric(yy==1); t0<-as.numeric(yy==0)
      p1<-as.vector(Matrix::crossprod(Zm,t1))/sum(t1); p0<-as.vector(Matrix::crossprod(Zm,t0))/sum(t0)
      den<-sqrt((p1*(1-p1)+p0*(1-p0))/2); ifelse(den>1e-12, abs(p1-p0)/den, 0) }
    o <- smd(ym)
    ## each stratum has exactly two rows; swap labels per pair in vectorised form
    ord <- order(st); i1 <- ord[seq(1, length(ord), by = 2)]; i2 <- ord[seq(2, length(ord), by = 2)]
    stopifnot(length(i1) == length(i2), all(st[i1] == st[i2]))
    permLab <- function() { f <- sample(c(0L, 1L), length(i1), replace = TRUE)
      lab <- integer(length(st)); lab[i1] <- f; lab[i2] <- 1L - f; lab }
    nm <- replicate(NB, mean(smd(permLab())))
    data.frame(site=sn, model=lab, pairs=sum(ym==1), mean=mean(o), max=max(o),
               gt0.1=sum(o>0.1), gt0.2=sum(o>0.2), nullMean=mean(nm), nullHi=quantile(nm,.975),
               overNoise=mean(o) > quantile(nm,.975))
  }
  r <- rbind(row(psA[ii],"A shared intercept"), row(psB[ii],"B site intercepts"))
  print(r, row.names=FALSE, digits=4)
}
