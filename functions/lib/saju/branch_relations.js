'use strict';

/**
 * 지지 관계 — 육합·육충·삼합 (Phase 5-3).
 *
 * 표가 명시적이고 유파 차이가 없는 세 관계만 구현한다. 형(刑)·파(破)·해(害)·
 * 방합(三會)은 유파별 표가 갈려 이번 Phase에서 제외했다(최종 보고 참고).
 *
 * **엔진은 좋고 나쁨을 판정하지 않는다.** 합이 항상 좋은 것도, 충이 항상 나쁜
 * 것도 아니다. 관계의 존재만 돌려주고 해석은 상위 계층이 맡는다.
 *
 * convention: 자평명리 표준 육합·육충·삼합 표.
 * source type: 명리학 표준 표. 천문 자료가 아니다.
 * 확인 날짜: 2026-07-22
 * 적용 범위: 지지 12개 조합.
 */

const { branchByKorean } = require('./saju_constants');

const RELATION_TYPES = Object.freeze({
  SIX_HARMONY: 'sixHarmony',
  SIX_CLASH: 'sixClash',
  THREE_HARMONY: 'threeHarmony',
});

/** 육합(六合) 6쌍. */
const SIX_HARMONY_PAIRS = Object.freeze([
  Object.freeze(['자', '축']),
  Object.freeze(['인', '해']),
  Object.freeze(['묘', '술']),
  Object.freeze(['진', '유']),
  Object.freeze(['사', '신']),
  Object.freeze(['오', '미']),
]);

/** 육충(六沖) 6쌍. */
const SIX_CLASH_PAIRS = Object.freeze([
  Object.freeze(['자', '오']),
  Object.freeze(['축', '미']),
  Object.freeze(['인', '신']),
  Object.freeze(['묘', '유']),
  Object.freeze(['진', '술']),
  Object.freeze(['사', '해']),
]);

/** 삼합(三合) 4그룹과 결과 오행. */
const THREE_HARMONY_GROUPS = Object.freeze([
  Object.freeze({ branches: Object.freeze(['신', '자', '진']), element: '수' }),
  Object.freeze({ branches: Object.freeze(['해', '묘', '미']), element: '목' }),
  Object.freeze({ branches: Object.freeze(['인', '오', '술']), element: '화' }),
  Object.freeze({ branches: Object.freeze(['사', '유', '축']), element: '금' }),
]);

function pairKey(a, b) {
  return [a, b].sort().join('-');
}

const SIX_HARMONY_SET = new Set(SIX_HARMONY_PAIRS.map(([a, b]) => pairKey(a, b)));
const SIX_CLASH_SET = new Set(SIX_CLASH_PAIRS.map(([a, b]) => pairKey(a, b)));

/** 두 지지가 육합인지. 순서와 무관하다. */
function isSixHarmony(a, b) {
  return SIX_HARMONY_SET.has(pairKey(a, b));
}

/** 두 지지가 육충인지. 순서와 무관하다. */
function isSixClash(a, b) {
  return SIX_CLASH_SET.has(pairKey(a, b));
}

/**
 * 확정된 기둥 목록에서 지지 관계를 찾는다.
 *
 * [slots]는 `{ pillar: 'year'|'month'|'day'|'hour', branch: '자' }` 배열이다.
 * **불확실하거나 없는 기둥은 호출부가 미리 빼고 넘긴다** — 여기서 후보를
 * 넣어 "가능한 관계"를 실제 관계처럼 만들지 않는다.
 *
 * 같은 관계를 순서만 바꿔 중복 반환하지 않는다.
 */
function findBranchRelations(slots) {
  const valid = (slots || []).filter(
    (slot) => slot && slot.branch && branchByKorean(slot.branch),
  );
  const relations = [];

  // 육합·육충 — 서로 다른 두 기둥의 조합.
  for (let i = 0; i < valid.length; i += 1) {
    for (let j = i + 1; j < valid.length; j += 1) {
      const a = valid[i];
      const b = valid[j];
      if (isSixHarmony(a.branch, b.branch)) {
        relations.push({
          type: RELATION_TYPES.SIX_HARMONY,
          branches: [a.branch, b.branch],
          pillars: [a.pillar, b.pillar],
          resultingElement: null,
        });
      } else if (isSixClash(a.branch, b.branch)) {
        relations.push({
          type: RELATION_TYPES.SIX_CLASH,
          branches: [a.branch, b.branch],
          pillars: [a.pillar, b.pillar],
          resultingElement: null,
        });
      }
    }
  }

  // 삼합 — 세 지지가 모두 있어야 성립한다(반합은 이번 Phase에서 다루지 않는다).
  for (const group of THREE_HARMONY_GROUPS) {
    const matched = group.branches.map((branch) =>
      valid.find((slot) => slot.branch === branch),
    );
    if (matched.every(Boolean)) {
      // 같은 지지를 두 번 쓰지 않았는지 확인한다.
      const pillars = matched.map((slot) => slot.pillar);
      if (new Set(pillars).size === pillars.length) {
        relations.push({
          type: RELATION_TYPES.THREE_HARMONY,
          branches: [...group.branches],
          pillars,
          resultingElement: group.element,
        });
      }
    }
  }

  return relations;
}

/**
 * 두 사람의 확정된 지지를 교차 비교한다.
 *
 * 본인 원국 내부 관계와 섞이지 않도록, 항상 first × second 쌍만 만든다.
 * 삼합은 한 사람 안에서 성립하는 개념이라 교차 비교에서는 다루지 않는다.
 */
function findCrossBranchRelations(firstSlots, secondSlots) {
  const first = (firstSlots || []).filter(
    (s) => s && s.branch && branchByKorean(s.branch),
  );
  const second = (secondSlots || []).filter(
    (s) => s && s.branch && branchByKorean(s.branch),
  );
  const relations = [];

  for (const a of first) {
    for (const b of second) {
      let type = null;
      if (isSixHarmony(a.branch, b.branch)) type = RELATION_TYPES.SIX_HARMONY;
      else if (isSixClash(a.branch, b.branch)) type = RELATION_TYPES.SIX_CLASH;
      if (!type) continue;
      relations.push({
        type,
        firstPillar: a.pillar,
        firstBranch: a.branch,
        secondPillar: b.pillar,
        secondBranch: b.branch,
      });
    }
  }

  return relations;
}

module.exports = {
  RELATION_TYPES,
  SIX_HARMONY_PAIRS,
  SIX_CLASH_PAIRS,
  THREE_HARMONY_GROUPS,
  isSixHarmony,
  isSixClash,
  findBranchRelations,
  findCrossBranchRelations,
};
