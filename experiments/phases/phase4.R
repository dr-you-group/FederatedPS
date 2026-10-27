## Phase 4: CKKS aggregation of the block packets (TenSEAL, see ckks.py).
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
source(file.path(FP_EXP, "common/kit.R")); source(file.path(FP_EXP, "phases/mirror.R"))
suppressPackageStartupMessages(library(reticulate))
use_python(Sys.getenv("FP_PYTHON", "python3"), required = TRUE)
ck <- import_from_path("ckks", path = file.path(FP_EXP, "phases"))
np <- import("numpy")

PL <- readRDS(file.path(FP_OUT, "phases/phase3_pooled.rds"))
Xp <- as(cbind(Matrix(1, nrow(PL$X), 1, sparse = TRUE), PL$X), "CsparseMatrix")
y <- PL$y; d <- ncol(Xp); P <- 20L; ALPHA <- 0.062
cat(sprintf("Phase 4 problem: n = %d, d = %d, P = %d, alpha = %.2f\n", nrow(Xp), d, P, ALPHA))
## three sites = the covariate-shift partition (setting C)
S <- lapply(1:3, function(k) {
  dd <- readRDS(sprintf(file.path(FP_OUT, "sitedata/p3C/s%d.rds"), k))
  j <- match(as.numeric(colnames(dd$x)), PL$feat)
  t <- Matrix::summary(as(dd$x, "TsparseMatrix"))
  X <- sparseMatrix(i = t$i, j = j[t$j], x = t$x, dims = c(nrow(dd$x), length(PL$feat)))
  list(X = as(cbind(Matrix(1, nrow(X), 1, sparse = TRUE), X), "CsparseMatrix"), y = dd$treatment)
})
cat(sprintf("sites: %s\n", paste(sapply(S, function(s) nrow(s$X)), collapse = " / ")))

## ---- 1. mirror vs compiled C++ --------------------------------------------
cpp <- runCfg(Xp, y, P = P, alpha = ALPHA)
mir <- mirrorBlockCCD(S, P = P, alpha = ALPHA)
cat(sprintf("\n[1] mirror vs compiled C++ (plaintext): passes %d vs %d ; rounds %d vs %d\n",
            mir$passes, cpp$passes, mir$rounds, cpp$R_loop))
cat(sprintf("    max|diff| = %.3e  relerr = %.3e  support identical = %s\n",
            max(abs(mir$beta - cpp$beta)),
            sqrt(sum((mir$beta - cpp$beta)^2))/sqrt(sum(cpp$beta^2)),
            identical(which(mir$beta != 0), which(cpp$beta != 0))))

## ---- 2. packet-level CKKS aggregation error --------------------------------
cap <- new.env(); cap$pk <- list(); cap$i <- 0L
capAgg <- function(pk, w) { cap$i <- cap$i + 1L
  if (cap$i %% 97L == 1L) cap$pk[[length(cap$pk) + 1L]] <- list(w = w, pk = pk)
  v <- Reduce(`+`, lapply(pk, function(p) p[seq_len(2*w)])); c(v, pk[[1]][(2*w+1):(4*w)]) }
invisible(mirrorBlockCCD(S, P = P, alpha = ALPHA, aggFun = capAgg))
cat(sprintf("\n[2] captured %d representative packets across the whole run\n", length(cap$pk)))

rows <- list()
for (Ndeg in c(8192L, 32768L)) {
  ctx <- ck$make_context(poly_modulus_degree = Ndeg, scale_bits = 40L)
  for (scheme in c("A_full", "B_stats")) {
    ei <- er <- ct <- te <- ta <- td <- numeric(0); nct <- 0L
    for (rec in cap$pk) {
      w <- rec$w
      vecs <- lapply(rec$pk, function(p) if (scheme == "A_full") p else p[seq_len(2*w)])
      res <- ck$aggregate(ctx, lapply(vecs, function(v) np$array(v)))
      e <- ck$err(res[[1]], res[[2]])
      ei <- c(ei, e$inf); er <- c(er, e$rel_inf)
      t <- res[[3]]; te <- c(te, t$encrypt); ta <- c(ta, t$add); td <- c(td, t$decrypt)
      ct <- c(ct, t$ct_bytes); nct <- nct + as.integer(t$n_ct)
    }
    rows[[length(rows)+1L]] <- data.frame(N = Ndeg, slots = Ndeg %/% 2L, scheme = scheme,
      width = if (scheme == "A_full") 4L*P else 2L*P,
      inf_err_median = median(ei), inf_err_max = max(ei),
      rel_inf_median = median(er), rel_inf_max = max(er),
      ct_bytes = median(ct), ct_per_block = 3L,
      encrypt_ms = 1e3*median(te), add_ms = 1e3*median(ta), decrypt_ms = 1e3*median(td))
  }
}
tabP <- do.call(rbind, rows); rownames(tabP) <- NULL
write.csv(tabP, file.path(FP_OUT, "phases/tables/phase4_packet_error.csv"), row.names = FALSE)
cat("\n[2] packet-level CKKS aggregation error\n"); print(tabP, row.names = FALSE, digits = 4)

