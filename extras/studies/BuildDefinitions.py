#!/usr/bin/env python3
"""Build reviewable ATLAS cohorts from pinned public sources and a CDM vocabulary.

uv run --with 'psycopg[binary]' --with python-dotenv python extras/studies/BuildDefinitions.py
This reads vocabulary tables only. Patient selection is performed by CirceR in R.
"""
import argparse
import copy
import csv
import hashlib
import itertools
import json
from pathlib import Path

import psycopg
from dotenv import dotenv_values

ROOT = Path(__file__).resolve().parents[2]
DEST = ROOT / "inst/studies"
SOURCE = DEST / "source"


def read_json(path):
    return json.loads((SOURCE / path).read_text())


def items(ids, concepts):
    return [{"concept": concepts[int(i)], "isExcluded": False,
             "includeDescendants": True, "includeMapped": False} for i in sorted(set(ids))]


def codeset(id_, name, expression_items):
    return {"id": id_, "name": name, "expression": {"items": copy.deepcopy(expression_items)}}


def rule(name, domain, codeset_id, start=None, end=0, count=1):
    start_window = {"Coeff": -1}
    if start is not None:
        start_window["Days"] = start
    return {"name": name, "expression": {"Type": "ALL", "CriteriaList": [{
        "Criteria": {domain: {"CodesetId": codeset_id}},
        "StartWindow": {"Start": start_window, "End": {"Days": abs(end), "Coeff": -1 if end < 0 else 1}},
        "Occurrence": {"Type": 2 if count else 0, "Count": count}}],
        "DemographicCriteriaList": [], "Groups": []}}


def adult_rule():
    return {"name": "Age at least 18 at index", "expression": {"Type": "ALL", "CriteriaList": [],
            "DemographicCriteriaList": [{"Age": {"Value": 18, "Op": "gte"}}], "Groups": []}}


def cohort(exposure_items, label, prior=0, domain="DrugEra"):
    return {"cdmVersionRange": ">=5.0.0", "ConceptSets": [codeset(0, label, exposure_items)],
            "PrimaryCriteria": {"CriteriaList": [{domain: {"CodesetId": 0, "First": True}}],
                                "ObservationWindow": {"PriorDays": prior, "PostDays": 0},
                                "PrimaryCriteriaLimit": {"Type": "First"}},
            "QualifiedLimit": {"Type": "First"}, "ExpressionLimit": {"Type": "First"},
            "InclusionRules": [adult_rule()], "EndStrategy": {"DateOffset": {"DateField": "StartDate", "Offset": 0}},
            "CensoringCriteria": [], "CollapseSettings": {"CollapseType": "ERA", "EraPad": 0},
            "CensorWindow": {}}


