# Windows Server 폐쇄망 실행

대상은 기존 번들의 10~13 단계를 완료한 **Windows Server 2022 x64 / R 4.6.1 /
Rtools45 / Temurin 17** 환경입니다. Docker, WSL, Python, 인터넷 연결 없이 Rscript
프로세스 하나씩으로 집계기와 각 사이트를 실행합니다. RStudio Desktop은 선택 사항입니다.

Windows의 기본 데이터 구성은 **YUHS SQL Server CDM을 세 기관으로 분리**하는 방식입니다.
기존 MIMIC/SynPUF/EHRSHOT PostgreSQL 예제는 `-Dataset Example`으로만 선택합니다.

## 기존 번들에서 추가로 바뀌는 것

`snu_proximal_ccd`는 Cyclops `a08a9a8317a8ded49db77f6ff0394ab918b02a94`를 요구합니다.
기존 번들의 `1c265564...`와 **표시 버전은 모두 3.7.1**이지만, 이전 빌드에는
`blockSize`와 `alpha`가 없습니다. FederatedPs 소스만 바꿔서는 블록 CCD를 실행할 수 없습니다.

이 설치 절차는 새 Cyclops와 FederatedPs 0.0.5를
`C:\FederatedPS\RLibrary\windows-block`에 설치합니다. 기존
`C:\FederatedPS\RLibrary\4.6`은 의존성 라이브러리로 계속 사용합니다.
이 폴더 구조는 프로젝트 소스 경로와 별개입니다. 아래 예제에서는 소스를
`C:\FederatedPS-src`에 둡니다.

## 1. 인터넷 PC에서 소스 준비

