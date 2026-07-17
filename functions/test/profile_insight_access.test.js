'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const {
  safeUidHash,
  deriveMatchId,
  isActiveMatchFor,
  assertProfileInsightAccess,
  buildInsightSourceData,
  INSIGHT_USER_FIELD_MASK,
} = require('../lib/profile_insight_access');

class FakeHttpsError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

function createLogger() {
  const records = [];
  return {
    records,
    warn: (m) => records.push(String(m)),
    error: (m) => records.push(String(m)),
    log: (m) => records.push(String(m)),
  };
}

function matchSnap(exists, data) {
  return { exists, data: () => data };
}

// 접근 계약 검증을 fake 의존성으로 호출하는 헬퍼.
async function callAssert({
  callerUid = 'caller',
  targetUid = 'target',
  match = null, // {participants, unmatchedBy} 또는 null(문서 없음)
  blocks = {}, // { 'owner->blocked': true }
  authExists = true,
  logger = createLogger(),
  matchThrows = false,
} = {}) {
  const calls = { getMatch: 0, blockExists: 0, getAuthUser: 0, matchIds: [] };
  const deps = {
    callerUid,
    targetUid,
    HttpsError: FakeHttpsError,
    getMatchDoc: async (matchId) => {
      calls.getMatch += 1;
      calls.matchIds.push(matchId);
      if (matchThrows) throw new Error('firestore down');
      return match ? matchSnap(true, match) : matchSnap(false, undefined);
    },
    blockExists: async (ownerUid, blockedUid) => {
      calls.blockExists += 1;
      return blocks[`${ownerUid}->${blockedUid}`] === true;
    },
    getAuthUser: async (uid) => {
      calls.getAuthUser += 1;
      if (!authExists) {
        const e = new Error('no user');
        e.code = 'auth/user-not-found';
        throw e;
      }
      return { uid };
    },
    logger,
  };
  const result = await assertProfileInsightAccess(deps);
  return { result, calls, logger };
}

// ===========================================================================
// 순수 helper
// ===========================================================================
test('deriveMatchId: 정렬 후 join, 순서 무관 동일', () => {
  assert.equal(deriveMatchId('b', 'a'), 'a_b');
  assert.equal(deriveMatchId('a', 'b'), 'a_b');
});

test('isActiveMatchFor: participants 둘 다 포함 + unmatchedBy 비어야 활성', () => {
  assert.equal(isActiveMatchFor(matchSnap(true, { participants: ['a', 'b'] }), 'a', 'b'), true);
  assert.equal(isActiveMatchFor(matchSnap(true, { participants: ['a', 'c'] }), 'a', 'b'), false);
  assert.equal(isActiveMatchFor(matchSnap(true, { participants: ['a', 'b'], unmatchedBy: ['a'] }), 'a', 'b'), false);
  assert.equal(isActiveMatchFor(matchSnap(false, undefined), 'a', 'b'), false);
  assert.equal(isActiveMatchFor(null, 'a', 'b'), false);
});

test('safeUidHash: 8 hex, 원문 미포함', () => {
  const h = safeUidHash('some-secret-uid');
  assert.match(h, /^[0-9a-f]{8}$/);
  assert.ok(!h.includes('secret'));
});

// ===========================================================================
// 접근 계약 (테스트 2~9)
// ===========================================================================
test('self target 허용 — match/block/auth 조회 없이 통과 (2)', async () => {
  const { result, calls } = await callAssert({ callerUid: 'me', targetUid: 'me' });
  assert.equal(result.relation, 'self');
  assert.equal(calls.getMatch, 0);
  assert.equal(calls.blockExists, 0);
  assert.equal(calls.getAuthUser, 0);
});

test('유효 match participant target 허용 (3)', async () => {
  const { result, calls } = await callAssert({
    callerUid: 'a',
    targetUid: 'b',
    match: { participants: ['a', 'b'] },
    authExists: true,
  });
  assert.equal(result.relation, 'match');
  // 서버가 파생한 matchId 로 조회했는지.
  assert.deepEqual(calls.matchIds, ['a_b']);
  assert.equal(calls.getAuthUser, 1);
});

test('임의 targetUid(매치 없음) 차단 (4)', async () => {
  await assert.rejects(
    callAssert({ callerUid: 'a', targetUid: 'stranger', match: null }),
    (e) => e instanceof FakeHttpsError && e.code === 'permission-denied',
  );
});

test('caller가 participant가 아닌 match 차단 (5)', async () => {
  // match 문서에 caller 가 없음(참여자 c,b). 서버는 파생 matchId로 조회하므로
  // 이런 문서는 애초에 다른 matchId에 있지만, 방어적으로 participants 재확인.
  await assert.rejects(
    callAssert({ callerUid: 'a', targetUid: 'b', match: { participants: ['c', 'b'] } }),
    (e) => e.code === 'permission-denied',
  );
});

