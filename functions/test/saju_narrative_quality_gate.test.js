'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const { computeSajuChart } = require('../lib/saju/saju_engine_v2');
const { buildPersonalSajuEvidence } = require('../lib/saju/saju_evidence_v1');
const { buildCompatibilityEvidence } = require('../lib/saju/compatibility_evidence_v1');
const {
  NARRATIVE_SCHEMA_VERSION,
  NARRATIVE_PROMPT_VERSION,
  PERSONAL_SECTION_KEYS,
  COMPATIBILITY_SECTION_KEYS,
  PERSONAL_NARRATIVE_JSON_SCHEMA,
  COMPATIBILITY_NARRATIVE_JSON_SCHEMA,
  toPublicPersonalNarrative,
  toPublicCompatibilityNarrative,
  isValidPublicNarrative,
  collectPublicText,
} = require('../lib/saju/narrative_schema_v3');
const {
  buildPersonalEvidenceCatalog,
  buildCompatibilityEvidenceCatalog,
  validatePersonalGrounding,
  validateCompatibilityGrounding,
} = require('../lib/saju/narrative_grounding');
const {
  runHardChecks,
  runQualitySignals,
  textSimilarity,
} = require('../lib/saju/narrative_quality_checks');
const {
  modelFamilyOf,
  samplingParamsFor,
  classifyError,
  generateStructuredNarrative,
  NarrativeGenerationError,
  FAILURE_KINDS,
} = require('../lib/saju/narrative_client');
const {
  buildPersonalCases,
  buildCompatibilityCases,
} = require('../evals/saju_narrative_cases');
const {
  RUBRIC_KEYS,
  QUALITY_GATE,
  aggregateScores,
  evaluateQualityGate,
  canPreferBalancedCandidate,
} = require('../evals/saju_narrative_rubric');
const {
  estimateRun,
  promptFor,
  parseArgs,
  PRICING_USD_PER_MTOK,
  CANDIDATES,
} = require('../evals/saju_narrative_eval');

// Phase 5-4 Stage A — 품질 gate 계약.
//
// 여기서는 외부 API를 호출하지 않는다. schema 계약, grounding 검증,
// 금지 문구 검사, 평가 세트 커버리지, gate 판정만 확인한다.

// ── 합성 입력 (production 데이터 아님) ─────────────────────────────────────

const FULL_INPUT = { year: 1994, month: 5, day: 12, birthTimeKnown: true, birthTimeMinutes: 545 };
const DATE_ONLY_INPUT = { year: 1991, month: 9, day: 3, birthTimeKnown: false, birthTimeMinutes: null };

function chartOf(input) {
  return computeSajuChart(input);
}

function personalContext(input) {
  const chart = chartOf(input);
  const evidence = buildPersonalSajuEvidence(chart);
  return { evidence, catalog: buildPersonalEvidenceCatalog(evidence) };
}

function compatibilityContext(firstInput, secondInput) {
  const firstChart = chartOf(firstInput);
  const secondChart = chartOf(secondInput);
  const firstEvidence = buildPersonalSajuEvidence(firstChart);
  const secondEvidence = buildPersonalSajuEvidence(secondChart);
  const evidence = buildCompatibilityEvidence({
    firstChart,
    secondChart,
    firstPersonalEvidence: firstEvidence,
    secondPersonalEvidence: secondEvidence,
  });
  return { evidence, catalog: buildCompatibilityEvidenceCatalog(evidence) };
}

/** 모델이 돌려줄 법한 정상 개인 응답을 만든다. */
function personalModelResponse(catalog, overrides = {}) {
  // confidence는 메타 근거라 관찰 claim의 근거가 될 수 없다. 관찰 가능한 것만 쓴다.
  const refs = catalog.filter((c) => c.kind !== 'confidence').map((c) => c.id);
  const section = (body, index) => ({
    claims: [
      { text: body, type: 'observation', groundingRefs: [refs[index % refs.length]] },
    ],
  });
  const base = {
    characterType: '🌿 신중한 다정형',
    summary:
      '마음이 생겨도 먼저 확 다가가기보다 상대의 반응을 몇 번 확인하는 편이에요. 그래서 처음에는 조용해 보여도, 편해지면 표현이 훨씬 부드러워져요.',
    reasons: [
      { icon: '💬', text: '답장 속도보다 말투 변화를 먼저 살펴요.' },
      { icon: '🧭', text: '약속을 정할 때 상대 일정부터 물어보는 편이에요.' },
      { icon: '🌱', text: '서운한 일이 있어도 바로 말하기까지 시간이 걸려요.' },
    ],
    personalSections: {
      loveStyle: section('처음 두세 번의 대화에서는 질문을 더 많이 하는 쪽이에요.', 0),
      affectionStyle: section('좋아지면 연락 시간이 조금씩 길어져요.', 1),
      conflictPattern: section('서운하면 말수가 줄고 답장 간격이 벌어져요.', 2),
      emotionalNeed: section('약속이 지켜질 때 마음이 놓이는 편이에요.', 3),
      attractionPattern: section('표현이 분명한 사람에게 편안함을 느껴요.', 4),
      growthAdvice: {
        claims: [
          {
            text: '서운함을 쌓아두면 상대가 눈치채기 어려워요.',
            type: 'observation',
            groundingRefs: [refs[5 % refs.length]],
          },
        ],
        action: '오늘은 마음에 걸린 일 하나를 짧게 먼저 말해보세요.',
      },
    },
  };
  return { ...base, ...overrides };
}

