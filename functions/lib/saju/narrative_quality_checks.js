'use strict';

/**
 * 서사 품질 검사 — Phase 5-4.
 *
 * 두 종류다:
 * - **hard check**: 하나라도 걸리면 그 응답은 쓰지 않는다(production에서도 실행).
 *   근거 위반, 개인정보 노출, 점수·운명 단정, 내부 코드 노출 같은 계약 위반.
 * - **quality signal**: 실패는 아니지만 품질 점수에 반영한다(평가 harness 전용).
 *   상투 표현, 장면 없음, 문장 과다 길이, 섹션 간 중복 등.
 *
 * 검사 대상은 **공개 문구**다. 내부 groundingRefs는 제거된 뒤에 검사한다.
 */

const { collectPublicText } = require('./narrative_schema_v3');

/** 사용자 문구에 절대 나오면 안 되는 패턴. */
const HARD_PATTERNS = Object.freeze([
  { code: 'numericScore', pattern: /\d+\s*(?:점|％|%|퍼센트)/ },
  {
    // "우선순위"는 일상어라 순위 지표가 아니다. fatalism의 `무조건`과 같은
    // 종류의 오탐이어서 같이 좁힌다(pilot 1회차에서 Terra의 유일한 hard 위반).
    code: 'ranking',
    // `위\b`는 한글이 ASCII \w가 아니라 경계가 성립하지 않아 "3위"를 한 번도
    // 잡지 못했다. 뒤에 한글이 이어지지 않을 때만 순위 표기로 본다.
    pattern: /\d+\s*위(?![가-힣])|(?<!우선)순위|등급|궁합도|점수/,
  },
  {
    // 확정 예언만 hard fail로 잡는다.
    //
    // v1은 `무조건`을 단독 토큰으로 잡아서 "무조건 참기보다 ~"처럼 비교·조언
    // 문맥까지 fatalism으로 판정했다(Stage A 1차에서 Sol의 유일한 hard 위반이
    // 이 오탐이었다). `무조건`은 뒤에 확정 서술이 붙을 때만 위반으로 본다.
    code: 'fatalism',
    pattern: new RegExp(
      [
        '운명적으로',
        '운명이에요',
        '반드시 이렇게',
        '반드시 그렇게',
        '틀림없이',
        '평생 함께',
        '헤어지게 (?:돼|될|됩니다)',
        '이별하게 (?:돼|될|됩니다)',
        '성공할 수밖에',
        // "무조건 헤어져요", "무조건 잘 돼요" 같은 확정 예언
        '무조건\\s+\\S*(?:헤어|이별|실패|성공|잘\\s*돼|잘\\s*될)',
        // "반드시 성공한다" 류
        '반드시\\s+\\S*(?:성공|실패|헤어|이별)',
      ].join('|'),
    ),
  },
  {
    code: 'absoluteVerdict',
    pattern: /최고의 궁합|최악의 궁합|완벽한 사람|완벽한 궁합|타고난 승리자|모두가 좋아하는/,
  },
  {
    code: 'harmonyClashVerdict',
    pattern:
      /합이 (?:있으니|있어서|있으면)|충이 (?:있으니|있어서|있으면)|오행이 부족해서/,
  },
]);

/** 개인정보·내부값 노출 패턴. */
const PRIVACY_PATTERNS = Object.freeze([
  { code: 'rawBirthDate', pattern: /\d{4}\s*[-./년]\s*\d{1,2}\s*[-./월]\s*\d{1,2}/ },
  { code: 'rawBirthTime', pattern: /birthTime|birthTimeMinutes|\d{1,2}시\s*\d{1,2}분에 태어/ },
  { code: 'identifierLike', pattern: /\b[A-Za-z0-9_-]{20,}\b/ },
  { code: 'fingerprintLike', pattern: /\b[0-9a-f]{16,}\b/ },
]);

/** 서버 내부 evidence code 문자열. 사용자 문구에 그대로 나오면 안 된다. */
const INTERNAL_CODE_TOKENS = Object.freeze([
  'dayMasterSameElement',
  'firstGeneratesSecond',
  'secondGeneratesFirst',
  'crossSixHarmony',
  'sharedElementPresence',
  'firstControlsSecond',
  'secondControlsFirst',
  'crossSixClash',
  'contrastingYinYang',
  'sixHarmony',
  'sixClash',
  'threeHarmony',
  'missingHourPillar',
  'uncertainYearPillar',
  'uncertainMonthPillar',
  'uncertainElementBalance',
  'groundingRefs',
  'evidenceVersion',
]);

