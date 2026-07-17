'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const {
  IDEAL_TYPE_IMAGE_USAGE_POLICY,
  PROFILE_INSIGHT_USAGE_POLICY,
  SLOT_DECISION,
  SLOT_OUTCOME,
  buildLeaseId,
  createAiUsageGuard,
} = require('../lib/ai_usage_guard');

const POLICY = IDEAL_TYPE_IMAGE_USAGE_POLICY;

// ---------------------------------------------------------------------------
// Fake Firestore — path 기반 in-memory + optimistic concurrency (실제 tx 의미).
// ---------------------------------------------------------------------------
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

// ===========================================================================
// 정책 상수 (2 — 정책 분리)
// ===========================================================================
test('IDEAL_TYPE_IMAGE_USAGE_POLICY 값: 시간당6/일일15/cooldown20s/lease180s', () => {
  assert.equal(POLICY.functionName, 'generateIdealTypeImage');
  assert.equal(POLICY.hourlyLimit, 6);
  assert.equal(POLICY.dailyLimit, 15);
  assert.equal(POLICY.cooldownMs, 20 * 1000);
  assert.equal(POLICY.leaseTtlMs, 180 * 1000);
});

test('profile insight 정책과 분리되어 있다', () => {
  assert.notEqual(POLICY.functionName, PROFILE_INSIGHT_USAGE_POLICY.functionName);
  assert.notEqual(POLICY.hourlyLimit, PROFILE_INSIGHT_USAGE_POLICY.hourlyLimit);
});

// ===========================================================================
// buildLeaseId — 명확한 deterministic encoding, self(null target)
// ===========================================================================
test('buildLeaseId: null targetUid deterministic, raw uid 미노출', () => {
  const a = buildLeaseId('generateIdealTypeImage', 'caller-secret', null, 'h1');
  const b = buildLeaseId('generateIdealTypeImage', 'caller-secret', null, 'h1');
  assert.equal(a, b);
  assert.match(a, /^[0-9a-f]{64}$/);
  assert.ok(!a.includes('caller-secret'));
});

test('buildLeaseId: 함수명이 다르면 lease ID도 다름(정책 분리)', () => {
  const ideal = buildLeaseId('generateIdealTypeImage', 'u1', null, 'h1');
  const insight = buildLeaseId('generateProfileInsight', 'u1', 't1', 'h1');
  assert.notEqual(ideal, insight);
});

test('buildLeaseId: JSON 인코딩이라 결합 모호성 없음', () => {
  // 공백 join이었다면 ("a b","c") 와 ("a","b c") 가 뭉개질 수 있다. JSON 인코딩은 구분.
  const x = buildLeaseId('fn', 'a b', 'c', 'h');
  const y = buildLeaseId('fn', 'a', 'b c', 'h');
  assert.notEqual(x, y);
});

// ===========================================================================
// guard 동작 — ideal 정책 (7,8,9,10,11,12,13,14,15,18)
// ===========================================================================
test('첫 호출 ALLOW, 이후 동일 inputHash 진행 중 lease로 REJECT(중복 방지) (12)', async () => {
  const db = createFakeDb();
  const guard = createAiUsageGuard({ db, policy: POLICY, now: () => 1_000_000 });
  const first = await guard.acquireGenerationSlot({ callerUid: 'u1', targetUid: null, inputHash: 'h1', isRefresh: false, cacheValid: false });
  assert.equal(first.decision, SLOT_DECISION.ALLOW);
  const second = await guard.acquireGenerationSlot({ callerUid: 'u1', targetUid: null, inputHash: 'h1', isRefresh: false, cacheValid: false });
  assert.equal(second.decision, SLOT_DECISION.REJECT_INFLIGHT);
  assert.equal(second.outcome, SLOT_OUTCOME.REJECT);
});

test('동시(Promise.all) 동일 inputHash는 정확히 한 번만 ALLOW → provider 1회 (12)', async () => {
  const db = createFakeDb();
  const guard = createAiUsageGuard({ db, policy: POLICY, now: () => 1_000_000 });
  const results = await Promise.all([
    guard.acquireGenerationSlot({ callerUid: 'u1', targetUid: null, inputHash: 'h1', isRefresh: false, cacheValid: false }),
    guard.acquireGenerationSlot({ callerUid: 'u1', targetUid: null, inputHash: 'h1', isRefresh: false, cacheValid: false }),
  ]);
  assert.equal(results.filter((r) => r.decision === SLOT_DECISION.ALLOW).length, 1);
  const usage = db.store.get('_internalAiUsage/u1/functions/generateIdealTypeImage');
  assert.equal(usage.hourCount, 1);
});

