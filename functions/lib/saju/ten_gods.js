'use strict';

/**
 * 십성(十星) 계산 — Phase 5-3.
 *
 * 일간(日干)을 기준으로 다른 천간과의 오행 생극 관계 + 음양 동일 여부만으로
 * 결정론적으로 정해진다. 표가 아니라 규칙이므로 100개 조합을 전부 테스트한다.
 *
 * convention: 자평명리 표준 십성 정의.
 * source type: 명리학 표준 규칙(유파 무관). 천문 자료가 아니다.
 * 확인 날짜: 2026-07-22
 * 적용 범위: 천간 10 × 천간 10. 지지는 지장간을 거쳐 이 함수를 재사용한다.
 *
 * **AI에게 이 계산을 시키지 않는다.** 결과 key와 label을 함께 넘겨 해석만 맡긴다.
 */

const { stemByKorean, elementRelation } = require('./saju_constants');

/** 십성 key와 한글 label. key는 저장·비교용, label은 표시·프롬프트용이다. */
const TEN_GOD_LABELS = Object.freeze({
  biGyeon: '비견',
  geopJae: '겁재',
  sikSin: '식신',
  sangGwan: '상관',
  pyeonJae: '편재',
  jeongJae: '정재',
  pyeonGwan: '편관',
  jeongGwan: '정관',
  pyeonIn: '편인',
  jeongIn: '정인',
});

const TEN_GOD_KEYS = Object.freeze(Object.keys(TEN_GOD_LABELS));

/**
 * 일간 대비 오행 관계와 음양 일치 여부로 십성 key를 정한다.
 *
 * 관계는 **일간에서 대상을 본 방향**이다:
 * - same          같은 오행      → 같은 음양 비견 / 다른 음양 겁재
 * - generates     일간이 생함    → 같은 음양 식신 / 다른 음양 상관
 * - controls      일간이 극함    → 같은 음양 편재 / 다른 음양 정재
 * - controlledBy  일간이 극당함  → 같은 음양 편관 / 다른 음양 정관
 * - generatedBy   일간이 생받음  → 같은 음양 편인 / 다른 음양 정인
 */
const RELATION_MAP = Object.freeze({
  same: { sameYinYang: 'biGyeon', differentYinYang: 'geopJae' },
  generates: { sameYinYang: 'sikSin', differentYinYang: 'sangGwan' },
  controls: { sameYinYang: 'pyeonJae', differentYinYang: 'jeongJae' },
  controlledBy: { sameYinYang: 'pyeonGwan', differentYinYang: 'jeongGwan' },
  generatedBy: { sameYinYang: 'pyeonIn', differentYinYang: 'jeongIn' },
});

/**
 * [dayMasterKorean] 일간에서 본 [targetStemKorean]의 십성.
 *
 * 알 수 없는 천간이면 null을 반환한다 — 조용히 기본값으로 넘기지 않는다.
 */
function tenGodFor(dayMasterKorean, targetStemKorean) {
  const dayMaster = stemByKorean(dayMasterKorean);
  const target = stemByKorean(targetStemKorean);
  if (!dayMaster || !target) return null;

  const relation = elementRelation(dayMaster.element, target.element);
  const mapping = RELATION_MAP[relation];
  if (!mapping) return null;

  const sameYinYang = dayMaster.yinYang === target.yinYang;
  const key = sameYinYang ? mapping.sameYinYang : mapping.differentYinYang;

  return {
    key,
    label: TEN_GOD_LABELS[key],
    stem: target.korean,
    element: target.element,
    yinYang: target.yinYang,
    elementRelation: relation,
    sameYinYang,
  };
}

module.exports = {
  TEN_GOD_KEYS,
  TEN_GOD_LABELS,
  RELATION_MAP,
  tenGodFor,
};
