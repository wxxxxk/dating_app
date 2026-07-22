'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const {
  MATCH_TEXT_AI_USAGE_POLICIES,
  SELF_TEXT_AI_USAGE_POLICIES,
  CHARM_REPORT_USAGE_POLICY,
  SLOT_DECISION,
  buildLeaseId,
  createAiUsageGuard,
} = require('../lib/ai_usage_guard');

const TEXT_POLICIES = Object.freeze({
  generateFortuneNarrative: SELF_TEXT_AI_USAGE_POLICIES.generateFortuneNarrative,
  generateMatchNarrative: MATCH_TEXT_AI_USAGE_POLICIES.generateMatchNarrative,
  generateIcebreakers: MATCH_TEXT_AI_USAGE_POLICIES.generateIcebreakers,
  generateConversationTips: MATCH_TEXT_AI_USAGE_POLICIES.generateConversationTips,
  generateDailyFortune: SELF_TEXT_AI_USAGE_POLICIES.generateDailyFortune,
  generateCharmReport: CHARM_REPORT_USAGE_POLICY,
});

const MATCH_FUNCTIONS = [
  'generateMatchNarrative',
  'generateIcebreakers',
  'generateConversationTips',
];
const SELF_FUNCTIONS = [
  'generateFortuneNarrative',
  'generateDailyFortune',
  'generateCharmReport',
];

