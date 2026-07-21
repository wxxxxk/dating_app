'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const {
  CONFIRMATION_TEXT,
  JOB_STATUS,
  RECENT_AUTH_MAX_AGE_SECONDS,
  deletedIdentifierForUid,
  deleteMyAccountCore,
  recoverPendingAuthDeletionCore,
  toHttpsError,
  uidHashFor,
} = require('../lib/account_deletion');

const DELETE_FIELD = Symbol('deleteField');
const NOW_MS = Date.UTC(2026, 6, 19, 0, 0, 0);
const UID = 'user-alpha';
const OTHER = 'user-beta';
const UID_HASH = uidHashFor(UID);
const DELETED_ID = deletedIdentifierForUid(UID);

class FakeSnapshot {
  constructor(ref, data) {
    this.ref = ref;
    this._data = data == null ? null : clone(data);
    this.exists = data != null;
    this.id = ref.id;
  }

  data() {
    return this._data == null ? undefined : clone(this._data);
  }
}

class FakeQuerySnapshot {
  constructor(docs) {
    this.docs = docs;
  }
}

class FakeDocRef {
  constructor(db, pathValue) {
    this.db = db;
    this.path = pathValue;
    this.id = pathValue.split('/').at(-1);
  }

  collection(id) {
    return new FakeCollectionRef(this.db, `${this.path}/${id}`);
  }

  async get() {
    if (this.db.failGetPaths.has(this.path)) {
      const error = new Error('raw get failure should not leak');
      error.code = 'unavailable';
      throw error;
    }
    return new FakeSnapshot(this, this.db.docs.get(this.path));
  }

  async set(data, options = {}) {
    this.db.operations.push(`set:${this.path}`);
    if (this.db.failSetPaths.has(this.path)) {
      const error = new Error('raw set failure should not leak');
      error.code = 'unavailable';
      throw error;
    }
    if (options.merge === true) {
      const next = { ...(this.db.docs.get(this.path) || {}) };
      for (const [key, value] of Object.entries(data)) {
        if (value === DELETE_FIELD) {
          delete next[key];
        } else {
          next[key] = clone(value);
        }
      }
      this.db.docs.set(this.path, next);
    } else {
      const next = applyDeletes(data);
      this.db.docs.set(this.path, next);
    }
  }

  async update(data) {
    this.db.operations.push(`update:${this.path}`);
    const current = this.db.docs.get(this.path) || {};
    const next = { ...current };
    for (const [key, value] of Object.entries(data)) {
      if (value === DELETE_FIELD) {
        delete next[key];
      } else {
        next[key] = clone(value);
      }
    }
    this.db.docs.set(this.path, next);
  }

  async create(data) {
    this.db.operations.push(`create:${this.path}`);
    if (this.db.failCreatePaths.has(this.path)) {
      const error = new Error('raw create failure should not leak');
      error.code = 'unavailable';
      throw error;
    }
    if (this.db.docs.has(this.path)) {
      const error = new Error('already exists');
      error.code = 'already-exists';
      throw error;
    }
    this.db.docs.set(this.path, clone(data));
  }

  async delete() {
    this.db.operations.push(`delete:${this.path}`);
    this.db.docs.delete(this.path);
  }

  /** 서브컬렉션 문서에서 부모 문서를 찾는 경로(커뮤니티 카운트 보정에서 사용). */
  get parent() {
    const parts = this.path.split('/');
    return {
      id: parts.at(-2),
      path: parts.slice(0, -1).join('/'),
      parent:
        parts.length > 2
          ? new FakeDocRef(this.db, parts.slice(0, -2).join('/'))
          : null,
    };
  }
}

class FakeCollectionRef {
  constructor(db, pathValue) {
    this.db = db;
    this.path = pathValue;
    this.id = pathValue.split('/').at(-1);
  }

  doc(id) {
    return new FakeDocRef(this.db, `${this.path}/${id}`);
  }

  where(field, op, value) {
    return new FakeQuery(this.db, this.path, false, [{ field, op, value }]);
  }

  async get() {
    return new FakeQuery(this.db, this.path, false, []).get();
  }
}

class FakeCollectionGroup {
  constructor(db, id) {
    this.db = db;
    this.id = id;
  }

  where(field, op, value) {
    return new FakeQuery(this.db, this.id, true, [{ field, op, value }]);
  }
}

class FakeQuery {
  constructor(db, pathValue, collectionGroup, filters) {
    this.db = db;
    this.path = pathValue;
    this.collectionGroup = collectionGroup;
    this.filters = filters;
  }

  where(field, op, value) {
    return new FakeQuery(this.db, this.path, this.collectionGroup, [
      ...this.filters,
      { field, op, value },
    ]);
  }

  async get() {
    const signature = [
      this.collectionGroup ? 'group' : 'collection',
      this.path,
      this.filters.map(({ field, op }) => `${field}${op}`).join('&'),
    ].join(':');
    const pathKey = `${this.collectionGroup ? 'group' : 'collection'}:${this.path}`;
    if (this.db.failQuerySignatures.has(signature) || this.db.failQueryPaths.has(pathKey)) {
      const error = new Error('raw query failure should not leak');
      error.code = 'unavailable';
      throw error;
    }
    const docs = [];
    for (const [docPath, data] of this.db.docs.entries()) {
      if (!this._matchesPath(docPath)) continue;
      if (!this._matchesFilters(data)) continue;
      docs.push(new FakeSnapshot(new FakeDocRef(this.db, docPath), data));
    }
    return new FakeQuerySnapshot(docs);
  }

  _matchesPath(docPath) {
    const parts = docPath.split('/');
    if (this.collectionGroup) {
      return parts.length >= 2 && parts.at(-2) === this.path;
    }
    const prefix = `${this.path}/`;
    if (!docPath.startsWith(prefix)) return false;
    const rest = docPath.slice(prefix.length).split('/');
    return rest.length === 1;
  }

  _matchesFilters(data) {
    return this.filters.every(({ field, op, value }) => {
      const actual = data[field];
      if (op === '==') return actual === value;
      if (op === 'array-contains') {
        return Array.isArray(actual) && actual.includes(value);
      }
      throw new Error(`unsupported op ${op}`);
    });
  }
}

