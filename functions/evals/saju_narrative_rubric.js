'use strict';

/**
 * 서사 품질 rubric — Phase 5-4.
 *
 * 자동 검사(hard check / quality signal)로는 "읽고 공감되는가"를 판정할 수 없다.
 * rubric은 그 부분을 1~5점으로 평가하기 위한 기준이다.
 *
 * 중요: 이 rubric으로 모델이 채점한 결과는 **참고치(model judge)**다.
 * 사람 평가와 같은 것으로 보고하지 않는다. 최종 판단은 blind sample을 사람이 읽고 한다.
 */

const RUBRIC_CRITERIA = Object.freeze([
  {
    key: 'evidenceFidelity',
    title: 'Evidence fidelity',
    question: '실제 제공된 근거만 사용했는가',
  },
  {
    key: 'specificity',
    title: 'Specificity',
    question: '다른 사용자에게 그대로 붙여도 되는 generic 문구가 아닌가',
  },
  {
    key: 'emotionalResonance',
    title: 'Emotional resonance',
    question: '사용자가 자신의 연애 경험을 떠올릴 만한가',
  },
  {
    key: 'sceneConcreteness',
    title: 'Scene concreteness',
    question: '메시지·데이트·갈등의 실제 장면이 있는가',
  },
  {
    key: 'balance',
    title: 'Balance',
    question: '장점만 칭찬하거나 단점만 경고하지 않는가',
  },
  {
    key: 'actionability',
    title: 'Actionability',
    question: '바로 적용할 수 있는 행동이나 대화법이 있는가',
  },
  {
    key: 'koreanNaturalness',
    title: 'Korean naturalness',
    question: '번역투·부자연스러운 조사·AI 말투가 없는가',
  },
  {
    key: 'distinctiveness',
    title: 'Distinctiveness',
    question: '다른 case 결과와 충분히 구분되는가',
  },
  {
    key: 'nonFatalism',
    title: 'Non-fatalism',
    question: '운명·이별·성공을 단정하지 않는가',
  },
  {
    key: 'readability',
    title: 'Readability',
    question: '모바일에서 읽기 좋은 길이와 구조인가',
  },
]);

const RUBRIC_KEYS = Object.freeze(RUBRIC_CRITERIA.map((c) => c.key));

/** 품질 gate 기준. Stage B 진입 여부를 이 값으로 판정한다. */
const QUALITY_GATE = Object.freeze({
  minOverallAverage: 4.0,
  minPerCriterionAverage: 3.6,
  minImprovementOverBaseline: 0.4,
  improvementCriteria: Object.freeze(['specificity', 'emotionalResonance']),
  maxGenericDuplicateRatio: 0.1,
  /** 이 유사도 이상이면 서로 "generic 중복 결과"로 센다. */
  duplicateSimilarityThreshold: 0.45,
});

/** judge에게 주는 채점 지시. 후보 모델 이름은 절대 넣지 않는다. */
function rubricJudgeSystemPrompt() {
  return [
    '당신은 한국어 연애 콘텐츠의 품질을 평가하는 심사자입니다.',
    '주어진 결과물을 아래 10개 항목에 대해 각각 1~5점으로 채점합니다.',
    '',
    '- 1점: 기준을 전혀 만족하지 않음',
    '- 3점: 무난하지만 인상적이지 않음',
    '- 5점: 기준을 뚜렷하게 만족함',
    '',
    ...RUBRIC_CRITERIA.map((c) => `- ${c.key} (${c.title}): ${c.question}`),
    '',
    '평가 규칙:',
    '- 어떤 모델이 썼는지 알 수 없으며, 추측하지 않는다.',
    '- 문장이 길고 화려하다는 이유로 점수를 올리지 않는다.',
    '- "근거 목록"에 없는 내용을 단정하면 evidenceFidelity를 낮게 준다.',
    '- 다른 사람에게 그대로 붙여넣어도 말이 되는 문장이 많으면 specificity를 낮게 준다.',
    '- 점수만 주고 사족을 붙이지 않는다.',
  ].join('\n');
}

/** rubric 채점용 strict json schema. */
const RUBRIC_JSON_SCHEMA = Object.freeze({
  name: 'saju_narrative_rubric_scores',
  strict: true,
  schema: {
    type: 'object',
    properties: Object.fromEntries(
      RUBRIC_KEYS.map((key) => [key, { type: 'integer' }]),
    ),
    required: RUBRIC_KEYS.slice(),
    additionalProperties: false,
  },
});

/** blind pairwise 비교 지시. 후보 이름을 노출하지 않고 A/B로만 부른다. */
function pairwiseJudgeSystemPrompt() {
  return [
    '당신은 한국어 연애 콘텐츠 두 편(A, B)을 비교하는 심사자입니다.',
    '두 결과물은 같은 사주 근거로 만들어졌습니다. 아래 다섯 질문에 A 또는 B로 답합니다.',
    '',
    '- moreMine: 어느 결과가 더 "내 이야기"처럼 느껴지는가',
    '- moreConcrete: 어느 결과가 더 구체적인가',
    '- lessCliche: 어느 결과가 덜 상투적인가',
    '- moreUsefulAdvice: 어느 결과의 조언이 더 쓸 만한가',
    '',
    'ungroundedClaim에는 "근거 목록"을 벗어난 문장이 있는 쪽을 적습니다.',
    '둘 다 있거나 둘 다 없으면 "none"을 적습니다.',
    '',
    'A와 B의 제시 순서는 의미가 없습니다. 순서 때문에 한쪽을 선호하지 않습니다.',
    '어떤 모델이 썼는지 추측하지 않습니다.',
  ].join('\n');
}

