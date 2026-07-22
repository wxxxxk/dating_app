'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const { computeSajuChart } = require('../lib/saju/saju_engine_v2');
const {
  SAJU_EVIDENCE_VERSION,
  OMITTED,
  buildPersonalSajuEvidence,
  resolvedBranchSlots,
} = require('../lib/saju/saju_evidence_v1');
const {
  SUPPORT_CODES,
  TENSION_CODES,
  buildCompatibilityEvidence,
} = require('../lib/saju/compatibility_evidence_v1');

const personalFixture = require('./fixtures/saju_evidence_v1.json');
const compatFixture = require('./fixtures/compatibility_evidence_v1.json');

// Phase 5-3 — evidence 계약.
//
// 명리 규칙 자체는 saju_ten_gods.test.js가 전수 검증한다. 여기서는 계약 구조,
// 불확실성 전파, A/B 순서 안정성, 개인정보 경계를 확인한다.
// 모든 입력은 합성 날짜다.

function chartOf(input) {
  return computeSajuChart({
    year: input.year,
    month: input.month,
    day: input.day,
    birthTimeKnown: input.birthTimeKnown,
    birthTimeMinutes: input.birthTimeMinutes,
  });
}

function evidenceOf(input) {
  return buildPersonalSajuEvidence(chartOf(input));
}

function compatOf(firstInput, secondInput) {
  const firstChart = chartOf(firstInput);
  const secondChart = chartOf(secondInput);
  return buildCompatibilityEvidence({
    firstChart,
    secondChart,
    firstPersonalEvidence: buildPersonalSajuEvidence(firstChart),
    secondPersonalEvidence: buildPersonalSajuEvidence(secondChart),
  });
}

// ── fixture 계약 ─────────────────────────────────────────────────────────

test('개인 fixture가 요구 범위를 덮는다', () => {
  const cases = personalFixture.cases;
  assert.ok(cases.length >= 30, `${cases.length}건뿐이다`);
  assert.equal(personalFixture.evidenceVersion, SAJU_EVIDENCE_VERSION);

  // 일간 10개 전부.
  const dayMasters = new Set(cases.map((c) => c.expected.dayMaster.stem));
  assert.equal(dayMasters.size, 10, `일간 ${dayMasters.size}종`);

  // 지지 12개 지장간 전부.
  const branches = new Set();
  for (const c of cases) {
    for (const h of c.expected.hiddenStems) branches.add(h.branch);
  }
  assert.equal(branches.size, 12, `지지 ${branches.size}종`);

  // 관계 3종과 무관계, known/unknown, boundary 사례.
  const types = new Set();
  for (const c of cases) {
    for (const r of c.expected.branchRelations) types.add(r.type);
  }
  for (const needed of ['sixHarmony', 'sixClash', 'threeHarmony']) {
    assert.ok(types.has(needed), `${needed} 사례가 없다`);
  }
  assert.ok(cases.some((c) => c.expected.branchRelations.length === 0));
  assert.ok(cases.some((c) => c.input.birthTimeKnown));
  assert.ok(cases.some((c) => !c.input.birthTimeKnown));
  assert.ok(
    cases.some((c) =>
      c.expected.omittedEvidence.includes(OMITTED.UNCERTAIN_YEAR_PILLAR) ||
      c.expected.omittedEvidence.includes(OMITTED.UNCERTAIN_MONTH_PILLAR),
    ),
    '절기 경계 사례가 없다',
  );
});

test('개인 fixture에 자연어 성격 결과가 없다', () => {
  const serialized = JSON.stringify(personalFixture.cases);
  for (const banned of ['성격', '점수', 'score', 'percent', '%']) {
    assert.ok(!serialized.includes(banned), `금지 표현: ${banned}`);
  }
});

