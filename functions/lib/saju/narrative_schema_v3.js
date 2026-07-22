'use strict';

/**
 * 사주·궁합 서사 schema v3 — Phase 5-4.
 *
 * v2까지는 `response_format: { type: 'json_object' }`(일반 JSON 모드)로 받고
 * sanitizeNarrative()가 사후 보정했다. v3는 strict Structured Outputs로 바꿔서
 * "형식이 틀린 응답"이라는 실패 모드 자체를 없앤다.
 *
 * 두 층의 schema가 있다:
 * - **내부 schema**(AI가 채우는 것): 각 섹션마다 `groundingRefs`를 요구한다.
 *   서버가 evidence catalog와 대조해 근거 밖 생성인지 검증한다.
 * - **공개 schema**(앱이 받는 것): groundingRefs를 제거하고, 섹션 제목은
 *   서버 상수로 채운다. 모델이 제목을 흔들지 못하게 하기 위함이다.
 *
 * 하위호환: v2의 4개 공개 필드(characterType/summary/reasons/relationshipStory)는
 * v3에서도 같은 의미로 항상 존재한다. 구버전 앱은 새 필드를 무시하면 된다.
 *
 * strict Structured Outputs 제약(OpenAI):
 * - 모든 object에 `additionalProperties: false`
 * - `required`에 모든 property를 나열(선택 필드는 nullable union으로 표현)
 * - minLength/maxLength/minItems 같은 길이 제약은 지원되지 않는다
 *   → 길이·개수는 프롬프트로 요구하고 narrative_quality_checks.js가 검사한다
 */

/** 서사 계약 버전. evidenceVersion(1)·conventionVersion(2)과 별개 축이다. */
const NARRATIVE_SCHEMA_VERSION = 3;

/** 프롬프트 버전. 문구 지침을 바꾸면 올린다 → 기존 캐시가 자연 miss된다. */
const NARRATIVE_PROMPT_VERSION = 4;

/** reasons 항목 수. 프롬프트와 검사기가 같은 상수를 본다. */
const REASONS_COUNT = 3;

/** 개인 사주 섹션 key와 화면 제목. 제목은 서버가 채운다(모델이 만들지 않는다). */
const PERSONAL_SECTION_TITLES = Object.freeze({
  loveStyle: '연애할 때 나는',
  affectionStyle: '마음이 가면',
  conflictPattern: '갈등이 생기면',
  emotionalNeed: '관계에서 필요한 것',
  attractionPattern: '이런 사람에게 끌려요',
  growthAdvice: '관계를 더 편하게 만드는 법',
});

/** 궁합 섹션 key와 화면 제목. */
const COMPATIBILITY_SECTION_TITLES = Object.freeze({
  initialChemistry: '처음 끌리는 이유',
  communicationFlow: '대화가 잘 통하는 순간',
  differencePoint: '서로 다르게 반응하는 지점',
  conflictScene: '서운함이 생길 수 있는 장면',
  repairConversation: '관계를 편하게 만드는 대화법',
});

const PERSONAL_SECTION_KEYS = Object.freeze(Object.keys(PERSONAL_SECTION_TITLES));
const COMPATIBILITY_SECTION_KEYS = Object.freeze(
  Object.keys(COMPATIBILITY_SECTION_TITLES),
);

/** groundingRefs를 요구하는 섹션(participantAdvice는 제외 — 조언 쌍이다). */
const GROUNDED_PERSONAL_KEYS = PERSONAL_SECTION_KEYS;
const GROUNDED_COMPATIBILITY_KEYS = COMPATIBILITY_SECTION_KEYS;

const groundingRefsProperty = Object.freeze({
  type: 'array',
  description:
    '이 문장의 근거가 된 evidence catalog id 목록. catalog에 없는 id는 금지.',
  items: { type: 'string' },
});

/**
 * claim = 문장 하나 + 그 문장의 근거.
 *
 * 섹션 단위로 근거를 받으면 어느 문장이 근거를 벗어났는지 알 수 없다.
 * 문장마다 근거를 들고 오게 해서 검증 가능한 단위로 낮춘다.
 */
const claimsProperty = Object.freeze({
  type: 'array',
  description:
    '이 섹션을 이루는 문장들. 각 문장은 자기 근거를 직접 인용한다. ' +
    'observation은 근거에서 바로 따라 나오는 관찰, advice는 실천 가능한 조언이다.',
  items: {
    type: 'object',
    properties: {
      text: { type: 'string' },
      type: { type: 'string', enum: ['observation', 'advice'] },
      groundingRefs: groundingRefsProperty,
    },
    required: ['text', 'type', 'groundingRefs'],
    additionalProperties: false,
  },
});

/** {claims} 섹션. 공개 body는 서버가 claim들을 이어 붙여 만든다. */
function bodySection(description) {
  return {
    type: 'object',
    description,
    properties: {
      claims: claimsProperty,
    },
    required: ['claims'],
    additionalProperties: false,
  };
}

