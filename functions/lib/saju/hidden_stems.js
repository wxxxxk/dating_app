'use strict';

/**
 * 지장간(支藏干) — Phase 5-3.
 *
 * 각 지지 안에 숨어 있는 천간 표다. 순서는 본기(main) → 중기(secondary) →
 * 여기(residual)의 의미를 갖는다.
 *
 * **가중치를 부여하지 않는다.** 60%/30%/10% 같은 비율은 유파마다 다르고
 * 근거를 댈 수 없으므로, 이번 Phase에서는 presence와 순서만 제공한다.
 *
 * convention: 자평명리 표준 지장간 표(본기/중기/여기 3분).
 * source type: 명리학 표준 표. 천문 자료가 아니다 —
 *              한국천문연구원 절기 자료와 출처를 혼동하지 않는다.
 * 확인 날짜: 2026-07-22
 * 적용 범위: 지지 12개 전체.
 */

const { branchByKorean } = require('./saju_constants');
const { tenGodFor } = require('./ten_gods');

/** 지지 → 지장간(순서 = 본기, 중기, 여기). */
const HIDDEN_STEMS = Object.freeze({
  자: Object.freeze(['계']),
  축: Object.freeze(['기', '계', '신']),
  인: Object.freeze(['갑', '병', '무']),
  묘: Object.freeze(['을']),
  진: Object.freeze(['무', '을', '계']),
  사: Object.freeze(['병', '무', '경']),
  오: Object.freeze(['정', '기']),
  미: Object.freeze(['기', '정', '을']),
  신: Object.freeze(['경', '임', '무']),
  유: Object.freeze(['신']),
  술: Object.freeze(['무', '신', '정']),
  해: Object.freeze(['임', '갑']),
});

/**
 * 개수에 따른 위치 이름.
 * 1개면 본기만, 2개면 본기·중기, 3개면 본기·중기·여기다.
 */
const POSITIONS = Object.freeze(['main', 'secondary', 'residual']);

function positionAt(index) {
  return POSITIONS[index] || null;
}

/**
 * [branchKorean]의 지장간을 [dayMasterKorean] 기준 십성과 함께 반환한다.
 *
 * 알 수 없는 지지면 null. 불확실한 기둥에서는 **호출부가 아예 부르지 않는다** —
 * 여기서 임의로 빈 배열을 돌려주지 않는다.
 */
function hiddenStemsFor(branchKorean, dayMasterKorean) {
  const branch = branchByKorean(branchKorean);
  if (!branch) return null;
  const stems = HIDDEN_STEMS[branch.korean];
  if (!stems) return null;

  return {
    branch: branch.korean,
    stems: stems.map((stem, index) => ({
      stem,
      position: positionAt(index),
      tenGod: tenGodFor(dayMasterKorean, stem),
    })),
  };
}

module.exports = {
  HIDDEN_STEMS,
  POSITIONS,
  hiddenStemsFor,
};
