# SQL 실행 병목 수정: sql-plan-4

이전 `SitePartition SQL 1/7`은 전체 VISIT_OCCURRENCE에서 모든 양수 CARE_SITE_ID를
환자별 MIN/MAX로 집계했습니다. 환자 상한은 훨씬 뒤에 적용되므로 200명 테스트도
전체 방문 집계, 기관 환자 전체의 방문 복사와 약제 조회를 먼저 수행했습니다.
이 작업은 기관별로 반복되었습니다. 0%는 완료된 SQL 문장이 0개라는 뜻으로,
실행 중인 쿼리가 실제로 행을 읽고 있는지 또는 기다리는지는 나타내지 못했습니다.

## 새 실행 순서

| 순서 | SQL / 처리 | 읽거나 만드는 범위 |
| --- | --- | --- |
| 1 | StudyConcepts.sql | 연구 약제의 ingredient/ATC/descendant 매핑; vocabulary 테이블 |
| 2 | SitePartition.sql, 4개 문장 | 해당 기관에서 날짜·환자·방문 연결이 유효한 연구 약제 노출 환자를 찾고, 다른 양수 기관 방문자를 제외 |
| 3 | LimitPartitionPatients.sql | default + 환자 제한이 있을 때 기존 규칙과 같은 환자를 조기 선택 |
| 4 | SiteVisits.sql, 3개 문장 | 준비된 환자의 해당 기관 방문 전체를 복사하고 임시 인덱스 생성 |
| 5 | 집계·연결성 점검, StudyDrugs.sql | 준비된 환자의 레코드와 모든 관련 과거 약제 노출 |
| 6 | DefaultStudy / SpecificStudy → LimitPatients → CohortMethod → Covariates | 기존 적격성·최초 노출·washout·관찰기간·공변량 조건 적용 |

현재 RUN의 default 설정에서는 site_id 1/2/3의 방문 복사에 들어가기 전에 각각
200/100/300명 상한이 적용됩니다. 처음 약제 후보를 찾거나 다른 기관 방문을 검사하는
조회 자체는 더 많은 행을 읽을 수 있습니다. 200명 제한을 모든 원본 테이블의
200행 조회로 해석하면 안 됩니다. 정확한 후보 선택에 필요한 조회는 남습니다.

전체 CDM의 환자별 기관 집계는 제거했습니다. 순차 추출 1개와 기존 분석 옵션을 유지합니다.
명시적으로 병렬 추출을 늘리면 DB 동시 쿼리가 늘어나므로 클라이언트의 낮은 CPU만 보고
동시 실행 수를 높이지 마십시오. 원격 SQL Server에서 실행되는 쿼리의 부담은 Windows
분석 인스턴스의 CPU/메모리 수치로 판별할 수 없습니다.

## 선택 기준을 유지하는 이유

- 기존 분석에 들어가는 사람은 반드시 해당 기관의 유효한 연구 약제 노출을 갖습니다.
  이 필요조건으로 후보를 먼저 좁혀도 기존 분석 대상은 제외되지 않습니다.
- 다른 기관 방문 여부는 연구 약제 노출과 관계없이 모든 양수 CARE_SITE_ID에 대해 확인합니다.
  설정된 세 기관 밖의 4/17/99 등도 제외 판단에 포함하며 NULL/0/음수 처리는 유지합니다.
- default의 첫 치료군은 가장 이른 target/comparator 노출일로 정하고 같은 날이면 target을
  먼저 둡니다. 각 군 안에서 person_id 순으로 정렬하고 군을 번갈아 선택하는 기존
  LimitPatients 규칙과 같습니다. 선택한 사람의 나머지 방문/노출 이력은 버리지 않습니다.
- studySpecific은 적격성 판단 뒤에 후보가 달라질 수 있어 조기 상한을 적용하지 않습니다.
  기존대로 SpecificStudy를 마친 다음 환자 상한을 적용합니다.

동일한 CDM 스냅샷을 전제로 합성/무작위 fixture 49개 조건에서 이전/새 경로의 노출,
선택 환자의 전체 방문 및 약제 이력이 일치함을 검증했습니다. 104개 SQL 준비 조합도
검사했습니다. 실제 SQL Server의 실행 계획이나 Windows/HIWARE 소요시간을 측정한 것은 아닙니다.

## 진행 표시와 감사 집계

실행 중인 SQL의 행 진행률은 알 수 없으므로 화면에서 정지한 0% 막대 대신
`SQL 1/4, done 0/4; rows unknown`과 경과 시간을 표시합니다.
완료한 문장 수와 각 기관의 단계는 계속 표시합니다. 첫 실행에서 ETA를 임의로 추정하지 않습니다.

실제 DB의 `sitePartition`에는 studyCandidatesAtSite, preparedPersons, linkedVisits,
earlyPatientLimit, auditScope를 기록합니다. 전체 CDM 집계를 위해 다시 전체 방문을 읽지
않도록 multisitePersonsAllCdm와 unattributedVisitsAllCdm는 NA(미집계)로 둡니다.
recordLinkage도 준비된 환자 범위의 집계이며 auditScope를 포함합니다.
이 수치를 기관 전체 환자 수로 해석하지 마십시오. 합성 데이터의 기존 감사 집계는 그대로입니다.

## 그래도 특정 SQL이 오래 걸리는 경우

쿼리 구조의 비효율은 수정했지만 SQL 1/x 표시만으로 잠금, 디스크 I/O, 실행 계획,
인덱스 부족 또는 JDBC/네트워크 대기를 구분할 수는 없습니다. timeout을 늘리거나
자동 재시도하는 대신 로그의 정확한 SQL 파일과 SPID를 기준으로 확인해야 합니다.

DBeaver에서 `diagnostics/CheckExtractionIndexes.sql`을 열어 같은 DB 연결로 실행하십시오.
VIEW SERVER PERFORMANCE STATE를 사용하는 DMV 대신 테이블/인덱스 카탈로그를 조회합니다.
접근 가능한 메타데이터만 반환하며 환자 행은 조회하지 않습니다. 빈 결과는 권한/뷰/synonym
등의 영향일 수도 있으므로 인덱스가 없다고 단정하면 안 됩니다.

DBA가 실제 계획과 함께 살펴볼 키는 VISIT_OCCURRENCE의 visit_occurrence_id 및
(person_id, care_site_id), DRUG_EXPOSURE의 drug_concept_id/person_id/visit_occurrence_id,
CONCEPT_ANCESTOR의 ancestor_concept_id/descendant_concept_id입니다. 기존 인덱스 구성과
선택도에 따라 적절한 순서가 달라집니다. 패키지는 원본 CDM 인덱스를 만들거나 변경하지 않습니다.

실행 중 스레드/SQL/로그 수집:

```powershell
.\09_COLLECT_DIAGNOSTICS.ps1 -RunDirectory '화면에 표시된 Output 전체 경로'
```

관련 공식 문서:
- https://learn.microsoft.com/en-us/sql/relational-databases/sql-server-index-design-guide
- https://learn.microsoft.com/en-us/sql/relational-databases/security/metadata-visibility-configuration
- https://learn.microsoft.com/en-us/troubleshoot/sql/database-engine/performance/understand-resolve-blocking
