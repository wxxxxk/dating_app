'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const {
  PROFILE_INSIGHT_USAGE_POLICY,
  CHARM_REPORT_USAGE_POLICY,
  PROFILE_KEYWORD_SUMMARY_USAGE_POLICY,
  SLOT_DECISION,
  SLOT_OUTCOME,
  sanitizeCount,
  sanitizeTimestamp,
  safeUidHash,
  buildLeaseId,
  normalizeUsageDoc,
  normalizeLeaseDoc,
  evaluateGenerationSlot,
  resolveSlotOutcome,
  createAiUsageGuard,
} = require('../lib/ai_usage_guard');
const {
  PROFILE_KEYWORD_SUMMARY_MODEL,
  PROFILE_KEYWORD_SUMMARY_PROMPT_VERSION,
  buildProfileKeywordGenerationInputHash,
} = require('../lib/profile_keyword_summary');

const POLICY = PROFILE_INSIGHT_USAGE_POLICY;

test('profile keyword summary usage policy export and limits are stable', () => {
  assert.equal(PROFILE_KEYWORD_SUMMARY_USAGE_POLICY.functionName, 'generateProfileKeywordSummary');
  assert.equal(PROFILE_KEYWORD_SUMMARY_USAGE_POLICY.hourlyLimit, 6);
  assert.equal(PROFILE_KEYWORD_SUMMARY_USAGE_POLICY.dailyLimit, 20);
  assert.equal(PROFILE_KEYWORD_SUMMARY_USAGE_POLICY.cooldownMs, 20 * 1000);
  assert.equal(PROFILE_KEYWORD_SUMMARY_USAGE_POLICY.refreshCooldownMs, 24 * 60 * 60 * 1000);
  assert.equal(PROFILE_KEYWORD_SUMMARY_USAGE_POLICY.leaseTtlMs, 60 * 1000);
  assert.ok(Object.isFrozen(PROFILE_KEYWORD_SUMMARY_USAGE_POLICY));

  assert.equal(PROFILE_INSIGHT_USAGE_POLICY.hourlyLimit, 10);
  assert.equal(CHARM_REPORT_USAGE_POLICY.dailyLimit, 15);
});

test('profile keyword summary lease id is deterministic and separated by source/model/version input hash', () => {
  const sourceHashA = 'a'.repeat(64);
  const sourceHashB = 'b'.repeat(64);
  const inputHashA1 = buildProfileKeywordGenerationInputHash(sourceHashA);
  const inputHashA2 = buildProfileKeywordGenerationInputHash(sourceHashA);
  const inputHashB = buildProfileKeywordGenerationInputHash(sourceHashB);
  assert.equal(inputHashA1, inputHashA2);
  assert.notEqual(inputHashA1, inputHashB);
  assert.match(inputHashA1, /^[0-9a-f]{64}$/);

  const lease1 = buildLeaseId(
    PROFILE_KEYWORD_SUMMARY_USAGE_POLICY.functionName,
    'caller',
    null,
    inputHashA1,
  );
  const lease2 = buildLeaseId(
    PROFILE_KEYWORD_SUMMARY_USAGE_POLICY.functionName,
    'caller',
    null,
    inputHashA2,
  );
  const lease3 = buildLeaseId(
    PROFILE_KEYWORD_SUMMARY_USAGE_POLICY.functionName,
    'caller',
    null,
    inputHashB,
  );
  assert.equal(lease1, lease2);
  assert.notEqual(lease1, lease3);
  assert.equal(PROFILE_KEYWORD_SUMMARY_MODEL, 'gpt-4o-mini');
  assert.equal(PROFILE_KEYWORD_SUMMARY_PROMPT_VERSION, 1);
});

