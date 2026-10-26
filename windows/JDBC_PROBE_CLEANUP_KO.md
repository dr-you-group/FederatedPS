# CARE_SITE / JDBC close 대기 수정 (jdbc-probe-3)

환자 상한 2명은 연구 후보 선택에 적용됩니다. SELECT 1과 CARE_SITE 확인은 그보다 앞선 연결 검사이므로 환자 상한으로 이 단계의 대기를 줄일 수 없습니다.

DBeaver에서 같은 주소와 계정으로 조회가 된다는 것은 유용한 비교입니다. 다만 실행 도구마다 드라이버 버전, 세션 설정, 결과 수신 및 종료 방식이 달라 패키지에서도 모든 호출이 성공한다는 보장은 아닙니다. 기존 `JDBC close` 표시는 ResultSet과 Statement를 구분하지 않았고, 앞선 오류 이후의 정리 단계도 같은 이름으로 표시했습니다. 해당 한 줄만으로 DB 스캔, 잠금, HIWARE 또는 JVM 중 원인을 확정할 수 없습니다.

## 수정 내용

- SELECT 1/@@SPID와 SELECT TOP (2) CARE_SITE만 Microsoft direct forward-only/read-only statement 및 `responseBuffering=full`을 사용합니다. 전체 응답을 수신한 뒤 최대 2행을 읽습니다.
- 두 번째 행을 읽어도 중단하지 않고 `next() == FALSE`와 `getMoreResults()`의 최종 응답을 확인합니다. 행 뒤에 도착한 SQL 오류를 `close()`가 버리는 것을 막습니다. 예상치 못한 추가 결과는 성공으로 처리하지 않습니다.
- `ResultSet.close`, `Statement.close`, `Connection.setNetworkTimeout`을 구분합니다. 최초 JDBC 예외를 정리 전에 stderr에 기록하고, `probe-events.tsv`에 최초 실패 호출·읽은 행 수·EOF 여부를 남깁니다. 이 TSV에는 반환된 값이나 계정 정보를 넣지 않습니다.
- 성공 정리 후 연결이 이미 닫혔으면 성공으로 처리하지 않습니다.
- 기본 연결은 `selectMethod=direct;responseBuffering=adaptive`입니다. 대량 코호트/공변량 결과는 계속 배치로 읽습니다. full 버퍼링은 최대 2행 검사에만 적용됩니다.
- 기존 쿼리·소켓·외부 watchdog 시간 제한 및 자동 재시도 금지는 유지합니다. TLS 설정과 임상 후보 선정 규칙도 그대로입니다.

응답의 마지막 패킷이 실제로 오지 않는 경우 이 수정은 누락된 응답을 만들어내지 않습니다. 그런 경우 완전한 응답을 받는 실행 단계에서 실패하며, 수신·조회 오류와 정리 대기를 구분할 증거를 남깁니다. 실제 YUHS/HIWARE에서의 재검증이 필요합니다.

## 적용과 실행

실행 중인 분석 및 R/RStudio를 종료하고 패치 폴더에서 다음을 실행합니다. APPLY_FIX는 기존 파일의 해시나 편집 여부를 비교하지 않고 제공된 파일로 덮어쓴 뒤 FederatedPs를 자동 재설치합니다. RUN은 기관별 2명 설정으로 갱신되며 기존 파일은 patch-backups에 백업됩니다.

```powershell
& {
    $ErrorActionPreference = 'Stop'
    .\APPLY_FIX.ps1 -BundleRoot 'C:\FP'
    Set-Location 'C:\FP'
    .\07_CHECK_DB.ps1
    .\RUN.ps1
}
```

시작 표시: `[jdbc-probe-3; sql-plan-4]`. 07 검사가 실패하면 위 블록은 RUN으로 진행하지 않습니다. 07은 새 연결에서 SELECT 1, 모든 설정된 CARE_SITE, 명시적 연결 종료까지만 확인하며 임상 데이터 추출 성공을 보장하지 않습니다.

```powershell
# RUN 파일을 편집하지 않고 기관별 상한 변경
.\RUN.ps1 -PatientLimits @{1=200;2=100;3=300}
```

2명은 실행 점검용 상한입니다. 연구 적격성 조건 이후 대상군 또는 비교군이 비면 정상적으로 중단할 수 있습니다.

## 오류 발생 시 확인할 파일

07 검사: `C:\FP\FederatedPS\work\diagnostics\connection-*\diagnostic`의 `run.stderr.log`, `sql-diagnostics\probe-events.tsv`, `sql-diagnostics\operations.tsv`. 상위 `connection-*`의 스레드 진단도 함께 확인합니다. DB 비밀번호가 들어 있는 `windows\config\yuhs.Renviron`은 공유하지 않습니다.

RUN 실패: 출력된 run 폴더에 대해 `09_COLLECT_DIAGNOSTICS.ps1 -RunDirectory '<출력된 run 경로>'`를 실행합니다. 이번 수정의 probe-events.tsv도 수집됩니다.

`probe-events.tsv` 열: UTC 시각, R PID, 호출/단계, 상태, 읽은 행 수, EOF 도달 여부, 최초 실패 호출. `first-failure`가 있으면 이후 close보다 이 오류가 먼저입니다. EOF=TRUE만으로 전체 SQL 응답 완료를 뜻하지 않으며 getMoreResults와 정리가 모두 완료되어야 합니다.

## 검증 범위

번들의 Microsoft JDBC 9.2.0과 실제 R/rJava를 로컬 TDS 응답 모형에 연결해 검사했습니다. 0/1/2행, 한글/NULL, 나누어 도착하는 응답, 행 뒤의 SQL 오류, 종료 응답 누락을 확인했습니다. 기존 구현은 행 뒤의 오류를 놓치고 성공으로 반환하는 경우가 재현됐으며 새 구현은 원래 SQL 오류를 보고합니다. 이후 새 statement는 adaptive 설정을 유지합니다. 이는 실제 SQL Server 실행계획, Windows, HIWARE 통합시험을 대체하지 않습니다.

관련 공식 문서:
- https://learn.microsoft.com/en-us/sql/connect/jdbc/using-adaptive-buffering
- https://learn.microsoft.com/en-us/sql/connect/jdbc/reference/setresponsebuffering-method-sqlserverstatement


## 함께 수정한 integrity failure

실행 옵션/소스를 직접 수정하면 원본 SHA-256과 달라지는 것은 정상입니다.
APPLY_FIX와 10_UPDATE_PACKAGE는 번들 무결성 검사를 호출하지 않습니다. 기존 파일의 편집 여부와 해시 차이는 업데이트를 막지 않습니다.
설치 파일, 의존성, runtime-lock, git bundle은 계속 검증합니다.
원본과 모든 소스의 일치를 확인하려면 `00_VERIFY.ps1 -StrictSource`를 사용합니다.
수정한 패키지 소스를 설치까지 반영하려면 `RUN.ps1 -UpdatePackage` 또는
`10_UPDATE_PACKAGE.ps1` 후 RUN을 실행합니다. manifest를 임의로 삭제/재작성하지 않습니다.