test('개인 fixture 기대값이 현재 엔진과 일치한다', () => {
  const mismatches = [];
  for (const c of personalFixture.cases) {
    const ev = evidenceOf(c.input);
    const actual = {
      confidence: ev.confidence,
      precision: ev.precision,
      dayMaster: ev.dayMaster,
      omittedEvidence: ev.omittedEvidence,
      visibleTenGods: ev.visibleTenGods.map((t) => ({
        position: t.position,
        stem: t.stem,
        key: t.key,
      })),
      hiddenStems: ev.hiddenStems.map((h) => ({
        position: h.position,
        branch: h.branch,
        stems: h.stems.map((s) => ({
          stem: s.stem,
          position: s.position,
          tenGod: s.tenGod.key,
        })),
      })),
      yinYangVisible: ev.yinYangBalance.visible,
      elementPresence: ev.elementPresence,
      branchRelations: ev.branchRelations,
    };
    if (JSON.stringify(actual) !== JSON.stringify(c.expected)) {
      // 어떤 field가 어긋났는지만 남긴다.
      for (const key of Object.keys(c.expected)) {
        if (JSON.stringify(actual[key]) !== JSON.stringify(c.expected[key])) {
          mismatches.push(`case=${c.id} field=${key}`);
        }
      }
    }
  }
  assert.equal(mismatches.length, 0, mismatches.join('\n'));
});

test('궁합 fixture가 요구 범위를 덮는다', () => {
  const cases = compatFixture.cases;
  assert.ok(cases.length >= 30, `${cases.length}쌍뿐이다`);

  const summaries = new Set(cases.map((c) => c.expected.dayMasterInteraction.summary));
  for (const needed of [
    'sameElement',
    'firstGeneratesSecond',
    'secondGeneratesFirst',
    'firstControlsSecond',
    'secondControlsFirst',
  ]) {
    assert.ok(summaries.has(needed), `${needed} 사례가 없다`);
  }

  const allSupports = new Set(cases.flatMap((c) => c.expected.supports));
  const allTensions = new Set(cases.flatMap((c) => c.expected.tensions));
  assert.ok(allSupports.has(SUPPORT_CODES.CROSS_SIX_HARMONY));
  assert.ok(allTensions.has(TENSION_CODES.CROSS_SIX_CLASH));
  // 합과 충이 동시에 존재하는 사례.
  assert.ok(
    cases.some(
      (c) =>
        c.expected.supports.includes(SUPPORT_CODES.CROSS_SIX_HARMONY) &&
        c.expected.tensions.includes(TENSION_CODES.CROSS_SIX_CLASH),
    ),
  );
  // 음양 동일/상이 둘 다.
  assert.ok(cases.some((c) => c.expected.dayMasterInteraction.sameYinYang));
  assert.ok(cases.some((c) => !c.expected.dayMasterInteraction.sameYinYang));
  // dateOnly 한 명 / 두 명.
  assert.ok(cases.some((c) => c.first.birthTimeKnown !== c.second.birthTimeKnown));
  assert.ok(cases.some((c) => !c.first.birthTimeKnown && !c.second.birthTimeKnown));
  assert.ok(cases.some((c) => c.expected.confidence === 'partial'));
});

test('궁합 fixture 기대값이 현재 엔진과 일치한다', () => {
  const mismatches = [];
  for (const c of compatFixture.cases) {
    const comp = compatOf(c.first, c.second);
    const actual = {
      confidence: comp.confidence,
      dayMasterInteraction: {
        summary: comp.dayMasterInteraction.summary,
        sameElement: comp.dayMasterInteraction.sameElement,
        sameYinYang: comp.dayMasterInteraction.sameYinYang,
        firstToSecond: comp.dayMasterInteraction.firstToSecond.relation,
        secondToFirst: comp.dayMasterInteraction.secondToFirst.relation,
      },
      crossBranchRelations: comp.crossBranchRelations,
      sharedElements: comp.sharedElements,
      complementaryElements: comp.complementaryElements,
      supports: comp.supports,
      tensions: comp.tensions,
      omittedEvidence: comp.omittedEvidence,
    };
    for (const key of Object.keys(c.expected)) {
      if (JSON.stringify(actual[key]) !== JSON.stringify(c.expected[key])) {
        mismatches.push(`case=${c.id} field=${key}`);
      }
    }
  }
  assert.equal(mismatches.length, 0, mismatches.join('\n'));
});

