# Java 종료 및 CARE_SITE JDBC 비교 진단

현재 설정을 독립 Java 프로세스에서 검사합니다. 이미 설치된 R/JDK/JDBC를 사용하며 인터넷 연결이나 추가 설치가 필요하지 않습니다.

## 최신 로그에서 확인한 범위와 다음 실행

2026-10-26 19:42(KST)의 ID-only 독립 Java 진단은 SELECT 1, site_id 1/2/3 조회,
각 결과의 EOF/추가 결과 확인, Statement.close, Connection.close까지 약 1.5초에 완료했습니다.
`CHECKS_COMPLETE` 이후 Java 프로세스가 종료되지 않아 외부 195초 제한으로 강제 종료됐습니다.
이 실행의 실패는 **조회 완료 후 프로세스 종료 시간 초과**입니다.
앞선 07_CHECK_DB의 R 경로 정지는 별도 문제로 남아 있으므로 전체 분석이 해결됐다는 뜻은 아닙니다.

새 진단 ZIP을 별도 폴더에 풀고 먼저 다음을 실행하십시오. 기존 패키지를 덮어쓰거나 재설치할 필요가 없습니다.

```powershell
.\CHECK_JVM.ps1 -BundleRoot 'C:\FP'
```

이 검사는 DB 접속, R/rJava, JDBC, Renviron 없이 같은 기본 Temurin 17에서
`main`의 정상 반환과 `System.exit(0)`를 각각 새 프로세스로 실행합니다.
본문 완료, shutdown hook 시작/완료, 실제 프로세스 종료를 구분합니다.
각 검사는 외부 제한 시간을 적용하고 멈춘 경우 해당 자식 프로세스와 진단 보조 프로세스만 종료합니다.
콘솔에 표시되는 `jvm-lifecycle-*.zip`을 확인하십시오. 성공하더라도 JDBC/분석 성공을 보장하지 않습니다.

JDK를 비교할 때만 `-JavaHome '실제 Java 설치 폴더'`를 추가하십시오.
이 도구는 소스 파일 실행 기능이 있는 JDK 17 이상이 필요합니다.
컴파일러 모듈이 생략된 DBeaver 내장 JRE는 이 도구로 직접 비교할 수 없습니다.
DBeaver와 JDBC 파일이 같아도 DBeaver가 사용하는 Java 런타임까지 같다는 뜻은 아닙니다.
이 도구는 시스템 Java, 드라이버, 보안 프로그램이나 SSL 설정을 변경하지 않습니다.

## 앞선 로그에서 확인한 범위

2026-10-26 독립 Java 검사에서도 7.4.1 JDBC, Java 17.0.20.1, encrypt=false가 사용되었습니다. SELECT 1은 성공했고, CARE_SITE 쿼리는 약 6ms에 반환됐으며 첫 행의 숫자 ID도 읽었습니다. 이후 기관명 문자열 읽기 구간에서 응답이 끊겨 외부 제한 195초에 종료됐습니다.

이전 도구의 해당 구간에는 getString, wasNull, 완료 로그 출력이 함께 포함되어 있었습니다. 따라서 그 로그만으로 내부의 어느 호출이 멈췄는지 확정할 수 없습니다. R/rJava 밖에서도 재현되므로 R만의 문제라고 볼 수 없고, 이번 CARE_SITE 정지는 SQL 실행이 오래 걸린 것으로도 설명되지 않습니다. 내부 감시 로그가 없다는 사실만으로 JVM 교착을 확정할 수도 없습니다.

분석은 기관 ID로 분할되며 CARE_SITE 이름/source value를 계산에 사용하지 않습니다. jdbc-probe-5 분석 패키지와 이 도구의 기본값은 불필요한 문자열을 요청하지 않고 **ID의 존재·유일성·일치 여부를 검증**합니다. 반환된 기관 메타데이터의 이름/source value는 NA, textMetadataFetched=FALSE로 명시됩니다. 이후 대용량 문자열 처리까지 해결됐음을 의미하지는 않습니다.

