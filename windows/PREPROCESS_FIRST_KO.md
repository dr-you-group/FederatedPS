# FederatedPs 0.0.10: 전처리 우선 실행기 핫픽스 (2026-10-26)

기존 0.0.10 오프라인 번들에 적용하는 실행기 업데이트입니다. R 패키지 버전은
0.0.10 그대로이며, 08_UPDATE_PACKAGE.ps1이나 설치 파일을 다시 실행할 필요가 없습니다.

## 실행 순서

기본 `ExtractionWorkers`를 1로 변경합니다. 0.0.8처럼 하나의 R 프로세스가
site_id 순서대로 전처리하고, 모든 기관의 입력을 준비·검증한 뒤 모델을 계산합니다.

1. site_id=1: 완료 캐시 확인 → 필요하면 DB 연결, 기관 분할, CohortMethod, 공변량, 설계행렬 → 완료 캐시 저장.
2. site_id=2: 같은 전처리 과정.
3. site_id=3: 같은 전처리 과정.
4. 전체 기관 입력 검증 → 선택한 local-only 모델 → pooled 모델 → 선택 시 federated 모델.

기관 ID는 설정에서 읽으며 기본 순서는 숫자 오름차순입니다. `-Sites`를 지정하면 그 순서를 사용합니다.
0.0.8도 세 기관 데이터를 하나의 SQL로 한 번에 조회한 것이 아니라, 한 R 프로세스 안에서
기관별 추출을 순서대로 수행했습니다. 이번 핫픽스는 그 실행 경로를 기본으로 사용합니다.
기관별 진행률·SQL 문장 로그·환자 제한·SSL 설정·Cyclops proximal CCD는 유지합니다.

초기 확인 실패 기관을 나중에 별도 프로세스로 재실행하는 복구 방식은 추가하지 않습니다.
기존 R의 최초 확인 쿼리 오류에 대한 제한된 1회 재연결 정책은 변경하지 않습니다.
명시적으로 `-ExtractionWorkers 2` 또는 `3`을 쓰면 기존 병렬 경로를 선택하므로,
이전 명령에 있던 `-ExtractionWorkers 3`을 제거하거나 `1`로 바꾸십시오.

## 적용과 실행

현재 분석을 종료하고 R/RStudio를 닫은 뒤, ZIP을 별도 폴더에 풀어
APPLY_UPDATE.ps1가 있는 폴더에서 실행합니다. 실행 중인 프로세스를 자동 종료하지 않습니다.

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

처음에는 site_id=1만 extracting이고 2·3은 queued인 것이 정상입니다.
로그는 `FederatedPS\work\methods\<RunId>\baselines\`에 기록됩니다.
SQL 진단은 같은 실행 폴더의 `extraction\<site_id>\sql-diagnostics\`에 있습니다.

## 시간 제한과 캐시

180초는 각 기관이 실제 DB 연결을 시작한 때부터 계산합니다. 대기 중인 2·3의 시간은
세지 않습니다. 연결 확인이 완료되면 이 제한은 해제되며, 이후 추출은 기존 DB 쿼리 제한을 사용합니다.
이 분석 안에서 동시 기관 추출이 만드는 DB 부하를 줄이는 수정입니다. 실제 HIWARE/DB 연결 지연이
병렬 부하 때문인지는 아직 검증하지 못했으며, 순차 실행에서도 연결 자체의 문제는 남을 수 있습니다.

이번 핫픽스는 DESCRIPTION, R 코드, SQL, R 런타임 스크립트를 변경하지 않습니다.
따라서 **현재 0.0.10에서 정상 완료된 기관 캐시는 동일 조건에서 재사용**합니다.
기관별 환자 제한, study/scenario, 접속 설정 등 기존 캐시 조건은 그대로 적용됩니다.
중단된 기관의 부분 추출은 재개하지 않으며, 0.0.8/0.0.9 캐시를 0.0.10 캐시로 변환하지 않습니다.
기존 결과·캐시·SSL 수정·접속 설정 파일을 덮어쓰거나 삭제하지 않습니다.

## 검증 범위

PowerShell 테스트로 기본값 1의 전달, 단일 전처리 작업 경로, 모든 전처리 후 모델 실행,
방법 선택 7개 조합, 명시적 2/3 옵션, 기관별 타이머와 진행 표시를 검증합니다.
0.0.10과 캐시 지문을 구성하는 파일이 모두 동일한지도 비교합니다.
실제 Windows/HIWARE/SQL Server 통합 실행과 성능 측정은 이 환경에서 수행하지 않았습니다.
