'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  STEMS,
  BRANCHES,
  ELEMENT_KEYS,
  elementRelation,
} = require('../lib/saju/saju_constants');
const { TEN_GOD_KEYS, TEN_GOD_LABELS, tenGodFor } = require('../lib/saju/ten_gods');
const { HIDDEN_STEMS, hiddenStemsFor } = require('../lib/saju/hidden_stems');
const {
  SIX_HARMONY_PAIRS,
  SIX_CLASH_PAIRS,
  THREE_HARMONY_GROUPS,
  isSixHarmony,
  isSixClash,
  findBranchRelations,
  findCrossBranchRelations,
} = require('../lib/saju/branch_relations');

// Phase 5-3 — 명리 규칙 전수 검증.
//
// 여기서 검증하는 것은 표와 규칙 자체다. fixture 회귀(saju_evidence.test.js)와
// 역할이 다르다 — 표가 틀리면 fixture도 함께 틀리므로, 표는 독립적으로 확인한다.
// 실제 사용자 데이터를 쓰지 않는다.

// ── 테스트 쪽에 독립적으로 둔 명리 표 ──────────────────────────────────────
// 프로덕션 코드를 import하지 않고 다시 적는다. 한쪽에 오타가 나면 어긋난다.

const STEM_SPEC = {
  갑: ['목', 'yang'],
  을: ['목', 'yin'],
  병: ['화', 'yang'],
  정: ['화', 'yin'],
  무: ['토', 'yang'],
  기: ['토', 'yin'],
  경: ['금', 'yang'],
  신: ['금', 'yin'],
  임: ['수', 'yang'],
  계: ['수', 'yin'],
};

const BRANCH_SPEC = {
  자: ['수', 'yang'],
  축: ['토', 'yin'],
  인: ['목', 'yang'],
  묘: ['목', 'yin'],
  진: ['토', 'yang'],
  사: ['화', 'yin'],
  오: ['화', 'yang'],
  미: ['토', 'yin'],
  신: ['금', 'yang'],
  유: ['금', 'yin'],
  술: ['토', 'yang'],
  해: ['수', 'yin'],
};

const GEN = { 목: '화', 화: '토', 토: '금', 금: '수', 수: '목' };
const CON = { 목: '토', 토: '수', 수: '화', 화: '금', 금: '목' };

/** 일간 오행 D에서 본 대상 오행 T의 관계를 테스트 쪽에서 다시 유도한다. */
function expectedRelation(d, t) {
  if (d === t) return 'same';
  if (GEN[d] === t) return 'generates';
  if (GEN[t] === d) return 'generatedBy';
  if (CON[d] === t) return 'controls';
  if (CON[t] === d) return 'controlledBy';
  return null;
}

const EXPECTED_TEN_GOD = {
  same: ['biGyeon', 'geopJae'],
  generates: ['sikSin', 'sangGwan'],
  controls: ['pyeonJae', 'jeongJae'],
  controlledBy: ['pyeonGwan', 'jeongGwan'],
  generatedBy: ['pyeonIn', 'jeongIn'],
};

// ── 음양·오행 계약 ────────────────────────────────────────────────────────

test('천간 10개의 오행·음양이 표준 표와 일치한다', () => {
  assert.equal(STEMS.length, 10);
  assert.equal(new Set(STEMS.map((s) => s.korean)).size, 10);
  for (const stem of STEMS) {
    const [element, yinYang] = STEM_SPEC[stem.korean];
    assert.equal(stem.element, element, `${stem.korean} 오행`);
    assert.equal(stem.yinYang, yinYang, `${stem.korean} 음양`);
    assert.ok(ELEMENT_KEYS.includes(stem.element));
  }
});

test('지지 12개의 오행·음양이 표준 표와 일치한다', () => {
  assert.equal(BRANCHES.length, 12);
  assert.equal(new Set(BRANCHES.map((b) => b.korean)).size, 12);
  for (const branch of BRANCHES) {
    const [element, yinYang] = BRANCH_SPEC[branch.korean];
    assert.equal(branch.element, element, `${branch.korean} 오행`);
    assert.equal(branch.yinYang, yinYang, `${branch.korean} 음양`);
  }
  // 양지 6개, 음지 6개.
  assert.equal(BRANCHES.filter((b) => b.yinYang === 'yang').length, 6);
  assert.equal(BRANCHES.filter((b) => b.yinYang === 'yin').length, 6);
});

