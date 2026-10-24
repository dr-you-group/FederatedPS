-- SynPUF person_id and state of residence, used to split SynPUF into sites by state.
-- psql ... -c "\copy (<this query>) to '$FP_DATA/synpuf_state.csv' csv"
SELECT p.person_id, l.state
FROM synpuf.person p
LEFT JOIN synpuf.location l ON l.location_id = p.location_id
ORDER BY p.person_id;