class FakeFirestore {
  constructor(seed = {}) {
    this.docs = new Map(Object.entries(seed).map(([key, value]) => [key, clone(value)]));
    this.operations = [];
    this.failCreatePaths = new Set();
    this.failGetPaths = new Set();
    this.failQueryPaths = new Set();
    this.failQuerySignatures = new Set();
    this.failSetPaths = new Set();
    this._transactionQueue = Promise.resolve();
  }

  collection(id) {
    return new FakeCollectionRef(this, id);
  }

  collectionGroup(id) {
    return new FakeCollectionGroup(this, id);
  }

  async runTransaction(fn) {
    const run = async () => {
      const tx = {
        get: (ref) => ref.get(),
        set: (ref, data, options) => ref.set(data, options),
      };
      return fn(tx);
    };
    const result = this._transactionQueue.then(run, run);
    this._transactionQueue = result.catch(() => {});
    return result;
  }

  async recursiveDelete(ref) {
    this.operations.push(`recursiveDelete:${ref.path}`);
    const prefix = `${ref.path}/`;
    for (const key of [...this.docs.keys()]) {
      if (key === ref.path || key.startsWith(prefix)) {
        this.docs.delete(key);
      }
    }
  }
}

class FakeAuth {
  constructor() {
    this.deleted = [];
    this.fail = false;
    this.notFound = false;
  }

  async deleteUser(uid) {
    this.deleted.push(uid);
    if (this.notFound) {
      const error = new Error('user not found raw message');
      error.code = 'auth/user-not-found';
      throw error;
    }
    if (this.fail) {
      const error = new Error('auth failed raw message');
      error.code = 'internal';
      throw error;
    }
  }
}

class FakeBucket {
  constructor(files = [], options = {}) {
    this.files = new Map(files.map((name) => [name, { name, deleted: false }]));
    this.operations = options.operations || [];
    this.failDelete = options.failDelete || false;
    this.failList = options.failList || false;
    this.pageSize = options.pageSize || 2;
  }

  async getFiles(query) {
    if (this.failList) {
      const error = new Error('raw storage list failure should not leak');
      error.code = 403;
      throw error;
    }
    const prefix = query.prefix;
    const pageToken = Number(query.pageToken || 0);
    const names = [...this.files.keys()].filter((name) => name.startsWith(prefix));
    const page = names.slice(pageToken, pageToken + this.pageSize);
    const next = pageToken + this.pageSize < names.length
      ? { ...query, pageToken: pageToken + this.pageSize }
      : null;
    return [
      page.map((name) => ({
        name,
        delete: async () => {
          this.operations.push(`storageDelete:${name}`);
          if (this.failDelete) {
            const error = new Error('storage raw failure');
            error.code = 500;
            throw error;
          }
          this.files.delete(name);
        },
      })),
      next,
    ];
  }
}

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

function applyDeletes(data) {
  const result = {};
  for (const [key, value] of Object.entries(data)) {
    if (value !== DELETE_FIELD) result[key] = clone(value);
  }
  return result;
}

function request(overrides = {}) {
  return {
    auth: {
      uid: UID,
      token: { auth_time: Math.floor(NOW_MS / 1000) },
    },
    data: { confirmation: CONFIRMATION_TEXT },
    ...overrides,
  };
}

function seed() {
  return {
    [`users/${UID}`]: { displayName: 'secret', jelly: 10 },
    [`users/${UID}/dailyFortune/2026-07-19`]: { message: 'private' },
    [`users/${UID}/swipes/${OTHER}`]: {
      actorUid: UID,
      targetUid: OTHER,
      action: 'like',
    },
    [`users/${UID}/blocks/user-gamma`]: {
      blockerUid: UID,
      blockedUid: 'user-gamma',
    },
    [`users/${UID}/jellyTransactions/tx-raw-id`]: {
      type: 'charge',
      amount: 30,
      reason: 'iap_android_jelly_30',
      productId: 'jelly_30',
      platform: 'android',
      receiptHash: 'receipt-hash',
      providerCategory: 'purchased',
      createdAt: 'ORIGINAL_TIME',
      ignoredRawField: { nested: true },
    },
    [`users/${OTHER}/swipes/${UID}`]: {
      actorUid: OTHER,
      targetUid: UID,
      action: 'superlike',
    },
    'users/user-gamma/swipes/user-delta': {
      actorUid: 'user-gamma',
      targetUid: 'user-delta',
      action: 'like',
    },
    [`users/${OTHER}/blocks/${UID}`]: {
      blockerUid: OTHER,
      blockedUid: UID,
    },
    'users/user-gamma/blocks/user-delta': {
      blockerUid: 'user-gamma',
      blockedUid: 'user-delta',
    },
    [`publicProfiles/${UID}`]: { displayName: 'public secret' },
    'matches/m1': {
      participants: [UID, OTHER],
      uid1: UID,
      uid2: OTHER,
      unmatchedBy: [UID],
      celebratedBy: [UID, OTHER],
      lastReadAtByUid: { [UID]: 'READ', [OTHER]: 'OTHER_READ' },
      lastMessage: { text: 'keep', senderId: UID, createdAt: 'MSG_TIME' },
    },
    'matches/m1/messages/msg-user': {
      senderId: UID,
      text: 'message body must stay',
      createdAt: 'T1',
      senderName: 'Secret Name',
      senderPhotoUrl: 'https://example.test/photo.jpg',
    },
    'matches/m1/messages/msg-other': {
      senderId: OTHER,
      text: 'other body must stay',
      createdAt: 'T2',
    },
    'reports/r1': {
      reporterUid: UID,
      reportedUid: OTHER,
      reason: 'spam_scam',
      detail: 'report detail must stay server-only',
      reporterName: 'Secret Reporter',
      reporterPhotoUrl: 'https://example.test/reporter.jpg',
    },
    'reports/r2': {
      reporterUid: OTHER,
      reportedUid: UID,
      reason: 'other',
      reportedName: 'Secret Reported',
    },
    '_purchaseReceipts/receipt1': {
      uid: UID,
      receiptHash: 'receipt1',
      platform: 'android',
      productId: 'jelly_30',
      grantedJellyAmount: 30,
    },
    [`_purchaseVerificationUsage/${UID}`]: { hourCount: 1 },
    [`_internalAiUsage/${UID}`]: { marker: true },
    [`_internalAiUsage/${UID}/functions/generateDailyFortune`]: { dayCount: 1 },
    '_internalAiLeases/opaque-hash': { leaseExpiresAt: NOW_MS + 1000 },
  };
}

