'use strict';

/**
 * Evidence catalog와 grounding 검증 — Phase 5-4 (Stage A 보정 1회차).
 *
 * 목적: 모델이 쓴 **각 문장**이 실제로 계산된 근거를 쓴 것인지 확인한다.
 *
 * v1(1차 평가)은 섹션 단위 `groundingRefs`만 받았다. 섹션이 [P03, P07]을
 * 인용했다고 해도 그 안의 어느 문장이 어느 근거에서 나왔는지 알 수 없어서,
 * 사실상 검증이 불가능했다 — 모델은 그럴듯한 id를 적고 본문은 자유롭게 썼다.
 * 그래서 claim 단위로 바꾼다: 문장마다 자기 근거를 들고 온다.
 *
 * 원칙:
 * - catalog는 결정론적 evidence에서만 만든다
 * - 후보(candidate) 기둥, omittedEvidence 항목은 catalog에 넣지 않는다
 * - 내부 코드명(sikSin, crossSixClash)을 그대로 노출하지 않는다.
 *   서버가 한국어 의미로 바꿔서 넘긴다(narrative_vocabulary.js)
 * - 모델이 임의 id를 만들면 응답을 거부한다
 * - 검증이 끝나면 claim 구조와 groundingRefs는 공개 payload에서 제거한다
 *   (Firestore client-readable 캐시에도 저장하지 않는다)
 * - catalog 설명에는 raw 생년월일·출생시각·UID가 들어가지 않는다
 */

const {
  GROUNDED_PERSONAL_KEYS,
  GROUNDED_COMPATIBILITY_KEYS,
} = require('./narrative_schema_v3');
const { TEN_GOD_LABELS } = require('./ten_gods');
const {
  DOMAINS,
  TEN_GOD_MEANINGS,
  BRANCH_RELATION_MEANINGS,
  INTERACTION_MEANINGS,
  meaningFor,
} = require('./narrative_vocabulary');

/** 개인 catalog id prefix. */
const PERSONAL_REF_PREFIX = 'P';
/** 궁합 catalog id prefix. */
const COMPATIBILITY_REF_PREFIX = 'C';

/** 서로 다른 evidence를 최소 몇 개 써야 하는지(한 근거로 전 섹션 도배 방지). */
const MIN_DISTINCT_REFS = 3;

/**
 * 한 근거가 최대 몇 개 섹션에 쓰일 수 있는지.
 *
 * 1차 평가에서 distinctiveness가 낮았던 이유 중 하나가, 지배적인 근거 하나가
 * 전 섹션에 반복 인용되면서 모든 섹션이 같은 일반론으로 수렴한 것이다.
 */
const MAX_SECTIONS_PER_REF = 3;

/** confidence 항목은 관찰 근거가 아니다 — 이것만으로 관찰 claim을 쓸 수 없다. */
const META_KINDS = Object.freeze(new Set(['confidence']));

const POSITION_LABELS = Object.freeze({
  year: '연주',
  month: '월주',
  day: '일주',
  hour: '시주',
});

function refId(prefix, index) {
  return `${prefix}${String(index).padStart(2, '0')}`;
}

function positionLabel(position) {
  return POSITION_LABELS[position] || position;
}

/**
 * 개인 원국 evidence → catalog.
 *
 * `buildPersonalSajuEvidence()` 결과만 읽는다. 확정된 기둥에서 파생된 항목만
 * 들어가므로, 시주가 없거나 절기 경계로 확정하지 못한 기둥은 자연히 빠진다.
 */
