# Defaults for the shell runners; see common/config.R. Override any of them in the environment.
: "${FP_EXP:=experiments}"
: "${FP_DATA:=data}"
: "${FP_OUT:=$FP_DATA/out}"
: "${FP_LIB:=}"
: "${FP_EXCHANGE:=$FP_OUT/exchange}"
: "${RSCRIPT:=Rscript}"
: "${JOBS:=8}"
export FP_EXP FP_DATA FP_OUT FP_LIB FP_EXCHANGE RSCRIPT
mkdir -p "$FP_OUT/logs"
: "${STUDIES:=acetaminophen_ibuprofen acid_suppression antiemetic class_ppi_h2ra laxative
morphine_hydromorphone ondansetron_prochlorperazine ondansetron_promethazine opioid
oxycodone_hydromorphone pantoprazole_lansoprazole ppi}"
