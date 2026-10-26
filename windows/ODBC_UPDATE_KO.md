# FederatedPS ODBC 오프라인 업데이트

기존 Windows 폐쇄망 번들(예: `C:\FP`)을 JDBC 대신 Microsoft ODBC로 실행하는 업데이트입니다. R 4.6.1, Temurin 17, 기존 OHDSI 패키지와 proximal CCD Cyclops가 설치된 환경에 적용합니다. 새 Windows 인스턴스를 위한 전체 런타임 설치본은 아닙니다.

## 적용 순서

1. ZIP 전체를 폐쇄망에 반입하고 `C:\FP_ODBC_Update`처럼 기존 번들과 다른 폴더에 압축을 풉니다.
2. 분석과 RStudio/R 세션을 종료합니다. HIWARE는 기존 방식대로 로그인해 둡니다.
3. **관리자 권한의 64비트 Windows PowerShell**에서 다음을 실행합니다.

```powershell
Set-Location C:\FP_ODBC_Update
.\APPLY_ODBC.ps1 -BundleRoot 'C:\FP' -InstallRoot 'C:\FederatedPS'
```

실행 순서는 소스/스크립트 백업 및 덮어쓰기 → ODBC 드라이버와 R 의존성 오프라인 설치 → 기존 설정에 `DB_BACKEND=odbc` 추가 → FederatedPs 재설치 → ODBC 진단입니다. 기존 RUN.ps1의 편집 여부 때문에 중단하지 않습니다. 접속 주소·계정·비밀번호·TLS 선택과 분석 결과는 유지합니다. 변경 전 파일은 기존 번들의 `patch-backups`에 보관됩니다. 이 폴더에는 접속 설정 백업도 있으므로 외부로 전달하지 마십시오.

설치 프로그램이 재부팅을 요청하면 재부팅 후 HIWARE에 다시 로그인하고 같은 명령을 재실행합니다. 인터넷 다운로드나 R 소스 의존성 컴파일은 하지 않습니다.

HIWARE에 아직 로그인하지 못했다면 설치만 먼저 할 수 있습니다.

```powershell
.\APPLY_ODBC.ps1 -BundleRoot 'C:\FP' -SkipConnectionCheck
# HIWARE 로그인 후
Set-Location C:\FP
.\CHECK_ODBC.ps1
```

진단 두 단계 모두 PASS로 끝나면 분석합니다.

```powershell
Set-Location C:\FP
.\RUN.ps1
```

`RUN.ps1`은 매번 ODBC 진단을 먼저 수행하고, 정상 종료가 확인된 경우에만 다음 옵션으로 실제 YUHS 분석을 시작합니다.

```powershell
.\05_RUN_YUHS.ps1 -Test $false -DbBackend odbc `
    -Study ppi -Scenario default `
    -Methods local-only,pooled `
    -PatientLimits @{1=2; 2=2; 3=2} `
    -ExtractionWorkers 1 -StatusSeconds 10
```

환자 상한만 바꾸려면 `RUN.ps1 -PatientLimits @{1=200;2=100;3=300}`을 실행합니다. 상한 2명은 빠른 실행 확인용입니다. 기관별 치료군·비교군 또는 모델 적합에 필요한 환자 수가 부족하면 데이터 검증/모델 단계에서 중단될 수 있으며, 이는 접속 성공 여부와 별개입니다.

## 접속 설정

기존 파일 `C:\FP\FederatedPS\windows\config\yuhs.Renviron`을 사용합니다.

```text
DB_BACKEND=odbc
DB_ODBC_DRIVER="ODBC Driver 18 for SQL Server"
```

`DB_ODBC_DRIVER`가 없으면 Driver 18을 선택합니다. 기존 `DB_SERVER`, `DB_PORT`, `DB_DATABASE`, `DB_USER`, `DB_PASSWORD`, `CDM_DATABASE_SCHEMA`를 그대로 사용합니다. DSN 생성은 필요하지 않습니다. HIWARE를 거치던 주소를 직접 DB 주소로 바꾸지 않습니다.

TLS도 기존 설정을 그대로 매핑합니다. 기존 DBeaver SSL 해제 선택을 사용하던 파일에 아래 값이 있으면 ODBC에서도 `Encrypt=no`, `TrustServerCertificate=no`로 전달합니다.

```text
DB_ENCRYPT=false
DB_TRUST_SERVER_CERTIFICATE=false
```

업데이트는 이 값을 강제로 바꾸지 않습니다. `DB_ENCRYPT`가 없는 설정은 기존 패키지와 동일하게 암호화 사용을 기본값으로 합니다. 서버가 암호화를 강제하는 경우 서버 정책이 우선합니다. JDBC JAR 경로는 ODBC 연결에 사용되지 않습니다.

## 진단이 검사하는 것

`CHECK_ODBC.ps1`은 서로 다른 두 R 프로세스를 순서대로 실행합니다.

- `native`: Java를 로드하지 않고 R의 DBI/odbc로 연결합니다.
- `production`: SqlRender JVM을 먼저 사용한 뒤 DatabaseConnector의 DBI 연결과 패키지의 CARE_SITE 검사 경로를 사용합니다.

