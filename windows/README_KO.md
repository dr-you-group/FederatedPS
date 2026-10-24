# Windows Server 폐쇄망 실행

대상은 기존 번들의 10~13 단계를 완료한 **Windows Server 2022 x64 / R 4.6.1 /
Rtools45 / Temurin 17** 환경입니다. Docker, WSL, Python, 인터넷 연결 없이 Rscript
프로세스 하나씩으로 집계기와 각 사이트를 실행합니다. RStudio Desktop은 선택 사항입니다.

## 기존 번들에서 추가로 바뀌는 것

`snu_proximal_ccd`는 Cyclops `a08a9a8317a8ded49db77f6ff0394ab918b02a94`를 요구합니다.
기존 번들의 `1c265564...`와 **표시 버전은 모두 3.7.1**이지만, 이전 빌드에는
`blockSize`와 `alpha`가 없습니다. FederatedPs 소스만 바꿔서는 블록 CCD를 실행할 수 없습니다.

이 설치 절차는 새 Cyclops와 FederatedPs 0.0.3을
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
고정된 커밋의 소스만 내려받고 `runtime-lock.json`의 SHA-256과 대조합니다.
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
경로, FederatedPs 버전/프로토콜, JVM 및 PostgreSQL JDBC를 확인합니다.

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

각 실행은 새로운 RunId를 자동으로 만듭니다. 합성 데이터로 집계기 1개와 사이트 2개를
동시에 실행하고, 모든 프로세스 종료 코드, 사이트/집계기 계수 일치, PS 범위 및 합성
데이터를 합쳐 계산한 기준 모델과의 차이(최대 절대 계수 차이 0.01 이하)를 확인합니다.
두 명령 모두 마지막에 `PASS: all roles completed`와 `SUCCESS.txt`를 만들어야 합니다.
`BlockSize 1 / Alpha 1`은 원래 CCD, 두 번째 명령은 블록 CCD 경로의 연동 확인입니다.
이 작은 합성 데이터 검증은 실제 CDM 결과의 통계적 검증을 대신하지 않습니다.

## 4. 실제 DB 실행

사이트별 예제를 한 번 복사하고 각 파일의 실제 접속 정보를 입력합니다.

```powershell
Copy-Item .\windows\config\mimic.Renviron.example .\windows\config\mimic.Renviron
Copy-Item .\windows\config\synpuf.Renviron.example .\windows\config\synpuf.Renviron
notepad .\windows\config\mimic.Renviron
notepad .\windows\config\synpuf.Renviron
```

`PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, `PGPASSWORD`, `CDM_DATABASE_SCHEMA`를 모두
채웁니다. `PGHOST`는 Windows에서 도달 가능한 내부 IP/DNS입니다. DB가 같은 서버에
있을 때만 `127.0.0.1`을 사용합니다. Docker용 `host.docker.internal`은 사용하지 않습니다.
`PGPASSWORD`의 공백/특수문자는 R의 `.Renviron` 인용 규칙에 맞게 입력합니다.
설정 파일은 Git에서 제외됩니다. 해당 Windows 계정에만 필요한 NTFS 접근 권한을 부여합니다.

```powershell
.\windows\Run-FederatedPS.ps1 -Mode Database -Study ppi -Scenario default `
    -Sites mimic,synpuf -BlockSize 1 -Alpha 1

# 동일한 데이터 정의로 블록 CCD를 실행하는 예시. 연구별 설정은 별도로 결정합니다.
.\windows\Run-FederatedPS.ps1 -Mode Database -Study ppi -Scenario default `
    -Sites mimic,synpuf -BlockSize 50 -Alpha 0.5
```

`-Study`는 `FederatedPs::listStudies()`의 연구 ID, `-Scenario`는 `default` 또는
`studySpecific`입니다. EHRSHOT을 추가하려면 해당 예제를 복사·설정한 뒤
`-Sites mimic,synpuf,ehrshot`을 사용합니다. 새 사이트 이름도 별도 `<site>.Renviron`으로
사용할 수 있습니다. 이름은 영숫자이며 `aggregator`, `total`은 예약어입니다.

각 사이트가 자신의 연결 설정으로 데이터를 추출하고 로컬 PS 결과를 저장합니다.
집계기는 DB 설정을 읽지 않으며 공유 폴더에는 패키지 프로토콜의 특성 정보/요약 통계만
전달됩니다. 하나의 Windows 계정에서 실행하는 여러 프로세스는 보안 격리된 병원이
아닙니다. 이 도구는 현재 단일 인스턴스의 여러 CDM/사이트 실행을 위한 것입니다.

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