// ---------------------------------------------------------------------------
// Fake Firestore — path 기반 in-memory store + optimistic concurrency.
// transaction.get으로 읽은 문서 버전이 커밋 시점에 바뀌었으면 충돌로 보고
// 콜백을 재시도한다(실제 Firestore transaction 의미와 동일). tx.get은 이벤트
// 루프를 한 번 양보해 동시 transaction 간 인터리빙을 만든다.
// ---------------------------------------------------------------------------
function createFakeDb(initial = {}) {
  const store = new Map(Object.entries(initial));
  const versions = new Map();
  let txCount = 0;

  function versionOf(p) {
    return versions.get(p) || 0;
  }
  function snap(p) {
    const data = store.get(p);
    return {
      exists: data !== undefined,
      data() {
        return data;
      },
    };
  }
  function applySet(p, data, opts) {
    const prev = opts && opts.merge ? store.get(p) || {} : {};
    store.set(p, { ...prev, ...data });
    versions.set(p, versionOf(p) + 1);
  }
  function docRef(p) {
    return {
      path: p,
      async get() {
        return snap(p);
      },
      async set(data, opts) {
        applySet(p, data, opts);
      },
      collection(name) {
        return collRef(`${p}/${name}`);
      },
    };
  }
  function collRef(p) {
    return {
      doc(id) {
        return docRef(`${p}/${id}`);
      },
    };
  }

  return {
    store,
    txCount: () => txCount,
    collection(name) {
      return collRef(name);
    },
    async runTransaction(fn) {
      txCount += 1;
      for (let attempt = 0; attempt < 8; attempt += 1) {
        const reads = new Map();
        const writes = [];
        const tx = {
          async get(ref) {
            reads.set(ref.path, versionOf(ref.path));
            // 동시 transaction 인터리빙을 위해 한 번 양보.
            await new Promise((resolve) => setImmediate(resolve));
            return snap(ref.path);
          },
          set(ref, data, opts) {
            writes.push({ path: ref.path, data, opts });
          },
        };
        const result = await fn(tx);
        let conflict = false;
        for (const [p, v] of reads) {
          if (versionOf(p) !== v) {
            conflict = true;
            break;
          }
        }
        if (conflict) continue; // 재시도
        for (const w of writes) applySet(w.path, w.data, w.opts);
        return result;
      }
      throw new Error('fake transaction exceeded max attempts');
    },
  };
}

function fixedNow(ms) {
  return () => ms;
}

// ===========================================================================
// 순수 helper
// ===========================================================================
test('sanitizeCount: 음수/NaN/문자열 -> 0, 양수는 floor', () => {
  assert.equal(sanitizeCount(-3), 0);
  assert.equal(sanitizeCount(NaN), 0);
  assert.equal(sanitizeCount('5'), 0);
  assert.equal(sanitizeCount(undefined), 0);
  assert.equal(sanitizeCount(2.9), 2);
  assert.equal(sanitizeCount(0), 0);
});

test('sanitizeTimestamp: 음수/NaN -> 0', () => {
  assert.equal(sanitizeTimestamp(-1), 0);
  assert.equal(sanitizeTimestamp(NaN), 0);
  assert.equal(sanitizeTimestamp(1000), 1000);
});

test('buildLeaseId: deterministic 하고 raw uid/target을 노출하지 않는다', () => {
  const id = buildLeaseId('generateProfileInsight', 'caller-uid-123', 'target-uid-456', 'abc');
  const id2 = buildLeaseId('generateProfileInsight', 'caller-uid-123', 'target-uid-456', 'abc');
  assert.equal(id, id2);
  assert.match(id, /^[0-9a-f]{64}$/);
  assert.ok(!id.includes('caller-uid-123'));
  assert.ok(!id.includes('target-uid-456'));
  // inputHash가 다르면 다른 lease.
  assert.notEqual(id, buildLeaseId('generateProfileInsight', 'caller-uid-123', 'target-uid-456', 'xyz'));
});

test('safeUidHash: 8자 hex, 원문 uid 미포함', () => {
  const h = safeUidHash('caller-uid-123');
  assert.match(h, /^[0-9a-f]{8}$/);
  assert.ok(!h.includes('caller'));
});

// ===========================================================================
// normalizeUsageDoc / window rollover (테스트 9)
// ===========================================================================
test('normalizeUsageDoc: window 지나면 카운트 리셋 (9)', () => {
  const now = 10_000_000;
  const doc = {
    hourWindowStart: now - POLICY.hourMs - 1, // 만료됨
    hourCount: 9,
    dayWindowStart: now - 1000, // 유효
    dayCount: 20,
    lastAttemptAt: now - 1000,
  };
  const u = normalizeUsageDoc(doc, now, POLICY);
  assert.equal(u.hourCount, 0); // 시간 window 리셋
  assert.equal(u.hourWindowStart, now);
  assert.equal(u.dayCount, 20); // 일일 window 유지
});