test('fixture provenance가 회귀 baseline임을 밝힌다', () => {
  for (const fixture of [personalFixture, compatFixture]) {
    assert.equal(fixture.metadata.provenanceLevel, 'regression-baseline');
    assert.ok(fixture.metadata.conventionSource.includes('자평명리'));
    assert.ok(fixture.metadata.retrievedAt);
  }
  // 절기 fixture와 출처를 혼동하지 않는다.
  assert.ok(personalFixture.metadata.provenanceNote.includes('한국천문연구원'));
});

// ── 개인 evidence 구조 ───────────────────────────────────────────────────

const KNOWN_TIME = {
  year: 1995, month: 6, day: 15, birthTimeKnown: true, birthTimeMinutes: 455,
};
const UNKNOWN_TIME = {
  year: 1995, month: 6, day: 15, birthTimeKnown: false, birthTimeMinutes: null,
};
// 1995 입춘은 2/4 16:13 KST — 시각 미상이면 연주·월주가 갈린다.
const BOUNDARY_DATE = {
  year: 1995, month: 2, day: 4, birthTimeKnown: false, birthTimeMinutes: null,
};

test('출생시간을 알고 경계도 없으면 confidence는 full이다', () => {
  const ev = evidenceOf(KNOWN_TIME);
  assert.equal(ev.confidence, 'full');
  assert.deepEqual(ev.omittedEvidence, []);
  assert.ok(ev.pillars.year && ev.pillars.month && ev.pillars.day && ev.pillars.hour);
  assert.equal(ev.visibleTenGods.length, 4);
  assert.equal(ev.hiddenStems.length, 4);
  assert.equal(ev.yinYangBalance.visible.total, 8);
  assert.equal(ev.elementPresence.surface.total, 8);
});

test('출생시간 미상이면 시주 관련 근거가 통째로 빠진다', () => {
  const ev = evidenceOf(UNKNOWN_TIME);
  assert.equal(ev.confidence, 'partial');
  assert.ok(ev.omittedEvidence.includes(OMITTED.MISSING_HOUR_PILLAR));
  assert.equal(ev.pillars.hour, null);
  assert.equal(ev.visibleTenGods.filter((t) => t.position === 'hour').length, 0);
  assert.equal(ev.hiddenStems.filter((h) => h.position === 'hour').length, 0);
  assert.equal(ev.yinYangBalance.visible.total, 6);
  assert.equal(ev.elementPresence.surface.total, 6);
  // 시주가 들어간 관계도 없어야 한다.
  for (const relation of ev.branchRelations) {
    assert.ok(!relation.pillars.includes('hour'));
  }
});

test('절기 경계에 걸리면 해당 기둥과 파생 근거가 빠진다', () => {
  const ev = evidenceOf(BOUNDARY_DATE);
  assert.equal(ev.confidence, 'partial');
  assert.ok(ev.omittedEvidence.includes(OMITTED.UNCERTAIN_YEAR_PILLAR));
  assert.ok(ev.omittedEvidence.includes(OMITTED.UNCERTAIN_MONTH_PILLAR));
  assert.ok(ev.omittedEvidence.includes(OMITTED.UNCERTAIN_ELEMENT_BALANCE));
  assert.equal(ev.pillars.year, null);
  assert.equal(ev.pillars.month, null);
  // 일주는 확정이므로 남는다.
  assert.ok(ev.pillars.day);
  assert.equal(ev.visibleTenGods.length, 1);
  assert.equal(ev.visibleTenGods[0].position, 'day');
  assert.equal(ev.hiddenStems.length, 1);
  assert.equal(ev.hiddenStems[0].position, 'day');
  assert.deepEqual(ev.branchRelations, []);
  assert.equal(ev.elementPresence.surface.total, 2);
});

