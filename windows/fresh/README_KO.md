# FederatedPS 새 Windows Server 폐쇄망 설치본

2026-10-26, Windows Server 2022 x64용. R, Rtools, Java, RStudio, R 라이브러리가
설치되지 않은 새 인스턴스에서 시작합니다. 이 ZIP에는 실제 설치 파일과 Windows용
R 패키지 ZIP, 고정 Cyclops 소스, JDBC, FederatedPS 전체 소스가 들어 있습니다.
인터넷 연결 PC에서 00_BUILD_ONLINE을 실행하거나 기존 서버의 R 라이브러리를 복사할 필요가 없습니다.

이 배포본의 `SETUP.ps1`은 로컬 파일만 사용합니다. Windows 자체와 HIWARE 프로그램·로그인,
기관 내부 네트워크/방화벽, DB 계정 및 접근 권한은 해당 기관에서 준비해야 합니다.
HIWARE는 기관 배포 파일이 필요한 별도 제품이므로 이 ZIP에 포함하지 않습니다.
DB 비밀번호와 실제 환자 데이터는 들어 있지 않습니다.

## 1. 반입과 압축 해제

배포 파일은 아래 **3개 ZIP 전부**를 반입합니다. 각 ZIP은 독립적으로 압축 해제할 수 있으며,
세 파일을 이어 붙이는 방식이 아닙니다.

- `FederatedPS_YUHS_Fresh_2026-10-26_A_Core.zip`: 설치/실행 스크립트, R, Java, R 패키지, 저장소, JDBC.
- `FederatedPS_YUHS_Fresh_2026-10-26_B_Rtools.zip`: Rtools45 설치 파일.
- `FederatedPS_YUHS_Fresh_2026-10-26_C_RStudio.zip`: RStudio Desktop 설치 파일.

각 ZIP의 **압축 해제 대상을 모두 `C:\`로 지정**합니다. 내부의 같은 최상위 폴더가 합쳐져
아래 경로가 만들어집니다. ZIP 이름별 하위 폴더에 따로 풀면 SETUP이 필요한 파일을 찾지 못합니다.
00 검사가 세 ZIP의 모든 파일을 확인하므로, 압축을 모두 푼 다음 설치를 시작하십시오.

```text
C:\FederatedPS_YUHS_Offline\SETUP.ps1
C:\FederatedPS_YUHS_Offline\RUN.ps1
C:\FederatedPS_YUHS_Offline\installers\
C:\FederatedPS_YUHS_Offline\packages\
C:\FederatedPS_YUHS_Offline\FederatedPS\
```

기존 번들 위에 덮어쓰는 업데이트용이 아닙니다. 새 빈 폴더에 풉니다.
ZIP과 압축 해제본, Rtools 및 패키지 빌드 공간을 합쳐 설치용 여유 공간 약 12~15GB를 확보하십시오.
이후 실제 CDM 추출 결과·캐시의 크기는 별도이며 데이터에 따라 달라집니다.

## 2. 한 번에 설치하고 합성 데이터로 확인

**관리자 권한의 64비트 Windows PowerShell 5.1**에서 실행합니다.
먼저 켜 놓은 R/RStudio 창이 있으면 닫습니다.

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
cd C:\FederatedPS_YUHS_Offline
.\SETUP.ps1
```

SETUP은 아래 단계를 순서대로 실행합니다. 하나라도 실패하면 다음 단계로 넘어가지 않습니다.

| 순서 | 스크립트 | 작업 |
|---|---|---|
| 00 | `00_VERIFY.ps1` | 설치/의존 파일 SHA-256·크기와 패키지 목록 검사, 로컬 소스 변경 표시 |
| 01 | `01_INSTALL_RUNTIME.ps1` | R 4.6.1, Rtools45, Temurin JDK 17, RStudio Desktop 설치 |
| 02 | `02_INSTALL_PACKAGES.ps1` | Windows 바이너리 의존 패키지 설치, 고정 Cyclops 소스 빌드, FederatedPs/JDBC 설치 |
| 03 | `03_VERIFY_RUNTIME.ps1` | R·패키지·proximal CCD 확인 및 DB 없는 SQL 렌더링 검사 |
| 04 | `04_TEST_SYNTHETIC.ps1` | 가상 3기관 데이터로 local-only/pooled 실행 및 결과 검증 |