function context(options = {}) {
  const operations = [];
  const db = new FakeFirestore(options.seed || seed());
  for (const docPath of options.failGetPaths || []) db.failGetPaths.add(docPath);
  for (const queryPath of options.failQueryPaths || []) db.failQueryPaths.add(queryPath);
  for (const querySignature of options.failQuerySignatures || []) {
    db.failQuerySignatures.add(querySignature);
  }
  const bucket = new FakeBucket(
    options.files || [
      `users/${UID}/profile/a.jpg`,
      `users/${UID}/idealType/b.png`,
      `users/${UID}2/not-owned.jpg`,
    ],
    {
      operations,
      failDelete: options.failStorage === true,
      failList: options.failStorageList === true,
    },
  );
  const auth = new FakeAuth();
  const ctx = {
    db,
    bucket,
    auth,
    loggerRecords: [],
    call: (req = request()) =>
      deleteMyAccountCore({
        request: req,
        db,
        auth,
        storageBucket: bucket,
        serverTimestamp: () => 'SERVER_TIME',
        fieldDelete: () => DELETE_FIELD,
        nowMs: () => options.nowMs || NOW_MS,
        leaseTtlMs: 1000,
        logger: { log: (entry) => ctx.loggerRecords.push(entry) },
      }),
  };
  return ctx;
}

async function runDelete(options = {}) {
  const ctx = context(options);
  ctx.loggerRecords = [];
  await deleteMyAccountCore({
    request: options.request || request(),
    db: ctx.db,
    auth: ctx.auth,
    storageBucket: ctx.bucket,
    serverTimestamp: () => 'SERVER_TIME',
    fieldDelete: () => DELETE_FIELD,
    nowMs: () => options.nowMs || NOW_MS,
    leaseTtlMs: options.leaseTtlMs || 1000,
    logger: { log: (entry) => ctx.loggerRecords.push(entry) },
  });
  return ctx;
}

async function assertRejectsCode(fn, code) {
  await assert.rejects(fn, (error) => error.code === code);
}

async function assertInventoryFailureCategory(options, expectedCategory) {
  const ctx = context(options);
  await assertRejectsCode(() => ctx.call(), 'internal');
  const job = ctx.db.docs.get(`_accountDeletionJobs/${UID_HASH}`);
  assert.equal(job.status, JOB_STATUS.FAILED_RETRYABLE);
  assert.equal(job.failedStep, 'inventory');
  assert.equal(job.failureCategory, expectedCategory);
  assert.equal(job.retryable, true);
  assert.equal(ctx.db.docs.has(`users/${UID}`), true);
  assert.deepEqual(ctx.auth.deleted, []);
  const serialized = JSON.stringify(ctx.loggerRecords);
  assert.equal(serialized.includes(UID), false);
  assert.equal(serialized.includes('raw'), false);
}

test('1. unauthenticated 차단', async () => {
  const ctx = context();
  await assertRejectsCode(() => ctx.call({ data: { confirmation: CONFIRMATION_TEXT } }), 'unauthenticated');
});

test('2. confirmation 불일치 차단', async () => {
  const ctx = context();
  await assertRejectsCode(() => ctx.call(request({ data: { confirmation: 'NO' } })), 'invalid-argument');
});

test('3. auth_time 누락 차단', async () => {
  const ctx = context();
  await assertRejectsCode(() => ctx.call(request({ auth: { uid: UID, token: {} } })), 'failed-precondition');
});

test('4. 300초 초과 재인증 차단', async () => {
  const ctx = context();
  const stale = Math.floor(NOW_MS / 1000) - RECENT_AUTH_MAX_AGE_SECONDS - 1;
  await assertRejectsCode(
    () => ctx.call(request({ auth: { uid: UID, token: { auth_time: stale } } })),
    'failed-precondition',
  );
});

test('5. 미래 auth_time 차단', async () => {
  const ctx = context();
  const future = Math.floor(NOW_MS / 1000) + 1;
  await assertRejectsCode(
    () => ctx.call(request({ auth: { uid: UID, token: { auth_time: future } } })),
    'failed-precondition',
  );
});

test('6. targetUid 입력 차단', async () => {
  const ctx = context();
  await assertRejectsCode(
    () => ctx.call(request({ data: { confirmation: CONFIRMATION_TEXT, targetUid: OTHER } })),
    'invalid-argument',
  );
});

test('6a. callable payload는 confirmation 단일 key만 허용한다', async () => {
  const ctx = context();
  const forbiddenPayloads = [
    null,
    [],
    { confirmation: CONFIRMATION_TEXT, uid: UID },
    { confirmation: CONFIRMATION_TEXT, email: 'user@example.com' },
    { confirmation: CONFIRMATION_TEXT, phone: '+821012345678' },
    { confirmation: CONFIRMATION_TEXT, provider: 'password' },
    { confirmation: CONFIRMATION_TEXT, extra: { nested: true } },
  ];

  for (const data of forbiddenPayloads) {
    await assertRejectsCode(() => ctx.call(request({ data })), 'invalid-argument');
  }
});

test('7. 본인 UID만 사용', async () => {
  const ctx = await runDelete();
  assert.equal(ctx.db.docs.has(`users/${UID}`), false);
  assert.equal(ctx.db.docs.has(`users/${OTHER}`), false);
  assert.equal(ctx.db.docs.has('users/user-gamma/swipes/user-delta'), true);
});

test('8. 독립 사용자 정상 삭제', async () => {
  const ctx = await runDelete({
    files: [`users/${UID}/profile/a.jpg`],
  });
  const job = ctx.db.docs.get(`_accountDeletionJobs/${UID_HASH}`);
  assert.equal(job.status, JOB_STATUS.COMPLETED);
  assert.equal(ctx.auth.deleted[0], UID);
});

test('9. Storage가 Auth/Firestore profile보다 먼저 삭제', async () => {
  const ctx = await runDelete();
  const storageIndex = ctx.bucket.operations.findIndex((op) => op.startsWith('storageDelete:'));
  const profileIndex = ctx.db.operations.findIndex((op) => op === `recursiveDelete:users/${UID}`);
  const authIndex = ctx.auth.deleted.length > 0
    ? ctx.db.operations.length + ctx.bucket.operations.length
    : -1;
  assert.ok(storageIndex >= 0);
  assert.ok(profileIndex >= 0);
  assert.ok(storageIndex < profileIndex);
  assert.ok(authIndex > profileIndex);
});