각 프로세스는 `SELECT 1`, 세 기관의 CARE_SITE_ID, 동일 세션 유지, 한글·NULL·64비트 정수 변환, 임시 테이블 생성/조회/삭제, 연결 해제, **R 프로세스의 정상 종료 코드 0**까지 검사합니다. 임시 테이블에는 만들어낸 값 한 행만 넣으며 CDM 원본에 쓰지 않습니다. CARE_SITE 이름이나 환자 행을 진단 파일에 저장하지 않습니다.

조회가 끝났어도 종료 중 멈추면 실패입니다. 기본 180초의 전체 진단 제한을 넘으면 진단이 만든 프로세스만 종료합니다. 로그인 제한 시간은 30초이며 전체 진단 제한과 다릅니다. 자동 재시도나 JDBC로의 자동 전환은 하지 않습니다.

필요하면 두 경로를 따로 확인합니다.

```powershell
.\CHECK_ODBC.ps1 -Mode native
.\CHECK_ODBC.ps1 -Mode production
```

화면에 표시되는 `FederatedPS\work\diagnostics\odbc-*` 폴더에 단계별 `events.ndjson`, `status.json`, `process.json`, `summary.json`이 남습니다. 원시 드라이버 오류에는 비밀번호나 접속 정보가 포함될 수 있으므로 원시 stdout/stderr는 저장하지 않습니다. 진단 실패 시 이 ODBC 진단 폴더를 확인하거나 전달하면 됩니다. 실제 `.Renviron`, `patch-backups`, 환자 데이터는 포함하지 마십시오.

## 분석 경로의 변경

DB 연결·SQL 실행·결과 읽기는 Microsoft ODBC를 사용합니다. SqlRender는 계속 Java를 사용하므로 Java 설치는 필요합니다. 기관 분할 SQL, 환자 상한, local-only/pooled/federated 계산과 고정된 proximal CCD Cyclops 소스는 유지합니다.

ODBC의 `dbConnect(timeout=...)`는 로그인 시간 제한입니다. 분석 중 SQL 실행·fetch는 독립된 PowerShell 감시자가 `DbQueryTimeoutSeconds` 기준으로 감시하며, 연결 종료에는 짧은 작업 제한(기본 75초)을 적용합니다. 화면의 경과 시간과 제한 시간은 예상 완료 시간이 아닙니다. DB 서버가 실제 완료율을 제공하지 않는 작업에는 가짜 ETA를 표시하지 않습니다.

64비트 ID는 ODBC에서 정확히 읽습니다. 기존 분석의 double 변환으로 정밀도를 잃을 수 있는 범위(절댓값 2^53 초과)는 조용히 반올림하지 않고 중단합니다. 해당 데이터셋은 별도의 ID 표현 수정이 필요합니다.

완성된 데이터 캐시는 기존 재사용 규칙을 따릅니다. 이번 버전/설정 변경은 캐시 호환성 검사에 반영되므로 이전 추출 캐시를 다시 만들 수 있습니다. 실행 중인 임시 SQL 테이블이나 불완전한 추출을 완료된 캐시로 취급하지 않습니다.

## 포함 파일과 검증 범위

- `APPLY_ODBC.ps1`, 소스 덮어쓰기 도구, 전체 FederatedPS 저장소 소스 및 패키지 소스 아카이브
- ODBC용 RUN/CHECK/설치/진단 스크립트와 이 문서
- Microsoft ODBC Driver 18.7.1.1 x64 MSI
- R 4.6.1 Windows용 `odbc 1.7.2`와 필수 의존성 13개 ZIP
- 선택 설치용 VC++ x64 재배포 파일(Driver 18.7은 별도 사전 설치가 필요하지 않아 기본으로 실행하지 않음)
- 설치 파일의 버전·출처·해시 기록

수정 가능한 RUN/소스 파일에 예전 해시와 일치하라는 조건을 걸지 않습니다. 새로 반입하는 바이너리 설치 파일의 손상 여부와 Microsoft 서명은 실행 전에 확인합니다.

로컬에서 R 로직, PowerShell 구문·프로세스 감시·설정 전달·설치 분기를 검증했습니다. 개발 환경의 R/PowerShell 검증은 Windows R 4.6.1 + 실제 HIWARE/SQL Server 실행을 대체하지 않습니다. **실제 폐쇄망 연결 성공은 반입 후 CHECK_ODBC 두 단계 결과로 확인해야 합니다.** 이 업데이트가 HIWARE 자체의 모든 로딩 문제를 해결했다고 단정하지 않습니다.

공식 참고: [ODBC 다운로드](https://learn.microsoft.com/en-us/sql/connect/odbc/download-odbc-driver-for-sql-server), [R odbc 연결](https://odbc.r-dbi.org/reference/dbConnect-OdbcDriver-method.html), [DatabaseConnector DBI 연결](https://ohdsi.github.io/DatabaseConnector/reference/createDbiConnectionDetails.html).