function compatibilityModelResponse(catalog, overrides = {}) {
  const refs = catalog.filter((c) => c.kind !== 'confidence').map((c) => c.id);
  const section = (body, index) => ({
    claims: [
      { text: body, type: 'observation', groundingRefs: [refs[index % refs.length]] },
    ],
  });
  const base = {
    characterType: '🌊🔥 속도가 다른 두 사람',
    summary:
      '처음에는 대화 리듬이 잘 맞아서 금방 편해질 수 있어요. 다만 감정을 확인하는 방식이 달라서 중간에 한 번은 속도를 맞춰야 해요.',
    reasons: [
      { icon: '💬', text: '한 사람이 먼저 말을 꺼내는 편이에요.' },
      { icon: '⏳', text: '다른 한 사람은 생각을 정리할 시간이 필요해요.' },
      { icon: '🤝', text: '약속을 정하는 방식에서 차이가 드러나요.' },
    ],
    relationshipStory:
      '처음 몇 주는 서로의 말투를 익히는 시간이에요. 한 사람이 분위기를 열면 다른 한 사람이 이야기를 이어가요. 답장이 늦어지는 날에는 오해가 생길 수 있어요. 그때 짧게라도 상황을 알려주면 편해져요.',
    compatibilitySections: {
      initialChemistry: section('첫 대화에서 질문을 주고받는 리듬이 잘 맞아요.', 0),
      communicationFlow: section('약속을 정할 때 의견이 빨리 모이는 편이에요.', 1),
      differencePoint: section('한 사람은 바로 말하고, 다른 한 사람은 시간을 두고 말해요.', 2),
      conflictScene: section('답장이 하루 늦어지면 서운함이 생길 수 있어요.', 3),
      repairConversation: {
        claims: [
          {
            text: '감정을 따지기 전에 상황부터 짧게 공유하면 대화가 다시 열려요.',
            type: 'observation',
            groundingRefs: [refs[4 % refs.length]],
          },
        ],
        examplePhrase: '어제 답장이 늦어서 미안해요. 그때 정신이 없었어요.',
      },
      participantAdvice: {
        first: '먼저 말하기 전에 한 박자만 기다려주세요.',
        second: '생각이 정리되기 전이라도 지금 상태만 알려주세요.',
      },
    },
  };
  return { ...base, ...overrides };
}

// ── Structured Output schema 계약 ────────────────────────────────────────

test('strict schema는 additionalProperties를 막고 모든 필드를 required로 둔다', () => {
  const check = (node, pathLabel) => {
    if (!node || typeof node !== 'object') return;
    if (node.type === 'object') {
      assert.equal(node.additionalProperties, false, `${pathLabel}: additionalProperties`);
      const properties = Object.keys(node.properties || {});
      assert.deepEqual(
        [...(node.required || [])].sort(),
        properties.sort(),
        `${pathLabel}: required가 모든 property를 포함해야 한다`,
      );
    }
    for (const [key, child] of Object.entries(node.properties || {})) {
      check(child, `${pathLabel}.${key}`);
    }
    if (node.items) check(node.items, `${pathLabel}[]`);
  };
  for (const schema of [PERSONAL_NARRATIVE_JSON_SCHEMA, COMPATIBILITY_NARRATIVE_JSON_SCHEMA]) {
    assert.equal(schema.strict, true);
    check(schema.schema, schema.name);
  }
});

test('개인 응답이 공개 payload v3로 변환된다', () => {
  const { catalog } = personalContext(FULL_INPUT);
  const publicNarrative = toPublicPersonalNarrative(personalModelResponse(catalog));
  assert.equal(publicNarrative.schemaVersion, NARRATIVE_SCHEMA_VERSION);
  assert.equal(publicNarrative.relationshipStory, null);
  assert.equal(publicNarrative.compatibilitySections, null);
  assert.deepEqual(Object.keys(publicNarrative.personalSections), PERSONAL_SECTION_KEYS);
  assert.ok(isValidPublicNarrative(publicNarrative, { kind: 'personal' }));
});

test('궁합 응답이 공개 payload v3로 변환된다', () => {
  const { catalog } = compatibilityContext(FULL_INPUT, DATE_ONLY_INPUT);
  const publicNarrative = toPublicCompatibilityNarrative(compatibilityModelResponse(catalog));
  assert.equal(publicNarrative.personalSections, null);
  assert.deepEqual(
    Object.keys(publicNarrative.compatibilitySections),
    [...COMPATIBILITY_SECTION_KEYS, 'participantAdvice'],
  );
  assert.ok(isValidPublicNarrative(publicNarrative, { kind: 'compatibility' }));
});

test('required 필드가 비면 공개 payload 검증에 실패한다', () => {
  const { catalog } = personalContext(FULL_INPUT);
  const raw = personalModelResponse(catalog);
  raw.personalSections.growthAdvice.action = '   ';
  assert.equal(isValidPublicNarrative(toPublicPersonalNarrative(raw), { kind: 'personal' }), false);

  const compat = compatibilityModelResponse(compatibilityContext(FULL_INPUT, DATE_ONLY_INPUT).catalog);
  compat.compatibilitySections.repairConversation.examplePhrase = '';
  assert.equal(
    isValidPublicNarrative(toPublicCompatibilityNarrative(compat), { kind: 'compatibility' }),
    false,
  );
});

test('공개 payload에는 groundingRefs가 남지 않는다', () => {
  const { catalog } = personalContext(FULL_INPUT);
  const publicNarrative = toPublicPersonalNarrative(personalModelResponse(catalog));
  const serialized = JSON.stringify(publicNarrative);
  assert.equal(serialized.includes('groundingRefs'), false);
  const compatPublic = toPublicCompatibilityNarrative(
    compatibilityModelResponse(compatibilityContext(FULL_INPUT, DATE_ONLY_INPUT).catalog),
  );
  assert.equal(JSON.stringify(compatPublic).includes('groundingRefs'), false);
});

test('v2 공개 필드 4개가 v3에도 그대로 존재한다', () => {
  const { catalog } = personalContext(FULL_INPUT);
  const publicNarrative = toPublicPersonalNarrative(personalModelResponse(catalog));
  for (const key of ['characterType', 'summary', 'reasons', 'relationshipStory']) {
    assert.ok(key in publicNarrative, `${key}가 없다`);
  }
});

