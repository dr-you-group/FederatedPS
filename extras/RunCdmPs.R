# Explicit, private CDM experiment. Never run this driver from a unit test.
# Rscript --vanilla RunCdmPs.R <private-directory> <extract|verify|reference|train|report> <code-directory>
args <- commandArgs(trailingOnly = TRUE)
stopifnot(length(args) == 3L)
private <- normalizePath(args[[1L]], mustWork = TRUE)
stage <- match.arg(args[[2L]], c("extract", "verify", "reference", "train", "report"))
code <- normalizePath(args[[3L]], mustWork = TRUE)
stopifnot(grepl("^(/tmp/federatedps-real-private/|/opt/federatedps/private/)", private),
    as.character(file.info(private)$mode) == "700")
Sys.umask("0077")
public <- file("/proc/self/fd/1", open = "w", raw = TRUE)
log <- file(file.path(private, paste0(stage, "-execution.log")), open = "a")
sink(log); sink(log, type = "message")
settings <- list(seed = 20260907L, sampleLimit = 1500L, minFraction = 0.001,
    priorVariance = 1, extractionSeconds = 7200, fitSeconds = 3600,
    remoteSeconds = 129600, totalSeconds = 172800,
    control = list(convergenceType = "lange", tolerance = 1e-12,
        maxIterations = 500L, threads = 1L, noiseLevel = "silent"),
    matching = list(maxRatio = 1, caliper = 0.2, caliperScale = "standardized logit"))
sites <- c(site1 = "mimiciv", site2 = "synpuf23")
started <- proc.time()[["elapsed"]]
currentStep <- "initialization"
execution <- list()
record <- function(step, status, seconds = 0) {
    execution[[length(execution) + 1L]] <<- data.frame(stage = stage, step = step,
        status = status, seconds = seconds, disclosure = "withheld_pending_policy")
    utils::write.csv(do.call(rbind, execution), file.path(private, paste0(stage, "-status.csv")), row.names = FALSE)
    cat(stage, step, status, sprintf("%.3f seconds", seconds), "\n", file = public)
    flush(public)
}
savePrivate <- function(value, name) {
    saveRDS(value, file.path(private, name))
    Sys.chmod(file.path(private, name), "0600")
}
exactNumeric <- function(x) {
    if (inherits(x, "integer64")) {
        text <- as.character(x)
        x <- as.numeric(x)
        stopifnot(all(is.na(text) | (is.finite(x) & abs(x) <= 2^53 - 1 & sprintf("%.0f", x) == text)))
    }
    x
}

# FE's documented custom-builder contract. The research projection contains
# point-record histories, filtered BEFORE aggregation, never modified CDM rows.
# Age/gender still use FE's ordinary builder directly on the source CDM.
getDbPsHistoryCovariateData <- function(connection, tempEmulationSchema = NULL,
    cdmDatabaseSchema, cdmVersion, cohortTable, cohortIds, rowIdField, covariateSettings,
    targetCovariateTable = NULL, targetCovariateContinuousTable = NULL,
    targetCovariateRefTable = NULL, targetAnalysisRefTable = NULL, targetTimeRefTable = NULL,
    aggregated = FALSE, minCharacterizationMean = 0, minCharacterizationCount = 0) {
    stopifnot(!aggregated, is.null(targetCovariateTable),
        cdmDatabaseSchema %in% unname(sites),
        identical(covariateSettings$projection, paste0("fps_", cdmDatabaseSchema)))
    projection <- covariateSettings$projection
    # Each event is represented as a point at its original source start date.
    # FE's default interval-overlap SQL consequently implements start-in-window
    # for BOTH [-90,-1] and [-30,-1], without clipping or imputing source dates.
    views <- c(condition_occurrence = "SELECT person_id,condition_concept_id,condition_start_date,condition_start_date AS condition_end_date FROM %s.condition_records",
        drug_exposure = "SELECT person_id,drug_concept_id,drug_exposure_start_date,drug_exposure_start_date AS drug_exposure_end_date FROM %s.drug_records",
        procedure_occurrence = "SELECT person_id,procedure_concept_id,procedure_date FROM %s.procedure_records")
    for (name in names(views)) DatabaseConnector::executeSql(connection,
        paste0("CREATE TEMP VIEW ", name, " AS ", sprintf(views[[name]], projection)),
        progressBar = FALSE, reportOverallTime = FALSE)
    DatabaseConnector::executeSql(connection,
        paste0("CREATE TEMP VIEW concept AS SELECT * FROM ", cdmDatabaseSchema, ".concept"),
        progressBar = FALSE, reportOverallTime = FALSE)
    on.exit(DatabaseConnector::executeSql(connection,
        "DROP VIEW pg_temp.condition_occurrence; DROP VIEW pg_temp.drug_exposure; DROP VIEW pg_temp.procedure_occurrence; DROP VIEW pg_temp.concept;",
        progressBar = FALSE, reportOverallTime = FALSE), add = TRUE)
    FeatureExtraction::getDbDefaultCovariateData(connection = connection,
        cdmDatabaseSchema = "pg_temp", cohortTable = cohortTable, cohortIds = cohortIds,
        rowIdField = rowIdField, cdmVersion = cdmVersion,
        covariateSettings = covariateSettings$default, aggregated = FALSE)
}