test('시간당 6회 초과 차단 (7)', async () => {
  const db = createFakeDb();
  let clock = 1_000_000;
  const guard = createAiUsageGuard({ db, policy: POLICY, now: () => clock });
  for (let i = 0; i < POLICY.hourlyLimit; i += 1) {
    const r = await guard.acquireGenerationSlot({ callerUid: 'u1', targetUid: null, inputHash: `h${i}`, isRefresh: false, cacheValid: false });
    assert.equal(r.decision, SLOT_DECISION.ALLOW, `attempt ${i}`);
    clock += POLICY.cooldownMs + 1;
  }
  const over = await guard.acquireGenerationSlot({ callerUid: 'u1', targetUid: null, inputHash: 'hX', isRefresh: false, cacheValid: false });
  assert.equal(over.decision, SLOT_DECISION.REJECT_HOURLY);
});

test('일일 15회 초과 차단 (8)', async () => {
  const db = createFakeDb();
  let clock = 1_000_000;
  const guard = createAiUsageGuard({ db, policy: POLICY, now: () => clock });
  // 시간당 6 제한을 피하려고 매 호출마다 1시간+ 전진(일일 window는 유지).
  for (let i = 0; i < POLICY.dailyLimit; i += 1) {
    const r = await guard.acquireGenerationSlot({ callerUid: 'u1', targetUid: null, inputHash: `h${i}`, isRefresh: false, cacheValid: false });
    assert.equal(r.decision, SLOT_DECISION.ALLOW, `attempt ${i}`);
    clock += POLICY.hourMs + 1; // 시간 window 리셋, 일일은 누적
  }
  const over = await guard.acquireGenerationSlot({ callerUid: 'u1', targetUid: null, inputHash: 'hX', isRefresh: false, cacheValid: false });
  assert.equal(over.decision, SLOT_DECISION.REJECT_DAILY);
});

test('20초 cooldown 동작 (9)', async () => {
  const db = createFakeDb();
  let clock = 1_000_000;
  const guard = createAiUsageGuard({ db, policy: POLICY, now: () => clock });
  const a = await guard.acquireGenerationSlot({ callerUid: 'u1', targetUid: null, inputHash: 'h1', isRefresh: false, cacheValid: false });
  assert.equal(a.decision, SLOT_DECISION.ALLOW);
  await guard.releaseGenerationSlot({ callerUid: 'u1', targetUid: null, inputHash: 'h1', success: true });
  clock += 10 * 1000; // 20초 미만
  const soon = await guard.acquireGenerationSlot({ callerUid: 'u1', targetUid: null, inputHash: 'h2', isRefresh: false, cacheValid: false });
  assert.equal(soon.decision, SLOT_DECISION.REJECT_COOLDOWN);
});

test('lease TTL(180s) 이후 takeover 가능 (14)', async () => {
  const db = createFakeDb();
  let clock = 1_000_000;
  const guard = createAiUsageGuard({ db, policy: POLICY, now: () => clock });
  const first = await guard.acquireGenerationSlot({ callerUid: 'u1', targetUid: null, inputHash: 'h1', isRefresh: false, cacheValid: false });
  assert.equal(first.decision, SLOT_DECISION.ALLOW);
  // release 없이(비정상 종료 가정) lease TTL 경과 + cooldown 경과 후 재시도.
  clock += POLICY.leaseTtlMs + 1;
  const takeover = await guard.acquireGenerationSlot({ callerUid: 'u1', targetUid: null, inputHash: 'h1', isRefresh: false, cacheValid: false });
  assert.equal(takeover.decision, SLOT_DECISION.ALLOW);
});