// ── evidence catalog / grounding ─────────────────────────────────────────

test('개인 catalog는 확정된 근거만 담는다 — 시주 없으면 시주 항목도 없다', () => {
  const { evidence, catalog } = personalContext(DATE_ONLY_INPUT);
  assert.equal(evidence.pillars.hour, null);
  assert.equal(catalog.some((item) => item.description.includes('시주')), false);
  assert.ok(catalog.every((item) => /^P\d{2}$/.test(item.id)));
  assert.ok(catalog.length >= 4);
});

test('궁합 catalog는 이름 대신 첫 번째/두 번째 사람으로만 표현한다', () => {
  const { catalog } = compatibilityContext(FULL_INPUT, DATE_ONLY_INPUT);
  const text = JSON.stringify(catalog);
  assert.ok(text.includes('첫 번째 사람'));
  assert.ok(text.includes('두 번째 사람'));
  assert.ok(catalog.every((item) => /^C\d{2}$/.test(item.id)));
});

test('catalog에 없는 ref는 거부된다', () => {
  const { catalog } = personalContext(FULL_INPUT);
  const raw = personalModelResponse(catalog);
  raw.personalSections.loveStyle.claims[0].groundingRefs = ['P99'];
  const result = validatePersonalGrounding(raw, catalog);
  assert.equal(result.ok, false);
  assert.ok(result.violations.some((v) => v.code === 'unknownGroundingRef'));
});

test('groundingRefs가 비면 claim 단위로 거부된다', () => {
  const { catalog } = compatibilityContext(FULL_INPUT, DATE_ONLY_INPUT);
  const raw = compatibilityModelResponse(catalog);
  raw.compatibilitySections.conflictScene.claims[0].groundingRefs = [];
  const result = validateCompatibilityGrounding(raw, catalog);
  assert.equal(result.ok, false);
  assert.ok(result.violations.some((v) => v.code === 'missingGroundingRef' && v.section === 'conflictScene'));
});

test('한 근거로 모든 섹션을 채우면 다양성 위반이다', () => {
  const { catalog } = personalContext(FULL_INPUT);
  const raw = personalModelResponse(catalog);
  for (const key of PERSONAL_SECTION_KEYS) {
    for (const claim of raw.personalSections[key].claims) {
      claim.groundingRefs = [catalog[0].id];
    }
  }
  const result = validatePersonalGrounding(raw, catalog);
  assert.equal(result.ok, false);
  assert.ok(result.violations.some((v) => v.code === 'insufficientEvidenceDiversity'));
  // 한 근거가 4개 이상 섹션에 걸치는 것도 별도로 잡는다.
  assert.ok(result.violations.some((v) => v.code === 'refOverusedAcrossSections'));
});

test('정상 응답은 grounding 검증을 통과한다', () => {
  const { catalog } = personalContext(FULL_INPUT);
  assert.equal(validatePersonalGrounding(personalModelResponse(catalog), catalog).ok, true);
  const compat = compatibilityContext(FULL_INPUT, DATE_ONLY_INPUT);
  assert.equal(
    validateCompatibilityGrounding(compatibilityModelResponse(compat.catalog), compat.catalog).ok,
    true,
  );
});

// ── 금지 문구 / 개인정보 ─────────────────────────────────────────────────

function personalPublic(overrides) {
  const { catalog } = personalContext(FULL_INPUT);
  return {
    catalog,
    narrative: toPublicPersonalNarrative(personalModelResponse(catalog, overrides)),
  };
}

test('점수·퍼센트·순위 표현은 hard fail이다', () => {
  const { narrative, catalog } = personalPublic({ summary: '두 사람의 궁합도는 87% 정도예요.' });
  const result = runHardChecks(narrative, {
    kind: 'personal',
    hourPillarKnown: true,
    catalogIds: catalog.map((c) => c.id),
  });
  assert.equal(result.ok, false);
  assert.ok(result.violations.some((v) => v.code === 'numericScore' || v.code === 'ranking'));
});

test('운명 단정과 합·충 가치 판정은 hard fail이다', () => {
  const fatal = personalPublic({ summary: '두 사람은 운명적으로 평생 함께할 사이예요.' });
  assert.equal(runHardChecks(fatal.narrative, { kind: 'personal' }).ok, false);

  const verdict = personalPublic({ summary: '합이 있으니 잘 맞아요. 최고의 궁합이에요.' });
  const result = runHardChecks(verdict.narrative, { kind: 'personal' });
  assert.equal(result.ok, false);
  assert.ok(result.violations.some((v) => v.code === 'harmonyClashVerdict'));
  assert.ok(result.violations.some((v) => v.code === 'absoluteVerdict'));
});

test('출생시간을 모르면 시주 언급이 hard fail이다', () => {
  const { catalog } = personalContext(DATE_ONLY_INPUT);
  const narrative = toPublicPersonalNarrative(
    personalModelResponse(catalog, { summary: '시주를 보면 저녁 시간대의 기운이 강해요.' }),
  );
  const result = runHardChecks(narrative, {
    kind: 'personal',
    hourPillarKnown: false,
    catalogIds: catalog.map((c) => c.id),
  });
  assert.equal(result.ok, false);
  assert.ok(result.violations.some((v) => v.code === 'hourPillarWithoutBirthTime'));
});

test('출생시간 안내 문구 자체는 hard fail이 아니다', () => {
  const { catalog } = personalContext(DATE_ONLY_INPUT);
  const narrative = toPublicPersonalNarrative(
    personalModelResponse(catalog, {
      summary: '태어난 시간을 알려주시면 더 자세히 볼 수 있어요. 지금은 확정된 부분만 정리했어요.',
    }),
  );
  const result = runHardChecks(narrative, {
    kind: 'personal',
    hourPillarKnown: false,
    catalogIds: catalog.map((c) => c.id),
  });
  assert.equal(result.violations.some((v) => v.code === 'hourPillarWithoutBirthTime'), false);
});