runExtraction <- function() {
    stopifnot(as.character(utils::packageVersion("FeatureExtraction")) == "3.14.0",
        all(nzchar(Sys.getenv(c("PGHOST", "PGPORT", "PGDATABASE", "PGUSER", "PGPASSWORD")))),
        Sys.getenv("PGDATABASE") == "ohdsi")
    lines <- readLines(file.path(code, "extras/sql/CohortFeasibility.sql"))
    markers <- which(startsWith(lines, "-- @step "))
    statements <- setNames(lapply(seq_along(markers), function(i) {
        end <- if (i < length(markers)) markers[[i + 1L]] - 1L else length(lines)
        paste(lines[seq.int(markers[[i]] + 1L, end)], collapse = "\n")
    }), sub("-- @step ", "", lines[markers], fixed = TRUE))
    products <- utils::read.csv(file.path(code, "metadata/product-definitions.csv"), stringsAsFactors = FALSE)
    vocabulary <- utils::read.csv(file.path(code, "metadata/vocabulary-metadata.csv"), stringsAsFactors = FALSE)
    canonical <- function(x) {
        x[] <- lapply(x, as.character)
        x <- x[do.call(order, x), , drop = FALSE]; rownames(x) <- NULL; x
    }
    allInputs <- list(); summaries <- list(); coverage <- list()
    for (name in names(sites)) {
        schema <- sites[[name]]; analysis <- paste0("fps_", schema)
        cachedPath <- file.path(private, paste0(name, "-cohort.rds"))
        if (file.exists(cachedPath)) {
            cached <- readRDS(cachedPath)
            stopifnot(identical(cached$settings, settings), identical(cached$sqlHash,
                unname(tools::md5sum(file.path(code, "extras/sql/CohortFeasibility.sql")))))
            check <- DBI::dbConnect(RPostgres::Postgres(), host = Sys.getenv("PGHOST"),
                port = as.integer(Sys.getenv("PGPORT")), dbname = Sys.getenv("PGDATABASE"),
                user = Sys.getenv("PGUSER"), password = Sys.getenv("PGPASSWORD"),
                options = "-c default_transaction_read_only=on -c statement_timeout=30000")
            mapped <- DBI::dbGetQuery(check, paste0("SELECT row_id,subject_id,cohort_start_date,cohort_definition_id FROM ", analysis, ".cohort ORDER BY row_id"))
            DBI::dbDisconnect(check)
            mapped$subject_id <- as.character(mapped$subject_id)
            mapped[] <- lapply(mapped, exactNumeric)
            stopifnot(identical(mapped, cached$input$mapping))
            allInputs[[name]] <- cached$input
            summaries[[name]] <- cached$summary
            coverage[[name]] <- cached$coverage
            record(paste0(name, "/cohort_reuse"), "identity_verified")
            next
        }
        connection <- DBI::dbConnect(RPostgres::Postgres(), host = Sys.getenv("PGHOST"),
            port = as.integer(Sys.getenv("PGPORT")), dbname = Sys.getenv("PGDATABASE"),
            user = Sys.getenv("PGUSER"), password = Sys.getenv("PGPASSWORD"),
            options = "-c statement_timeout=600000 -c lock_timeout=5000")
        on.exit(if (DBI::dbIsValid(connection)) DBI::dbDisconnect(connection), add = TRUE)
        DBI::dbBegin(connection)
        DBI::dbExecute(connection, "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ WRITE")
        query <- function(step, sql, fetch = FALSE, seconds = 600) {
            currentStep <<- paste(name, step, sep = "/")
            remaining <- settings$extractionSeconds - (proc.time()[["elapsed"]] - started)
            if (remaining <= 0) stop("extraction_budget_exhausted")
            DBI::dbExecute(connection, paste0("SET LOCAL statement_timeout=", floor(1000 * min(seconds, remaining))))
            begin <- proc.time()[["elapsed"]]
            value <- if (fetch) DBI::dbGetQuery(connection, sql) else invisible(DBI::dbExecute(connection, sql))
            record(currentStep, "completed", proc.time()[["elapsed"]] - begin)
            value
        }
        ownership <- query("schema_ownership", paste0("SELECT nspowner=current_user::regrole AS owned FROM pg_namespace WHERE nspname='", analysis, "'"), TRUE, 30)
        # Existing objects are never silently reused or overwritten.
        if (nrow(ownership)) stop("analysis_schema_already_exists_review_required")
        query("create_research_schema", paste("CREATE SCHEMA", analysis))
        access <- query("private_schema_acl", paste0("SELECT NOT EXISTS (SELECT 1 FROM pg_namespace n,",
            "LATERAL aclexplode(coalesce(n.nspacl,acldefault('n',n.nspowner))) a ",
            "WHERE n.nspname='", analysis, "' AND a.grantee<>n.nspowner) AS private"), TRUE, 30)
        stopifnot(isTRUE(access$private))
        current <- query("vocabulary_identity", paste0("SELECT vocabulary_id,vocabulary_name,vocabulary_reference,vocabulary_version FROM ", schema,
            ".vocabulary WHERE vocabulary_id IN ('None','RxNorm','RxNorm Extension','SNOMED','Type Concept') ORDER BY vocabulary_id"), TRUE, 30)
        stopifnot(identical(canonical(current), canonical(vocabulary[vocabulary$site == schema, names(current)])))
        definition <- products[products$site == schema, ]
        current <- query("product_identity", paste0("SELECT DISTINCT a.ancestor_concept_id AS study_ingredient_id,c.concept_id,c.concept_name,c.concept_class_id,c.vocabulary_id,c.concept_code FROM ",
            schema, ".concept_ancestor a JOIN ", schema, ".concept c ON c.concept_id=a.descendant_concept_id WHERE a.ancestor_concept_id IN (1545958,1539403) AND c.standard_concept='S' AND c.domain_id='Drug' AND c.invalid_reason IS NULL ORDER BY study_ingredient_id,concept_id"), TRUE, 30)
        stopifnot(identical(canonical(current), canonical(definition[names(current)])),
            !anyDuplicated(definition[c("concept_id", "study_ingredient_id")]))
        values <- paste(sprintf("(%d,%d,%s)", definition$concept_id, definition$study_ingredient_id,
            ifelse(!is.na(definition$single_ingredient) & definition$single_ingredient, "TRUE", "FALSE")), collapse = ",")
        query("definitions", paste0("CREATE TEMP TABLE e1_definitions ON COMMIT DROP AS SELECT * FROM (VALUES ", values, ") v(drug_concept_id,ingredient_id,single_ingredient)"))
        query("definitions_key", "CREATE UNIQUE INDEX ON pg_temp.e1_definitions(drug_concept_id,ingredient_id)")
        query("definitions_statistics", "ANALYZE pg_temp.e1_definitions")
        for (step in c("exposures", "first", "age", "visits", "cohort", "final")) {
            sql <- SqlRender::render(statements[[step]], cdm_schema = schema)
            query(step, paste0("CREATE TEMP TABLE e1_", step, " ON COMMIT DROP AS ", sql))
            if (step != "exposures") query(paste0(step, "_key"), paste0("CREATE UNIQUE INDEX ON pg_temp.e1_", step, "(person_id)"))
            query(paste0(step, "_statistics"), paste0("ANALYZE pg_temp.e1_", step))
        }
        attrition <- query("attrition", statements$attrition, TRUE)
        stopifnot(all(as.numeric(attrition$value[attrition$section == "validation"]) == 0))
        final <- attrition[attrition$metric == "06_baseline_visit_final", ]
        stopifnot(setequal(final$ingredient_id, c(1545958, 1539403)), all(as.numeric(final$value) > 0))
        query("full_cohort", paste0("CREATE TABLE ", analysis, ".cohort_full AS SELECT person_id AS subject_id,index_date AS cohort_start_date,index_date AS cohort_end_date,CASE ingredient_id WHEN 1545958 THEN 1 ELSE 2 END AS cohort_definition_id,age,complete_birth FROM pg_temp.e1_final"))
        query("full_cohort_key", paste0("CREATE UNIQUE INDEX ON ", analysis, ".cohort_full(subject_id)"))
        # Proportional largest-remainder allocation, retaining both groups when
        # possible. The MD5 ordering is a fixed site-local seeded draw, not PS jitter.
        sampleSql <- paste0("WITH sizes AS (SELECT cohort_definition_id,count(*) AS n FROM ", analysis, ".cohort_full GROUP BY 1), totals AS (SELECT *,sum(n) OVER () AS total FROM sizes), quota AS (SELECT *,least(total,1500)::bigint AS wanted FROM totals), allocation AS (SELECT *,CASE WHEN total<=1500 THEN n WHEN cohort_definition_id=1 THEN greatest(1,least(1499,round(1500*n/total))) ELSE 1500-(SELECT greatest(1,least(1499,round(1500*n/total))) FROM quota WHERE cohort_definition_id=1) END AS take FROM quota), ranked AS (SELECT c.*,row_number() OVER (PARTITION BY c.cohort_definition_id ORDER BY md5(c.subject_id::text||':20260907'),c.subject_id) AS draw FROM ", analysis, ".cohort_full c) SELECT row_number() OVER (ORDER BY r.subject_id)::bigint AS row_id,r.subject_id,r.cohort_start_date,r.cohort_end_date,r.cohort_definition_id FROM ranked r JOIN allocation a USING(cohort_definition_id) WHERE r.draw<=a.take")
        query("analysis_sample", paste0("CREATE TABLE ", analysis, ".cohort AS ", sampleSql))
        query("sample_person_key", paste0("CREATE UNIQUE INDEX ON ", analysis, ".cohort(subject_id)"))
        query("sample_row_key", paste0("CREATE UNIQUE INDEX ON ", analysis, ".cohort(row_id)"))
        query("sample_statistics", paste0("ANALYZE ", analysis, ".cohort"))
        population <- query("population", paste0("SELECT row_id,subject_id,cohort_start_date,cohort_definition_id FROM ", analysis, ".cohort ORDER BY row_id"), TRUE)
        stopifnot(nrow(population) <= settings$sampleLimit, !anyDuplicated(population$subject_id), length(unique(population$cohort_definition_id)) == 2L)
        domains <- list(condition = c("condition_occurrence", "condition_start_date", "condition_start_datetime", "condition_concept_id"),
            drug = c("drug_exposure", "drug_exposure_start_date", "drug_exposure_start_datetime", "drug_concept_id"),
            procedure = c("procedure_occurrence", "procedure_date", "procedure_datetime", "procedure_concept_id"))
        domainSummary <- list(); collection <- logical()
        for (domain in names(domains)) {
            d <- domains[[domain]]
            collection[[domain]] <- query(paste0(domain, "_coverage"), paste0("SELECT EXISTS (SELECT 1 FROM ", schema, ".", d[[1L]], ") AS collected"), TRUE, 30)$collected
            # Preserve the raw date and visit evidence in the protected research
            # table. No original CDM record is changed by this SELECT projection.
            visit <- "v.visit_occurrence_id IS NOT NULL AND v.person_id=d.person_id AND isfinite(v.visit_start_date) AND isfinite(v.visit_end_date) AND v.visit_start_date<=v.visit_end_date AND v.visit_end_date<c.cohort_start_date"
            if (domain == "drug") visit <- paste0("(d.visit_occurrence_id IS NULL OR (", visit, "))")
            eligible <- paste0("d.", d[[2L]], " BETWEEN c.cohort_start_date-90 AND c.cohort_start_date-1 AND isfinite(d.", d[[2L]], ") AND (d.", d[[3L]], " IS NULL OR (isfinite(d.", d[[3L]], ") AND d.", d[[3L]], "::date=d.", d[[2L]], ")) AND (", visit, ") AND EXISTS (SELECT 1 FROM ", schema, ".concept t WHERE t.concept_id=d.", d[[4L]], " AND t.standard_concept='S' AND t.invalid_reason IS NULL)")
            if (domain == "drug") eligible <- paste0(eligible, " AND NOT EXISTS (SELECT 1 FROM pg_temp.e1_definitions m WHERE m.drug_concept_id=d.drug_concept_id)")
            query(paste0(domain, "_records"), paste0("CREATE TABLE ", analysis, ".", domain, "_records AS SELECT d.*,c.row_id AS analysis_row_id,c.cohort_start_date AS analysis_index_date FROM ", analysis, ".cohort c JOIN ", schema, ".", d[[1L]], " d ON d.person_id=c.subject_id LEFT JOIN ", schema, ".visit_occurrence v ON v.visit_occurrence_id=d.visit_occurrence_id WHERE ", eligible), seconds = 1800)
            query(paste0(domain, "_records_index"), paste0("CREATE INDEX ON ", analysis, ".", domain, "_records(person_id)"))
            query(paste0(domain, "_records_statistics"), paste0("ANALYZE ", analysis, ".", domain, "_records"))
            domainSummary[[domain]] <- query(paste0(domain, "_retained_summary"), paste0("SELECT count(*) AS records,count(DISTINCT person_id) AS persons FROM ", analysis, ".", domain, "_records"), TRUE)
        }
        access <- query("research_table_acl", paste0("SELECT NOT EXISTS(SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace,LATERAL aclexplode(coalesce(c.relacl,acldefault('r',c.relowner))) a WHERE n.nspname='", analysis, "' AND a.grantee<>c.relowner) AS private"), TRUE, 30)
        stopifnot(isTRUE(access$private))
        DBI::dbCommit(connection)
        DBI::dbDisconnect(connection)
        coverage[[name]] <- collection
        summaries[[name]] <- list(attrition = attrition, sample = table(population$cohort_definition_id), domains = domainSummary)
        # OMOP person IDs can exceed float64's exact integer range. The source
        # identifier remains character; explicit local row IDs are exact and map
        # one-to-one to persons. No identifier is rounded or used as a predictor.
        population$subject_id <- as.character(population$subject_id)
        population[] <- lapply(population, exactNumeric)
        allInputs[[name]] <- list(population = data.frame(rowId = population$row_id,
            treatment = as.numeric(population$cohort_definition_id == 1),
            personSeqId = population$row_id, personId = population$subject_id),
            mapping = population, sourceSchema = schema)
        savePrivate(list(input = allInputs[[name]], summary = summaries[[name]], coverage = collection,
            settings = settings, sqlHash = unname(tools::md5sum(file.path(code, "extras/sql/CohortFeasibility.sql")))), paste0(name, "-cohort.rds"))
        savePrivate(list(settings = settings, sites = summaries, coverage = coverage), "cohort-summary.rds")
    }
    commonDomains <- names(which(Reduce(`&`, coverage)))
    savePrivate(list(coverage = coverage, retained = commonDomains,
        limitation = "A populated ETL domain is evidence of collection, not complete observation; absent/unknown domains excluded jointly."), "domain-coverage.rds")
    for (name in names(sites)) {
        schema <- sites[[name]]
        currentStep <<- paste0(name, "/FeatureExtraction")
        begin <- proc.time()[["elapsed"]]
        jdbc <- DatabaseConnector::connect(dbms = "postgresql", server = paste0(Sys.getenv("PGHOST"), "/", Sys.getenv("PGDATABASE")),
            port = Sys.getenv("PGPORT"), user = Sys.getenv("PGUSER"), password = Sys.getenv("PGPASSWORD"), pathToDriver = "/opt/federatedps-drivers")
        on.exit(try(DatabaseConnector::disconnect(jdbc), silent = TRUE), add = TRUE)
        remaining <- settings$extractionSeconds - (proc.time()[["elapsed"]] - started)
        stopifnot(remaining > 0)
        DatabaseConnector::executeSql(jdbc, paste0("SET statement_timeout=", floor(1000 * min(1800, remaining)), "; SET lock_timeout=5000;"), progressBar = FALSE)
        demo <- FeatureExtraction::createCovariateSettings(useDemographicsAge = TRUE, useDemographicsGender = TRUE)
        history <- FeatureExtraction::createCovariateSettings(
            useConditionOccurrenceLongTerm = "condition" %in% commonDomains,
            useConditionOccurrenceShortTerm = "condition" %in% commonDomains,
            useDrugExposureLongTerm = "drug" %in% commonDomains,
            useDrugExposureShortTerm = "drug" %in% commonDomains,
            useProcedureOccurrenceLongTerm = "procedure" %in% commonDomains,
            useProcedureOccurrenceShortTerm = "procedure" %in% commonDomains,
            longTermStartDays = -90, shortTermStartDays = -30, endDays = -1)
        custom <- structure(list(default = history, projection = paste0("fps_", schema)),
            class = "covariateSettings", fun = "getDbPsHistoryCovariateData")
        cov <- FeatureExtraction::getDbCovariateData(connection = jdbc, cdmDatabaseSchema = schema,
            cohortDatabaseSchema = paste0("fps_", schema), cohortTable = "cohort", cohortIds = c(1, 2),
            rowIdField = "row_id", covariateSettings = list(demo, custom), aggregated = FALSE)
        pieces <- list()
        Andromeda::batchApply(cov$covariates, function(batch) {
            pieces[[length(pieces) + 1L]] <<- as.data.frame(batch[c("rowId", "covariateId", "covariateValue")])
        }, batchSize = 100000L)
        long <- do.call(rbind, pieces); long[] <- lapply(long, exactNumeric)
        ref <- as.data.frame(dplyr::collect(cov$covariateRef)); ref[] <- lapply(ref, exactNumeric)
        analysis <- as.data.frame(dplyr::collect(cov$analysisRef)); analysis[] <- lapply(analysis, exactNumeric)
        stopifnot(!anyDuplicated(long[c("rowId", "covariateId")]), all(is.finite(long$covariateValue)),
            all(long$covariateValue >= 0), all(long$rowId %in% allInputs[[name]]$population$rowId))
        meta <- analysis[match(ref$analysisId, analysis$analysisId), ]
        ref$timeWindow <- ifelse(is.na(meta$startDay), "index", paste0("[", meta$startDay, ",", meta$endDay, "]"))
        ref$valueType <- ifelse(meta$isBinary == "Y", "binary", "continuous")
        ref$isCollected <- TRUE
        allInputs[[name]]$covariates <- long
        allInputs[[name]]$covariateRef <- ref
        allInputs[[name]]$analysisRef <- analysis[c("analysisId", "analysisName", "domainId", "isBinary", "missingMeansZero")]
        allInputs[[name]]$metadata <- list(dataMode = "cdm", featureExtractionVersion = "3.14.0",
            analysisRef = analysis, settings = list(demo = demo, history = history),
            historyRule = "source start in window; valid linked visit ends before index; unlinked drug dates allowed; no study drugs")
        Andromeda::close(cov)
        DatabaseConnector::disconnect(jdbc)
        record(currentStep, "completed", proc.time()[["elapsed"]] - begin)
        savePrivate(allInputs[[name]], paste0(name, "-extracted.rds"))
    }
    # Only candidate definitions cross sites here; this protected evaluator is
    # expressly separate from the later summary-only learning coordinator.
    refs <- do.call(rbind, lapply(allInputs, function(x) x$covariateRef))
    uniqueRef <- unique(refs)
    stopifnot(!anyDuplicated(uniqueRef$covariateId))
    uniqueRef <- uniqueRef[order(uniqueRef$covariateId), ]; rownames(uniqueRef) <- NULL
    analyses <- unique(do.call(rbind, lapply(allInputs, function(x) x$analysisRef)))
    stopifnot(!anyDuplicated(analyses$analysisId))
    analyses <- analyses[order(analyses$analysisId), ]; rownames(analyses) <- NULL
    for (name in names(allInputs)) {
        site <- allInputs[[name]]
        site$covariateRef <- uniqueRef; site$analysisRef <- analyses
        input <- list(synthetic = FALSE, dataMode = "cdm", name = name, site = site,
            covariateIds = uniqueRef$covariateId, excludedIds = numeric(),
            scales = stats::setNames(rep(1, nrow(uniqueRef)), as.character(uniqueRef$covariateId)),
            settings = list(priorVariance = settings$priorVariance, control = settings$control,
                startingCoefficients = stats::setNames(rep(0, nrow(uniqueRef) + 1L), c("(Intercept)", as.character(uniqueRef$covariateId)))))
        savePrivate(input, paste0(name, "-input.rds"))
    }
    savePrivate(settings, "settings.rds")
    record("cohort_feature_input", "completed", proc.time()[["elapsed"]] - started)
}

