## Relative RMSE of shared vs local and vs the partner/others model, with study-level cluster
## bootstrap 95% intervals (null scenario), for fixed and CV-tuned prior variances.
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
S <- FP_OUT; DEG <- "ondansetron_promethazine"; set.seed(1); B <- 2000
rd <- function(dir, pat) { d <- do.call(rbind, lapply(list.files(file.path(S, dir), pattern = pat, full.names = TRUE), read.csv))
  d$err <- d$logHR - d$truth; d$ok <- is.finite(d$logHR) & is.finite(d$se) & d$se < 10 & abs(d$logHR) < 10
  d[d$study != DEG & d$scenario == "null", ] }
pairdiff <- function(d, grp, a, b) {   # rows where both methods gave an estimate
  k <- c("study", grp, "rep", "draw")
  A <- d[d$method == a & d$ok, c(k, "err")]; Bm <- d[d$method == b & d$ok, c(k, "err")]
  m <- merge(A, Bm, by = k, suffixes = c(".a", ".b")); m$g <- m[[grp]]; m }
ci <- function(m) { st <- unique(m$study); by <- split(m, m$study)
  rel <- function(x) sqrt(mean(x$err.a^2)) / sqrt(mean(x$err.b^2)) - 1
  bs <- replicate(B, rel(do.call(rbind, by[sample(st, replace = TRUE)])))
  sprintf("%+5.1f%% [%+5.1f, %+5.1f]", 100*rel(m), 100*quantile(bs, .025), 100*quantile(bs, .975)) }
run <- function(dir, pat, grp, a, b, lab) { d <- rd(dir, pat); m <- pairdiff(d, grp, a, b)
  cat(sprintf("\n%s: RMSE(%s)/RMSE(%s) − 1, 95%% CI\n", lab, a, b))
  for (g in sort(unique(m$g))) cat(sprintf("  %-8s %s\n", g, ci(m[m$g == g, ]))) }
for (v in list(c("plasmode", "fixed"), c("plasmode_cv", "CV"))) {
  run(v[1], "_[0-9]+\\.csv$", "size", "shared", "local", paste("size sweep,", v[2]))
  run(v[1], "_[0-9]+\\.csv$", "size", "shared", "partner", paste("size sweep,", v[2])) }
for (v in list(c("plasmode_cons", "fixed"), c("plasmode_cons_cv", "CV"))) {
  run(v[1], "__[a-z]+\\.csv$", "setting", "shared", "local", paste("small consortia,", v[2]))
  run(v[1], "__[a-z]+\\.csv$", "setting", "shared", "others", paste("small consortia,", v[2])) }