test('raw 생년월일·식별자·fingerprint 노출은 hard fail이다', () => {
  for (const summary of [
    '1994년 5월 12일에 태어난 분이에요.',
    '사용자 aBcDeF1234567890XyZq 님의 결과예요.',
    '지문 3f9a2b7c4d1e8f60 기준으로 계산했어요.',
  ]) {
    const { narrative } = personalPublic({ summary });
    assert.equal(runHardChecks(narrative, { kind: 'personal' }).ok, false, summary);
  }
});

test('내부 evidence code와 catalog id 노출은 hard fail이다', () => {
  const { catalog } = personalContext(FULL_INPUT);
  const leaked = toPublicPersonalNarrative(
    personalModelResponse(catalog, { summary: 'crossSixClash 근거를 반영했어요.' }),
  );
  assert.ok(
    runHardChecks(leaked, { kind: 'personal', catalogIds: catalog.map((c) => c.id) }).violations.some(
      (v) => v.code === 'internalCodeLeak',
    ),
  );

  const idLeak = toPublicPersonalNarrative(
    personalModelResponse(catalog, { summary: 'P01 근거에 따르면 그렇습니다.' }),
  );
  assert.ok(
    runHardChecks(idLeak, { kind: 'personal', catalogIds: catalog.map((c) => c.id) }).violations.some(
      (v) => v.code === 'evidenceIdLeak',
    ),
  );
});

test('정상 응답은 hard check를 통과한다', () => {
  const { catalog } = personalContext(FULL_INPUT);
  const narrative = toPublicPersonalNarrative(personalModelResponse(catalog));
  const result = runHardChecks(narrative, {
    kind: 'personal',
    hourPillarKnown: true,
    catalogIds: catalog.map((c) => c.id),
  });
  assert.deepEqual(result.violations, []);

  const compat = compatibilityContext(FULL_INPUT, DATE_ONLY_INPUT);
  const compatNarrative = toPublicCompatibilityNarrative(compatibilityModelResponse(compat.catalog));
  assert.deepEqual(
    runHardChecks(compatNarrative, {
      kind: 'compatibility',
      hourPillarKnown: false,
      catalogIds: compat.catalog.map((c) => c.id),
    }).violations,
    [],
  );
});

test('궁합에서 participantAdvice가 비면 hard fail이다', () => {
  const compat = compatibilityContext(FULL_INPUT, DATE_ONLY_INPUT);
  const raw = compatibilityModelResponse(compat.catalog);
  raw.compatibilitySections.participantAdvice.second = '';
  const narrative = toPublicCompatibilityNarrative(raw);
  assert.ok(
    runHardChecks(narrative, { kind: 'compatibility' }).violations.some(
      (v) => v.code === 'missingParticipantAdvice',
    ),
  );
});

// ── quality signal ───────────────────────────────────────────────────────

test('상투 표현 반복과 장면 부재를 감지한다', () => {
  const { catalog } = personalContext(FULL_INPUT);
  const raw = personalModelResponse(catalog, {
    summary: '서로의 부족한 부분을 채워줘요. 균형을 이루어요. 좋은 에너지를 만들어요.',
    reasons: [{ icon: '✨', text: '천천히 알아가면 좋아요.' }],
  });
  const setBody = (key, text) => {
    raw.personalSections[key].claims = [
      { ...raw.personalSections[key].claims[0], text },
    ];
  };
  setBody('loveStyle', '균형을 이루어요.');
  setBody('affectionStyle', '좋은 에너지를 만들어요.');
  setBody('conflictPattern', '서로를 이해하면 좋아요.');
  setBody('emotionalNeed', '천천히 알아가면 좋아요.');
  setBody('attractionPattern', '새로운 관점을 줄 수 있어요.');
  setBody('growthAdvice', '단서가 돼요.');
  raw.personalSections.growthAdvice.action = '좋은 에너지를 떠올려보세요.';
  const { signals } = runQualitySignals(toPublicPersonalNarrative(raw), { kind: 'personal' });
  const codes = signals.map((s) => s.code);
  assert.ok(codes.includes('clicheOveruse'));
  assert.ok(codes.includes('noConcreteScene'));
  assert.ok(codes.includes('praiseOnly'));
});

test('과도하게 긴 문장을 감지한다', () => {
  const { catalog } = personalContext(FULL_INPUT);
  const long = `${'이 사람은 대화를 나눌 때 상대의 반응을 살피며 조심스럽게 다가가는 편이라 '.repeat(4)}그래요.`;
  const { signals } = runQualitySignals(
    toPublicPersonalNarrative(personalModelResponse(catalog, { summary: long })),
    { kind: 'personal' },
  );
  assert.ok(signals.some((s) => s.code === 'longSentence'));
});

test('generic 유사도로 중복 결과를 잡아낼 수 있다', () => {
  const a = '답장이 늦어도 먼저 상황을 알려주면 오해가 줄어요.';
  assert.ok(textSimilarity(a, a) > 0.9);
  assert.ok(textSimilarity(a, '약속 장소를 정할 때 상대 일정부터 물어봐요.') < 0.3);
});

// ── 평가 세트 커버리지 ────────────────────────────────────────────────────

test('개인 평가 세트가 요구 범위를 덮는다', () => {
  const cases = buildPersonalCases();
  assert.ok(cases.length >= 16, `${cases.length}건뿐이다`);

  const dayMasters = new Set(cases.map((c) => c.evidence.dayMaster.stem));
  assert.equal(dayMasters.size, 10, `일간 ${dayMasters.size}종`);

  const axes = new Set(cases.flatMap((c) => c.axes));
  for (const required of [
    'full',
    'partial',
    'noBirthTime',
    'boundaryYear',
    'boundaryMonth',
    'sixHarmony',
    'sixClash',
    'threeHarmony',
    'noRelation',
    'nearDuplicatePair',
  ]) {
    assert.ok(axes.has(required), `${required} 축이 없다`);
  }
  assert.ok(cases.some((c) => c.confidence === 'full'));
  assert.ok(cases.some((c) => c.confidence === 'partial'));
});

