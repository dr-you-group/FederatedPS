1. **실제로 확인한 version/ref와 호출 경로**

   [AGENTS.md](/workspace/he-cdm/ps-model/AGENTS.md)를 읽었습니다. **확인한 설치본과 공식 소스에는 요구사항을 충족하는 federated Cyclops CCD 공개 실행 경로가 없습니다.** 기존 계산을 재사용하되, Cyclops에 작은 공개 계산 경계를 추가해야 합니다.

   현재 상태는 다음과 같습니다.

   | 구분 | 확인 결과 |
   |---|---|
   | 현재 프로젝트 | `ps-model`에는 `.env`, `AGENTS.md`만 존재. R 패키지·소스·테스트·cohort/feature 명세 없음 |
   | Git | 상위 `/workspace/he-cdm` 저장소 소속. HEAD `e8a3ae80aafe478b0a8d619dcf644e770d512508`. 현재 파일들은 HEAD와 구분해야 하는 미추적 작업 트리 |
   | 기존 DB 설정 | `.env`에 PostgreSQL 연결 변수 존재. DB명 `ohdsi`, 포트 `5432`. 계정·접속 주소·비밀번호는 출력하지 않음 |
   | 인접 적재 코드 | [create_cdm_schemas.R](/workspace/he-cdm/load_data/create_cdm_schemas.R:25)에 `mimiciv`, `synpuf`, CDM `5.3` 명시 |
   | 미확인 설정 | 실제 PostgreSQL 서버 버전, vocabulary 버전, 승인된 analysis schema·output directory·프로젝트 실행 환경 |
   | 호스트 | WSL2 Ubuntu 26.04, PATH에서 `R`, `Rscript`, `g++`, `psql` 없음 |
   | 기존 협력 환경 | 별도 RStudio 컨테이너 3개 확인. 어느 것도 `ps-model`을 마운트하지 않음 |

   **설치 패키지는 프로젝트 설정과 구분했습니다.**

   - `feature-extraction-v2-rstudio`, `feature-extraction-rstudio`: R **4.6.1**, Cyclops **3.7.1**, CohortMethod **6.0.3**, FeatureExtraction **3.14.0**. DatabaseConnector **7.2.0**, CommonDataModel **1.0.1**, Andromeda **1.2.1**, Matrix **1.7-6**, Rcpp **1.1.2**도 확인했습니다.
   - 이 설치본의 주 라이브러리는 `/usr/local/lib/R/site-library`이며, 주요 OHDSI 패키지는 RSPM 설치 메타데이터가 있습니다. **원본 Git SHA는 없어 아래 공식 commit과 동일한 빌드라고 확정할 수 없습니다.**
   - 별도 legacy `web-rstudio`: R **4.1.1**, Cyclops **3.1.2**, CohortMethod **4.2.3**, FeatureExtraction **3.2.0**입니다.
   - 세 컨테이너 모두 `pda`, `DSI`, `DSOpal`, `opalr`, `distcomp`, `opencpu`는 설치되어 있지 않았습니다.

   공식 참고 소스는 다음 ref로 확인했습니다. commit 링크는 전체 SHA를 가리킵니다.

   | 공식 참고 저장소 | 확인 ref | 소스 version | 확인 commit |
   |---|---|---|---|
   | OHDSI/Cyclops | main | 3.7.1 | [89dd48b18fca](https://github.com/OHDSI/Cyclops/commit/89dd48b18fcaa8cc4d88f235b1da38459ab912a3) |
   | OHDSI/CohortMethod | main | 6.0.3 | [dd1a2a856ef6](https://github.com/OHDSI/CohortMethod/commit/dd1a2a856ef608547a99d3db2d60d5c872f80dc6) |
   | OHDSI/FeatureExtraction | main | 3.14.0 | [53266f0233c2](https://github.com/OHDSI/FeatureExtraction/commit/53266f0233c2ee7cae127e8669ad35b0d60406ae) |
   | dr-you-group/Metis | master | 0.0.1 | [c07606848d9a](https://github.com/dr-you-group/Metis/commit/c07606848d9a24ea7fa1b682da4ea563fdb823f0) |

   실제 경로는 아래와 같습니다. 내부 구현은 추적 근거이며, 프로젝트에서 호출할 공개 API와 구분했습니다.

   | 파일·함수 | 역할 |
   |---|---|
   | FeatureExtraction `R/DefaultCovariateSettings.R` → `createCovariateSettings()`; `R/GetCovariates.R` → `getDbCovariateData()` | 승인된 cohort table에서 site 내부 sparse covariate 추출 |
   | CohortMethod `R/PsFunctions.R` → `createPs()` | population 정렬·feature 선택·tidy → Cyclops 변환·적합·예측 → PS population |
   | Cyclops `R/NewDataConversion.R` → `convertToCyclopsData()` | `rowId,y`와 `rowId,covariateId,covariateValue` 입력. Andromeda covariates를 batch로 native sparse 저장소에 적재 |
   | Cyclops `R/ModelFit.R` → `fitCyclopsModel()` | prior/control 설정 후 native 적합 또는 CV 실행 |
   | `src/cyclops/engine/ModelSpecifics.h/.hpp` | logistic likelihood, 좌표 gradient/Hessian, sparse iterator, predictor cache |
   | `src/cyclops/priors/CovariatePrior.h` → `LaplacePrior::getDelta()` | Laplace penalty를 반영한 좌표 increment |
   | `src/cyclops/CyclicCoordinateDescent.cpp` → `ccdUpdateBeta()` → `applyBounds()` → `updateSufficientStatistics()` | 순차 좌표 갱신, step 제한, coefficient/cache 갱신 |
   | Cyclops `R/Predict.R` → `predict.cyclopsFit()` | native 예측 또는 covariateId 기반 새 입력 예측. 반환값 이름은 rowId |
   | CohortMethod `matchOnPs()`, `computeCovariateBalance()`, `plotPs()` | site 내부 matching 및 diagnostics |

   근거: [OHDSI PS 경로](https://github.com/OHDSI/CohortMethod/blob/dd1a2a856ef608547a99d3db2d60d5c872f80dc6/R/PsFunctions.R#L62), [sparse 변환](https://github.com/OHDSI/Cyclops/blob/89dd48b18fcaa8cc4d88f235b1da38459ab912a3/R/NewDataConversion.R#L417), [CPU CCD 순서](https://github.com/OHDSI/Cyclops/blob/89dd48b18fcaa8cc4d88f235b1da38459ab912a3/src/cyclops/CyclicCoordinateDescent.cpp#L1207).

2. **재사용 가능한 기능과 새로 필요한 기능**

   **기존 Cyclops의 수학과 계산을 유지할 수 있습니다.** 표준 unweighted logistic–Laplace MAP 목적함수는 다음과 같습니다. 연구에서 사용할 feature 변환·벌점 제외 집합·site 항은 아직 미정입니다.

   \[
   F(\beta)=
   \sum_s\sum_{i\in s}
   \left[\log(1+\exp(\eta_i))-y_i\eta_i\right]
   +\sum_{j\in P}\lambda_j|\beta_j|,
   \qquad
   \eta_i=x_i^\top\beta,\quad
   \lambda_j=\sqrt{2/v_j}.
   \]

   Cyclops의 `variance`는 여기의 \(v_j\)입니다. likelihood를 합산하므로, 관측치 수로 나눈 loss의 lambda와 혼동하면 안 됩니다. [Laplace 구현](https://github.com/OHDSI/Cyclops/blob/89dd48b18fcaa8cc4d88f235b1da38459ab912a3/src/cyclops/priors/CovariatePrior.h#L249)

   같은 global \(\beta\)에서 각 site가 계산할 값은

   \[
   g_{sj}=\sum_{i\in s}x_{ij}(p_i-y_i),\qquad
   h_{sj}=\sum_{i\in s}x_{ij}^{2}p_i(1-p_i)
   \]

   이고, global 좌표 계산에는 \(g_j=\sum_sg_{sj}\), \(h_j=\sum_sh_{sj}\)를 사용합니다. **prior는 global 목적함수에 한 번만 적용합니다.**

   실제 CPU CCD는 이 gradient/Hessian으로 기존 Laplace increment를 계산하고, 부호가 바뀌면 zero에서 멈추는 처리를 수행합니다. 이어서 increment를 \([-d_j,d_j]\)로 제한하고, 다음 bound를

   \[
   d_j\leftarrow\max(2|\delta_j|,\ d_j/2,\ 10^{-3})
   \]

   로 갱신합니다. 이후 해당 sparse 열의 행에 \(\eta_i\leftarrow\eta_i+\delta_jx_{ij}\)를 적용하고 관련 cache를 갱신합니다. `¼Σx²` 같은 고정 curvature로 교체하는 안이 아닙니다. [step 제한](https://github.com/OHDSI/Cyclops/blob/89dd48b18fcaa8cc4d88f235b1da38459ab912a3/src/cyclops/CyclicCoordinateDescent.cpp#L1745), [cache 갱신](https://github.com/OHDSI/Cyclops/blob/89dd48b18fcaa8cc4d88f235b1da38459ab912a3/src/cyclops/engine/ModelSpecifics.hpp#L1941)

   | 재사용할 기능 | 실제로 부족한 기능 |
   |---|---|
   | FE cohort/feature 추출과 기존 자료형 | 두 site에 동일한 feature 순서·제거 결정·정규화 배율 적용 |
   | Cyclops sparse 저장소, float64 계산, Laplace/CCD/bounds/cache | full fit 없이 상태 초기화, 좌표 통계 조회, global 통계로 기존 좌표 update를 호출하는 **공개 API** |
   | Cyclops pooled/local-only 적합 | global initialization·수렴 판정·CV 조정 |
   | Cyclops 예측, CohortMethod matching/diagnostics | site 내부 PS population 연결과 실제 입출력 검증 |
   | 선정 도구의 통신·인증·세션·직렬화 | 작은 coordinator loop와 등록된 site 계산 함수 |

   중요한 재사용 제약은 네 가지입니다.

   - **공개 `gradient()`만으로는 부족합니다.** 좌표 curvature·bound·cache update를 함께 제어할 수 없습니다. `.cyclopsSetBeta` 등의 내부 함수나 protected C++ 메서드를 공개 확장점으로 취급하지 않겠습니다. [NAMESPACE](https://github.com/OHDSI/Cyclops/blob/89dd48b18fcaa8cc4d88f235b1da38459ab912a3/NAMESPACE)
   - **기관별 `createPs()` 호출은 federated 준비 과정이 될 수 없습니다.** 내부 `tidyCovariateData()`가 기본적으로 희귀·중복 feature를 제거하고 feature별 관측 max로 나눕니다. 기관별 처리는 pooled와 다른 행렬·penalty를 만듭니다. 외부 global 배율을 주입하는 공개 옵션도 확인되지 않았습니다. 따라서 공통 전처리 결정을 적용하는 작은 입력 계산 경계가 필요합니다. [FE 정규화](https://github.com/OHDSI/FeatureExtraction/blob/53266f0233c2ee7cae127e8669ad35b0d60406ae/R/Normalization.R#L50)
   - **수렴·CV도 그대로 추적해야 합니다.** 기본 `"gradient"` 수렴 기준은 KKT norm이 아니라 `Σyη`의 변화입니다. `"lange"`는 log-likelihood와 log-prior를 사용합니다. 기존 실패 회복에는 bound 축소와 `"lange"` 재적합이 있으므로 발생 여부와 최종 상태를 남겨야 합니다. CV는 auto/grid 후보마다 재적합하고 held-out likelihood를 평가합니다. 기관별 CV 결과나 coefficient 평균으로 대체할 수 없습니다. [control·회복 경로](https://github.com/OHDSI/Cyclops/blob/89dd48b18fcaa8cc4d88f235b1da38459ab912a3/R/ModelFit.R), [수렴 구현](https://github.com/OHDSI/Cyclops/blob/89dd48b18fcaa8cc4d88f235b1da38459ab912a3/src/cyclops/CyclicCoordinateDescent.cpp#L626)
   - **Metis는 joint training 구현이 아닙니다.** 예제는 크기별 독립 적합 후 `getPsModel()` → `predictPs()`로 모델을 이전합니다. 설정 → 준비 → 적합 → matching → 진단의 흐름만 참고하고, 오래된 API·하드코딩·encoder·모델 이전 경로는 가져오지 않습니다. [Metis 예제](https://github.com/dr-you-group/Metis/blob/c07606848d9a24ea7fa1b682da4ea563fdb823f0/extras/TestCode.r#L301)

3. **실행 도구 비교와 선정**

   **기본 실행 도구로 DataSHIELD/DSI + DSOpal을 조건부 선정합니다.** 서버는 Opal + Rock 조합입니다. 기존 사용 기반은 발견하지 못했으며, 표준성이나 사용 경험을 선정 근거로 삼지 않았습니다.

   | 후보 | 확인 version/ref | 실제 API와 판단 |
   |---|---|---|
   | pda | 1.3.2, master [ee90de152f68](https://github.com/Penncil/pda/commit/ee90de152f6886bcba1404cce9cde11cb31f3777) | `pda()`, `pdaPut/Get/Sync()`. 파일·단계 교환은 가능하지만 공개 custom-model 등록점과 지속 worker 원격 실행 경로는 확인되지 않음 |
   | DSI / DSOpal / opalr | 1.8.0 / 1.5.0 / 3.6.1, 각각 master [5196cff6b789](https://github.com/datashield/DSI/commit/5196cff6b789ca64829bc5563572f498793568b1), [07deca654e66](https://github.com/datashield/DSOpal/commit/07deca654e66c93d732add137572bc43607be36e), [0a7f19ea887f](https://github.com/obiba/opalr/commit/0a7f19ea887f49dd06aa34dbfbdce1c75881f5b4) | `datashield.login()`, `datashield.assign.expr()`, `datashield.aggregate()`. 설치·허용된 사용자 함수를 지속 R 세션에서 호출 가능 |
   | distcomp | 1.3-4, master [42ffaf1d5f1e](https://github.com/bnaras/distcomp/commit/42ffaf1d5f1e589bc9168594f73ff2d6cdfd3c68) | `makeWorker/Master()`, `createWorkerInstance()`, `executeMethod()`. 호출마다 RDS 상태를 읽고 저장하여 살아 있는 Cyclops pointer/cache 보존에 부적합 |

   요구사항별 비교는 다음과 같습니다.

   | 기준 | pda | DataSHIELD/DSI | distcomp |
   |---|---|---|---|
   | 사용자 계산·집계 | summary 교환 가능. 반복 participant 실행 조정이 추가로 필요 | 등록 함수 실행 가능. 결과는 site별로 반환되므로 coordinator가 합산 |
   | sparse·native 상태 | 사용자 프로세스가 직접 유지해야 함 | 동일 Rserve 세션에 sparse 객체·environment·native pointer를 유지하는 구조 |
   | 반복 CCD | 별도 polling/barrier 또는 내부 확장 부담 | 공개 assign/aggregate 호출에 작은 계산 함수 연결 가능 |
   | float64 | `pdaPut()` 기본 `digits=4`; 조정·왕복 검증 필요 | 반환은 R binary serialization. 요청 표현식의 수치 정밀도는 별도 검증 필요 |
   | 환자 자료 비전송 | summary만 교환하도록 제한 가능 | local loader와 집계 함수만 등록하는 경로 가능 |
   | 주요 운영 부담 | R≥4.1, C++ 의존성, 공유 저장소/PDA 서버, participant 실행 관리 | R≥4.3인 DSI, DSOpal/opalr, site별 Opal·Rock·Rserve·Java·인증·세션 관리 |
   | distcomp의 추가 제약 | — | — | OpenCPU, 매 호출 상태 복원, JSON 정밀도 경로. `homomorpheR`, `gmp`도 Imports |
   | license | Apache 2.0 | DSI/DSOpal LGPL≥2.1, opalr GPL-3, Opal/Rock GPLv3 | LGPL≥2 |

   pda의 공개 교환 기능은 재사용 가능하지만, 이번 용도의 원격 worker 실행과 상태 수명 관리를 채우려면 추가 코드가 커집니다. distcomp는 실제 `executeMethod()`가 `readRDS()`/`saveRDS()`를 사용하므로 native pointer를 유지한다고 볼 수 없습니다. [pda 구현](https://github.com/Penncil/pda/blob/ee90de152f6886bcba1404cce9cde11cb31f3777/R/pda.R), [distcomp 상태 처리](https://github.com/bnaras/distcomp/blob/42ffaf1d5f1e589bc9168594f73ff2d6cdfd3c68/R/distcomp-package.R#L498)

   DataSHIELD 선정의 핵심 근거는 **지속 세션과 공개 사용자 계산 확장점**입니다. Opal assignment는 서버 symbol에 객체를 직접 저장하고, Rock는 세션별 R 연결을 유지합니다. coordinator에는 계산 결과만 반환할 수 있습니다. 다만 이것은 소스상 가능성으로, Cyclops 연결의 실행 성공은 아직 아닙니다. [Opal assignment](https://github.com/obiba/opal/blob/06305ae4ca625ae23a72c162adbf77ee6df77add/opal-datashield/src/main/java/org/obiba/opal/datashield/RestrictedAssignmentROperation.java#L29), [Rock 세션](https://rockdoc.obiba.org/en/latest/introduction.html#stateful-r-sessions)

   **float64에는 확인 과제가 남습니다.** 반환은 `application/octet-stream` → `unserialize()`지만 요청은 기본 `deparse()`를 거칠 수 있습니다. 공개 R `deparse1(..., control=c("keepNA","keepInteger","hexNumeric"))`로 만든 character expression 전달을 시험 후보로 삼되, 서버 parser까지 포함한 왕복 보존을 확인해야 합니다. [반환 경로](https://github.com/datashield/DSOpal/blob/07deca654e66c93d732add137572bc43607be36e/R/datashield.aggregate.r#L14), [문자열 요청 경로](https://github.com/datashield/DSOpal/blob/07deca654e66c93d732add137572bc43607be36e/R/datashield.assign.r#L14), [R 정밀도 옵션](https://stat.ethz.ch/R-manual/R-devel/library/base/html/deparseOpts.html)

   조사한 서버 소스는 Opal `6.0-SNAPSHOT` [06305ae4ca62](https://github.com/obiba/opal/commit/06305ae4ca625ae23a72c162adbf77ee6df77add), Rock `2.2-SNAPSHOT` [fb770fb96192](https://github.com/obiba/rock/commit/fb770fb96192db66626e16acf78f9690360a4691)입니다. 배포 대상으로 확정한 버전은 아닙니다. 현재 설치 문서는 Java 21과 R/Rserve 운영을 요구하므로 **R 패키지 설치만으로 분산 실행이 준비되지는 않습니다.** [Opal 설치](https://opaldoc.obiba.org/en/latest/admin/installation.html), [Rock 설치](https://rockdoc.obiba.org/en/latest/admin/installation.html)

   실행 도구 자체의 fork는 필요하지 않을 것으로 판단합니다. 이 선택이 성립하지 않으면 실패 근거를 보고하고 멈추며, 자작 실행 framework로 확대하지 않습니다.

4. **미정 사항과 작은 feasibility test**

   실제 연구 명세에서 미정인 사항은 다음과 같습니다.

   | 영역 | 승인·확인이 필요한 내용 |
   |---|---|
   | Cohort | 약제/concept set, 연령, first-recorded의 정확한 의미, index, baseline, washout, 중복 노출·재진입 처리 |
   | Feature | 공통 vocabulary/feature 의미, 시간창, 노출 정의 관련 제외 feature, binary/continuous 및 missing 의미 |
   | 목적함수 | intercept/site 효과, 벌점 제외, 공통 정규화·희귀/중복 제거, 초기값, CV와 local-only tuning 정책 |
   | 비교 환경 | 실제 pooled benchmark를 허용할 별도 계산 위치. federated coordinator로 환자 자료를 보내는 경로와 구분 필요 |
   | 운영 | 승인 analysis schema·output directory, 사용할 R 환경, worker 배치·release·자원·세션 timeout |
   | 규모 | `p≈10,000`, `n≈3,000`은 성능 목표만 확인. 실제 cohort 크기는 조회하지 않음 |

   **Outcome 없는 OHDSI 입력도 시험이 필요합니다.** CM 6.0.3의 `getDbCohortMethodData()`는 outcome 조회를 항상 수행하며, 빈 outcome을 건너뛰는 경로는 확인되지 않았습니다. `outcomeIds=integer(0)`이나 dummy outcome을 검증된 해결책으로 제안하지 않습니다. [추출 코드](https://github.com/OHDSI/CohortMethod/blob/dd1a2a856ef608547a99d3db2d60d5c872f80dc6/R/DataLoadingSaving.R#L252), [실제 SQL](https://github.com/OHDSI/CohortMethod/blob/dd1a2a856ef608547a99d3db2d60d5c872f80dc6/inst/sql/GetOutcomes.sql)

   최소 후보는 승인 cohort와 FE 결과를 공개 `Andromeda::andromeda()` 및 export된 `CohortMethodData` 자료형으로 연결하는 함수 하나입니다. 공식 simulation도 이 구성 방식을 사용하지만, 공개 변환 constructor는 없습니다. 따라서 outcome 없는 입력의 matching/balance 호환성을 먼저 검증해야 합니다. [공개 자료형](https://github.com/OHDSI/CohortMethod/blob/dd1a2a856ef608547a99d3db2d60d5c872f80dc6/R/CohortMethodData.R#L17), [공식 구성 사례](https://github.com/OHDSI/CohortMethod/blob/dd1a2a856ef608547a99d3db2d60d5c872f80dc6/R/Simulation.R#L359)

   승인 후 작은 시험은 다음 순서가 적절합니다.

   | 시험 | 완료 판단 |
   |---|---|
   | 같은 프로세스의 pooled 1-state 대 2-site simulation | 코드로 만든 작은 sparse fixture, 고정 variance·초기값에서 좌표별 `g,h,δ,bound,β,η`와 objective 일치 |
   | 입력·수치 경계 | row/feature 불일치, binary label 위반, nonfinite, site에 없는 열, zero column, 극단 predictor를 명확하게 처리 |
   | 실패·상태 경계 | 미수렴, 누락 site, stale/중복 update, session 재시작을 오류로 식별. increment 중복 적용 방지 |
   | 분리 worker 시험 | 두 실제 세션 사이에서 native 상태 유지와 float64 왕복 확인. 같은 프로세스 simulation과 구분 |
   | OHDSI 출력 시험 | outcome 없이 `rowId,treatment,propensityScore` → `matchOnPs()` → `computeCovariateBalance()` 실행, 분모·행 대응 검증 |
   | 작은 통신 측정 | 좌표별 요청 수·latency·sweep 시간을 측정한 뒤 목표 규모 시험 가능 여부 판단 |

   Cyclops 입력에는 불일치 rowId를 자동 제거하는 경로가 있으므로 **호출 전에 오류로 검출**해야 합니다. 또한 `createPs()`는 PS를 소수 10자리로 반올림하므로 수치 동등성 비교는 raw prediction에서 수행해야 합니다. Matching은 최소 PS column과 기존 metadata를 사용하고, 비공개 `computePreferenceScore()`·`computeIptw()`를 호출하지 않습니다.

   **통신 비용은 작다고 보장할 수 없습니다.** 정확한 CCD는 좌표 \(j\)의 global update를 모든 site에 적용한 뒤 \(j+1\) 통계를 계산해야 합니다. `p=10,000`이면 sweep마다 약 10,000개의 순차 동기화가 필요합니다. 좌표당 전체 비용이 10 ms라면 약 100초/sweep이라는 계산이며, 실측값은 아닙니다. CV에서는 후보·fold·반복 적합만큼 증가합니다. 전체 gradient를 한 번에 계산해 동시에 갱신하면 원래 CCD와 달라집니다.

5. **단계별 최소 변경 파일·테스트·완료 조건**

   아래는 **승인 후 변경 후보**이며, 이번에는 생성하거나 수정하지 않았습니다.

   | 단계 | 최소 변경 파일 | 테스트·완료 조건 |
   |---|---|---|
   | A. Cyclops 계산 경계 | 별도 upstream의 `src/cyclops/CyclicCoordinateDescent.h/.cpp`, `src/RcppCyclopsInterface.cpp`, 신규 `R/CoordinateDescent.R` | 기존 sparse·prior·bound·cache를 호출하는 초기화/통계/global 좌표 적용/완료 경계. 같은 프로세스 pooled 대 2-state 좌표 시험 통과 |
   | A의 공개 API·생성 파일 | `DESCRIPTION`, `R/RcppExports.R`, `src/RcppExports.cpp`, `NAMESPACE`, `man/*.Rd`, focused `tests/testthat/test-*.R` | Rcpp 등록은 `Rcpp::compileAttributes()`, export·문서는 roxygen으로 생성. 기존 pooled 적합 회귀 확인 |
   | B. 프로젝트 패키지 하나 | 신규 `DESCRIPTION`, `NAMESPACE`, `R/PreparePsData.R`, `R/FederatedPs.R`, `R/SiteComputation.R`, 해당 `man/*.Rd`·테스트 | OHDSI 입력, global loop, site 계산이라는 실제 경계만 구성. outcome 없는 자료형·공통 전처리·PS 출력 시험 통과 |
   | C. 선정 도구 연결 | 신규 `inst/DATASHIELD`, B의 실행 함수와 분리 worker 테스트 보완 | 허용된 assign/aggregate 함수 등록. 두 site 응답·상태·정밀도·실패 검사 통과 |
   | D. global CV와 비교 | B의 기존 함수·focused test 확장, 실제 실행 흐름용 `extras/RunPs.R` 하나 | 같은 fold/전처리/후보 정책에서 pooled–federated CV 확인. pooled/local-only/federated 모델 모두 site 내부 matching/diagnostics 사용 |
   | E. 규모·실DB | 별도 승인 후 기존 실행 파일 사용 | 작은 통신 시험에 근거해 성능 목표 시험. 실제 DB 실행은 승인 명세·환경·출력 위치 확정 후 별도 수행 |

   Cyclops의 신규 공개 API는 **상태 초기화, 좌표 통계 조회, 합산 통계로 기존 CCD 적용, 종료 검증**에 한정하는 안입니다. 현재 존재하는 API라고 주장하지 않습니다. coordinator가 합산 `g,h`를 모든 worker에 전달하고, 동일한 `β/prior/bound`를 가진 worker가 기존 update를 적용하도록 하면 coordinator용 가짜 Cyclops 데이터나 별도 optimizer class를 만들 필요가 없습니다. 동일 increment와 상태를 확인해야 하며, 이는 논리적으로 하나의 global update입니다.

   프로젝트의 직접 dependency 후보는 `Cyclops`, `FeatureExtraction`, `CohortMethod`, `Andromeda`, 실제 사용 시 `DatabaseConnector`·`SqlRender`, 실행 계층의 `DSI`·`DSOpal`입니다. `opalr`는 DSOpal 경로의 의존성으로 둡니다. 테스트·문서 도구는 `testthat`·`roxygen2`이며, Cyclops에는 transport dependency를 추가하지 않습니다. 한 패키지에 client 함수와 서버 등록 함수를 함께 두는 구조가 가능합니다. [DataSHIELD 패키지 확장 방식](https://datashield.github.io/DSLite/articles/developing-with-dslite.html)

   OHDSI·Metis의 Apache 2.0 표기를 확인했습니다. Cyclops 변경은 별도 upstream patch로 관리하며 attribution·변경 notice를 유지합니다. 참고 저장소 vendor, 실행 도구 fork, 새 optimizer 구현은 기본 계획에 없습니다. OHDSI 자료형 연결이나 기존 계산 호출만으로 해결되지 않으면 추가 변경 이유를 보고하고 범위 확대 전에 멈춥니다.

   **첫 패치 제안 범위는 A의 공개 계산 경계와 같은 프로세스 synthetic test까지입니다.** 서버 설치·global CV·실DB 실행은 첫 패치에 포함하지 않습니다.

   이번에 실행한 것은 `git status --short`, `git rev-parse HEAD`, `git diff --stat`, 파일·설정의 제한된 읽기, `docker ps`/선별 `docker inspect`, 컨테이너의 `Rscript --vanilla`를 통한 `installed.packages()`·함수 정의 조회, 공식 소스의 메모리 내 HTTP 읽기입니다. 초기 shell은 bwrap namespace 오류로 실패했고, 읽기 전용 escalation 이후 확인했습니다.

   **모델·synthetic test·분리 worker·DB 시험은 실행하지 않았습니다. 변경 파일·새 dependency·새 public API는 모두 0개입니다.** 종료 시 Git 상태는 시작과 같았습니다. 상위 저장소의 기존 5개 삭제 표시와 `load_data/`, `ps-model/` 미추적 상태를 보존했고, 계획 파일도 저장하지 않았습니다.

<oai-mem-citation>
<citation_entries>
MEMORY.md:18-19|note=[read-only planning scope and evidence boundaries]
MEMORY.md:29-30|note=[final git status check and no analysis execution]
</citation_entries>
<rollout_ids>
01a02cfb-97dd-71e2-a711-1a343aa4fbb8
</rollout_ids>
</oai-mem-citation>