/** 출생시간을 모를 때 언급하면 안 되는 표현(안내 문구는 여기 걸리지 않는다). */
const HOUR_PILLAR_PATTERN = /시주|時柱|태어난 시간대/;

/** 반복되면 감점되는 상투 표현. */
const CLICHE_PHRASES = Object.freeze([
  '서로의 부족한 부분을 채워',
  '균형을 이루',
  '균형을 만들어',
  '좋은 에너지',
  '단서가 돼요',
  '단서가 될',
  '새로운 관점을 줄',
  '천천히 알아가면',
  '서로를 이해하면',
  '배려하면',
]);

/** 실제 연애 장면이 있는지 판단할 때 보는 단어. */
const SCENE_KEYWORDS = Object.freeze([
  '답장',
  '메시지',
  '연락',
  '카톡',
  '약속',
  '데이트',
  '만나',
  '전화',
  '대화',
  '먼저 말',
]);

/** 조심할 점이 함께 있는지 판단할 때 보는 단어. */
const CAUTION_KEYWORDS = Object.freeze([
  '서운',
  '부담',
  '오해',
  '조심',
  '지칠',
  '지치',
  '어려울',
  '멀어질',
  '답답',
  '피로',
]);

/** 과하게 나열되면 감점되는 명리 용어. */
const JARGON_TERMS = Object.freeze([
  '일간',
  '십성',
  '지장간',
  '천간',
  '지지',
  '육합',
  '육충',
  '삼합',
  '비견',
  '식신',
  '편관',
  '정관',
  '편인',
  '정인',
  '편재',
  '정재',
  '상관',
  '겁재',
]);

const MAX_SENTENCE_LENGTH = 120;
const MAX_JARGON_TERMS = 4;
const MAX_CLICHE_HITS = 1;

/** 공개 길이 기준. */
const LENGTH_RANGES = Object.freeze({
  personal: { min: 700, max: 1200 },
  compatibility: { min: 900, max: 1500 },
});

function sentencesOf(text) {
  return text
    .split(/(?<=[.!?])\s+|\n+/)
    .map((s) => s.trim())
    .filter(Boolean);
}

/**
 * hard check. 하나라도 걸리면 응답을 채택하지 않는다.
 *
 * @param {object} narrative 공개 payload(groundingRefs 제거 후)
 * @param {{ kind: 'personal'|'compatibility', hourPillarKnown: boolean, catalogIds: string[] }} context
 */
function runHardChecks(narrative, { kind, hourPillarKnown = true, catalogIds = [] } = {}) {
  const parts = collectPublicText(narrative);
  const text = parts.join('\n');
  const violations = [];

  for (const { code, pattern } of HARD_PATTERNS) {
    if (pattern.test(text)) violations.push({ code });
  }
  for (const { code, pattern } of PRIVACY_PATTERNS) {
    if (pattern.test(text)) violations.push({ code });
  }
  for (const token of INTERNAL_CODE_TOKENS) {
    if (text.includes(token)) violations.push({ code: 'internalCodeLeak', token });
  }
  for (const id of catalogIds) {
    if (new RegExp(`\\b${id}\\b`).test(text)) {
      violations.push({ code: 'evidenceIdLeak', token: id });
    }
  }
  if (!hourPillarKnown && HOUR_PILLAR_PATTERN.test(text)) {
    violations.push({ code: 'hourPillarWithoutBirthTime' });
  }
  if (kind === 'compatibility') {
    const advice = narrative?.compatibilitySections?.participantAdvice;
    if (!advice || !advice.first?.trim() || !advice.second?.trim()) {
      violations.push({ code: 'missingParticipantAdvice' });
    }
  }

  return { ok: violations.length === 0, violations, textLength: text.replace(/\s/g, '').length };
}

/**
 * quality signal. 실패가 아니라 감점 요소다(평가 harness에서 rubric과 함께 본다).
 */