test('궁합 평가 세트가 요구 범위를 덮는다', () => {
  const cases = buildCompatibilityCases();
  assert.ok(cases.length >= 16, `${cases.length}건뿐이다`);

  const summaries = new Set(
    cases.map((c) => c.compatibilityEvidence.dayMasterInteraction.summary),
  );
  for (const required of [
    'sameElement',
    'firstGeneratesSecond',
    'secondGeneratesFirst',
    'firstControlsSecond',
    'secondControlsFirst',
  ]) {
    assert.ok(summaries.has(required), `${required} 관계가 없다`);
  }

  const axes = new Set(cases.flatMap((c) => c.axes));
  for (const required of [
    'crossHarmony',
    'crossClash',
    'harmonyAndClash',
    'fewRelations',
    'oneDateOnly',
    'bothDateOnly',
    'boundaryAmbiguity',
    'differentYinYang',
    'abSwap',
  ]) {
    assert.ok(axes.has(required), `${required} 축이 없다`);
  }
  assert.ok(cases.some((c) => c.swapped));
});

test('평가 case에 자연어 정답이나 raw 출생정보가 들어가지 않는다', () => {
  const cases = [...buildPersonalCases(), ...buildCompatibilityCases()];
  for (const testCase of cases) {
    assert.equal('expectedText' in testCase, false);
    const serialized = JSON.stringify(testCase);
    assert.equal(/birthTimeMinutes/.test(serialized), false, testCase.id);
    assert.equal(/"year":\s*\d{4}/.test(serialized), false, testCase.id);
    assert.ok(testCase.allowedEvidenceIds.length > 0);
    assert.ok(testCase.prohibitedClaims.includes('fatalism'));
  }
});

test('A/B swap case는 방향 근거가 반전된다', () => {
  const cases = buildCompatibilityCases();
  const swapped = cases.filter((c) => c.swapped);
  assert.ok(swapped.length >= 2);
  for (const testCase of swapped) {
    const original = cases.find(
      (c) => !c.swapped && c.sourceFixtureId === testCase.sourceFixtureId,
    );
    if (!original) continue;
    assert.notEqual(
      testCase.compatibilityEvidence.dayMasterInteraction.summary,
      original.compatibilityEvidence.dayMasterInteraction.summary,
    );
  }
});

// ── 모델 호출 계약 ────────────────────────────────────────────────────────

test('모델 계열별로 지원되는 파라미터만 만든다', () => {
  assert.equal(modelFamilyOf('gpt-4o-mini'), 'gpt-4o');
  assert.equal(modelFamilyOf('gpt-5.6-sol'), 'gpt-5');
  assert.throws(() => modelFamilyOf('claude-3'), /지원하지 않는/);

  const legacy = samplingParamsFor('gpt-4o-mini', { maxOutputTokens: 1000 });
  assert.ok('temperature' in legacy && 'max_tokens' in legacy);
  assert.equal('reasoning_effort' in legacy, false);

  const next = samplingParamsFor('gpt-5.6-sol', { maxOutputTokens: 1000 });
  assert.equal(next.reasoning_effort, 'low');
  assert.equal(next.max_completion_tokens, 1000);
  assert.equal('temperature' in next, false);
  assert.equal('max_tokens' in next, false);
});

test('refusal / truncation / empty를 분류해 던진다', async () => {
  const { catalog } = personalContext(FULL_INPUT);
  const call = (payload) =>
    generateStructuredNarrative({
      client: { chat: { completions: { create: async () => payload } } },
      modelId: 'gpt-4o-mini',
      jsonSchema: PERSONAL_NARRATIVE_JSON_SCHEMA,
      systemPrompt: 'x',
      userPayload: { catalog },
    });

  await assert.rejects(
    () => call({ choices: [{ message: { refusal: '거부' }, finish_reason: 'stop' }] }),
    (error) => error.kind === FAILURE_KINDS.REFUSAL,
  );
  await assert.rejects(
    () => call({ choices: [{ message: { content: '{' }, finish_reason: 'length' }] }),
    (error) => error.kind === FAILURE_KINDS.TRUNCATED,
  );
  await assert.rejects(
    () => call({ choices: [{ message: { content: '' }, finish_reason: 'stop' }] }),
    (error) => error.kind === FAILURE_KINDS.EMPTY,
  );
  await assert.rejects(
    () => call({ choices: [{ message: { content: 'not json' }, finish_reason: 'stop' }] }),
    (error) => error.kind === FAILURE_KINDS.INVALID_JSON,
  );
});

test('접근 불가·rate limit·unsupported parameter를 구분한다', () => {
  assert.equal(classifyError({ status: 404, code: 'model_not_found' }), FAILURE_KINDS.ACCESS_DENIED);
  assert.equal(classifyError({ status: 403 }), FAILURE_KINDS.ACCESS_DENIED);
  assert.equal(classifyError({ status: 429 }), FAILURE_KINDS.RATE_LIMIT);
  assert.equal(
    classifyError({ status: 400, message: "Unsupported parameter: 'temperature'" }),
    FAILURE_KINDS.UNSUPPORTED_PARAMETER,
  );
});

test('정상 응답은 usage와 model을 그대로 돌려준다', async () => {
  const { catalog } = personalContext(FULL_INPUT);
  const parsed = personalModelResponse(catalog);
  const result = await generateStructuredNarrative({
    client: {
      chat: {
        completions: {
          create: async () => ({
            model: 'gpt-4o-mini-2024-07-18',
            usage: { prompt_tokens: 10, completion_tokens: 20 },
            system_fingerprint: 'fp_test',
            choices: [{ message: { content: JSON.stringify(parsed) }, finish_reason: 'stop' }],
          }),
        },
      },
    },
    modelId: 'gpt-4o-mini',
    jsonSchema: PERSONAL_NARRATIVE_JSON_SCHEMA,
    systemPrompt: 'x',
    userPayload: {},
  });
  assert.equal(result.modelId, 'gpt-4o-mini-2024-07-18');
  assert.equal(result.usage.prompt_tokens, 10);
  assert.equal(result.systemFingerprint, 'fp_test');
});