test('normalizeUsageDoc: 미래 window(비정상)면 리셋', () => {
  const now = 10_000_000;
  const doc = { hourWindowStart: now + 999999, hourCount: 5, dayWindowStart: now + 999999, dayCount: 5 };
  const u = normalizeUsageDoc(doc, now, POLICY);
  assert.equal(u.hourCount, 0);
  assert.equal(u.dayCount, 0);
});

test('normalizeUsageDoc: malformed doc 안전 복구 (13)', () => {
  const now = 10_000_000;
  const u = normalizeUsageDoc(
    { hourCount: 'oops', dayCount: -5, hourWindowStart: NaN, dayWindowStart: null },
    now,
    POLICY,
  );
  assert.equal(u.hourCount, 0);
  assert.equal(u.dayCount, 0);
  assert.equal(u.hourWindowStart, now);
  assert.equal(u.dayWindowStart, now);
});

// ===========================================================================
// evaluateGenerationSlot 순수 결정 (4,5,6,7,8)
// ===========================================================================
test('빈 상태에서 첫 생성은 ALLOW + 카운터 증가', () => {
  const now = 1_000_000;
  const r = evaluateGenerationSlot({
    usageDoc: null,
    leaseDoc: null,
    now,
    policy: POLICY,
    isRefresh: false,
    cacheValid: false,
  });
  assert.equal(r.decision, SLOT_DECISION.ALLOW);
  assert.equal(r.usageUpdate.hourCount, 1);
  assert.equal(r.usageUpdate.dayCount, 1);
  assert.equal(r.usageUpdate.lastAttemptAt, now);
  assert.equal(r.leaseUpdate.leaseExpiresAt, now + POLICY.leaseTtlMs);
});

test('refresh + 유효캐시 + cooldown 미충족 -> RETURN_CACHE, 외부 호출 없음 (4)', () => {
  const now = 1_000_000;
  const r = evaluateGenerationSlot({
    usageDoc: null,
    leaseDoc: { leaseExpiresAt: 0, lastGeneratedAt: now - 1000 }, // 방금 생성됨
    now,
    policy: POLICY,
    isRefresh: true,
    cacheValid: true,
  });
  assert.equal(r.decision, SLOT_DECISION.RETURN_CACHE);
  assert.equal(r.usageUpdate, undefined); // quota 미소비
});

test('refresh + cooldown 지남 -> ALLOW (재생성 허용)', () => {
  const now = 100_000_000;
  const r = evaluateGenerationSlot({
    usageDoc: null,
    leaseDoc: { leaseExpiresAt: 0, lastGeneratedAt: now - POLICY.refreshCooldownMs - 1 },
    now,
    policy: POLICY,
    isRefresh: true,
    cacheValid: true,
  });
  assert.equal(r.decision, SLOT_DECISION.ALLOW);
});

test('입력 변경(cacheValid=false)이면 refresh cooldown 무시하고 신규 생성 (12)', () => {
  const now = 1_000_000;
  const r = evaluateGenerationSlot({
    usageDoc: null,
    leaseDoc: { leaseExpiresAt: 0, lastGeneratedAt: now - 1000 },
    now,
    policy: POLICY,
    isRefresh: false,
    cacheValid: false, // inputHash가 달라진 상황
  });
  assert.equal(r.decision, SLOT_DECISION.ALLOW);
});

test('연속 호출 cooldown 미충족 -> REJECT_COOLDOWN (8)', () => {
  const now = 1_000_000;
  const r = evaluateGenerationSlot({
    usageDoc: { hourCount: 1, dayCount: 1, hourWindowStart: now - 100, dayWindowStart: now - 100, lastAttemptAt: now - 5000 },
    leaseDoc: null,
    now,
    policy: POLICY,
    isRefresh: false,
    cacheValid: false,
  });
  assert.equal(r.decision, SLOT_DECISION.REJECT_COOLDOWN);
});

test('시간당 quota 초과 -> REJECT_HOURLY (6)', () => {
  const now = 1_000_000;
  const r = evaluateGenerationSlot({
    usageDoc: {
      hourCount: POLICY.hourlyLimit,
      dayCount: POLICY.hourlyLimit,
      hourWindowStart: now - 100,
      dayWindowStart: now - 100,
      lastAttemptAt: now - POLICY.cooldownMs - 1,
    },
    leaseDoc: null,
    now,
    policy: POLICY,
    isRefresh: false,
    cacheValid: false,
  });
  assert.equal(r.decision, SLOT_DECISION.REJECT_HOURLY);
});

