1. **승인된 계산 경계와 같은 프로세스 synthetic 검증을 구현했고, A/B/C/D 비교가 모두 통과했습니다.**

검토 가능한 소스는 별도 checkout인 [/tmp/cyclops_history](/tmp/cyclops_history)에 있습니다. 기준 commit은 요청한 `89dd48b18fcaa8cc4d88f235b1da38459ab912a3`이며, 패키지 버전은 3.7.1입니다.

| 변경 파일·함수                                                                                                                                                      | 역할과 재사용                                                                                |
| -------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| [CyclicCoordinateDescent.cpp](/tmp/cyclops_history/src/cyclops/CyclicCoordinateDescent.cpp:1669), [.h](/tmp/cyclops_history/src/cyclops/CyclicCoordinateDescent.h:199) | full fit 없는 초기화, 좌표 통계 조회, 합산 통계 갱신, 순서·종료 검사                        |
| `coordinateIncrement()`                                                                                                                                            | 기존`jointPrior->getDelta()`의 Laplace increment와 부호 처리 호출                          |
| `applyCoordinateIncrement()`                                                                                                                                       | 기존`applyBounds()`와 `updateSufficientStatistics()` 호출. 정상 fit도 같은 메서드를 사용 |
| `checkCoordinateConvergence()`                                                                                                                                     | 합산 likelihood에 prior를 한 번 더하고 기존 Lange 종료 판정 재사용                           |
| [RcppCyclopsInterface.cpp](/tmp/cyclops_history/src/RcppCyclopsInterface.cpp:132)                                                                                     | 기존 native 객체에 연결하는 5개 bridge                                                       |
| [CoordinateDescent.R](/tmp/cyclops_history/R/CoordinateDescent.R:64)                                                                                                  | 공개 입력 검증, sparse 입력 생성 경로, 기존`cyclopsFit`·예측 연결                         |

`ModelSpecifics`, prior 구현, `DESCRIPTION`은 수정하지 않았습니다. 새 dependency는 없습니다. 기존 bound 하한을 포함한 계산 규칙을 유지했으며 새로운 epsilon·ridge·optimizer는 추가하지 않았습니다.

2. **새 공개 API**

```r
initializeCyclopsCoordinateDescent(
  y, sx,
  prior = createPrior("laplace", exclude = "(Intercept)"),
  control = createControl(convergenceType = "lange"),
  startingCoefficients
)

getCyclopsCoordinateStatistics(object, covariate)

updateCyclopsCoordinate(object, covariate, gradient, curvature)

checkCyclopsCoordinateConvergence(object, logLikelihood = NULL)

getCyclopsCoordinateFit(object)
```

- 초기화는 이름으로 정합성을 검사한 `y`와 `dgCMatrix`, 명시적 초기 계수를 받아 기존 native 상태를 준비합니다. 로컬 fit을 실행하지 않습니다.
- 통계 조회는 현재 좌표의 `gradient`, `curvature`, `coefficient`, `bound`를 반환합니다.
- 갱신은 합산한 `g,h`로 기존 좌표 갱신을 실행하고 `increment`, 갱신된 계수·bound를 반환합니다.
- 종료 확인은 초기 상태와 각 sweep 뒤에 호출합니다. 두 site에는 같은 합산 log-likelihood를 전달합니다.
- fit accessor는 기존 `coef()`와 raw `predict()`에 연결합니다. 미수렴 상태의 계수에는 `ignoreConvergence=TRUE`가 필요하며, likelihood는 snapshot의 `log_likelihood` 필드를 사용합니다.

좌표 순서, sweep 경계, 종료 후 갱신, 일반 fit으로 변경된 상태를 검사합니다. 전체 native state를 내보내는 debug API는 추가하지 않았습니다.

3. **실행 환경·빌드·테스트**

기존 `feature-extraction-v2-rstudio`에서 R 4.6.1과 기존 빌드 도구를 사용했습니다. 컨테이너·시스템 패키지·전역 R library는 변경하지 않았습니다.

컨테이너 작업 경로는 `/tmp/cyclops-ccd-feasibility.p6a0pI`입니다.

| 구분              | 설치·로딩 경로                                                   |
| ----------------- | ----------------------------------------------------------------- |
| 수정 전 reference | `/tmp/cyclops-ccd-feasibility.p6a0pI/reference-library/Cyclops` |
| 수정본            | `/tmp/cyclops-ccd-feasibility.p6a0pI/modified-library/Cyclops`  |

각각 **별도 R 프로세스**에서 `.libPaths()`를 지정하고 `find.package("Cyclops")`의 정확한 경로를 확인했습니다. Reference 소스는 고정 commit의 `git archive`로 준비했습니다.

