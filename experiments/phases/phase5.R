## Phase 5: wall time under network latency, T = exchanges * latency + local compute.
source(file.path(Sys.getenv("FP_EXP", "experiments"), "common", "config.R"))
source(file.path(FP_EXP, "common/kit.R"))
p2 <- readRDS(file.path(FP_OUT, "phases/phase2.rds"))$tab          # mimic d = 9,812, K = 2
full <- data.frame(config = "full scale d=40,376 K=3 P=20 a=0.52",
                   R_loop = 90901, localSecs = 19.7, MB = 910)
sel <- p2[p2$P %in% c(1, 10, 20, 50), ]
sel <- sel[!(sel$P == 20 & sel$alpha != 0.52), ]
lat <- c(1, 5, 10, 50, 100) / 1000
rows <- list()
for (i in seq_len(nrow(sel))) {
  for (L in lat) {
    comm <- sel$R_loop[i] * L
    rows[[length(rows)+1L]] <- data.frame(
      problem = "mimic d=9,812 K=2", method = ifelse(sel$P[i] == 1, "exact CCD",
        sprintf("proximal block P=%d", sel$P[i])), P = sel$P[i], alpha = sel$alpha[i],
      latency_ms = L * 1000, exchanges = sel$R_loop[i], MB = sel$MB[i],
      commSecs = comm, localSecs = sel$localSecs[i], totalSecs = comm + sel$localSecs[i])
  }
}
tab <- do.call(rbind, rows); rownames(tab) <- NULL
## speed-up of each block configuration against exact CCD at the same latency
base <- tab[tab$P == 1, c("latency_ms", "totalSecs")]
tab$speedupVsExact <- base$totalSecs[match(tab$latency_ms, base$latency_ms)] / tab$totalSecs
write.csv(tab, file.path(FP_OUT, "phases/tables/phase5_network.csv"), row.names = FALSE)
cat("=== Phase 5: modelled wall clock vs per-round latency (mimic d=9,812, K=2) ===\n")
print(tab[, c("method","P","alpha","latency_ms","exchanges","MB","commSecs","localSecs","totalSecs","speedupVsExact")],
      row.names = FALSE, digits = 4)

## full-scale projection, anchored on the measured 9.19 ms/round
cat("\n=== full scale d=40,376 K=3 (measured: 90,901 exchanges, 9.19 ms/round, 835.0 s) ===\n")
fs <- data.frame(latency_ms = c(9.19, 1, 5, 10, 50, 100))
fs$exact_exchanges <- 1816966; fs$block_exchanges <- 90901
fs$exact_totalSecs <- fs$exact_exchanges * fs$latency_ms/1000 + 23.7
fs$block_totalSecs <- fs$block_exchanges * fs$latency_ms/1000 + 19.7
fs$speedup <- fs$exact_totalSecs / fs$block_totalSecs
fs$measured <- c("block run measured at 835.0 s", rep("", 5))
write.csv(fs, file.path(FP_OUT, "phases/tables/phase5_fullscale.csv"), row.names = FALSE)
print(fs, row.names = FALSE, digits = 5)
cat("\nBytes do NOT decrease: block packets carry 4P doubles, so bytes per pass are\n")
cat("roughly constant; the gain is in round count and therefore latency.\n")
