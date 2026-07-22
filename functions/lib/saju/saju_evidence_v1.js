'use strict';

/**
 * 개인 원국 evidence — Phase 5-3, evidenceVersion 1.
 *
 * `computeSajuChart` 결과만 입력으로 받는다. raw 생년월일·출생시각·UID는 받지도
 * 만들지도 않는다. AI는 여기서 나온 구조화된 근거만 해석하고, 십성·지장간·합충을
 * 직접 계산하지 않는다.
 *
 * 불확실성 전파 원칙:
 * - 출생시간 미상 → 시주 자체가 없으므로 시주 관련 근거를 만들지 않는다
 * - 절기 경계로 연주·월주가 timeDependent → 해당 기둥과 그 파생 근거를 제외한다
 * - 후보(candidates)를 넣어 "가능한 관계"를 실제 관계처럼 표시하지 않는다
 */

const {
  ELEMENT_KEYS,
  stemByKorean,
  branchByKorean,
  emptyElementCounts,
} = require('./saju_constants');
const { tenGodFor } = require('./ten_gods');
const { hiddenStemsFor } = require('./hidden_stems');
const { findBranchRelations } = require('./branch_relations');

/** evidence 계약 버전. 계산(3)·convention(2)과 별개로 관리한다. */
const SAJU_EVIDENCE_VERSION = 1;

/** 근거를 만들지 못한 이유 코드. AI와 화면이 같은 값을 본다. */
const OMITTED = Object.freeze({
  MISSING_HOUR_PILLAR: 'missingHourPillar',
  UNCERTAIN_YEAR_PILLAR: 'uncertainYearPillar',
  UNCERTAIN_MONTH_PILLAR: 'uncertainMonthPillar',
  UNCERTAIN_ELEMENT_BALANCE: 'uncertainElementBalance',
});

const PILLAR_ORDER = Object.freeze(['year', 'month', 'day', 'hour']);

/** 확정된 기둥만 골라 {name, pillar} 목록으로 만든다. */
function resolvedPillars(chart) {
  const { saju, boundaryStatus } = chart;
  const out = [];
  if (boundaryStatus.yearPillar === 'exact' && saju.yearPillar) {
    out.push({ name: 'year', pillar: saju.yearPillar });
  }
  if (boundaryStatus.monthPillar === 'exact' && saju.monthPillar) {
    out.push({ name: 'month', pillar: saju.monthPillar });
  }
  out.push({ name: 'day', pillar: saju.dayPillar });
  if (saju.hourPillar) out.push({ name: 'hour', pillar: saju.hourPillar });
  return out;
}

function describePillar(name, pillar, dayMaster) {
  const stem = stemByKorean(pillar.stem);
  const branch = branchByKorean(pillar.branch);
  return {
    position: name,
    korean: pillar.korean,
    stem: {
      korean: pillar.stem,
      element: stem ? stem.element : null,
      yinYang: stem ? stem.yinYang : null,
      // 일간 자신은 비견으로 나온다 — 기준점임을 그대로 드러낸다.
      tenGod: tenGodFor(dayMaster, pillar.stem),
    },
    branch: {
      korean: pillar.branch,
      element: branch ? branch.element : null,
      yinYang: branch ? branch.yinYang : null,
    },
  };
}

/**
 * 원국 evidence를 만든다.
 *
 * confidence:
 * - `full`    출생시간을 알고 절기 경계 ambiguity도 없음
 * - `partial` 시주가 없거나 연주·월주 중 하나라도 확정되지 않음
 */