test('10. Storage 실패 시 이후 단계 중단', async () => {
  const ctx = context({ failStorage: true });
  await assertRejectsCode(() => ctx.call(), 'internal');
  assert.equal(ctx.db.docs.has(`users/${UID}`), true);
  assert.deepEqual(ctx.auth.deleted, []);
  assert.equal(ctx.db.docs.get(`_accountDeletionJobs/${UID_HASH}`).status, JOB_STATUS.FAILED_RETRYABLE);
});

test('10a. inventory substep 실패 category를 안전하게 기록한다', async () => {
  const cases = [
    [
      { failGetPaths: [`users/${UID}`] },
      'inventory_user_failed',
    ],
    [
      { failGetPaths: [`publicProfiles/${UID}`] },
      'inventory_public_profile_failed',
    ],
    [
      { failQuerySignatures: [`collection:users/${UID}/dailyFortune:`] },
      'inventory_daily_fortune_failed',
    ],
    [
      { failQuerySignatures: [`collection:users/${UID}/swipes:`] },
      'inventory_outbound_swipes_failed',
    ],
    [
      { failQuerySignatures: [`collection:users/${UID}/blocks:`] },
      'inventory_outbound_blocks_failed',
    ],
    [
      { failQuerySignatures: [`collection:users/${UID}/jellyTransactions:`] },
      'inventory_jelly_transactions_failed',
    ],
    [
      { failQuerySignatures: ['group:swipes:targetUid=='] },
      'inventory_inbound_swipes_failed',
    ],
    [
      { failQuerySignatures: ['group:blocks:blockedUid=='] },
      'inventory_inbound_blocks_failed',
    ],
    [
      { failQuerySignatures: ['collection:matches:participantsarray-contains'] },
      'inventory_matches_failed',
    ],
    [
      { failQuerySignatures: ['collection:reports:reporterUid=='] },
      'inventory_reports_reporter_failed',
    ],
    [
      { failQuerySignatures: ['collection:reports:reportedUid=='] },
      'inventory_reports_reported_failed',
    ],
    [
      { failQuerySignatures: ['collection:_purchaseReceipts:uid=='] },
      'inventory_receipts_failed',
    ],
    [
      { failStorageList: true },
      'inventory_storage_list_failed',
    ],
    [
      { failQuerySignatures: ['collection:matches/m1/messages:senderId=='] },
      'inventory_match_messages_failed',
    ],
  ];

  for (const [options, category] of cases) {
    await assertInventoryFailureCategory(options, category);
  }
});

test('11. outbound swipes/blocks 삭제', async () => {
  const ctx = await runDelete();
  assert.equal(ctx.db.docs.has(`users/${UID}/swipes/${OTHER}`), false);
  assert.equal(ctx.db.docs.has(`users/${UID}/blocks/user-gamma`), false);
});

test('12. inbound swipes/blocks 정확한 대상만 삭제', async () => {
  const ctx = await runDelete();
  assert.equal(ctx.db.docs.has(`users/${OTHER}/swipes/${UID}`), false);
  assert.equal(ctx.db.docs.has(`users/${OTHER}/blocks/${UID}`), false);
});

test('13. 다른 사용자 관계 보존', async () => {
  const ctx = await runDelete();
  assert.equal(ctx.db.docs.has('users/user-gamma/swipes/user-delta'), true);
  assert.equal(ctx.db.docs.has('users/user-gamma/blocks/user-delta'), true);
});

test('14. match 전체 삭제 없음', async () => {
  const ctx = await runDelete();
  assert.equal(ctx.db.docs.has('matches/m1'), true);
});

test('15. participant UID 익명화', async () => {
  const ctx = await runDelete();
  assert.deepEqual(ctx.db.docs.get('matches/m1').participants, [DELETED_ID, OTHER]);
});

test('16. uid1/uid2 익명화', async () => {
  const ctx = await runDelete();
  assert.equal(ctx.db.docs.get('matches/m1').uid1, DELETED_ID);
  assert.equal(ctx.db.docs.get('matches/m1').uid2, OTHER);
});

test('16a. unmatchedBy에 deleted identifier를 보장해 새 메시지를 차단한다', async () => {
  const normalSeed = seed();
  delete normalSeed['matches/m1'].unmatchedBy;
  const ctx = await runDelete({ seed: normalSeed });
  assert.deepEqual(ctx.db.docs.get('matches/m1').unmatchedBy, [DELETED_ID]);
});

test('17. lastReadAtByUid 정리', async () => {
  const ctx = await runDelete();
  assert.deepEqual(ctx.db.docs.get('matches/m1').lastReadAtByUid, { [OTHER]: 'OTHER_READ' });
});

test('18. lastMessage.senderId 익명화', async () => {
  const ctx = await runDelete();
  assert.equal(ctx.db.docs.get('matches/m1').lastMessage.senderId, DELETED_ID);
  assert.equal(ctx.db.docs.get('matches/m1').lastMessage.text, 'keep');
});

test('19. 탈퇴 사용자의 messages만 익명화', async () => {
  const ctx = await runDelete();
  assert.equal(ctx.db.docs.get('matches/m1/messages/msg-user').senderId, DELETED_ID);
  assert.equal(ctx.db.docs.get('matches/m1/messages/msg-user').senderDeleted, true);
});

test('20. 메시지 내용 보존', async () => {
  const ctx = await runDelete();
  assert.equal(ctx.db.docs.get('matches/m1/messages/msg-user').text, 'message body must stay');
});

test('21. 상대방 messages 변경 없음', async () => {
  const ctx = await runDelete();
  assert.deepEqual(ctx.db.docs.get('matches/m1/messages/msg-other'), {
    senderId: OTHER,
    text: 'other body must stay',
    createdAt: 'T2',
  });
});

test('22. reports 삭제 없음', async () => {
  const ctx = await runDelete();
  assert.equal(ctx.db.docs.has('reports/r1'), true);
  assert.equal(ctx.db.docs.has('reports/r2'), true);
});