test('오행 관계 함수가 방향을 구분한다', () => {
  assert.equal(elementRelation('목', '목'), 'same');
  assert.equal(elementRelation('목', '화'), 'generates');
  assert.equal(elementRelation('화', '목'), 'generatedBy');
  assert.equal(elementRelation('목', '토'), 'controls');
  assert.equal(elementRelation('토', '목'), 'controlledBy');
  assert.equal(elementRelation('목', '없음'), null);
  // 5×5 전부 관계가 정의돼야 한다.
  for (const a of ELEMENT_KEYS) {
    for (const b of ELEMENT_KEYS) {
      assert.equal(elementRelation(a, b), expectedRelation(a, b), `${a}->${b}`);
    }
  }
});

// ── 십성 ─────────────────────────────────────────────────────────────────

test('십성 10개 key와 label이 고정돼 있다', () => {
  assert.equal(TEN_GOD_KEYS.length, 10);
  assert.equal(new Set(Object.values(TEN_GOD_LABELS)).size, 10);
  assert.deepEqual(
    [...TEN_GOD_KEYS].sort(),
    [
      'biGyeon', 'geopJae', 'jeongGwan', 'jeongIn', 'jeongJae',
      'pyeonGwan', 'pyeonIn', 'pyeonJae', 'sangGwan', 'sikSin',
    ].sort(),
  );
});

test('일간 10 × 대상 천간 10 = 100조합이 모두 규칙과 일치한다', () => {
  const mismatches = [];
  for (const dayMaster of Object.keys(STEM_SPEC)) {
    for (const target of Object.keys(STEM_SPEC)) {
      const [dElement, dYinYang] = STEM_SPEC[dayMaster];
      const [tElement, tYinYang] = STEM_SPEC[target];
      const relation = expectedRelation(dElement, tElement);
      const sameYinYang = dYinYang === tYinYang;
      const want = EXPECTED_TEN_GOD[relation][sameYinYang ? 0 : 1];

      const actual = tenGodFor(dayMaster, target);
      if (!actual || actual.key !== want) {
        mismatches.push(
          `dayMaster=${dayMaster} target=${target} expected=${want} actual=${
            actual ? actual.key : 'null'
          }`,
        );
      }
    }
  }
  assert.equal(mismatches.length, 0, mismatches.join('\n'));
});

test('갑 일간의 십성 10개가 표준 결과와 일치한다', () => {
  // 손으로 확인한 기준값. 규칙 유도와 별개로 한 줄씩 고정한다.
  const expected = {
    갑: 'biGyeon',
    을: 'geopJae',
    병: 'sikSin',
    정: 'sangGwan',
    무: 'pyeonJae',
    기: 'jeongJae',
    경: 'pyeonGwan',
    신: 'jeongGwan',
    임: 'pyeonIn',
    계: 'jeongIn',
  };
  for (const [target, key] of Object.entries(expected)) {
    assert.equal(tenGodFor('갑', target).key, key, `갑 -> ${target}`);
  }
});

test('자기 자신은 항상 비견이다', () => {
  for (const stem of Object.keys(STEM_SPEC)) {
    assert.equal(tenGodFor(stem, stem).key, 'biGyeon', stem);
  }
});

test('같은 오행 반대 음양은 항상 겁재다', () => {
  const pairs = [
    ['갑', '을'], ['병', '정'], ['무', '기'], ['경', '신'], ['임', '계'],
  ];
  for (const [a, b] of pairs) {
    assert.equal(tenGodFor(a, b).key, 'geopJae', `${a}->${b}`);
    assert.equal(tenGodFor(b, a).key, 'geopJae', `${b}->${a}`);
  }
});

test('방향이 바뀌면 십성도 바뀐다', () => {
  // 갑(목)이 병(화)을 생하면 식신, 반대로 병 일간이 갑을 보면 편인이다.
  assert.equal(tenGodFor('갑', '병').key, 'sikSin');
  assert.equal(tenGodFor('병', '갑').key, 'pyeonIn');
  assert.equal(tenGodFor('갑', '무').key, 'pyeonJae');
  assert.equal(tenGodFor('무', '갑').key, 'pyeonGwan');
});

test('알 수 없는 천간은 null로 거부한다 — 기본값으로 넘기지 않는다', () => {
  assert.equal(tenGodFor('갑', '자'), null, '지지를 천간으로 넘기면 거부');
  assert.equal(tenGodFor('없음', '갑'), null);
  assert.equal(tenGodFor('갑', ''), null);
  assert.equal(tenGodFor(null, '갑'), null);
  assert.equal(tenGodFor('갑', undefined), null);
});

test('십성 결과 key 집합이 allowlist를 벗어나지 않는다', () => {
  const allowed = new Set([
    'key', 'label', 'stem', 'element', 'yinYang', 'elementRelation', 'sameYinYang',
  ]);
  const result = tenGodFor('갑', '병');
  for (const key of Object.keys(result)) {
    assert.ok(allowed.has(key), `허용되지 않은 key=${key}`);
  }
  assert.ok(TEN_GOD_KEYS.includes(result.key));
});