RStudio 설치 마법사가 열리면 기본 경로로 설치를 마치고 RStudio는 닫아 두십시오.
RStudio를 설치하지 않을 경우 `.\SETUP.ps1 -SkipRStudio`를 사용해도 분석은 가능합니다.
RStudio 공식 Windows 다운로드 대상은 Windows 11이며, Windows Server 2022의 GUI 호환성은
대상 서버에서 확인해야 합니다. RStudio Server는 Windows용이 아니므로 포함하지 않습니다.

설치 프로그램이 재부팅을 요청하면 SETUP이 중단됩니다. Windows를 다시 시작한 뒤
같은 명령을 실행합니다. 이미 있는 런타임과 동일 버전 의존 패키지는 확인 후 재사용합니다.
02를 다시 실행하면 지정된 Cyclops/FederatedPs를 다시 빌드할 수 있습니다.
빌드 로그에 경고가 있더라도 최종 종료 코드와 `PASS`/`SUCCESS.txt`를 기준으로 판단합니다.

기본 설치 위치:
- R: `C:\Program Files\R\R-4.6.1`
- Rtools: `C:\rtools45`
- Java: `C:\Program Files\Eclipse Adoptium\jdk-17*`
- R 바이너리 라이브러리: `C:\FederatedPS\RLibrary\4.6`
- 고정 Cyclops/FederatedPs: `C:\FederatedPS\RLibrary\windows-block`
- JDBC: `C:\FederatedPS\jdbc\sqlserver`

## 3. HIWARE와 실제 YUHS 접속 설정

기관에서 제공하는 HIWARE 프로그램을 설치·설정하고 로그인한 상태에서 진행합니다.
DB 접속이 가능한 Windows 사용자로 PowerShell을 열어 아래를 실행합니다.

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
cd C:\FederatedPS_YUHS_Offline
.\06_CONFIGURE_DB.ps1
```

메모장에서 `DB_SERVER`, `DB_PORT`, `DB_USER`, `DB_PASSWORD`를 채우고 저장합니다.
기본 데이터베이스/스키마는 `CDM54_2601` / `CDM54_2601.CDM`입니다.
파일 위치는 `FederatedPS\windows\config\yuhs.Renviron`입니다. 이 파일을 외부로 보내지 마십시오.

이 구성 스크립트가 처음 만드는 설정은 앞서 사용한 DBeaver의 **Use SSL 해제**에 맞춰
`DB_ENCRYPT=false`입니다. 서버에서 암호화를 강제하면 서버 정책이 우선합니다.
필요하면 `DB_ENCRYPT=true`와 적절한 인증서 신뢰 설정을 사용하십시오.
`DB_TRUST_SERVER_CERTIFICATE=false`가 기본이며 설정값은 true/false만 허용됩니다.
기존 설정 파일은 다시 실행해도 덮어쓰지 않습니다.

`yuhs-sites.json`에는 표시 이름과 CARE_SITE_ID의 매핑이 있습니다. 실행·환자 수 제한은
이름이 아닌 `1`, `2`, `3`을 기준으로 합니다. 새 DB의 CARE_SITE_ID가 다르면 먼저 실제 매핑을 확인하십시오.

접속 확인:

```powershell
.\07_CHECK_DB.ps1
```

이 검사는 SELECT 1, 세 기관 CARE_SITE 조회, 연결 종료를 확인합니다.
대용량 임상 쿼리의 실행 시간이나 성공을 보장하는 검사는 아닙니다.

## 4. 요청한 옵션으로 실행

```powershell
cd C:\FederatedPS_YUHS_Offline
.\RUN.ps1
```

RUN은 60초 제한의 독립 SQL 렌더링 점검이 성공한 뒤 아래 옵션을 전달합니다.

```powershell
.\05_RUN_YUHS.ps1 -Test $false `
    -Study ppi -Scenario default `
    -Methods local-only,pooled `
    -PatientLimits @{1=2; 2=2; 3=2} `
    -ExtractionWorkers 1 `
    -StatusSeconds 10
```

