## Per-site design matrices for each test scenario (fixed seeds).
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
suppressPackageStartupMessages(library(Matrix))
scen <- commandArgs(trailingOnly = TRUE)[1]
out <- file.path(file.path(FP_OUT, "sitedata"), scen); dir.create(out, recursive = TRUE, showWarnings = FALSE)
save1 <- function(site, x, treatment, rowIds) {
  saveRDS(list(x = x, treatment = treatment, rowIds = rowIds), file.path(out, paste0(site, ".rds")))
  cat(sprintf("  %-8s n=%-8d p=%-6d nnz=%d\n", site, nrow(x), ncol(x), length(x@x)))
}
if (scen == "b1") {
  set.seed(101); n <- 500L; d <- 25L
  Xd <- matrix(rbinom(n*d, 1, 0.35), n, d)
  y <- rbinom(n, 1, 1/(1+exp(-(-0.3 + Xd %*% c(1.2,-0.9,0.7, rep(0,d-3))))))
  g <- rep(1:2, length.out = n)
  for (k in 1:2) { idx <- which(g==k)
    X <- as(Matrix(Xd[idx,,drop=FALSE], sparse=TRUE), "CsparseMatrix")
    colnames(X) <- as.character(seq_len(d))
    save1(paste0("s",k), X, y[idx], idx) }
} else if (scen == "b2") {
  set.seed(404); nk <- c(600L,200L,50L); d <- 30L; n <- sum(nk)
  Xd <- matrix(rbinom(n*d, 1, 0.35), n, d)
  y <- rbinom(n, 1, 1/(1+exp(-(-0.3 + Xd %*% c(1.3,-1.0,0.8, rep(0,d-3))))))
  grp <- rep(c("A","B","C"), nk)
  for (s in c("A","B","C")) { idx <- which(grp==s)
    X <- as(Matrix(Xd[idx,,drop=FALSE], sparse=TRUE), "CsparseMatrix")
    colnames(X) <- as.character(seq_len(d))
    save1(s, X, y[idx], idx) }
} else if (scen %in% c("b3","full")) {
  loadDesign <- function(nm) {
    dd <- readRDS(sprintf(file.path(FP_DATA, "statin/%s/design.rds"), nm))
    rows <- sort(dd$rowId); feat <- dd$covariateIds
    i <- match(dd$cov$rowId, rows); j <- match(dd$cov$covariateId, feat)
    ok <- !is.na(i) & !is.na(j)
    X <- sparseMatrix(i=i[ok], j=j[ok], x=dd$cov$covariateValue[ok],
                      dims=c(length(rows), length(feat)))
    colnames(X) <- as.character(feat)
    list(X = as(X,"CsparseMatrix"), y = dd$treatment[match(rows, dd$rowId)], rows = rows)
  }
  if (scen == "b3") {
    m <- loadDesign("mimic")
    set.seed(20260921); g <- sample(rep(1:2, length.out = nrow(m$X)))
    for (k in 1:2) { idx <- which(g==k)
      Xk <- m$X[idx,,drop=FALSE]; keep <- colSums(Xk != 0) > 0
      save1(paste0("s",k), Xk[, keep, drop=FALSE], m$y[idx], m$rows[idx]) }
  } else {
    m <- loadDesign("mimic"); s <- loadDesign("synpuf")
    save1("mimic", m$X, m$y, m$rows)
    set.seed(770); half <- sample(rep(1:2, length.out = nrow(s$X)))
    for (k in 1:2) { idx <- which(half==k)
      Xk <- s$X[idx,,drop=FALSE]; keep <- colSums(Xk != 0) > 0
      save1(paste0("synpuf",k), Xk[, keep, drop=FALSE], s$y[idx], s$rows[idx]) }
  }
}
cat("scenario", scen, "written to", out, "\n")