test('target이 match 상대와 불일치하면 차단 (6)', async () => {
  await assert.rejects(
    callAssert({ callerUid: 'a', targetUid: 'b', match: { participants: ['a', 'x'] } }),
    (e) => e.code === 'permission-denied',
  );
});

test('비활성(unmatch된) match 차단 (7)', async () => {
  await assert.rejects(
    callAssert({ callerUid: 'a', targetUid: 'b', match: { participants: ['a', 'b'], unmatchedBy: ['b'] } }),
    (e) => e.code === 'permission-denied',
  );
});

test('양방향 block 관계 차단 — caller가 target 차단 (8a)', async () => {
  await assert.rejects(
    callAssert({
      callerUid: 'a',
      targetUid: 'b',
      match: { participants: ['a', 'b'] },
      blocks: { 'a->b': true },
    }),
    (e) => e.code === 'permission-denied',
  );
});

test('양방향 block 관계 차단 — target이 caller 차단 (8b)', async () => {
  await assert.rejects(
    callAssert({
      callerUid: 'a',
      targetUid: 'b',
      match: { participants: ['a', 'b'] },
      blocks: { 'b->a': true },
    }),
    (e) => e.code === 'permission-denied',
  );
});

test('Auth에 없는 orphan target 차단 (9)', async () => {
  await assert.rejects(
    callAssert({ callerUid: 'a', targetUid: 'b', match: { participants: ['a', 'b'] }, authExists: false }),
    (e) => e.code === 'failed-precondition',
  );
});

test('orphan 차단은 block/match 통과 후 Auth 단계에서 발생', async () => {
  const { calls } = await callAssert({
    callerUid: 'a',
    targetUid: 'b',
    match: { participants: ['a', 'b'] },
    authExists: true,
  }).catch(() => ({ calls: null }));
  // 정상 통과 케이스에서 순서: match -> block(2) -> auth(1)
  assert.ok(calls);
  assert.equal(calls.getMatch, 1);
  assert.equal(calls.blockExists, 2);
  assert.equal(calls.getAuthUser, 1);
});