전처리 순서: site_id 1 → 2 → 3 → 모든 기관 입력 검증 → local-only → pooled.
한 기관이 전처리 중이면 다음 기관이 queued로 표시됩니다. federated는 실행하지 않습니다.
RUN 기본값은 기관별 2명입니다. 파일을 편집하지 않고 `./RUN.ps1 -PatientLimits @{1=200;2=100;3=300}`으로 변경할 수 있습니다. 2명은 실행 점검용이며 연구 조건 적용 후 한 군이 비어 분석이 중단될 수 있습니다.
0은 제한 없음이고, 2 이상의 값은 기관별 상한입니다. 후속 기준 적용 후 최종 환자는 더 적을 수 있습니다.
default는 동일한 환자 선택 규칙으로 방문 복사 전에 상한을 적용합니다. 초기 약제 후보 검색은 더 많은 행을 읽을 수 있습니다.
studySpecific은 기존처럼 적격성 판단 뒤 CohortMethod 전에 상한을 적용합니다.

기관별 추출·population·공변량·설계행렬이 모두 정상 완료된 캐시만 동일 조건에서 재사용합니다.
SitePartition/CohortMethod 중간 단계만 끝난 상태는 재개 체크포인트가 아닙니다.
로그/결과: `FederatedPS\work\methods\<RunId>`; 완료 캐시: `FederatedPS\work\yuhs-cache`.

## 설치 완료 후 JDBC 확인 단계 패치

2026-10-26 `jdbc-probe-2` 수정은 초기 확인에서 JDBC `setMaxRows(2)`를 제거합니다.
이 호출은 `SELECT 1` 앞에 별도 `SET ROWCOUNT 2`를 전송했습니다. CARE_SITE 조회는
`TOP (2)`로 제한하고, 연결 처음부터 짧은 소켓 제한을 적용합니다.
확인 완료 뒤에는 긴 임상 쿼리용 소켓 제한으로 전환합니다. 자동 재시도는 하지 않습니다.

수정된 소스를 반입한 기존 설치는 R/RStudio와 분석을 종료하고 다음을 실행합니다.

```powershell
.\10_UPDATE_PACKAGE.ps1
.\RUN.ps1
```

R, Rtools, Java, Cyclops를 다시 설치할 필요가 없습니다. 실행 전 확인에
`[jdbc-probe-3; sql-plan-4]`가 표시되어야 합니다. 같은 0.0.10이라도 설치된 패키지가 구버전이면
분석을 시작하지 않고 업데이트 명령을 안내합니다.

0단계는 `db-startup-watchdog.log`에 기관별 현재 호출과 경과/제한 시간을 기록합니다.
기본 확인 쿼리 제한은 60초, 소켓/외부 호출 제한은 75초, 기관별 초기 확인 전체 제한은
180초입니다. 시간 초과 뒤 JVM 덤프 및 프로세스 정리 시간이 추가될 수 있습니다.

완료 캐시 파일은 삭제하지 않지만 이 패치는 추출 소스 지문을 바꾸므로 이전 버전의 캐시는
자동 재사용되지 않을 수 있습니다. 미완료된 0단계에는 재개할 코호트가 없습니다.
실제 HIWARE 경로에서 이번 정체의 직접 원인은 대상 서버 로그로 확인해야 합니다.

## 5. SQL 준비 정체 수정 (`sql-plan-3`)

`Rendering SitePartition.sql [started]`는 로컬 SQL 문자열을 만드는 호출의 시작 기록입니다.
이 호출이 몇 시간 걸리는 것은 정상적인 CDM 조회 시간이 아닙니다. 이전 코드에서는
DB 연결 뒤 각 템플릿을 렌더링했고, DBI 실행·조회 래퍼에서도 문장 분리를 다시 호출했습니다.
대상 Windows의 스레드 기록이 없으므로 그 안에서 멈춘 직접 원인은 아직 미확정입니다.