def exposure_set(original):
    event = next(iter(original["PrimaryCriteria"]["CriteriaList"][0].values()))
    return next(s for s in original["ConceptSets"] if s["id"] == event["CodesetId"])


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(value, ensure_ascii=False, indent=2) + "\n"
    path.write_text(text)
    return hashlib.sha256(text.encode()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--connection-file", default=".Renviron.mimic")
    args = parser.parse_args()
    config = dotenv_values(ROOT / args.connection_file)
    schema = config["CDM_DATABASE_SCHEMA"]
    legend = list(csv.DictReader((SOURCE / "Legend/inst/settings/ExposuresOfInterest.csv").open()))
    requested = {316866, 4152280, 4029498, 435783, 436665, 739138, 797617, 715939,
                 755695, 743670, 715259, 1395058, 974166}
    for row in legend:
        if row["conceptId"]: requested.add(int(row["conceptId"]))
        requested.update(int(i) for i in row["includedConceptIds"].split(";") if i)
    from psycopg import sql
    with psycopg.connect(host=config["PGHOST"], port=config["PGPORT"], dbname=config["PGDATABASE"],
                         user=config["PGUSER"], password=config["PGPASSWORD"],
                         options="-c default_transaction_read_only=on") as connection:
        records = connection.execute(sql.SQL("SELECT concept_id, concept_name, domain_id, vocabulary_id, "
            "concept_class_id, concept_code, standard_concept, invalid_reason FROM {}.concept "
            "WHERE concept_id = ANY(%s)").format(sql.Identifier(schema)), (list(requested),))
        concepts = {}
        for row in records:
            concepts[row[0]] = dict(zip(["CONCEPT_ID", "CONCEPT_NAME", "DOMAIN_ID", "VOCABULARY_ID",
                                        "CONCEPT_CLASS_ID", "CONCEPT_CODE", "STANDARD_CONCEPT", "INVALID_REASON"], row))
        vocabularies = connection.execute(sql.SQL("SELECT vocabulary_id, vocabulary_version FROM {}.vocabulary "
            "WHERE vocabulary_id IN ('None','RxNorm','RxNorm Extension','SNOMED','ATC') ORDER BY 1").format(sql.Identifier(schema))).fetchall()
    classes = {"acei": (1, "ACE inhibitors"), "arb": (4, "ARBs"),
               "dccb": (10, "dihydropyridine CCBs"), "thiazide": (15, "thiazide / thiazide-like diuretics")}
    definitions = {}
    for key, (id_, label) in classes.items():
        row = next(r for r in legend if r["indicationId"] == "Hypertension" and r["type"] == "Drug class" and int(r["cohortId"]) == id_)
        definitions[key] = (label, [int(i) for i in row["includedConceptIds"].split(";")])
    all_htn = sorted({int(r["conceptId"]) for r in legend if r["indicationId"] == "Hypertension" and r["type"] == "Drug"})
    candidates = []

    def add(study, group, labels, exposure_items, prior, doi, journal, year, question, rationale, sources, **other):
        candidates.append(dict(study=study, group=group, target=labels[0], comparator=labels[1],
            exposureItems=exposure_items, priorObservationDays=prior, doi=doi, journal=journal,
            publicationYear=year, question=question, rationale=rationale, sourceFiles=sources, **other))

    for a, b in itertools.combinations(classes, 2):
        add(f"ohdsi_htn_{a}_{b}", "hypertension", [definitions[a][0], definitions[b][0]],
            [items(definitions[a][1], concepts), items(definitions[b][1], concepts)], 365,
            "10.1016/S0140-6736(19)32317-7", "The Lancet", 2019,
            "Comparative effectiveness and safety of first-line antihypertensive therapies.",
            "Common indication with differences in initial drug-class choice.",
            ["Legend/inst/sql/sql_server/CreateExposureCohortsHypertension.sql", "Legend/inst/settings/ExposuresOfInterest.csv"])
    add("ohdsi_htn_chlorthalidone_hctz", "hypertension", ["chlorthalidone", "hydrochlorothiazide"],
        [items([1395058], concepts), items([974166], concepts)], 365, "10.1001/jamainternmed.2019.7454",
        "JAMA Internal Medicine", 2020, "Cardiovascular and safety outcomes of first-line chlorthalidone versus hydrochlorothiazide.",
        "Within-class ingredient choice complements the class-level comparisons.",
        ["Legend/inst/sql/sql_server/CreateExposureCohortsHypertension.sql", "Legend/inst/settings/ExposuresOfInterest.csv"])
    for name, id_ in [("citalopram", 797617), ("escitalopram", 715939), ("fluoxetine", 755695), ("venlafaxine", 743670), ("duloxetine", 715259)]:
        add(f"ohdsi_depression_sertraline_{name}", "depression", ["sertraline", name],
            [items([739138], concepts), items([id_], concepts)], 365, "10.1098/rsta.2017.0356",
            "Philosophical Transactions of the Royal Society A", 2018,
            "Large-scale comparative effectiveness of depression treatments across observational databases.",
            "Psychiatric indication; SSRI and SSRI/SNRI treatment-choice tasks.",
            ["StudyProtocols/LargeScalePopEst/inst/sql/sql_server/ExposureCohorts.sql",
             "StudyProtocols/LargeScalePopEst/inst/settings/ExposuresOfInterest.csv"])
    for study, group, files, labels, prior, doi, journal, year, question, rationale in [
        ("ohdsi_levetiracetam_phenytoin", "epilepsy", ["KeppraAngioedema/inst/circe/Treatment.json", "KeppraAngioedema/inst/circe/Comparator.json"],
         ["levetiracetam", "phenytoin"], 183, "10.1111/epi.13828", "Epilepsia", 2017,
         "Angioedema risk among new users of levetiracetam compared with phenytoin.", "Antiseizure treatment choice and a 183-day observation requirement."),
        ("ohdsi_alendronate_raloxifene", "osteoporosis", ["AlendronateVsRaloxifene/inst/cohorts/Alendronate.json", "AlendronateVsRaloxifene/inst/cohorts/Raloxifene.json"],
         ["alendronate", "raloxifene"], 365, "10.1038/s41598-020-68037-8", "Scientific Reports", 2020,
         "Fracture effectiveness and safety of alendronate compared with raloxifene in women with osteoporosis.", "Sex-, age- and indication-restricted treatment choice.")]:
        source_files = ["StudyProtocols/" + p for p in files]
        original = [read_json(p) for p in source_files]
        add(study, group, labels, [exposure_set(j)["expression"]["items"] for j in original], prior,
            doi, journal, year, question, rationale, source_files, originals=original)
    for group, ids in [("uti", [1060, 1061, 1062]), ("pneumonia", [1063, 1064])]:
        for a, b in itertools.combinations(ids, 2):
            source_files = [f"PhenotypeLibrary/inst/cohorts/{n}.json" for n in [a, b]]
            originals = [read_json(p) for p in source_files]
            names = {1060: "fluoroquinolone", 1061: "cephalosporin", 1062: "trimethoprim", 1063: "fluoroquinolone", 1064: "cephalosporin"}
            add(f"pl_{group}_{names[a]}_{names[b]}", group, [names[a], names[b]],
                [exposure_set(j)["expression"]["items"] for j in originals], 365, None, None, None,
                f"Antibiotic-class choice in patients with {'urinary tract infection' if group == 'uti' else 'acute typical pneumonia'}.",
                "Acute infection indication using a pair of public treatment phenotypes; not a published comparative-effect replication.",
                source_files, originals=originals, phenotypeIds=[a, b])

    registry = []
    common_changes = ["Outcome cohorts and treatment-effect analyses are not run.",
        "Require adults and a native observation period containing index.",
        "One person per comparison; simultaneous target/comparator initiation is excluded, otherwise keep the earlier eligible index.",
        "SynPUF virtual-site membership adds a patient-specific 365-day landmark, applied after cohort generation.",
        "Covariates end on day -1; first use means first recorded use, not verified lifetime initiation."]
    for number, c in enumerate(candidates, 1):
        group = c["group"]
        changes = list(common_changes)
        if group == "hypertension":
            changes += ["The SQL-defined LEGEND exposure logic is reconstructed as an adapted Circe cohort; original-SQL equivalence is not asserted.",
                "Retain no prior antihypertensive exposure and hypertension in [-365,0].",
                "Replace post-index 7-day ingredient monotherapy selection with no other antihypertensive class/ingredient starting on index day; within-class co-initiation remains possible.",
                "Use DrugExposure first recorded starts and index-day cohort end; original reconstructed exposure eras are not reproduced."]
        elif group == "depression":
            changes += ["Reconstruct the public SQL as DrugEra first use with prior MDD and no prior bipolar disorder or schizophrenia.",
                        "Add symmetric 365-day target/comparator washout; no treatment-effect replication is asserted."]
        elif group == "epilepsy":
            changes += ["Retain 183-day observation and prior seizure-disorder diagnosis; add symmetric 183-day pair washout.",
                        "Outcome-related angioedema exclusions are not part of this PS-only cohort."]
        elif group == "osteoporosis":
            changes += ["Remove the absolute pre-2012-02-01 date restriction and 90-day post-index observation requirement.",
                        "Retain the original >45 female, osteoporosis and clinical exclusion rules; use index-day cohort end."]
        else:
            changes += ["Combine two independent phenotypes into a comparative task; library peer review is pending.",
                        "Add symmetric 365-day pair washout. Same-day indication is retained for phenotype fidelity and flagged for temporal review.",
                        "Systemic formulation cannot be inferred from an ingredient seed alone; source ingredient sets include topical products. Route/formulation diagnostics are mandatory before primary-study adoption."]
        for scenario in ["default", "studySpecific"]:
            for arm in [0, 1]:
                own = c["exposureItems"][arm]
                label = c["target"] if arm == 0 else c["comparator"]
                if scenario == "default":
                    j = cohort(own, label)
                elif group == "osteoporosis":
                    j = copy.deepcopy(c["originals"][arm])
                    j["PrimaryCriteria"]["ObservationWindow"]["PostDays"] = 0
                    for event in j["PrimaryCriteria"]["CriteriaList"]:
                        for data in event.values(): data.pop("OccurrenceStartDate", None)
                    j["EndStrategy"] = {"DateOffset": {"DateField": "StartDate", "Offset": 0}}
                    j["CensorWindow"] = {}
                else:
                    domain = "DrugEra" if group in ["depression", "epilepsy"] else "DrugExposure"
                    j = cohort(own, label, c["priorObservationDays"], domain)
                    wash_items = c["exposureItems"][0] + c["exposureItems"][1]
                    if group == "hypertension":
                        indication = items([316866], concepts)
                        wash_items = items(all_htn, concepts)
                        prior_window = None
                        indication_days = 365
                    elif group == "depression":
                        indication = items([4152280], concepts)
                        prior_window = 365
                        indication_days = None
                    elif group == "epilepsy":
                        indication = items([4029498], concepts)
                        prior_window = 183
                        indication_days = None
                    else:
                        original = c["originals"][arm]
                        indication_id = original["InclusionRules"][0]["expression"]["CriteriaList"][0]["Criteria"]["ConditionOccurrence"]["CodesetId"]
                        indication = next(s for s in original["ConceptSets"] if s["id"] == indication_id)["expression"]["items"]
                        prior_window = 365
                        indication_days = 30
                    j["ConceptSets"].extend([codeset(2, "Indication", indication), codeset(3, "Prior treatment exclusion", wash_items)])
                    j["InclusionRules"].append(rule("Indication before or on index", "ConditionOccurrence", 2, indication_days))
                    # DrugEra overlap captures prior dispensing whose start predates the lookback.
                    wash = rule("No previous treatment in washout", "DrugEra", 3, None, -1, 0)
                    if prior_window is not None:
                        wash["expression"]["CriteriaList"][0]["EndWindow"] = {
                            "Start": {"Days": prior_window, "Coeff": -1}, "End": {"Coeff": 1}}
                    j["InclusionRules"].append(wash)
                    if group == "hypertension":
                        own_ids = {x["concept"]["CONCEPT_ID"] for x in own}
                        j["ConceptSets"].append(codeset(4, "Other antihypertensives", items(set(all_htn)-own_ids, concepts)))
                        j["InclusionRules"].append(rule("No other antihypertensive at initiation", "DrugExposure", 4, 0, 0, 0))
                    if group == "depression":
                        j["ConceptSets"].append(codeset(4, "Bipolar disorder or schizophrenia", items([435783, 436665], concepts)))
                        j["InclusionRules"].append(rule("No prior bipolar disorder or schizophrenia", "ConditionOccurrence", 4, None, 0, 0))
                # Empty null-valued concept attributes are legal but not useful in ATLAS.
                for cs in j["ConceptSets"]:
                    for entry in cs["expression"]["items"]:
                        entry["concept"] = {k: v for k, v in entry["concept"].items() if v is not None}
                save(DEST / "cohorts" / c["study"] / f"{scenario}_{'target' if arm == 0 else 'comparator'}.json", j)
        originals = c.pop("originals", None)
        c.pop("exposureItems")
        c.update(definitionVersion=1, sourceType="phenotypeLibrary" if group in ["uti", "pneumonia"] else "ohdsiStudy",
                 status="candidate_requires_diagnostics", replicationLevel="adapted_ps_benchmark", changes=changes,
                 targetId=200000 + number * 2 - 1, comparatorId=200000 + number * 2,
                 longTermStartDays=-c["priorObservationDays"], shortTermStartDays=-30, endDays=-1,
                 timePolicy="preIndexDay", reviewStatus="Pending peer review" if group in ["uti", "pneumonia"] else "Local implementation requires review",
                 sourceJsonAvailable=originals is not None)
        registry.append(c)
    save(DEST / "registry.json", registry)
    save(DEST / "vocabulary-build.json", {"vocabularyVersions": dict(vocabularies), "patientDataRead": False})
    print(f"Built {len(registry)} studies, {len(registry)*4} cohort JSON files.")


if __name__ == "__main__":
    main()
