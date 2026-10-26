# FederatedPs 0.0.10: 전처리 우선 실행과 기관별 진행 상황

최신 실행기 핫픽스는 [PREPROCESS_FIRST_KO.md](PREPROCESS_FIRST_KO.md)를 참조하십시오.
0.0.10 설치가 완료된 환경에서는 R 패키지 재설치 없이 적용합니다.
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
    .\05_RUN_YUHS.ps1 -Test $false `
        -Study ppi -Scenario default `
        -Methods local-only,pooled `
        -PatientLimits @{1=200; 2=100; 3=300} `
        -ExtractionWorkers 1 `
        -ConnectionCheckTimeoutSeconds 180 `
        -StatusSeconds 10
}
```

- `-ExtractionWorkers 1`: 기본값입니다. 하나의 R 프로세스가 모든 기관의 전처리를 순서대로 완료한 뒤 모델을 계산합니다.
  `2` 또는 `3`을 명시하면 기존 병렬 추출 경로를 사용합니다.
  실행 수는 설정된 기관 수를 넘지 않으며, 1~3 범위에서 지정할 수 있습니다.
  대기열은 숫자 site_id 오름차순입니다. `-Sites`를 명시하면 그 대기열 순서를 사용합니다.
- `-StatusSeconds 10`: 상태 요약과 monitor.log를 10초마다 기록합니다. 기본값 15초.
  화면 진행 표시와 경과 시간은 약 1초마다 갱신합니다. SQL 시작/완료 이벤트는 즉시 기록합니다.
- `-NoProgress`: PowerShell 진행 막대만 끕니다. 상태 요약과 파일 로그는 계속 기록합니다.

기본값 1에서는 단일 R 프로세스가 기관마다 JDBC 연결을 열어 순서대로 SitePartition부터 CohortMethod, 공변량,
최종 설계행렬 및 완료 캐시 생성까지 처리합니다. SQL Server의 `#` 임시 테이블은 연결별로 분리되고,
로컬 SQL 로그·Andromeda 임시 파일·캐시·진행 이력도 기관별로 구분합니다. 새 R 패키지를 추가하지 않습니다.
모든 기관의 완료 입력을 검증한 뒤 모델 계산을 시작합니다. local-only는 기관별 순차 학습,
pooled는 같은 입력을 합쳐 한 번 학습하며, federated 선택 시 기존 분산 실행을 사용합니다.
명시적 병렬 모드에서는 기관마다 독립된 R/JVM을 사용하며, 모든 추출 작업의 정상 종료 후 모델을 계산합니다.
BLAS/OpenMP와 Cyclops의 기존 1-thread 설정을 유지해 기관 병렬화 위에 중첩 병렬화를 추가하지 않습니다.

기관 작업이 실패하거나 제한 시간을 넘기면 이 실행에서 시작한 남은 작업을 정리하고 전체 실행을 실패 처리합니다.
이미 정상 완료된 기관 캐시는 유지합니다. 다음 실행에서 같은 조건의 완료 캐시를 재사용합니다.
모델 프로세스는 기관 작업이 지정한 정확한 캐시 세대를 읽으며, 준비 데이터가 손상/누락되면
자동 재추출이나 다른 캐시로 대체하지 않고 오류를 보고합니다.

## 0/10 Connection self-check 장시간 대기 방지

연결 생성·SELECT 1/세션 ID 확인·CARE_SITE 조회/검증 전체에 기관별
`-ConnectionCheckTimeoutSeconds 180`의 외부 감시를 적용합니다. 첫 JDBC 연결 직전부터
같은 시작 시각을 유지합니다. 초기 확인 쿼리는 자동으로 재시도하지 않습니다.
R 초기 패키지 로딩 시간은 포함하지 않습니다. 병렬 모드와 `-ExtractionWorkers 1` 모두 적용됩니다.

JDBC의 내부 쿼리/네트워크 제한이나 Java 호출이 멈추더라도 PowerShell이 별도로 감시합니다.
초과 시 마지막 JDBC 단계와 시간 초과 기록을 저장하고, 가능한 경우 제한된 시간 내 JVM 스레드 덤프를
수집한 뒤 이 실행의 작업들을 정리하여 실패로 종료합니다. 덤프/프로세스 정리 시간은 180초에 추가됩니다.
`-NoProgress` 또는 화면 모니터 비활성화와 관계없이 감시합니다.

초기 접속부터 `socketTimeout=75000`(기본)을 적용합니다. 각 JDBC 호출도
`SmallQueryTimeoutSeconds + 15`초의 외부 감시를 받으며, 기본값은 75초입니다.
연결 로그인에는 최소 45초의 호출 제한을 허용하되 전체 180초 제한은 유지합니다.
확인 성공 뒤에만 임상 추출용 소켓 제한(기본 7215초)으로 전환합니다.
`setMaxRows(2)`는 드라이버가 별도 `SET ROWCOUNT`를 전송하므로 제거했습니다.
CARE_SITE는 `SELECT TOP (2)`로 제한하여 중복 행 검증을 유지합니다.

`db-startup-watchdog.log`와 화면에는 site_id, 현재 JDBC 호출, 단계 경과 시간,
제한 시간을 기록합니다. 이 제한은 ETA나 분석 진척률이 아닙니다.

