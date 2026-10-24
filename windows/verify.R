args <- commandArgs(trailingOnly = TRUE)
stopifnot(length(args) == 1L)
source(file.path(args[1], "windows", "common.R"))
fp_verify_runtime(args[1])