test('후보 pillar가 evidence에 새어나가지 않는다', () => {
  const serialized = JSON.stringify(evidenceOf(BOUNDARY_DATE));
  assert.ok(!serialized.includes('Candidates'));
  const chart = chartOf(BOUNDARY_DATE);
  // 엔진에는 후보가 2개 있지만 evidence에는 그 값이 등장하지 않는다.
  assert.equal(chart.saju.yearPillarCandidates.length, 2);
  for (const candidate of chart.saju.yearPillarCandidates) {
    assert.ok(!serialized.includes(candidate.korean), candidate.korean);
  }
});

test('오행은 surface와 hidden을 분리하고 퍼센트를 만들지 않는다', () => {
  const ev = evidenceOf(KNOWN_TIME);
  assert.ok(ev.elementPresence.surface);
  assert.ok(ev.elementPresence.hidden);
  // 모든 count는 정수다 — 정규화된 비율이 아니다.
  for (const scope of ['surface', 'hidden']) {
    for (const [key, value] of Object.entries(ev.elementPresence[scope])) {
      assert.ok(Number.isInteger(value), `${scope}.${key}=${value}`);
    }
  }
  const serialized = JSON.stringify(ev.elementPresence);
  assert.ok(!serialized.includes('.'), '소수(비율)가 들어 있다');
  assert.ok(!serialized.includes('percent'));
  // surface와 hidden을 합친 필드를 만들지 않았다.
  assert.ok(!('combined' in ev.elementPresence));
  assert.ok(!('total' in ev.elementPresence));
});

test('용신·강약 판정을 하지 않는다', () => {
  const serialized = JSON.stringify(evidenceOf(KNOWN_TIME));
  for (const banned of ['yongsin', 'useGod', 'strength', 'strong', 'weak', '용신']) {
    assert.ok(!serialized.includes(banned), `판정 흔적: ${banned}`);
  }
});

test('evidence에 raw 생년월일·시각이 없다', () => {
  const serialized = JSON.stringify(evidenceOf(KNOWN_TIME));
  assert.ok(!serialized.includes('1995'));
  assert.ok(!serialized.includes('455'));
  for (const banned of ['birthDate', 'birthTimeMinutes', 'timeZone', 'uid', 'fingerprint']) {
    assert.ok(!serialized.includes(banned), `개인정보 흔적: ${banned}`);
  }
});

test('resolvedBranchSlots는 확정된 기둥만 돌려준다', () => {
  assert.equal(resolvedBranchSlots(chartOf(KNOWN_TIME)).length, 4);
  assert.equal(resolvedBranchSlots(chartOf(UNKNOWN_TIME)).length, 3);
  assert.equal(resolvedBranchSlots(chartOf(BOUNDARY_DATE)).length, 1);
});

// ── 궁합 evidence ────────────────────────────────────────────────────────

/** 특정 일간을 갖는 합성 날짜를 찾는다. */
function dateWithDayMaster(stem, { known = true } = {}) {
  for (let offset = 0; offset < 60; offset += 1) {
    const d = new Date(Date.UTC(1995, 5, 1 + offset));
    const input = {
      year: d.getUTCFullYear(),
      month: d.getUTCMonth() + 1,
      day: d.getUTCDate(),
      birthTimeKnown: known,
      birthTimeMinutes: known ? 600 : null,
    };
    if (chartOf(input).saju.dayMaster === stem) return input;
  }
  throw new Error(`일간 ${stem} 날짜를 찾지 못했다`);
}

test('일간 상호작용 — 같은 오행·음양 조합', () => {
  const same = compatOf(dateWithDayMaster('갑'), dateWithDayMaster('갑'));
  assert.equal(same.dayMasterInteraction.summary, 'sameElement');
  assert.equal(same.dayMasterInteraction.sameElement, true);
  assert.equal(same.dayMasterInteraction.sameYinYang, true);
  assert.ok(same.supports.includes(SUPPORT_CODES.DAY_MASTER_SAME_ELEMENT));
  assert.ok(!same.tensions.includes(TENSION_CODES.CONTRASTING_YIN_YANG));

  // 갑(목양) × 을(목음) — 같은 오행, 다른 음양.
  const diffYinYang = compatOf(dateWithDayMaster('갑'), dateWithDayMaster('을'));
  assert.equal(diffYinYang.dayMasterInteraction.sameElement, true);
  assert.equal(diffYinYang.dayMasterInteraction.sameYinYang, false);
  assert.ok(diffYinYang.tensions.includes(TENSION_CODES.CONTRASTING_YIN_YANG));
});

