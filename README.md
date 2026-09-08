FederatedPs
===========

CohortMethod 데이터로 plaintext federated PS를 적합한다. 각 병원의 gradient/Hessian을
pda로 합산하고 Cyclops의 Bayesian LASSO/CCD로 업데이트한다. 환자 행과 PS는 병원에 남는다.
공식 OHDSI 패키지는 아니며, CohortMethod 데이터와 matching·balance 함수를 사용한다.

Installation
============

R 패키지는 다음 명령으로 설치한다.

```r
install.packages("remotes")
remotes::install_github("dr-you-group/FederatedPS")
```

Docker, Docker Compose와 Python 3가 필요하다. 최초 설정 시 아래 파일을 복사하고
세 RStudio 비밀번호와 각 DB 계정을 입력한다. 실제 설정 파일은 Git에서 제외한다.

```sh
cp .env.example .env
cp .Renviron.mimic.example .Renviron.mimic
cp .Renviron.synpuf.example .Renviron.synpuf
chmod 600 .env .Renviron.mimic .Renviron.synpuf
python3 start.py
```

| 역할 | RStudio | 로컬 CDM | 연결 설정 |
| --- | --- | --- | --- |
| Aggregator | http://localhost:38787 | 없음 | 없음 |
| MIMIC | http://localhost:38788 | `ohdsi.mimiciv` | `.Renviron.mimic` |
| SynPUF | http://localhost:38789 | `ohdsi.synpuf23` | `.Renviron.synpuf` |

각 환경은 별도 컨테이너와 Docker network에서 실행된다. 사이트는 자기 DB 설정과
`work/<site>`만 마운트한다. pda 모델·통계량은 Docker의 `federatedps-slides_exchange`
volume으로 교환한다. 작은 파일을 반복 교환하므로 호스트 폴더 대신 이 volume을 사용한다.
DB 접근 범위는 각 DB 계정의 권한으로 제한한다. `PGHOST`에는 컨테이너에서 접근할
수 있는 DB 주소를 지정한다. R 패키지, JDBC 드라이버와 `DESCRIPTION`에 고정된
[Cyclops fork](https://github.com/dr-you-group/Cyclops)는 이미지에 설치된다.

How to run
==========

`rstudio`로 로그인하여 `/home/rstudio/FederatedPs/FederatedPs.Rproj`를 연다.
같은 실행의 세 세션에서 다음 스크립트를 실행한다.

```r
# Aggregator
source("extras/RunAggregator.R")

# MIMIC 및 SynPUF: 각각 자기 RStudio에서 실행
source("extras/CodeToRun.R")
```

`CodeToRun.R`는 CohortMethod의 `drug_era` 경로로 **65세 이상, 첫 기록 atorvastatin
(1545958) 대 simvastatin (1539403)** cohort를 준비한다. 별도 cohort 테이블은 필요 없다.
같은 날짜의 양쪽 약물 사용자는 CohortMethod 규칙에 따라 제외한다. PS에는 노출 전
90일의 진단·약물·시술·검사 발생 및 연령군·성별을 사용하고, 비교 약물 feature와
달력 연도는 제외한다. 관찰기간 90일을 요구하지 않으며, 신규 복용자 연구로 해석하지 않는다.
MIMIC의 제한된 관찰 이력과 SynPUF의 합성 데이터 특성상 이 설정은 **구현 검증용**이다.

Feature ID는 두 사이트의 정렬된 합집합을 사용하고, 공통 0인 열만 제거한다.
이 예제의 feature는 이진값이므로 scale은 1이다. Laplace variance는 1로 고정하며
intercept는 penalize하지 않는다. CV나 outcome 분석은 수행하지 않는다.
각 사이트의 `population`에 PS가 추가되고 Andromeda 객체는 사용 후 닫힌다.
새 적합을 시작할 때는 `python3 start.py`로 새 run ID를 생성한다.

Tests
=====

```sh
R CMD build .
R CMD check FederatedPs_0.0.1.tar.gz
```

테스트는 synthetic 데이터로 분리 R 프로세스의 pooled 수치 일치, 행·feature 정합성,
CohortMethod matching·balance 및 수렴 실패 보고를 검증한다. 실제 CDM 검증에는
접속 가능한 DB와 각 사이트의 두 치료군이 필요하다.