test('다른 UID quota 독립 (11)', async () => {
  const db = createFakeDb();
  let clock = 1_000_000;
  const guard = createAiUsageGuard({ db, policy: POLICY, now: () => clock });
  for (let i = 0; i < POLICY.hourlyLimit; i += 1) {
    await guard.acquireGenerationSlot({ callerUid: 'u1', targetUid: null, inputHash: `h${i}`, isRefresh: false, cacheValid: false });
    clock += POLICY.cooldownMs + 1;
  }
  const u1over = await guard.acquireGenerationSlot({ callerUid: 'u1', targetUid: null, inputHash: 'hX', isRefresh: false, cacheValid: false });
  assert.equal(u1over.decision, SLOT_DECISION.REJECT_HOURLY);
  const u2 = await guard.acquireGenerationSlot({ callerUid: 'u2', targetUid: null, inputHash: 'h0', isRefresh: false, cacheValid: false });
  assert.equal(u2.decision, SLOT_DECISION.ALLOW);
});

test('다른 inputHash는 독립 생성 (13)', async () => {
  const db = createFakeDb();
  let clock = 1_000_000;
  const guard = createAiUsageGuard({ db, policy: POLICY, now: () => clock });
  const a = await guard.acquireGenerationSlot({ callerUid: 'u1', targetUid: null, inputHash: 'h1', isRefresh: false, cacheValid: false });
  clock += POLICY.cooldownMs + 1;
  const b = await guard.acquireGenerationSlot({ callerUid: 'u1', targetUid: null, inputHash: 'h2', isRefresh: false, cacheValid: false });
  assert.equal(a.decision, SLOT_DECISION.ALLOW);
  assert.equal(b.decision, SLOT_DECISION.ALLOW);
});

test('provider 실패도 attempt quota 소비 — release(failure)가 카운터를 되돌리지 않음 (15)', async () => {
  const db = createFakeDb();
  const guard = createAiUsageGuard({ db, policy: POLICY, now: () => 1_000_000 });
  await guard.acquireGenerationSlot({ callerUid: 'u1', targetUid: null, inputHash: 'h1', isRefresh: false, cacheValid: false });
  await guard.releaseGenerationSlot({ callerUid: 'u1', targetUid: null, inputHash: 'h1', success: false });
  const usage = db.store.get('_internalAiUsage/u1/functions/generateIdealTypeImage');
  assert.equal(usage.hourCount, 1); // 실패해도 quota 유지
  const leaseId = buildLeaseId(POLICY.functionName, 'u1', null, 'h1');
  const lease = db.store.get(`_internalAiLeases/${leaseId}`);
  assert.equal(lease.leaseExpiresAt, 0); // lease는 해제
});

test('malformed usage 문서도 안전 처리 (18)', async () => {
  const leaseIrrelevant = {};
  const db = createFakeDb({
    '_internalAiUsage/u1/functions/generateIdealTypeImage': {
      hourCount: 'bad',
      dayCount: -9,
      hourWindowStart: NaN,
      dayWindowStart: null,
    },
  });
  void leaseIrrelevant;
  const guard = createAiUsageGuard({ db, policy: POLICY, now: () => 5_000_000 });
  const r = await guard.acquireGenerationSlot({ callerUid: 'u1', targetUid: null, inputHash: 'h1', isRefresh: false, cacheValid: false });
  assert.equal(r.decision, SLOT_DECISION.ALLOW); // 안전 복구 후 정상 허용
});

