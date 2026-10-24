# Process-scoped startup profile set only by Launch-RStudio.ps1.
local({
    project <- Sys.getenv("FEDERATEDPS_PROJECT")
    helpers <- new.env(parent = globalenv())
    sys.source(file.path(project, "windows", "common.R"), envir = helpers)
    helpers$fp_verify_runtime(project)
    message("Windows offline project ready. Use Run-FederatedPS.ps1 to start concurrent roles.")
})
