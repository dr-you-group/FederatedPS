## Post-matching balance next to its within-pair randomisation reference.
## Binary covariate j, m matched pairs: swapping labels within pairs keeps the pair totals fixed
## (mean pbar), so delta = S / m with S = 2B - q, q discordant pairs, B ~ Bin(q, 1/2), and
## SMD = |delta| / sqrt(pbar (1 - pbar) - delta^2 / 4).
## Returns observed |SMD| > 0.1 counts and mean |SMD| with their expectations under that
## reference (exact binomial; normal approximation for q > 400).
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
balRCT <- function(Z, m) {
  m <- m[order(m$stratumId, -m$treatment), ]
  st <- unique(m$stratumId)
  t1 <- m$rowId[m$treatment == 1][match(st, m$stratumId[m$treatment == 1])]
  t0 <- m$rowId[m$treatment == 0][match(st, m$stratumId[m$treatment == 0])]
  np <- length(t1); A <- Z[t1, , drop = FALSE]; B0 <- Z[t0, , drop = FALSE]
  a1 <- colSums(A); a0 <- colSums(B0); pbar <- (a1 + a0) / (2 * np)
  q <- colSums((A - B0)^2); keep <- pbar > 0 & pbar < 1
  smdOf <- function(dl, pb) abs(dl) / sqrt(pmax(pb * (1 - pb) - dl^2 / 4, 1e-12))
  obs <- smdOf((a1 - a0) / np, pbar)[keep]
  pr <- numeric(sum(keep)); em <- numeric(sum(keep)); qq <- q[keep]; pp <- pbar[keep]
  for (i in seq_along(qq)) { qi <- qq[i]
    if (qi == 0) { pr[i] <- 0; em[i] <- 0; next }
    if (qi <= 400) { b <- 0:qi; w <- dbinom(b, qi, 0.5); s <- smdOf((2 * b - qi) / np, pp[i]) }
    else { sdv <- sqrt(qi); g <- seq(-5, 5, length.out = 401); w <- dnorm(g); w <- w / sum(w); s <- smdOf(g * sdv / np, pp[i]) }
    pr[i] <- sum(w[s > 0.1]); em[i] <- sum(w * s) }
  c(pairs = np, nCov = sum(keep), gt01 = sum(obs > 0.1), gt01RCT = sum(pr), excess01 = sum(obs > 0.1) - sum(pr),
    meanSMD = mean(obs), meanSMDRCT = mean(em)) }