const PAIRWISE_JSON_SCHEMA = Object.freeze({
  name: 'saju_narrative_pairwise_verdict',
  strict: true,
  schema: {
    type: 'object',
    properties: {
      moreMine: { type: 'string', enum: ['A', 'B'] },
      moreConcrete: { type: 'string', enum: ['A', 'B'] },
      lessCliche: { type: 'string', enum: ['A', 'B'] },
      moreUsefulAdvice: { type: 'string', enum: ['A', 'B'] },
      ungroundedClaim: { type: 'string', enum: ['A', 'B', 'both', 'none'] },
    },
    required: [
      'moreMine',
      'moreConcrete',
      'lessCliche',
      'moreUsefulAdvice',
      'ungroundedClaim',
    ],
    additionalProperties: false,
  },
});

/** 점수 배열의 평균. */
function average(values) {
  const nums = values.filter((v) => typeof v === 'number' && Number.isFinite(v));
  if (nums.length === 0) return null;
  return nums.reduce((sum, v) => sum + v, 0) / nums.length;
}

/** case별 rubric 점수 목록 → 항목별/전체 평균. */
function aggregateScores(scoreList) {
  const perCriterion = {};
  for (const key of RUBRIC_KEYS) {
    perCriterion[key] = average(scoreList.map((s) => s?.[key]));
  }
  const overall = average(Object.values(perCriterion));
  return { perCriterion, overall, sampleCount: scoreList.length };
}

/**
 * 품질 gate 판정.
 *
 * @param {{ hardViolations: number, privacyViolations: number, schemaFailures: number,
 *           fatalismViolations: number, aggregate: object, baselineAggregate: object|null,
 *           genericDuplicateRatio: number }} input
 */
function evaluateQualityGate(input) {
  const failures = [];
  const {
    hardViolations,
    privacyViolations,
    schemaFailures,
    fatalismViolations,
    aggregate,
    baselineAggregate,
    genericDuplicateRatio,
  } = input;

  if (hardViolations > 0) failures.push({ code: 'hardViolation', value: hardViolations });
  if (privacyViolations > 0) failures.push({ code: 'privacyViolation', value: privacyViolations });
  if (schemaFailures > 0) failures.push({ code: 'schemaFailure', value: schemaFailures });
  if (fatalismViolations > 0) failures.push({ code: 'fatalismViolation', value: fatalismViolations });

  if (!(aggregate?.overall >= QUALITY_GATE.minOverallAverage)) {
    failures.push({ code: 'overallBelowGate', value: aggregate?.overall ?? null });
  }
  for (const key of RUBRIC_KEYS) {
    const value = aggregate?.perCriterion?.[key];
    if (!(value >= QUALITY_GATE.minPerCriterionAverage)) {
      failures.push({ code: 'criterionBelowGate', criterion: key, value: value ?? null });
    }
  }
  if (baselineAggregate) {
    for (const key of QUALITY_GATE.improvementCriteria) {
      const delta = (aggregate?.perCriterion?.[key] ?? 0) - (baselineAggregate?.perCriterion?.[key] ?? 0);
      if (!(delta >= QUALITY_GATE.minImprovementOverBaseline)) {
        failures.push({ code: 'improvementBelowGate', criterion: key, value: delta });
      }
    }
  }
  if (!(genericDuplicateRatio < QUALITY_GATE.maxGenericDuplicateRatio)) {
    failures.push({ code: 'genericDuplicateRatio', value: genericDuplicateRatio });
  }

  return { passed: failures.length === 0, failures };
}

/**
 * Terra를 고를 수 있는지 판정한다. 기본값은 품질 우선(Sol)이다.
 * 조건을 하나라도 못 채우면 Sol을 고른다.
 */
function canPreferBalancedCandidate({
  balanced,
  quality,
  balancedPairwiseLoss,
  latencyOrCostMeaningful,
}) {
  if (!balanced?.gate?.passed || !quality?.gate?.passed) return false;
  const overallGap = (quality.aggregate.overall ?? 0) - (balanced.aggregate.overall ?? 0);
  if (overallGap > 0.2) return false;
  for (const key of QUALITY_GATE.improvementCriteria) {
    const gap = (quality.aggregate.perCriterion[key] ?? 0) - (balanced.aggregate.perCriterion[key] ?? 0);
    if (gap > 0.2) return false;
  }
  if (balancedPairwiseLoss) return false;
  return !!latencyOrCostMeaningful;
}

module.exports = {
  RUBRIC_CRITERIA,
  RUBRIC_KEYS,
  QUALITY_GATE,
  RUBRIC_JSON_SCHEMA,
  PAIRWISE_JSON_SCHEMA,
  rubricJudgeSystemPrompt,
  pairwiseJudgeSystemPrompt,
  average,
  aggregateScores,
  evaluateQualityGate,
  canPreferBalancedCandidate,
};
