'use strict';

/**
 * 서사 품질 평가 세트 — Phase 5-4.
 *
 * **production 사용자 데이터를 쓰지 않는다.** 입력은 전부 Phase 5-3에서 만든
 * 합성 fixture(test/fixtures/*.json)의 날짜를 재사용한다. 정답 문장(자연어)은
 * 넣지 않는다 — 서사 품질은 rubric과 hard check로 판정한다.
 *
 * 각 case가 갖는 것:
 * - synthetic id
 * - 결정론적 evidence를 만들 입력(합성 생년월일)
 * - 허용된 evidence id 집합(catalog에서 파생)
 * - 금지 주장(prohibitedClaims)
 * - confidence
 */

const path = require('node:path');

const { computeSajuChart } = require('../lib/saju/saju_engine_v2');
const { buildPersonalSajuEvidence } = require('../lib/saju/saju_evidence_v1');
const {
  buildCompatibilityEvidence,
} = require('../lib/saju/compatibility_evidence_v1');
const {
  buildPersonalEvidenceCatalog,
  buildCompatibilityEvidenceCatalog,
  catalogIds,
} = require('../lib/saju/narrative_grounding');

const FIXTURE_DIR = path.join(__dirname, '..', 'test', 'fixtures');
const personalFixture = require(path.join(FIXTURE_DIR, 'saju_evidence_v1.json'));
const compatFixture = require(path.join(FIXTURE_DIR, 'compatibility_evidence_v1.json'));

/**
 * 개인 평가 case로 쓸 fixture id와, 그 case가 덮는 축.
 * 일간 10종 전부 + full/partial + 시간 유무 + 절기 경계 + 육합/육충/삼합/무관계
 * + 근사한 원국 pair(distinctiveness 확인용).
 */
const PERSONAL_CASE_SPECS = Object.freeze([
  { fixtureId: 'personal_02_threeHarmony', axes: ['dayMaster:갑', 'full', 'threeHarmony', 'sixHarmony'] },
  { fixtureId: 'personal_24_unknownTime', axes: ['dayMaster:갑', 'partial', 'noBirthTime', 'noRelation'] },
  { fixtureId: 'personal_03_none', axes: ['dayMaster:갑', 'full', 'noRelation', 'nearDuplicatePair'] },
  { fixtureId: 'personal_04_none', axes: ['dayMaster:갑', 'full', 'noRelation', 'nearDuplicatePair'] },
  { fixtureId: 'personal_19_boundary', axes: ['dayMaster:을', 'partial', 'boundaryYear', 'boundaryMonth'] },
  { fixtureId: 'personal_20_hiddenBranch', axes: ['dayMaster:을', 'full', 'sixHarmony', 'sixClash'] },
  { fixtureId: 'personal_08_sixHarmony', axes: ['dayMaster:병', 'full', 'sixHarmony'] },
  { fixtureId: 'personal_30_boundary', axes: ['dayMaster:병', 'partial', 'boundaryMonth', 'noBirthTime'] },
  { fixtureId: 'personal_18_dayMaster', axes: ['dayMaster:정', 'partial', 'sixClash', 'noBirthTime'] },
  { fixtureId: 'personal_33_hiddenBranch', axes: ['dayMaster:정', 'partial', 'hiddenStemHeavy'] },
  { fixtureId: 'personal_14_knownTime', axes: ['dayMaster:무', 'full', 'sixHarmony', 'sixClash'] },
  { fixtureId: 'personal_32_threeHarmony', axes: ['dayMaster:무', 'full', 'threeHarmony', 'sixClash'] },
  { fixtureId: 'personal_23_dayMaster', axes: ['dayMaster:기', 'partial', 'noBirthTime'] },
  { fixtureId: 'personal_27_dayMaster', axes: ['dayMaster:경', 'partial', 'sixHarmony', 'noBirthTime'] },
  { fixtureId: 'personal_11_sixClash', axes: ['dayMaster:신', 'full', 'sixClash'] },
  { fixtureId: 'personal_22_dayMaster', axes: ['dayMaster:임', 'partial', 'noBirthTime'] },
  { fixtureId: 'personal_17_dayMaster', axes: ['dayMaster:계', 'partial', 'sixClash', 'noBirthTime'] },
]);

/**
 * 궁합 평가 case. 오행 관계 6종 + 교차 합/충 + 동시 존재 + 관계 희소 +
 * 한쪽/양쪽 dateOnly + 절기 경계 + A/B swap.
 */
const COMPATIBILITY_CASE_SPECS = Object.freeze([
  { fixtureId: 'compat_29_sameElement', axes: ['sameElement', 'crossHarmony'] },
  { fixtureId: 'compat_34_sameElementDifferentYinYang', axes: ['sameElement', 'differentYinYang', 'fullConfidence'] },
  { fixtureId: 'compat_27_firstGeneratesSecond', axes: ['firstGeneratesSecond'] },
  { fixtureId: 'compat_35_secondGeneratesFirst', axes: ['secondGeneratesFirst', 'crossClash'] },
  { fixtureId: 'compat_13_firstControlsSecond', axes: ['firstControlsSecond', 'crossHarmony'] },
  { fixtureId: 'compat_31_secondControlsFirst', axes: ['secondControlsFirst', 'harmonyAndClash', 'fullConfidence'] },
  { fixtureId: 'compat_05_crossHarmony', axes: ['crossHarmony', 'firstGeneratesSecond'] },
  { fixtureId: 'compat_19_crossClash', axes: ['crossClash', 'sameElement', 'differentYinYang'] },
  { fixtureId: 'compat_08_harmonyAndClash', axes: ['harmonyAndClash', 'secondControlsFirst'] },
  { fixtureId: 'compat_02_oneDateOnly', axes: ['fewRelations', 'oneDateOnly'] },
  { fixtureId: 'compat_01_oneDateOnly', axes: ['oneDateOnly', 'crossHarmony'] },
  { fixtureId: 'compat_12_bothDateOnly', axes: ['bothDateOnly', 'firstControlsSecond'] },
  { fixtureId: 'compat_04_boundaryAmbiguous', axes: ['boundaryAmbiguity', 'firstGeneratesSecond'] },
  { fixtureId: 'compat_18_boundaryAmbiguous', axes: ['boundaryAmbiguity', 'crossClash'] },
  { fixtureId: 'compat_13_firstControlsSecond', swap: true, axes: ['abSwap', 'firstControlsSecond'] },
  { fixtureId: 'compat_31_secondControlsFirst', swap: true, axes: ['abSwap', 'secondControlsFirst'] },
]);