test('일간 상호작용 — 생·극 방향이 양방향으로 구분된다', () => {
  // 갑(목) → 병(화): 목생화.
  const generates = compatOf(dateWithDayMaster('갑'), dateWithDayMaster('병'));
  assert.equal(generates.dayMasterInteraction.summary, 'firstGeneratesSecond');
  assert.equal(generates.dayMasterInteraction.firstToSecond.relation, 'generates');
  assert.equal(generates.dayMasterInteraction.secondToFirst.relation, 'generatedBy');
  assert.ok(generates.supports.includes(SUPPORT_CODES.FIRST_GENERATES_SECOND));

  // 반대 방향.
  const generatedBy = compatOf(dateWithDayMaster('병'), dateWithDayMaster('갑'));
  assert.equal(generatedBy.dayMasterInteraction.summary, 'secondGeneratesFirst');
  assert.ok(generatedBy.supports.includes(SUPPORT_CODES.SECOND_GENERATES_FIRST));

  // 갑(목) → 무(토): 목극토.
  const controls = compatOf(dateWithDayMaster('갑'), dateWithDayMaster('무'));
  assert.equal(controls.dayMasterInteraction.summary, 'firstControlsSecond');
  assert.ok(controls.tensions.includes(TENSION_CODES.FIRST_CONTROLS_SECOND));

  const controlledBy = compatOf(dateWithDayMaster('무'), dateWithDayMaster('갑'));
  assert.equal(controlledBy.dayMasterInteraction.summary, 'secondControlsFirst');
  assert.ok(controlledBy.tensions.includes(TENSION_CODES.SECOND_CONTROLS_FIRST));
});

test('A/B 순서를 바꿔도 대칭 필드는 같고 방향 필드는 반전된다', () => {
  const mismatches = [];
  for (const c of compatFixture.cases) {
    const ab = compatOf(c.first, c.second);
    const ba = compatOf(c.second, c.first);

    // 대칭.
    if (ab.dayMasterInteraction.sameElement !== ba.dayMasterInteraction.sameElement) {
      mismatches.push(`case=${c.id} field=sameElement`);
    }
    if (ab.dayMasterInteraction.sameYinYang !== ba.dayMasterInteraction.sameYinYang) {
      mismatches.push(`case=${c.id} field=sameYinYang`);
    }
    if (ab.confidence !== ba.confidence) {
      mismatches.push(`case=${c.id} field=confidence`);
    }
    if (JSON.stringify(ab.sharedElements) !== JSON.stringify(ba.sharedElements)) {
      mismatches.push(`case=${c.id} field=sharedElements`);
    }
    if (JSON.stringify(ab.omittedEvidence) !== JSON.stringify(ba.omittedEvidence)) {
      mismatches.push(`case=${c.id} field=omittedEvidence`);
    }
    // 교차 관계 집합은 방향만 바뀌고 구성은 같아야 한다.
    const key = (r, swapped) =>
      swapped
        ? `${r.type}:${r.secondPillar}:${r.secondBranch}:${r.firstPillar}:${r.firstBranch}`
        : `${r.type}:${r.firstPillar}:${r.firstBranch}:${r.secondPillar}:${r.secondBranch}`;
    const abSet = new Set(ab.crossBranchRelations.map((r) => key(r, false)));
    const baSet = new Set(ba.crossBranchRelations.map((r) => key(r, true)));
    if (
      abSet.size !== baSet.size ||
      [...abSet].some((k) => !baSet.has(k))
    ) {
      mismatches.push(`case=${c.id} field=crossBranchRelations`);
    }

    // 방향 — 정확히 반전.
    if (
      ab.dayMasterInteraction.firstToSecond.relation !==
      ba.dayMasterInteraction.secondToFirst.relation
    ) {
      mismatches.push(`case=${c.id} field=directionalRelation`);
    }
    if (
      JSON.stringify(ab.complementaryElements.onlyInFirst) !==
      JSON.stringify(ba.complementaryElements.onlyInSecond)
    ) {
      mismatches.push(`case=${c.id} field=complementaryElements`);
    }
    // 방향 code도 반전된다.
    const flip = {
      firstGeneratesSecond: 'secondGeneratesFirst',
      secondGeneratesFirst: 'firstGeneratesSecond',
      firstControlsSecond: 'secondControlsFirst',
      secondControlsFirst: 'firstControlsSecond',
    };
    const abCodes = [...ab.supports, ...ab.tensions].map((c2) => flip[c2] || c2).sort();
    const baCodes = [...ba.supports, ...ba.tensions].sort();
    if (JSON.stringify(abCodes) !== JSON.stringify(baCodes)) {
      mismatches.push(`case=${c.id} field=supportsTensions`);
    }
  }
  assert.equal(mismatches.length, 0, mismatches.join('\n'));
});