이번 수정은 순차 실행에서 **모든 기관의 SQL 준비를 첫 DB 연결 전으로 이동**합니다.
SitePartition뿐 아니라 StudyConcepts, 노출/환자 제한, CohortMethod, 공변량 SQL도
미리 생성하고 문장으로 나눕니다. 병렬 옵션에서는 각 기관 작업이 자기 연결 전에 준비합니다.
DB 연결 이후에는 준비된 문장을 순서대로 실행하며 SQL 렌더링/분리를 다시 호출하지 않습니다.
CohortMethod의 원래 템플릿과 조건, 실행 순서, 최종 commit, 분할 데이터 전송은 유지합니다.

`RUN.ps1`의 로컬 사전 검사는 동일한 전체 SQL 준비 함수를 세 기관에 적용합니다.
본 분석에도 별도 PowerShell 감시를 추가했습니다. 각 로컬 생성/분리 호출이 60초를
넘으면 진단을 기록하고 이 실행의 프로세스를 정리합니다. 자동 재시도하지 않습니다.
진단/종료 시간은 추가될 수 있습니다. 이 60초는 임상 SQL 실행 제한이 아닙니다.

최신 `sql-plan-4`는 실제 SQL 실행량도 줄입니다. 연구 약제 매핑 → 해당 기관의 노출 후보
→ 다른 양수 기관 방문자 제외 → default의 기존 환자 상한 → 방문 복사 순서입니다.
따라서 RUN 기본값은 방문 복사 전에 site_id 1/2/3을 각각 2명으로 제한합니다.
초기 후보 검색은 여전히 큰 테이블을 읽을 수 있습니다. studySpecific은 기존처럼
적격성 판단 뒤에 상한을 적용합니다. 선택한 환자의 전체 관련 이력과 CohortMethod 조건을 유지합니다.

새 로그는 `StudyConcepts.sql` → `SitePartition.sql SQL 1/4` →
`LimitPartitionPatients.sql`(default 제한 시) → `SiteVisits.sql SQL 1/3` 순서입니다.
실행 중인 SQL에는 행 진행률을 알 수 없다는 표시와 경과 시간을 제공합니다.
전체 CDM 감사 집계는 NA(미집계), 준비된 환자의 집계는 범위를 명시해 저장합니다.

준비 SQL은 `extraction\<site_id>\sql-diagnostics\prepared-*.sql`,
준비 상태는 `sql-prepare-state.json`, 외부 감시는 `sql-prepare-watchdog.log`에 기록합니다.
49개 이전/새 추출 비교와 104개 SQL 준비 조합을 검사했습니다.
실제 Windows/HIWARE/YUHS DB의 실행 시간은 검증하지 못했습니다.
자세한 변경 범위는 `FederatedPS\windows\STUDY_FIRST_EXTRACTION_KO.md`에 있습니다.
인덱스 확인은 DBeaver에서 `diagnostics\CheckExtractionIndexes.sql`을 실행하십시오.

실행 중 정체가 재현되면 다른 PowerShell 창에서, 화면의 Output 경로를 넣어 실행합니다.

```powershell
.\09_COLLECT_DIAGNOSTICS.ps1 `
    -RunDirectory 'C:\FederatedPS_YUHS_Offline\FederatedPS\work\methods\실제_RunId'
