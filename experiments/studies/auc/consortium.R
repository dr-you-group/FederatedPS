## Consortium of small sites, no large partner. Evaluated at one focal site:
## local (own data), others (the other K - 1 sites), shared (all K).
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))

source(file.path(FP_EXP, "common/kit.R"))
suppressPackageStartupMessages(library(Matrix))
a <- commandArgs(TRUE); study <- a[1]; K <- as.integer(a[2]); n <- as.integer(a[3]); src <- a[4]
CV <- "cv" %in% a   # "cv": choose the prior variance by cross-validation
source(file.path(FP_EXP, "common/kitcv.R"))
NREP <- 5L; NFOLD <- 5L; SEED <- 20261003L

load1 <- function(site) {
  dd <- readRDS(sprintf(file.path(FP_DATA, "design/%s__%s.rds"), study, site))
  rows <- sort(dd$rowId); feat <- dd$covariateIds
  i <- match(dd$cov$rowId, rows); j <- match(dd$cov$covariateId, feat)
  ok <- !is.na(i) & !is.na(j)
  list(X=sparseMatrix(i=i[ok], j=j[ok], x=dd$cov$covariateValue[ok],
                      dims=c(length(rows), length(feat))),
       feat=feat, y=dd$treatment[match(rows, dd$rowId)]) }
M <- load1("mimiciv")
S <- if (src == "mixed") load1("synpuf") else NULL
axis <- sort(unique(c(M$feat, if (!is.null(S)) S$feat)))
onAx <- function(D, ix) { t <- summary(as(D$X[ix,,drop=FALSE], "TsparseMatrix"))
  j <- match(D$feat, axis)
  sparseMatrix(i=t$i, j=j[t$j], x=t$x, dims=c(length(ix), length(axis))) }

fit1 <- function(Xs, ys) {
  pres <- which(colSums(Xs != 0) > 0)
  if (!length(pres) || length(unique(ys)) < 2) return(NULL)
  r <- try(runCfg(cbind(Matrix(1,nrow(Xs),1,sparse=TRUE), Xs[,pres,drop=FALSE]), ys, P=1L, alpha=1), silent=TRUE)
  if (inherits(r,"try-error") || r$diverged) return(NULL)
  list(b0=r$beta[1], bj=r$beta[-1], idx=pres) }
if (CV) fit1 <- function(Xs, ys) fitCV(Xs, ys)
pred1 <- function(m, Xs) if (is.null(m)) rep(NA_real_, nrow(Xs)) else
  1/(1+exp(-(m$b0 + as.vector(Xs[,m$idx,drop=FALSE] %*% m$bj))))
auc1 <- function(p, yy) { ok <- is.finite(p); p <- p[ok]; yy <- yy[ok]
  if (length(unique(yy)) < 2) return(NA_real_)
  r <- rank(p); n1 <- as.numeric(sum(yy==1)); n0 <- as.numeric(sum(yy==0))
  (sum(r[yy==1]) - n1*(n1+1)/2)/(n1*n0) }
draw <- function(D, m, used) {              # treatment-stratified draw without reuse
  pr <- mean(D$y); nT <- max(2L, round(m*pr)); nC <- max(2L, m-nT)
  c1 <- setdiff(which(D$y==1), used); c0 <- setdiff(which(D$y==0), used)
  if (nT > length(c1) || nC > length(c0)) return(NULL)
  sort(c(sample(c1,nT), sample(c0,nC))) }

out <- list()
for (rep in 1:NREP) {
  set.seed(SEED + 1000L*rep + 97L*K + n)
  ## The focal site is MIMIC; the other K - 1 come from MIMIC (src = mimic) or SynPUF (mixed).
  usedM <- integer(0); sites <- list()
  ix <- draw(M, n, usedM); if (is.null(ix)) next
  usedM <- c(usedM, ix); sites[[1]] <- list(X=onAx(M,ix), y=M$y[ix])
  bad <- FALSE
  for (k in 2:K) {
    if (src == "mixed") { iy <- draw(S, n, integer(0)); if (is.null(iy)) { bad <- TRUE; break }
      sites[[k]] <- list(X=onAx(S,iy), y=S$y[iy]) }
    else { iy <- draw(M, n, usedM); if (is.null(iy)) { bad <- TRUE; break }
      usedM <- c(usedM, iy); sites[[k]] <- list(X=onAx(M,iy), y=M$y[iy]) } }
  if (bad) next
  Xo <- do.call(rbind, lapply(sites[-1], `[[`, "X"))      # all sites but the focal one
  yo <- unlist(lapply(sites[-1], `[[`, "y"))
  X1 <- sites[[1]]$X; y1 <- sites[[1]]$y
  fold <- integer(length(y1))
  for (g in c(0,1)) { iq <- which(y1==g); fold[iq] <- sample(rep_len(1:NFOLD, length(iq))) }
  ps <- matrix(NA_real_, length(y1), 3, dimnames=list(NULL,c("local","others","shared")))
  mOth <- fit1(Xo, yo)                                     # does not use focal data
  for (f in 1:NFOLD) {
    tr <- which(fold != f); te <- which(fold == f)
    ps[te,"local"]  <- pred1(fit1(X1[tr,,drop=FALSE], y1[tr]), X1[te,,drop=FALSE])
    ps[te,"others"] <- pred1(mOth, X1[te,,drop=FALSE])
    ps[te,"shared"] <- pred1(fit1(rbind(Xo, X1[tr,,drop=FALSE]), c(yo, y1[tr])), X1[te,,drop=FALSE]) }
  for (m in colnames(ps)) out[[length(out)+1L]] <- data.frame(
    study=study, K=K, n=n, src=src, rep=rep, model=m, auc=auc1(ps[,m], y1))
}
res <- do.call(rbind, out)
OUT <- sprintf(file.path(FP_OUT, "consortium%s"), if (CV) "_cv" else ""); dir.create(OUT, showWarnings=FALSE)
write.csv(res, sprintf(paste0(OUT, "/%s_K%d_n%d_%s.csv"), study, K, n, src), row.names=FALSE)
g <- function(m) mean(res$auc[res$model==m], na.rm=TRUE)
cat(sprintf("%-29s K=%2d n=%5d %-6s  local %.3f / others %.3f / shared %.3f  | sh-lo %+.3f sh-ot %+.4f\n",
    study, K, n, src, g("local"), g("others"), g("shared"), g("shared")-g("local"), g("shared")-g("others")))