[ts06068/FederatedPS의 windows-server-offline 브랜치](https://github.com/ts06068/FederatedPS/tree/windows-server-offline)에서
Code → Download ZIP으로 소스를 내려받아 압축을 풀고 **저장소 루트**에서 실행합니다.
GitHub 소스 ZIP에는 `windows/payload`가 포함되지 않으므로 아래 준비 단계는 인터넷 PC에서
실행해야 합니다. 기존 R 런타임 번들을 다시 만들 필요는 없습니다.

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\windows\Prepare-Offline.ps1
```

`windows\payload\Cyclops-a08a9a8317a8ded49db77f6ff0394ab918b02a94.zip`이 생성됩니다.
`windows\payload\sqlServerV9.2.0.zip`도 생성됩니다. OHDSI DatabaseConnector의
SQL Server JDBC 드라이버와 고정된 Cyclops 소스를 내려받고 `runtime-lock.json`의 SHA-256과 대조합니다.
이는 소스 아카이브를 확인해 계산한 전송 무결성 값이며 별도의 서명은 아닙니다.
설치 파일 전체나 R 패키지 전체를 다시 내려받지는 않습니다.

이 소스를 `windows\payload`까지 포함해 폐쇄망 서버의 `C:\FederatedPS-src`로 복사합니다.
DB 비밀번호가 들어 있는 개인 설정, 환자 데이터, 기존 `work`, `data`, `exchange` 폴더를
반출용 압축에 추가하지 마십시오. 함께 제공되는 반입용 소스 ZIP에 위 파일이 이미 들어
있다면 인터넷 PC의 준비 단계는 생략할 수 있습니다.

## 2. 폐쇄망에서 새 패키지 설치

R/RStudio 세션을 모두 닫습니다. 설치 경로에 쓰기 권한이 있는 64비트 PowerShell에서:

```powershell
cd C:\FederatedPS-src
Set-ExecutionPolicy -Scope Process Bypass -Force
.\windows\Install-Offline.ps1
```

Cyclops C++ 소스를 Rtools45로 빌드하므로 시간이 걸립니다. `R CMD INSTALL`만 사용하며
`install_github()`나 의존성 다운로드를 실행하지 않습니다. 빌드와 새 R 프로세스의 검증을
모두 통과해야 완료 메시지가 나옵니다. `blockSize`뿐 아니라 Cyclops 커밋, 라이브러리
경로, FederatedPs 버전/프로토콜, JVM 및 SQL Server JDBC를 확인합니다. SQL Server JAR는 기존 JDBC 폴더 아래
`sqlserver`에 따로 설치하며 PostgreSQL 드라이버를 바꾸지 않습니다.
이전 Windows 브랜치를 설치한 경우에도 새 소스와 JDBC payload를 반입하여 재설치하십시오.

설치 위치가 다르면 `-InstallRoot`, `-RHome`, `-JavaHome`, `-RtoolsHome`을 지정합니다.
이후 실행에도 동일한 `-InstallRoot`, `-RHome`, `-JavaHome`을 사용합니다.
`Rtools45 missing`이면 기존 번들의 11번을 `-SkipRtools` 없이 완료해야 합니다.
DLL 사용 중 오류가 나면 다른 Windows 로그인 세션의 R 작업도 종료된 상태인지 확인합니다.

## 3. HIWARE 로그인 전: test=true로 합성 YUHS CDM 실행

**DB 주소에 연결할 수 없거나 HIWARE에 로그인하지 않은 상태에서도 실행할 수 있습니다.**
설치(2단계)를 마친 뒤, 저장소 루트의 일반 사용자 PowerShell에서:

```powershell
.\windows\Run-YUHS.ps1 -Test $true
# 기본값도 Test=true
.\windows\Run-YUHS.ps1
# 블록 CCD 확인
.\windows\Run-YUHS.ps1 -Test $true -BlockSize 4 -Alpha 0.5
```

`Test=true`는 내부 `SyntheticCDM` 모드입니다. `yuhs.Renviron`을 만들거나 편집할
필요가 없고, 기존 설정 파일이 있더라도 읽지 않습니다. DB 연결/접속 확인이나 HIWARE
로그인을 시도하지 않습니다. 설치된 R/Java/JDBC/패키지의 로컬 로딩 검사는 그대로 합니다.
인터넷, Python, 로컬 SQL Server, 새 의존성 설치는 필요하지 않습니다.

`inst/extdata/yuhs-synthetic`의 **완전히 가상으로 만든** CARE_SITE, PERSON,
VISIT_OCCURRENCE, OBSERVATION_PERIOD, DRUG_EXPOSURE, CONDITION_OCCURRENCE,
PROCEDURE_OCCURRENCE, MEASUREMENT, CONCEPT, CONCEPT_ANCESTOR CSV를 읽습니다.
세 기관 각각 120명(총 360명)의 치료군/비교군과, 제외될 다기관 방문 환자 1명이 있습니다.
테스트용 가상 concept ID와 축약된 열을 사용하므로 완전한 OMOP CDM은 아닙니다.

R에서 기관/방문 연결, 코호트와 이진 공변량을 만들고 실제 분석과 같은
`CohortMethod::createStudyPopulation()` → `FederatedPs::fitPs()` → Cyclops/집계기 경로를
실행합니다. `fitPsDesign()`으로 임의 행렬만 적합하는 기존 `Synthetic` 모드와 구분합니다.
기본 CCD와 블록 CCD에서 새 RunId와 결과 폴더를 만들며, 역할별 계수 일치, PS 범위,
360명 유지, 기관 간 환자 중복 없음, 합성 데이터를 합친 기준 CCD와 PS 최대 차이
0.01 이하를 확인합니다. `SUCCESS.txt`에는 **TEST=true / synthetic CDM only**가 기록됩니다.

샘플 테스트는 **`-Study ppi -Scenario default`, 세 기관 1/2/3**에 한정됩니다.
`studySpecific`, 다른 연구/기관 조합은 명확한 오류로 중단합니다. 실제 연구처럼 보이는
샘플 결과를 만들지 않도록 입력과 결과에 synthetic 표시를 넣고 실제 DB와 다른 모델
메타데이터를 사용합니다. 세 기관의 실제 환자 분포를 재현한 자료는 아닙니다.

결과: `work/windows/<RunId>/<site>/result.rds`, `synthetic-cdm-input.rds`,
`careSite.csv`, `sitePartition.csv`, `recordLinkage.csv`, `attrition.csv`, 실행 로그.
샘플 CSV 원본은 위 `inst/extdata`에서 볼 수 있습니다.
**이 테스트의 PASS는 실제 DB/T-SQL/HIWARE/TLS 연결 또는 연구 타당성 검증을 뜻하지 않습니다.**

기존 작은 임의 행렬 테스트와 실행기 자체 검사도 사용할 수 있습니다.

```powershell
.\windows\tests\Test-Launcher.ps1
.\windows\tests\Test-YUHS-Routing.ps1
.\windows\Run-FederatedPS.ps1 -Mode Synthetic
```

## 4. HIWARE 로그인 후: test=false로 실제 YUHS 실행

첨부 CARE_SITE 화면에 맞춘 기본 매핑은 `windows/config/yuhs-sites.json`에 있습니다.
`CARE_SITE_SOURCE_VALUE`의 10/20/30이 아니라 **CARE_SITE_ID의 1/2/3**을 사용합니다.

| 실행 사이트 | 기관 | CARE_SITE_ID |
| --- | --- | --- |
| `severance` | 세브란스병원 | 1 |
| `gangnam` | 강남세브란스병원 | 2 |
| `yongin` | 용인세브란스병원 | 3 |

먼저 평소 절차대로 HIWARE에 로그인해 실제 DB 연결이 가능한 상태로 만드십시오.
이 스크립트는 HIWARE 로그인을 대신하지 않습니다. 세 역할은 동일한 SQL Server CDM에 각각 연결합니다. 공통 접속 설정은 한 번만 작성합니다.
실제 서버 주소와 계정·비밀번호는 저장소에 포함하지 않습니다.

```powershell
Copy-Item .\windows\config\yuhs.Renviron.example .\windows\config\yuhs.Renviron
notepad .\windows\config\yuhs.Renviron
```

`DB_SERVER`는 내부 SQL Server 주소, `DB_PORT`는 포트(기본 1433), `DB_DATABASE`는
`CDM54_2601`, `CDM_DATABASE_SCHEMA`는 `CDM54_2601.CDM`입니다. 실제 스냅샷이 다르면
두 값을 함께 바꿉니다. `DBMS="sql server"`와 SQL 로그인용 `DB_USER`, `DB_PASSWORD`를
설정합니다. 비밀번호는 R `.Renviron`의 따옴표/이스케이프 규칙을 따릅니다. 이 파일은 Git에서
제외되며, 해당 Windows 계정에만 필요한 NTFS 접근 권한을 부여합니다.

JDBC는 `encrypt=true;trustServerCertificate=false`로 연결합니다. 서버 인증서의 DNS 이름과
일치하는 `DB_SERVER`를 사용하고 기관 CA를 Temurin 신뢰 저장소에 등록하십시오.
인증서 오류는 검증을 끄지 않고 CA/이름 설정으로 해결합니다. 현재 실행기는 SQL 로그인을
지원합니다. Windows 통합 인증은 별도 인증 DLL/설정이 필요하므로 이 경로에 포함하지 않습니다.

```powershell
# DB 없이 합성 CDM/블록 CCD부터 확인
.\windows\Run-YUHS.ps1 -Test $true -BlockSize 4 -Alpha 0.5

# 기본: severance, gangnam, yongin / 동일 YUHS CDM
.\windows\Run-YUHS.ps1 -Test $false -Study ppi -Scenario default

# 같은 사이트/연구 정의로 블록 CCD
.\windows\Run-YUHS.ps1 -Test $false -Study ppi -Scenario default `
    -BlockSize 50 -Alpha 0.5

# indication/관찰기간/washout/product 제한을 사용하는 기존 프리셋
.\windows\Run-YUHS.ps1 -Test $false -Study ppi -Scenario studySpecific `
    -BlockSize 50 -Alpha 0.5
```

`Test=false`에서 연결에 실패하면 오류로 중단하며 합성 데이터로 자동 전환하지 않습니다.

기관 ID가 변경되면 `yuhs-sites.json`을 수정합니다. 서로 다른 양의 정수 ID여야 하며,
실제 `CARE_SITE`에 한 행씩 있어야 합니다. 일부 기관만 실행하려면
`-Sites severance,gangnam`처럼 두 곳 이상을 지정합니다. `-Study`는
`FederatedPs::listStudies()`에 있는 연구 ID입니다. 각 기관에 치료군과 비교군이 모두
있어야 하며, 비어 있으면 조건을 자동으로 완화하지 않고 중단합니다.

### 기관 분리와 연구 정의

1. `VISIT_OCCURRENCE.CARE_SITE_ID`로 기관을 찾습니다. `PERSON.CARE_SITE_ID`를 환자의
   기관으로 간주하지 않습니다. 전체 CDM 방문에서 **서로 다른 양의 CARE_SITE_ID가 두 개
   이상인 PERSON_ID는 모든 사이트에서 제외**합니다. 설정한 세 기관 외의 방문도 이 검사에
   포함합니다. 이 정책은 중복 환자를 방지하지만 다기관 이용 환자를 제외하는 선택 편향이
   생길 수 있으므로, 실제 제외 규모를 확인한 뒤 연구계획에 명시해야 합니다.
2. 노출·indication·washout·공변량은 해당 기관 방문에 `VISIT_OCCURRENCE_ID`와 `PERSON_ID`가
   모두 일치하는 기록만 사용합니다. 방문 연결이 NULL/0/깨진 링크이거나 환자 ID가 맞지 않는
   기록은 사용하지 않습니다. 기관 ID가 없는 방문은 기관 할당 근거로 쓰지 않습니다.
3. 통합 `DRUG_ERA`에는 방문 키가 없으므로 사용하지 않습니다. `default`는 기관에 연결된
   `DRUG_EXPOSURE`의 첫 기록이며, `studySpecific`의 washout도 기관별 exposure 기간으로
   확인합니다. 약제 concept/ATC, 연령, native observation period, indication 및 시간 창은
   프리셋 설정을 사용합니다. 전기관 drug-era 기반 기존 PostgreSQL 추출과 동일한 코호트라고
   가정하면 안 됩니다. 관찰기간은 CDM의 native observation period를 유지하며 기관별로
   새로 추정하지 않습니다.
4. SQL Server 공변량은 기관 필터를 빠뜨리지 않도록 명시적인 `care-site-binary-v1` SQL로
   추출합니다. 성별, 5세 연령군(인덱스 연도−출생 연도), condition/drug/procedure/measurement의
   이진 발생 여부입니다. 연속 검사값이나 수치 표준화는 사용하지 않습니다. 임상 창은
   기본 -90~-1일이며 studySpecific에서는 기존 prior/short-term 창과 acute-episode cutoff를
   적용합니다. 치료/비교 약제와 descendants는 공변량에서 제외합니다.
5. 공통 feature ID는 `concept_id * 1000 + analysis_id`입니다. analysis ID는 성별 1,
   연령군 2, condition 101/102, drug 201/202, procedure 301/302, measurement 401/402
   (long/short)입니다. 연령군은 concept 대신 5세 구간 번호를 씁니다. 이 정의는 세 YUHS
   사이트에서 동일하며, 기존 FeatureExtraction의 PostgreSQL 출력과 한 모델에 혼합하지
   않습니다. 메타데이터의 definitionVersion=2/featureDefinition으로 구별됩니다.

소스 CDM에는 SELECT만 수행하고 작업 테이블은 연결별 SQL Server `#temp`에 만듭니다.
source schema의 CREATE/UPDATE 권한은 필요 없지만 tempdb 공간이 필요합니다.
사이트마다 방문 집계·임상 테이블을 읽으므로 대규모 CDM에서는 DB 부하와 tempdb 여유를
확인하십시오. 동시 실행 중 원본 CDM이 갱신되지 않는 고정 스냅샷을 사용합니다.

실제 YUHS 데이터에는 이 개발 환경에서 접속하지 않았습니다. 최초 실행에서 각 역할의
`careSite.csv`, `sitePartition.csv`, `recordLinkage.csv`, `attrition.csv`를 확인하십시오.
연결 제외 수는 **단일기관 환자의 해당 테이블 전체 기록**을 분모로 하며, 연구 시간 창이나
concept 필터 적용 전 수치입니다. 다기관 환자 수와 기관 미상 방문 수는 전체 CDM 값이라
기관별 파일에 반복됩니다. 추출 중단 시에도 역할 로그에 단일기관 환자 수와 방문 연결 제외
건수를 남깁니다. 환자별 결과는 각 사이트의 `result.rds`에만 저장하며, 실행 후 세 결과의
PERSON_ID 중복도 확인합니다. 공유 exchange에는 환자 ID를 쓰지 않습니다.
단일 Windows 계정의 프로세스 세 개는 기관 간 접근권한 격리를 제공하지 않습니다.

### 기존 PostgreSQL 예제

기존 기관별 `.Renviron` 파일을 사용하는 경우에만 명시적으로 선택합니다.

```powershell
.\windows\Run-FederatedPS.ps1 -Mode Database -Dataset Example `
    -Sites mimic,synpuf,ehrshot -Study ppi -Scenario default
```

이 경로의 `PGHOST`는 Windows에서 도달 가능한 주소입니다. 기존 PostgreSQL JDBC JAR가
필요합니다. 이 설정으로 YUHS를 실행하지 마십시오.

## 결과와 실패 처리

- `work\windows\<RunId>\run.json`: 비밀번호가 없는 공통 실행 설정.
- `work\windows\<RunId>\aggregator\result.rds`: 공통 계수 벡터.
- `work\windows\<RunId>\<site>\result.rds`: DB 모드에서는 PS가 추가된 population;
  Synthetic/Design 모드에서는 계수, PS, rowIds 및 통신 횟수 등.
- 각 역할 폴더의 `run.stdout.log`, `run.stderr.log`: 해당 R 프로세스 로그.
- `SUCCESS.txt`: 모든 역할과 결과 검증을 통과한 경우에만 생성.
- `exchange\windows\<RunId>`: 해당 실행의 pda 메시지. 완료/실패 후에도 보존합니다.

같은 RunId의 기존 결과를 덮어쓰지 않습니다. 실패 후에는 원인을 수정하고 새 RunId로
실행합니다. 하나가 실패하거나 전체 제한 시간을 넘으면 **이 명령이 시작한 프로세스만**
종료하고 로그를 보존합니다. 다른 R/RStudio 작업은 종료하지 않습니다.

추출이 오래 걸리면 `-ExchangeTimeoutSeconds`(기본 3600초)를 늘립니다.
`-RunTimeoutSeconds`는 전체 실행 시간 제한(기본 86400초)입니다. `-WorkDirectory`,
`-ExchangeDirectory`, `-ConfigDirectory`로 경로를 바꿀 수 있습니다. 서버 메모리는
실제 코호트 크기에 따라 확인해야 하며, 각 R 프로세스의 계산 스레드는 1개로 제한합니다.

## RStudio Desktop

이미 반입한 RStudio Desktop 설치 파일로 설치하고, 열려 있는 RStudio를 닫은 뒤:

```powershell
.\windows\Launch-RStudio.ps1
```

RStudio에서 R 4.6.1을 선택합니다. 이 실행기는 별도 라이브러리/JAVA_HOME/JDBC를 전달하고
시작 시 검증을 수행합니다. 시작 콘솔의 PASS를 확인하십시오. 일반 아이콘이나 이전
번들의 `Launch-R-Offline.ps1`은 새 라이브러리를 설정하지 않습니다.
GUI 없이 `Run-FederatedPS.ps1`만으로 전체 분석을 실행할 수 있습니다.
RStudio GUI와 실제 Windows Server 구동 여부는 대상 서버에서 확인해야 합니다.

### RStudio에서 실제 YUHS 실행

`extras/CodeToRun.R`와 `extras/ConnectionDetails.R`는 기존 PostgreSQL 예제입니다.
Windows/YUHS에서는 실행하지 않습니다. `FEDERATEDPS_SITE`가 없는 상태에서 해당
예제를 실행하면 `.Renviron.` 파일을 찾다가 실패하며, 이는 DB 접속을 시도하기 전의
설정 오류입니다. YUHS 설정 파일은 `windows/config/yuhs.Renviron`입니다.

HIWARE 로그인 후 위의 SQL Server 접속 설정을 저장합니다. **R Console의 `>` 프롬프트가
아닌 Terminal 탭의 PowerShell(`PS ...>`)**에서 저장소 루트로 이동해 실행합니다.
Terminal이 cmd라면 먼저 `powershell`을 입력해 PowerShell로 전환합니다.

```powershell
Set-Location -LiteralPath 'C:\FederatedPS_YUHS_Offline\FederatedPS'
.\windows\Run-YUHS.ps1 -Test $false -Study ppi -Scenario default
```

번들 최상위 폴더에서 실행할 때는 다음과 같습니다. 03번은 기존 설정을 보존하며
편집기로 엽니다. HIWARE 로그인과 별도로 JDBC가 사용할 DB 계정·접속 주소가 필요합니다.

```powershell
Set-Location -LiteralPath 'C:\FederatedPS_YUHS_Offline'
.\03_CONFIGURE_YUHS.ps1
.\05_RUN_YUHS.ps1 -Test $false -Study ppi -Scenario default
```

실행 초기에 `TEST=false: real database run`이 표시되어야 합니다. Test를 생략하면
기본값은 여전히 true이며 합성 CDM을 실행합니다. 이 실행기는 집계기와 세 기관을 함께
시작하므로 RStudio 창 세 개를 열거나 사이트 이름을 수동 지정할 필요가 없습니다.
실제 추출·계산이 끝나면 `PASS: all roles completed` 및 해당 RunId의 `SUCCESS.txt`를
확인합니다. 시작 시의 runtime/preflight PASS만으로 DB 연결 성공을 판단하지 않습니다.

RStudio 시작 시 `getFromNamespace` 함수를 찾을 수 없다는 오류는 시작 검증에서
`utils::getFromNamespace`를 명시하도록 수정했습니다. R 기본 패키지들이 붙기 전에도
동작하게 하는 수정이며, 이미 0.0.5가 설치되어 있다면 패키지 재설치는 필요 없습니다.
수정 후 RStudio를 종료하고 번들의 `06_LAUNCH_RSTUDIO.ps1`로 다시 여십시오.

## 준비된 설계 행렬과 기존 실험

DB 재추출 없이 사이트별 RDS(`x`, `treatment`, `rowIds`를 갖는 list)를 실행할 수 있습니다.
`x`는 숫자 ID가 열 이름인 희소 행렬입니다. 모든 사이트의 데이터 정의와 단위가 같아야 합니다.

```powershell
.\windows\Run-FederatedPS.ps1 -Mode Design -Sites s1,s2,s3 `
    -DesignDirectory C:\study\sitedata\scenarioA -BlockSize 50 -Alpha 0.5

.\windows\Run-RScript.ps1 -Script experiments\validation\test1_legacy.R -ScriptArguments patched
```

`Run-RScript.ps1`은 저장소 루트에서 R 파일을 실행하며 `-ScriptArguments` 배열도 지원합니다.
실험의 `FP_DATA`, `FP_OUT` 등은 PowerShell에서 `$env:FP_DATA='C:\study\data'`처럼 지정합니다.
`FP_LIB`는 Windows의 세미콜론 구분을 지원하도록 수정했습니다.
기존 `.sh` 배치 실행기와 `pkill`을 호출하는 진단은 Linux용으로 남아 있습니다.
여러 프로세스를 이용한 핵심 연합 적합은 위의 Design 모드가 Windows 실행 경로입니다.
CKKS/Python 실험 등의 추가 의존성은 이번 기본 오프라인 런타임에 포함되지 않습니다.

## 개발 검증 범위

`windows/tests/Test-Launcher.ps1`은 식별자, 공백·인용부호 경로 전달, 비정상 종료,
타임아웃과 작업 정리를 검증합니다. `windows/tests/test-validation.R`은 의존성 없는
식별자/블록 패킷/설계 행렬 입력 검증입니다. Windows 서버의 실제 설치와 합성 연합 적합은
위 2~3단계로 확인하십시오. 실제 CDM 연결/추출/분석 결과는 해당 서버에서 검증해야 합니다.

## Windows PowerShell 5.1에서 `failed (exit )`가 나왔던 경우

2026-10-25 실행기 수정에서 자식 프로세스를 `System.Diagnostics.Process`로 직접
시작해 종료 코드를 유지하고 표준 출력/오류를 동시에 기록하도록 변경했습니다.
기존 `Start-Process`의 빈 ExitCode 문제를 피하며, 종료 코드가 없으면 명확한 오류로
중단합니다. 성공으로 간주하거나 임의로 0을 넣지 않습니다.

이미 FederatedPs 0.0.5를 설치한 서버에서는 실행기 패치만 적용하면 됩니다.
R/Rtools/Java/Cyclops/FederatedPs를 다시 설치하거나 DB 설정을 바꿀 필요가 없습니다.

```powershell
.\windows\tests\Test-Launcher.ps1
.\windows\Run-YUHS.ps1 -Test $true
```

수정 후 숫자가 있는 `failed (exit 1)` 등의 메시지가 나오면 해당 역할의
`run.stderr.log`와 `run.stdout.log`를 확인하십시오. 이는 실제 자식 프로세스의 실패이며
무시하면 안 됩니다. `Test=true` 실행은 HIWARE 로그인 및 실제 DB 접속이 필요 없습니다.

`noisy.stdout.log ... being used by another process`는 첫 실행기 수정의 로그 닫기
순서에서 발생한 문제입니다. 후속 수정은 로그 복사가 완료된 후 파일 쓰기 핸들을
즉시 닫고 검사하도록 변경했습니다. 해당 패치 후 04번을 다시 실행하십시오.

## 실시간 로그와 진행 상황 (0.0.6)

`Run-YUHS.ps1`은 기본적으로 집계기/기관별 stdout·stderr를 실시간으로 표시합니다.
약 1초 간격으로 진행 막대를 갱신하고 15초마다 텍스트 상태를 남깁니다.
프로세스 PID/경과 시간, CPU 사용량(코어 하나=100%), 마지막 로그·진행 이벤트 이후
시간을 표시합니다. CPU 정보를 OS에서 제공하지 못하면 `?`입니다.
프로세스가 살아 있거나 CPU가 낮다는 사실만으로 SQL 실행이 정상/정지했다고 판단하지 않습니다.

- DB 연결 시작과 성공을 구분합니다. 이후 기관 분리, 연결 검사, 컨셉 정의,
  코호트, 공변량 추출·전송을 표시합니다.
- DB 추출 막대의 %는 **10개 작업 단계 중 완료한 단계 수**입니다. 단계별 작업량은
  다르므로 데이터 행 처리율이나 남은 시간 비율이 아닙니다. SQL 단일 쿼리의 ETA는
  `unknown`으로 표시합니다. 추가 DB 모니터링 권한이나 중복 COUNT 쿼리는 요구하지 않습니다.
- 집계기의 CCD 막대는 **현재 sweep에서 완료한 좌표/전체 좌표**입니다. ETA는 해당
  sweep의 관측 처리 속도로 추정하며, 전체 학습 종료 시간이 아닙니다. 다음 sweep에서
  %가 다시 시작됩니다. 수렴 검사/기관 대기 중에는 ETA가 unknown으로 돌아갑니다.
  10초 넘게 갱신되지 않은 ETA도 표시하지 않습니다. maxIterations를 완료율의 분모로 쓰지 않습니다.
- 전체 역할 완료 후 최종 결과 검증도 별도 프로세스/로그로 감시합니다. 종료 코드가
  0이어도 `SUCCESS.txt`가 없으면 성공으로 처리하지 않습니다.

결과 폴더의 `monitor.log`는 합쳐진 텍스트 출력, 각 역할의 `progress.jsonl`은
단계 이벤트입니다. 기존 `run.stdout.log`/`run.stderr.log`도 그대로 저장합니다.
진행 이벤트에는 접속 정보, SQL 본문, 환자별 데이터 또는 PS 값을 넣지 않습니다.
표시만 숨기려면 `-NoProgress`를 사용합니다. 이때도 실시간 로그와 15초 상태는 남습니다.

기존 0.0.5 설치에서 업그레이드할 때는 진행 중인 분석이 끝난 뒤 R/RStudio를 닫고:

```powershell
.\windows\Update-FederatedPs.ps1
```

FederatedPs 0.0.6만 설치하고 기존 Cyclops/JDBC/의존성은 재사용합니다. 전체 C++ 재빌드인
`Install-Offline.ps1`을 반복할 필요는 없습니다. DB 설정과 `windows/common.R`의 로컬
SSL 변경은 진행 표시용 패치에서 보존됩니다. 새 전체 번들의 기본 TLS 설정은 기존과 같습니다.

이미 실행 중인 작업은 별도 PowerShell 창에서 읽기 전용 모니터로 볼 수 있습니다:

```powershell
.\windows\Watch-FederatedRun.ps1 -RunDirectory 'C:\FederatedPS_YUHS_Offline\FederatedPS\work\windows\<RunId>'
```

이 모니터에서 Ctrl+C는 모니터만 끝내며 분석 프로세스를 종료하지 않습니다.
업데이트 전 시작한 작업에는 단계 이벤트가 없으므로 기존 로그를 표시하고
%/ETA는 unknown입니다. 새 단계/진행률 표시는 업데이트 후 새 실행부터 적용됩니다.