test('일일 quota 초과 -> REJECT_DAILY (7)', () => {
  const now = 1_000_000;
  const r = evaluateGenerationSlot({
    usageDoc: {
      hourCount: 0, // 시간 window는 여유(리셋 상황 가정)
      dayCount: POLICY.dailyLimit,
      hourWindowStart: now,
      dayWindowStart: now - 100,
      lastAttemptAt: now - POLICY.cooldownMs - 1,
    },
    leaseDoc: null,
    now,
    policy: POLICY,
    isRefresh: false,
    cacheValid: false,
  });
  assert.equal(r.decision, SLOT_DECISION.REJECT_DAILY);
});

test('진행 중 lease가 살아있으면 REJECT_INFLIGHT', () => {
  const now = 1_000_000;
  const r = evaluateGenerationSlot({
    usageDoc: null,
    leaseDoc: { leaseExpiresAt: now + 5000, lastGeneratedAt: 0 },
    now,
    policy: POLICY,
    isRefresh: false,
    cacheValid: false,
  });
  assert.equal(r.decision, SLOT_DECISION.REJECT_INFLIGHT);
});

test('만료된 lease는 takeover 가능(ALLOW)', () => {
  const now = 1_000_000;
  const r = evaluateGenerationSlot({
    usageDoc: null,
    leaseDoc: { leaseExpiresAt: now - 1, lastGeneratedAt: 0 },
    now,
    policy: POLICY,
    isRefresh: false,
    cacheValid: false,
  });
  assert.equal(r.decision, SLOT_DECISION.ALLOW);
});

// ===========================================================================
// resolveSlotOutcome (5,6)
// ===========================================================================
test('resolveSlotOutcome: ALLOW -> GENERATE', () => {
  assert.equal(resolveSlotOutcome(SLOT_DECISION.ALLOW, false), SLOT_OUTCOME.GENERATE);
});
test('resolveSlotOutcome: 거부인데 유효캐시 있으면 RETURN_CACHE (5)', () => {
  assert.equal(resolveSlotOutcome(SLOT_DECISION.RETURN_CACHE, true), SLOT_OUTCOME.RETURN_CACHE);
  assert.equal(resolveSlotOutcome(SLOT_DECISION.REJECT_HOURLY, true), SLOT_OUTCOME.RETURN_CACHE);
});
test('resolveSlotOutcome: 거부인데 캐시 없으면 REJECT (6)', () => {
  assert.equal(resolveSlotOutcome(SLOT_DECISION.REJECT_HOURLY, false), SLOT_OUTCOME.REJECT);
  assert.equal(resolveSlotOutcome(SLOT_DECISION.REJECT_INFLIGHT, false), SLOT_OUTCOME.REJECT);
});

// ===========================================================================
// createAiUsageGuard — 실제 transaction 경로 (10,11,12,14,16)
// ===========================================================================
test('acquireGenerationSlot: 첫 호출 ALLOW, usage/lease 문서 기록', async () => {
  const db = createFakeDb();
  const guard = createAiUsageGuard({ db, policy: POLICY, now: fixedNow(1_000_000) });
  const r = await guard.acquireGenerationSlot({
    callerUid: 'u1',
    targetUid: 't1',
    inputHash: 'h1',
    isRefresh: false,
    cacheValid: false,
  });
  assert.equal(r.decision, SLOT_DECISION.ALLOW);
  assert.equal(r.outcome, SLOT_OUTCOME.GENERATE);
  const usage = db.store.get('_internalAiUsage/u1/functions/generateProfileInsight');
  assert.equal(usage.hourCount, 1);
  assert.equal(usage.dayCount, 1);
});