function buildPersonalEvidenceCatalog(evidence) {
  const catalog = [];
  const push = (kind, description, domains, extra = {}) => {
    catalog.push({
      id: refId(PERSONAL_REF_PREFIX, catalog.length + 1),
      kind,
      description,
      domains,
      ...extra,
    });
  };

  push(
    'dayMaster',
    `타고난 기본 결은 ${evidence.dayMaster.element} 기운이고, 표현 방향은 ${
      evidence.dayMaster.yinYang === 'yang' ? '밖으로 향하는 편' : '안으로 향하는 편'
    }`,
    [DOMAINS.TEMPERAMENT, DOMAINS.PACE],
  );

  for (const tenGod of evidence.visibleTenGods || []) {
    const info = meaningFor(TEN_GOD_MEANINGS, tenGod.key, [DOMAINS.TEMPERAMENT]);
    // 뜻을 모르는 코드는 근거로 내보내지 않는다. 모델이 추측하게 두지 않는다.
    if (!info.meaning) continue;
    push(
      'visibleTenGod',
      `겉으로 드러나는 결(${positionLabel(tenGod.position)}): ${info.meaning}`,
      info.domains,
    );
  }

  for (const hidden of evidence.hiddenStems || []) {
    // v1 버그: `${s.tenGod}`가 객체여서 `[object Object]`가 들어갔다.
    // tenGod는 {key, label, ...} 객체이므로 key로 의미를 찾는다.
    const meanings = [];
    for (const stem of hidden.stems || []) {
      const key = stem?.tenGod?.key;
      const info = key ? TEN_GOD_MEANINGS[key] : null;
      if (info?.meaning) meanings.push(info.meaning);
    }
    if (meanings.length === 0) continue;
    const domains = new Set();
    for (const stem of hidden.stems || []) {
      const key = stem?.tenGod?.key;
      for (const d of TEN_GOD_MEANINGS[key]?.domains || []) domains.add(d);
    }
    push(
      'hiddenStem',
      `겉으로 잘 드러나지 않는 안쪽 결(${positionLabel(hidden.position)}): ${meanings.join(' / ')}`,
      [...domains],
    );
  }

  const yinYang = evidence.yinYangBalance?.visible;
  if (yinYang && yinYang.total > 0) {
    const leaning =
      yinYang.yang > yinYang.yin
        ? '드러내는 쪽이 우세'
        : yinYang.yin > yinYang.yang
          ? '안에서 정리하는 쪽이 우세'
          : '드러내는 쪽과 정리하는 쪽이 비슷';
    push('yinYangBalance', `표현 방향의 균형: ${leaning}`, [
      DOMAINS.EXPRESSION,
      DOMAINS.PACE,
    ]);
  }

  const surface = evidence.elementPresence?.surface;
  if (surface && surface.total > 0) {
    push(
      'elementPresenceSurface',
      `겉으로 쓰는 기운의 폭: ${diversityText(surface)}`,
      [DOMAINS.TEMPERAMENT, DOMAINS.ATTRACTION],
    );
  }
  const hiddenPresence = evidence.elementPresence?.hidden;
  if (hiddenPresence && hiddenPresence.total > 0) {
    push(
      'elementPresenceHidden',
      `안쪽에 쌓아둔 기운의 폭: ${diversityText(hiddenPresence)}`,
      [DOMAINS.NEED, DOMAINS.TEMPERAMENT],
    );
  }

  for (const relation of evidence.branchRelations || []) {
    const info = meaningFor(BRANCH_RELATION_MEANINGS, relation.type, [
      DOMAINS.INTERACTION,
    ]);
    if (!info.meaning) continue;
    push('branchRelation', `내 안에서 ${info.meaning}`, info.domains);
  }

  push(
    'confidence',
    evidence.confidence === 'full'
      ? '출생시간과 절기 경계가 모두 확정되어 있어 말할 수 있는 범위가 넓음'
      : '출생시간 미상 또는 절기 경계로 일부가 확정되지 않아 말할 수 있는 범위가 좁음',
    [DOMAINS.META],
  );

  return catalog;
}

/** 오행 분포 → 편중/고른 정도. 숫자 나열 대신 해석 가능한 문장으로 준다. */
function diversityText(counts) {
  const keys = Object.keys(counts).filter((key) => key !== 'total');
  const present = keys.filter((key) => counts[key] > 0);
  const missing = keys.filter((key) => counts[key] === 0);
  if (missing.length === 0) return '다섯 기운이 고루 있음';
  if (present.length <= 2) return `${present.join('·')} 쪽으로 크게 치우쳐 있음`;
  return `${present.join('·')} 위주이고 ${missing.join('·')} 쪽은 비어 있음`;
}

/**
 * 궁합 evidence → catalog.
 *
 * 이름·UID 대신 "첫 번째 사람"/"두 번째 사람"으로만 표현한다.
 */
