'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

// 1-C 보정 회귀 테스트.
//
// 실제 OpenAI를 호출하지 않는다. index.js는 secret·admin 초기화를 하므로
// require하지 않고, 소스 계약 검사 + 순수 helper 재구현 검증으로 나눈다.

const SOURCE = fs.readFileSync(
  path.join(__dirname, '..', 'index.js'),
  'utf8',
);

function functionSlice(name) {
  const start = SOURCE.indexOf(`exports.${name} = onCall(`);
  assert.ok(start >= 0, `${name} not found`);
  const next = SOURCE.indexOf('\nexports.', start + 1);
  return SOURCE.slice(start, next === -1 ? SOURCE.length : next);
}

const TIPS = functionSlice('generateConversationTips');

// ── 권한·차단 계약 ────────────────────────────────────────────────────────

test('1. unauthenticated를 거부한다', () => {
  assert.ok(TIPS.includes("if (!request.auth)"));
  assert.ok(TIPS.includes("throw new HttpsError('unauthenticated'"));
});

test('2/3. match 존재와 active participant를 검증한다', () => {
  assert.ok(TIPS.includes("throw new HttpsError('not-found', '매치를 찾을 수 없습니다.')"));
  assert.ok(TIPS.includes('assertActiveMatchParticipant({'));
  // client가 보낸 상대 UID를 신뢰하지 않는다 — matchId만 받는다.
  assert.ok(TIPS.includes('const { matchId } = request.data || {}'));
  assert.ok(!TIPS.includes('request.data.otherUid'));
});

test('4/5. 차단 검증이 캐시 확인보다 먼저 실행된다', () => {
  const blockIdx = TIPS.indexOf('assertNoMatchBlocks({');
  const cacheIdx = TIPS.indexOf('readConversationTipsCache(');
  assert.ok(blockIdx >= 0, '차단 검증이 없다');
  assert.ok(cacheIdx >= 0, '캐시 확인이 없다');
  assert.ok(
    blockIdx < cacheIdx,
    '차단 검증이 캐시 뒤에 있으면 차단된 관계에서 과거 추천이 반환된다',
  );
});

test('6. unmatched/종료 매치는 assertActiveMatchParticipant가 거부한다', () => {
  const helperStart = SOURCE.indexOf('function assertActiveMatchParticipant');
  const helper = SOURCE.slice(helperStart, helperStart + 900);
  assert.ok(helper.includes('isUnmatchedMatchData(matchData)'));
  assert.ok(helper.includes("HttpsError('failed-precondition', '이미 종료된 매치입니다.')"));
  assert.ok(helper.includes("HttpsError('permission-denied'"));
});

test('7. 메시지가 없으면 failed-precondition이다', () => {
  assert.ok(TIPS.includes("throw new HttpsError('failed-precondition', '대화 메시지가 필요합니다.')"));
});

// ── 캐시 버전 계약 ────────────────────────────────────────────────────────

test('8/9/10/11. 캐시는 lastMessageId와 suggestionVersion이 모두 맞아야 hit이다', () => {
  const start = SOURCE.indexOf('function readConversationTipsCache');
  const slice = SOURCE.slice(start, start + 700);
  assert.ok(slice.includes('cached.lastMessageId !== latestMessageId'));
  assert.ok(slice.includes('cached.suggestionVersion !== CONVERSATION_SUGGESTION_VERSION'));
  // v1(문자열 배열) 캐시는 suggestionVersion이 없어 자연히 miss된다.
  assert.ok(slice.includes('sanitizeConversationSuggestionItems('));
});

test('구버전 앱을 위해 문자열 suggestions를 계속 저장·반환한다', () => {
  assert.ok(TIPS.includes('suggestions: suggestionTextsOf(suggestionItems)'));
  const respStart = SOURCE.indexOf('function conversationTipsResponse');
  const resp = SOURCE.slice(respStart, respStart + 500);
  assert.ok(resp.includes('suggestions: suggestionTextsOf(items)'));
  assert.ok(resp.includes('suggestionItems: items'));
  assert.ok(resp.includes('schemaVersion: 2'));
  // 참가자 UID를 응답에 넣지 않는다.
  assert.ok(!resp.includes('uidA'));
  assert.ok(!resp.includes('uidB'));
});

// ── provider 오류 정규화 ──────────────────────────────────────────────────

test('17/18/19. provider 오류가 범주별 typed error로 정규화된다', () => {
  const start = SOURCE.indexOf('function classifyProviderError');
  const slice = SOURCE.slice(start, start + 1200);
  assert.ok(slice.includes("httpsCode: 'resource-exhausted'"));
  assert.ok(slice.includes("httpsCode: 'unavailable'"));
  assert.ok(slice.includes("httpsCode: 'internal'"));
  assert.ok(slice.includes('status === 429'));
  assert.ok(slice.includes('status === 401'));
  // invalid key는 사용자에게 내부 사유를 노출하지 않는다.
  assert.ok(slice.includes("category: 'provider_auth'"));
});

