## R implementation of the Cyclops proximal block CCD loop, used where the per-site packets
## have to be intercepted (CKKS aggregation in phase4.R).
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
LAMBDA1 <- sqrt(2); BOUND0 <- 2; BFLOOR <- 1e-3
.getDelta <- function(g, h, b) {                 # Cyclops LaplacePrior::getDelta
  if (!is.finite(h) || h <= 0) return(0)
  nu <- -(g - LAMBDA1) / h; pu <- -(g + LAMBDA1) / h; sb <- sign(b)
  if (sb == 0) { if (nu < 0) nu else if (pu > 0) pu else 0 }
  else { d <- if (sb < 0) nu else pu; if (sign(b + d) != sb) -b else d }
}
.getDeltaNoPrior <- function(g, h) if (!is.finite(h) || h <= 0) 0 else -g / h

#' @param S list of sites: list(X = dgCMatrix with intercept col 1, y)
#' @param aggFun function(list_of_site_packets) -> aggregated packet (length 4w)
mirrorBlockCCD <- function(S, P = 1L, alpha = 1, tol = 1e-6, maxPasses = 1000L,
                           aggFun = NULL, trace = FALSE) {
  d <- ncol(S[[1]]$X); K <- length(S)
  beta <- numeric(d); bnd <- rep(BOUND0, d)
  st <- lapply(S, function(s) list(eta = numeric(nrow(s$X)), p = rep(0.5, nrow(s$X)),
                                   w = rep(0.25, nrow(s$X))))
  Xb <- lapply(S, function(s) lapply(split(seq_len(d), ceiling(seq_len(d)/P)),
                                     function(b) s$X[, b, drop = FALSE]))
  X2b <- lapply(seq_len(K), function(k) lapply(Xb[[k]], function(m) m * m))
  blocks <- split(seq_len(d), ceiling(seq_len(d)/P)); nb <- length(blocks)
  prev <- NULL; rounds <- 0L; passes <- 0L; aggLog <- list()
  for (pass in seq_len(maxPasses)) {
    passes <- pass
    for (bi in seq_len(nb)) {
      blk <- blocks[[bi]]; w <- length(blk)
      pk <- lapply(seq_len(K), function(k) c(
        as.vector(Matrix::crossprod(Xb[[k]][[bi]],  st[[k]]$p - S[[k]]$y)),
        as.vector(Matrix::crossprod(X2b[[k]][[bi]], st[[k]]$w)),
        beta[blk], bnd[blk]))
      rounds <- rounds + 1L
      agg <- if (is.null(aggFun)) {
        v <- Reduce(`+`, lapply(pk, function(p) p[seq_len(2*w)]))
        c(v, pk[[1]][(2*w+1):(4*w)])
      } else aggFun(pk, w)
      g <- agg[seq_len(w)]; h <- agg[(w+1):(2*w)]
      del <- numeric(w)
      for (i in seq_len(w)) {
        j <- blk[i]; hh <- h[i]; gg <- g[i]
        if (!is.finite(hh) || hh < 0) { gg <- 0; hh <- 0 }
        hh <- hh / alpha
        dl <- if (j == 1L) .getDeltaNoPrior(gg, hh) else .getDelta(gg, hh, beta[j])
        dl <- max(-bnd[j], min(bnd[j], dl))
        del[i] <- dl
        bnd[j] <- max(2 * abs(dl) / alpha, bnd[j]/2, BFLOOR)
      }
      if (any(del != 0)) {
        beta[blk] <- beta[blk] + del
        for (k in seq_len(K)) {
          de <- as.vector(Xb[[k]][[bi]] %*% del); r <- which(de != 0)
          if (length(r)) { st[[k]]$eta[r] <- st[[k]]$eta[r] + de[r]
            pr <- 1/(1+exp(-st[[k]]$eta[r])); st[[k]]$p[r] <- pr; st[[k]]$w[r] <- pr*(1-pr) }
        }
      }
      if (!all(is.finite(beta))) return(list(beta=beta, diverged=TRUE, passes=pass, rounds=rounds))
    }
    rounds <- rounds + 1L                               # coordinate-0 convergence exchange
    ll <- 0; for (k in seq_len(K)) { e <- st[[k]]$eta; ll <- ll + sum(S[[k]]$y*e - log1p(exp(e))) }
    o <- ll - LAMBDA1*sum(abs(beta[-1L])) + (d-1)*log(LAMBDA1/2)
    if (trace && pass %% 10 == 0) cat(sprintf("   pass %4d obj %.6f\n", pass, o))
    if (!is.null(prev) && abs(o - prev)/(abs(o)+1) < tol) break
    prev <- o
  }
  list(beta = beta, diverged = FALSE, passes = passes, rounds = rounds + 1L)
}