verifyExtraction <- function() {
    for (name in names(sites)) {
        currentStep <<- paste0(name, "/extraction_validation")
        input <- readRDS(file.path(private, paste0(name, "-input.rds")))
        connection <- DBI::dbConnect(RPostgres::Postgres(), host = Sys.getenv("PGHOST"),
            port = as.integer(Sys.getenv("PGPORT")), dbname = Sys.getenv("PGDATABASE"),
            user = Sys.getenv("PGUSER"), password = Sys.getenv("PGPASSWORD"),
            options = "-c default_transaction_read_only=on -c statement_timeout=600000")
        DBI::dbBegin(connection)
        DBI::dbExecute(connection, "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY")
        schema <- paste0("fps_", sites[[name]])
        analyses <- input$site$metadata$analysisRef
        checks <- list()
        for (i in seq_len(nrow(analyses))) {
            a <- analyses[i, ]
            if (!a$domainId %in% c("Condition", "Drug", "Procedure")) next
            domain <- tolower(a$domainId)
            column <- switch(domain, condition = "condition_start_date", drug = "drug_exposure_start_date", procedure = "procedure_date")
            concept <- switch(domain, condition = "condition_concept_id", drug = "drug_concept_id", procedure = "procedure_concept_id")
            expected <- DBI::dbGetQuery(connection, paste0("SELECT DISTINCT analysis_row_id AS row_id,", concept,
                "::bigint*1000+", a$analysisId, " AS covariate_id,1::double precision AS covariate_value FROM ", schema, ".", domain,
                "_records WHERE ", column, " BETWEEN analysis_index_date+(", a$startDay, ") AND analysis_index_date+(", a$endDay, ")"))
            expected[] <- lapply(expected, exactNumeric)
            names(expected) <- c("rowId", "covariateId", "covariateValue")
            actual <- input$site$covariates[input$site$covariates$covariateId %in%
                input$site$covariateRef$covariateId[input$site$covariateRef$analysisId == a$analysisId], ]
            orderTriplets <- function(x) {
                x[] <- lapply(x, as.numeric)
                x <- x[order(x$rowId, x$covariateId), ]; rownames(x) <- NULL; x
            }
            stopifnot(identical(orderTriplets(actual), orderTriplets(expected)))
            checks[[as.character(a$analysisId)]] <- "exact_history_match"
        }
        stopifnot(length(checks) > 0L,
            !anyDuplicated(input$site$population$personId),
            !anyDuplicated(input$site$population$rowId))
        DBI::dbRollback(connection); DBI::dbDisconnect(connection)
        savePrivate(checks, paste0(name, "-extraction-validation.rds"))
        record(currentStep, "passed")
    }
}