test('교차 관계는 확정된 기둥에서만 나온다', () => {
  const comp = compatOf(BOUNDARY_DATE, KNOWN_TIME);
  // 경계일 쪽은 일주만 확정이므로 교차 관계의 firstPillar는 day뿐이다.
  for (const relation of comp.crossBranchRelations) {
    assert.equal(relation.firstPillar, 'day');
  }
  assert.equal(comp.confidence, 'partial');
  assert.ok(comp.omittedEvidence.includes(OMITTED.UNCERTAIN_YEAR_PILLAR));
});

test('한쪽이라도 partial이면 궁합 confidence도 partial이다', () => {
  assert.equal(compatOf(KNOWN_TIME, KNOWN_TIME).confidence, 'full');
  assert.equal(compatOf(KNOWN_TIME, UNKNOWN_TIME).confidence, 'partial');
  assert.equal(compatOf(UNKNOWN_TIME, UNKNOWN_TIME).confidence, 'partial');
});

test('궁합 evidence에 점수·퍼센트·자연어 판정이 없다', () => {
  const serialized = JSON.stringify(compatOf(KNOWN_TIME, UNKNOWN_TIME));
  for (const banned of [
    'score', 'point', 'percent', 'rating', 'rank', 'good', 'bad', '점수', '궁합도',
  ]) {
    assert.ok(!serialized.includes(banned), `금지 표현: ${banned}`);
  }
  // 숫자 자체가 거의 없어야 한다 — count조차 궁합 evidence에는 담지 않는다.
  assert.ok(!/\d+\.\d+/.test(serialized), '비율이 들어 있다');
});

test('궁합 evidence에 raw 생년월일·시각·UID가 없다', () => {
  const serialized = JSON.stringify(compatOf(KNOWN_TIME, UNKNOWN_TIME));
  assert.ok(!serialized.includes('1995'));
  assert.ok(!serialized.includes('455'));
  for (const banned of ['birthDate', 'birthTimeMinutes', 'uid', 'fingerprint', 'Timestamp']) {
    assert.ok(!serialized.includes(banned), `개인정보 흔적: ${banned}`);
  }
});

test('supports·tensions는 고정된 code만 쓴다', () => {
  const allowedSupports = new Set(Object.values(SUPPORT_CODES));
  const allowedTensions = new Set(Object.values(TENSION_CODES));
  for (const c of compatFixture.cases) {
    for (const code of c.expected.supports) {
      assert.ok(allowedSupports.has(code), `${c.id} 알 수 없는 support=${code}`);
    }
    for (const code of c.expected.tensions) {
      assert.ok(allowedTensions.has(code), `${c.id} 알 수 없는 tension=${code}`);
    }
  }
});

test('supports 개수가 많다고 좋은 궁합으로 표시되지 않는다', () => {
  // 엔진 결과 어디에도 종합 판정 필드가 없어야 한다.
  const comp = compatOf(KNOWN_TIME, UNKNOWN_TIME);
  for (const banned of ['verdict', 'overall', 'summaryText', 'level', 'grade']) {
    assert.ok(!(banned in comp), `종합 판정 필드: ${banned}`);
  }
});
