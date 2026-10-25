# FederatedPs 0.0.9: 기관별 진행 상황과 추출 성능

이 업데이트는 기존 YUHS 오프라인 환경에서 FederatedPs 소스 패키지만 다시 설치합니다.
Cyclops proximal CCD, R, Java, JDBC를 다시 설치하지 않습니다.
`windows/common.R`의 SSL 수정, `yuhs.Renviron`, 결과 및 캐시 파일을 덮어쓰지 않습니다.

## 적용과 실행

실행 중인 분석에는 새 코드가 소급 적용되지 않습니다. 현재 분석이 종료된 뒤
R/RStudio를 닫고 ZIP을 별도 폴더에 풀어 적용합니다. 실행 중인 프로세스는 자동 종료하지 않습니다.

```powershell
& {
    $ErrorActionPreference = 'Stop'
    .\APPLY_UPDATE.ps1 -BundleRoot 'C:\FederatedPS_YUHS_Offline'
    cd C:\FederatedPS_YUHS_Offline
    .\08_UPDATE_PACKAGE.ps1
    .\05_RUN_YUHS.ps1 -Test $false `
        -Study ppi -Scenario default `
        -Methods local-only,pooled `
        -PatientLimits @{1=200; 2=100; 3=300} `
        -StatusSeconds 10
}
```

- 기관별 추출은 순차 실행합니다. 기본 순서는 설정된 숫자 site_id의 오름차순이며,
  현재 설정에서는 1 → 2 → 3입니다. `-Sites`를 명시하면 그 순서를 사용합니다.
- `-StatusSeconds 10`: 상태 요약과 monitor.log를 10초마다 기록합니다. 기본값 15초.
  화면 진행 표시와 경과 시간은 약 1초마다 갱신합니다. SQL 시작/완료 이벤트는 즉시 기록합니다.
- `-NoProgress`: PowerShell 진행 막대만 끕니다. 상태 요약과 파일 로그는 계속 기록합니다.

동시에 DB를 추출하는 기관은 하나입니다. local-only 모델들도 순차 학습하며,
pooled 모델은 같은 기관별 입력을 합쳐 한 번 학습합니다. federated 선택 시 기존 분산 실행을 사용합니다.
순서는 기관별 추출·캐시 저장(1 → 2 → 3), 선택된 local-only 학습(1 → 2 → 3),
선택된 pooled 학습입니다. 기관 하나의 추출이 완료되어야 다음 기관 추출을 시작합니다.
SQL/Andromeda 임시 파일과 완료 캐시는 기관별로 구분합니다.

## 기관별 화면 읽기

기관 이름은 설정 파일의 표시 이름을 읽으며, 모든 추적과 옵션의 기준은 숫자 site_id입니다.
예시의 시간과 문장 수는 화면 설명용이며 실제 벤치마크가 아닙니다.

```text
[site_id=1 (...)] extracting | SitePartition.sql SQL 2/7: Index patient-to-institution membership
  extraction stage 1/10 | SQL done 1/7 = 14% of statements | elapsed 00:02:31
[site_id=2 (...)] queued: extraction has not started
[site_id=3 (...)] queued: extraction has not started
```

`queued`는 아직 시작하지 않은 상태입니다. `data-ready`는 추출과 캐시 저장 완료,
`data-ready (cache)`는 기존 캐시 재사용,
`local-fitting`은 해당 기관 모델 학습, `local-complete`는 해당 모델 검증 완료입니다.
pooled 작업은 공통 baselines 행에 표시됩니다. 최종 성공은 SUCCESS.txt로 판정합니다.

SitePartition은 집계, membership 인덱스, 기관별 환자 선택, 환자 인덱스,
방문 복사, 방문 ID 인덱스, 환자 ID 인덱스의 7개 문장으로 표시됩니다.
CohortMethod 등도 실제 설치된 SQL을 SqlRender로 분리한 문장별 시작·완료를 표시합니다.
SQL 문장 실행 순서와 JDBC의 기존 최종 커밋 경계는 유지합니다. 실패 시 재실행하지 않습니다.
SQL 반환 시 드라이버가 제공한 영향 행 수 또는 조회 결과 행 수를 기록합니다.
집계된 환자·방문 수 및 도메인별 연결 제외 건수도 확인되는 즉시 출력합니다.

`1/10`은 추출 단계 번호, `1/7`은 해당 SQL 묶음에서 완료된 문장 수입니다.
문장마다 비용이 다르므로 이 비율은 처리 행 수나 전체 소요 시간의 비율이 아닙니다.
단일 GROUP BY/SELECT 실행 도중의 처리 행 수·처리율은 이 연결에서 제공되지 않습니다.
경과 시간과 살아 있는 R 프로세스만으로 DB가 연산 중인지 잠금/I/O 대기 중인지 구분하지 않습니다.