## 기본 실행

HIWARE 로그인 상태를 유지하고, 진단 ZIP을 별도 폴더에 푼 뒤 64비트 Windows PowerShell에서 실행합니다.

```powershell
.\CHECK_JDBC.ps1 -BundleRoot 'C:\FP'
```

C:\FP는 RUN.ps1과 FederatedPS 폴더가 있는 기존 번들 위치입니다. 런타임 설치 위치가 기본 C:\FederatedPS와 다르면 -InstallRoot를 지정하십시오. 현재 yuhs.Renviron의 주소·계정·SSL·JDBC 경로, yuhs-sites.json의 숫자 ID를 사용합니다. 설정을 읽는 짧은 R 프로세스에는 rJava를 로드하지 않고 실제 조회는 java.exe에서 수행합니다.

기본 검사: SELECT 1/세션 ID → 기관별 SELECT TOP (2) care_site_id → EOF/추가 결과 확인 → 연결 종료 → 프로세스 종료. 실패한 ID를 건너뛰거나 성공으로 처리하지 않습니다.

## 문자열 문제를 추가로 분리할 때

실제 임상 데이터 없이 고정 ASCII/Korean 문자열과 코드 페이지를 검사합니다.

```powershell
.\CHECK_JDBC.ps1 -BundleRoot 'C:\FP' -ProbeMode synthetic-text
```

기존 CARE_SITE 이름/source value 조회를 재현하려면 아래를 별도로 실행합니다. 이미 정지가 관찰된 경로이므로 분석 시작의 필수 검사는 아닙니다.

```powershell
.\CHECK_JDBC.ps1 -BundleRoot 'C:\FP' -ProbeMode care-site-text
```

각 명령은 새 Java 프로세스에서 실행됩니다. 기본값은 -ProbeMode care-site-id, -ResponseBuffering full입니다. 모드를 서로 비교할 때는 같은 설정과 JAR을 사용하십시오.

## 로그와 한계

- getString, wasNull을 별도 기록하고 문자열 읽기 전에 숫자 JDBC column type/precision을 기록합니다. 반환 문자열 값은 출력하지 않습니다.
- stdout과 별도의 stderr heartbeat/timeout 표식을 사용하고 PowerShell 외부 시간 제한도 적용합니다. 프로세스 CPU·메모리·스레드 관찰값은 결과에 포함됩니다.
- JDBC 검사 완료와 프로세스 종료를 별도 기록합니다. 완료 표식 후에도 종료되지 않으면 `shutdown-timeout`으로 실패 처리합니다. 강제 종료를 성공으로 바꾸지 않습니다. JVM 종료가 시작된 뒤 heartbeat가 없다는 사실만으로 DB 또는 JVM 내부 교착 원인을 확정할 수 없습니다.
- 사용자명·비밀번호·Renviron 원문은 진단 ZIP에 기록하지 않습니다. 로컬 경로, 버전, site_id, SQL Server 세션 ID는 포함됩니다.
- 쿼리 제한은 기본 60초, 네트워크/단계 제한은 75초입니다. Java 전체 제한은 180초이며 외부 종료 여유가 추가됩니다. 사전 파일/설정 오류가 아니라 실제 진단이 시작된 경우, 성공·실패 모두 콘솔의 Diagnostic ZIP 경로에 결과를 만듭니다.
- 코호트/환자 추출이나 임상 테이블 변경을 수행하지 않습니다. ID-only 성공은 기관 검증 성공이며 전체 분석이나 문자열 처리의 성공을 보장하지 않습니다.

실제 YUHS/HIWARE에서 수정 후 성공 여부는 이 도구와 분석을 해당 서버에서 실행하여 확인해야 합니다. 모의 응답 검증과 실제 서버 검증은 구분합니다.