function buildCompatibilityEvidenceCatalog(evidence) {
  const catalog = [];
  const push = (kind, description, domains) => {
    catalog.push({
      id: refId(COMPATIBILITY_REF_PREFIX, catalog.length + 1),
      kind,
      description,
      domains,
    });
  };

  const interaction = evidence.dayMasterInteraction;
  const summaryInfo = meaningFor(INTERACTION_MEANINGS, interaction.summary, [
    DOMAINS.INTERACTION,
  ]);
  if (summaryInfo.meaning) {
    push('dayMasterInteraction', `두 사람의 기본 결 사이에서 ${summaryInfo.meaning}`, summaryInfo.domains);
  }
  push(
    'dayMasterYinYang',
    interaction.sameYinYang
      ? '두 사람이 감정을 밖으로 꺼내는 속도가 비슷함'
      : '두 사람이 감정을 밖으로 꺼내는 속도가 서로 다름',
    [DOMAINS.EXPRESSION, DOMAINS.PACE],
  );

  for (const support of evidence.supports || []) {
    const info = meaningFor(INTERACTION_MEANINGS, support, [DOMAINS.ATTRACTION]);
    if (!info.meaning) continue;
    push('support', `가까워지는 쪽으로 작용: ${info.meaning}`, info.domains);
  }
  for (const tension of evidence.tensions || []) {
    const info = meaningFor(INTERACTION_MEANINGS, tension, [DOMAINS.CONFLICT]);
    if (!info.meaning) continue;
    push('tension', `반응 차이가 드러나는 쪽으로 작용: ${info.meaning}`, info.domains);
  }

  for (const relation of evidence.crossBranchRelations || []) {
    const info = meaningFor(BRANCH_RELATION_MEANINGS, relation.type, [
      DOMAINS.INTERACTION,
    ]);
    if (!info.meaning) continue;
    push('crossBranchRelation', `두 사람 사이에서 ${info.meaning}`, info.domains);
  }

  if ((evidence.sharedElements || []).length > 0) {
    push(
      'sharedElements',
      `두 사람이 공통으로 지닌 기운이 ${evidence.sharedElements.length}가지 있어 겹치는 기반이 있음`,
      [DOMAINS.INTERACTION, DOMAINS.EXPRESSION],
    );
  }
  const complementary = evidence.complementaryElements;
  if (complementary && (complementary.onlyInFirst.length || complementary.onlyInSecond.length)) {
    const parts = [];
    if (complementary.onlyInFirst.length) parts.push('첫 번째 사람에게만 있는 기운이 있음');
    if (complementary.onlyInSecond.length) parts.push('두 번째 사람에게만 있는 기운이 있음');
    push('complementaryElements', parts.join(', '), [DOMAINS.ATTRACTION, DOMAINS.NEED]);
  }

  push(
    'confidence',
    evidence.confidence === 'full'
      ? '두 사람 모두 확정되어 있어 말할 수 있는 범위가 넓음'
      : '적어도 한 사람이 확정되지 않아 말할 수 있는 범위가 좁음',
    [DOMAINS.META],
  );

  return catalog;
}

/**
 * dominant / secondary evidence 분리.
 *
 * dominant는 그 case를 가장 잘 특징짓는 근거다. 섹션마다 서로 다른 근거를
 * 중심에 두게 만들어, case가 달라지면 결과도 실제로 달라지게 한다.
 */
function splitEvidenceSalience(catalog) {
  const observable = catalog.filter((item) => !META_KINDS.has(item.kind));
  const weight = (item) => {
    if (item.kind === 'dayMaster' || item.kind === 'dayMasterInteraction') return 3;
    if (item.kind === 'tension' || item.kind === 'support') return 2;
    if (item.kind === 'visibleTenGod') return 2;
    return 1;
  };
  const sorted = observable.slice().sort((a, b) => weight(b) - weight(a));
  const cut = Math.max(1, Math.ceil(sorted.length / 3));
  return {
    dominant: sorted.slice(0, cut).map((i) => i.id),
    secondary: sorted.slice(cut).map((i) => i.id),
  };
}

// ── claim 단위 검증 ──────────────────────────────────────────────────────

/** claim 종류. 관찰과 조언을 구분해서 검증 기준을 다르게 적용한다. */
const CLAIM_TYPES = Object.freeze({ OBSERVATION: 'observation', ADVICE: 'advice' });

