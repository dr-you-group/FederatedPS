# DBeaver Java 11과 동일 JDBC를 사용하는 독립 진단

## 현재 확인된 결과

- Java 17에서 DB 없는 JVM 종료 검사는 정상 반환과 System.exit(0) 모두 통과했습니다.
- Java 17 독립 JDBC 검사에서는 site_id 1/2/3 조회와 연결 해제가 완료됐으나 프로세스가 종료되지 않았습니다.
- 2026-10-26 20:28(KST)의 R 진단은 실제 Java 11.0.12, JDBC 7.4.1, rJava 1.0.18을 사용했습니다. SELECT 1과 site_id 1/2는 정리까지 완료됐고, site_id 3의 Statement.executeQuery 구간에서 응답이 끊겨 240초 후 강제 종료됐습니다.
- 2026-10-26 20:57(KST)의 독립 Java 11 진단은 동일 JDBC로 SELECT 1과 site_id 1/2/3의 조회·결과 정리·연결 해제를 약 1.5초 안에 완료했습니다. 그 뒤 진단 도구가 추가로 실행한 종료 전 스레드 수집에서 진행이 끊겼습니다. `JAVA_THREAD_DUMP_BEGIN` 이후 스레드 항목은 없었으며, `terminationRequested=false`로 JVM 종료 요청에도 도달하지 않았습니다. 최종 상태는 `post-check-timeout`이고 195.8초 뒤 외부에서 종료했습니다.

이번 수정은 **정상 조회 뒤 스레드 수집을 의무적으로 실행하던 진단 도구의 문제를 제거**합니다. 기본 실행은 스레드 스냅샷을 수집하지 않고 정상 JVM 종료를 확인합니다. `Thread.getAllStackTraces()` 호출부터 첫 스레드 항목 출력 전까지의 구간에서 멈췄다는 것이 현재 증거의 범위이며, 정확한 내부 원인이나 특정 보안 프로그램의 개입은 확인되지 않았습니다.

독립 Java에서 이번 조회가 완료됐다는 사실은 이전 R/rJava 실행의 정지가 해결됐다는 뜻은 아닙니다. 이 파일은 진단 도구 수정이며 분석 패키지의 Java 기본값, JDBC, SSL, 임상 SQL과 시간 제한을 변경하지 않습니다.

## 현재 서버에서 실행

1. HIWARE 로그인을 유지합니다.
2. 진단 ZIP을 기존 분석 번들과 별도의 새 폴더에 완전히 풉니다.
3. 그 폴더에서 64비트 Windows PowerShell로 아래 명령을 실행합니다.

```powershell
.\CHECK_JDBC.ps1 -BundleRoot 'C:\FP' `
    -JavaHome 'C:\Program Files\DBeaver\jre' `
    -ProbeMode care-site-id `
    -SmallQueryTimeoutSeconds 30 `
    -TimeoutSeconds 180
```

추가 설치나 APPLY_FIX, R 패키지 재설치는 필요 없습니다. ZIP에 Java 11 대상으로 미리 컴파일한 진단 class가 포함되어 있으므로 DBeaver JRE에 javac/jdk.compiler가 없어도 실행됩니다. 기본 JVM 종료 검사용 CHECK_JVM은 이번에 다시 실행할 필요가 없습니다.

실행 시작 시 `launch=compiled-java11`, `JAVA_VERSION=11.0.12`, 기존 `mssql-jdbc-7.4.1.jre8.jar` 사용 여부를 확인합니다. 기본 실행의 `result.json`에는 `capturePreExitThreads=false`, `snapshotStarted=false`가 기록됩니다. 현재 yuhs.Renviron의 주소·계정·SSL·JDBC 경로 및 yuhs-sites.json의 ID를 그대로 사용합니다. R은 설정을 읽을 때만 사용하며, 그 프로세스에는 rJava를 로드하지 않습니다. 실제 연결/조회는 별도 Java 프로세스에서 수행합니다.

명령 종료 후 콘솔의 **Diagnostic ZIP** 경로에 생성된 `java-connection-*.zip`을 전달하십시오. 성공·실패 모두 로그와 result.json을 남깁니다. 이 비교가 통과해도 R/rJava 또는 전체 코호트 추출의 성공을 보장하지는 않습니다.

## 검사와 결과 해석

SELECT 1/세션 ID → 기관별 SELECT TOP (2) care_site_id → EOF/추가 결과 확인 → 결과/Statement 정리 → 연결 종료 → JVM 종료 순서입니다. 기본 경로에서는 종료 전 전체 스레드 수집을 호출하지 않습니다.

- ID 존재·유일성·일치를 확인하며, 실패한 기관을 건너뛰지 않습니다.
- 조회 완료와 프로세스 종료를 분리합니다. 강제 종료나 완료 표식만으로 PASS를 만들지 않습니다.
- `shutdown-timeout`은 조회와 연결 해제 완료 및 종료 요청 표식 이후 프로세스가 제한 시간 내 종료되지 않았다는 뜻입니다.
- `post-check-timeout`은 조회와 연결 해제는 완료됐으나 종료 요청 표식에 도달하기 전에 제한 시간이 지난 경우입니다. 종료 전 스레드 수집에서 멈춘 경우도 여기에 포함됩니다.
- shutdown hook 시작/완료는 계속 기록합니다. 정상 종료 코드 0, 검사 완료, 출력 수집 완료, 강제 종료 없음이 모두 충족되어야 PASS입니다.
- 외부 제한은 지정한 TimeoutSeconds에 15초를 더합니다. Java 내부 heartbeat가 끊기더라도 PowerShell이 해당 진단 프로세스의 종료를 관리합니다.
- 사용자명·비밀번호·Renviron 원문과 조회된 문자열 값은 출력하지 않습니다. 경로, 버전, site_id, SQL Server 세션 ID 및 스레드 ID/상태/호출 프레임은 포함됩니다. 스레드 이름, heap dump와 환자 데이터 추출은 포함하지 않습니다.

## 추가 검사 모드

필요할 때만 `-ProbeMode synthetic-text`로 고정 ASCII/Korean 문자열 변환을, `-ProbeMode care-site-text`로 기존 CARE_SITE 이름/source value 조회를 검사할 수 있습니다. 기본값은 ID-only이며 전체 분석 SQL과 환자 수는 변경하지 않습니다.

`-CapturePreExitThreads`는 종료 전 전체 스레드 수집을 명시적으로 요청하는 선택 옵션입니다. 이 환경에서는 해당 경로가 이미 멈췄으므로 위 기본 비교 실행에 추가하지 마십시오. 스냅샷은 수집 시점의 상태이며 나중에 발생한 정지의 원인을 확정하지 않습니다. 실패 시 watchdog이 시도하는 스레드 기록과 외부 종료 제한은 유지합니다.

DB 없는 기본 JVM 종료 검사는 `CHECK_JVM.ps1`로 제공됩니다. 이 별도 도구는 소스 실행용 JDK 17 이상이 필요하며, DBeaver Java 11 비교에는 위 CHECK_JDBC 명령을 사용합니다.

## 빌드와 검증 범위

온라인 빌드 환경에서 `python windows/build-jdbc-probe.py OUTPUT_DIRECTORY`를 실행하면 javac --release 11로 class를 생성합니다. class major version은 55이며 build.json에는 소스와 class 해시가 기록됩니다. 배포 ZIP의 tools/java11에 이 출력이 포함됩니다.

모의 서버와 로컬 Java/PowerShell 검증은 실제 Windows/HIWARE의 정지 원인을 재현한 것이 아닙니다. 실제 서버에서 실행한 결과를 구분해 판단해야 합니다.