const reasonsProperty = Object.freeze({
  type: 'array',
  description: `서로 다른 관점의 근거 ${REASONS_COUNT}개.`,
  items: {
    type: 'object',
    properties: {
      icon: { type: 'string' },
      text: { type: 'string' },
    },
    required: ['icon', 'text'],
    additionalProperties: false,
  },
});

/** 개인 사주 — 모델이 채우는 내부 schema. */
const PERSONAL_NARRATIVE_JSON_SCHEMA = Object.freeze({
  name: 'personal_saju_narrative_v3',
  strict: true,
  schema: {
    type: 'object',
    properties: {
      characterType: { type: 'string' },
      summary: { type: 'string' },
      reasons: reasonsProperty,
      personalSections: {
        type: 'object',
        properties: {
          loveStyle: bodySection('관계를 시작할 때의 속도와 태도'),
          affectionStyle: bodySection('호감을 표현하고 상대 반응을 확인하는 방식'),
          conflictPattern: bodySection('갈등·서운함에 반응하는 모습'),
          emotionalNeed: bodySection('관계에서 필요한 안정감'),
          attractionPattern: bodySection('끌리는 상대의 특징과 반복하기 쉬운 패턴'),
          growthAdvice: {
            type: 'object',
            description: '관계를 더 편하게 만드는 방법과 바로 할 수 있는 행동 하나',
            properties: {
              claims: claimsProperty,
              action: { type: 'string' },
            },
            required: ['claims', 'action'],
            additionalProperties: false,
          },
        },
        required: PERSONAL_SECTION_KEYS.slice(),
        additionalProperties: false,
      },
    },
    required: ['characterType', 'summary', 'reasons', 'personalSections'],
    additionalProperties: false,
  },
});

/** 궁합 — 모델이 채우는 내부 schema. */
const COMPATIBILITY_NARRATIVE_JSON_SCHEMA = Object.freeze({
  name: 'compatibility_saju_narrative_v3',
  strict: true,
  schema: {
    type: 'object',
    properties: {
      characterType: { type: 'string' },
      summary: { type: 'string' },
      reasons: reasonsProperty,
      relationshipStory: { type: 'string' },
      compatibilitySections: {
        type: 'object',
        properties: {
          initialChemistry: bodySection('처음 서로에게 끌릴 수 있는 이유'),
          communicationFlow: bodySection('대화가 자연스럽게 이어지는 순간'),
          differencePoint: bodySection('표현 속도·감정 확인 방식의 차이'),
          conflictScene: bodySection('실제로 서운함이 생길 수 있는 장면'),
          repairConversation: {
            type: 'object',
            description: '다시 대화를 시작하는 방법과 실제로 쓸 수 있는 문장 하나',
            properties: {
              claims: claimsProperty,
              examplePhrase: { type: 'string' },
            },
            required: ['claims', 'examplePhrase'],
            additionalProperties: false,
          },
          participantAdvice: {
            type: 'object',
            description:
              '첫 번째 사람과 두 번째 사람에게 각각 도움이 되는 행동. 순서를 바꾸지 않는다.',
            properties: {
              first: { type: 'string' },
              second: { type: 'string' },
            },
            required: ['first', 'second'],
            additionalProperties: false,
          },
        },
        required: [...COMPATIBILITY_SECTION_KEYS, 'participantAdvice'],
        additionalProperties: false,
      },
    },
    required: [
      'characterType',
      'summary',
      'reasons',
      'relationshipStory',
      'compatibilitySections',
    ],
    additionalProperties: false,
  },
});

// ── 공개 payload 조립 ────────────────────────────────────────────────────

function trimmed(value) {
  return typeof value === 'string' ? value.trim() : '';
}

/**
 * 검증을 통과한 claim들을 공개 body 한 문자열로 조합한다.
 *
 * 공개 payload에는 claim 구조도 groundingRefs도 남기지 않는다 — 앱이 받는
 * 모양은 v3 그대로다(문자열 body). 내부 구조는 검증용으로만 존재한다.
 */
function assembleBody(section) {
  const claims = Array.isArray(section?.claims) ? section.claims : [];
  return claims
    .map((claim) => trimmed(claim?.text))
    .filter(Boolean)
    .join(' ');
}

function publicReasons(reasons) {
  return (Array.isArray(reasons) ? reasons : [])
    .map((r) => ({ icon: trimmed(r?.icon) || '✨', text: trimmed(r?.text) }))
    .filter((r) => r.text);
}

/**
 * 모델 응답(내부) → 앱이 받는 공개 payload.
 *
 * - groundingRefs 제거 (Firestore 캐시에도 저장되지 않는다)
 * - 섹션 제목은 서버 상수로 채운다
 * - v2 공개 필드 4개를 항상 유지한다
 */
