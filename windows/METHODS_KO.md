# v0.0.10 업데이트

전처리 우선 실행 핫픽스는 [PREPROCESS_FIRST_KO.md](PREPROCESS_FIRST_KO.md), 기관별 진행 표시는 [PROGRESS_PERFORMANCE_KO.md](PROGRESS_PERFORMANCE_KO.md)를 참조하십시오.
`-ExtractionWorkers` 기본값은 1입니다. 모든 기관 전처리를 마친 뒤 모델을 계산합니다.
`-StatusSeconds 10`으로 10초 간격 상태 기록을 선택할 수 있습니다. 이 절이 아래 0.0.8 안내보다 우선합니다.

# YUHS 실행 방법·환자 제한·추출 재사용 (0.0.8)

이 안내는 05번 YUHS 실행에 관한 이전 안내보다 우선합니다. 기존 Windows 폐쇄망 환경의
FederatedPs를 0.0.8로 업데이트하며, 설치된 Cyclops proximal CCD/R/Java/JDBC는 그대로 사용합니다.

## 업데이트

작은 업데이트 ZIP을 기존 번들과 다른 폴더에 풉니다. 진행 중인 분석이 끝난 뒤 R/RStudio를 닫고,
PowerShell에서 실행합니다. 경로가 다르면 실제 경로로 바꾸십시오.

```powershell
& {
    $ErrorActionPreference = 'Stop'
    Set-ExecutionPolicy -Scope Process Bypass -Force
    cd C:\FederatedPS_Methods_Update
    .\APPLY_UPDATE.ps1 -BundleRoot 'C:\FederatedPS_YUHS_Offline'
    cd C:\FederatedPS_YUHS_Offline
    .\08_UPDATE_PACKAGE.ps1
    .\05_RUN_YUHS.ps1 -Test $false -Methods local-only,pooled -PatientLimits @{1=200; 2=200; 3=200}
}
```

08은 인터넷 없이 FederatedPs의 R 코드와 SQL만 설치합니다. R/Rtools/Java/Cyclops/JDBC를
재설치하거나 01번 설치를 반복하지 않습니다. 기존 common.R의 SSL 설정, yuhs.Renviron,
분석 결과는 보존합니다. 0.0.7 복구 번들(5d46d68) 및 연결 점검 핫픽스(acb0606)에서 적용할 수 있습니다.

## 선택 옵션

| 옵션 | 의미 |
| --- | --- |
| `-Methods local-only` | 세 기관에서 각각 별도 PS 모델 1개씩 |
| `-Methods pooled` | 세 기관의 데이터를 서버 내에서 합쳐 PS 모델 1개 |
| `-Methods federated` | 세 기관과 aggregator로 연합 모델 학습 |
| `-Methods local-only,pooled` | 위 두 방법만 실행; aggregator를 시작하지 않음 |
| `-Methods local-only,pooled,federated` | 같은 추출 데이터로 세 방법 모두 실행 |
| `-PatientLimits @{1=200; 2=100; 3=300}` | **기관별 상한 개별 지정**(예: 세브란스 200, 강남 100, 용인 300명) |
| `-PatientLimit 200` | 세 기관 공통 기본 상한 200명; PatientLimits의 기관별 값이 우선 |
| `-PatientLimit 0` | 제한 없음(기본값) |
| `-Test $false` | 실제 YUHS DB; 최초 추출 때 HIWARE 연결 필요 |
| `-Test $true` | DB 접속 없는 합성 CDM(기본값, 원본 120명/기관) |
| `-RebuildData` | 완료 캐시를 재사용하지 않고 새로 추출하여 새 체크포인트 저장 |
| `-CacheDirectory 'D:\YUHS_cache'` | 추출 캐시 위치 지정; 재사용할 때도 같은 경로 사용 |