## ETA

- 최초 실행 SQL: 같은 조건의 완료 기록이 없어 ETA가 없다는 이유를 표시합니다.
- 같은 SQL·기관·DB 설정·study/scenario·환자 제한·패키지/드라이버 버전:
  최근 최대 5개 정상 완료 기록의 중앙값으로 **현재 작업의** 예상 시간을 표시합니다.
- 과거 예상 시간을 이미 넘긴 요청: `historical duration exceeded; remaining ETA unavailable`.
  실행 중인데 ETA를 0초로 표시하지 않습니다.
- CCD: 현재 sweep의 좌표 수와 속도로 추정한 ETA를 표시합니다. 전체 수렴 시간의 ETA가 아닙니다.
- 전체 분석 ETA: 서로 다른 SQL 비용과 미정인 수렴 횟수 때문에 확정하지 않습니다.

과거 기록은 예측 참고값이며 DB 부하·데이터 증가에 따라 실제 시간은 달라질 수 있습니다.
이력은 `FederatedPS\work\progress-history`에 식별용 해시·시간만 저장합니다.
SQL 본문·환자 행·접속 비밀번호는 이력에 저장하지 않습니다. 이력 손상은 분석 성공 여부에 영향을 주지 않습니다.

## 적용한 성능 변경과 한계

1. 양수 care_site_id의 최솟값과 최댓값이 같으면 단일 기관 환자입니다.
   이 동치 조건으로 DISTINCT 집계를 대체합니다. 여러 기관 방문자 제외와 전체 CDM의
   다기관 환자 수 집계는 동일하게 유지됩니다. NULL/0/음수 및 설정 외 기관 ID 처리도 같습니다.
2. `#fps_visit`에 모든 열을 복사하던 대신 후속 SQL이 사용하는 6개 열만 저장해
   임시 테이블 및 인덱스의 데이터 폭을 줄였습니다.
분석 Windows 인스턴스의 CPU는 SQL Server의 CPU와 다릅니다. 공유 DB의 I/O·메모리·tempdb가
병목이면 동시 쿼리를 늘려도 빨라지지 않을 수 있습니다. 이번 버전은 기관별 순차 추출을 유지하면서
집계 및 임시 저장 작업량을 줄입니다. 실제 YUHS에서의 속도 배수는 측정하지 않았습니다.
원본 CDM에 인덱스를 생성하거나 NOLOCK, 근사 집계, 환자 선정 기준 완화를 사용하지 않습니다.

환자 제한은 여전히 노출 후보 생성 후 CohortMethod 직전에 적용됩니다.
200명으로 제한해도 SitePartition의 전체 방문 집계 자체는 필요합니다.

## 로그 및 재사용

- 실행 로그: `FederatedPS\work\methods\<RunId>\baselines\`의
  `run.stdout.log`, `run.stderr.log`, `progress.jsonl`.
- SQL 원문/문장 계획/소요 시간: `extraction\<site_id>\sql-diagnostics\`.
  `*-plan.tsv`, `*.sql`, `operations.tsv`, `connection.tsv`를 함께 확인합니다.
- 기관별 최신 상태: 각 로그 폴더의 `sites\<site_id>.json`.
- 통합 상태 기록: 실행 폴더의 `monitor.log`.

별도 창에서 읽기 전용으로 보기:

```powershell
.\FederatedPS\windows\Watch-FederatedRun.ps1 `
    -RunDirectory 'C:\FederatedPS_YUHS_Offline\FederatedPS\work\methods\실제_RunId' `
    -StatusSeconds 10
```

이 뷰어의 Ctrl+C는 분석을 종료하지 않습니다. 기존 프로세스에는 새 SQL 세부 이벤트가 생기지 않습니다.
v0.0.9는 소스 및 버전 지문이 달라 **v0.0.8 캐시를 자동 재사용하지 않으며 최초 1회 재추출**합니다.
이전 캐시를 삭제하지 않습니다. 이후 v0.0.9에서 조건이 같은 기관의 완료 캐시는 재사용됩니다.
SitePartition 중간 상태는 체크포인트가 아니므로 중단 후에는 해당 기관 추출을 다시 시작합니다.

## 검증 범위

Linux의 R 4.3.3 및 PowerShell 7에서 SQL 작업 순서/오류 전달/최종 커밋 호출,
기관별 상태 및 ETA의 범위, 부분 로그 처리, 순차 실행 경로 및 실패 처리,
환자 및 캐시 계약을 검사합니다. SQLite로 변환한 동치성 테스트에서 기존/새 기관 분할의
환자·방문 행과 다기관 환자 집계를 비교합니다.
Windows Server R 4.6.1, 실제 HIWARE 연결, SQL Server 실행 계획 및 네이티브 Cyclops를
이 환경에서 통합 실행한 것은 아닙니다.