test('동일 caller+target+inputHash 두 번째 요청은 진행 중 lease로 REJECT_INFLIGHT (11)', async () => {
  const db = createFakeDb();
  const guard = createAiUsageGuard({ db, policy: POLICY, now: fixedNow(1_000_000) });
  const first = await guard.acquireGenerationSlot({ callerUid: 'u1', targetUid: 't1', inputHash: 'h1', isRefresh: false, cacheValid: false });
  assert.equal(first.decision, SLOT_DECISION.ALLOW);
  // 아직 release 전 — lease 살아있음.
  const second = await guard.acquireGenerationSlot({ callerUid: 'u1', targetUid: 't1', inputHash: 'h1', isRefresh: false, cacheValid: false });
  assert.equal(second.decision, SLOT_DECISION.REJECT_INFLIGHT);
  assert.equal(second.outcome, SLOT_OUTCOME.REJECT);
});

test('동시(Promise.all) 동일 inputHash 요청은 정확히 한 번만 ALLOW (10,11)', async () => {
  const db = createFakeDb();
  const guard = createAiUsageGuard({ db, policy: POLICY, now: fixedNow(1_000_000) });
  const results = await Promise.all([
    guard.acquireGenerationSlot({ callerUid: 'u1', targetUid: 't1', inputHash: 'h1', isRefresh: false, cacheValid: false }),
    guard.acquireGenerationSlot({ callerUid: 'u1', targetUid: 't1', inputHash: 'h1', isRefresh: false, cacheValid: false }),
  ]);
  const allowed = results.filter((r) => r.decision === SLOT_DECISION.ALLOW);
  assert.equal(allowed.length, 1);
  // 카운터도 한 번만 증가.
  const usage = db.store.get('_internalAiUsage/u1/functions/generateProfileInsight');
  assert.equal(usage.hourCount, 1);
});

test('다른 inputHash는 독립적으로 각각 ALLOW (12)', async () => {
  const db = createFakeDb();
  let clock = 1_000_000;
  const guard = createAiUsageGuard({ db, policy: POLICY, now: () => clock });
  const a = await guard.acquireGenerationSlot({ callerUid: 'u1', targetUid: 't1', inputHash: 'h1', isRefresh: false, cacheValid: false });
  clock += POLICY.cooldownMs + 1; // 연속 호출 cooldown 통과
  const b = await guard.acquireGenerationSlot({ callerUid: 'u1', targetUid: 't1', inputHash: 'h2', isRefresh: false, cacheValid: false });
  assert.equal(a.decision, SLOT_DECISION.ALLOW);
  // 다른 inputHash라 h1의 진행 중 lease에 걸리지 않고 신규 생성 허용.
  assert.equal(b.decision, SLOT_DECISION.ALLOW);
});

test('시간당 quota 초과까지 반복하면 REJECT (10 - 카운터 원자성)', async () => {
  const db = createFakeDb();
  let clock = 1_000_000;
  const guard = createAiUsageGuard({ db, policy: POLICY, now: () => clock });
  // lease가 막지 않도록 매번 다른 inputHash + cooldown 회피 위해 시계 전진.
  for (let i = 0; i < POLICY.hourlyLimit; i += 1) {
    const r = await guard.acquireGenerationSlot({ callerUid: 'u1', targetUid: 't1', inputHash: `h${i}`, isRefresh: false, cacheValid: false });
    assert.equal(r.decision, SLOT_DECISION.ALLOW, `attempt ${i} should ALLOW`);
    clock += POLICY.cooldownMs + 1; // cooldown 통과
  }
  const over = await guard.acquireGenerationSlot({ callerUid: 'u1', targetUid: 't1', inputHash: 'hX', isRefresh: false, cacheValid: false });
  assert.equal(over.decision, SLOT_DECISION.REJECT_HOURLY);
});

test('다른 UID의 quota는 서로 독립 (14)', async () => {
  const db = createFakeDb();
  let clock = 1_000_000;
  const guard = createAiUsageGuard({ db, policy: POLICY, now: () => clock });
  for (let i = 0; i < POLICY.hourlyLimit; i += 1) {
    await guard.acquireGenerationSlot({ callerUid: 'u1', targetUid: 't1', inputHash: `h${i}`, isRefresh: false, cacheValid: false });
    clock += POLICY.cooldownMs + 1;
  }
  // u1은 초과, u2는 여전히 허용.
  const u1over = await guard.acquireGenerationSlot({ callerUid: 'u1', targetUid: 't1', inputHash: 'hX', isRefresh: false, cacheValid: false });
  assert.equal(u1over.decision, SLOT_DECISION.REJECT_HOURLY);
  const u2 = await guard.acquireGenerationSlot({ callerUid: 'u2', targetUid: 't1', inputHash: 'h0', isRefresh: false, cacheValid: false });
  assert.equal(u2.decision, SLOT_DECISION.ALLOW);
});