test('20. provider 오류 로그에 원문·key·raw id가 없다', () => {
  const idx = TIPS.indexOf("'provider_error'");
  assert.ok(idx >= 0);
  const slice = TIPS.slice(idx - 200, idx + 400);
  assert.ok(slice.includes('errorCategory'));
  assert.ok(slice.includes('callerHash: safeUidHash('));
  assert.ok(slice.includes('matchHash: safeMatchHash('));
  assert.ok(!slice.includes('error.message'));
  assert.ok(!slice.includes('String(error)'));
});

test('로그에 raw matchId·UID·메시지 원문이 없다', () => {
  assert.ok(!/matchId: matchId/.test(TIPS));
  assert.ok(!/uid: request\.auth\.uid/.test(TIPS));
  assert.ok(!TIPS.includes('recentMessages,\n          retryable'));
  // 모든 로그 호출이 hash를 쓴다.
  const logCalls = TIPS.match(/logTextAiEvent\([^)]*\{[\s\S]*?\}\)/g) || [];
  for (const call of logCalls) {
    if (call.includes('callerHash')) continue;
    assert.fail('로그에 callerHash가 없는 호출이 있다');
  }
});

// ── 21/22/23. usage slot 해제 ─────────────────────────────────────────────

test('21/22/23. 실패해도 slot을 해제하고, 성공에만 cooldown을 찍는다', () => {
  assert.ok(TIPS.includes('} finally {'));
  assert.ok(TIPS.includes('releaseTextAiGenerationSlot({'));
  assert.ok(TIPS.includes('success,'));
  // success 플래그는 생성·검증·저장이 모두 끝난 뒤에만 true가 된다.
  const successIdx = TIPS.indexOf('success = true;');
  const setIdx = TIPS.indexOf('await matchRef.set(');
  assert.ok(setIdx >= 0 && successIdx > setIdx);

  // guard 계약: success=false면 lastGeneratedAt을 찍지 않는다 → cooldown 없음.
  const guard = fs.readFileSync(
    path.join(__dirname, '..', 'lib', 'ai_usage_guard.js'),
    'utf8',
  );
  const relStart = guard.indexOf('async function releaseGenerationSlot');
  const rel = guard.slice(relStart, relStart + 600);
  assert.ok(rel.includes('const payload = { leaseExpiresAt: 0 };'));
  assert.ok(rel.includes('if (success === true)'));
  assert.ok(rel.includes('payload.lastGeneratedAt = now();'));
});

// ── 24. 실제 OpenAI 미호출 ────────────────────────────────────────────────

test('24. 이 테스트는 OpenAI를 호출하지 않는다', () => {
  assert.equal(typeof process.env.OPENAI_API_KEY, 'undefined');
});

// ── 12~16. 문장 품질 계약 (순수 helper 재구현 검증) ────────────────────────
//
// index.js를 require하면 secret/admin 초기화가 일어나므로, 소스에서 helper를
// 잘라내 격리 실행한다. 실제 배포되는 코드와 같은 함수 본문을 쓴다.

function loadHelpers() {
  const names = [
    'CONVERSATION_TONES',
    'MAX_SUGGESTION_LENGTH',
    'COACHING_PATTERNS',
    'stripSuggestionDecoration',
    'normalizedSuggestionKey',
    'looksLikeCoaching',
    'sanitizeConversationSuggestionItems',
    'isValidConversationSuggestionItems',
  ];
  const pieces = [];
  for (const name of names) {
    const constIdx = SOURCE.indexOf(`const ${name} =`);
    const fnIdx = SOURCE.indexOf(`function ${name}(`);
    const start = constIdx >= 0 ? constIdx : fnIdx;
    assert.ok(start >= 0, `${name} not found`);
    // 다음 최상위 선언 직전까지 자른다.
    const rest = SOURCE.slice(start + 1);
    const nextConst = rest.search(/\n(?:const|function|exports)\s/);
    pieces.push(SOURCE.slice(start, nextConst === -1 ? SOURCE.length : start + 1 + nextConst));
  }
  const body = `${pieces.join('\n')}\nreturn { sanitizeConversationSuggestionItems, isValidConversationSuggestionItems, stripSuggestionDecoration, looksLikeCoaching };`;
  // eslint-disable-next-line no-new-func
  return new Function(body)();
}

const helpers = loadHelpers();