test('23. reporter/reported UID 익명화', async () => {
  const ctx = await runDelete();
  assert.equal(ctx.db.docs.get('reports/r1').reporterUid, DELETED_ID);
  assert.equal(ctx.db.docs.get('reports/r1').reportedUid, OTHER);
  assert.equal(Object.hasOwn(ctx.db.docs.get('reports/r1'), 'reporterName'), false);
  assert.equal(Object.hasOwn(ctx.db.docs.get('reports/r1'), 'reporterPhotoUrl'), false);
  assert.equal(ctx.db.docs.get('reports/r2').reporterUid, OTHER);
  assert.equal(ctx.db.docs.get('reports/r2').reportedUid, DELETED_ID);
  assert.equal(Object.hasOwn(ctx.db.docs.get('reports/r2'), 'reportedName'), false);
});

test('24. purchase receipt 삭제 없음', async () => {
  const ctx = await runDelete();
  assert.equal(ctx.db.docs.has('_purchaseReceipts/receipt1'), true);
});

test('25. receipt UID 익명화', async () => {
  const ctx = await runDelete();
  const receipt = ctx.db.docs.get('_purchaseReceipts/receipt1');
  assert.equal(Object.hasOwn(receipt, 'uid'), false);
  assert.equal(receipt.deletedSubjectHash, UID_HASH);
  assert.equal(receipt.receiptHash, 'receipt1');
});

test('26. jelly transaction 감사 복사 후 원본 삭제', async () => {
  const ctx = await runDelete();
  const auditPath = [...ctx.db.docs.keys()].find((key) =>
    key.startsWith(`_deletedAccountAudit/${UID_HASH}/jellyTransactions/`));
  assert.ok(auditPath);
  assert.equal(ctx.db.docs.get(auditPath).amount, 30);
  assert.equal(ctx.db.docs.has(`users/${UID}/jellyTransactions/tx-raw-id`), false);
});

test('27. 감사 복사 실패 시 profile/Auth 삭제 금지', async () => {
  const db = new FakeFirestore(seed());
  const txHash = require('crypto').createHash('sha256').update('tx-raw-id').digest('hex');
  db.failCreatePaths.add(`_deletedAccountAudit/${UID_HASH}/jellyTransactions/${txHash}`);
  const bucket = new FakeBucket([`users/${UID}/profile/a.jpg`]);
  const auth = new FakeAuth();
  await assertRejectsCode(
    () => deleteMyAccountCore({
      request: request(),
      db,
      auth,
      storageBucket: bucket,
      serverTimestamp: () => 'SERVER_TIME',
      fieldDelete: () => DELETE_FIELD,
      nowMs: () => NOW_MS,
    }),
    'internal',
  );
  assert.equal(db.docs.has(`users/${UID}`), true);
  assert.deepEqual(auth.deleted, []);
});

test('28. usage 문서 정리', async () => {
  const ctx = await runDelete();
  assert.equal(ctx.db.docs.has(`_purchaseVerificationUsage/${UID}`), false);
  assert.equal(ctx.db.docs.has(`_internalAiUsage/${UID}`), false);
  assert.equal(ctx.db.docs.has(`_internalAiUsage/${UID}/functions/generateDailyFortune`), false);
  assert.equal(ctx.db.docs.has('_internalAiLeases/opaque-hash'), true);
});

test('29. private/public profile 삭제', async () => {
  const ctx = await runDelete();
  assert.equal(ctx.db.docs.has(`users/${UID}`), false);
  assert.equal(ctx.db.docs.has(`publicProfiles/${UID}`), false);
});

test('30. 하위 컬렉션 잔존 없음', async () => {
  const ctx = await runDelete();
  assert.equal([...ctx.db.docs.keys()].some((key) => key.startsWith(`users/${UID}/`)), false);
});

test('31. Auth 삭제가 항상 마지막 사용자 데이터 mutation 이후 실행', async () => {
  const ctx = await runDelete();
  const profileDeleteIndex = ctx.db.operations.findIndex((op) => op === `recursiveDelete:users/${UID}`);
  const finalJobIndex = ctx.db.operations.lastIndexOf(`set:_accountDeletionJobs/${UID_HASH}`);
  assert.ok(profileDeleteIndex >= 0);
  assert.ok(finalJobIndex > profileDeleteIndex);
  assert.deepEqual(ctx.auth.deleted, [UID]);
});

test('32. 동일 요청 재실행 idempotent', async () => {
  const ctx = await runDelete();
  await deleteMyAccountCore({
    request: request(),
    db: ctx.db,
    auth: ctx.auth,
    storageBucket: ctx.bucket,
    serverTimestamp: () => 'SERVER_TIME',
    fieldDelete: () => DELETE_FIELD,
    nowMs: () => NOW_MS,
  });
  assert.deepEqual(ctx.auth.deleted, [UID]);
});

test('33. 완료 작업 재호출 성공', async () => {
  const ctx = await runDelete();
  assert.equal(Object.hasOwn(ctx.db.docs.get(`_accountDeletionJobs/${UID_HASH}`), 'subjectUid'), false);
  const result = await deleteMyAccountCore({
    request: request(),
    db: ctx.db,
    auth: ctx.auth,
    storageBucket: ctx.bucket,
    serverTimestamp: () => 'SERVER_TIME',
    fieldDelete: () => DELETE_FIELD,
    nowMs: () => NOW_MS,
  });
  assert.equal(result.alreadyCompleted, true);
  assert.equal(result.status, JOB_STATUS.COMPLETED);
});

test('33a. AUTH_DELETE_PENDING 기록 실패 -> Auth 삭제 0', async () => {
  const db = new FakeFirestore(seed());
  const auth = new FakeAuth();
  const bucket = new FakeBucket([`users/${UID}/profile/a.jpg`]);
  let pendingAttemptSeen = false;
  const originalSet = FakeDocRef.prototype.set;
  FakeDocRef.prototype.set = async function patchedSet(data, options) {
    if (
      this.path === `_accountDeletionJobs/${UID_HASH}` &&
      data.status === JOB_STATUS.AUTH_DELETE_PENDING
    ) {
      pendingAttemptSeen = true;
      const error = new Error('pending write failed raw');
      error.code = 'unavailable';
      throw error;
    }
    return originalSet.call(this, data, options);
  };
  try {
    await assertRejectsCode(
      () => deleteMyAccountCore({
        request: request(),
        db,
        auth,
        storageBucket: bucket,
        serverTimestamp: () => 'SERVER_TIME',
        fieldDelete: () => DELETE_FIELD,
        nowMs: () => NOW_MS,
      }),
      'internal',
    );
  } finally {
    FakeDocRef.prototype.set = originalSet;
  }
  assert.equal(pendingAttemptSeen, true);
  assert.deepEqual(auth.deleted, []);
});

