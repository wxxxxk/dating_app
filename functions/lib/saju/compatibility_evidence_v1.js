'use strict';

/**
 * 궁합 evidence — Phase 5-3, evidenceVersion 1.
 *
 * 두 사람의 원국에서 **결정론적으로 확인 가능한 상호작용**만 만든다.
 *
 * 하지 않는 것:
 * - 궁합 점수·퍼센트·순위
 * - support가 많으면 좋은 궁합이라는 판정
 * - tension이 있으면 나쁜 궁합이라는 판정
 * - 자연어 성격 서술 (Phase 5-4에서 AI가 맡는다)
 *
 * 같은 관계가 상황에 따라 끌림도 갈등도 될 수 있다. 엔진은 관계의 존재만
 * evidence code로 남기고 가치 판단을 하지 않는다.
 */

const { stemByKorean, elementRelation } = require('./saju_constants');
const {
  SAJU_EVIDENCE_VERSION,
  resolvedBranchSlots,
} = require('./saju_evidence_v1');
const {
  RELATION_TYPES,
  findCrossBranchRelations,
} = require('./branch_relations');

/** 상호작용 evidence code. 좋고 나쁨이 아니라 "무엇이 있는가"다. */
const SUPPORT_CODES = Object.freeze({
  DAY_MASTER_SAME_ELEMENT: 'dayMasterSameElement',
  FIRST_GENERATES_SECOND: 'firstGeneratesSecond',
  SECOND_GENERATES_FIRST: 'secondGeneratesFirst',
  CROSS_SIX_HARMONY: 'crossSixHarmony',
  SHARED_ELEMENT_PRESENCE: 'sharedElementPresence',
});

const TENSION_CODES = Object.freeze({
  FIRST_CONTROLS_SECOND: 'firstControlsSecond',
  SECOND_CONTROLS_FIRST: 'secondControlsFirst',
  CROSS_SIX_CLASH: 'crossSixClash',
  CONTRASTING_YIN_YANG: 'contrastingYinYang',
});

/** 두 일간의 오행 관계 요약 key. */
const INTERACTION_KEYS = Object.freeze({
  SAME_ELEMENT: 'sameElement',
  FIRST_GENERATES_SECOND: 'firstGeneratesSecond',
  SECOND_GENERATES_FIRST: 'secondGeneratesFirst',
  FIRST_CONTROLS_SECOND: 'firstControlsSecond',
  SECOND_CONTROLS_FIRST: 'secondControlsFirst',
  NEUTRAL: 'neutral',
});

/** 오행이 실제로 존재하는(count > 0) 원소 집합. */
function presentElements(personalEvidence) {
  const surface = personalEvidence.elementPresence.surface;
  return new Set(
    Object.keys(surface).filter((key) => key !== 'total' && surface[key] > 0),
  );
}

/**
 * 두 사람의 궁합 evidence를 만든다.
 *
 * 대칭 필드(sameElement, cross relation 집합, sharedElements, confidence)는
 * 인자 순서를 바꿔도 같아야 하고, 방향 필드(firstToSecond 등)는 정확히 반전돼야
 * 한다. 이 성질은 테스트로 고정한다.
 */