// ===========================================================================
// 로그 안전성 (테스트 17)
// ===========================================================================
test('접근 거부 로그에 raw uid/PII 미포함, hash만 (17)', async () => {
  const logger = createLogger();
  await callAssert({
    callerUid: 'caller-uid-secret',
    targetUid: 'target-uid-secret',
    match: null,
    logger,
  }).catch(() => {});
  const joined = logger.records.join('\n');
  assert.ok(logger.records.length > 0);
  assert.ok(!joined.includes('caller-uid-secret'));
  assert.ok(!joined.includes('target-uid-secret'));
  assert.match(joined, /callerHash":"[0-9a-f]{8}"/);
  assert.match(joined, /category":"access_denied_no_active_match"/);
});

// ===========================================================================
// private 데이터 최소화 / 입력 조립 (테스트 12,13,14,15)
// ===========================================================================
test('users fieldMask는 birthDate + profileInsight 만 (13)', () => {
  assert.deepEqual([...INSIGHT_USER_FIELD_MASK].sort(), ['birthDate', 'profileInsight']);
});

test('buildInsightSourceData: 공개 필드는 publicData에서 온다 (12)', () => {
  const publicData = {
    photoUrls: ['u1', 'u2'],
    bio: 'hello',
    interests: ['i1'],
    personalityTags: ['p1'],
    idealTags: ['t1'],
    relationshipGoal: 'serious',
    mbti: 'INFP',
  };
  const src = buildInsightSourceData({ publicData, birthDate: { seconds: 1 } });
  assert.deepEqual(src.photoUrls, ['u1', 'u2']);
  assert.equal(src.bio, 'hello');
  assert.deepEqual(src.interests, ['i1']);
  assert.equal(src.relationshipGoal, 'serious');
  assert.equal(src.mbti, 'INFP');
  assert.deepEqual(src.birthDate, { seconds: 1 });
});

test('buildInsightSourceData: 민감 필드는 포함하지 않는다 (15)', () => {
  const publicData = {
    bio: 'hi',
    photoUrls: [],
    // 아래는 publicProfiles에 있어서도 절대 옮기면 안 되는 값들(방어적으로 확인)
    email: 'x@y.z',
    phone: '01000000000',
    fcmTokens: ['tok'],
    location: { lat: 1, lng: 2 },
    jelly: 999,
    boostUntil: 123,
    discoveryFilter: { ageMin: 20 },
  };
  const src = buildInsightSourceData({ publicData, birthDate: null });
  const keys = Object.keys(src);
  for (const forbidden of ['email', 'phone', 'fcmTokens', 'location', 'jelly', 'boostUntil', 'discoveryFilter']) {
    assert.ok(!keys.includes(forbidden), `${forbidden} 포함되면 안 됨`);
  }
  // birthDate는 원문으로 보관되지만(사주 파생용), 아래 (14) 테스트에서 프롬프트
  // 입력에는 파생값만 들어가는 것을 index.js 정적 검증으로 확인한다.
});

test('buildInsightSourceData: 비정상 publicData도 안전 기본값', () => {
  const src = buildInsightSourceData({ publicData: null, birthDate: undefined });
  assert.deepEqual(src.photoUrls, []);
  assert.equal(src.bio, '');
  assert.deepEqual(src.interests, []);
  assert.equal(src.relationshipGoal, null);
  assert.equal(src.birthDate, null);
});

// ===========================================================================
// index.js 통합 불변식 — 정적 소스 검증 (테스트 1,10,11,14,16,20)
// ===========================================================================
test('index.js: profile insight 접근/최소화/로그 불변식 (1,10,11,14,16,20)', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'index.js'), 'utf8');

  // (1) unauthenticated 차단 유지.
  assert.ok(src.includes("throw new HttpsError('unauthenticated', '로그인이 필요합니다.');"));

  // generateProfileInsight 블록만 잘라서 검사(다른 callable/헬퍼와 섞이지 않게).
  const exportStart = src.indexOf('exports.generateProfileInsight = onCall(');
  const blockEnd = src.indexOf('// M9: AI 이상형 이미지 생성', exportStart);
  assert.ok(exportStart > 0 && blockEnd > exportStart, 'generateProfileInsight 블록 확인');
  const fnSrc = src.slice(exportStart, blockEnd);

  // (11) 접근 검증이 users private 문서 읽기보다 먼저. assert 호출이 getAll/
  //      publicProfiles 읽기보다 소스상 앞서는지 위치로 확인.
  const idxAssert = fnSrc.indexOf('assertProfileInsightAccess({');
  const idxGetAll = fnSrc.indexOf("db.getAll(userRef, { fieldMask: INSIGHT_USER_FIELD_MASK }");
  const idxPublic = fnSrc.indexOf("db.collection('publicProfiles').doc(targetUid).get()");
  assert.ok(idxAssert > 0 && idxGetAll > idxAssert, '접근 검증이 users getAll 보다 먼저');
  assert.ok(idxPublic > idxAssert, '접근 검증이 publicProfiles 읽기보다 먼저');

  // (11) users 문서는 fieldMask 로만 읽는다(전체 snap().data() 로 안 읽음).
  assert.ok(fnSrc.includes('fieldMask: INSIGHT_USER_FIELD_MASK'));
  assert.ok(!/=\s*snap\.data\(\)\s*\|\|\s*\{\};/.test(fnSrc), '전체 users 문서 read 잔재 없음');
  assert.ok(!fnSrc.includes('const snap = await userRef.get();'), '전체 users get() 잔재 없음');

  // (12) 공개 필드는 publicProfiles 우선.
  assert.ok(idxPublic > 0, 'publicProfiles 읽기 존재');

  // (14) 원문 birthDate 는 프롬프트에 안 들어가고 파생 사주만. userPayload 는
  //      profileInsightInputFromData 결과(profile)만 전달한다.
  assert.ok(src.includes('userPayload: { 프로필: profile },'), '프롬프트 입력은 파생 profile 만');
  assert.ok(!src.includes('birthDate: sourceData'), '프롬프트에 birthDate 직접 주입 없음');

  // (16,17) sanitized 로그 — generateProfileInsight 는 원문 error.message /
  //         error 객체를 로그로 흘리지 않는다(다른 함수는 이 phase 범위 밖).
  assert.ok(!fnSrc.includes('error?.message'), 'error.message 로그 잔재 제거');
  assert.ok(!fnSrc.includes('error.message'), 'error.message 로그 잔재 제거');
  assert.ok(!fnSrc.includes('releaseError?.message'), 'release 원문 로그 잔재 제거');
  assert.ok(src.includes('function logInsightEvent('), 'sanitized 로그 헬퍼 존재');

  // (20) 모델/프롬프트/generation 파라미터 불변.
  assert.ok(src.includes("const PROFILE_INSIGHT_MODEL = 'gpt-4o';"));
  assert.ok(src.includes('temperature: 0.6,'));
  assert.ok(src.includes("response_format: { type: 'json_object' }"));
  assert.ok(src.includes("detail: 'low',"));
  assert.ok(src.includes('비외모적 첫인상과 대화 힌트를 분석하는 카피라이터'));
  assert.ok(
    src.includes('{"firstImpression": string, "conversationStyle": string, "atmosphere": string, "goodMatchType": string}'),
  );
});