test('33b. deleteUser 실패 -> retryable job 유지', async () => {
  const ctx = context();
  ctx.auth.fail = true;
  await assertRejectsCode(() => ctx.call(), 'internal');
  const job = ctx.db.docs.get(`_accountDeletionJobs/${UID_HASH}`);
  assert.equal(job.status, JOB_STATUS.FAILED_RETRYABLE);
  assert.equal(job.failedStep, 'auth');
  assert.equal(job.retryable, true);
});

test('33c. deleteUser 성공 후 finalization 실패 -> 복구 가능 상태 유지', async () => {
  const db = new FakeFirestore(seed());
  const auth = new FakeAuth();
  const bucket = new FakeBucket([`users/${UID}/profile/a.jpg`]);
  let failNextAuthDeleted = true;
  const originalSet = FakeDocRef.prototype.set;
  FakeDocRef.prototype.set = async function patchedSet(data, options) {
    if (
      failNextAuthDeleted &&
      this.path === `_accountDeletionJobs/${UID_HASH}` &&
      data.status === JOB_STATUS.AUTH_DELETED
    ) {
      failNextAuthDeleted = false;
      const error = new Error('finalization failed raw');
      error.code = 'unavailable';
      throw error;
    }
    return originalSet.call(this, data, options);
  };
  try {
    await assertRejectsCode(
      () => deleteMyAccountCore({
        request: request(),
        db,
        auth,
        storageBucket: bucket,
        serverTimestamp: () => 'SERVER_TIME',
        fieldDelete: () => DELETE_FIELD,
        nowMs: () => NOW_MS,
      }),
      'internal',
    );
  } finally {
    FakeDocRef.prototype.set = originalSet;
  }
  const job = db.docs.get(`_accountDeletionJobs/${UID_HASH}`);
  assert.equal(job.status, JOB_STATUS.AUTH_DELETE_PENDING);
  assert.equal(job.subjectUid, UID);
  assert.deepEqual(auth.deleted, [UID]);
});

test('33d. Auth user-not-found + AUTH_DELETE_PENDING -> 완료 상태 복구', async () => {
  const db = new FakeFirestore({
    [`_accountDeletionJobs/${UID_HASH}`]: {
      status: JOB_STATUS.AUTH_DELETE_PENDING,
      subjectUid: UID,
      uidHash: UID_HASH,
    },
  });
  const auth = new FakeAuth();
  auth.notFound = true;
  const result = await recoverPendingAuthDeletionCore({
    uidHash: UID_HASH,
    db,
    auth,
    serverTimestamp: () => 'SERVER_TIME',
    fieldDelete: () => DELETE_FIELD,
  });
  const job = db.docs.get(`_accountDeletionJobs/${UID_HASH}`);
  assert.equal(result.status, JOB_STATUS.COMPLETED);
  assert.equal(job.status, JOB_STATUS.COMPLETED);
  assert.equal(Object.hasOwn(job, 'subjectUid'), false);
});

test('34. 동시 요청 실제 작업 1회', async () => {
  const ctx = context();
  ctx.loggerRecords = [];
  const opts = {
    request: request(),
    db: ctx.db,
    auth: ctx.auth,
    storageBucket: ctx.bucket,
    serverTimestamp: () => 'SERVER_TIME',
    fieldDelete: () => DELETE_FIELD,
    nowMs: () => NOW_MS,
    leaseTtlMs: 60 * 1000,
    logger: { log: (entry) => ctx.loggerRecords.push(entry) },
  };
  const results = await Promise.allSettled([
    deleteMyAccountCore(opts),
    deleteMyAccountCore(opts),
  ]);
  assert.equal(results.filter((r) => r.status === 'fulfilled').length, 1);
  assert.equal(ctx.auth.deleted.length, 1);
});

test('35. lease TTL takeover', async () => {
  const active = context();
  active.db.docs.set(`_accountDeletionJobs/${UID_HASH}`, {
    status: JOB_STATUS.REQUESTED,
    leaseExpiresAtMs: NOW_MS + 1000,
  });
  await assertRejectsCode(() => active.call(), 'failed-precondition');

  const expired = await runDelete({
    seed: {
      ...seed(),
      [`_accountDeletionJobs/${UID_HASH}`]: {
        status: JOB_STATUS.REQUESTED,
        leaseExpiresAtMs: NOW_MS - 1,
      },
    },
  });
  assert.equal(expired.db.docs.get(`_accountDeletionJobs/${UID_HASH}`).status, JOB_STATUS.COMPLETED);
});

test('36. 부분 실패 후 재시도는 idempotent 단계로 완료', async () => {
  const ctx = context({ failStorage: true });
  await assertRejectsCode(() => ctx.call(), 'internal');
  ctx.bucket.failDelete = false;
  await deleteMyAccountCore({
    request: request(),
    db: ctx.db,
    auth: ctx.auth,
    storageBucket: ctx.bucket,
    serverTimestamp: () => 'SERVER_TIME',
    fieldDelete: () => DELETE_FIELD,
    nowMs: () => NOW_MS + 2000,
  });
  assert.equal(ctx.db.docs.get(`_accountDeletionJobs/${UID_HASH}`).status, JOB_STATUS.COMPLETED);
});

test('37. unknown/malformed shared shape fail-closed', async () => {
  const badSeed = seed();
  badSeed['matches/m1'].uid1 = null;
  const ctx = context({ seed: badSeed });
  await assertRejectsCode(() => ctx.call(), 'failed-precondition');
  assert.equal(ctx.db.docs.has(`users/${UID}`), true);
  assert.deepEqual(ctx.auth.deleted, []);
});

test('38. raw UID/PII/error.message 로그 없음', async () => {
  const ctx = await runDelete();
  const serialized = JSON.stringify(ctx.loggerRecords);
  assert.equal(serialized.includes(UID), false);
  assert.equal(serialized.includes('Secret Name'), false);
  assert.equal(serialized.includes('photo.jpg'), false);
  assert.equal(serialized.includes('raw'), false);
});