// ── 지장간 ───────────────────────────────────────────────────────────────

test('지장간 12지지 표가 표준과 정확히 일치한다', () => {
  const expected = {
    자: ['계'],
    축: ['기', '계', '신'],
    인: ['갑', '병', '무'],
    묘: ['을'],
    진: ['무', '을', '계'],
    사: ['병', '무', '경'],
    오: ['정', '기'],
    미: ['기', '정', '을'],
    신: ['경', '임', '무'],
    유: ['신'],
    술: ['무', '신', '정'],
    해: ['임', '갑'],
  };
  assert.equal(Object.keys(HIDDEN_STEMS).length, 12);
  for (const [branch, stems] of Object.entries(expected)) {
    assert.deepEqual([...HIDDEN_STEMS[branch]], stems, branch);
  }
});

test('지장간 position이 개수에 따라 정해진다', () => {
  assert.deepEqual(
    hiddenStemsFor('자', '갑').stems.map((s) => s.position),
    ['main'],
  );
  assert.deepEqual(
    hiddenStemsFor('오', '갑').stems.map((s) => s.position),
    ['main', 'secondary'],
  );
  assert.deepEqual(
    hiddenStemsFor('축', '갑').stems.map((s) => s.position),
    ['main', 'secondary', 'residual'],
  );
});

test('지장간에 중복 천간이 없고 순서가 보존된다', () => {
  for (const [branch, stems] of Object.entries(HIDDEN_STEMS)) {
    assert.equal(new Set(stems).size, stems.length, `${branch} 중복`);
    const result = hiddenStemsFor(branch, '갑');
    assert.deepEqual(result.stems.map((s) => s.stem), [...stems], branch);
  }
});

test('지장간의 십성이 일간별로 결정론적으로 파생된다', () => {
  // 축 = 기(토)·계(수)·신(금). 갑(목) 일간 기준으로 각각 정재·정인·정관이다.
  const forGap = hiddenStemsFor('축', '갑');
  assert.deepEqual(
    forGap.stems.map((s) => s.tenGod.key),
    ['jeongJae', 'jeongIn', 'jeongGwan'],
  );
  // 일간이 바뀌면 십성도 바뀐다.
  const forGyeong = hiddenStemsFor('축', '경');
  assert.notDeepEqual(
    forGyeong.stems.map((s) => s.tenGod.key),
    forGap.stems.map((s) => s.tenGod.key),
  );
  // 모든 지지 × 모든 일간에서 십성이 반드시 나온다.
  for (const branch of Object.keys(HIDDEN_STEMS)) {
    for (const dayMaster of Object.keys(STEM_SPEC)) {
      for (const item of hiddenStemsFor(branch, dayMaster).stems) {
        assert.ok(TEN_GOD_KEYS.includes(item.tenGod.key), `${branch}/${dayMaster}`);
      }
    }
  }
});

test('지장간에 가중치·비율이 들어 있지 않다', () => {
  const serialized = JSON.stringify(hiddenStemsFor('축', '갑'));
  for (const banned of ['weight', 'ratio', 'percent', '0.6', '0.3', '0.1']) {
    assert.ok(!serialized.includes(banned), `가중치 흔적: ${banned}`);
  }
});

test('알 수 없는 지지는 null로 거부한다', () => {
  assert.equal(hiddenStemsFor('갑', '갑'), null, '천간을 지지로 넘기면 거부');
  assert.equal(hiddenStemsFor('없음', '갑'), null);
  assert.equal(hiddenStemsFor(null, '갑'), null);
});

// ── 지지 관계 ────────────────────────────────────────────────────────────

test('육합 6쌍이 표준과 일치하고 순서에 무관하다', () => {
  const expected = [
    ['자', '축'], ['인', '해'], ['묘', '술'],
    ['진', '유'], ['사', '신'], ['오', '미'],
  ];
  assert.equal(SIX_HARMONY_PAIRS.length, 6);
  for (const [a, b] of expected) {
    assert.ok(isSixHarmony(a, b), `${a}-${b}`);
    assert.ok(isSixHarmony(b, a), `${b}-${a} (역순)`);
  }
  assert.ok(!isSixHarmony('자', '오'));
});

test('육충 6쌍이 표준과 일치하고 순서에 무관하다', () => {
  const expected = [
    ['자', '오'], ['축', '미'], ['인', '신'],
    ['묘', '유'], ['진', '술'], ['사', '해'],
  ];
  assert.equal(SIX_CLASH_PAIRS.length, 6);
  for (const [a, b] of expected) {
    assert.ok(isSixClash(a, b), `${a}-${b}`);
    assert.ok(isSixClash(b, a), `${b}-${a} (역순)`);
  }
  assert.ok(!isSixClash('자', '축'));
});