Methods는 비어 있지 않은 어떤 조합이든 가능합니다. 생략하면 federated만 실행합니다.
PatientLimits에서 생략한 기관은 PatientLimit 값을 사용하며, 둘 다 생략하면 0(무제한)입니다.
키는 `yuhs-sites.json`에 등록된 **CARE_SITE_ID(site_id)**이며 현재 1, 2, 3입니다.
기관명을 옵션에 하드코딩하지 않습니다. ID와 표시명은 설정 파일에서 읽습니다.
각 상한 값은 0 또는 2 이상의 정수여야 합니다. 세 기관을 모두 명시하면 의도하지 않은 전체 추출을 피할 수 있습니다.

PowerShell 콘솔에서 쉼표로 나누거나 `-Methods @('local-only','pooled')`를 사용하십시오.

실제 DB를 빠르게 시험하려면 `-Test $false`와 기관별 `-PatientLimits`를 함께 지정합니다.
Test=true는 실제 DB의 작은 표본이 아니라 별도로 만든 합성 자료입니다.

환자 제한은 사이트별 연구 노출 후보가 만들어진 뒤, **CohortMethod 생성 전에** 적용합니다.
가장 이른 노출의 군을 기준으로 두 군을 번갈아 선택하고 군 안에서는 PERSON_ID 순서로
선택하는 결정적 시험 표본입니다. 선정 환자의 모든 노출 행을 보존해 기존 첫 노출/교차 노출/
관찰기간/나이/세척기간 규칙을 그대로 적용합니다. 최종 환자는 200명보다 적을 수 있으며,
한 군이 비면 실패합니다. 이때 해당 기관의 상한을 늘리십시오. 임상 기준을 자동으로 완화하지 않습니다.
이는 대표성 있는 무작위 표본이 아니므로 전체 연구 결과로 해석하지 마십시오.

기관 분리, 방문 연결 감사, 약물 개념/노출 후보 조회는 제한 적용 전에 수행합니다.
따라서 앞단 SQL 지연까지 없어지거나 전체 실행이 일정 시간 내 끝난다고 보장하지 않습니다.
원본 CDM은 변경하지 않고 연결별 임시 테이블만 제한합니다.

## 언제 다시 추출하지 않는가

기관마다 **CohortMethod 코호트 + 공변량 추출 + 분석 대상자 구성**이 끝나면,
행렬·환자 매핑·연구 정의를 완성된 체크포인트로 저장합니다. 다음 실행은 조건이 일치하고
체크섬 검증에 성공한 기관의 데이터를 자동으로 재사용합니다. 화면과 로그에 `CACHE HIT`가 표시됩니다.
예를 들어 severance 완료 후 gangnam에서 실패하면 다음 실행은 severance를 재사용합니다.

- 기존 화면의 **CohortMethod 6/10 완료만으로는 충분하지 않습니다.** 뒤의 공변량 전송과
  분석 대상자 구성까지 끝나 `CACHE SAVED`가 기록되어야 합니다.
- 이미 끝난 이전 버전 실행에는 이 체크포인트가 없으므로 자동 변환/재사용하지 않습니다.
- 연구·scenario·실제/합성 구분·기관 매핑·해당 기관의 환자 상한·DB 설정·추출 소스·관련 패키지 버전이
  달라지면 다른 캐시를 사용합니다. **한 기관의 상한만 바꾸면 그 기관만 다시 추출**합니다.
  200명 캐시를 제한 없는 실행에서 재사용하지 않습니다.
- Methods, BlockSize, Alpha를 바꿔도 같은 추출 캐시를 재사용할 수 있습니다. 모델은 새로 학습합니다.
  중단된 Cyclops 반복 계산 자체를 이어서 실행하는 기능은 아닙니다.
- DB 내용이 같은 주소에서 갱신된 사실은 자동 감지하지 못합니다. 최신 데이터를 다시 읽으려면
  `-RebuildData`를 지정하십시오. 다음 실행부터 새로 완료된 체크포인트를 사용합니다.
