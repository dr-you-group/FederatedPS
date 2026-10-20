## Fixed prior variance (1) vs cross-validated variance for the sweep, consortium and hetero runs.
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
S <- FP_OUT
rdsw <- function(dir) { d <- do.call(rbind, lapply(list.files(file.path(S, dir), pattern = "_[0-9]+\\.csv$", full.names = TRUE), read.csv))
  w <- reshape(d[, c("study","size","rep","model","auc")], idvar = c("study","size","rep"), timevar = "model", direction = "wide")
  names(w) <- sub("^auc\\.", "", names(w)); w }
for (v in c("sweep", "sweep_cv")) { w <- rdsw(v); w$gain <- w$shared - w$local; w$extra <- w$shared - w$partner
  a <- aggregate(cbind(local, partner, shared, gain, extra) ~ size, data = w, FUN = mean)
  pos <- tapply(w$gain, w$size, function(g) sprintf("%d/%d", sum(g > 0), length(g)))
  cell <- aggregate(gain ~ study + size, data = w, FUN = mean); cpos <- sum(cell$gain > 0)
  cat(sprintf("\n== %s: mean AUC by size (cells with gain > 0: %d/%d) ==\n", v, cpos, nrow(cell)))
  a[, -1] <- round(a[, -1], 3); a$repsPos <- pos[as.character(a$size)]; print(a, row.names = FALSE) }
rdc <- function(dir) { d <- do.call(rbind, lapply(list.files(file.path(S, dir), pattern = "_n[0-9]+_[a-z]+\\.csv$", full.names = TRUE), read.csv))
  w <- reshape(d, idvar = c("study","K","n","src","rep"), timevar = "model", direction = "wide"); names(w) <- sub("^auc\\.", "", names(w)); w }
for (v in c("consortium", "consortium_cv")) { w <- rdc(v)
  a <- aggregate(cbind(local, others, shared, shlo = shared - local, shot = shared - others) ~ src + K, data = w, FUN = mean)
  a[, -(1:2)] <- round(a[, -(1:2)], 3); cat(sprintf("\n== %s ==\n", v)); print(a, row.names = FALSE) }
for (v in c("hetero", "hetero_cv")) { d <- do.call(rbind, lapply(list.files(file.path(S, v), pattern = "__(hetero|homo)\\.csv$", full.names = TRUE), read.csv))
  a <- aggregate(cbind(local, others, shared, shlo = shared - local, shot = shared - others) ~ mode, data = d, FUN = mean)
  a[, -1] <- round(a[, -1], 3); cat(sprintf("\n== %s ==\n", v)); print(a, row.names = FALSE) }