function createFakeDb(initial = {}) {
  const store = new Map(Object.entries(initial));
  const versions = new Map();
  const versionOf = (p) => versions.get(p) || 0;
  const snap = (p) => {
    const data = store.get(p);
    return { exists: data !== undefined, data: () => data };
  };
  const applySet = (p, data, opts) => {
    const prev = opts && opts.merge ? store.get(p) || {} : {};
    store.set(p, { ...prev, ...data });
    versions.set(p, versionOf(p) + 1);
  };
  const docRef = (p) => ({
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
  });
  const collRef = (p) => ({ doc: (id) => docRef(`${p}/${id}`) });

  return {
    store,
    collection: (name) => collRef(name),
    async runTransaction(fn) {
      for (let attempt = 0; attempt < 8; attempt += 1) {
        const reads = new Map();
        const writes = [];
        const tx = {
          async get(ref) {
            reads.set(ref.path, versionOf(ref.path));
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
        if (conflict) continue;
        for (const w of writes) applySet(w.path, w.data, w.opts);
        return result;
      }
      throw new Error('fake transaction exceeded max attempts');
    },
  };
}

function source() {
  return fs.readFileSync(path.join(__dirname, '..', 'index.js'), 'utf8');
}

function functionSlice(src, exportName) {
  const start = src.indexOf(`exports.${exportName} = onCall(`);
  assert.ok(start >= 0, `${exportName} export not found`);
  const next = src.indexOf('\nexports.', start + 1);
  return src.slice(start, next === -1 ? src.length : next);
}

function countOpenAiCallsFor(fnSrc) {
  return (fnSrc.match(/callOpenAiForNarrative\(/g) || []).length;
}

test('text AI usage policies are separated and match required quotas', () => {
  for (const fn of MATCH_FUNCTIONS) {
    const p = TEXT_POLICIES[fn];
    assert.equal(p.functionName, fn);
    assert.equal(p.hourlyLimit, 12);
    assert.equal(p.dailyLimit, 40);
    assert.equal(p.cooldownMs, 10 * 1000);
    assert.equal(p.leaseTtlMs, 90 * 1000);
  }
  {
    const p = TEXT_POLICIES.generateFortuneNarrative;
    assert.equal(p.functionName, 'generateFortuneNarrative');
    assert.equal(p.hourlyLimit, 10);
    assert.equal(p.dailyLimit, 20);
    assert.equal(p.cooldownMs, 10 * 1000);
    assert.equal(p.leaseTtlMs, 90 * 1000);
  }
  {
    // 최근 7일 운세 backfill이 미캐시 날짜를 연속 호출하므로 cooldown은 0이고,
    // 시간당/일일 quota로만 총 호출량을 제한한다.
    const p = TEXT_POLICIES.generateDailyFortune;
    assert.equal(p.functionName, 'generateDailyFortune');
    assert.equal(p.hourlyLimit, 10);
    assert.equal(p.dailyLimit, 20);
    assert.equal(p.cooldownMs, 0);
    assert.equal(p.leaseTtlMs, 90 * 1000);
  }
  assert.equal(CHARM_REPORT_USAGE_POLICY.hourlyLimit, 6);
  assert.equal(CHARM_REPORT_USAGE_POLICY.dailyLimit, 15);
  assert.equal(CHARM_REPORT_USAGE_POLICY.cooldownMs, 20 * 1000);
});

test('all target callables keep unauthenticated guard', () => {
  const src = source();
  for (const fn of Object.keys(TEXT_POLICIES)) {
    assert.ok(functionSlice(src, fn).includes("HttpsError('unauthenticated'"));
  }
});

test('self functions use request.auth.uid and do not trust caller-provided uid', () => {
  const src = source();
  for (const fn of SELF_FUNCTIONS) {
    const fnSrc = functionSlice(src, fn);
    assert.ok(fnSrc.includes('request.auth.uid'));
    assert.ok(!fnSrc.includes('request.data?.uid'));
    assert.ok(!fnSrc.includes('request.data?.targetUid'));
  }
});

test('match functions keep participant verification and inactive match rejection', () => {
  const src = source();
  for (const fn of MATCH_FUNCTIONS) {
    const fnSrc = functionSlice(src, fn);
    assert.ok(fnSrc.includes('assertActiveMatchParticipant({'));
    assert.ok(fnSrc.includes(`fn: '${fn}'`));
  }
  assert.ok(src.includes('isUnmatchedMatchData(matchData)'));
  assert.ok(src.includes("HttpsError('failed-precondition', '이미 종료된 매치입니다.')"));
});

test('cache hit returns before text AI guard acquisition', () => {
  const src = source();
  for (const fn of Object.keys(TEXT_POLICIES)) {
    const fnSrc = functionSlice(src, fn);
    const cacheIdx = [
      'return cached',
      'return { narrative: cached, participantAttrs }',
      'return snap.data()',
      'return { icebreakers: cached }',
      'return conversationTipsResponse(cachedItems, latestMessageId)',
    ].map((needle) => fnSrc.indexOf(needle)).filter((idx) => idx >= 0)[0];
    const guardIdx = fnSrc.indexOf('acquireTextAiGenerationSlot({');
    assert.ok(cacheIdx >= 0, `${fn} cache return missing`);
    assert.ok(guardIdx > cacheIdx, `${fn} guard should run after cache hit return`);
  }
});

test('generateMatchNarrative accepts only matchId and ignores client attrs', () => {
  const fnSrc = functionSlice(source(), 'generateMatchNarrative');
  assert.ok(fnSrc.includes("const { matchId } = payload"));
  assert.ok(fnSrc.includes("key !== 'matchId'"));
  assert.ok(fnSrc.includes("HttpsError('invalid-argument', '지원하지 않는 요청 필드입니다.')"));
  assert.ok(!fnSrc.includes('request.data?.userA'));
  assert.ok(!fnSrc.includes('request.data?.userB'));
  assert.ok(!fnSrc.includes('const { matchId, userA, userB } = request.data'));
});

test('generateMatchNarrative verifies active match and blocks before birthDate read', () => {
  const fnSrc = functionSlice(source(), 'generateMatchNarrative');
  const participantIdx = fnSrc.indexOf('assertActiveMatchParticipant({');
  const blockIdx = fnSrc.indexOf('assertNoMatchBlocks({');
  const attrsIdx = fnSrc.indexOf('readMatchParticipantAttrs({');
  assert.ok(participantIdx >= 0);
  assert.ok(blockIdx > participantIdx);
  assert.ok(attrsIdx > blockIdx);
  // Phase 5-2: 출생시간 필드까지 읽되, 여전히 최소 fieldMask만 사용한다.
  const maskMatch = source().match(/db\.getAll\(\.\.\.refs, \{\s*fieldMask: \[([\s\S]*?)\],?\s*\}\)/);
  assert.ok(maskMatch, 'readMatchParticipantAttrs가 fieldMask를 쓰지 않는다');
  const maskFields = maskMatch[1].match(/'[^']+'/g).map((f) => f.replace(/'/g, ''));
  assert.deepEqual(maskFields.sort(), [
    'birthCalendarType',
    'birthDate',
    'birthTimeKnown',
    'birthTimeMinutes',
    'birthTimeZone',
  ]);
});

test('generateMatchNarrative returns derived attrs and does not log raw birthDate', () => {
  const src = source();
  const fnSrc = functionSlice(src, 'generateMatchNarrative');
  assert.ok(fnSrc.includes('return { narrative: cached, participantAttrs }'));
  assert.ok(fnSrc.includes('return { narrative, participantAttrs }'));
  assert.ok(src.includes('participantHash: safeUidHash(uid)'));
  assert.ok(!fnSrc.includes('birthDate'));
  assert.ok(!src.includes('console.log(birthDate'));
  assert.ok(!src.includes('console.warn(birthDate'));
  assert.ok(!src.includes('console.error(birthDate'));
});

test('target fortune callables persist deterministic fallback on model failure', () => {
  const src = source();
  const expected = {
    generateFortuneNarrative: 'buildFallbackFortuneNarrative(attrs)',
    generateMatchNarrative: 'buildFallbackMatchNarrative({ firstAttrs: userA, secondAttrs: userB })',
    generateDailyFortune: 'buildFallbackDailyFortune({ date, attrs })',
    generateCharmReport: 'buildFallbackCharmReport(data)',
  };
  for (const [fn, fallback] of Object.entries(expected)) {
    const fnSrc = functionSlice(src, fn);
    assert.ok(fnSrc.includes("'model_failed'"), `${fn} missing model_failed log`);
    assert.ok(fnSrc.includes("'generated_fallback'"), `${fn} missing fallback log`);
    assert.ok(fnSrc.includes(fallback), `${fn} missing fallback builder`);
  }
});

test('OpenAI call starts only after guard acquisition and is released in finally', () => {
  const src = source();
  for (const fn of Object.keys(TEXT_POLICIES)) {
    const fnSrc = functionSlice(src, fn);
    const guardIdx = fnSrc.indexOf('acquireTextAiGenerationSlot({');
    const openAiIdx = fnSrc.indexOf('callOpenAiForNarrative({');
    const finallyIdx = fnSrc.indexOf('} finally {');
    const releaseIdx = fnSrc.indexOf('releaseTextAiGenerationSlot({');
    assert.ok(openAiIdx > guardIdx, `${fn} OpenAI before guard`);
    assert.ok(finallyIdx > openAiIdx, `${fn} missing finally after OpenAI`);
    assert.ok(releaseIdx > finallyIdx, `${fn} missing release in finally`);
    assert.equal(countOpenAiCallsFor(fnSrc), 1);
  }
});

test('hourly quota is enforced per function policy', async () => {
  for (const [fn, policy] of Object.entries(TEXT_POLICIES)) {
    const db = createFakeDb();
    let clock = 1_000_000;
    const guard = createAiUsageGuard({ db, policy, now: () => clock });
    for (let i = 0; i < policy.hourlyLimit; i += 1) {
      const r = await guard.acquireGenerationSlot({
        callerUid: 'u1',
        targetUid: 'm1',
        inputHash: `h${i}`,
        isRefresh: false,
        cacheValid: false,
      });
      assert.equal(r.decision, SLOT_DECISION.ALLOW, `${fn} ${i}`);
      clock += policy.cooldownMs + 1;
    }
    const over = await guard.acquireGenerationSlot({
      callerUid: 'u1',
      targetUid: 'm1',
      inputHash: 'over',
      isRefresh: false,
      cacheValid: false,
    });
    assert.equal(over.decision, SLOT_DECISION.REJECT_HOURLY, fn);
  }
});

test('daily quota is enforced per function policy', async () => {
  for (const [fn, policy] of Object.entries(TEXT_POLICIES)) {
    const clock = 1_000_000;
    const db = createFakeDb({
      [`_internalAiUsage/u1/functions/${fn}`]: {
        hourWindowStart: clock,
        hourCount: 0,
        dayWindowStart: clock,
        dayCount: policy.dailyLimit,
        lastAttemptAt: clock - policy.cooldownMs - 1,
      },
    });
    const guard = createAiUsageGuard({ db, policy, now: () => clock });
    const over = await guard.acquireGenerationSlot({
      callerUid: 'u1',
      targetUid: 'm1',
      inputHash: 'over',
      isRefresh: false,
      cacheValid: false,
    });
    assert.equal(over.decision, SLOT_DECISION.REJECT_DAILY, fn);
  }
});

test('cooldown, window rollover, malformed usage are safe', async () => {
  // generateDailyFortune는 backfill을 위해 cooldown이 0이므로, cooldown 로직 자체는
  // cooldown이 남아있는 generateFortuneNarrative 정책으로 검증한다.
  const policy = TEXT_POLICIES.generateFortuneNarrative;
  let clock = 1_000_000;
  const db = createFakeDb();
  const guard = createAiUsageGuard({ db, policy, now: () => clock });
  assert.equal((await guard.acquireGenerationSlot({
    callerUid: 'u1', targetUid: null, inputHash: 'h1', isRefresh: false, cacheValid: false,
  })).decision, SLOT_DECISION.ALLOW);
  assert.equal((await guard.acquireGenerationSlot({
    callerUid: 'u1', targetUid: null, inputHash: 'h2', isRefresh: false, cacheValid: false,
  })).decision, SLOT_DECISION.REJECT_COOLDOWN);

  clock += policy.hourMs + 1;
  assert.equal((await guard.acquireGenerationSlot({
    callerUid: 'u1', targetUid: null, inputHash: 'h3', isRefresh: false, cacheValid: false,
  })).decision, SLOT_DECISION.ALLOW);

  const malformedDb = createFakeDb({
    '_internalAiUsage/u2/functions/generateFortuneNarrative': {
      hourCount: 'bad',
      dayCount: -1,
      hourWindowStart: NaN,
      dayWindowStart: null,
    },
  });
  const malformedGuard = createAiUsageGuard({ db: malformedDb, policy, now: () => 2_000_000 });
  assert.equal((await malformedGuard.acquireGenerationSlot({
    callerUid: 'u2', targetUid: null, inputHash: 'h1', isRefresh: false, cacheValid: false,
  })).decision, SLOT_DECISION.ALLOW);
});

test('different UID and different function counters are independent', async () => {
  const policyA = TEXT_POLICIES.generateFortuneNarrative;
  const policyB = TEXT_POLICIES.generateDailyFortune;
  const db = createFakeDb();
  let clock = 1_000_000;
  const guardA = createAiUsageGuard({ db, policy: policyA, now: () => clock });
  const guardB = createAiUsageGuard({ db, policy: policyB, now: () => clock });
  for (let i = 0; i < policyA.hourlyLimit; i += 1) {
    await guardA.acquireGenerationSlot({
      callerUid: 'u1', targetUid: null, inputHash: `h${i}`, isRefresh: false, cacheValid: false,
    });
    clock += policyA.cooldownMs + 1;
  }
  assert.equal((await guardA.acquireGenerationSlot({
    callerUid: 'u1', targetUid: null, inputHash: 'over', isRefresh: false, cacheValid: false,
  })).decision, SLOT_DECISION.REJECT_HOURLY);
  assert.equal((await guardA.acquireGenerationSlot({
    callerUid: 'u2', targetUid: null, inputHash: 'h0', isRefresh: false, cacheValid: false,
  })).decision, SLOT_DECISION.ALLOW);
  assert.equal((await guardB.acquireGenerationSlot({
    callerUid: 'u1', targetUid: null, inputHash: 'h0', isRefresh: false, cacheValid: false,
  })).decision, SLOT_DECISION.ALLOW);
});

test('same request concurrency allows one OpenAI attempt only', async () => {
  const policy = TEXT_POLICIES.generateConversationTips;
  const db = createFakeDb();
  const guard = createAiUsageGuard({ db, policy, now: () => 1_000_000 });
  const results = await Promise.all([
    guard.acquireGenerationSlot({ callerUid: 'u1', targetUid: 'm1', inputHash: 'h1', isRefresh: false, cacheValid: false }),
    guard.acquireGenerationSlot({ callerUid: 'u1', targetUid: 'm1', inputHash: 'h1', isRefresh: false, cacheValid: false }),
  ]);
  assert.equal(results.filter((r) => r.decision === SLOT_DECISION.ALLOW).length, 1);
  const usage = db.store.get('_internalAiUsage/u1/functions/generateConversationTips');
  assert.equal(usage.hourCount, 1);
});

test('different inputHash and different match are independent leases', async () => {
  const policy = TEXT_POLICIES.generateIcebreakers;
  const db = createFakeDb();
  let clock = 1_000_000;
  const guard = createAiUsageGuard({ db, policy, now: () => clock });
  assert.equal((await guard.acquireGenerationSlot({
    callerUid: 'u1', targetUid: 'm1', inputHash: 'h1', isRefresh: false, cacheValid: false,
  })).decision, SLOT_DECISION.ALLOW);
  clock += policy.cooldownMs + 1;
  assert.equal((await guard.acquireGenerationSlot({
    callerUid: 'u1', targetUid: 'm1', inputHash: 'h2', isRefresh: false, cacheValid: false,
  })).decision, SLOT_DECISION.ALLOW);
  clock += policy.cooldownMs + 1;
  assert.equal((await guard.acquireGenerationSlot({
    callerUid: 'u1', targetUid: 'm2', inputHash: 'h1', isRefresh: false, cacheValid: false,
  })).decision, SLOT_DECISION.ALLOW);
});

test('lease TTL takeover works', async () => {
  const policy = TEXT_POLICIES.generateMatchNarrative;
  const db = createFakeDb();
  let clock = 1_000_000;
  const guard = createAiUsageGuard({ db, policy, now: () => clock });
  await guard.acquireGenerationSlot({
    callerUid: 'u1', targetUid: 'm1', inputHash: 'h1', isRefresh: false, cacheValid: false,
  });
  clock += policy.leaseTtlMs + 1;
  assert.equal((await guard.acquireGenerationSlot({
    callerUid: 'u1', targetUid: 'm1', inputHash: 'h1', isRefresh: false, cacheValid: false,
  })).decision, SLOT_DECISION.ALLOW);
});

test('OpenAI failure consumes attempt and does not mark successful cache generation', async () => {
  const policy = TEXT_POLICIES.generateCharmReport;
  const db = createFakeDb();
  const guard = createAiUsageGuard({ db, policy, now: () => 1_000_000 });
  await guard.acquireGenerationSlot({
    callerUid: 'u1', targetUid: null, inputHash: 'h1', isRefresh: false, cacheValid: false,
  });
  await guard.releaseGenerationSlot({
    callerUid: 'u1', targetUid: null, inputHash: 'h1', success: false,
  });
  const usage = db.store.get('_internalAiUsage/u1/functions/generateCharmReport');
  assert.equal(usage.hourCount, 1);
  const leaseId = buildLeaseId(policy.functionName, 'u1', null, 'h1');
  const lease = db.store.get(`_internalAiLeases/${leaseId}`);
  assert.equal(lease.leaseExpiresAt, 0);
  assert.ok(!lease.lastGeneratedAt);
});

test('refresh cannot bypass guard and frequent refresh returns valid cache', async () => {
  const policy = TEXT_POLICIES.generateCharmReport;
  const db = createFakeDb();
  let clock = 1_000_000;
  const guard = createAiUsageGuard({ db, policy, now: () => clock });
  await guard.acquireGenerationSlot({
    callerUid: 'u1', targetUid: null, inputHash: 'h1', isRefresh: true, cacheValid: true,
  });
  await guard.releaseGenerationSlot({
    callerUid: 'u1', targetUid: null, inputHash: 'h1', success: true,
  });
  clock += policy.cooldownMs + 1;
  const refresh = await guard.acquireGenerationSlot({
    callerUid: 'u1', targetUid: null, inputHash: 'h1', isRefresh: true, cacheValid: true,
  });
  assert.equal(refresh.decision, SLOT_DECISION.RETURN_CACHE);
});

test('malformed cache is not accepted as cache hit', () => {
  const src = source();
  // Phase 5-2: 스키마·문구 버전에 더해 출생정보 지문까지 일치해야 캐시 hit이다.
  const fortuneSlice = functionSlice(src, 'generateFortuneNarrative');
  assert.ok(fortuneSlice.includes('isValidNarrative(cached)'));
  assert.ok(fortuneSlice.includes('isCurrentTextContent(cached)'));
  // Phase 5-3: evidenceVersion까지 일치해야 hit이다.
  assert.ok(
    fortuneSlice.includes(
      "isCurrentSajuCache(cached, profile, { requireEvidenceVersion: true })",
    ),
  );
  const dailySlice = functionSlice(src, 'generateDailyFortune');
  assert.ok(dailySlice.includes('isValidDailyFortune(snap.data())'));
  assert.ok(dailySlice.includes('isCurrentTextContent(snap.data())'));
  assert.ok(dailySlice.includes('isCurrentSajuCache(snap.data(), profile)'));
  const matchSlice = functionSlice(src, 'generateMatchNarrative');
  assert.ok(matchSlice.includes('isValidNarrative(cached)'));
  assert.ok(matchSlice.includes('isCurrentTextContent(cached)'));
  // 궁합은 두 참가자 지문 + evidenceVersion까지 확인한다.
  assert.ok(matchSlice.includes('isCurrentMatchEvidenceCache(cached, matchEvidenceMetadata)'));
  assert.ok(functionSlice(src, 'generateCharmReport').includes('if (!refresh && isValidCharmReport(cached) && isCurrentTextContent(cached))'));
  assert.ok(functionSlice(src, 'generateIcebreakers').includes('if (isValidIcebreakerList(cached))'));
  // v2: tone 3종 계약 + suggestionVersion까지 확인해야 hit이다.
  assert.ok(functionSlice(src, 'generateConversationTips').includes('readConversationTipsCache(matchData.conversationTips'));
});

test('text content version stamps caches and old caches miss', () => {
  const src = source();
  assert.ok(src.includes('const TEXT_CONTENT_VERSION = 2;'));
  // 4개 텍스트 결과 저장 경로 모두 contentVersion을 찍는다.
  assert.ok(functionSlice(src, 'generateFortuneNarrative').includes('narrative.contentVersion = TEXT_CONTENT_VERSION;'));
  assert.ok(functionSlice(src, 'generateMatchNarrative').includes('narrative.contentVersion = TEXT_CONTENT_VERSION;'));
  assert.ok(functionSlice(src, 'generateDailyFortune').includes('fortune.contentVersion = TEXT_CONTENT_VERSION;'));
  assert.ok(functionSlice(src, 'generateCharmReport').includes('report.contentVersion = TEXT_CONTENT_VERSION;'));
  // charm refresh cooldown 판정도 현재 버전 캐시만 유효로 본다.
  assert.ok(functionSlice(src, 'generateCharmReport').includes('const cacheValid = isValidCharmReport(cached) && isCurrentTextContent(cached);'));
  // 버전 헬퍼는 정확히 contentVersion === TEXT_CONTENT_VERSION만 통과시킨다.
  assert.ok(src.includes('return !!value && value.contentVersion === TEXT_CONTENT_VERSION;'));
});

test('generateMatchNarrative uses the returned active participants list', () => {
  const fnSrc = functionSlice(source(), 'generateMatchNarrative');
  // 반환값을 버리지 않고 participants로 받아 이후 검증/조회에 실제로 쓴다.
  assert.ok(fnSrc.includes('const participants = assertActiveMatchParticipant({'));
  const assignIdx = fnSrc.indexOf('const participants = assertActiveMatchParticipant({');
  assert.ok(fnSrc.indexOf('participants,\n      callerUid', assignIdx) > assignIdx);
  assert.ok(fnSrc.includes('const [uidA, uidB] = participants;'));
});

test('fallback charm first impression never appends 이 to a raw label', () => {
  const src = source();
  const start = src.indexOf('function buildFallbackCharmReport(');
  const end = src.indexOf('exports.generateCharmReport = onCall(', start + 1);
  assert.ok(start >= 0 && end > start);
  const fnSrc = src.slice(start, end);
  // "아담한이 자연스럽게…" 를 만들던 raw label + '이' 연결을 완전히 제거한다.
  assert.ok(!fnSrc.includes('이 자연스럽게 전해지는 프로필이에요'));
  assert.ok(!fnSrc.includes('${firstSignal}'));
  // 외모/이상형 계열 key는 성격 첫인상 근거에서 제외한다.
  assert.ok(src.includes('const APPEARANCE_OR_IDEAL_TAG_KEYS = new Set(['));
  assert.ok(src.includes("'petite'"));
  assert.ok(src.includes("'good_looking'"));
  assert.ok(src.includes('function personalitySignalLabels('));
  assert.ok(fnSrc.includes('personalitySignalLabels(data?.personalityTags)'));
});

test('text AI logs do not include raw uid, matchId, prompt, response, or error.message', () => {
  const src = source();
  const start = src.indexOf('const TEXT_AI_RATE_LIMIT_MESSAGE');
  const end = src.indexOf('// ============================================================================\n// M8: 매력 리포트');
  const textSection = src.slice(start, end);
  assert.ok(!textSection.includes('error?.message'));
  assert.ok(!textSection.includes('error.message'));
  assert.ok(!textSection.includes('raw:'));
  assert.ok(!textSection.includes('sanitized:'));
  assert.ok(!textSection.includes('uid: request.auth.uid'));
  assert.ok(!textSection.includes("console.log('[generate"));
  assert.ok(!textSection.includes("console.warn('[generate"));
  assert.ok(!textSection.includes("console.error('[generate"));
});

test('result JSON schemas are unchanged', () => {
  const src = source();
  for (const schema of [
    '{"characterType": string, "summary": string, "reasons"',
    '"relationshipStory": null',
    '"relationshipStory": string',
    '{"icebreakers": [{"topic": string, "message": string}]}',
    '{"suggestions":[',
    '{"id":"natural","tone":"natural","text":"..."},',
    '{"loveScore": number, "mood": string, "message": string, "advice": string}',
    '{"firstImpression": string, "charmPoints": [{"title": string, "description": string}], "appealTip": string}',
  ]) {
    assert.ok(src.includes(schema), schema);
  }
});

test('model and generation settings are unchanged for text AI', () => {
  const src = source();
  assert.ok(src.includes("const FORTUNE_MODEL = 'gpt-4o-mini';"));
  const callStart = src.indexOf('async function callOpenAiForNarrative');
  const callEnd = src.indexOf('/**\n * 내 사주 서사 생성', callStart);
  const callSrc = src.slice(callStart, callEnd);
  assert.ok(callSrc.includes('model: FORTUNE_MODEL,'));
  assert.ok(callSrc.includes("response_format: { type: 'json_object' },"));
  assert.ok(callSrc.includes('temperature: 0.8,'));
  assert.ok(!callSrc.includes('max_tokens'));
  assert.ok(!callSrc.includes('top_p'));
});

test('profile insight and ideal image guard tests remain present', () => {
  assert.ok(fs.existsSync(path.join(__dirname, 'profile_insight_access.test.js')));
  assert.ok(fs.existsSync(path.join(__dirname, 'ideal_type_image_guard.test.js')));
  assert.ok(fs.existsSync(path.join(__dirname, 'ai_usage_guard.test.js')));
});

// 이 가드는 phase 단위로 갱신한다 — 현재 작업 중인 phase가 손대도 되는
// Flutter 파일 범위를 고정해, 관련 없는 화면이 함께 바뀌는 것을 막는다.
// 현재 기준: Phase 5-2A (출생시간 미상 경계 처리 및 절기 독립 검증).
test('no unrelated Flutter or production configuration files are changed for this phase', () => {
  const changed = require('child_process')
    .execFileSync('git', ['diff', '--name-only'], { cwd: path.join(__dirname, '..', '..') })
    .toString()
    .trim()
    .split('\n')
    .filter(Boolean);
  const allowedFlutterFiles = new Set([
    'lib/features/charm/charm_report_screen.dart',
    // 1-C: 대화 이어가기 복구·보정 대상.
    'lib/features/chat/chat_screen.dart',
    'lib/features/fortune/fortune_history_screen.dart',
    'lib/features/fortune/fortune_hub_screen.dart',
    'lib/features/fortune/match_fortune_screen.dart',
    'lib/features/fortune/my_fortune_screen.dart',
    'lib/features/fortune/widgets/saju_precision_notice.dart',
    'lib/features/home/home_screen.dart',
    'lib/features/onboarding/basic_info_step.dart',
    'lib/features/onboarding/onboarding_screen.dart',
    'lib/models/fortune/saju_convention.dart',
    'lib/models/fortune_model.dart',
    'lib/models/user_profile.dart',
    'lib/services/database/firestore_service.dart',
    'lib/services/fortune/fortune_calculator.dart',
    'lib/services/fortune/fortune_service.dart',
  ]);
  assert.deepEqual(
    changed.filter((file) => file.startsWith('lib/') && !allowedFlutterFiles.has(file)),
    [],
  );
  assert.ok(!changed.includes('firebase.json'));
  assert.ok(!changed.includes('storage.rules'));
});