runReference <- function() {
    .libPaths(c("/opt/federatedps/corrected-reference-library", .libPaths()))
    stopifnot(find.package("Cyclops") == "/opt/federatedps/corrected-reference-library/Cyclops",
        !"initializeCyclopsCoordinateDescent" %in% getNamespaceExports("Cyclops"))
    inputs <- lapply(names(sites), function(name) readRDS(file.path(private, paste0(name, "-input.rds"))))
    names(inputs) <- names(sites)
    prepared <- lapply(inputs, FederatedPs::preparePsCvDS, folds = 0L, seed = settings$seed)
    on.exit(for (x in prepared) Andromeda::close(x$raw$cohortMethodData), add = TRUE)
    results <- list()
    for (method in c(names(sites), "pooled")) {
        currentStep <<- paste0(method, "/corrected_reference")
        namesToUse <- if (method == "pooled") names(sites) else method
        raw <- do.call(rbind, lapply(namesToUse, function(name) {
            x <- prepared[[name]]$raw$x
            rownames(x) <- paste0(nchar(name), ":", name, ":", rownames(x)); x
        }))
        y <- unlist(lapply(prepared[namesToUse], function(x) unname(x$raw$y)), use.names = FALSE)
        names(y) <- rownames(raw)
        # Independent pooled/local oracle: recompute from this method's raw
        # rows, without worker summaries or the coordinator's chosen mask.
        counts <- Matrix::colSums(raw != 0)
        maximum <- stats::setNames(vapply(seq_len(ncol(raw)), function(j) {
            from <- raw@p[j] + 1L; to <- raw@p[j + 1L]
            if (from > to) 0 else max(0, raw@x[from:to])
        }, 0.0), colnames(raw))
        keep <- counts > 0 & counts / nrow(raw) >= settings$minFraction
        stopifnot(any(keep))
        scales <- maximum[keep]
        x <- raw[, keep, drop = FALSE] %*% Matrix::Diagonal(x = 1 / scales)
        dimnames(x) <- list(rownames(raw), names(scales))
        initial <- stats::setNames(rep(0, ncol(x) + 1L), c("(Intercept)", colnames(x)))
        data <- Cyclops::createCyclopsData(y ~ 1, data = data.frame(y = y, row.names = names(y)),
            sx = x, modelType = "lr", floatingPoint = 64)
        data$coefficientNames <- names(initial)
        begin <- proc.time()[["elapsed"]]
        setTimeLimit(elapsed = settings$fitSeconds, transient = TRUE)
        fit <- Cyclops::fitCyclopsModel(data,
            prior = Cyclops::createPrior("laplace", variance = settings$priorVariance,
                exclude = "(Intercept)", useCrossValidation = FALSE),
            control = do.call(Cyclops::createControl, settings$control), startingCoefficients = initial)
        setTimeLimit(cpu = Inf, elapsed = Inf, transient = FALSE)
        if (!fit$return_flag %in% c("SUCCESS", "MAX_ITERATIONS")) {
            savePrivate(list(status = fit$return_flag, iterations = fit$iterations), paste0(method, "-failure.rds"))
            stop("corrected_reference_failed")
        }
        partial <- identical(fit$return_flag, "MAX_ITERATIONS")
        if (partial && fit$iterations != settings$control$maxIterations) stop("Unexpected partial reference boundary")
        beta <- if (partial) stats::coef(fit, ignoreConvergence = TRUE) else stats::coef(fit)
        prediction <- stats::predict(fit) # Live cached predictions; diagnostic only when partial.
        eta <- as.numeric(x %*% beta[-1L]) + beta[[1L]]
        stopifnot(identical(names(prediction), rownames(x)), all(is.finite(prediction)),
            all(abs(prediction - stats::plogis(eta)) <= 1e-7 + 1e-7 * pmax(abs(prediction), abs(stats::plogis(eta)))))
        model <- list(coefficients = beta, objective = -(fit$log_likelihood + fit$log_prior),
            logLikelihood = fit$log_likelihood, logPrior = fit$log_prior,
            iterations = fit$iterations, returnFlag = fit$return_flag)
        populations <- etas <- list()
        for (name in namesToUse) {
            population <- inputs[[name]]$site$population
            keys <- paste0(nchar(name), ":", name, ":", population$rowId)
            positions <- match(keys, names(prediction)); stopifnot(!anyNA(positions))
            population$propensityScore <- unname(prediction[positions])
            populations[[name]] <- population
            etas[[name]] <- stats::setNames(eta[positions], as.character(population$rowId))
        }
        results[[method]] <- list(model = model, populations = populations, eta = etas,
            specification = list(candidateIds = inputs[[1L]]$covariateIds,
                covariateIds = as.numeric(names(scales)), excludedIds = as.numeric(names(counts)[!keep]),
                n = nrow(raw), nonzero = counts, maximum = maximum, scales = scales),
            nnz = length(x@x), sparseBytes = as.numeric(object.size(x)),
            seconds = proc.time()[["elapsed"]] - begin, cyclopsPath = find.package("Cyclops"),
            nativePath = getLoadedDLLs()[["Cyclops"]][["path"]])
        savePrivate(results, "corrected-reference.rds")
        record(currentStep, fit$return_flag, results[[method]]$seconds)
    }
    for (name in names(sites)) {
        input <- inputs[[name]]
        ps <- results$pooled$populations[[name]]$propensityScore
        input$evaluation <- list(type = "cdm", seed = settings$seed,
            pooledStatus = results$pooled$model$returnFlag, pooledIterations = results$pooled$model$iterations,
            localStatus = results[[name]]$model$returnFlag,
            covariateIds = as.character(results$pooled$specification$covariateIds),
            scales = results$pooled$specification$scales,
            pooledPs = stats::setNames(ps, as.character(input$site$population$rowId)),
            pooledEta = results$pooled$eta[[name]],
            populations = list(local = results[[name]]$populations[[name]], pooled = results$pooled$populations[[name]]),
            matching = settings$matching, balance = list())
        savePrivate(input, paste0(name, "-worker.rds"))
    }
    # Contains only aggregate/model reference values. Transfer to the learning
    # coordinator for comparison AFTER its independent remote fit has finished.
    savePrivate(results$pooled[c("model", "specification")], "pooled-comparison.rds")
}

