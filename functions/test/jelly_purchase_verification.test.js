'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const {
  ANDROID_PACKAGE_NAME,
  IOS_BUNDLE_ID,
  JELLY_PRODUCTS,
  PURCHASE_VERIFICATION_RATE_LIMIT,
  PurchaseVerificationError,
  USER_PURCHASE_ERROR_MESSAGE,
  buildObfuscatedExternalAccountId,
  normalizeUsageDoc,
  receiptHashForAndroid,
  toHttpsError,
  verifyJellyPurchaseCore,
} = require('../lib/jelly_purchase_verification');

function deepClone(value) {
  return value === undefined ? undefined : JSON.parse(JSON.stringify(value));
}

function createFakeDb(initial = {}, options = {}) {
  const store = new Map();
  const versions = new Map();
  for (const [key, value] of Object.entries(initial)) {
    store.set(key, deepClone(value));
    versions.set(key, 1);
  }
  const versionOf = (p) => versions.get(p) || 0;
  const snap = (p) => {
    const data = deepClone(store.get(p));
    return {
      exists: data !== undefined,
      data: () => deepClone(data),
    };
  };
  const applySet = (p, data, opts) => {
    const prev = opts?.merge ? store.get(p) || {} : {};
    store.set(p, { ...deepClone(prev), ...deepClone(data) });
    versions.set(p, versionOf(p) + 1);
  };
  const applyUpdate = (p, data) => {
    if (options.failUpdatePath === p) throw new Error('write failure secret');
    const prev = store.get(p);
    if (prev === undefined) throw new Error('not-found');
    store.set(p, { ...deepClone(prev), ...deepClone(data) });
    versions.set(p, versionOf(p) + 1);
  };
  const docRef = (p) => ({
    path: p,
    async get() {
      return snap(p);
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
        const transaction = {
          async get(ref) {
            reads.set(ref.path, versionOf(ref.path));
            await new Promise((resolve) => setImmediate(resolve));
            return snap(ref.path);
          },
          update(ref, data) {
            if (options.failUpdatePath === ref.path) {
              throw new Error('write failure secret');
            }
            writes.push({ op: 'update', path: ref.path, data });
          },
          set(ref, data, opts) {
            if (options.failSetPath === ref.path) {
              throw new Error('write failure secret');
            }
            writes.push({ op: 'set', path: ref.path, data, opts });
          },
        };
        const result = await fn(transaction);
        let conflict = false;
        for (const [p, v] of reads) {
          if (versionOf(p) !== v) {
            conflict = true;
            break;
          }
        }
        if (conflict) continue;
        for (const write of writes) {
          if (write.op === 'set') applySet(write.path, write.data, write.opts);
          if (write.op === 'update') applyUpdate(write.path, write.data);
        }
        return result;
      }
      throw new Error('fake transaction exceeded max attempts');
    },
  };
}

function createLogger() {
  const entries = [];
  return {
    entries,
    log(payload) {
      entries.push(payload);
    },
  };
}

function serverTimestamp() {
  return '__serverTimestamp__';
}

function request({
  uid = 'user-1',
  platform = 'android',
  productId = 'jelly_30',
  purchaseToken = 'token-1',
  transactionId = 'tx-1',
  extra = {},
} = {}) {
  return {
    auth: uid ? { uid } : null,
    data: {
      platform,
      productId,
      purchaseToken,
      transactionId,
      ...extra,
    },
  };
}

function providerResult(overrides = {}) {
  return {
    packageName: ANDROID_PACKAGE_NAME,
    productId: 'jelly_30',
    purchaseState: 0,
    consumptionState: 0,
    acknowledgementState: 0,
    purchaseTimeMillis: '1760000000000',
    quantity: 1,
    refundableQuantity: 1,
    obfuscatedExternalAccountId: buildObfuscatedExternalAccountId('user-1'),
    ...overrides,
  };
}

async function callCore({
  db = createFakeDb({ 'users/user-1': { jelly: 10 } }),
  req = request(),
  verifier = async () => providerResult(),
  logger = createLogger(),
  nowMs = () => 10_000_000,
} = {}) {
  return verifyJellyPurchaseCore({
    request: req,
    db,
    serverTimestamp,
    logger,
    verifyAndroidPurchase: verifier,
    nowMs,
  });
}