- 불완전한 `.partial` 저장은 재사용하지 않습니다. 완료 캐시가 손상되면 오류를 내며,
  `-RebuildData`로 새로 추출할 수 있습니다. 실행 결과는 새 RunId 폴더에 저장합니다.

예: 200명 시험 결과를 만든 다음, 추출을 재사용해서 federated만 실행:

```powershell
.\05_RUN_YUHS.ps1 -Test $false -Methods federated -PatientLimits @{1=200; 2=200; 3=200}
```

예: 최신 전체 데이터로 local-only와 pooled 실행:

```powershell
.\05_RUN_YUHS.ps1 -Test $false -Methods local-only,pooled -PatientLimits @{1=0; 2=0; 3=0} -RebuildData
```

## 결과와 로그

기본 결과 폴더는 `FederatedPS\work\methods\<RunId>`입니다. 화면에도 절대 경로를 표시합니다.

- `local\1`, `local\2`, `local\3`: 기관별 모델
- `pooled`: 합쳐서 학습한 모델
- `federated\<site_id>`: 동일 환자에 다시 매핑하고 검증한 연합 결과
- 각 모델 폴더의 `result.rds`(환자별 PS), `model.rds`, `coefficients.csv`
- `summary.csv`: 선택 방법의 인원·변수·반복·학습시간 요약
- `baselines\run.stdout.log`, `run.stderr.log`, `progress.jsonl`, 루트 `monitor.log`
- `data-cache.json`: 기관별 재사용 여부·체크포인트 위치·환자 수
- `extraction\<site_id>\sql-diagnostics`: 새 추출의 SQL 단계와 오류
- `federated-runtime\<RunId>`: federated를 선택했을 때 집계기/기관별 원래 실행 로그
- `SUCCESS.txt`: 선택한 모든 모델 검증과 R 프로세스의 정상 종료를 확인한 뒤 생성

기본 캐시는 `FederatedPS\work\yuhs-cache`입니다. **실제 환자 ID·공변량을 포함**하며
서버 내 분석 자료로 관리해야 합니다. 이 캐시나 환자별 결과를 반출용 진단 ZIP에 넣지 마십시오.
pooled는 세 기관의 환자별 데이터를 이 서버 안에서 합칩니다. federated의 교환 폴더에는
기존과 같이 좌표 통계만 보냅니다. 세 방법은 같은 환자와 변수 정의를 사용합니다.

모든 모델은 고정 Laplace prior variance=1, 비벌점 절편, 교차검증 없는 in-sample PS입니다.
기본 BlockSize=1, Alpha=1을 유지하며 기존 proximal CCD 옵션을 그대로 전달합니다.
local-only/pooled는 집계 콜백이 자체 통계만 반환하므로 네트워크/파일 통계 교환이 없습니다.
단계·로그·현재 sweep 진행률은 표시하지만 SQL 내부 행 처리율이나 전체 ETA를 추정하지 않습니다.

## 검증 범위

PowerShell에서 모든 7개 Methods 조합과 환자/캐시 옵션 전달, 단일 추출 후 연합 연결,
실패/잘못된 완료 기록 거부를 검증했습니다. R에서는 360명 합성 CDM의 환자·변수 정렬,
기관 간 중복 거부, PS-계수 일치, 환자 제한, 캐시 재사용/무효화/손상/부분 저장을 검사했습니다.
업데이트 적용·재적용·실패 복구와 SSL/설정/결과 보존도 검사했습니다.
이 환경에는 대상 Windows/HIWARE 및 설치된 Cyclops/OHDSI 실행 환경이 없어 실제 DB 전체 실행과
native 수치 통합 시험은 수행하지 못했습니다. 현장에서 DB 없이 실행 경로를 먼저 확인하려면:

```powershell
.\05_RUN_YUHS.ps1 -Test $true -Methods local-only,pooled,federated -PatientLimits @{1=20; 2=20; 3=20}
```
