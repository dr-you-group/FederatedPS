# E1-followup. Patient rows stay in PostgreSQL; exact aggregates are private.
# Usage: script shared-output aggregate cached-E1-metadata [or metadata/synthetic].
args <- commandArgs(trailingOnly = TRUE)
stopifnot(length(args) %in% 1:3)
output <- normalizePath(args[[1L]], mustWork = TRUE)
stage <- if (length(args) >= 2L) match.arg(args[[2L]], c("metadata", "aggregate", "synthetic")) else "metadata"
metadataPath <- if (length(args)==3L) normalizePath(args[[3L]],mustWork=TRUE) else output
settings <- list(schemas=c("mimiciv","synpuf23"),ingredients=c("atorvastatin","simvastatin"),
    metadataSeconds=30L,statementSeconds=600L,lockSeconds=5L,totalSeconds=2700L)
stopifnot(!file.exists(file.path(output,"execution-summary.csv")))
required <- c("PGHOST","PGPORT","PGDATABASE","PGUSER","PGPASSWORD")
stopifnot(all(nzchar(Sys.getenv(required))),!is.na(as.integer(Sys.getenv("PGPORT"))))
script <- sub("^--file=","",commandArgs()[startsWith(commandArgs(),"--file=")])
lines <- readLines(file.path(dirname(script),"sql","CohortFeasibility.sql"))
markers <- which(startsWith(lines,"-- @step "))
statements <- setNames(lapply(seq_along(markers),function(i) {
    end <- if(i<length(markers)) markers[[i+1L]]-1L else length(lines)
    paste(lines[seq.int(markers[[i]]+1L,end)],collapse="\n")
}),sub("-- @step ","",lines[markers],fixed=TRUE))
started <- proc.time()[["elapsed"]]
execution <- list()
connections <- list()
aggregates <- list()
private <- NULL