// ===========================================================================
// index.js 통합 불변식 — 정적 검증
// (1,2,3,4,5,6,16,17,19,20,21,22,23,24)
// ===========================================================================
test('index.js: generateIdealTypeImage guard 배선/순서/보존 불변식', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'index.js'), 'utf8');

  // generateIdealTypeImageResult 본문만 슬라이스.
  const fnStart = src.indexOf('async function generateIdealTypeImageResult({');
  const fnEnd = src.indexOf('\nexports.generateIdealTypeImage = onCall(');
  assert.ok(fnStart > 0 && fnEnd > fnStart, 'result 함수 블록 확인');
  const fnSrc = src.slice(fnStart, fnEnd);

  // (1,2) unauthenticated + self(request.auth.uid) — export 에서 처리.
  const exportStart = src.indexOf('exports.generateIdealTypeImage = onCall(');
  const exportEnd = src.indexOf('exports.generateIdealTypeImageProviderPreview');
  const exportSrc = src.slice(exportStart, exportEnd);
  assert.ok(exportSrc.includes("throw new HttpsError('unauthenticated'"), 'unauth 차단');
  assert.ok(exportSrc.includes('uid: request.auth.uid,'), 'self uid 사용');
  assert.ok(!exportSrc.includes('targetUid'), '클라이언트 targetUid 신뢰 안 함');

  // (3) generateIdealTypeImage 는 guard 주입, (24) preview 는 미주입.
  assert.ok(exportSrc.includes('usageGuard: idealTypeImageUsageGuard,'), 'guard 주입');
  const previewStart = src.indexOf('exports.generateIdealTypeImageProviderPreview = onCall(');
  const previewEnd = src.indexOf('// Phase 0-D: 인증 배지', previewStart);
  const previewSrc = src.slice(previewStart, previewEnd);
  assert.ok(!previewSrc.includes('usageGuard'), 'preview 는 guard 미적용(무변경)');

  // (4,5,6) 캐시 재사용이 guard 보다 먼저(cache hit → provider/quota 미소비).
  const idxCacheReturn = fnSrc.indexOf('isReusableIdealImageCache(cached');
  const idxAcquire = fnSrc.indexOf('acquireGenerationSlot({');
  const idxProvider = fnSrc.indexOf('generateIdealTypeImageWithProvider(provider');
  assert.ok(idxCacheReturn > 0 && idxAcquire > idxCacheReturn, '캐시 체크가 guard 보다 먼저');
  // (guard) provider 호출은 slot 확보 이후.
  assert.ok(idxProvider > idxAcquire, 'provider 호출은 slot 확보 이후');

  // (15,16,17) release 는 finally, 캐시 write 는 upload 성공 이후.
  assert.ok(fnSrc.includes('} finally {'), 'lease 해제 finally 존재');
  assert.ok(fnSrc.includes('releaseGenerationSlot({'), 'lease 해제 호출');
  const idxUpload = fnSrc.indexOf('uploadIdealImage({');
  const idxCacheWrite = fnSrc.indexOf('userRef.set({ [cacheField]: result }');
  assert.ok(idxCacheWrite > idxUpload, '캐시 write 는 upload 이후');

  // (20) sanitized 로그 — 이미지 섹션에 raw error.message 로그 없음.
  const imgSectionStart = src.indexOf('function logIdealImageEvent(');
  const imgSectionEnd = src.indexOf('// Phase 0-D: 인증 배지', imgSectionStart);
  const imgSection = src.slice(imgSectionStart, imgSectionEnd);
  assert.ok(!imgSection.includes('error?.message'), '이미지 섹션 error.message 로그 없음');
  assert.ok(!imgSection.includes('error.message'), '이미지 섹션 error.message 로그 없음');
  assert.ok(src.includes('function logIdealImageEvent('), 'sanitized 로그 헬퍼 존재');

  // (21) inputHash 완전성 — 모든 이미지 결과 영향 입력 포함.
  const hashFn = src.slice(src.indexOf('function idealImageHash('), src.indexOf('function idealImageHash(') + 400);
  const hashPayload = src.slice(src.indexOf('function idealImageHashPayload('), src.indexOf('function idealImageHashPayload(') + 400);
  for (const k of ['gender', 'idealTags', 'mood', 'style', 'hair', 'impression', 'background']) {
    assert.ok(hashPayload.includes(`${k}:`), `hash payload에 ${k} 포함`);
  }
  assert.ok(hashFn.includes('provider,'), 'hash에 provider 포함');
  assert.ok(hashFn.includes('promptVersion,'), 'hash에 promptVersion 포함');
  assert.ok(hashFn.includes('refinementText'), 'hash에 refinementText 포함');

  // (22) 결과 JSON 스키마 동일 (shorthand `key,` 와 `key:` 모두 허용).
  for (const k of ['inputHash', 'imageUrl', 'storagePath', 'summary', 'safetyLabel', 'options', 'revisedPrompt', 'provider', 'model', 'promptVersion', 'safetyPolicyVersion', 'imageCount', 'syntheticHuman']) {
    assert.ok(new RegExp(`\\b${k}\\s*[:,]`).test(fnSrc), `result에 ${k} 유지`);
  }

  // (23) provider/모델/prompt/이미지 품질 파라미터 불변.
  assert.ok(src.includes('const ACTIVE_IDEAL_IMAGE_PROVIDER = IDEAL_IMAGE_PROVIDERS.FAL_FLUX;'), 'provider 고정 유지');
  assert.ok(src.includes("The character is not a real individual, not a celebrity, not an app user"), '안전 정책 프롬프트 유지');
  assert.ok(src.includes('buildPromptForProvider(provider, input)'), 'prompt 빌드 경로 유지');
});