runRemote <- function() {
    stopifnot(find.package("Cyclops") == "/opt/federatedps/library/Cyclops")
    library(DSOpal)
    options(opal.retry.times = 1L, datashield.errors.print = FALSE,
        opal.opts = list(cainfo = normalizePath(file.path(private, "opal-public.pem")),
            connect_to = "localhost:8443:opal:8443", ssl_verifyhost = 2L, ssl_verifypeer = TRUE,
            timeout = 1800L, connecttimeout = 30L))
    logins <- data.frame(server = names(sites), url = "https://localhost:8443", user = "c1-researcher",
        password = Sys.getenv("C1_RESEARCH_PASSWORD"), profile = paste0("c1-", names(sites)))
    connections <- DSI::datashield.login(logins, assign = FALSE, failSafe = FALSE, opts = getOption("opal.opts"))
    on.exit(DSI::datashield.logout(connections), add = TRUE)
    # No input/model file is read by the learning coordinator. Each loader has
    # one administrator-fixed private site path and no client-supplied path.
    currentStep <<- "site_local_load"
    DSI::datashield.assign.expr(connections, "cdmInput", "loadPsCdmDS()", async = FALSE)
    DSI::datashield.assign.expr(connections, "cdmRaw",
        sprintf("preparePsCvDS(cdmInput, 0, %d)", settings$seed), async = FALSE)
    summaries <- DSI::datashield.aggregate(connections, "getPsPreprocessingDS(cdmRaw, 0)", async = FALSE)
    specification <- FederatedPs::combinePsSummaries(summaries, settings$minFraction)
    savePrivate(list(summaries = summaries, specification = specification), "remote-preprocessing.rds")
    DSI::datashield.assign.expr(connections, "cdmPrepared",
        sprintf("applyPsPreprocessingDS(cdmRaw, 0, c(%s), c(%s))",
            paste(sprintf("%.17g", specification$covariateIds), collapse = ","),
            paste(sprintf("%.17g", specification$scales), collapse = ",")), async = FALSE)
    record("training_only_preprocessing", "completed", proc.time()[["elapsed"]] - started)
    currentStep <<- "fixed_prior_joint_fit"
    record(currentStep, "started")
    sessionIds <- vapply(connections, function(conn) opalr::opal.session_get(conn@opal)$id, "")
    savePrivate(list(sessionIds = sessionIds, runId = "ActualFixedPrior",
        startedAt = format(Sys.time(), "%Y-%m-%dT%H:%M:%OS6Z", tz = "UTC")), "remote-session-metadata.rds")
    setTimeLimit(elapsed = settings$remoteSeconds, transient = TRUE)
    # The explicit partial option preserves diagnostics at a consistent native
    # iteration limit. Only SUCCESS proceeds to the downstream analysis.
    fit <- FederatedPs::fitPsDataShield(connections, "cdmPrepared", "ActualFixedPrior", returnPartial = TRUE)
    setTimeLimit(cpu = Inf, elapsed = Inf, transient = FALSE)
    fit$trainingEndedAt <- format(Sys.time(), "%Y-%m-%dT%H:%M:%OS6Z", tz = "UTC")
    fit$sessionIds <- sessionIds
    savePrivate(fit, "remote-fit.rds")
    record(currentStep, fit$model$returnFlag, fit$trainingSeconds)
    if (!fit$model$returnFlag %in% c("SUCCESS", "MAX_ITERATIONS")) stop("real_remote_fit_failed")
    currentStep <<- "worker_evaluation"
    DSI::datashield.assign.expr(connections, fit$stateSymbol,
        sprintf('evaluatePsSiteDS(%s, cdmPrepared, "%s", %d)', fit$stateSymbol, fit$runId, fit$step), async = FALSE)
    evaluation <- DSI::datashield.aggregate(connections,
        sprintf('getPsSiteEvaluationDS(%s, "%s", %d)', fit$stateSymbol, fit$runId, fit$step), async = FALSE)
    savePrivate(evaluation, "evaluation-status.rds")
    for (name in names(sites)) {
        x <- evaluation[[name]]$evaluation
        stopifnot(x$numericalComparison %in% c("passed", "passed_partial_same_sweep"),
            x$nativeCache == "passed", x$stateUnchanged == "passed", x$savedPrivately)
        record(paste0(name, "/native_prediction_comparison"), "passed")
        for (method in names(x$matchingStatus)) {
            record(paste(name, method, "matching", sep = "/"), x$matchingStatus[[method]])
            record(paste(name, method, "balance", sep = "/"), x$balanceStatus[[method]])
            record(paste(name, method, "plot", sep = "/"), x$plotStatus[[method]])
        }
    }
}