```

baselines/기관별 로그와 SQL 진단, 가능한 JVM 스레드 기록을 `diagnostic-exports` ZIP으로 모읍니다.
이 수집은 분석을 종료하지 않으며 DB 비밀번호 설정 파일·RDS·Andromeda 환자 자료를 포함하지 않습니다.
정체 중인 프로세스를 종료하기 전에 실행해야 스레드 상태를 확보할 수 있습니다.

## 포함 버전과 검증 범위

- R 4.6.1 x64 / rtools45-6768-6492 / Temurin JDK 17.0.20.1+1.
- RStudio Desktop 2026.10.0-233.
- Windows R 4.6 의존 패키지 전체 목록과 고정 버전은 `packages/PACKAGE_LOCK.json`.
- FederatedPs 0.0.10 및 `SOURCE_INFO.json`에 기록된 Git 커밋/전체 이력 bundle.
- Cyclops: `taseong/Cyclops`의 `snu_proximal_ccd` 계열 고정 커밋
  `a08a9a8317a8ded49db77f6ff0394ab918b02a94`. stock CRAN Cyclops는 의존 라이브러리에
  있을 수 있지만 실제 실행 라이브러리에서는 이 fork가 우선하며 RemoteSha와 block CCD 인수를 검증합니다.
- SQL Server JDBC: mssql-jdbc-9.2.0.jre8.jar (Temurin 17에서 사용).

제작 환경에서는 다운로드 무결성, 패키지 의존성/버전/Windows 빌드 메타데이터, ZIP CRC,
PowerShell 구문과 실행 옵션 전달, 설치 순서/실패 시 중단을 검사합니다.
Linux 제작 환경이므로 새 Windows 서버에서의 전체 설치·C++ 컴파일·GUI·HIWARE/실제 DB 통합 실행은
여기서 수행하지 못했습니다. SETUP의 런타임·렌더링·합성 데이터 검사가 대상 서버에서 이를 단계적으로 확인합니다.
R installer는 CRAN 공식 MD5, Java MSI는 공급자 SHA-256과 대조했고 다른 파일은 HTTPS로 확보하여
반입 무결성 SHA-256을 기록했습니다.

공식 자료: [R Windows 설치](https://cran.r-project.org/bin/windows/base/),
[Rtools45](https://cran.r-project.org/bin/windows/Rtools/rtools45/rtools.html),
[Temurin 17](https://github.com/adoptium/temurin17-binaries/releases),
[RStudio 다운로드](https://docs.posit.co/ide/user/download.html).


2026-10-26 `jdbc-probe-3`은 CARE_SITE/SELECT 1에만 direct/full 응답 처리를 적용합니다.
2행이 반환되어도 EOF와 최종 SQL 응답을 확인한 다음 닫습니다. `ResultSet.close`와
`Statement.close`를 구분하고 최초 오류를 정리 전에 stderr와 `probe-events.tsv`에 기록합니다.
대량 추출은 adaptive 방식이며 SSL/환자 선정 규칙/시간 제한을 변경하지 않습니다.
업데이트 후 `07_CHECK_DB.ps1`가 성공하면 `RUN.ps1`로 재실행하십시오.
연결 검사 로그는 `FederatedPS\work\diagnostics\connection-*` 아래에 저장됩니다.
자세한 설명: `FederatedPS/windows/JDBC_PROBE_CLEANUP_KO.md`.


## 로컬 수정과 무결성 검사

`RUN.ps1` 옵션, PowerShell 스크립트, FederatedPS R/SQL 소스는 수정 가능합니다.
기본 검사는 이 변경을 `LOCAL EDIT accepted`로 알리고 계속합니다.
설치 EXE/MSI, 의존 패키지 ZIP/lock, JDBC/Cyclops payload, git bundle,
`SOURCE_INFO.json` 및 `FederatedPS/windows/runtime-lock.json`은 계속 엄격하게 검증합니다.
`BUNDLE_MANIFEST.json`을 지우거나 다시 계산할 필요가 없습니다.

```powershell
# RUN 옵션 변경은 파일 편집 없이 가능
.\RUN.ps1 -PatientLimits @{1=2;2=2;3=2}

# R/SQL 패키지 소스를 수정했다면 설치된 R 패키지에 반영 후 실행
.\RUN.ps1 -UpdatePackage

# 배포 원본과 소스까지 일치하는지 확인하고 싶을 때
.\00_VERIFY.ps1 -StrictSource
```

`-UpdatePackage`는 FederatedPs만 갱신하며, 실패하면 분석을 시작하지 않습니다.
R/RStudio를 닫은 뒤 실행합니다. 일반 RUN은 설치된 패키지를 사용하므로,
R/inst 소스 수정 후에는 이 옵션 또는 `10_UPDATE_PACKAGE.ps1`가 필요합니다.