function buildPersonalSajuEvidence(chart) {
  const { saju, boundaryStatus } = chart;
  const dayMaster = saju.dayMaster;
  const dayMasterStem = stemByKorean(dayMaster);

  const omittedEvidence = [];
  if (!saju.hourPillar) omittedEvidence.push(OMITTED.MISSING_HOUR_PILLAR);
  if (boundaryStatus.yearPillar === 'timeDependent') {
    omittedEvidence.push(OMITTED.UNCERTAIN_YEAR_PILLAR);
  }
  if (boundaryStatus.monthPillar === 'timeDependent') {
    omittedEvidence.push(OMITTED.UNCERTAIN_MONTH_PILLAR);
  }
  if (saju.fiveElementBalance === null) {
    omittedEvidence.push(OMITTED.UNCERTAIN_ELEMENT_BALANCE);
  }

  const resolved = resolvedPillars(chart);
  const resolvedByName = Object.fromEntries(resolved.map((r) => [r.name, r.pillar]));

  const pillars = {};
  for (const name of PILLAR_ORDER) {
    const pillar = resolvedByName[name];
    pillars[name] = pillar ? describePillar(name, pillar, dayMaster) : null;
  }

  // 드러난 천간(투간)의 십성. 확정된 기둥만 센다.
  const visibleTenGods = resolved
    .map(({ name, pillar }) => {
      const tenGod = tenGodFor(dayMaster, pillar.stem);
      return tenGod ? { position: name, ...tenGod } : null;
    })
    .filter(Boolean);

  // 지장간. 확정된 지지에서만 뽑는다.
  const hiddenStems = resolved
    .map(({ name, pillar }) => {
      const hidden = hiddenStemsFor(pillar.branch, dayMaster);
      return hidden ? { position: name, ...hidden } : null;
    })
    .filter(Boolean);

  // 음양 — 드러난 글자(천간+지지)만 센다.
  const yinYangVisible = { yin: 0, yang: 0, total: 0 };
  for (const { pillar } of resolved) {
    for (const korean of [pillar.stem, pillar.branch]) {
      const item = stemByKorean(korean) || branchByKorean(korean);
      if (!item) continue;
      yinYangVisible[item.yinYang] += 1;
      yinYangVisible.total += 1;
    }
  }

  // 오행 presence. surface와 hidden을 **합치지 않는다**.
  // 퍼센트로 정규화하지 않고, 많고 적음으로 용신을 판정하지도 않는다.
  const surface = emptyElementCounts();
  for (const { pillar } of resolved) {
    surface[pillar.stemElement] += 1;
    surface[pillar.branchElement] += 1;
  }
  const hidden = emptyElementCounts();
  for (const entry of hiddenStems) {
    for (const item of entry.stems) {
      const stem = stemByKorean(item.stem);
      if (stem) hidden[stem.element] += 1;
    }
  }

  const branchRelations = findBranchRelations(
    resolved.map(({ name, pillar }) => ({ pillar: name, branch: pillar.branch })),
  );

  const boundaryUncertainty = {
    yearPillar: boundaryStatus.yearPillar === 'timeDependent',
    monthPillar: boundaryStatus.monthPillar === 'timeDependent',
  };

  const confidence =
    chart.precision === 'dateAndTime' &&
    !boundaryUncertainty.yearPillar &&
    !boundaryUncertainty.monthPillar
      ? 'full'
      : 'partial';

  return {
    evidenceVersion: SAJU_EVIDENCE_VERSION,
    precision: chart.precision,
    confidence,
    boundaryUncertainty,
    dayMaster: {
      stem: dayMaster,
      element: dayMasterStem ? dayMasterStem.element : null,
      yinYang: dayMasterStem ? dayMasterStem.yinYang : null,
    },
    pillars,
    visibleTenGods,
    hiddenStems,
    yinYangBalance: { visible: yinYangVisible },
    elementPresence: {
      surface: { ...surface, total: sumCounts(surface) },
      hidden: { ...hidden, total: sumCounts(hidden) },
    },
    branchRelations,
    omittedEvidence,
  };
}

function sumCounts(counts) {
  return ELEMENT_KEYS.reduce((total, key) => total + counts[key], 0);
}

/** 궁합 계산에 쓸 확정 지지 slot 목록. */
function resolvedBranchSlots(chart) {
  return resolvedPillars(chart).map(({ name, pillar }) => ({
    pillar: name,
    branch: pillar.branch,
  }));
}

module.exports = {
  SAJU_EVIDENCE_VERSION,
  OMITTED,
  PILLAR_ORDER,
  buildPersonalSajuEvidence,
  resolvedBranchSlots,
};
