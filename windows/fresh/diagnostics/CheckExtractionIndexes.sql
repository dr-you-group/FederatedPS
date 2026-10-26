-- Read-only metadata check; paste into DBeaver on the same YUHS connection.
-- No server-performance DMV or VIEW SERVER PERFORMANCE STATE is used.
-- Change the database/schema identifiers if the local CDM name differs.
-- These results contain table/index metadata, not patient rows.
SELECT s.name AS schema_name, t.name AS table_name, i.name AS index_name,
       i.type_desc, i.is_unique, i.is_disabled, i.has_filter, i.filter_definition,
       ic.key_ordinal, ic.is_included_column, c.name AS column_name
FROM CDM54_2601.sys.tables t
JOIN CDM54_2601.sys.schemas s ON s.schema_id = t.schema_id
LEFT JOIN CDM54_2601.sys.indexes i ON i.object_id = t.object_id
LEFT JOIN CDM54_2601.sys.index_columns ic
  ON ic.object_id = i.object_id AND ic.index_id = i.index_id
LEFT JOIN CDM54_2601.sys.columns c
  ON c.object_id = ic.object_id AND c.column_id = ic.column_id
WHERE s.name = 'CDM' AND t.name IN
  ('VISIT_OCCURRENCE','DRUG_EXPOSURE','CONCEPT_ANCESTOR','PERSON','OBSERVATION_PERIOD')
ORDER BY t.name, i.index_id, ic.key_ordinal, ic.index_column_id;

-- Confirm whether the named objects are tables, views or synonyms. A missing
-- metadata row does not prove that an object/index is absent (visibility varies).
SELECT s.name AS schema_name, o.name AS object_name, o.type_desc,
       sy.base_object_name
FROM CDM54_2601.sys.objects o
JOIN CDM54_2601.sys.schemas s ON s.schema_id = o.schema_id
LEFT JOIN CDM54_2601.sys.synonyms sy ON sy.object_id = o.object_id
WHERE s.name = 'CDM' AND o.name IN
  ('VISIT_OCCURRENCE','DRUG_EXPOSURE','CONCEPT_ANCESTOR','PERSON','OBSERVATION_PERIOD');
