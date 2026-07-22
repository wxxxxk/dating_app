'use strict';

/**
 * Evidence 코드 → 한국어 의미와 **허용 서술 범위** — Phase 5-4 Stage A 보정 1회차.
 *
 * Stage A 1차 평가에서 evidenceFidelity가 세 후보 공통 최저 항목이었다.
 * 원인 분석 결과, 모델이 근거를 무시한 게 아니라 **근거에 의미가 없어서**
 * 스스로 의미를 지어내고 있었다:
 *
 * - catalog가 `crossSixHarmony`, `secondControlsFirst`, `sikSin` 같은
 *   내부 코드명을 그대로 노출했다. 모델은 뜻을 추측할 수밖에 없고,
 *   그 추측이 그대로 단정 문장이 됐다.
 * - hiddenStem 항목은 `${s.tenGod}` 보간 버그로 `[object Object]`가 들어갔다.
 *   개인 catalog 13개 중 4개가 아무 정보도 담지 못한 채 인용 가능했다.
 *
 * 그래서 코드 → 의미 변환을 **서버가 결정론적으로** 하고, 각 항목이
 * 무엇을 말해도 되는지(`domains`)까지 함께 넘긴다. 모델은 해석만 한다.
 *
 * 여기 있는 문장은 evidence에서 바로 따라 나오는 범위까지만 쓴다.
 * 구체적 행동·감정 단정은 여기서 하지 않는다 — 그건 모델이 조건부로 쓴다.
 */

/** 서술 도메인. claim이 어느 주제를 다룰 수 있는지 제한하는 축이다. */
const DOMAINS = Object.freeze({
  TEMPERAMENT: 'temperament',
  EXPRESSION: 'expression',
  PACE: 'pace',
  CONFLICT: 'conflict',
  NEED: 'need',
  ATTRACTION: 'attraction',
  INTERACTION: 'interaction',
  /** 확정도. 관찰 근거가 아니라 "얼마나 말할 수 있는지"의 메타 정보다. */
  META: 'meta',
});

/**
 * 십성 → 관계 맥락에서의 의미와 허용 도메인.
 *
 * label은 표시용이고, meaning은 모델이 실제로 읽는 해석 근거다.
 * meaning은 성격 단정이 아니라 "어떤 축이 두드러진다"까지만 말한다.
 */
const TEN_GOD_MEANINGS = Object.freeze({
  biGyeon: {
    meaning: '자기 기준과 주도권을 유지하려는 축이 뚜렷함',
    domains: [DOMAINS.TEMPERAMENT, DOMAINS.PACE, DOMAINS.CONFLICT],
  },
  geopJae: {
    meaning: '경쟁·비교 상황에서 반응이 빨라지는 축',
    domains: [DOMAINS.TEMPERAMENT, DOMAINS.CONFLICT],
  },
  sikSin: {
    meaning: '즐거움과 편안함을 밖으로 드러내는 표현 축',
    domains: [DOMAINS.EXPRESSION, DOMAINS.ATTRACTION],
  },
  sangGwan: {
    meaning: '느낀 것을 직접적으로 말로 드러내는 표현 축',
    domains: [DOMAINS.EXPRESSION, DOMAINS.CONFLICT],
  },
  pyeonJae: {
    meaning: '상황과 사람을 폭넓게 살피며 관계를 운용하는 축',
    domains: [DOMAINS.ATTRACTION, DOMAINS.EXPRESSION],
  },
  jeongJae: {
    meaning: '약속·현실 조건을 꼼꼼히 챙기는 축',
    domains: [DOMAINS.NEED, DOMAINS.PACE],
  },
  pyeonGwan: {
    meaning: '긴장과 책임을 스스로 지려는 축',
    domains: [DOMAINS.CONFLICT, DOMAINS.NEED],
  },
  jeongGwan: {
    meaning: '규범과 예의를 지키려는 축',
    domains: [DOMAINS.NEED, DOMAINS.PACE],
  },
  pyeonIn: {
    meaning: '혼자 정리하고 해석하는 내적 처리 축',
    domains: [DOMAINS.CONFLICT, DOMAINS.TEMPERAMENT],
  },
  jeongIn: {
    meaning: '받아들이고 기다려주는 수용 축',
    domains: [DOMAINS.NEED, DOMAINS.ATTRACTION],
  },
});

/** 지지 관계 코드 → 의미. */
const BRANCH_RELATION_MEANINGS = Object.freeze({
  sixHarmony: {
    meaning: '서로 당기는 방향으로 맞물리는 자리',
    domains: [DOMAINS.ATTRACTION, DOMAINS.INTERACTION],
  },
  sixClash: {
    meaning: '반응이 서로 부딪히기 쉬운 자리',
    domains: [DOMAINS.CONFLICT, DOMAINS.INTERACTION],
  },
  threeHarmony: {
    meaning: '여러 자리가 같은 방향으로 모이는 자리',
    domains: [DOMAINS.ATTRACTION, DOMAINS.INTERACTION],
  },
});

/** 궁합 support/tension 코드 → 의미. */
const INTERACTION_MEANINGS = Object.freeze({
  crossSixHarmony: {
    meaning: '두 사람의 자리가 서로 맞물려 가까워지기 쉬움',
    domains: [DOMAINS.ATTRACTION, DOMAINS.INTERACTION],
  },
  crossSixClash: {
    meaning: '두 사람의 자리가 부딪혀 반응 차이가 드러나기 쉬움',
    domains: [DOMAINS.CONFLICT, DOMAINS.INTERACTION],
  },
  sharedElementPresence: {
    meaning: '공통된 기반이 있어 말이 빨리 통하는 지점이 있음',
    domains: [DOMAINS.INTERACTION, DOMAINS.EXPRESSION],
  },
  contrastingYinYang: {
    meaning: '표현을 밖으로 꺼내는 속도가 서로 다름',
    domains: [DOMAINS.EXPRESSION, DOMAINS.PACE],
  },
  dayMasterSameElement: {
    meaning: '두 사람의 기본 결이 같은 방향임',
    domains: [DOMAINS.INTERACTION, DOMAINS.TEMPERAMENT],
  },
  firstControlsSecond: {
    meaning: '첫 번째 사람이 기준을 제시하는 쪽으로 기울기 쉬움',
    domains: [DOMAINS.INTERACTION, DOMAINS.CONFLICT],
  },
  secondControlsFirst: {
    meaning: '두 번째 사람이 기준을 제시하는 쪽으로 기울기 쉬움',
    domains: [DOMAINS.INTERACTION, DOMAINS.CONFLICT],
  },
  firstGeneratesSecond: {
    meaning: '첫 번째 사람이 북돋아주는 쪽으로 기울기 쉬움',
    domains: [DOMAINS.INTERACTION, DOMAINS.NEED],
  },
  secondGeneratesFirst: {
    meaning: '두 번째 사람이 북돋아주는 쪽으로 기울기 쉬움',
    domains: [DOMAINS.INTERACTION, DOMAINS.NEED],
  },
});

/** 알 수 없는 코드는 조용히 넘기지 않는다 — 의미 없는 근거를 만들지 않기 위함. */
function meaningFor(map, code, fallbackDomains) {
  const found = map[code];
  if (found) return found;
  return {
    meaning: null,
    domains: fallbackDomains,
    unknownCode: code,
  };
}

module.exports = {
  DOMAINS,
  TEN_GOD_MEANINGS,
  BRANCH_RELATION_MEANINGS,
  INTERACTION_MEANINGS,
  meaningFor,
};