// ── rubric / gate ────────────────────────────────────────────────────────

test('rubric 집계와 gate 판정이 기준대로 동작한다', () => {
  const perfect = Object.fromEntries(RUBRIC_KEYS.map((k) => [k, 5]));
  const aggregate = aggregateScores([perfect, perfect]);
  assert.equal(aggregate.overall, 5);

  const pass = evaluateQualityGate({
    hardViolations: 0,
    privacyViolations: 0,
    schemaFailures: 0,
    fatalismViolations: 0,
    aggregate,
    baselineAggregate: aggregateScores([Object.fromEntries(RUBRIC_KEYS.map((k) => [k, 3]))]),
    genericDuplicateRatio: 0,
  });
  assert.equal(pass.passed, true);

  const hardFail = evaluateQualityGate({
    hardViolations: 1,
    privacyViolations: 0,
    schemaFailures: 0,
    fatalismViolations: 0,
    aggregate,
    baselineAggregate: null,
    genericDuplicateRatio: 0,
  });
  assert.equal(hardFail.passed, false);
  assert.ok(hardFail.failures.some((f) => f.code === 'hardViolation'));
});

test('baseline 대비 개선 폭이 부족하면 gate에 걸린다', () => {
  const candidate = aggregateScores([Object.fromEntries(RUBRIC_KEYS.map((k) => [k, 4]))]);
  const baseline = aggregateScores([Object.fromEntries(RUBRIC_KEYS.map((k) => [k, 4]))]);
  const gate = evaluateQualityGate({
    hardViolations: 0,
    privacyViolations: 0,
    schemaFailures: 0,
    fatalismViolations: 0,
    aggregate: candidate,
    baselineAggregate: baseline,
    genericDuplicateRatio: 0,
  });
  assert.equal(gate.passed, false);
  assert.ok(gate.failures.some((f) => f.code === 'improvementBelowGate'));
});

test('generic 중복 비율이 기준을 넘으면 gate에 걸린다', () => {
  const aggregate = aggregateScores([Object.fromEntries(RUBRIC_KEYS.map((k) => [k, 5]))]);
  const gate = evaluateQualityGate({
    hardViolations: 0,
    privacyViolations: 0,
    schemaFailures: 0,
    fatalismViolations: 0,
    aggregate,
    baselineAggregate: null,
    genericDuplicateRatio: QUALITY_GATE.maxGenericDuplicateRatio,
  });
  assert.equal(gate.passed, false);
  assert.ok(gate.failures.some((f) => f.code === 'genericDuplicateRatio'));
});

test('기본은 품질 우선 — 조건을 못 채우면 balanced 후보를 고르지 않는다', () => {
  const strong = { gate: { passed: true }, aggregate: aggregateScores([Object.fromEntries(RUBRIC_KEYS.map((k) => [k, 5]))]) };
  const close = { gate: { passed: true }, aggregate: aggregateScores([Object.fromEntries(RUBRIC_KEYS.map((k) => [k, 4.9]))]) };
  const weak = { gate: { passed: true }, aggregate: aggregateScores([Object.fromEntries(RUBRIC_KEYS.map((k) => [k, 4]))]) };

  assert.equal(
    canPreferBalancedCandidate({ balanced: close, quality: strong, balancedPairwiseLoss: false, latencyOrCostMeaningful: true }),
    true,
  );
  assert.equal(
    canPreferBalancedCandidate({ balanced: weak, quality: strong, balancedPairwiseLoss: false, latencyOrCostMeaningful: true }),
    false,
  );
  assert.equal(
    canPreferBalancedCandidate({ balanced: close, quality: strong, balancedPairwiseLoss: true, latencyOrCostMeaningful: true }),
    false,
  );
  assert.equal(
    canPreferBalancedCandidate({ balanced: close, quality: strong, balancedPairwiseLoss: false, latencyOrCostMeaningful: false }),
    false,
  );
});

// ── eval runner 계약 (API 호출 없음) ──────────────────────────────────────

test('평가 계획 추정은 API 호출 없이 계산되고 단가 미확인을 숨기지 않는다', () => {
  const cases = [...buildPersonalCases(), ...buildCompatibilityCases()];
  const estimate = estimateRun(cases, CANDIDATES);
  assert.equal(estimate.rows.length, CANDIDATES.length);
  assert.equal(estimate.callsTotal, cases.length * CANDIDATES.length);
  for (const row of estimate.rows) {
    assert.ok(row.maxInputTokens > 0);
    if (PRICING_USD_PER_MTOK[row.modelId] === null) assert.equal(row.maxCostUsd, null);
  }
});

test('후보 모델 ID는 rolling alias가 아니다', () => {
  for (const candidate of CANDIDATES) {
    assert.notEqual(candidate.modelId, 'gpt-5.6');
    assert.ok(/^gpt-(4o-mini|5\.6-(terra|sol))$/.test(candidate.modelId), candidate.modelId);
  }
});

test('eval 인자 파서가 estimate/probe/models를 해석한다', () => {
  const args = parseArgs(['node', 'eval', '--estimate', '--models=baseline,sol', '--judge=gpt-4o-mini']);
  assert.equal(args.estimate, true);
  assert.deepEqual(args.models, ['baseline', 'sol']);
  assert.equal(args.judge, 'gpt-4o-mini');
  assert.throws(() => parseArgs(['node', 'eval', '--nope']), /알 수 없는 인자/);
});