function runQualitySignals(narrative, { kind } = {}) {
  const parts = collectPublicText(narrative);
  const text = parts.join('\n');
  const compact = text.replace(/\s/g, '');
  const signals = [];

  const range = LENGTH_RANGES[kind];
  if (range && (compact.length < range.min || compact.length > range.max)) {
    signals.push({ code: 'lengthOutOfRange', value: compact.length });
  }

  const clicheHits = CLICHE_PHRASES.filter((phrase) => text.includes(phrase));
  if (clicheHits.length > MAX_CLICHE_HITS) {
    signals.push({ code: 'clicheOveruse', value: clicheHits.length, hits: clicheHits });
  }

  if (!SCENE_KEYWORDS.some((word) => text.includes(word))) {
    signals.push({ code: 'noConcreteScene' });
  }
  if (!CAUTION_KEYWORDS.some((word) => text.includes(word))) {
    signals.push({ code: 'praiseOnly' });
  }

  const jargonHits = JARGON_TERMS.filter((term) => text.includes(term));
  if (jargonHits.length > MAX_JARGON_TERMS) {
    signals.push({ code: 'jargonOverload', value: jargonHits.length });
  }

  const longSentences = sentencesOf(text).filter((s) => s.length > MAX_SENTENCE_LENGTH);
  if (longSentences.length > 0) {
    signals.push({ code: 'longSentence', value: longSentences.length });
  }

  const duplicates = duplicateNgrams(parts, 8);
  if (duplicates.length > 0) {
    signals.push({ code: 'repeatedPhrase', value: duplicates.length });
  }

  if (kind === 'personal') {
    const action = narrative?.personalSections?.growthAdvice?.action;
    if (!action || !action.trim()) signals.push({ code: 'noActionAdvice' });
  } else {
    const phrase = narrative?.compatibilitySections?.repairConversation?.examplePhrase;
    if (!phrase || !phrase.trim()) signals.push({ code: 'noExamplePhrase' });
  }

  return { signals, textLength: compact.length };
}

/** 서로 다른 문단 사이에서 반복되는 n-gram(문자 단위)을 찾는다. */
function duplicateNgrams(parts, n) {
  const seen = new Map();
  const duplicates = [];
  parts.forEach((part, index) => {
    const compact = part.replace(/\s/g, '');
    for (let i = 0; i + n <= compact.length; i += 1) {
      const gram = compact.slice(i, i + n);
      const owner = seen.get(gram);
      if (owner === undefined) {
        seen.set(gram, index);
      } else if (owner !== index) {
        duplicates.push(gram);
        seen.set(gram, index);
      }
    }
  });
  return [...new Set(duplicates)];
}

/**
 * 두 결과가 얼마나 비슷한지(0~1). generic 중복 결과 비율 계산에 쓴다.
 * 문자 4-gram Jaccard.
 */
function textSimilarity(a, b) {
  const gramsOf = (text) => {
    const compact = text.replace(/\s/g, '');
    const set = new Set();
    for (let i = 0; i + 4 <= compact.length; i += 1) set.add(compact.slice(i, i + 4));
    return set;
  };
  const first = gramsOf(a);
  const second = gramsOf(b);
  if (first.size === 0 || second.size === 0) return 0;
  let intersection = 0;
  for (const gram of first) if (second.has(gram)) intersection += 1;
  return intersection / (first.size + second.size - intersection);
}

/**
 * case 간 반복 검사 — distinctiveness 보정용.
 *
 * 1차 평가에서 distinctiveness가 낮았던 이유는 결과 전체가 비슷해서가 아니라
 * (전체 유사도는 낮았다) **같은 문장·같은 장면**이 case를 넘어 재사용됐기
 * 때문이다. 전체 유사도만 보면 이걸 놓친다. 문장 단위로 본다.
 *
 * @param {Array<{caseId: string, narrative: object}>} entries
 * @returns {{ repeatedSentences: Array<{text: string, caseIds: string[]}>,
 *             repeatedSentenceRatio: number }}
 */
function crossCaseRepetition(entries) {
  const owners = new Map();
  let total = 0;
  for (const entry of entries) {
    const seenInCase = new Set();
    for (const part of collectPublicText(entry.narrative)) {
      for (const sentence of sentencesOf(part)) {
        // 아주 짧은 문장은 우연히 겹칠 수 있어 제외한다.
        const key = sentence.replace(/\s/g, '');
        if (key.length < 12 || seenInCase.has(key)) continue;
        seenInCase.add(key);
        total += 1;
        if (!owners.has(key)) owners.set(key, { text: sentence, caseIds: [] });
        owners.get(key).caseIds.push(entry.caseId);
      }
    }
  }
  const repeated = [...owners.values()].filter((o) => o.caseIds.length > 1);
  const repeatedCount = repeated.reduce((sum, o) => sum + o.caseIds.length, 0);
  return {
    repeatedSentences: repeated,
    repeatedSentenceRatio: total === 0 ? 0 : repeatedCount / total,
  };
}

module.exports = {
  HARD_PATTERNS,
  PRIVACY_PATTERNS,
  INTERNAL_CODE_TOKENS,
  CLICHE_PHRASES,
  SCENE_KEYWORDS,
  JARGON_TERMS,
  LENGTH_RANGES,
  MAX_SENTENCE_LENGTH,
  runHardChecks,
  runQualitySignals,
  duplicateNgrams,
  textSimilarity,
  crossCaseRepetition,
};