test('release(success) 후 refresh는 24h cooldown으로 캐시 반환, 지나면 재생성', async () => {
  const db = createFakeDb();
  let clock = 1_000_000;
  const guard = createAiUsageGuard({ db, policy: POLICY, now: () => clock });
  const first = await guard.acquireGenerationSlot({ callerUid: 'u1', targetUid: 't1', inputHash: 'h1', isRefresh: false, cacheValid: false });
  assert.equal(first.decision, SLOT_DECISION.ALLOW);
  await guard.releaseGenerationSlot({ callerUid: 'u1', targetUid: 't1', inputHash: 'h1', success: true });

  clock += POLICY.cooldownMs + 1; // 연속 cooldown은 통과시키되
  const refreshSoon = await guard.acquireGenerationSlot({ callerUid: 'u1', targetUid: 't1', inputHash: 'h1', isRefresh: true, cacheValid: true });
  assert.equal(refreshSoon.decision, SLOT_DECISION.RETURN_CACHE); // 24h 미경과

  clock += POLICY.refreshCooldownMs; // 24h 경과
  const refreshLater = await guard.acquireGenerationSlot({ callerUid: 'u1', targetUid: 't1', inputHash: 'h1', isRefresh: true, cacheValid: true });
  assert.equal(refreshLater.decision, SLOT_DECISION.ALLOW);
});

test('release(failure)는 lease만 풀고 lastGeneratedAt 미기록(재시도 가능)', async () => {
  const db = createFakeDb();
  const guard = createAiUsageGuard({ db, policy: POLICY, now: fixedNow(1_000_000) });
  await guard.acquireGenerationSlot({ callerUid: 'u1', targetUid: 't1', inputHash: 'h1', isRefresh: false, cacheValid: false });
  await guard.releaseGenerationSlot({ callerUid: 'u1', targetUid: 't1', inputHash: 'h1', success: false });
  const leaseId = buildLeaseId(POLICY.functionName, 'u1', 't1', 'h1');
  const lease = db.store.get(`_internalAiLeases/${leaseId}`);
  assert.equal(lease.leaseExpiresAt, 0); // 해제됨
  assert.ok(!lease.lastGeneratedAt); // 성공 아님 -> 미기록
});

test('로그에 raw uid/target/email/phone 미포함, uidHash만 (16)', async () => {
  const records = [];
  const logger = { log: (m) => records.push(String(m)) };
  const db = createFakeDb();
  const guard = createAiUsageGuard({ db, policy: POLICY, now: fixedNow(1_000_000), logger });
  await guard.acquireGenerationSlot({
    callerUid: 'caller-uid-secret',
    targetUid: 'target-uid-secret',
    inputHash: 'h1',
    isRefresh: false,
    cacheValid: false,
  });
  assert.ok(records.length > 0);
  const joined = records.join('\n');
  assert.ok(!joined.includes('caller-uid-secret'));
  assert.ok(!joined.includes('target-uid-secret'));
  assert.match(joined, /uidHash=[0-9a-f]{8}/);
});

// ===========================================================================
// 품질 보존 가드레일 — index.js의 모델/프롬프트/generation 파라미터 미변경 (17,18)
// ===========================================================================
test('index.js: profile insight 모델/파라미터/프롬프트 불변식 유지 (17,18)', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'index.js'), 'utf8');
  assert.ok(src.includes("const PROFILE_INSIGHT_MODEL = 'gpt-4o';"), '모델 ID gpt-4o 유지');
  assert.ok(src.includes('temperature: 0.6,'), 'temperature 0.6 유지');
  assert.ok(src.includes("response_format: { type: 'json_object' }"), 'json_object response_format 유지');
  assert.ok(src.includes("detail: 'low',"), 'vision 이미지 detail low 유지');
  // 시스템 프롬프트 핵심 문장 유지.
  assert.ok(src.includes('비외모적 첫인상과 대화 힌트를 분석하는 카피라이터'), 'system prompt 유지');
  assert.ok(
    src.includes('{"firstImpression": string, "conversationStyle": string, "atmosphere": string, "goodMatchType": string}'),
    '응답 JSON 스키마 유지',
  );
});