record <- function(site,step,operation,status,seconds,disclosure="not_applicable") {
    execution[[length(execution)+1L]] <<- data.frame(site=site,step=step,operation=operation,
        status=status,seconds=seconds,result_disclosure=disclosure)
    utils::write.csv(do.call(rbind,execution),file.path(output,"execution-summary.csv"),row.names=FALSE)
    cat(site,step,operation,status,sprintf("%.3f seconds",seconds),"\n")
}
connect <- function(site,readWrite=FALSE) {
    connection <- tryCatch(DBI::dbConnect(RPostgres::Postgres(),host=Sys.getenv("PGHOST"),
        port=as.integer(Sys.getenv("PGPORT")),dbname=Sys.getenv("PGDATABASE"),
        user=Sys.getenv("PGUSER"),password=Sys.getenv("PGPASSWORD"),connect_timeout=10,
        options="-c default_transaction_read_only=on -c statement_timeout=30000 -c lock_timeout=5000"),
        error=function(e) stop("connection_failed_details_withheld",call.=FALSE))
    connections[[site]] <<- connection
    DBI::dbBegin(connection)
    DBI::dbExecute(connection,paste("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ",
        if(readWrite) "READ WRITE" else "READ ONLY"))
    connection
}
query <- function(site,step,sql,fetch=TRUE,metadata=FALSE,operation=if(fetch) "aggregate" else "temporary_materialization") {
    remaining <- settings$totalSeconds-(proc.time()[["elapsed"]]-started)
    if(remaining<=0) stop("total_budget_exhausted",call.=FALSE)
    connection <- connections[[site]]
    seconds <- min(remaining,if(metadata) settings$metadataSeconds else settings$statementSeconds)
    DBI::dbExecute(connection,paste0("SET LOCAL statement_timeout = ",max(1L,floor(seconds*1000))))
    begin <- proc.time()[["elapsed"]]
    value <- tryCatch(withCallingHandlers({
        if(fetch) DBI::dbGetQuery(connection,sql) else invisible(DBI::dbExecute(connection,sql))
    },warning=function(w) stop("database_warning_details_withheld",call.=FALSE)),error=function(e) {
        message <- conditionMessage(e)
        state <- if(any(vapply(c("canceling statement due to statement timeout",
            "명령실행시간 초과로 작업을 취소합니다."),function(s) grepl(s,message,fixed=TRUE),TRUE))) "timeout"
            else if(grepl("lock timeout|잠금.*초과",message)) "lock_timeout"
            else if(grepl("permission denied|권한.*없",message)) "permission_error" else "query_error"
        record(site,step,operation,state,proc.time()[["elapsed"]]-begin,
            if(fetch && !metadata) state else "not_applicable")
        stop(paste("E1",site,step,state,"details_withheld"),call.=FALSE)
    })
    record(site,step,operation,"completed",proc.time()[["elapsed"]]-begin,
        if(fetch && !metadata) "withheld_pending_policy" else "not_applicable")
    value
}
siteSql <- function(step,site) {
    if(grepl("@cdm_schema",statements[[step]],fixed=TRUE)) {
        SqlRender::render(statements[[step]],cdm_schema=as.character(DBI::dbQuoteIdentifier(connections[[site]],site)))
    } else {
        SqlRender::render(statements[[step]])
    }
}
explain <- function(site,step,sql) {
    plan <- query(site,step,paste("EXPLAIN (COSTS FALSE)",sql),metadata=TRUE,operation="explain_without_analyze")
    path <- file.path(private,"query-plans.log")
    cat(paste(site,step),paste(plan[[1L]],collapse="\n"),sep="\n",file=path,append=TRUE)
    Sys.chmod(path,"0600")
}
materialize <- function(site,step,select,key=NULL,metadata=FALSE) {
    name <- paste0("e1_",step)
    stopifnot(grepl("^e1_[a-z_]+$",name))
    sql <- paste("CREATE TEMP TABLE",name,"ON COMMIT DROP AS",select)
    explain(site,step,sql)
    query(site,step,sql,fetch=FALSE,metadata=metadata)
    owned <- query(site,paste0(step,"_ownership"),paste0("SELECT coalesce(bool_and(relpersistence='t' ",
        "AND relnamespace=pg_my_temp_schema()),FALSE) AS owned FROM pg_class WHERE oid=to_regclass('pg_temp.",name,"')"),
        metadata=TRUE,operation="temporary_ownership_check")
    stopifnot(isTRUE(owned$owned))
    if(!is.null(key)) query(site,step,paste0("CREATE UNIQUE INDEX ",name,"_key ON pg_temp.",name," (",key,")"),
        fetch=FALSE,metadata=metadata,operation="temporary_index")
    query(site,step,paste("ANALYZE pg_temp.",name,sep=""),fetch=FALSE,metadata=metadata,operation="temporary_analyze")
    invisible(NULL)
}
saveAggregates <- function() {
    # Only explicitly populated aggregate lists, never a workspace/connection.
    path <- file.path(private,"cohort-aggregates.rds")
    if(!file.exists(path)) file.create(path)
    Sys.chmod(path,"0600")
    saveRDS(list(definition="E1 first-recorded single ingredient; age >=65; valid visit end [-90,-1]",
        disclosure="withheld_pending_policy",sites=aggregates),path)
    stopifnot(as.character(file.info(path)$mode)=="600")
}
closeConnections <- function() {
    for(site in names(connections)) {
        connection <- connections[[site]]
        if(!DBI::dbIsValid(connection)) next
        clean <- tryCatch({
            DBI::dbRollback(connection)
            check <- DBI::dbGetQuery(connection,"SELECT NOT EXISTS (SELECT 1 FROM pg_class
                WHERE relnamespace=pg_my_temp_schema() AND relname LIKE 'e1_%') AS cleared")
            isTRUE(check$cleared)
        },error=function(e) FALSE)
        DBI::dbDisconnect(connection)
        record(site,"session_cleanup","rollback_disconnect",if(clean) "completed" else "cleanup_check_failed",0)
    }
}
run <- function() {
    on.exit(closeConnections(),add=TRUE)
    if(stage=="metadata") {
        stopifnot(!file.exists(file.path(output,"concept-metadata.csv")))
        connection <- connect("metadata")
        metadataQuery <- query
        query <- function(label,sql) metadataQuery("metadata",label,sql,metadata=TRUE,operation="metadata")
    access <- query("schema_and_table_access", "SELECT t.table_schema, t.table_name,
        has_schema_privilege(t.table_schema,'USAGE') AS schema_usage,
        has_table_privilege(format('%I.%I',t.table_schema,t.table_name),'SELECT') AS can_select
        FROM information_schema.tables t WHERE t.table_schema IN ('mimiciv','synpuf23')
        AND t.table_name IN ('person','drug_exposure','visit_occurrence','observation_period',
            'condition_occurrence','procedure_occurrence') ORDER BY t.table_schema,t.table_name")
    columns <- query("domain_date_columns", "SELECT table_schema,table_name,column_name,data_type
        FROM information_schema.columns WHERE table_schema IN ('mimiciv','synpuf23')
        AND table_name IN ('person','drug_exposure','visit_occurrence','observation_period',
            'condition_occurrence','procedure_occurrence')
        AND (column_name LIKE '%date%' OR column_name LIKE '%birth%' OR column_name='visit_occurrence_id')
        ORDER BY table_schema,table_name,ordinal_position")
    utils::write.csv(access, file.path(output,"domain-access.csv"), row.names=FALSE)
    utils::write.csv(columns, file.path(output,"domain-columns.csv"), row.names=FALSE)
    sources <- vocabularies <- seeds <- products <- list()
    for (site in settings$schemas) {
        schema <- as.character(DBI::dbQuoteIdentifier(connection, site))
        source <- query(paste(site, "cdm_source"), paste0("SELECT cdm_source_name, cdm_source_abbreviation,
            cdm_holder, source_description, source_documentation_reference, cdm_etl_reference,
            source_release_date, cdm_release_date, cdm_version, vocabulary_version FROM ", schema, ".cdm_source"))
        source$site <- site
        sources[[site]] <- source
        vocabulary <- query(paste(site, "vocabulary"), paste0("SELECT vocabulary_id, vocabulary_name,
            vocabulary_reference, vocabulary_version FROM ", schema, ".vocabulary
            WHERE vocabulary_id IN ('None','RxNorm','RxNorm Extension','SNOMED','Type Concept') ORDER BY vocabulary_id"))
        vocabulary$site <- site
        vocabularies[[site]] <- vocabulary
        seed <- query(paste(site, "ingredient_seed"), paste0("SELECT concept_id, concept_name, vocabulary_id,
            concept_code, standard_concept, concept_class_id, valid_start_date, valid_end_date, invalid_reason
            FROM ", schema, ".concept WHERE lower(concept_name) IN ('atorvastatin','simvastatin')
            AND domain_id='Drug' AND concept_class_id='Ingredient'
            AND standard_concept='S' AND invalid_reason IS NULL ORDER BY concept_name"))
        stopifnot(nrow(seed) == 2L, identical(tolower(seed$concept_name), settings$ingredients))
        seed$site <- site
        seeds[[site]] <- seed
        # Search names only to identify the seeds. All subsequent membership is
        # based on their verified IDs and all standard ingredient ancestors.
        ids <- paste(as.integer(seed$concept_id), collapse = ",")
        sql <- paste0("WITH products AS MATERIALIZED (
            SELECT DISTINCT a.ancestor_concept_id AS study_ingredient_id, c.concept_id,
                c.concept_name, c.concept_class_id, c.vocabulary_id, c.concept_code
            FROM ", schema, ".concept_ancestor a JOIN ", schema, ".concept c ON c.concept_id=a.descendant_concept_id
            WHERE a.ancestor_concept_id IN (", ids, ") AND c.standard_concept='S'
                AND c.domain_id='Drug' AND c.invalid_reason IS NULL
        ), ingredients AS (
            SELECT DISTINCT p.concept_id, a.ancestor_concept_id AS ingredient_id, 'ancestor' AS evidence
            FROM (SELECT DISTINCT concept_id FROM products) p
            JOIN ", schema, ".concept_ancestor a ON a.descendant_concept_id=p.concept_id
            JOIN ", schema, ".concept i ON i.concept_id=a.ancestor_concept_id
            WHERE i.concept_class_id='Ingredient' AND i.standard_concept='S' AND i.invalid_reason IS NULL
            UNION
            SELECT DISTINCT p.concept_id, d.ingredient_concept_id, 'strength' AS evidence
            FROM (SELECT DISTINCT concept_id FROM products) p
            JOIN ", schema, ".drug_strength d ON d.drug_concept_id=p.concept_id
            WHERE d.invalid_reason IS NULL
        ), definition AS (
            SELECT concept_id, count(DISTINCT ingredient_id) AS ingredient_count,
                min(ingredient_id) AS only_ingredient_id,
                count(DISTINCT ingredient_id) FILTER (WHERE evidence='ancestor') AS ancestor_ingredients,
                count(DISTINCT ingredient_id) FILTER (WHERE evidence='strength') AS strength_ingredients
            FROM ingredients GROUP BY concept_id
        ) SELECT p.*, d.ingredient_count, d.ancestor_ingredients, d.strength_ingredients,
            (d.ingredient_count=1 AND d.only_ingredient_id=p.study_ingredient_id) AS single_ingredient
        FROM products p LEFT JOIN definition d USING(concept_id)
        ORDER BY p.study_ingredient_id,p.concept_id")
        product <- query(paste(site, "product_ingredient_definition"), sql)
        product$site <- site
        products[[site]] <- product
    }
    for (entry in c("sources", "vocabularies", "seeds", "products")) {
        value <- get(entry)
        filename <- c(sources = "cdm-source.csv", vocabularies = "vocabulary-metadata.csv",
            seeds = "concept-metadata.csv", products = "product-definitions.csv")[[entry]]
        utils::write.csv(do.call(rbind, value), file.path(output, filename), row.names = FALSE)
    }
    fields <- setdiff(names(products[[1L]]), "site")
    stopifnot(identical(products[[1L]][fields], products[[2L]][fields]))
    cat("E1_PRODUCT_DEFINITIONS_IDENTICAL\n")
    for (site in settings$schemas) {
        p <- products[[site]]
        cat(site, "vocabulary candidates", nrow(p), "single ingredient", sum(p$single_ingredient, na.rm = TRUE), "\n")
    }

        cat("E1_NONPATIENT_METADATA_COMPLETE\n")
        return(invisible(NULL))
    }
    # Verify the dedicated path is in the existing container's internal /tmp,
    # not any bind/volume mount. The Docker mount list is also checked by setup.
    stopifnot(file.exists("/.dockerenv"),!nzchar(Sys.readlink("/tmp")))
    mountPoints <- vapply(strsplit(readLines("/proc/self/mountinfo")," ",fixed=TRUE),`[[`,"",5L)
    base <- "/tmp/federatedps-e1-private"
    stopifnot(!any(mountPoints!="/" & (startsWith(base,paste0(mountPoints,"/")) | base==mountPoints)))
    if(!dir.exists(base)) dir.create(base,mode="0700")
    stopifnot(!nzchar(Sys.readlink(base)),normalizePath(base)==base)
    Sys.chmod(base,"0700")
    private <<- file.path(base,paste0(format(Sys.time(),"%Y%m%dT%H%M%S"),"-",Sys.getpid()))
    stopifnot(dir.create(private,mode="0700"),as.character(file.info(private)$mode)=="700")
    cat("E1_PRIVATE_DIRECTORY",private,"\n")
    writeLines(paste("private_aggregate_path",file.path(private,"cohort-aggregates.rds")),
        file.path(output,"provenance.log"))

    # Use the actual SELECT fragments for both index algorithms and eligibility.
    connection <- connect("synthetic")
    sourceNames <- c("pg_temp.e1_definitions"="fixture_definitions",
        "@cdm_schema.drug_exposure"="fixture_drug_exposure",
        "@cdm_schema.person"="fixture_person","@cdm_schema.visit_occurrence"="fixture_visit_occurrence")
    substitute <- function(sql,prefix="") {
        replacements <- c(sourceNames,setNames(paste0(prefix,c("exposures","first","age","visits","cohort","final")),
            paste0("pg_temp.e1_",c("exposures","first","age","visits","cohort","final"))))
        replacements[["pg_temp.e1_exposures"]] <- "exposures"
        for(key in names(replacements)) sql <- gsub(key,replacements[[key]],sql,fixed=TRUE)
        sql
    }
    ctes <- c(statements$synthetic_sources,paste0("exposures AS (",substitute(statements$exposures),")"))
    for(prefix in c("old_","new_")) {
        first <- if(prefix=="old_") statements$synthetic_original_first else substitute(statements$first,prefix)
        ctes <- c(ctes,paste0(prefix,"first AS (",first,")"))
        for(step in c("age","visits","cohort","final","attrition")) {
            select <- substitute(statements[[step]],prefix)
            if(prefix=="old_" && step=="visits") select <- paste0("SELECT a.person_id,count(*) AS baseline_visits,
                TRUE AS any_prior_visit,FALSE AS earlier_than_baseline FROM old_age a
                JOIN fixture_visit_occurrence v USING(person_id) WHERE a.age>=65
                AND v.visit_start_date IS NOT NULL AND v.visit_end_date IS NOT NULL
                AND isfinite(v.visit_start_date) AND isfinite(v.visit_end_date)
                AND v.visit_start_date<=v.visit_end_date
                AND v.visit_end_date BETWEEN a.index_date-90 AND a.index_date-1 GROUP BY a.person_id")
            ctes <- c(ctes,paste0(prefix,step," AS (",select,")"))
        }
        ctes <- c(ctes,paste0(prefix,"rows AS (SELECT f.*,a.age,coalesce(a.baseline_visits,0)::bigint AS baseline_visits,
            coalesce(a.age>=65 AND a.baseline_visits>0,FALSE) AS final_member FROM ",prefix,"first f LEFT JOIN ",prefix,
            "cohort a USING(person_id))"))
    }
    ctes <- c(ctes,paste0("expected AS (",statements$synthetic_expected,")"))
    comparisons <- c("index_treatment_age_baseline"="SELECT * FROM old_rows EXCEPT ALL SELECT * FROM new_rows",
        "reverse_index_treatment_age_baseline"="SELECT * FROM new_rows EXCEPT ALL SELECT * FROM old_rows",
        "explicit_expected_cases"="SELECT * FROM new_rows EXCEPT ALL SELECT * FROM expected",
        "missing_expected_cases"="SELECT * FROM expected EXCEPT ALL SELECT * FROM new_rows",
        "attrition"="SELECT * FROM old_attrition EXCEPT ALL SELECT * FROM new_attrition",
        "reverse_attrition"="SELECT * FROM new_attrition EXCEPT ALL SELECT * FROM old_attrition")
    tests <- paste(vapply(names(comparisons),function(name) paste0("SELECT '",name,"' AS test,
        NOT EXISTS (",comparisons[[name]],") AS passed"),""),collapse=" UNION ALL ")
    validation <- query("synthetic","values_equivalence",paste("WITH",paste(ctes,collapse=",\n"),tests),
        metadata=TRUE,operation="synthetic_sql")
    utils::write.csv(validation,file.path(output,"synthetic-equivalence.csv"),row.names=FALSE)
    stopifnot(all(validation$passed))
    DBI::dbRollback(connection)
    DBI::dbDisconnect(connection)
    connections[["synthetic"]] <<- NULL
    if(stage=="synthetic") return(invisible(NULL))

    products <- utils::read.csv(file.path(metadataPath,"product-definitions.csv"),check.names=FALSE)
    vocabulary <- utils::read.csv(file.path(metadataPath,"vocabulary-metadata.csv"),check.names=FALSE)
    fields <- setdiff(names(products),"site")
    canonical <- function(x) { rownames(x)<-NULL; x[]<-lapply(x,as.character); x }
    stopifnot(identical(canonical(products[products$site==settings$schemas[[1L]],fields]),
        canonical(products[products$site==settings$schemas[[2L]],fields])))
    cat("CACHED_VOCABULARY_ID_DEFINITIONS_IDENTICAL\n")
    # Complete both mandatory cohorts first; each connection retains its own
    # repeatable-read snapshot for the subsequent availability queries.
    available <- setNames(rep(FALSE,length(settings$schemas)),settings$schemas)
    for(site in settings$schemas) {
        tryCatch({
            connection <- connect(site,readWrite=TRUE)
            mode <- query(site,"connection_metadata","SELECT current_database() AS database_name,
                current_setting('server_version') AS server_version,current_setting('transaction_read_only') AS read_only,
                current_setting('transaction_isolation') AS isolation,
                current_setting('lock_timeout') AS lock_timeout,has_database_privilege(current_database(),'TEMP') AS temp_allowed",
                metadata=TRUE,operation="metadata")
            stopifnot(mode$database_name=="ohdsi",mode$read_only=="off",mode$isolation=="repeatable read",
                mode$lock_timeout=="5s",isTRUE(mode$temp_allowed))
            schema <- as.character(DBI::dbQuoteIdentifier(connection,site))
            current <- query(site,"vocabulary_version",paste0("SELECT vocabulary_id,vocabulary_name,
                vocabulary_reference,vocabulary_version FROM ",schema,".vocabulary
                WHERE vocabulary_id IN ('None','RxNorm','RxNorm Extension','SNOMED','Type Concept') ORDER BY vocabulary_id"),
                metadata=TRUE,operation="metadata")
            stopifnot(identical(canonical(current),canonical(vocabulary[vocabulary$site==site,names(current)])))
            definition <- products[products$site==site,]
            stopifnot(!anyDuplicated(definition[c("concept_id","study_ingredient_id")]),
                all(is.finite(definition$concept_id)),all(definition$concept_id==as.integer(definition$concept_id)),
                all(definition$study_ingredient_id %in% c(1545958,1539403)))
            # Reuse the verified all-ingredient/strength classification. Confirm
            # exact current candidate IDs and product definitions, not just size.
            current <- query(site,"product_membership",paste0("SELECT DISTINCT a.ancestor_concept_id AS study_ingredient_id,
                c.concept_id,c.concept_name,c.concept_class_id,c.vocabulary_id,c.concept_code FROM ",schema,
                ".concept_ancestor a JOIN ",schema,".concept c ON c.concept_id=a.descendant_concept_id
                WHERE a.ancestor_concept_id IN (1545958,1539403) AND c.standard_concept='S'
                AND c.domain_id='Drug' AND c.invalid_reason IS NULL ORDER BY study_ingredient_id,concept_id"),
                metadata=TRUE,operation="metadata")
            stopifnot(identical(canonical(current),canonical(definition[names(current)])))
            values <- paste(sprintf("(%d,%d,%s)",definition$concept_id,definition$study_ingredient_id,
                ifelse(!is.na(definition$single_ingredient)&definition$single_ingredient,"TRUE","FALSE")),collapse=",")
            materialize(site,"definitions",paste0("SELECT DISTINCT * FROM (VALUES ",values,
                ") v(drug_concept_id,ingredient_id,single_ingredient)"),"drug_concept_id,ingredient_id",metadata=TRUE)
            for(step in c("exposures","first","age","visits","cohort","final")) {
                materialize(site,step,siteSql(step,site),if(step=="exposures") NULL else "person_id")
            }
            sql <- siteSql("attrition",site)
            explain(site,"attrition",sql)
            result <- query(site,"attrition",sql)
            checks <- result[result$section=="validation",]
            stopifnot(nrow(checks)==6L,all(as.numeric(checks$value)==0),
                all(is.finite(as.numeric(result$value))),all(as.numeric(result$value)>=0))
            for(id in c(1545958,1539403)) {
                counts <- result[result$section=="attrition" & !is.na(result$ingredient_id) & result$ingredient_id==id,]
                counts <- counts[order(counts$metric),]
                stopifnot(nrow(counts)==5L,all(diff(as.numeric(counts$value))<=0))
            }
            aggregates[[site]] <<- list(connection_metadata=mode,attrition=result,
                limitations=c("first-recorded; not new-user or complete 90-day observation",
                    "exact counts withheld pending disclosure policy; clinical comparability not established"))
            saveAggregates()
            available[[site]] <- TRUE
        },error=function(e) {
            record(site,"mandatory_cohort","site_execution","failed_details_withheld",0,"not_computed")
            if(!is.null(connections[[site]]) && DBI::dbIsValid(connections[[site]])) {
                try(DBI::dbRollback(connections[[site]]),silent=TRUE)
                DBI::dbDisconnect(connections[[site]])
                connections[[site]] <<- NULL
            }
        })
    }
    domains <- list(condition=c("condition_occurrence","condition_start_date","condition_start_datetime"),
        drug=c("drug_exposure","drug_exposure_start_date","drug_exposure_start_datetime"),
        procedure=c("procedure_occurrence","procedure_date","procedure_datetime"))
    for(site in settings$schemas) {
        if(!available[[site]]) {
            for(step in c("observation",names(domains),"drug_types"))
                record(site,step,"aggregate","not_computed",0,"not_computed")
            next
        }
        for(step in c("observation",names(domains),"drug_types")) {
            if(!available[[site]]) {
                record(site,step,"aggregate","not_computed",0,"not_computed")
                next
            }
            tryCatch({
                sql <- if(step %in% names(domains)) SqlRender::render(siteSql("domain",site),
                    domain_table=domains[[step]][[1L]],event_date=domains[[step]][[2L]],event_datetime=domains[[step]][[3L]])
                    else siteSql(step,site)
                explain(site,step,sql)
                result <- query(site,step,sql)
                numericFields <- if(step=="drug_types") c("study_exposure_records","study_exposed_persons",
                    "eligible_exposure_records","eligible_exposed_persons") else "value"
                stopifnot(all(vapply(result[numericFields],function(x) all(is.finite(as.numeric(x)) & as.numeric(x)>=0),TRUE)))
                aggregates[[site]][[step]] <<- result
                saveAggregates()
            },error=function(e) {
                available[[site]] <<- FALSE
                record(site,step,"availability_execution","failed_details_withheld",0,"not_computed")
                try(DBI::dbRollback(connections[[site]]),silent=TRUE)
                DBI::dbDisconnect(connections[[site]])
                connections[[site]] <<- NULL
            })
        }
    }
    cat("E1_PRIVATE_AGGREGATE_FILE_CREATED",file.exists(file.path(private,"cohort-aggregates.rds")),"\n")
    if(!all(available)) stop("one_or_more_sites_incomplete; inspect nonnumeric execution statuses",call.=FALSE)
    cat("E1_INTERNAL_AGGREGATES_COMPLETE; exact results withheld_pending_policy\n")
}
status <- tryCatch({run();0L},error=function(e) {
    # Errors can contain query text/data; never echo the original condition.
    cat("E1_EXECUTION_INCOMPLETE_DETAILS_WITHHELD; inspect execution-summary.csv\n")
    1L
})
quit(status=status,save="no")
