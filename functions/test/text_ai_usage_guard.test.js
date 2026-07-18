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
  for (const fn of ['generateFortuneNarrative', 'generateDailyFortune']) {
    const p = TEXT_POLICIES[fn];
    assert.equal(p.functionName, fn);
    assert.equal(p.hourlyLimit, 10);
    assert.equal(p.dailyLimit, 20);
    assert.equal(p.cooldownMs, 10 * 1000);
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
      'return snap.data()',
      'return { icebreakers: cached }',
      'return { suggestions: cached.suggestions }',
    ].map((needle) => fnSrc.indexOf(needle)).filter((idx) => idx >= 0)[0];
    const guardIdx = fnSrc.indexOf('acquireTextAiGenerationSlot({');
    assert.ok(cacheIdx >= 0, `${fn} cache return missing`);
    assert.ok(guardIdx > cacheIdx, `${fn} guard should run after cache hit return`);
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
  const policy = TEXT_POLICIES.generateDailyFortune;
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
    '_internalAiUsage/u2/functions/generateDailyFortune': {
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
  assert.ok(functionSlice(src, 'generateFortuneNarrative').includes('if (isValidNarrative(cached)) return cached;'));
  assert.ok(functionSlice(src, 'generateDailyFortune').includes('if (isValidDailyFortune(snap.data())) return snap.data();'));
  assert.ok(functionSlice(src, 'generateCharmReport').includes('if (!refresh && isValidCharmReport(cached)) return cached;'));
  assert.ok(functionSlice(src, 'generateIcebreakers').includes('if (isValidIcebreakerList(cached))'));
  assert.ok(functionSlice(src, 'generateConversationTips').includes('isValidConversationSuggestions(cached?.suggestions)'));
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
    '{"suggestions": [string, string, string]}',
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

test('no Flutter or unrelated production configuration files are changed for this phase', () => {
  const changed = require('child_process')
    .execFileSync('git', ['diff', '--name-only'], { cwd: path.join(__dirname, '..', '..') })
    .toString()
    .trim()
    .split('\n')
    .filter(Boolean);
  assert.deepEqual(
    changed.filter((file) => file.startsWith('lib/')),
    [
      'lib/features/jelly/jelly_shop_screen.dart',
      'lib/services/jelly/jelly_purchase_service.dart',
    ],
  );
  assert.ok(!changed.includes('firebase.json'));
  assert.ok(!changed.includes('storage.rules'));
});