function itemsOf(...texts) {
  return {
    suggestions: [
      { id: 'natural', tone: 'natural', text: texts[0] },
      { id: 'curious', tone: 'curious', text: texts[1] },
      { id: 'playful', tone: 'playful', text: texts[2] },
    ],
  };
}

const GOOD = [
  '아까 그 얘기 계속 생각났는데, 요즘 제일 자주 듣는 노래 뭐예요?',
  '그럼 주말에는 보통 어디서 시간 보내는 편이에요?',
  '그 취향이면 우리 은근 잘 맞을지도 몰라요 😄',
];

test('12/13. 정확히 3개, natural/curious/playful 각각 하나면 통과한다', () => {
  const items = helpers.sanitizeConversationSuggestionItems(itemsOf(...GOOD));
  assert.equal(items.length, 3);
  assert.deepEqual(
    items.map((i) => i.tone),
    ['natural', 'curious', 'playful'],
  );
  assert.ok(helpers.isValidConversationSuggestionItems(items));
});

test('12. 2개만 오면 거부한다', () => {
  const raw = itemsOf(...GOOD);
  raw.suggestions.pop();
  const items = helpers.sanitizeConversationSuggestionItems(raw);
  assert.equal(helpers.isValidConversationSuggestionItems(items), false);
});

test('13. tone이 중복되면 거부한다', () => {
  const raw = itemsOf(...GOOD);
  raw.suggestions[1].tone = 'natural';
  raw.suggestions[1].id = 'natural';
  const items = helpers.sanitizeConversationSuggestionItems(raw);
  assert.equal(helpers.isValidConversationSuggestionItems(items), false);
});

test('14. 중복·근접 중복 문장을 거부한다', () => {
  const dup = helpers.sanitizeConversationSuggestionItems(
    itemsOf(GOOD[0], GOOD[0], GOOD[2]),
  );
  assert.equal(helpers.isValidConversationSuggestionItems(dup), false);

  // 문장부호·이모지만 다른 근접 중복도 거부한다.
  const near = helpers.sanitizeConversationSuggestionItems(
    itemsOf(GOOD[0], `${GOOD[0]} 😄`, GOOD[2]),
  );
  assert.equal(helpers.isValidConversationSuggestionItems(near), false);
});

test('15. 빈 문장을 거부한다', () => {
  const items = helpers.sanitizeConversationSuggestionItems(
    itemsOf(GOOD[0], '   ', GOOD[2]),
  );
  assert.equal(helpers.isValidConversationSuggestionItems(items), false);
});

test('16. 설명·코칭 문구를 거부한다', () => {
  for (const bad of [
    '상대방의 관심사를 존중하며 개방형 질문을 해보세요.',
    '공감 표현을 통해 라포를 형성하세요.',
    '대화를 이어가기 위해 취미를 물어보는 것이 좋습니다.',
    '운명적으로 잘 맞는 상대이니 솔직하게 다가가세요.',
  ]) {
    assert.ok(helpers.looksLikeCoaching(bad), bad);
    const items = helpers.sanitizeConversationSuggestionItems(
      itemsOf(bad, GOOD[1], GOOD[2]),
    );
    assert.equal(
      helpers.isValidConversationSuggestionItems(items),
      false,
      bad,
    );
  }
});

test('좋은 예시 문장은 코칭으로 오탐되지 않는다', () => {
  for (const good of GOOD) {
    assert.equal(helpers.looksLikeCoaching(good), false, good);
  }
});

test('지나치게 긴 문장을 거부한다', () => {
  const long = '가'.repeat(130);
  const items = helpers.sanitizeConversationSuggestionItems(
    itemsOf(long, GOOD[1], GOOD[2]),
  );
  assert.equal(helpers.isValidConversationSuggestionItems(items), false);
});

test('markdown·번호·따옴표 장식을 제거한다', () => {
  assert.equal(helpers.stripSuggestionDecoration('1. 안녕하세요'), '안녕하세요');
  assert.equal(helpers.stripSuggestionDecoration('- 안녕하세요'), '안녕하세요');
  assert.equal(helpers.stripSuggestionDecoration('"안녕하세요"'), '안녕하세요');
  assert.equal(helpers.stripSuggestionDecoration('**안녕하세요**'), '안녕하세요');
});

test('알 수 없는 tone은 버린다', () => {
  const items = helpers.sanitizeConversationSuggestionItems({
    suggestions: [
      { id: 'natural', tone: 'natural', text: GOOD[0] },
      { id: 'flirty', tone: 'flirty', text: '몰라요' },
      { id: 'curious', tone: 'curious', text: GOOD[1] },
    ],
  });
  assert.equal(items.length, 2);
  assert.equal(helpers.isValidConversationSuggestionItems(items), false);
});
