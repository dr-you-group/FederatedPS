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

이 설치 절차는 새 Cyclops와 FederatedPs 0.0.4을
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

## 3. DB 없는 실행 검증

일반 사용자 PowerShell에서 저장소 루트로 이동하여 실행합니다.

```powershell
.\windows\tests\Test-Launcher.ps1
.\windows\Run-FederatedPS.ps1 -Mode Synthetic
.\windows\Run-FederatedPS.ps1 -Mode Synthetic -BlockSize 4 -Alpha 0.5
```

각 실행은 새로운 RunId를 자동으로 만듭니다. 합성 데이터로 집계기 1개와 사이트 3개를
동시에 실행하고, 모든 프로세스 종료 코드, 사이트/집계기 계수 일치, PS 범위 및 합성
데이터를 합쳐 계산한 기준 모델과의 차이(최대 절대 계수 차이 0.01 이하)를 확인합니다.
두 명령 모두 마지막에 `PASS: all roles completed`와 `SUCCESS.txt`를 만들어야 합니다.
`BlockSize 1 / Alpha 1`은 원래 CCD, 두 번째 명령은 블록 CCD 경로의 연동 확인입니다.
이 작은 합성 데이터 검증은 실제 CDM 결과의 통계적 검증을 대신하지 않습니다.

## 4. YUHS 세 기관 실행 (기본값)

첨부 CARE_SITE 화면에 맞춘 기본 매핑은 `windows/config/yuhs-sites.json`에 있습니다.
`CARE_SITE_SOURCE_VALUE`의 10/20/30이 아니라 **CARE_SITE_ID의 1/2/3**을 사용합니다.

| 실행 사이트 | 기관 | CARE_SITE_ID |
| --- | --- | --- |
| `severance` | 세브란스병원 | 1 |
| `gangnam` | 강남세브란스병원 | 2 |
| `yongin` | 용인세브란스병원 | 3 |

세 역할은 동일한 SQL Server CDM에 각각 연결합니다. 공통 접속 설정은 한 번만 작성합니다.
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
# DB 없이 세 역할의 실행기/블록 CCD부터 확인
.\windows\Run-FederatedPS.ps1 -Mode Synthetic -BlockSize 4 -Alpha 0.5

# 기본: severance, gangnam, yongin / 동일 YUHS CDM
.\windows\Run-FederatedPS.ps1 -Mode Database -Study ppi -Scenario default

# 같은 사이트/연구 정의로 블록 CCD
.\windows\Run-FederatedPS.ps1 -Mode Database -Study ppi -Scenario default `
    -BlockSize 50 -Alpha 0.5

# indication/관찰기간/washout/product 제한을 사용하는 기존 프리셋
.\windows\Run-FederatedPS.ps1 -Mode Database -Study ppi -Scenario studySpecific `
    -BlockSize 50 -Alpha 0.5
```

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