async function assertRejectsWithCode(promise, code) {
  await assert.rejects(
    promise,
    (error) => error instanceof PurchaseVerificationError &&
      error.code === code,
  );
}

test('server catalog: 실제 Flutter 상품 ID와 서버 소유 수량만 허용', () => {
  assert.deepEqual(Object.keys(JELLY_PRODUCTS).sort(), [
    'jelly_100',
    'jelly_30',
    'jelly_300',
  ]);
  assert.equal(JELLY_PRODUCTS.jelly_30.jellyAmount, 30);
  assert.equal(JELLY_PRODUCTS.jelly_100.jellyAmount, 100);
  assert.equal(JELLY_PRODUCTS.jelly_300.jellyAmount, 300);
  assert.equal(JELLY_PRODUCTS.jelly_30.platform, 'android');
  assert.equal(IOS_BUNDLE_ID, 'com.cvrlab.datingApp');
});

test('unauthenticated 차단', async () => {
  await assertRejectsWithCode(callCore({ req: request({ uid: null }) }), 'unauthenticated');
});

test('malformed payload 차단', async () => {
  await assertRejectsWithCode(
    callCore({ req: request({ purchaseToken: '' }) }),
    'invalid-argument',
  );
});

test('unknown platform 차단', async () => {
  await assertRejectsWithCode(
    callCore({ req: request({ platform: 'web' }) }),
    'invalid-argument',
  );
});

test('unknown productId 차단', async () => {
  await assertRejectsWithCode(
    callCore({ req: request({ productId: 'jelly_999' }) }),
    'invalid-argument',
  );
});

test('client jellyAmount 불일치 차단', async () => {
  await assertRejectsWithCode(
    callCore({ req: request({ extra: { jellyAmount: 999 } }) }),
    'invalid-argument',
  );
});

test('Android 정상 구매 1회 지급: 서버 catalog amount만 반영', async () => {
  const db = createFakeDb({ 'users/user-1': { jelly: 10 } });
  const result = await callCore({ db });
  const hash = receiptHashForAndroid('token-1');
  assert.deepEqual(result, {
    amount: 30,
    balance: 40,
    duplicate: false,
    alreadyProcessed: false,
  });
  assert.equal(db.store.get('users/user-1').jelly, 40);
  assert.equal(db.store.get(`_purchaseReceipts/${hash}`).grantedJellyAmount, 30);
  assert.equal(
    db.store.get(`users/user-1/jellyTransactions/${hash}`).amount,
    30,
  );
});

test('provider productId 불일치 차단', async () => {
  await assertRejectsWithCode(
    callCore({ verifier: async () => providerResult({ productId: 'jelly_100' }) }),
    'failed-precondition',
  );
});

test('packageName 불일치 차단', async () => {
  await assertRejectsWithCode(
    callCore({ verifier: async () => providerResult({ packageName: 'bad.app' }) }),
    'failed-precondition',
  );
});

test('pending 구매 차단', async () => {
  await assertRejectsWithCode(
    callCore({ verifier: async () => providerResult({ purchaseState: 2 }) }),
    'failed-precondition',
  );
});

test('cancelled/refunded 구매 차단', async () => {
  await assertRejectsWithCode(
    callCore({ verifier: async () => providerResult({ purchaseState: 1 }) }),
    'failed-precondition',
  );
  await assertRejectsWithCode(
    callCore({ verifier: async () => providerResult({ refundableQuantity: 0 }) }),
    'failed-precondition',
  );
  await assertRejectsWithCode(
    callCore({ verifier: async () => providerResult({ consumptionState: 1 }) }),
    'failed-precondition',
  );
});

test('malformed provider response 차단', async () => {
  await assertRejectsWithCode(
    callCore({ verifier: async () => null }),
    'failed-precondition',
  );
  await assertRejectsWithCode(
    callCore({ verifier: async () => providerResult({ quantity: 2 }) }),
    'failed-precondition',
  );
  await assertRejectsWithCode(
    callCore({ verifier: async () => providerResult({ consumptionState: undefined }) }),
    'failed-precondition',
  );
});

test('provider 401/403 안전 처리', async () => {
  await assertRejectsWithCode(
    callCore({ verifier: async () => { throw { response: { status: 403 } }; } }),
    'failed-precondition',
  );
});

