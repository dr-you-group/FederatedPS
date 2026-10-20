## Phase 3: five three-site partitions of one pooled dataset (top 300 covariates by prevalence,
## so that the exact P = 1 baseline over the pda transport stays tractable).
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
source(file.path(FP_EXP, "common/kit.R"))
set.seed(31415)
D <- loadDesign("mimic")
prev <- colSums(D$X != 0)
keep <- order(-prev)[1:300]; keep <- sort(keep)
Xc <- D$X[, keep, drop = FALSE]; feat <- D$feat[keep]; y <- D$y; rows <- D$rows
n <- nrow(Xc)
cat(sprintf("pooled subproblem: %d subjects, %d covariates (+intercept), treated %d (%.3f)\n",
            n, ncol(Xc), sum(y == 1), mean(y)))
saveRDS(list(X = Xc, feat = feat, y = y, rows = rows), file.path(FP_OUT, "phases/phase3_pooled.rds"))

burden <- as.vector(rowSums(Xc))                    # comorbidity burden, drives shift
mk <- function(tag, grp) {
  stopifnot(length(grp) == n, all(sort(unique(grp)) == 1:3))
  out <- file.path(file.path(FP_OUT, "sitedata"), tag); dir.create(out, recursive = TRUE, showWarnings = FALSE)
  info <- data.frame()
  for (k in 1:3) {
    idx <- which(grp == k); Xk <- Xc[idx, , drop = FALSE]
    cols <- colSums(Xk != 0) > 0
    Xk <- Xk[, cols, drop = FALSE]; colnames(Xk) <- as.character(feat[cols])
    stopifnot(length(unique(y[idx])) == 2)
    saveRDS(list(x = as(Xk, "CsparseMatrix"), treatment = y[idx], rowIds = rows[idx]),
            file.path(out, sprintf("s%d.rds", k)))
    info <- rbind(info, data.frame(site = k, n = length(idx), prevalence = mean(y[idx]),
                                   meanBurden = mean(burden[idx]), features = ncol(Xk)))
  }
  cat(sprintf("\n[%s]\n", tag)); print(info, row.names = FALSE, digits = 4)
  info$setting <- tag; info
}
info <- list()
## A: IID, balanced
info$A <- mk("p3A", sample(rep(1:3, length.out = n)))
## B: unbalanced 10:3:1, otherwise IID
sz <- round(n * c(10, 3, 1) / 14); sz[3] <- n - sum(sz[1:2])
info$B <- mk("p3B", sample(rep(1:3, times = sz)))
## C: covariate shift, balanced sizes - split on comorbidity burden
info$C <- mk("p3C", as.integer(cut(rank(burden, ties.method = "random"),
                                   breaks = 3, labels = FALSE)))
## D: treatment-prevalence shift, balanced sizes.
## Targets must average to the pooled prevalence (0.650) or the partition is
## infeasible; the last site absorbs the rounding remainder.
{
  g <- integer(n); tr <- sample(which(y == 1)); co <- sample(which(y == 0))
  m <- floor(n / 3); sizes <- c(m, m, n - 2 * m); target <- c(0.85, 0.65, 0.45)
  n1 <- c(round(sizes[1] * target[1]), round(sizes[2] * target[2]), 0)
  n1[3] <- length(tr) - sum(n1[1:2])
  n0 <- sizes - n1
  stopifnot(all(n1 > 0), all(n0 > 0), sum(n0) == length(co))
  ti <- 1L; ci <- 1L
  for (k in 1:3) {
    g[tr[ti:(ti + n1[k] - 1L)]] <- k; ti <- ti + n1[k]
    g[co[ci:(ci + n0[k] - 1L)]] <- k; ci <- ci + n0[k]
  }
  info$D <- mk("p3D", g)
}
## E: combined - unbalanced 10:3:1 + covariate shift + treatment-prevalence shift.
{
  sz <- round(n * c(10, 3, 1) / 14); sz[3] <- n - sum(sz[1:2])
  ord <- order(burden, runif(n))                    # low burden -> site 1, high -> site 3
  g <- integer(n)
  g[ord[1:sz[1]]] <- 1L
  g[ord[(sz[1] + 1):(sz[1] + sz[2])]] <- 2L
  g[ord[(sz[1] + sz[2] + 1):n]] <- 3L
  # add a prevalence shift by swapping equal numbers between sites 1 and 3,
  # bounded so that both exposure groups survive at every site
  s1t <- which(g == 1 & y == 1); s3c <- which(g == 3 & y == 0)
  # cap the swap so that site 3 keeps at least 10 % controls
  cap <- max(0L, length(s3c) - ceiling(0.10 * sz[3]))
  nsw <- min(length(s1t) - 1L, cap, floor(0.40 * sz[3]))
  if (nsw > 0) { g[sample(s1t, nsw)] <- 3L; g[sample(s3c, nsw)] <- 1L }
  stopifnot(all(sort(unique(g)) == 1:3))
  info$E <- mk("p3E", g)
}
write.csv(do.call(rbind, info), file.path(FP_OUT, "phases/tables/phase3_partitions.csv"), row.names = FALSE)