test('육합과 육충은 겹치지 않는다', () => {
  for (const [a, b] of SIX_HARMONY_PAIRS) {
    assert.ok(!isSixClash(a, b), `${a}-${b}가 합이면서 충일 수 없다`);
  }
});

test('삼합 4그룹과 결과 오행이 표준과 일치한다', () => {
  const expected = [
    [['신', '자', '진'], '수'],
    [['해', '묘', '미'], '목'],
    [['인', '오', '술'], '화'],
    [['사', '유', '축'], '금'],
  ];
  assert.equal(THREE_HARMONY_GROUPS.length, 4);
  for (const [branches, element] of expected) {
    const group = THREE_HARMONY_GROUPS.find(
      (g) => g.branches.join('') === branches.join(''),
    );
    assert.ok(group, branches.join(''));
    assert.equal(group.element, element);
  }
});

test('원국 관계 탐지 — 육합·육충·삼합', () => {
  const harmony = findBranchRelations([
    { pillar: 'year', branch: '자' },
    { pillar: 'month', branch: '축' },
  ]);
  assert.equal(harmony.length, 1);
  assert.equal(harmony[0].type, 'sixHarmony');
  assert.deepEqual(harmony[0].pillars, ['year', 'month']);
  assert.equal(harmony[0].resultingElement, null);

  const clash = findBranchRelations([
    { pillar: 'day', branch: '인' },
    { pillar: 'hour', branch: '신' },
  ]);
  assert.equal(clash.length, 1);
  assert.equal(clash[0].type, 'sixClash');

  const three = findBranchRelations([
    { pillar: 'year', branch: '신' },
    { pillar: 'month', branch: '자' },
    { pillar: 'day', branch: '진' },
  ]);
  const threeHarmony = three.filter((r) => r.type === 'threeHarmony');
  assert.equal(threeHarmony.length, 1);
  assert.equal(threeHarmony[0].resultingElement, '수');
});

test('같은 관계를 순서만 바꿔 중복 반환하지 않는다', () => {
  const a = findBranchRelations([
    { pillar: 'year', branch: '자' },
    { pillar: 'month', branch: '축' },
  ]);
  const b = findBranchRelations([
    { pillar: 'month', branch: '축' },
    { pillar: 'year', branch: '자' },
  ]);
  assert.equal(a.length, 1);
  assert.equal(b.length, 1);
  assert.equal(a[0].type, b[0].type);
});

test('관계가 없으면 빈 배열을 반환한다', () => {
  assert.deepEqual(
    findBranchRelations([
      { pillar: 'year', branch: '자' },
      { pillar: 'month', branch: '인' },
    ]),
    [],
  );
});

test('불확실하거나 없는 기둥은 관계 계산에서 빠진다', () => {
  // 호출부가 null/누락 slot을 넘겨도 관계를 만들어내지 않는다.
  const relations = findBranchRelations([
    { pillar: 'day', branch: '자' },
    { pillar: 'month', branch: null },
    null,
    { pillar: 'hour', branch: '없음' },
  ]);
  assert.deepEqual(relations, []);
});

test('삼합은 세 지지가 모두 있어야 성립한다', () => {
  // 신·자만 있으면 반합인데, 이번 Phase에서는 다루지 않는다.
  const partial = findBranchRelations([
    { pillar: 'year', branch: '신' },
    { pillar: 'month', branch: '자' },
  ]);
  assert.equal(partial.filter((r) => r.type === 'threeHarmony').length, 0);
});

test('관계 결과에 좋음/나쁨 판정이 들어 있지 않다', () => {
  const relations = findBranchRelations([
    { pillar: 'year', branch: '자' },
    { pillar: 'month', branch: '축' },
    { pillar: 'day', branch: '오' },
  ]);
  const serialized = JSON.stringify(relations);
  for (const banned of ['good', 'bad', 'positive', 'negative', 'score', 'favorable']) {
    assert.ok(!serialized.includes(banned), `가치 판단 흔적: ${banned}`);
  }
});

test('교차 관계는 본인 원국 관계와 섞이지 않는다', () => {
  // 첫 번째 사람 안에서 자-축 합이 있어도, 교차 결과에는 나오지 않아야 한다.
  const cross = findCrossBranchRelations(
    [
      { pillar: 'year', branch: '자' },
      { pillar: 'month', branch: '축' },
    ],
    [{ pillar: 'day', branch: '오' }],
  );
  assert.equal(cross.length, 1);
  assert.equal(cross[0].type, 'sixClash');
  assert.equal(cross[0].firstBranch, '자');
  assert.equal(cross[0].secondBranch, '오');
  assert.equal(cross[0].firstPillar, 'year');
  assert.equal(cross[0].secondPillar, 'day');
});