function buildCompatibilityEvidence({
  firstChart,
  secondChart,
  firstPersonalEvidence,
  secondPersonalEvidence,
}) {
  const firstStem = stemByKorean(firstChart.saju.dayMaster);
  const secondStem = stemByKorean(secondChart.saju.dayMaster);

  const firstToSecond = elementRelation(firstStem.element, secondStem.element);
  const secondToFirst = elementRelation(secondStem.element, firstStem.element);
  const sameElement = firstStem.element === secondStem.element;
  const sameYinYang = firstStem.yinYang === secondStem.yinYang;

  const dayMasterInteraction = {
    firstToSecond: {
      relation: firstToSecond,
      fromElement: firstStem.element,
      toElement: secondStem.element,
    },
    secondToFirst: {
      relation: secondToFirst,
      fromElement: secondStem.element,
      toElement: firstStem.element,
    },
    summary: interactionSummary(firstToSecond),
    sameElement,
    sameYinYang,
  };

  // 교차 지지 관계 — 확정된 기둥끼리만 비교한다.
  const crossBranchRelations = findCrossBranchRelations(
    resolvedBranchSlots(firstChart),
    resolvedBranchSlots(secondChart),
  );

  const firstElements = presentElements(firstPersonalEvidence);
  const secondElements = presentElements(secondPersonalEvidence);
  const sharedElements = [...firstElements].filter((e) => secondElements.has(e)).sort();
  // 상대에게만 있는 오행 — "보완"이라는 가치 판단이 아니라 존재 차이의 기록이다.
  const complementaryElements = {
    onlyInFirst: [...firstElements].filter((e) => !secondElements.has(e)).sort(),
    onlyInSecond: [...secondElements].filter((e) => !firstElements.has(e)).sort(),
  };

  const supports = [];
  const tensions = [];

  if (sameElement) supports.push(SUPPORT_CODES.DAY_MASTER_SAME_ELEMENT);
  if (firstToSecond === 'generates') supports.push(SUPPORT_CODES.FIRST_GENERATES_SECOND);
  if (secondToFirst === 'generates') supports.push(SUPPORT_CODES.SECOND_GENERATES_FIRST);
  if (firstToSecond === 'controls') tensions.push(TENSION_CODES.FIRST_CONTROLS_SECOND);
  if (secondToFirst === 'controls') tensions.push(TENSION_CODES.SECOND_CONTROLS_FIRST);
  if (!sameYinYang) tensions.push(TENSION_CODES.CONTRASTING_YIN_YANG);
  if (sharedElements.length > 0) supports.push(SUPPORT_CODES.SHARED_ELEMENT_PRESENCE);

  const hasCrossHarmony = crossBranchRelations.some(
    (r) => r.type === RELATION_TYPES.SIX_HARMONY,
  );
  const hasCrossClash = crossBranchRelations.some(
    (r) => r.type === RELATION_TYPES.SIX_CLASH,
  );
  if (hasCrossHarmony) supports.push(SUPPORT_CODES.CROSS_SIX_HARMONY);
  if (hasCrossClash) tensions.push(TENSION_CODES.CROSS_SIX_CLASH);

  const omittedEvidence = [
    ...new Set([
      ...firstPersonalEvidence.omittedEvidence,
      ...secondPersonalEvidence.omittedEvidence,
    ]),
  ].sort();

  const confidence =
    firstPersonalEvidence.confidence === 'full' &&
    secondPersonalEvidence.confidence === 'full'
      ? 'full'
      : 'partial';

  return {
    evidenceVersion: SAJU_EVIDENCE_VERSION,
    confidence,
    participants: {
      first: {
        precision: firstPersonalEvidence.precision,
        dayMaster: firstPersonalEvidence.dayMaster,
        omittedEvidence: firstPersonalEvidence.omittedEvidence,
      },
      second: {
        precision: secondPersonalEvidence.precision,
        dayMaster: secondPersonalEvidence.dayMaster,
        omittedEvidence: secondPersonalEvidence.omittedEvidence,
      },
    },
    dayMasterInteraction,
    crossBranchRelations,
    sharedElements,
    complementaryElements,
    supports: supports.sort(),
    tensions: tensions.sort(),
    omittedEvidence,
  };
}

function interactionSummary(firstToSecond) {
  switch (firstToSecond) {
    case 'same':
      return INTERACTION_KEYS.SAME_ELEMENT;
    case 'generates':
      return INTERACTION_KEYS.FIRST_GENERATES_SECOND;
    case 'generatedBy':
      return INTERACTION_KEYS.SECOND_GENERATES_FIRST;
    case 'controls':
      return INTERACTION_KEYS.FIRST_CONTROLS_SECOND;
    case 'controlledBy':
      return INTERACTION_KEYS.SECOND_CONTROLS_FIRST;
    default:
      return INTERACTION_KEYS.NEUTRAL;
  }
}

module.exports = {
  SUPPORT_CODES,
  TENSION_CODES,
  INTERACTION_KEYS,
  buildCompatibilityEvidence,
};