# Independent downstream analysis of SUCCESS references. This stage can finish
# local comparisons even when a joint fit fails; it never matches a partial fit.
runReport <- function() {
    references <- readRDS(file.path(private, "corrected-reference.rds"))
    inputs <- stats::setNames(lapply(names(sites), function(name)
        readRDS(file.path(private, paste0(name, "-input.rds")))), names(sites))
    prepared <- lapply(inputs, FederatedPs::preparePsCvDS, folds = 0L, seed = settings$seed)
    on.exit(for (x in prepared) Andromeda::close(x$raw$cohortMethodData), add = TRUE)
    rows <- list(); results <- list()
    for (name in names(sites)) for (method in c("local", "pooled")) {
        reference <- references[[if (method == "local") name else "pooled"]]
        key <- paste(name, method, sep = "-")
        row <- data.frame(site = name, method = method, status = reference$model$returnFlag,
            matching = "not_run_nonconverged", balance = "not_run_nonconverged", plot = "not_run_nonconverged",
            sampleSize = nrow(inputs[[name]]$site$population),
            extractedFeatures = length(unique(inputs[[name]]$site$covariates$covariateId)),
            commonCandidates = length(inputs[[name]]$covariateIds),
            trainingFeatures = length(reference$specification$covariateIds),
            modelNnz = reference$nnz, nonzeroCoefficients = sum(reference$model$coefficients[-1L] != 0),
            iterations = reference$model$iterations, fitSeconds = reference$seconds)
        if (reference$model$returnFlag != "SUCCESS") {
            rows[[key]] <- row; record(key, "not_run_nonconverged"); next
        }
        population <- reference$populations[[name]]
        original <- inputs[[name]]$site$population
        stopifnot(identical(population[names(original)], original))
        population <- population[order(population$rowId), ]
        targetRange <- range(population$propensityScore[population$treatment == 1])
        comparatorRange <- range(population$propensityScore[population$treatment == 0])
        # Fraction in the intersection of observed group PS ranges, a
        # descriptive diagnostic, not proof of clinical positivity.
        overlap <- c(max(targetRange[[1L]], comparatorRange[[1L]]),
            min(targetRange[[2L]], comparatorRange[[2L]]))
        row$observedPsRangeOverlap <- mean(population$propensityScore >= overlap[[1L]] &
            population$propensityScore <= overlap[[2L]])
        # Catch only individual OHDSI downstream calls, preserve their errors
        # privately, and keep fit, matching, balance and plotting statuses apart.
        set.seed(settings$seed)
        matched <- tryCatch(CohortMethod::matchOnPs(population,
            do.call(CohortMethod::createMatchOnPsArgs, settings$matching)), error = function(e) e)
        if (inherits(matched, "error")) {
            row$matching <- "failed"; row$balance <- row$plot <- "not_run_matching_failed"
            results[[key]] <- list(error = conditionMessage(matched))
            rows[[key]] <- row; record(key, "matching_failed"); next
        }
        stopifnot(all(matched$rowId %in% original$rowId),
            identical(matched$propensityScore, population$propensityScore[match(matched$rowId, population$rowId)]))
        row$matching <- if (nrow(matched)) "completed" else "completed_empty"
        row$targetBefore <- sum(population$treatment == 1); row$comparatorBefore <- sum(population$treatment == 0)
        row$targetAfter <- sum(matched$treatment == 1); row$comparatorAfter <- sum(matched$treatment == 0)
        row$targetRetention <- row$targetAfter / row$targetBefore
        row$comparatorRetention <- row$comparatorAfter / row$comparatorBefore
        results[[key]] <- list(population = population, matched = matched)
        if (length(unique(matched$treatment)) != 2L) {
            row$balance <- row$plot <- "not_run_no_matched_groups"
            rows[[key]] <- row; record(key, row$matching); next
        }
        balance <- tryCatch(CohortMethod::computeCovariateBalance(matched,
            prepared[[name]]$raw$cohortMethodData, CohortMethod::createComputeCovariateBalanceArgs()), error = function(e) e)
        if (inherits(balance, "error")) {
            row$balance <- "failed"; row$plot <- "not_run_balance_failed"
            results[[key]]$balanceError <- conditionMessage(balance)
            rows[[key]] <- row; record(key, "balance_failed"); next
        }
        stopifnot(setequal(balance$covariateId, unique(inputs[[name]]$site$covariates$covariateId)))
        row$balance <- "completed"
        row$undefinedSmd <- sum(!is.finite(balance$afterMatchingStdDiff))
        defined <- abs(balance$afterMatchingStdDiff[is.finite(balance$afterMatchingStdDiff)])
        before <- abs(balance$beforeMatchingStdDiff[is.finite(balance$beforeMatchingStdDiff)])
        row$asamBefore <- if (length(before)) mean(before) else NA_real_
        row$maxAbsSmdBefore <- if (length(before)) max(before) else NA_real_
        row$undefinedSmdBefore <- sum(!is.finite(balance$beforeMatchingStdDiff))
        row$asam <- if (length(defined)) mean(defined) else NA_real_
        row$maxAbsSmd <- if (length(defined)) max(defined) else NA_real_
        row$undefinedReason <- if (length(defined)) "not_applicable" else "no_defined_smd"
        results[[key]]$balance <- balance
        utils::write.csv(balance, file.path(private, paste0(key, "-balance.csv")), row.names = FALSE)
        plotted <- tryCatch({
            CohortMethod::plotPs(population, scale = "propensity", showCountsLabel = FALSE, showAucLabel = FALSE,
                fileName = file.path(private, paste0(key, "-ps.pdf")))
            CohortMethod::plotCovariateBalanceScatterPlot(balance,
                fileName = file.path(private, paste0(key, "-balance.pdf")))
            TRUE
        }, error = function(e) e)
        row$plot <- if (isTRUE(plotted)) "completed" else "failed"
        if (inherits(plotted, "error")) results[[key]]$plotError <- conditionMessage(plotted)
        rows[[key]] <- row; record(key, paste(row$matching, row$balance, row$plot, sep = "/"))
    }
    columns <- unique(unlist(lapply(rows, names)))
    combined <- do.call(rbind, lapply(rows, function(row) {
        row[setdiff(columns, names(row))] <- NA; row[columns]
    }))
    utils::write.csv(combined, file.path(private, "comparison-summary.csv"), row.names = FALSE)
    savePrivate(results, "reference-downstream.rds")
    # Exact model and preprocessing values remain private, including when the
    # reference is an iteration-limit diagnostic rather than a successful fit.
    remoteFile <- file.path(private, "remote-fit.rds")
    remote <- if (file.exists(remoteFile)) readRDS(remoteFile) else NULL
    validation <- list(status = "not_run")
    if (!is.null(remote)) {
        preprocessing <- readRDS(file.path(private, "remote-preprocessing.rds"))
        oracle <- references$pooled$specification
        spec <- preprocessing$specification
        stopifnot(identical(as.character(spec$candidateIds), as.character(oracle$candidateIds)),
            identical(as.character(spec$covariateIds), as.character(oracle$covariateIds)),
            identical(as.character(spec$excludedIds), as.character(oracle$excludedIds)),
            spec$n == oracle$n, identical(names(spec$nonzero), names(oracle$nonzero)),
            all(spec$nonzero == oracle$nonzero), identical(names(spec$maximum), names(oracle$maximum)),
            all(abs(spec$maximum - oracle$maximum) <= 1e-12 + 1e-12 * pmax(abs(spec$maximum), abs(oracle$maximum))),
            all(abs(spec$scales - oracle$scales) <= 1e-12 + 1e-12 * pmax(abs(spec$scales), abs(oracle$scales))))
        maximumError <- abs(spec$maximum - oracle$maximum)
        scaleError <- abs(spec$scales - oracle$scales)
        sameBoundary <- identical(remote$model$returnFlag, references$pooled$model$returnFlag) &&
            (remote$model$returnFlag == "SUCCESS" || remote$model$iterations == references$pooled$model$iterations)
        validation <- list(status = "preprocessing_passed", sameBoundary = sameBoundary,
            maximum = c(error = max(maximumError), ratio = max(maximumError /
                (1e-12 + 1e-12 * pmax(abs(spec$maximum), abs(oracle$maximum))))),
            scales = c(error = max(scaleError), ratio = max(scaleError /
                (1e-12 + 1e-12 * pmax(abs(spec$scales), abs(oracle$scales))))))
        if (sameBoundary) {
            error <- abs(remote$model$objective - references$pooled$model$objective)
            limit <- 1e-7 + 1e-7 * max(abs(remote$model$objective), abs(references$pooled$model$objective))
            validation$objective <- c(error = error, ratio = error / limit)
            validation$status <- if (error <= limit) "passed_same_boundary" else "failed_objective"
        }
    }
    savePrivate(validation, "comparison-validation.rds")
    report <- c("# Private actual-CDM execution", "Disclosure: withheld_pending_policy.",
        paste("Sources:", paste(sites, collapse = ", ")),
        "This is a software/method comparison; SynPUF is synthetic claims data, not a second observed hospital.",
        "No real-data CV, causal outcome analysis, or privacy guarantee was validated.",
        "Cohort/feature artifacts retain the full cohort and the fixed capped sample separately.",
        "L is the independent initial-LANGE-classification correction; F also has the coordinate API patch.",
        paste("Settings:", paste(capture.output(str(settings)), collapse = "\n")),
        paste("Fit status:", paste(names(references), vapply(references, function(x) x$model$returnFlag, ""), collapse = "; ")),
        paste("Remote:", if (is.null(remote)) "no_terminal_remote_result" else remote$model$returnFlag),
        paste("Private cohort summary:", if (file.exists(file.path(private, "cohort-summary.rds")))
            paste(capture.output(print(readRDS(file.path(private, "cohort-summary.rds")))), collapse = "\n") else
            "Retained in the analysis container /tmp/federatedps-real-private/20260907-final"),
        paste("Comparison:", validation$status),
        "No nonconverged fit was used for matching. Errors are retained in the private downstream RDS.",
        paste(capture.output(print(combined, row.names = FALSE)), collapse = "\n"))
    writeLines(report, file.path(private, "final-report.md"))
    Sys.chmod(list.files(private, full.names = TRUE)[!file.info(list.files(private, full.names = TRUE))$isdir], "0600")
    record("private_final_report", "saved")
}

status <- tryCatch({
    if (stage == "extract") { runExtraction(); verifyExtraction() } else if (stage == "verify") verifyExtraction() else if (stage == "reference") runReference() else if (stage == "train") runRemote() else runReport()
    0L
}, error = function(e) {
    message <- conditionMessage(e)
    for (secret in Sys.getenv(c("PGPASSWORD", "C1_OPAL_PASSWORD", "C1_RESEARCH_PASSWORD")))
        if (nzchar(secret)) message <- gsub(secret, "[redacted]", message, fixed = TRUE)
    cat("PRIVATE ERROR at ", currentStep, ": ", message, "\n", sep = "")
    record(currentStep, "failed_details_private", proc.time()[["elapsed"]] - started)
    1L
})
sink(type = "message"); sink(); close(log); close(public)
quit(status = status, save = "no")