test('provider 429/5xx retryable 처리', async () => {
  await assertRejectsWithCode(
    callCore({ verifier: async () => { throw { response: { status: 429 } }; } }),
    'unavailable',
  );
  await assertRejectsWithCode(
    callCore({ verifier: async () => { throw { response: { status: 503 } }; } }),
    'unavailable',
  );
});

test('provider 401/403/429/5xx도 시작된 attempt quota로 계산된다', async () => {
  for (const status of [401, 403, 429, 503]) {
    const db = createFakeDb({ 'users/user-1': { jelly: 10 } });
    await assertRejectsWithCode(
      callCore({
        db,
        verifier: async () => { throw { response: { status } }; },
      }),
      status === 429 || status === 503 ? 'unavailable' : 'failed-precondition',
    );
    const usage = db.store.get('_purchaseVerificationUsage/user-1');
    assert.equal(usage.hourCount, 1, `status ${status}`);
    assert.equal(usage.dayCount, 1, `status ${status}`);
  }
});

test('동일 token 재호출 추가 지급 0, provider 재검증 없이 idempotent 성공', async () => {
  const db = createFakeDb({ 'users/user-1': { jelly: 10 } });
  await callCore({ db });
  let providerCalls = 0;
  const result = await callCore({
    db,
    verifier: async () => {
      providerCalls += 1;
      throw { response: { status: 503 } };
    },
  });
  assert.equal(providerCalls, 0);
  assert.equal(db.store.get('_purchaseVerificationUsage/user-1').hourCount, 1);
  assert.equal(result.balance, 40);
  assert.equal(result.duplicate, true);
  assert.equal(db.store.get('users/user-1').jelly, 40);
});

test('동일 신규 token 동시 호출은 provider 1회, 지급 1회, 나머지는 retryable 차단', async () => {
  const db = createFakeDb({ 'users/user-1': { jelly: 10 } });
  let providerCalls = 0;
  const results = await Promise.allSettled([
    callCore({
      db,
      verifier: async () => {
        providerCalls += 1;
        return providerResult();
      },
    }),
    callCore({
      db,
      verifier: async () => {
        providerCalls += 1;
        return providerResult();
      },
    }),
  ]);
  assert.equal(providerCalls, 1);
  assert.equal(
    results.filter((r) => r.status === 'fulfilled' && !r.value.duplicate).length,
    1,
  );
  assert.equal(
    results.filter(
      (r) => r.status === 'rejected' && r.reason.code === 'resource-exhausted',
    ).length,
    1,
  );
  assert.equal(db.store.get('users/user-1').jelly, 40);
});

test('다른 UID의 token 재사용 차단', async () => {
  const hash = receiptHashForAndroid('token-1');
  const db = createFakeDb({
    'users/user-1': { jelly: 40 },
    'users/user-2': { jelly: 10 },
    [`_purchaseReceipts/${hash}`]: {
      uid: 'user-1',
      receiptHash: hash,
      productId: 'jelly_30',
      platform: 'android',
      grantedJellyAmount: 30,
      status: 'granted',
    },
  });
  let providerCalls = 0;
  await assertRejectsWithCode(
    callCore({
      db,
      req: request({ uid: 'user-2' }),
      verifier: async () => {
        providerCalls += 1;
        return providerResult();
      },
    }),
    'permission-denied',
  );
  assert.equal(providerCalls, 0);
  assert.equal(db.store.get('users/user-2').jelly, 10);
});

test('다른 정상 token은 각각 지급', async () => {
  const db = createFakeDb({ 'users/user-1': { jelly: 0 } });
  let clock = 10_000_000;
  const nowMs = () => clock;
  await callCore({ db, req: request({ purchaseToken: 'token-a' }), nowMs });
  clock += PURCHASE_VERIFICATION_RATE_LIMIT.cooldownMs + 1;
  await callCore({ db, req: request({ purchaseToken: 'token-b' }), nowMs });
  assert.equal(db.store.get('users/user-1').jelly, 60);
});

test('balance와 receipt가 같은 transaction에서 반영된다', async () => {
  const db = createFakeDb({ 'users/user-1': { jelly: 5 } });
  await callCore({ db });
  const hash = receiptHashForAndroid('token-1');
  assert.equal(db.store.get('users/user-1').jelly, 35);
  assert.equal(db.store.get(`_purchaseReceipts/${hash}`).status, 'granted');
});