test('39. 기존 11 orphan 대상 경로 사용 없음', () => {
  const source = fs.readFileSync(path.join(__dirname, '..', 'lib', 'account_deletion.js'), 'utf8');
  assert.equal(source.includes('orphan'), false);
  assert.equal(source.includes('auth_verification_badge_unknown_orphan'), false);
  assert.equal(source.includes('cleanup_orphan_accounts'), false);
});

test('40. callable mapping은 내부 메시지를 노출하지 않는다', () => {
  class FakeHttpsError extends Error {
    constructor(code, message) {
      super(message);
      this.code = code;
    }
  }
  const mapped = toHttpsError(new Error('raw stack'), FakeHttpsError);
  assert.equal(mapped.code, 'internal');
  assert.equal(mapped.message.includes('raw stack'), false);
});

test('41. helper source has no production project access literal', () => {
  const source = fs.readFileSync(path.join(__dirname, '..', 'lib', 'account_deletion.js'), 'utf8');
  assert.equal(source.includes('cvr-dating-app'), false);
  assert.equal(source.includes('firebase deploy'), false);
});

test('42. callable runtime option 유지', () => {
  const source = fs.readFileSync(path.join(__dirname, '..', 'index.js'), 'utf8');
  const start = source.indexOf('exports.deleteMyAccount = onCall(');
  const body = source.slice(start, source.indexOf('// ============================================================================', start + 1));
  assert.ok(body.includes("timeoutSeconds: 540"));
  assert.ok(body.includes("memory: '1GiB'"));
  assert.ok(body.includes('maxInstances: 5'));
  assert.equal(body.includes('enforceAppCheck'), false);
});

// ── Phase 3-4A: 지인 피하기·인증 개인정보 정리 ──────────────────────────
//
// 기존 seed/파일 목록을 건드리지 않고, 이 시나리오 전용 seed를 주입한다.

const THIRD = 'user-gamma';
const PAIR_WITH_OTHER = 'pair-uid-other';
const PAIR_UNRELATED = 'pair-other-gamma';

function contactSeed() {
  return {
    ...seed(),
    // 지인 피하기 데이터
    [`privatePhoneIdentifiers/${UID}`]: {
      uid: UID,
      contactHash: 'a'.repeat(64),
    },
    [`contactAvoidanceSyncLimits/${UID}`]: { lastSyncAt: 'T1' },
    [`users/${UID}/contactAvoidanceMatches/${OTHER}`]: { targetUid: OTHER },
    // 상대가 나를 가리키는 inbound 관계
    [`users/${OTHER}/contactAvoidanceMatches/${UID}`]: { targetUid: UID },
    [`contactAvoidancePairs/${PAIR_WITH_OTHER}`]: {
      participants: [OTHER, UID].sort(),
    },
    // 나와 무관한 pair는 남아야 한다.
    [`contactAvoidancePairs/${PAIR_UNRELATED}`]: {
      participants: [OTHER, THIRD].sort(),
    },
    [`users/${OTHER}/contactAvoidanceMatches/${THIRD}`]: { targetUid: THIRD },
    // 사진 인증 요청(top-level)
    [`photoVerificationRequests/${UID}`]: {
      uid: UID,
      status: 'pending',
      storagePath: `photoVerification/${UID}/upload1.jpg`,
    },
  };
}

function contactFiles() {
  return [
    `users/${UID}/profile/a.jpg`,
    `photoVerification/${UID}/selfie.jpg`,
    `affiliationVerification/${UID}/work/proof.jpg`,
    `affiliationVerification/${UID}/school/proof.png`,
    // 다른 사용자 파일은 절대 지우면 안 된다.
    `users/${OTHER}/profile/keep.jpg`,
    `photoVerification/${OTHER}/keep.jpg`,
    `affiliationVerification/${OTHER}/work/keep.jpg`,
  ];
}

test('3-4A: 탈퇴 시 연락처 식별자·sync limit·사진 인증 요청을 삭제한다', async () => {
  const ctx = await runDelete({ seed: contactSeed(), files: contactFiles() });

  assert.equal(ctx.db.docs.has(`privatePhoneIdentifiers/${UID}`), false);
  assert.equal(ctx.db.docs.has(`contactAvoidanceSyncLimits/${UID}`), false);
  assert.equal(ctx.db.docs.has(`photoVerificationRequests/${UID}`), false);
});

test('3-4A: outbound/inbound owner relation과 본인 pair만 삭제한다', async () => {
  const ctx = await runDelete({ seed: contactSeed(), files: contactFiles() });

  // 내 소유 관계
  assert.equal(
    ctx.db.docs.has(`users/${UID}/contactAvoidanceMatches/${OTHER}`),
    false,
  );
  // 상대가 나를 가리키던 관계
  assert.equal(
    ctx.db.docs.has(`users/${OTHER}/contactAvoidanceMatches/${UID}`),
    false,
  );
  // 내가 포함된 pair
  assert.equal(
    ctx.db.docs.has(`contactAvoidancePairs/${PAIR_WITH_OTHER}`),
    false,
  );
  // 무관한 pair와 다른 사용자의 관계는 그대로
  assert.equal(
    ctx.db.docs.has(`contactAvoidancePairs/${PAIR_UNRELATED}`),
    true,
  );
  assert.equal(
    ctx.db.docs.has(`users/${OTHER}/contactAvoidanceMatches/${THIRD}`),
    true,
  );
});

test('3-4A: 세 Storage prefix를 모두 정리하고 남의 파일은 두지 않는다', async () => {
  const ctx = await runDelete({ seed: contactSeed(), files: contactFiles() });

  const deleted = ctx.db.operations
    .concat(ctx.bucket.operations)
    .filter((op) => typeof op === 'string' && op.startsWith('storageDelete:'))
    .map((op) => op.slice('storageDelete:'.length));

  assert.ok(deleted.includes(`users/${UID}/profile/a.jpg`));
  assert.ok(deleted.includes(`photoVerification/${UID}/selfie.jpg`));
  assert.ok(deleted.includes(`affiliationVerification/${UID}/work/proof.jpg`));
  assert.ok(deleted.includes(`affiliationVerification/${UID}/school/proof.png`));

  for (const kept of [
    `users/${OTHER}/profile/keep.jpg`,
    `photoVerification/${OTHER}/keep.jpg`,
    `affiliationVerification/${OTHER}/work/keep.jpg`,
  ]) {
    assert.equal(deleted.includes(kept), false, kept);
  }
});

