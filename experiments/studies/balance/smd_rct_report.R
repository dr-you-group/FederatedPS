## |SMD| > 0.1 counts with the within-pair randomisation reference. Cells: observed (reference).
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
setwd(FP_OUT)
ord <- c("ondansetron_promethazine","acetaminophen_ibuprofen","ondansetron_prochlorperazine","opioid","pantoprazole_lansoprazole","antiemetic","laxative","oxycodone_hydromorphone","class_ppi_h2ra","acid_suppression","ppi","morphine_hydromorphone")
cell <- function(o, e) ifelse(is.na(o), "—", sprintf("%.0f (%.0f)", o, e))
A <- do.call(rbind, lapply(list.files("smd_rct", "^expA_.*\\.csv$", full.names = TRUE), read.csv))
cat("== three large sites: |SMD|>0.1 observed (reference) for local / pooled / FL; mean |SMD| local / pooled / FL (reference)\n")
for (s in c("mimic","synpufA","synpufB")) { v <- A[A$site == s, ]
  w <- reshape(v[, c("study","model","gt01","gt01RCT","meanSMD","meanSMDRCT","pairs")], idvar = "study", timevar = "model", direction = "wide"); w <- w[match(ord, w$study), ]
  cat("\n--", s, "\n"); print(data.frame(study = w$study, pairs = w$pairs.local, local = cell(w$gt01.local, w$gt01RCT.local), pooled = cell(w$gt01.pooled, w$gt01RCT.pooled),
    FL = cell(w$gt01.fl_real, w$gt01RCT.fl_real), mean = sprintf("%.4f / %.4f / %.4f (%.4f)", w$meanSMD.local, w$meanSMD.pooled, w$meanSMD.fl_real, w$meanSMDRCT.local)), row.names = FALSE) }
B <- do.call(rbind, lapply(list.files("smd_rct", "__.*\\.csv$", full.names = TRUE), read.csv))
a <- aggregate(cbind(gt01, gt01RCT, excess01, meanSMD, meanSMDRCT, pairs) ~ study + setting + size + method, B, mean)
sw <- a[a$setting == "sweep", ]
cat("\n== large partner, by site size, mean over studies: |SMD|>0.1 observed (reference), excess\n")
g <- aggregate(cbind(gt01, gt01RCT, excess01, meanSMD, meanSMDRCT, pairs) ~ size + method, sw, mean)
g2 <- reshape(g, idvar = "size", timevar = "method", direction = "wide")
print(data.frame(size = g2$size, pairs = round(g2$pairs.local), local = cell(g2$gt01.local, g2$gt01RCT.local), pooled = cell(g2$gt01.pooled, g2$gt01RCT.pooled), transfer = cell(g2$gt01.transfer, g2$gt01RCT.transfer),
  excess = sprintf("%.0f / %.0f / %.0f", g2$excess01.local, g2$excess01.pooled, g2$excess01.transfer)), row.names = FALSE)
cat("\n   excess by study x size (local / pooled / transfer)\n")
w <- reshape(sw[, c("study","size","method","excess01")], idvar = c("study","size"), timevar = "method", direction = "wide")
w$txt <- sprintf("%.0f / %.0f / %.0f", w$excess01.local, w$excess01.pooled, w$excess01.transfer)
t <- reshape(w[, c("study","size","txt")], idvar = "study", timevar = "size", direction = "wide"); print(t[match(ord, t$study), ], row.names = FALSE)
cs <- a[a$setting != "sweep", ]
cat("\n== three 1,000-patient sites, mean over studies\n")
g <- aggregate(cbind(gt01, gt01RCT, excess01, pairs) ~ setting + method, cs, mean); g2 <- reshape(g, idvar = "setting", timevar = "method", direction = "wide")
print(data.frame(setting = g2$setting, pairs = round(g2$pairs.local), local = cell(g2$gt01.local, g2$gt01RCT.local), pooled = cell(g2$gt01.pooled, g2$gt01RCT.pooled), transfer = cell(g2$gt01.transfer, g2$gt01RCT.transfer),
  excess = sprintf("%.0f / %.0f / %.0f", g2$excess01.local, g2$excess01.pooled, g2$excess01.transfer)), row.names = FALSE)
cat("\n   excess by study x setting (local / pooled / transfer)\n")
w <- reshape(cs[, c("study","setting","method","excess01")], idvar = c("study","setting"), timevar = "method", direction = "wide")
w$txt <- sprintf("%.0f / %.0f / %.0f", w$excess01.local, w$excess01.pooled, w$excess01.transfer)
t <- reshape(w[, c("study","setting","txt")], idvar = "study", timevar = "setting", direction = "wide"); print(t[match(ord, t$study), ], row.names = FALSE)