/**
 * 섹션들의 claim을 catalog와 대조한다.
 *
 * 관찰(observation) claim은 반드시 관찰 가능한 근거를 인용해야 한다.
 * 조언(advice) claim은 근거 밖 성격 주장 없이 현실적인 행동을 말하는 것이므로
 * confidence 같은 메타 근거만 인용해도 통과시킨다.
 *
 * @returns {{ ok: boolean, violations: Array<{code: string, section?: string, ref?: string}> }}
 */
function validateGroundingRefs({ sections, catalog, requiredKeys }) {
  const violations = [];
  const byId = new Map(catalog.map((item) => [item.id, item]));
  const used = new Set();
  const sectionsPerRef = new Map();

  for (const key of requiredKeys) {
    const claims = sections?.[key]?.claims;
    if (!Array.isArray(claims) || claims.length === 0) {
      violations.push({ code: 'missingClaims', section: key });
      continue;
    }

    let observations = 0;
    const refsInSection = new Set();

    for (const claim of claims) {
      const text = typeof claim?.text === 'string' ? claim.text.trim() : '';
      if (!text) {
        violations.push({ code: 'emptyClaimText', section: key });
        continue;
      }
      const type = claim?.type;
      if (type !== CLAIM_TYPES.OBSERVATION && type !== CLAIM_TYPES.ADVICE) {
        violations.push({ code: 'unknownClaimType', section: key });
        continue;
      }
      const refs = claim?.groundingRefs;
      if (!Array.isArray(refs) || refs.length === 0) {
        violations.push({ code: 'missingGroundingRef', section: key });
        continue;
      }

      let observable = 0;
      for (const ref of refs) {
        const item = typeof ref === 'string' ? byId.get(ref) : null;
        if (!item) {
          violations.push({ code: 'unknownGroundingRef', section: key, ref: String(ref) });
          continue;
        }
        used.add(ref);
        refsInSection.add(ref);
        if (!META_KINDS.has(item.kind)) observable += 1;
      }

      if (type === CLAIM_TYPES.OBSERVATION) {
        observations += 1;
        // 관찰인데 확정도(meta)만 인용했다면 근거 없이 성격을 단정한 것이다.
        if (observable === 0) {
          violations.push({ code: 'observationWithoutObservableRef', section: key });
        }
      }
    }

    if (observations === 0) {
      violations.push({ code: 'sectionWithoutObservation', section: key });
    }
    for (const ref of refsInSection) {
      sectionsPerRef.set(ref, (sectionsPerRef.get(ref) || 0) + 1);
    }
  }

  const observableCatalog = catalog.filter((item) => !META_KINDS.has(item.kind));
  const minDistinct = Math.min(MIN_DISTINCT_REFS, observableCatalog.length);
  const usedObservable = [...used].filter((ref) => !META_KINDS.has(byId.get(ref)?.kind));
  if (usedObservable.length < minDistinct) {
    violations.push({ code: 'insufficientEvidenceDiversity' });
  }
  for (const [ref, count] of sectionsPerRef) {
    if (count > MAX_SECTIONS_PER_REF) {
      violations.push({ code: 'refOverusedAcrossSections', ref, sections: count });
    }
  }

  return { ok: violations.length === 0, violations };
}

/** 개인 서사 grounding 검증. */
function validatePersonalGrounding(raw, catalog) {
  return validateGroundingRefs({
    sections: raw?.personalSections,
    catalog,
    requiredKeys: GROUNDED_PERSONAL_KEYS,
  });
}

/** 궁합 서사 grounding 검증. */
function validateCompatibilityGrounding(raw, catalog) {
  return validateGroundingRefs({
    sections: raw?.compatibilitySections,
    catalog,
    requiredKeys: GROUNDED_COMPATIBILITY_KEYS,
  });
}

/** catalog id 목록(문구 누출 검사기가 쓴다). */
function catalogIds(catalog) {
  return catalog.map((item) => item.id);
}

module.exports = {
  PERSONAL_REF_PREFIX,
  COMPATIBILITY_REF_PREFIX,
  MIN_DISTINCT_REFS,
  MAX_SECTIONS_PER_REF,
  CLAIM_TYPES,
  META_KINDS,
  buildPersonalEvidenceCatalog,
  buildCompatibilityEvidenceCatalog,
  splitEvidenceSalience,
  validateGroundingRefs,
  validatePersonalGrounding,
  validateCompatibilityGrounding,
  catalogIds,
};