test('3-4A: 이미 없는 문서·파일에서도 멱등하게 성공한다', async () => {
  // 지인 피하기/인증 데이터가 전혀 없는 상태(이미 지워졌거나 사용한 적 없음)
  const ctx = await runDelete({
    seed: seed(),
    files: [`users/${UID}/profile/a.jpg`],
  });
  assert.equal(ctx.db.docs.has(`privatePhoneIdentifiers/${UID}`), false);

  // pair만 남고 관계는 이미 사라진 부분 삭제 상태에서도 성공한다.
  const partial = {
    ...seed(),
    [`contactAvoidancePairs/${PAIR_WITH_OTHER}`]: {
      participants: [OTHER, UID].sort(),
    },
  };
  const ctx2 = await runDelete({ seed: partial, files: [] });
  assert.equal(
    ctx2.db.docs.has(`contactAvoidancePairs/${PAIR_WITH_OTHER}`),
    false,
  );
});

test('3-4A: Auth는 여전히 마지막에 삭제되고 로그에 raw 값이 없다', async () => {
  const ctx = await runDelete({ seed: contactSeed(), files: contactFiles() });

  assert.deepEqual(ctx.auth.deleted, [UID], 'Auth 삭제가 수행돼야 한다');
  // Auth 삭제 시점에 Firestore/Storage 정리는 이미 끝나 있어야 한다.
  assert.equal(ctx.db.docs.has(`privatePhoneIdentifiers/${UID}`), false);
  assert.equal(ctx.db.docs.has(`contactAvoidancePairs/${PAIR_WITH_OTHER}`), false);

  const logged = JSON.stringify(ctx.loggerRecords);
  assert.equal(logged.includes(UID), false);
  assert.equal(logged.includes('photoVerification/'), false);
  assert.equal(logged.includes('affiliationVerification/'), false);
  assert.equal(logged.includes('privatePhoneIdentifiers'), false);
});

test('3-4A: 기존 match/message/report 익명화 계약은 그대로다', async () => {
  const ctx = await runDelete({ seed: contactSeed(), files: contactFiles() });

  const match = ctx.db.docs.get('matches/m1');
  assert.ok(match, '매치 문서는 보존된다');
  assert.equal(match.participants.includes(UID), false);
  assert.ok(match.participants.includes(DELETED_ID));

  const message = ctx.db.docs.get('matches/m1/messages/msg-other');
  assert.ok(message, '상대 메시지는 보존된다');
  assert.equal(message.text, 'other body must stay');

  assert.ok(ctx.db.docs.get('reports/r1'), '신고는 보존된다');
});

// ── Phase 4-2: 커뮤니티 데이터 수명주기 ────────────────────────────────────

function communitySeed() {
  return {
    ...seed(),
    'communityPosts/mine': {
      surface: 'lounge',
      authorUid: UID,
      authorSnapshot: { uid: UID, displayName: 'Secret Name', photoUrl: 'p' },
      text: 'my lounge post',
      status: 'active',
      visibility: 'authenticated',
      reactionCount: 0,
      commentCount: 0,
      schemaVersion: 1,
    },
    'communityPosts/theirs': {
      surface: 'lounge',
      authorUid: OTHER,
      authorSnapshot: { uid: OTHER, displayName: 'Other', photoUrl: '' },
      text: 'other lounge post',
      status: 'active',
      visibility: 'authenticated',
      reactionCount: 1,
      commentCount: 1,
      schemaVersion: 1,
    },
    'communityPosts/theirs/comments/c1': {
      postId: 'theirs',
      authorUid: UID,
      authorSnapshot: { uid: UID, displayName: 'Secret Name' },
      text: 'my comment',
      status: 'active',
      schemaVersion: 1,
    },
    [`communityPosts/theirs/reactions/${UID}`]: { uid: UID, type: 'like' },
    'communityReports/rep-mine': {
      reporterUid: UID,
      reportedUid: OTHER,
      targetType: 'post',
      postId: 'theirs',
      commentId: '',
      reason: 'other',
    },
    'communityReports/rep-others': {
      reporterUid: OTHER,
      reportedUid: UID,
      targetType: 'post',
      postId: 'mine',
      commentId: '',
      reason: 'other',
    },
  };
}

test('4-2: 탈퇴 시 커뮤니티 게시물/댓글은 익명 soft remove, 반응은 삭제된다', async () => {
  const ctx = await runDelete({ seed: communitySeed() });

  const post = ctx.db.docs.get('communityPosts/mine');
  assert.ok(post, '게시물 문서는 보존된다(운영 검토 참조)');
  assert.equal(post.status, 'removed');
  assert.equal(post.authorUid, DELETED_ID);
  assert.equal(post.authorSnapshot.uid, DELETED_ID);
  assert.equal(post.authorSnapshot.displayName, '탈퇴한 사용자');
  assert.equal(post.authorSnapshot.photoUrl, '');

  const comment = ctx.db.docs.get('communityPosts/theirs/comments/c1');
  assert.equal(comment.status, 'removed');
  assert.equal(comment.authorUid, DELETED_ID);
  assert.equal(comment.authorSnapshot.displayName, '탈퇴한 사용자');

  // 상대 게시물은 유지되고 카운트만 안전하게 줄어든다.
  const theirs = ctx.db.docs.get('communityPosts/theirs');
  assert.equal(theirs.status, 'active');
  assert.equal(theirs.commentCount, 0);
  assert.equal(theirs.reactionCount, 0);
  assert.equal(ctx.db.docs.has(`communityPosts/theirs/reactions/${UID}`), false);

  // 신고는 보존하되 신고자만 pseudonym으로 바꾼다.
  assert.equal(ctx.db.docs.get('communityReports/rep-mine').reporterUid, DELETED_ID);
  assert.equal(ctx.db.docs.get('communityReports/rep-others').reporterUid, OTHER);

  // Auth 삭제는 여전히 마지막이다.
  assert.deepEqual(ctx.auth.deleted, [UID]);
  const job = ctx.db.docs.get(`_accountDeletionJobs/${UID_HASH}`);
  assert.equal(job.status, 'COMPLETED');

  // 로그에 raw UID/본문이 남지 않는다.
  const logged = JSON.stringify(ctx.loggerRecords);
  assert.equal(logged.includes(UID), false);
  assert.equal(logged.includes('my lounge post'), false);
  assert.equal(logged.includes('my comment'), false);
});