test('프롬프트 payload에 raw 생년월일·UID가 들어가지 않는다', () => {
  for (const testCase of [...buildPersonalCases(), ...buildCompatibilityCases()]) {
    const { systemPrompt, userPayload } = promptFor(testCase);
    const serialized = `${systemPrompt}\n${JSON.stringify(userPayload)}`;
    assert.equal(/birthDate|birthTimeMinutes|inputFingerprint/.test(serialized), false, testCase.id);
    assert.equal(/"year":\s*\d{4}/.test(serialized), false, testCase.id);
  }
});

test('프롬프트 버전 상수가 schema 버전과 함께 관리된다', () => {
  assert.equal(NARRATIVE_SCHEMA_VERSION, 3);
  assert.equal(NARRATIVE_PROMPT_VERSION, 4);
});

test('collectPublicText는 사용자에게 보이는 문구만 모은다', () => {
  const { catalog } = compatibilityContext(FULL_INPUT, DATE_ONLY_INPUT);
  const narrative = toPublicCompatibilityNarrative(compatibilityModelResponse(catalog));
  const parts = collectPublicText(narrative);
  assert.ok(parts.length >= 10);
  assert.equal(parts.some((p) => p.includes('groundingRefs')), false);
  assert.ok(parts.includes(narrative.compatibilitySections.participantAdvice.first));
});

// ── Stage A 보정 1회차 — claim 단위 grounding / fatalism 오탐 / distinctiveness ──

const {
  CLAIM_TYPES,
  MAX_SECTIONS_PER_REF,
  splitEvidenceSalience,
} = require('../lib/saju/narrative_grounding');
const { crossCaseRepetition } = require('../lib/saju/narrative_quality_checks');

test('catalog에 내부 코드명이나 [object Object]가 남지 않는다', () => {
  const personal = personalContext(FULL_INPUT).catalog;
  const compat = compatibilityContext(FULL_INPUT, DATE_ONLY_INPUT).catalog;
  for (const catalog of [personal, compat]) {
    const text = JSON.stringify(catalog);
    assert.equal(text.includes('[object Object]'), false);
    for (const code of ['sikSin', 'jeongJae', 'biGyeon', 'crossSixClash', 'secondControlsFirst', 'sharedElementPresence']) {
      assert.equal(text.includes(code), false, code);
    }
    // 모든 항목이 서술 가능한 도메인을 갖는다.
    assert.ok(catalog.every((item) => Array.isArray(item.domains) && item.domains.length > 0));
  }
});

test('관찰 claim이 confidence만 인용하면 거부된다', () => {
  const { catalog } = personalContext(FULL_INPUT);
  const confidenceRef = catalog.find((c) => c.kind === 'confidence').id;
  const raw = personalModelResponse(catalog);
  raw.personalSections.loveStyle.claims = [
    { text: '이 사람은 항상 먼저 연락해요.', type: CLAIM_TYPES.OBSERVATION, groundingRefs: [confidenceRef] },
  ];
  const result = validatePersonalGrounding(raw, catalog);
  assert.equal(result.ok, false);
  assert.ok(result.violations.some((v) => v.code === 'observationWithoutObservableRef'));
});

test('조언 claim은 confidence만 인용해도 통과하지만 섹션에 관찰이 없으면 거부된다', () => {
  const { catalog } = personalContext(FULL_INPUT);
  const confidenceRef = catalog.find((c) => c.kind === 'confidence').id;
  const raw = personalModelResponse(catalog);
  raw.personalSections.loveStyle.claims = [
    { text: '오늘 하루 있었던 일을 한 줄로 보내보세요.', type: CLAIM_TYPES.ADVICE, groundingRefs: [confidenceRef] },
  ];
  const result = validatePersonalGrounding(raw, catalog);
  assert.equal(result.ok, false);
  assert.ok(result.violations.some((v) => v.code === 'sectionWithoutObservation'));
  assert.equal(result.violations.some((v) => v.code === 'observationWithoutObservableRef'), false);
});

test('claim type이 없거나 알 수 없으면 거부된다', () => {
  const { catalog } = personalContext(FULL_INPUT);
  const raw = personalModelResponse(catalog);
  raw.personalSections.loveStyle.claims[0].type = 'guess';
  const result = validatePersonalGrounding(raw, catalog);
  assert.equal(result.ok, false);
  assert.ok(result.violations.some((v) => v.code === 'unknownClaimType'));
});

test('공개 body는 claim들을 이어 붙여 만들고 claim 구조는 노출하지 않는다', () => {
  const { catalog } = personalContext(FULL_INPUT);
  const refs = catalog.filter((c) => c.kind !== 'confidence').map((c) => c.id);
  const raw = personalModelResponse(catalog);
  raw.personalSections.loveStyle.claims = [
    { text: '첫 문장이에요.', type: CLAIM_TYPES.OBSERVATION, groundingRefs: [refs[0]] },
    { text: '둘째 문장이에요.', type: CLAIM_TYPES.ADVICE, groundingRefs: [refs[1]] },
  ];
  const publicNarrative = toPublicPersonalNarrative(raw);
  assert.equal(publicNarrative.personalSections.loveStyle.body, '첫 문장이에요. 둘째 문장이에요.');
  const serialized = JSON.stringify(publicNarrative);
  assert.equal(serialized.includes('claims'), false);
  assert.equal(serialized.includes('groundingRefs'), false);
  assert.equal(serialized.includes('observation'), false);
});

test('fatalism: 확정 예언은 hard fail이다 (true positive)', () => {
  for (const text of [
    '두 사람은 무조건 헤어져요.',
    '이 관계는 운명적으로 정해져 있어요.',
    '반드시 성공한다고 볼 수 있어요.',
    '틀림없이 그렇게 될 거예요.',
  ]) {
    const { narrative } = personalPublic({ summary: text });
    const { violations } = runHardChecks(narrative, { kind: 'personal' });
    assert.ok(violations.some((v) => v.code === 'fatalism'), text);
  }
});