test('receipt 성공 + balance 실패 같은 부분 성공 없음', async () => {
  const db = createFakeDb(
    { 'users/user-1': { jelly: 5 } },
    { failUpdatePath: 'users/user-1' },
  );
  await assert.rejects(callCore({ db }), /write failure/);
  const hash = receiptHashForAndroid('token-1');
  assert.equal(db.store.get('users/user-1').jelly, 5);
  assert.equal(db.store.get(`_purchaseReceipts/${hash}`), undefined);
  assert.equal(db.store.get(`users/user-1/jellyTransactions/${hash}`), undefined);
});

test('provider 실패 시 receipt/grant 없음', async () => {
  const db = createFakeDb({ 'users/user-1': { jelly: 5 } });
  await assertRejectsWithCode(
    callCore({ db, verifier: async () => providerResult({ productId: 'bad' }) }),
    'failed-precondition',
  );
  const hash = receiptHashForAndroid('token-1');
  assert.equal(db.store.get('users/user-1').jelly, 5);
  assert.equal(db.store.get(`_purchaseReceipts/${hash}`), undefined);
});

test('iOS 미지원 상태 fail-closed', async () => {
  await assertRejectsWithCode(
    callCore({
      req: request({
        platform: 'ios',
        productId: 'jelly_30',
        purchaseToken: 'ios-receipt',
        transactionId: 'ios-tx',
      }),
    }),
    'failed-precondition',
  );
});

test('obfuscatedExternalAccountId는 필수이고 현재 사용자와 일치해야 한다', async () => {
  await assertRejectsWithCode(
    callCore({
      verifier: async () => providerResult({
        obfuscatedExternalAccountId: undefined,
      }),
    }),
    'failed-precondition',
  );
  await assertRejectsWithCode(
    callCore({
      verifier: async () => providerResult({
        obfuscatedExternalAccountId: buildObfuscatedExternalAccountId('other'),
      }),
    }),
    'permission-denied',
  );
  const result = await callCore({
    verifier: async () => providerResult({
      obfuscatedExternalAccountId: buildObfuscatedExternalAccountId('user-1'),
    }),
  });
  assert.equal(result.balance, 40);
});

test('verification rate limit: cooldown/hourly/daily/UID 독립/duplicate 무료', async () => {
  const db = createFakeDb({ 'users/user-1': { jelly: 10 }, 'users/user-2': { jelly: 10 } });
  let clock = 10_000_000;
  const nowMs = () => clock;

  await callCore({
    db,
    req: request({ purchaseToken: 'token-rate-1' }),
    nowMs,
    verifier: async () => providerResult({
      obfuscatedExternalAccountId: buildObfuscatedExternalAccountId('user-1'),
    }),
  });

  await assertRejectsWithCode(
    callCore({
      db,
      req: request({ purchaseToken: 'token-rate-2' }),
      nowMs,
      verifier: async () => providerResult({
        obfuscatedExternalAccountId: buildObfuscatedExternalAccountId('user-1'),
      }),
    }),
    'resource-exhausted',
  );

  let providerCalls = 0;
  const duplicate = await callCore({
    db,
    req: request({ purchaseToken: 'token-rate-1' }),
    nowMs,
    verifier: async () => {
      providerCalls += 1;
      return providerResult();
    },
  });
  assert.equal(duplicate.duplicate, true);
  assert.equal(providerCalls, 0);

  const otherUid = await callCore({
    db,
    req: request({ uid: 'user-2', purchaseToken: 'token-rate-other' }),
    nowMs,
    verifier: async () => providerResult({
      obfuscatedExternalAccountId: buildObfuscatedExternalAccountId('user-2'),
    }),
  });
  assert.equal(otherUid.balance, 40);

  clock += PURCHASE_VERIFICATION_RATE_LIMIT.cooldownMs + 1;
  const usage = {
    hourWindowStartMs: clock,
    hourCount: PURCHASE_VERIFICATION_RATE_LIMIT.hourlyLimit,
    dayWindowStartMs: clock,
    dayCount: 10,
    lastAttemptAtMs: 0,
  };
  db.store.set('_purchaseVerificationUsage/user-1', usage);
  await assertRejectsWithCode(
    callCore({
      db,
      req: request({ purchaseToken: 'token-rate-hourly' }),
      nowMs,
    }),
    'resource-exhausted',
  );

  db.store.set('_purchaseVerificationUsage/user-1', {
    ...usage,
    hourCount: 0,
    dayCount: PURCHASE_VERIFICATION_RATE_LIMIT.dailyLimit,
  });
  await assertRejectsWithCode(
    callCore({
      db,
      req: request({ purchaseToken: 'token-rate-daily' }),
      nowMs,
    }),
    'resource-exhausted',
  );
});