실행한 빌드·생성 명령은 다음과 같습니다. 아래 `W`는 위 컨테이너 작업 경로를 줄여 표기한 것입니다.

```sh
MAKEFLAGS=-j2 R CMD INSTALL --no-multiarch --with-keep.source \
  --library="$W/reference-library" "$W/reference-source"

MAKEFLAGS=-j2 R CMD INSTALL --no-multiarch --with-keep.source \
  --library="$W/modified-library" "$W/modified-source"
```

```r
Rcpp::compileAttributes(file.path(W, "modified-source"))
roxygen2::roxygenize(
  file.path(W, "modified-source"),
  roclets = c("rd", "namespace"),
  load_code = roxygen2::load_source
)
```

생성 도구의 무관한 metadata·기존 문서 변경은 포함하지 않았습니다. 최종 변경 파일과 관련 metadata **11개가 checkout과 빌드 소스에서 바이트 단위로 일치**했습니다.

Reference 프로세스에서는 `CYCLOPS_CCD_REFERENCE_OUTPUT`을 지정해 시험 파일을 `source()`했습니다. 수정본 프로세스에서는 그 결과를 `CYCLOPS_CCD_REFERENCE_INPUT`으로 지정하고 다음을 실행했습니다.

```r
testthat::test_file(
  file.path(W, "modified-source/tests/testthat/test-coordinateDescent.R"),
  reporter = "summary",
  stop_on_failure = TRUE
)
```

최종 focused 시험은 **6.632초**, 기존 소형 회귀 시험은 **3.693초**였습니다. 빌드는 모두 성공했으며 기존 Eigen 컴파일 경고가 있었습니다.

4. **비교 결과**

시험 설정은 [테스트 파일](/tmp/cyclops_history/tests/testthat/test-coordinateDescent.R:5)에 한곳으로 고정했습니다.

- seed `1701`, 초기 계수 모두 `0`, variance `1`, 따라서 `λ=√2`.
- CPU float64, 공통 비벌점 intercept, 고정 Laplace prior, CV 없음.
- Lange tolerance `1e-12`, 최대 5,000 sweep, 초기 bound `2`.
- 목적함수는 **합계 likelihood**와 prior 한 번을 사용합니다. 아래 objective 비교에는 기존 log-prior의 정규화 상수도 포함됩니다.

| Fixture                              | n / p¹ | Site 분할 | 수렴 sweep | 상태    |
| ------------------------------------ | ------: | --------: | ---------: | ------- |
| 기본 sparse                          |  80 / 8 |   40 + 40 |         14 | SUCCESS |
| 불균형·한 site에만 존재하는 feature | 73 / 12 |    9 + 64 |         15 | SUCCESS |
| n < p·중복/상관 feature             | 24 / 40 |    7 + 17 |         23 | SUCCESS |

¹ p는 intercept를 제외한 feature 수입니다.

허용오차는 실행 전에 고정했고 변경하지 않았습니다. 판정식은`|a-b| ≤ atol + rtol × max(|a|, |b|)`입니다.

- **좌표 기준:** `atol=1e-10`, `rtol=1e-10`
- **최종 기준:** `atol=1e-7`, `rtol=1e-7`

A는 수정 전 정상 fit, B는 수정 후 정상 fit, C는 새 API pooled 상태, D는 새 API 두 site 상태입니다.

| 비교 항목                                  |                              최대 절대오차 | 기준 | 결과 |
| ------------------------------------------ | -----------------------------------------: | ---- | ---- |
| A–B: 계수·objective·predictor·raw PS   |                                          0 | 최종 | 통과 |
| B–C: 최종 objective·predictor·raw PS    |                                          0 | 최종 | 통과 |
| B–C: 기본·불균형 fixture 계수            |                                          0 | 최종 | 통과 |
| C–D: pooled`g,h` 대 site 합             |                               `3.20e-14` | 좌표 | 통과 |
| C–D: coordinate increment                 |                               `2.67e-15` | 좌표 | 통과 |
| C–D: bound / beta                         |                `4.38e-15` / `3.33e-15` | 좌표 | 통과 |
| C–D: 좌표별 raw PS                        |                               `7.77e-16` | 좌표 | 통과 |
| sparse`Xβ` 대 predictor/cache           |                               `8.44e-15` | 좌표 | 통과 |
| 한 sweep: objective / predictor / PS       | `1.42e-14` / `1.33e-15` / `2.22e-16` | 좌표 | 통과 |
| 전체 sweep의 objective                     |                               `2.84e-14` | 좌표 | 통과 |
| A–D: 최종 objective                       |                               `2.84e-14` | 최종 | 통과 |
| A–D: 최종 predictor                       |                               `4.88e-15` | 최종 | 통과 |
| A–D: 최종 raw PS                          |                               `5.55e-16` | 최종 | 통과 |
| 별도 수식 검산:`g,h` / objective         |                `1.78e-14` / `1.42e-14` | 좌표 | 통과 |
| 초기 계수·PS, 조회 불변성, site 상태 격리 |                                          0 | 좌표 | 통과 |

