## Paths used by the experiment scripts. Override with environment variables.
##   FP_EXP       this directory (default: experiments, i.e. run from the repository root)
##   FP_DATA      extracted designs and other inputs
##   FP_OUT       results
##   FP_LIB       library path(s) holding the patched Cyclops, prepended to .libPaths()
##   FP_EXCHANGE  file-exchange directory for the multi-process federation tests
FP_EXP      <- Sys.getenv("FP_EXP", "experiments")
FP_DATA     <- Sys.getenv("FP_DATA", "data")
FP_OUT      <- Sys.getenv("FP_OUT", file.path(FP_DATA, "out"))
FP_LIB      <- Sys.getenv("FP_LIB", "")
FP_EXCHANGE <- Sys.getenv("FP_EXCHANGE", file.path(FP_OUT, "exchange"))
if (nzchar(FP_LIB)) .libPaths(c(strsplit(FP_LIB, .Platform$path.sep, fixed = TRUE)[[1]], .libPaths()))
for (d in c("logs", "sitedata", "fedruns", "predict", "validation", "phases/tables", "phases/figs", "statin3/tables", "statin3/figs"))
  dir.create(file.path(FP_OUT, d), recursive = TRUE, showWarnings = FALSE)