/** 모든 case가 공통으로 금지하는 주장. */
const BASE_PROHIBITED_CLAIMS = Object.freeze([
  'numericScore',
  'ranking',
  'fatalism',
  'absoluteVerdict',
  'harmonyClashVerdict',
  'internalCodeLeak',
  'evidenceIdLeak',
  'rawBirthDate',
  'identifierLike',
]);

function fixtureById(fixture, id) {
  const found = fixture.cases.find((c) => c.id === id);
  if (!found) throw new Error(`fixture case를 찾을 수 없습니다: ${id}`);
  return found;
}

function chartOf(input) {
  return computeSajuChart({
    year: input.year,
    month: input.month,
    day: input.day,
    birthTimeKnown: input.birthTimeKnown,
    birthTimeMinutes: input.birthTimeMinutes,
  });
}

/** 개인 평가 case를 만든다. */
function buildPersonalCases() {
  const seen = new Set();
  return PERSONAL_CASE_SPECS.map((spec, index) => {
    const fixtureCase = fixtureById(personalFixture, spec.fixtureId);
    const chart = chartOf(fixtureCase.input);
    const evidence = buildPersonalSajuEvidence(chart);
    const catalog = buildPersonalEvidenceCatalog(evidence);
    const id = `narr_personal_${String(index + 1).padStart(2, '0')}`;
    if (seen.has(id)) throw new Error(`중복 case id: ${id}`);
    seen.add(id);
    return {
      id,
      kind: 'personal',
      sourceFixtureId: spec.fixtureId,
      axes: spec.axes,
      confidence: evidence.confidence,
      hourPillarKnown: !!evidence.pillars.hour,
      evidence,
      catalog,
      allowedEvidenceIds: catalogIds(catalog),
      prohibitedClaims: [
        ...BASE_PROHIBITED_CLAIMS,
        ...(evidence.pillars.hour ? [] : ['hourPillarWithoutBirthTime']),
      ],
    };
  });
}

/** 궁합 평가 case를 만든다. swap이 true면 first/second를 뒤집는다. */
function buildCompatibilityCases() {
  return COMPATIBILITY_CASE_SPECS.map((spec, index) => {
    const fixtureCase = fixtureById(compatFixture, spec.fixtureId);
    const firstInput = spec.swap ? fixtureCase.second : fixtureCase.first;
    const secondInput = spec.swap ? fixtureCase.first : fixtureCase.second;
    const firstChart = chartOf(firstInput);
    const secondChart = chartOf(secondInput);
    const firstEvidence = buildPersonalSajuEvidence(firstChart);
    const secondEvidence = buildPersonalSajuEvidence(secondChart);
    const compatibilityEvidence = buildCompatibilityEvidence({
      firstChart,
      secondChart,
      firstPersonalEvidence: firstEvidence,
      secondPersonalEvidence: secondEvidence,
    });
    const catalog = buildCompatibilityEvidenceCatalog(compatibilityEvidence);
    return {
      id: `narr_match_${String(index + 1).padStart(2, '0')}`,
      kind: 'compatibility',
      sourceFixtureId: spec.fixtureId,
      swapped: !!spec.swap,
      axes: spec.axes,
      confidence: compatibilityEvidence.confidence,
      hourPillarKnown: !!(firstEvidence.pillars.hour && secondEvidence.pillars.hour),
      firstEvidence,
      secondEvidence,
      compatibilityEvidence,
      catalog,
      allowedEvidenceIds: catalogIds(catalog),
      prohibitedClaims: [
        ...BASE_PROHIBITED_CLAIMS,
        ...(firstEvidence.pillars.hour && secondEvidence.pillars.hour
          ? []
          : ['hourPillarWithoutBirthTime']),
      ],
    };
  });
}

/** distinctiveness 비교에 쓸 근사 원국 pair(같은 axes 태그를 가진 case). */
function nearDuplicatePersonalPairs(cases) {
  const tagged = cases.filter((c) => c.axes.includes('nearDuplicatePair'));
  const pairs = [];
  for (let i = 0; i < tagged.length; i += 1) {
    for (let j = i + 1; j < tagged.length; j += 1) pairs.push([tagged[i].id, tagged[j].id]);
  }
  return pairs;
}

module.exports = {
  PERSONAL_CASE_SPECS,
  COMPATIBILITY_CASE_SPECS,
  BASE_PROHIBITED_CLAIMS,
  buildPersonalCases,
  buildCompatibilityCases,
  nearDuplicatePersonalPairs,
};