test('fatalism: 비교·조언 문맥의 "무조건"은 통과한다 (false positive 회귀)', () => {
  // Stage A 1차에서 Sol의 유일한 hard 위반이 이 오탐이었다.
  for (const text of [
    '서운한 일이 생기면 무조건 참기보다 무엇이 불편했는지 짚고 넘어가는 편이 좋아요.',
    '무조건 맞춰주기보다 원하는 걸 한 번은 말해보세요.',
    '상대의 말을 무조건 받아들이지 않아도 괜찮아요.',
  ]) {
    const { narrative } = personalPublic({ summary: text });
    const { violations } = runHardChecks(narrative, { kind: 'personal' });
    assert.equal(violations.some((v) => v.code === 'fatalism'), false, text);
  }
});

test('dominant와 secondary evidence가 겹치지 않게 분리된다', () => {
  const { catalog } = personalContext(FULL_INPUT);
  const { dominant, secondary } = splitEvidenceSalience(catalog);
  assert.ok(dominant.length >= 1);
  assert.equal(dominant.some((id) => secondary.includes(id)), false);
  // confidence(메타)는 어느 쪽에도 들어가지 않는다.
  const confidenceRef = catalog.find((c) => c.kind === 'confidence').id;
  assert.equal([...dominant, ...secondary].includes(confidenceRef), false);
});

test('한 근거가 허용 섹션 수를 넘으면 refOverusedAcrossSections로 잡힌다', () => {
  const { catalog } = personalContext(FULL_INPUT);
  const refs = catalog.filter((c) => c.kind !== 'confidence').map((c) => c.id);
  const raw = personalModelResponse(catalog);
  PERSONAL_SECTION_KEYS.slice(0, MAX_SECTIONS_PER_REF + 1).forEach((key) => {
    raw.personalSections[key].claims = [
      { text: `${key} 문장이에요.`, type: CLAIM_TYPES.OBSERVATION, groundingRefs: [refs[0]] },
    ];
  });
  const result = validatePersonalGrounding(raw, catalog);
  assert.ok(result.violations.some((v) => v.code === 'refOverusedAcrossSections' && v.ref === refs[0]));
});

test('근거가 다른 두 case는 서로 다른 catalog를 만든다 (distinctiveness 전제)', () => {
  const first = personalContext(FULL_INPUT).catalog;
  const second = personalContext(DATE_ONLY_INPUT).catalog;
  const descriptionsOf = (catalog) => catalog.map((c) => c.description).join('|');
  assert.notEqual(descriptionsOf(first), descriptionsOf(second));
  // 확정도가 다르면 말할 수 있는 범위도 달라진다.
  const confidenceOf = (catalog) => catalog.find((c) => c.kind === 'confidence').description;
  assert.notEqual(confidenceOf(first), confidenceOf(second));
});

test('case 간 문장 반복을 감지한다', () => {
  const { catalog } = personalContext(FULL_INPUT);
  const shared = toPublicPersonalNarrative(personalModelResponse(catalog));
  const repeated = crossCaseRepetition([
    { caseId: 'a', narrative: shared },
    { caseId: 'b', narrative: shared },
  ]);
  assert.ok(repeated.repeatedSentenceRatio > 0.5);
  assert.ok(repeated.repeatedSentences.length > 0);

  const distinct = crossCaseRepetition([
    { caseId: 'a', narrative: shared },
    {
      caseId: 'b',
      narrative: toPublicPersonalNarrative(
        personalModelResponse(catalog, {
          summary: '완전히 다른 요약 문장을 여기에 넣어 반복을 없앱니다.',
        }),
      ),
    },
  ]);
  assert.ok(distinct.repeatedSentenceRatio <= repeated.repeatedSentenceRatio);
});

test('judge 실패는 일시적 오류만 재시도 대상이다', () => {
  const { RETRYABLE_JUDGE_KINDS, MAX_JUDGE_FAILURE_RATE } = require('../evals/saju_narrative_eval');
  assert.ok(RETRYABLE_JUDGE_KINDS.has(FAILURE_KINDS.RATE_LIMIT));
  assert.ok(RETRYABLE_JUDGE_KINDS.has(FAILURE_KINDS.TIMEOUT));
  assert.ok(RETRYABLE_JUDGE_KINDS.has(FAILURE_KINDS.EMPTY));
  // schema·contract 오류는 재시도하지 않는다.
  assert.equal(RETRYABLE_JUDGE_KINDS.has(FAILURE_KINDS.INVALID_JSON), false);
  assert.equal(RETRYABLE_JUDGE_KINDS.has(FAILURE_KINDS.REFUSAL), false);
  assert.equal(RETRYABLE_JUDGE_KINDS.has(FAILURE_KINDS.ACCESS_DENIED), false);
  assert.equal(MAX_JUDGE_FAILURE_RATE, 0.05);
});

test('ranking: 실제 순위·점수 지표는 hard fail이다 (true positive)', () => {
  for (const text of [
    '두 사람의 궁합도는 높은 편이에요.',
    '이 조합은 3위 정도로 볼 수 있어요.',
    '관계 점수를 매기면 잘 맞아요.',
    '등급으로 나누면 상위권이에요.',
  ]) {
    const { narrative } = personalPublic({ summary: text });
    const { violations } = runHardChecks(narrative, { kind: 'personal' });
    assert.ok(violations.some((v) => v.code === 'ranking'), text);
  }
});

test('ranking: "우선순위"는 통과한다 (false positive 회귀)', () => {
  // pilot 1회차에서 Terra의 유일한 hard 위반이 이 오탐이었다.
  for (const text of [
    '약속의 방식이나 우선순위를 정하는 장면에서 반응 차이가 드러날 수 있어요.',
    '무엇을 우선순위에 둘지 먼저 이야기해 보세요.',
  ]) {
    const { narrative } = personalPublic({ summary: text });
    const { violations } = runHardChecks(narrative, { kind: 'personal' });
    assert.equal(violations.some((v) => v.code === 'ranking'), false, text);
  }
});
