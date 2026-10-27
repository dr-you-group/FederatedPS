## Phase 1: propensity-score matching and covariate balance at full scale, exact vs block CCD.
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
source(file.path(FP_EXP, "common/kit.R"))
suppressPackageStartupMessages(library(ggplot2))
set.seed(1)

bExact <- readRDS(file.path(FP_DATA, "statin/mimic/psModelCoef.rds"))               # exact federated CCD
bBlock <- readRDS(file.path(FP_OUT, "fedruns/fullP20/agg.rds"))$coefficients  # proximal block CCD
stopifnot(setequal(names(bExact), names(bBlock)))
bBlock <- bBlock[names(bExact)]
axis <- as.numeric(names(bExact)[-1])
M <- loadDesign("mimic"); S <- loadDesign("synpuf")
X <- rbind(onAxis(M, axis), onAxis(S, axis)); y <- c(M$y, S$y)
site <- c(rep("mimic", nrow(M$X)), rep("synpuf", nrow(S$X)))
rm(M, S); invisible(gc())
Z <- X[, -1, drop = FALSE]
cat(sprintf("pooled %d x %d, nnz %d, treated %d, control %d\n",
            nrow(X), ncol(X), length(X@x), sum(y == 1), sum(y == 0)))

mE <- metrics(unname(bExact), X, y); mB <- metrics(unname(bBlock), X, y)
pre <- smdStats(Z, y)
rows <- list(); loveDat <- list(); matched <- list()
for (nm in c("Exact federated CCD", "Proximal block CCD")) {
  ps <- if (nm == "Exact federated CCD") mE$ps else mB$ps
  mm <- matchPs(ps, y)
  post <- smdStats(Z, y, mm$idx)
  matched[[nm]] <- list(mm = mm, post = post, ps = ps)
  for (stg in c("before", "after")) {
    s <- if (stg == "before") pre$summary else post$summary
    rows[[length(rows) + 1L]] <- data.frame(method = nm, stage = stg,
      meanSMD = s["mean"], medianSMD = s["median"], p90SMD = s["p90"], maxSMD = s["max"],
      n_gt_0.1 = s["n_gt_0.1"], n_gt_0.2 = s["n_gt_0.2"], nCovariates = s["nCov"],
      matchedPairs = if (stg == "after") mm$pairs else NA_integer_,
      unmatchedTreated = if (stg == "after") mm$unmatchedTreated else NA_integer_,
      unmatchedControl = if (stg == "after") mm$unmatchedControl else NA_integer_)
  }
}
tab <- do.call(rbind, rows); rownames(tab) <- NULL
write.csv(tab, file.path(FP_OUT, "phases/tables/phase1_balance.csv"), row.names = FALSE)
cat("\n=== Phase 1: balance summary ===\n"); print(tab, row.names = FALSE, digits = 4)

cat(sprintf("\nsolution comparison: objective %.4f vs %.4f (rel gap %.4e)\n",
            mE$obj, mB$obj, (mB$obj - mE$obj) / abs(mE$obj)))
cat(sprintf("KKT %.3f vs %.3f ; nnz %d vs %d ; PS correlation %.6f ; max|dPS| %.5f\n",
            mE$kkt, mB$kkt, mE$nnz, mB$nnz, cor(mE$ps, mB$ps), max(abs(mE$ps - mB$ps))))

## ---- covariates with the largest balance change (exact -> block, after matching)
pE <- matched[["Exact federated CCD"]]$post; pB <- matched[["Proximal block CCD"]]$post
common <- intersect(pE$which, pB$which)
dE <- pE$smd[match(common, pE$which)]; dB <- pB$smd[match(common, pB$which)]
chg <- data.frame(covariateId = sprintf("%.0f", axis[common]), smd_exact = dE, smd_block = dB,
                  delta = dB - dE, smd_before = pre$smd[match(common, pre$which)])
chg <- chg[order(-abs(chg$delta)), ]
write.csv(head(chg, 30), file.path(FP_OUT, "phases/tables/phase1_largest_changes.csv"), row.names = FALSE)
cat("\n=== 10 covariates with the largest post-matching SMD change ===\n")
print(head(chg, 10), row.names = FALSE, digits = 4)
cat("\n(covariate ids printed exactly)\n")

## ---- Love plot: top 35 covariates by pre-matching imbalance ----------------
top <- order(-pre$smd)[1:35]; ids <- pre$which[top]
lp <- rbind(
  data.frame(cov = factor(axis[ids]), smd = pre$smd[top], stage = "Before matching"),
  data.frame(cov = factor(axis[ids]), smd = pE$smd[match(ids, pE$which)],
             stage = "After matching - exact CCD"),
  data.frame(cov = factor(axis[ids]), smd = pB$smd[match(ids, pB$which)],
             stage = "After matching - proximal block CCD"))
lp$cov <- factor(lp$cov, levels = rev(as.character(axis[ids])))
g <- ggplot(lp, aes(x = smd, y = cov, colour = stage, shape = stage)) +
  geom_vline(xintercept = 0.1, linetype = "dashed", colour = "grey40") +
  geom_point(size = 2, alpha = 0.85) +
  labs(x = "absolute standardized mean difference", y = "covariate id",
       title = "Love plot: 35 most imbalanced covariates (full scale, d = 40,376)",
       colour = NULL, shape = NULL) +
  theme_minimal(base_size = 9) + theme(legend.position = "bottom")
ggsave(file.path(FP_OUT, "phases/figs/phase1_love.png"), g, width = 8, height = 7, dpi = 150)

## ---- PS distribution plots -------------------------------------------------
sub <- sample.int(length(y), 150000)
pd <- rbind(
  data.frame(ps = mE$ps[sub], treatment = ifelse(y[sub] == 1, "target", "comparator"),
             method = "Exact federated CCD"),
  data.frame(ps = mB$ps[sub], treatment = ifelse(y[sub] == 1, "target", "comparator"),
             method = "Proximal block CCD"))
g2 <- ggplot(pd, aes(x = ps, fill = treatment)) +
  geom_histogram(bins = 80, position = "identity", alpha = 0.55) +
  facet_wrap(~ method, ncol = 1) +
  labs(x = "propensity score", y = "subjects (150k sample)",
       title = "Propensity-score distributions by exposure group") +
  theme_minimal(base_size = 10)
ggsave(file.path(FP_OUT, "phases/figs/phase1_ps_dist.png"), g2, width = 8, height = 6, dpi = 150)
g3 <- ggplot(data.frame(e = mE$ps, b = mB$ps)[sub, ], aes(e, b)) +
  geom_hex(bins = 80) + geom_abline(slope = 1, colour = "red", linewidth = 0.3) +
  scale_fill_continuous(trans = "log10") +
  labs(x = "PS, exact federated CCD", y = "PS, proximal block CCD",
       title = sprintf("PS agreement (r = %.6f, max|diff| = %.4f)",
                       cor(mE$ps, mB$ps), max(abs(mE$ps - mB$ps)))) +
  theme_minimal(base_size = 10)
ggsave(file.path(FP_OUT, "phases/figs/phase1_ps_agreement.png"), g3, width = 6.5, height = 5, dpi = 150)

saveRDS(list(tab = tab, pre = pre, matched = lapply(matched, function(m)
          list(pairs = m$mm$pairs, idx = m$mm$idx, post = m$post)),
        psE = mE$ps, psB = mB$ps, y = y, site = site, axis = axis,
        mE = mE[setdiff(names(mE), "ps")], mB = mB[setdiff(names(mB), "ps")]),
        file.path(FP_OUT, "phases/phase1.rds"))
cat("\nPhase 1 complete.\n")
