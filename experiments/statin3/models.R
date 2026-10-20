## Methods A (MIMIC-local), B (site-local), C (centralized pooled).
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
source(file.path(FP_EXP, "common/kit.R"))
meta <- readRDS(file.path(FP_OUT, "statin3/meta.rds")); axis <- meta$axis; d <- meta$d
SITES <- c("synpuf","mimic","ehrshot")
S <- lapply(SITES, function(nm) {
  dd <- readRDS(sprintf(file.path(FP_OUT, "sitedata/tri/%s.rds"), nm))
  j <- match(as.numeric(colnames(dd$x)), axis)
  t <- Matrix::summary(as(dd$x, "TsparseMatrix"))
  Xg <- sparseMatrix(i = t$i, j = j[t$j], x = t$x, dims = c(nrow(dd$x), length(axis)))
  list(name = nm, Xlocal = as(dd$x, "CsparseMatrix"),
       Xg = as(cbind(Matrix(1, nrow(Xg), 1, sparse = TRUE), Xg), "CsparseMatrix"),
       y = dd$treatment, rows = dd$rowIds, localFeat = as.numeric(colnames(dd$x)))
}); names(S) <- SITES
X <- do.call(rbind, lapply(S, `[[`, "Xg")); y <- unlist(lapply(S, `[[`, "y"))
site <- rep(SITES, sapply(S, function(s) nrow(s$Xg)))
Z <- X[, -1, drop = FALSE]
cat(sprintf("pooled: %d x %d, nnz %d\n", nrow(X), ncol(X), length(X@x)))

## ---------- C: pooled fit ----------
t0 <- Sys.time(); pooled <- runCfg(X, y, P = 1L, alpha = 1)
mP <- metrics(pooled$beta, X, y)
cat(sprintf("[C] pooled: flag=%s passes=%d nnz=%d obj=%.4f kkt=%.3f  %.1fs\n",
            pooled$flag, pooled$passes, mP$nnz, mP$obj, mP$kkt, pooled$localSeconds))

## ---------- A/B: site-local models, each on its own feature space ----------
locals <- list()
for (nm in SITES) {
  s <- S[[nm]]
  Xl <- as(cbind(Matrix(1, nrow(s$Xlocal), 1, sparse = TRUE), s$Xlocal), "CsparseMatrix")
  r <- runCfg(Xl, s$y, P = 1L, alpha = 1)
  ## embed the local coefficients into the common axis for comparison
  bg <- numeric(d); bg[1] <- r$beta[1]
  bg[1L + match(s$localFeat, axis)] <- r$beta[-1]
  psLocalSite <- 1/(1 + exp(-as.vector(Xl %*% r$beta)))   # PS within its own site
  locals[[nm]] <- list(beta = r$beta, betaGlobal = bg, fit = r,
                       psSite = psLocalSite, nfeat = ncol(Xl))
  cat(sprintf("[A/B] %-8s local: flag=%-18s passes=%-4d d_local=%-6d nnz=%-6d %.1fs\n",
              nm, r$flag, r$passes, ncol(Xl), sum(r$beta != 0), r$localSeconds))
}
saveRDS(list(pooled = pooled, mP = mP[setdiff(names(mP), "ps")], psPooled = mP$ps,
             locals = lapply(locals, function(l) l[c("beta","betaGlobal","fit","psSite","nfeat")]),
             y = y, site = site, axis = axis, d = d,
             siteRows = lapply(S, `[[`, "rows")),
        file.path(FP_OUT, "statin3/models.rds"))
cat("\nmodels.R complete\n")