모든 수치 비교의 `오차 / 허용오차` 최댓값은 `3.20e-4`로 1보다 작았습니다. n < p fixture도 objective·predictor·PS를 함께 검증했습니다. 기본 fixture에서는 실제 비영 계수와 penalty로 0이 된 계수가 모두 발생했습니다.

5. **회귀·실패 처리·남은 제약**

기존 `test-smallNormal.R`, `test-floatingPoint.R`, `test-predict.R`의 **8개 시험이 통과**했습니다. 원래 `skip()`으로 지정된 대형 속도 시험 1개는 실행되지 않았습니다.

잘못된 row/feature 대응, binary label 위반, nonfinite 입력·통계량, 잘못된 좌표 순서, 상태 변경, 최대 반복 도달에 대한 시험도 통과했습니다.

전역 zero column은 수정 전·후 정상 fit에서 계수 0으로 처리되고 PS가 일치했습니다. **새 API는 global curvature가 0인 갱신을 명시적으로 거절**합니다. 반면 한 site에만 없는 feature의 로컬 `g=h=0`은 유지하고 다른 site와 합산해 갱신했습니다.

종료 기준은 기존 **Lange objective 변화**입니다. 별도로 계산한 KKT residual은 기본·불균형·wide 순서로 `7.64e-6`, `1.20e-5`, `2.77e-6`였으며, 이를 종료 기준의 tolerance와 동일하게 해석하지 않았습니다. 기준·수정 정상 fit은 모두 SUCCESS, 경고 0개였습니다. 새 경로는 자동 recovery를 실행하지 않습니다.

전체 패키지 시험, 대규모 성능, 분리 worker·원격 실행, DataSHIELD, 실제 DB 및 OHDSI end-to-end 검증은 **이번 범위에서 실행하지 않았습니다**. 이번 결과는 작은 같은 프로세스 시험의 수치적 feasibility입니다.

6. **최종 diff와 새 파일**

`git diff --stat`:

```text
 NAMESPACE                               |   5 ++
 R/RcppExports.R                         |  20 +++++
 src/RcppCyclopsInterface.cpp            |  46 ++++++++++
 src/RcppExports.cpp                     |  64 +++++++++++++
 src/cyclops/CyclicCoordinateDescent.cpp | 155 ++++++++++++++++++++++++++++++--
 src/cyclops/CyclicCoordinateDescent.h   |  25 ++++++
 6 files changed, 306 insertions(+), 9 deletions(-)
```

아직 추적되지 않아 위 통계에 빠진 새 파일은 다음 3개입니다.

| 새 파일                                                                                                    |  크기 | 필요성                               |
| ---------------------------------------------------------------------------------------------------------- | ----: | ------------------------------------ |
| [R/CoordinateDescent.R](/tmp/cyclops_history/R/CoordinateDescent.R)                                         | 209줄 | 공개 API와 입력 검증                 |
| [man/initializeCyclopsCoordinateDescent.Rd](/tmp/cyclops_history/man/initializeCyclopsCoordinateDescent.Rd) |  96줄 | 5개 공개 함수의 생성 문서            |
| [tests/testthat/test-coordinateDescent.R](/tmp/cyclops_history/tests/testthat/test-coordinateDescent.R)     | 412줄 | 독립 reference 및 A/B/C/D·오류 검증 |

합계 **9개 파일, +1,023 / −9줄**입니다. `git diff --check`는 통과했고 새 파일의 공백 검사에서도 오류가 없었습니다.

`ps-model`과 상위 `he-cdm`의 기존 변경, `.env`, `AGENTS.md`는 보존했습니다. commit·push·추가 단계 진행은 하지 않았습니다.

<oai-mem-citation>
<citation_entries>
MEMORY.md:18-19|note=[scope and evidence boundaries]
MEMORY.md:29-30|note=[final worktree scope check]
</citation_entries>
<rollout_ids>
01a02cfb-97dd-71e2-a711-1a343aa4fbb8
</rollout_ids>
</oai-mem-citation>
