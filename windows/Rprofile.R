# Process-scoped startup profile set only by Launch-RStudio.ps1.
local({
    project <- Sys.getenv("FEDERATEDPS_PROJECT")
    helpers <- new.env(parent = globalenv())
    sys.source(file.path(project, "windows", "common.R"), envir = helpers)
    helpers$fp_verify_runtime(project)
    message("Windows offline project ready. In the RStudio PowerShell Terminal, run:")
    message("  Set-Location -LiteralPath '", gsub("'", "''", project, fixed = TRUE), "'")
    message("  .\\windows\\Run-YUHS.ps1 -Test $false -Study ppi -Scenario default")
    message("Real YUHS requires HIWARE login and windows/config/yuhs.Renviron. Use -Test $true for the DB-free sample.")
    message("extras/CodeToRun.R and extras/ConnectionDetails.R are legacy PostgreSQL examples, not the Windows/YUHS entry point.")
})
