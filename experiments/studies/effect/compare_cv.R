## Fixed prior variance (1) vs CV-tuned variance in the plasmode runs (null scenario).
## |logHR| >= 10 (monotone likelihood with few matched pairs) is treated as not estimable.
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
S <- FP_OUT; DEG <- "ondansetron_promethazine"
rd <- function(dir, pat) { fs <- list.files(file.path(S, dir), pattern = pat, full.names = TRUE)
  d <- do.call(rbind, lapply(fs, read.csv)); d$err <- d$logHR - d$truth
  d$ok <- is.finite(d$logHR) & is.finite(d$se) & d$se < 10 & abs(d$logHR) < 10; d$cov <- abs(d$err) <= 1.96*d$se; d }
summ <- function(d, grp, meths) { d <- d[d$study != DEG & d$scenario == "null", ]
  key <- do.call(paste, d[, c("study", grp, "rep", "draw")])
  ok3 <- tapply(d$ok & d$method %in% meths, key, sum) == length(meths); d <- d[ok3[key] & d$method %in% meths, ]
  a <- aggregate(cbind(bias = err, RMSE = err^2, coverage = cov) ~ g + method, data = transform(d, g = d[[grp]]), FUN = mean)
  a$RMSE <- sqrt(a$RMSE)
  m <- aggregate(MAE50 ~ g + method, data = transform(d, g = d[[grp]], MAE50 = abs(err)), FUN = median)
  merge(a, m, by = c("g","method")) }
both <- function(dirF, dirC, pat, grp, meths) {
  A <- summ(rd(dirF, pat), grp, meths); A$prior <- "fixed1"
  B <- summ(rd(dirC, pat), grp, meths); B$prior <- "cv"
  r <- rbind(A, B); r[, c("bias","RMSE","MAE50","coverage")] <- round(r[, c("bias","RMSE","MAE50","coverage")], 3)
  r[order(r$g, r$method, r$prior), c("g","method","prior","bias","RMSE","MAE50","coverage")] }
cat("===== size sweep, large partner, null =====\n")
print(both("plasmode", "plasmode_cv", "_[0-9]+\\.csv$", "size", c("local","partner","shared")), row.names = FALSE)
cat("\n===== small consortia, null =====\n")
print(both("plasmode_cons", "plasmode_cons_cv", "__[a-z]+\\.csv$", "setting", c("local","others","shared")), row.names = FALSE)
## cell-level comparisons, CV-tuned runs
cell <- function(dir, pat, grp, a, b) { d <- rd(dir, pat); d <- d[d$study != DEG & d$scenario == "null" & d$ok, ]
  r <- aggregate(err ~ study + g + method, data = transform(d, g = d[[grp]]), FUN = function(e) sqrt(mean(e^2)))
  w <- reshape(r, idvar = c("study","g"), timevar = "method", direction = "wide"); names(w) <- sub("^err\\.", "", names(w))
  tapply(w[[a]] < w[[b]], w$g, function(v) sprintf("%d/%d", sum(v, na.rm=TRUE), sum(!is.na(v)))) }
cat("\ncells with RMSE(shared) < RMSE(local):\n"); print(cell("plasmode_cv", "_[0-9]+\\.csv$", "size", "shared", "local"))
print(cell("plasmode_cons_cv", "__[a-z]+\\.csv$", "setting", "shared", "local"))
cat("\ncells with RMSE(shared) < RMSE(partner):\n"); print(cell("plasmode_cv", "_[0-9]+\\.csv$", "size", "shared", "partner"))
print(cell("plasmode_cons_cv", "__[a-z]+\\.csv$", "setting", "shared", "others"))