test('malformed usage 문서는 안전하게 복구해 attempt를 기록한다', async () => {
  const db = createFakeDb({
    'users/user-1': { jelly: 10 },
    '_purchaseVerificationUsage/user-1': {
      hourWindowStartMs: 'bad',
      hourCount: 'bad',
      dayWindowStartMs: 99_999_999,
      dayCount: -1,
      lastAttemptAtMs: 99_999_999,
    },
  });
  const result = await callCore({ db, nowMs: () => 10_000_000 });
  assert.equal(result.balance, 40);
  const usage = db.store.get('_purchaseVerificationUsage/user-1');
  assert.equal(usage.hourWindowStartMs, 10_000_000);
  assert.equal(usage.hourCount, 1);
  assert.equal(usage.dayWindowStartMs, 10_000_000);
  assert.equal(usage.dayCount, 1);
});

test('normalizeUsageDoc는 window 만료/미래값/비정상 count를 정리한다', () => {
  const normalized = normalizeUsageDoc(
    {
      hourWindowStartMs: 99_999_999,
      hourCount: 'bad',
      dayWindowStartMs: 1,
      dayCount: 3.9,
      lastAttemptAtMs: 99_999_999,
    },
    10_000_000,
  );
  assert.equal(normalized.hourWindowStartMs, 10_000_000);
  assert.equal(normalized.hourCount, 0);
  assert.equal(normalized.dayWindowStartMs, 1);
  assert.equal(normalized.dayCount, 3);
  assert.equal(normalized.lastAttemptAtMs, 0);
});

test('raw token/UID/provider error.message 로그 없음', async () => {
  const logger = createLogger();
  await assertRejectsWithCode(
    callCore({
      logger,
      verifier: async () => {
        const error = new Error('provider secret token-1 user-1');
        error.response = { status: 503 };
        throw error;
      },
    }),
    'unavailable',
  );
  const serialized = JSON.stringify(logger.entries);
  assert.ok(!serialized.includes('token-1'));
  assert.ok(!serialized.includes('user-1'));
  assert.ok(!serialized.includes('provider secret'));
  assert.ok(serialized.includes('receiptHashPrefix'));
});

test('기존 callable 응답 계약 호환: amount/balance/duplicate 포함', async () => {
  const result = await callCore();
  assert.equal(typeof result.amount, 'number');
  assert.equal(typeof result.balance, 'number');
  assert.equal(typeof result.duplicate, 'boolean');
});

test('HttpsError 변환은 공통 사용자 메시지만 노출', () => {
  class FakeHttpsError extends Error {
    constructor(code, message) {
      super(message);
      this.code = code;
    }
  }
  const err = toHttpsError(
    new PurchaseVerificationError('failed-precondition', {
      providerCategory: 'provider_rejected',
    }),
    FakeHttpsError,
  );
  assert.equal(err.code, 'failed-precondition');
  assert.equal(err.message, USER_PURCHASE_ERROR_MESSAGE);
});

test('Rules: client balance 증가 및 charge 거래 생성 차단 계약', () => {
  const rules = fs.readFileSync(
    path.join(__dirname, '..', '..', 'firestore.rules'),
    'utf8',
  );
  const ownerKeysMatch = rules.match(/function userOwnerUpdateKeys\(\) \{[\s\S]*?\n      \}/);
  assert.ok(ownerKeysMatch);
  assert.ok(!ownerKeysMatch[0].includes("'jelly'"));

  const txRulesMatch = rules.match(/match \/jellyTransactions\/\{txId\} \{[\s\S]*?\n      \}/);
  assert.ok(txRulesMatch);
  assert.ok(txRulesMatch[0].includes("request.resource.data.type == 'spend'"));
  assert.ok(!txRulesMatch[0].includes("request.resource.data.type == 'charge'"));
  assert.ok(!rules.includes('RELEASE-BLOCKER'));
});
