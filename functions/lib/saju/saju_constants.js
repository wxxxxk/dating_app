'use strict';

/**
 * 천간·지지·오행 공용 상수와 관계 함수 — Phase 5-3.
 *
 * Phase 5-2A까지 saju_engine_v2.js 안에 있던 표를 여기로 옮겼다. 십성·지장간·
 * 지지 관계 모듈이 모두 같은 표를 참조해야 하고, index.js에 표가 계속 쌓이는 것을
 * 막기 위해서다. saju_engine_v2.js는 하위 호환을 위해 그대로 re-export한다.
 *
 * convention: 자평명리(子平命理) 표준 표.
 * source type: 명리학 표준 표(유파 무관하게 동일). 천문 계산이 아니므로
 *              한국천문연구원 자료와는 출처가 다르다 — 혼동하지 않는다.
 * 확인 날짜: 2026-07-22
 * 적용 범위: 천간 10 / 지지 12 음양·오행, 오행 상생·상극 순환.
 */

/** 오행 순서를 고정해 동점일 때도 결과가 항상 같게 만든다. */
const ELEMENT_KEYS = Object.freeze(['목', '화', '토', '금', '수']);

const YIN = 'yin';
const YANG = 'yang';

/**
 * 천간 10개. index는 60갑자 계산에 그대로 쓰인다.
 *
 * 갑·병·무·경·임이 양간, 을·정·기·신·계가 음간이다.
 */
const STEMS = Object.freeze([
  { korean: '갑', hanja: '甲', element: '목', yinYang: YANG },
  { korean: '을', hanja: '乙', element: '목', yinYang: YIN },
  { korean: '병', hanja: '丙', element: '화', yinYang: YANG },
  { korean: '정', hanja: '丁', element: '화', yinYang: YIN },
  { korean: '무', hanja: '戊', element: '토', yinYang: YANG },
  { korean: '기', hanja: '己', element: '토', yinYang: YIN },
  { korean: '경', hanja: '庚', element: '금', yinYang: YANG },
  { korean: '신', hanja: '辛', element: '금', yinYang: YIN },
  { korean: '임', hanja: '壬', element: '수', yinYang: YANG },
  { korean: '계', hanja: '癸', element: '수', yinYang: YIN },
].map((s) => Object.freeze({ ...s, yin: s.yinYang === YIN })));

/**
 * 지지 12개. 대표 오행만 쓰고 지장간(藏干) 세부 가중치는 반영하지 않는다.
 *
 * 음양은 순서 기준이다 — 자·인·진·오·신·술이 양지, 축·묘·사·미·유·해가 음지.
 * (일부 유파는 사·오의 체용 음양을 뒤집어 쓰지만, 이 제품은 위 표준을 채택한다.)
 */
const BRANCHES = Object.freeze([
  { korean: '자', hanja: '子', element: '수', yinYang: YANG },
  { korean: '축', hanja: '丑', element: '토', yinYang: YIN },
  { korean: '인', hanja: '寅', element: '목', yinYang: YANG },
  { korean: '묘', hanja: '卯', element: '목', yinYang: YIN },
  { korean: '진', hanja: '辰', element: '토', yinYang: YANG },
  { korean: '사', hanja: '巳', element: '화', yinYang: YIN },
  { korean: '오', hanja: '午', element: '화', yinYang: YANG },
  { korean: '미', hanja: '未', element: '토', yinYang: YIN },
  { korean: '신', hanja: '申', element: '금', yinYang: YANG },
  { korean: '유', hanja: '酉', element: '금', yinYang: YIN },
  { korean: '술', hanja: '戌', element: '토', yinYang: YANG },
  { korean: '해', hanja: '亥', element: '수', yinYang: YIN },
].map((b) => Object.freeze(b)));

const STEM_BY_KOREAN = Object.freeze(
  Object.fromEntries(STEMS.map((s) => [s.korean, s])),
);
const BRANCH_BY_KOREAN = Object.freeze(
  Object.fromEntries(BRANCHES.map((b) => [b.korean, b])),
);

/** 상생 순환: 목→화→토→금→수→목. */
const GENERATES = Object.freeze({
  목: '화',
  화: '토',
  토: '금',
  금: '수',
  수: '목',
});

/** 상극 순환: 목→토→수→화→금→목. */
const CONTROLS = Object.freeze({
  목: '토',
  토: '수',
  수: '화',
  화: '금',
  금: '목',
});

function stemByKorean(korean) {
  return STEM_BY_KOREAN[korean] || null;
}

function branchByKorean(korean) {
  return BRANCH_BY_KOREAN[korean] || null;
}

function isElement(value) {
  return ELEMENT_KEYS.includes(value);
}

/**
 * 두 오행의 관계. 이름 문자열 비교가 아니라 이 함수로만 판정한다.
 *
 * 반환: 'same' | 'generates' | 'generatedBy' | 'controls' | 'controlledBy'
 * [from] 기준으로 본 [to]와의 관계다. 방향이 바뀌면 결과도 바뀐다.
 */
function elementRelation(from, to) {
  if (!isElement(from) || !isElement(to)) return null;
  if (from === to) return 'same';
  if (GENERATES[from] === to) return 'generates';
  if (GENERATES[to] === from) return 'generatedBy';
  if (CONTROLS[from] === to) return 'controls';
  if (CONTROLS[to] === from) return 'controlledBy';
  // 오행 5개는 위 네 관계로 모두 덮인다 — 여기 도달하면 표가 깨진 것이다.
  return null;
}

/** 오행 count를 0으로 채운 map. */
function emptyElementCounts() {
  return Object.fromEntries(ELEMENT_KEYS.map((k) => [k, 0]));
}

module.exports = {
  YIN,
  YANG,
  ELEMENT_KEYS,
  STEMS,
  BRANCHES,
  GENERATES,
  CONTROLS,
  stemByKorean,
  branchByKorean,
  isElement,
  elementRelation,
  emptyElementCounts,
};