진행 이벤트는 `getNetworkTimeout`, `setNetworkTimeout`, `createStatement`, `setQueryTimeout`,
`executeQuery`, `next`, 값 읽기, `close` 등 JDBC 호출 전후를 표시합니다.
따라서 쿼리 실행 중인지, 반환 행 읽기인지, 리소스 정리인지 구분할 수 있습니다.
로그에는 해당 호출 이름만 추가하며 환자 행이나 연결 비밀번호를 추가하지 않습니다.

연결 확인 완료 후에는 이 제한이 해제됩니다. SitePartition·CohortMethod 등에는 기존의
`-DbQueryTimeoutSeconds`(기본 7200초), 전체 분석에는 `-RunTimeoutSeconds`가 적용됩니다.
180초 제한이 분석 데이터 추출을 끊지 않습니다. 캐시/합성 데이터 실행은 DB 확인 감시 대상이 아닙니다.

시간 초과 시 실행 폴더의 `failure.txt`, `db-startup-timeout-<site_id>.json`,
`shutdown-thread-<role>.txt`(생성된 경우), `extraction\<site_id>\db-startup-*.json`을 확인하십시오.
기존 JDBC 쿼리 제한은 60초, 로그인 제한은 30초이며 SSL 설정은 바꾸지 않습니다.
이는 프로그램이 초기 확인에서 무기한 대기하는 경로를 막고 대기 위치를 드러내는 수정입니다.
실제 HIWARE 세션·네트워크·SQL Server의 장애를 자동 복구하거나 연결 성공을 보장하지 않습니다.
[Microsoft의 JDBC timeout 구분](https://learn.microsoft.com/en-us/sql/connect/jdbc/understand-timeouts)을 참고하십시오.

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
`data-ready (cache)`는 기존 캐시 재사용, `data-ready (prepared)`는 기관 작업이 만든 입력을 모델 프로세스가 로드한 상태,
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
- 같은 SQL·기관·DB 설정·study/scenario·환자 제한·동시 실행 수·패키지/드라이버 버전:
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
병목이면 동시 쿼리를 늘려도 빨라지지 않을 수 있습니다. 이번 버전은 최대 세 기관을 겹쳐 실행하여
DB 응답 대기와 로컬 후처리가 겹칠 수 있는 옵션을 제공합니다. 최신 핫픽스의 기본값은 순차 추출입니다.
v0.0.9의 집계/임시 저장 최적화도 유지합니다.
각 연결은 여전히 전체 방문 집계를 수행하므로 세 작업의 동시 스캔·정렬은 DB의 부하를 높일 수 있습니다.
Windows CPU 수치에 따라 동시 실행 수를 자동으로 올리지 않습니다. 세 기관 동시 실행에서 SQL 지연이나
메모리 압박이 커지면 다음 실행에 `-ExtractionWorkers 2` 또는 `1`을 지정하십시오.
실제 YUHS에서의 속도 배수와 최대 메모리 사용량은 측정하지 않았습니다.
원본 CDM에 인덱스를 생성하거나 NOLOCK, 근사 집계, 환자 선정 기준 완화를 사용하지 않습니다.

환자 제한은 여전히 노출 후보 생성 후 CohortMethod 직전에 적용됩니다.
200명으로 제한해도 SitePartition의 전체 방문 집계 자체는 필요합니다.

## 로그 및 재사용

- 병렬 추출 로그: `FederatedPS\work\methods\<RunId>\<site_id>\`의
  `run.stdout.log`, `run.stderr.log`, `progress.jsonl`, `data-cache.json`, `preparation-complete.json`.
- 모델 계산 로그: 같은 실행 폴더의 `baselines\`. 순차 모드에서는 추출 로그도 여기에 기록됩니다.
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
최신 실행기 핫픽스는 0.0.10 완료 캐시를 재사용합니다. 다만 최초 0.0.10 설치 시에는 소스 및 버전 지문이 달라 **v0.0.9 이하 캐시를 자동 재사용하지 않으며 최초 1회 재추출**합니다.
이전 캐시를 삭제하지 않습니다. 이후 v0.0.10에서 조건이 같은 기관의 완료 캐시는 재사용됩니다.
동시 실행 수(1/2/3)만 변경해도 캐시를 재사용하며, 작업 ETA 이력은 해당 동시 실행 수별로 구분합니다.
SitePartition 중간 상태는 체크포인트가 아니므로 중단 후에는 해당 기관 추출을 다시 시작합니다.

## 검증 범위

Linux의 R 4.3.3 및 PowerShell 7에서 SQL 작업 순서/오류 전달/최종 커밋 호출,
기관별 상태 및 ETA의 범위, 부분 로그 처리, 실제 프로세스의 1/2/3개 동시 실행 제한,
모든 준비 완료 후 모델 실행, 정상 종료/완료 기록 검증, 실패 시 대기열 중단 및 프로세스 정리,
환자 및 캐시 계약을 검사합니다. SQLite로 변환한 동치성 테스트에서 기존/새 기관 분할의
환자·방문 행과 다기관 환자 집계를 비교합니다.
Windows Server R 4.6.1, 실제 HIWARE 연결, SQL Server 실행 계획 및 네이티브 Cyclops를
이 환경에서 통합 실행한 것은 아닙니다.

공식 참고 자료: [R의 Windows 프로세스 병렬화](https://stat.ethz.ch/R-manual/R-devel/library/parallel/html/makeCluster.html),
[Microsoft SQL Server 실행/대기 시간 진단](https://learn.microsoft.com/troubleshoot/sql/database-engine/performance/troubleshoot-slow-running-queries).
