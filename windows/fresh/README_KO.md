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
| 00 | `00_VERIFY.ps1` | 모든 반입 파일 SHA-256·크기, 패키지 목록 검사 |
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
    -PatientLimits @{1=200; 2=100; 3=300} `
    -ExtractionWorkers 1 `
    -StatusSeconds 10
```

전처리 순서: site_id 1 → 2 → 3 → 모든 기관 입력 검증 → local-only → pooled.
한 기관이 전처리 중이면 다음 기관이 queued로 표시됩니다. federated는 실행하지 않습니다.
실제 분석 전 환자 제한을 바꾸려면 RUN.ps1의 PatientLimits를 편집하거나 05를 직접 실행하십시오.
0은 제한 없음이고, 2 이상의 값은 기관별 상한입니다. 후속 기준 적용 후 최종 환자는 더 적을 수 있습니다.
환자 제한은 노출 후보 생성 뒤 CohortMethod 전에 적용되며 전체 SitePartition 스캔을 줄이지 않습니다.

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
`[jdbc-probe-2]`가 표시되어야 합니다. 같은 0.0.10이라도 설치된 패키지가 구버전이면
분석을 시작하지 않고 업데이트 명령을 안내합니다.

0단계는 `db-startup-watchdog.log`에 기관별 현재 호출과 경과/제한 시간을 기록합니다.
기본 확인 쿼리 제한은 60초, 소켓/외부 호출 제한은 75초, 기관별 초기 확인 전체 제한은
180초입니다. 시간 초과 뒤 JVM 덤프 및 프로세스 정리 시간이 추가될 수 있습니다.

완료 캐시 파일은 삭제하지 않지만 이 패치는 추출 소스 지문을 바꾸므로 이전 버전의 캐시는
자동 재사용되지 않을 수 있습니다. 미완료된 0단계에는 재개할 코호트가 없습니다.
실제 HIWARE 경로에서 이번 정체의 직접 원인은 대상 서버 로그로 확인해야 합니다.

## 5. 알려진 SQL 생성 정체와 진단

이 통합 설치본은 이전 로그의 `Rendering SitePartition.sql` 정체 원인을 해결했다고 주장하지 않습니다.
이전 로그는 DB 연결과 CARE_SITE 조회 완료 후 SQL 생성 구간에서 멈췄으며,
JVM 스레드 덤프가 없어 해당 호출 내부의 원인은 아직 미확정입니다.

새 로컬 점검은 DB에 접속하지 않고 설치된 SqlRender가 세 기관의 SitePartition SQL을
생성하고 7개 문장으로 나누는지 검사합니다. 60초가 지나면 진단을 수집하고 이 점검이 시작한
프로세스만 정리합니다. 이 검사가 통과해도 **실제 DB 연결 후 동일 구간의 정체가 해결됐다는 뜻은 아닙니다.**
본 분석의 렌더링에는 아직 별도 외부 타임아웃을 추가하지 않았습니다.

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
