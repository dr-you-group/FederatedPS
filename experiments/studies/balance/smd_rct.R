## Balance after matching, with the within-pair randomisation reference (balRCT), for small sites.
## setting: sweep   = partner A (60% of MIMIC) + site B of the given size
##          homo    = three 1,000-patient MIMIC sites
##          cluster = focal MIMIC site + two sites from the other covariate cluster
##          synpuf  = focal MIMIC site + two SynPUF sites
## Methods: local, transfer (partner model only), pooled (= FL). Prior variance chosen by CV.
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
source(file.path(FP_EXP, "common/kit.R")); source(file.path(FP_EXP, "common/kitcv.R")); source(file.path(FP_EXP, "common/balrct.R"))
a <- commandArgs(TRUE); study <- a[1]; setting <- a[2]; size <- if (length(a) > 2) as.integer(a[3]) else 1000L
NREP <- 10L; NN <- 1000L
load1 <- function(site) { dd <- readRDS(sprintf(file.path(FP_DATA, "design/%s__%s.rds"), study, site))
  rows <- sort(dd$rowId); feat <- dd$covariateIds; i <- match(dd$cov$rowId, rows); j <- match(dd$cov$covariateId, feat); ok <- !is.na(i) & !is.na(j)
  list(X = sparseMatrix(i=i[ok], j=j[ok], x=dd$cov$covariateValue[ok], dims=c(length(rows), length(feat))), feat = feat, y = dd$treatment[match(rows, dd$rowId)]) }
M <- load1("mimiciv"); S <- if (setting == "synpuf") load1("synpuf") else NULL
axis <- sort(unique(c(M$feat, if (!is.null(S)) S$feat)))
onAx <- function(D, ix) { t <- summary(as(D$X[ix,,drop=FALSE], "TsparseMatrix")); j <- match(D$feat, axis)
  sparseMatrix(i=t$i, j=j[t$j], x=t$x, dims=c(length(ix), length(axis))) }
y <- M$y
pred <- function(m, Xs) if (is.null(m)) NULL else 1/(1+exp(-(m$b0 + as.vector(Xs[, m$idx, drop=FALSE] %*% m$bj))))
mt <- function(ps, yy) { if (is.null(ps)) return(NULL); ps <- pmin(pmax(ps, 1e-8), 1-1e-8)
  m <- try(CohortMethod::matchOnPs(data.frame(rowId=seq_along(yy), treatment=yy, propensityScore=ps),
    matchOnPsArgs=CohortMethod::createMatchOnPsArgs(caliper=0.2, caliperScale="standardized logit", maxRatio=1)), silent=TRUE)
  if (inherits(m, "try-error") || sum(m$treatment==1) < 2) NULL else m }
drawM <- function(pool, used, n) { yy <- y[pool]; pr <- mean(y); nT <- max(2L, round(n*pr)); nC <- max(2L, n-nT)
  c1 <- setdiff(pool[yy==1], used); c0 <- setdiff(pool[yy==0], used); if (nT > length(c1) || nC > length(c0)) return(NULL); sort(c(sample(c1,nT), sample(c0,nC))) }
if (setting == "sweep") { set.seed(20261002L)
  iA <- sort(unlist(lapply(c(0,1), function(g) { ix <- which(y==g); sort(sample(ix, round(0.6*length(ix)))) })))
  pool <- setdiff(seq_along(y), iA); XA <- onAx(M, iA); yA <- y[iA]; mO <- fitCV(XA, yA) }
if (setting == "cluster") { set.seed(20261005L); pv <- colMeans(M$X != 0); tp <- order(-pv)[1:min(200L, ncol(M$X))]
  cl <- kmeans(as.matrix(M$X[, tp, drop=FALSE]), centers=2L, nstart=5L, iter.max=50L)$cluster
  P1 <- which(cl==1); P2 <- which(cl==2); if (length(P2) > length(P1)) { t <- P1; P1 <- P2; P2 <- t } } else { P1 <- P2 <- seq_along(y) }
out <- list()
for (rep in 1:NREP) {
  set.seed(20261012L + 1000L*rep + size + nchar(setting))
  if (setting == "sweep") { ix <- drawM(pool, integer(0), size); if (is.null(ix)) next; Xo <- XA; yo <- yA; mOr <- mO }
  else { ix <- drawM(P1, integer(0), NN); if (is.null(ix)) next; used <- ix; Xl <- list(); yl <- list(); bad <- FALSE
    for (k in 2:3) { if (setting == "synpuf") { pr <- mean(S$y); iy <- sort(c(sample(which(S$y==1), round(NN*pr)), sample(which(S$y==0), NN-round(NN*pr)))); Xl[[k-1]] <- onAx(S, iy); yl[[k-1]] <- S$y[iy] }
      else { iy <- drawM(if (setting == "cluster") P2 else P1, used, NN); if (is.null(iy)) { bad <- TRUE; break }; used <- c(used, iy); Xl[[k-1]] <- onAx(M, iy); yl[[k-1]] <- y[iy] } }
    if (bad) next; Xo <- do.call(rbind, Xl); yo <- unlist(yl); mOr <- fitCV(Xo, yo) }
  X1 <- onAx(M, ix); y1 <- y[ix]; Z <- (X1 != 0) * 1; Z <- Z[, colSums(Z) > 0, drop=FALSE]
  PS <- list(local = pred(fitCV(X1, y1), X1), transfer = pred(mOr, X1), pooled = pred(fitCV(rbind(Xo, X1), c(yo, y1)), X1))
  for (m in names(PS)) out[[length(out)+1]] <- data.frame(study=study, setting=setting, size=if (setting=="sweep") size else NN, rep=rep, method=m, t({ mm <- mt(PS[[m]], y1); if (is.null(mm)) c(pairs=0, nCov=NA, gt01=NA, gt01RCT=NA, excess01=NA, meanSMD=NA, meanSMDRCT=NA) else balRCT(Z, mm) })) }
R <- do.call(rbind, out); dir.create(file.path(FP_OUT, "smd_rct"), showWarnings=FALSE)
write.csv(R, sprintf(file.path(FP_OUT, "smd_rct/%s__%s_%d.csv"), study, setting, size), row.names=FALSE)
a2 <- aggregate(excess01 ~ method, R, mean); cat(sprintf("%-29s %-7s %5d  |SMD|>0.1 in excess of the reference: %s\n", study, setting, size, paste(sprintf("%s %.1f", a2$method, a2$excess01), collapse=" / ")))