## ---- 3. CKKS in the loop, end to end ---------------------------------------
ctx <- ck$make_context(poly_modulus_degree = 8192L, scale_bits = 40L)
mkAgg <- function(scheme, stat) function(pk, w) {
  stat$n <- stat$n + 1L
  vecs <- lapply(pk, function(p) if (scheme == "A_full") p else p[seq_len(2*w)])
  t0 <- Sys.time()
  res <- ck$aggregate(ctx, lapply(vecs, function(v) np$array(v)))
  stat$t <- stat$t + as.numeric(difftime(Sys.time(), t0, units = "secs"))
  dec <- as.numeric(res[[2]]); stat$ct <- stat$ct + 3L
  e <- abs(as.numeric(res[[1]]) - dec); stat$maxerr <- max(stat$maxerr, max(e))
  # beta and bound are identical at every site; their homomorphic sum is K times the value
  if (scheme == "A_full") c(dec[seq_len(2*w)], dec[(2*w+1):(4*w)] / length(pk))
  else c(dec[seq_len(2*w)], pk[[1]][(2*w+1):(4*w)])
}
pl <- mirrorBlockCCD(S, P = P, alpha = ALPHA)
ref <- metrics(pl$beta, Xp, y); refMM <- matchPs(ref$ps, y)
refBal <- smdStats(Xp[,-1,drop=FALSE], y, refMM$idx)
res3 <- list()
for (scheme in c("A_full", "B_stats")) {
  stat <- new.env(); stat$n <- 0L; stat$t <- 0; stat$ct <- 0L; stat$maxerr <- 0
  t0 <- Sys.time()
  r <- mirrorBlockCCD(S, P = P, alpha = ALPHA, aggFun = mkAgg(scheme, stat))
  wall <- as.numeric(difftime(Sys.time(), t0, units = "secs"))
  m <- metrics(r$beta, Xp, y); mm <- matchPs(m$ps, y)
  bal <- smdStats(Xp[,-1,drop=FALSE], y, mm$idx)
  res3[[length(res3)+1L]] <- data.frame(scheme = scheme,
    passes = r$passes, plaintextPasses = pl$passes, rounds = r$rounds,
    maxAggError = stat$maxerr, ciphertexts = stat$ct,
    ckksSeconds = stat$t, totalSeconds = wall,
    maxCoefDiff = max(abs(r$beta - pl$beta)),
    relCoefErr = sqrt(sum((r$beta - pl$beta)^2))/sqrt(sum(pl$beta^2)),
    objGapRel = (m$obj - ref$obj)/abs(ref$obj), kkt = m$kkt, kktPlain = ref$kkt,
    nnz = m$nnz, nnzPlain = ref$nnz,
    supportDiff = length(union(setdiff(which(pl$beta!=0), which(r$beta!=0)),
                               setdiff(which(r$beta!=0), which(pl$beta!=0)))),
    psCor = cor(m$ps, ref$ps), maxPSdiff = max(abs(m$ps - ref$ps)),
    matchedPairs = mm$pairs, meanSMD = bal$summary["mean"], meanSMDplain = refBal$summary["mean"],
    n_gt_0.1 = bal$summary["n_gt_0.1"])
  cat(sprintf("\n[3] %s: passes %d (plain %d) maxAggErr %.2e relCoefErr %.2e objGap %.2e nnz %d/%d SMD %.5f/%.5f\n",
      scheme, r$passes, pl$passes, stat$maxerr,
      sqrt(sum((r$beta-pl$beta)^2))/sqrt(sum(pl$beta^2)), (m$obj-ref$obj)/abs(ref$obj),
      m$nnz, ref$nnz, bal$summary["mean"], refBal$summary["mean"]))
}
tabE <- do.call(rbind, res3); rownames(tabE) <- NULL
write.csv(tabE, file.path(FP_OUT, "phases/tables/phase4_endtoend.csv"), row.names = FALSE)
saveRDS(list(packet = tabP, endtoend = tabE), file.path(FP_OUT, "phases/phase4.rds"))
cat("\nPhase 4 complete.\n")