function toPublicPersonalNarrative(raw) {
  const sections = raw?.personalSections || {};
  const personalSections = {};
  for (const key of PERSONAL_SECTION_KEYS) {
    const section = sections[key] || {};
    personalSections[key] = {
      title: PERSONAL_SECTION_TITLES[key],
      body: assembleBody(section),
    };
    if (key === 'growthAdvice') {
      personalSections[key].action = trimmed(section.action);
    }
  }
  return {
    schemaVersion: NARRATIVE_SCHEMA_VERSION,
    characterType: trimmed(raw?.characterType),
    summary: trimmed(raw?.summary),
    reasons: publicReasons(raw?.reasons),
    relationshipStory: null,
    personalSections,
    compatibilitySections: null,
  };
}

function toPublicCompatibilityNarrative(raw) {
  const sections = raw?.compatibilitySections || {};
  const compatibilitySections = {};
  for (const key of COMPATIBILITY_SECTION_KEYS) {
    const section = sections[key] || {};
    compatibilitySections[key] = {
      title: COMPATIBILITY_SECTION_TITLES[key],
      body: assembleBody(section),
    };
    if (key === 'repairConversation') {
      compatibilitySections[key].examplePhrase = trimmed(section.examplePhrase);
    }
  }
  compatibilitySections.participantAdvice = {
    first: trimmed(sections.participantAdvice?.first),
    second: trimmed(sections.participantAdvice?.second),
  };
  return {
    schemaVersion: NARRATIVE_SCHEMA_VERSION,
    characterType: trimmed(raw?.characterType),
    summary: trimmed(raw?.summary),
    reasons: publicReasons(raw?.reasons),
    relationshipStory: trimmed(raw?.relationshipStory),
    personalSections: null,
    compatibilitySections,
  };
}

/** 공개 payload에서 사용자에게 보이는 모든 문구를 모은다(검사기 입력). */
function collectPublicText(narrative) {
  const parts = [narrative?.characterType, narrative?.summary];
  for (const reason of narrative?.reasons || []) parts.push(reason?.text);
  if (narrative?.relationshipStory) parts.push(narrative.relationshipStory);
  for (const key of PERSONAL_SECTION_KEYS) {
    const section = narrative?.personalSections?.[key];
    if (!section) continue;
    parts.push(section.body, section.action);
  }
  for (const key of COMPATIBILITY_SECTION_KEYS) {
    const section = narrative?.compatibilitySections?.[key];
    if (!section) continue;
    parts.push(section.body, section.examplePhrase);
  }
  const advice = narrative?.compatibilitySections?.participantAdvice;
  if (advice) parts.push(advice.first, advice.second);
  return parts.filter((p) => typeof p === 'string' && p.trim()).map((p) => p.trim());
}

/**
 * 공개 payload가 v3 계약을 만족하는지. sanitize와 달리 **보정하지 않는다** —
 * strict Structured Outputs를 쓰므로 형식이 틀리면 실패로 취급한다.
 */
function isValidPublicNarrative(narrative, { kind }) {
  if (!narrative || typeof narrative !== 'object') return false;
  if (narrative.schemaVersion !== NARRATIVE_SCHEMA_VERSION) return false;
  if (!trimmed(narrative.characterType) || !trimmed(narrative.summary)) return false;
  if (!Array.isArray(narrative.reasons) || narrative.reasons.length === 0) return false;
  if (
    !narrative.reasons.every(
      (r) => r && typeof r.icon === 'string' && trimmed(r.text),
    )
  ) {
    return false;
  }
  if (kind === 'personal') {
    if (narrative.relationshipStory !== null) return false;
    if (narrative.compatibilitySections !== null) return false;
    const sections = narrative.personalSections;
    if (!sections) return false;
    return PERSONAL_SECTION_KEYS.every((key) => {
      const section = sections[key];
      if (!section || !trimmed(section.body)) return false;
      if (key === 'growthAdvice' && !trimmed(section.action)) return false;
      return true;
    });
  }
  if (!trimmed(narrative.relationshipStory)) return false;
  if (narrative.personalSections !== null) return false;
  const sections = narrative.compatibilitySections;
  if (!sections) return false;
  const sectionsOk = COMPATIBILITY_SECTION_KEYS.every((key) => {
    const section = sections[key];
    if (!section || !trimmed(section.body)) return false;
    if (key === 'repairConversation' && !trimmed(section.examplePhrase)) return false;
    return true;
  });
  if (!sectionsOk) return false;
  const advice = sections.participantAdvice;
  return !!(advice && trimmed(advice.first) && trimmed(advice.second));
}

module.exports = {
  NARRATIVE_SCHEMA_VERSION,
  NARRATIVE_PROMPT_VERSION,
  REASONS_COUNT,
  PERSONAL_SECTION_TITLES,
  COMPATIBILITY_SECTION_TITLES,
  PERSONAL_SECTION_KEYS,
  COMPATIBILITY_SECTION_KEYS,
  GROUNDED_PERSONAL_KEYS,
  GROUNDED_COMPATIBILITY_KEYS,
  PERSONAL_NARRATIVE_JSON_SCHEMA,
  COMPATIBILITY_NARRATIVE_JSON_SCHEMA,
  assembleBody,
  toPublicPersonalNarrative,
  toPublicCompatibilityNarrative,
  collectPublicText,
  isValidPublicNarrative,
};
