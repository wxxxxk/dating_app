'use strict';

// Phase 3-4 — 지인 피하기 서버 core 테스트.
//
// Firestore/Auth를 fake로 주입해 입력 검증, HMAC 저장 계약, 매칭 diff,
// reciprocal pair 유지, cooldown, 응답·로그의 개인정보 미노출을 확인한다.

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { test } = require('node:test');

const {
  MAX_CONTACT_DIGESTS,
  SYNC_COOLDOWN_MS,
  contactAvoidancePairId,
  contactHashFromDigest,
  contactHashFromPhoneNumber,
  isContactAvoidancePair,
  normalizePhoneNumber,
  syncAvoidContactsCore,
  syncPrivatePhoneIdentifier,
  validateSyncInput,
} = require('../lib/contact_avoidance');

const ME = 'me-uid';
const FRIEND = 'friend-uid';
const OTHER = 'other-uid';
const PEPPER = 'test-pepper-value';
/** 실제 Firestore Timestamp처럼 toMillis()를 제공해 cooldown 로직을 태운다. */
function fakeTimestamp(millis) {
  return { toMillis: () => millis, __serverTimestamp: true };
}

const PHONE_FRIEND = '+821012345678';
const PHONE_OTHER = '+821022223333';

function digestOf(phone) {
  return crypto.createHash('sha256').update(phone).digest('hex');
}

class FakeHttpsError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

/**
 * 최소 fake Firestore. 문서 경로 → data 맵으로 관리하고 batch/get/where 만
 * 지원한다. 실제 쿼리 의미(in 조회)도 흉내 낸다.
 */
function createFakeDb({ docs = {} } = {}) {
  const store = new Map(Object.entries(docs));
  const calls = { writes: [], deletes: [] };

  function docRef(path) {
    return {
      path,
      get: async () => ({
        exists: store.has(path),
        id: path.split('/').pop(),
        data: () => store.get(path),
      }),
      set: async (data, options) => {
        const prev = options?.merge ? store.get(path) || {} : {};
        store.set(path, { ...prev, ...data });
        calls.writes.push({ path, data });
      },
      delete: async () => {
        store.delete(path);
        calls.deletes.push(path);
      },
      collection: (name) => collectionRef(`${path}/${name}`),
    };
  }

  function collectionRef(prefix) {
    return {
      prefix,
      doc: (id) => docRef(`${prefix}/${id}`),
      where(field, op, value) {
        return {
          get: async () => {
            const docsOut = [];
            for (const [path, data] of store.entries()) {
              if (!path.startsWith(`${prefix}/`)) continue;
              if (path.slice(prefix.length + 1).includes('/')) continue;
              const actual = data?.[field];
              const hit =
                op === 'in' ? value.includes(actual) : actual === value;
              if (hit) {
                docsOut.push({
                  id: path.split('/').pop(),
                  data: () => data,
                });
              }
            }
            return { docs: docsOut };
          },
        };
      },
      get: async () => {
        const docsOut = [];
        for (const [path, data] of store.entries()) {
          if (!path.startsWith(`${prefix}/`)) continue;
          if (path.slice(prefix.length + 1).includes('/')) continue;
          docsOut.push({ id: path.split('/').pop(), data: () => data });
        }
        return { docs: docsOut };
      },
    };
  }

  return {
    store,
    calls,
    collection: collectionRef,
    doc: (path) => docRef(path),
    batch() {
      const ops = [];
      return {
        set: (ref, data, options) => ops.push({ ref, data, options }),
        delete: (ref) => ops.push({ ref, delete: true }),
        commit: async () => {
          for (const op of ops) {
            if (op.delete) {
              await op.ref.delete();
            } else {
              await op.ref.set(op.data, op.options);
            }
          }
        },
      };
    },
  };
}

function createAuth(users) {
  return {
    getUser: async (uid) => {
      if (!users[uid]) throw new Error('not found');
      return users[uid];
    },
  };
}

function createLogger() {
  const lines = [];
  return {
    lines,
    log: (m) => lines.push(String(m)),
    warn: (m) => lines.push(String(m)),
    error: (m) => lines.push(String(m)),
  };
}

/** 전화 인증을 마친 나 + 연락처에 저장된 가입자들이 있는 기본 상태. */
function baseDocs() {
  return {
    [`users/${ME}`]: { verifications: { phone: true } },
    [`users/${FRIEND}`]: { verifications: { phone: true } },
    [`users/${OTHER}`]: { verifications: { phone: true } },
    [`privatePhoneIdentifiers/${ME}`]: {
      uid: ME,
      contactHash: contactHashFromDigest(digestOf('+821000000000'), PEPPER),
    },
    [`privatePhoneIdentifiers/${FRIEND}`]: {
      uid: FRIEND,
      contactHash: contactHashFromDigest(digestOf(PHONE_FRIEND), PEPPER),
    },
    [`privatePhoneIdentifiers/${OTHER}`]: {
      uid: OTHER,
      contactHash: contactHashFromDigest(digestOf(PHONE_OTHER), PEPPER),
    },
  };
}

async function sync({
  uid = ME,
  data,
  db = createFakeDb({ docs: baseDocs() }),
  auth = createAuth({
    [ME]: { phoneNumber: '+821000000000' },
    [FRIEND]: { phoneNumber: PHONE_FRIEND },
    [OTHER]: { phoneNumber: PHONE_OTHER },
  }),
  logger = createLogger(),
  now = Date.now(),
} = {}) {
  const result = await syncAvoidContactsCore({
    request: { auth: { uid }, data },
    db,
    auth,
    pepper: PEPPER,
    HttpsError: FakeHttpsError,
    serverTimestamp: () => fakeTimestamp(now),
    logger,
    now,
  });
  return { result, db, logger };
}

// ── 권한/입력 검증 ───────────────────────────────────────────────────────
test('1. 미인증 호출은 거부된다', async () => {
  await assert.rejects(
    () =>
      syncAvoidContactsCore({
        request: { data: { enabled: true, contactDigests: [] } },
        db: createFakeDb(),
        auth: createAuth({}),
        pepper: PEPPER,
        HttpsError: FakeHttpsError,
        serverTimestamp: () => fakeTimestamp(Date.now()),
      }),
    (error) => error.code === 'unauthenticated',
  );
});

test('3. 전화 인증이 없으면 거부된다', async () => {
  // Auth에 전화번호가 없는 경우
  await assert.rejects(
    () =>
      sync({
        data: { enabled: true, contactDigests: [] },
        auth: createAuth({ [ME]: { phoneNumber: null } }),
      }),
    (error) => error.code === 'failed-precondition',
  );
  // private profile의 phone 배지가 false인 경우
  const db = createFakeDb({
    docs: { ...baseDocs(), [`users/${ME}`]: { verifications: { phone: false } } },
  });
  await assert.rejects(
    () => sync({ data: { enabled: true, contactDigests: [] }, db }),
    (error) => error.code === 'failed-precondition',
  );
});

test('4~6. 입력 형식 검증', () => {
  const bad = [
    null,
    'nope',
    [],
    {},
    { enabled: 'true' },
    { enabled: true, contactDigests: 'x' },
    { enabled: true, contactDigests: ['nothex'] },
    { enabled: true, contactDigests: [digestOf(PHONE_FRIEND).toUpperCase()] },
    { enabled: true, contactDigests: [''] },
    { enabled: true, contactDigests: [123] },
    // unknown field
    { enabled: true, contactDigests: [], extra: 1 },
    // 끄기인데 digest를 함께 보냄
    { enabled: false, contactDigests: [digestOf(PHONE_FRIEND)] },
  ];
  for (const data of bad) {
    assert.throws(
      () => validateSyncInput(data, FakeHttpsError),
      (error) => error.code === 'invalid-argument',
      JSON.stringify(data),
    );
  }

  // 2000개 초과
  const tooMany = Array.from({ length: MAX_CONTACT_DIGESTS + 1 }, (_, i) =>
    digestOf(`+8210000${String(i).padStart(5, '0')}`),
  );
  assert.throws(
    () =>
      validateSyncInput(
        { enabled: true, contactDigests: tooMany },
        FakeHttpsError,
      ),
    (error) => error.code === 'invalid-argument',
  );
});

test('7. 중복 digest는 하나로 합쳐진다', () => {
  const digest = digestOf(PHONE_FRIEND);
  const parsed = validateSyncInput(
    { enabled: true, contactDigests: [digest, digest, digest] },
    FakeHttpsError,
  );
  assert.deepEqual(parsed.digests, [digest]);
});

// ── 매칭/pair ────────────────────────────────────────────────────────────
test('8~12. 매칭된 가입자에 owner relation과 pair를 만든다', async () => {
  const { result, db } = await sync({
    data: {
      enabled: true,
      contactDigests: [
        digestOf(PHONE_FRIEND),
        digestOf('+821099998888'), // 가입자 아님
        digestOf('+821000000000'), // 10. 자기 자신은 제외
      ],
    },
  });

  assert.deepEqual(result, { enabled: true, contactCount: 3, hiddenCount: 1 });

  // 11. owner relation
  const owner = db.store.get(`users/${ME}/contactAvoidanceMatches/${FRIEND}`);
  assert.equal(owner.targetUid, FRIEND);
  // 12. pair (deterministic id, 정렬된 participants)
  const pairId = contactAvoidancePairId(ME, FRIEND);
  const pair = db.store.get(`contactAvoidancePairs/${pairId}`);
  assert.deepEqual(pair.participants, [ME, FRIEND].sort());
  // 9. 저장되는 값은 HMAC이며 client digest 자체는 어디에도 없다.
  const stored = JSON.stringify([...db.store.entries()]);
  assert.equal(stored.includes(digestOf(PHONE_FRIEND)), false);
  assert.equal(stored.includes(PHONE_FRIEND), false);

  // 8. HMAC은 pepper에 의존한다(다른 pepper면 값이 달라진다).
  assert.notEqual(
    contactHashFromDigest(digestOf(PHONE_FRIEND), PEPPER),
    contactHashFromDigest(digestOf(PHONE_FRIEND), 'other-pepper'),
  );
  // 자기 자신은 owner relation을 만들지 않는다.
  assert.equal(db.store.has(`users/${ME}/contactAvoidanceMatches/${ME}`), false);
});

test('13~15. 관계 제거 시 reciprocal pair는 유지, 없으면 삭제', async () => {
  const pairId = contactAvoidancePairId(ME, FRIEND);
  // 13. 상대도 나를 보유한 상태에서 내가 연락처를 지우면 pair는 유지된다.
  const withReciprocal = createFakeDb({
    docs: {
      ...baseDocs(),
      [`users/${ME}/contactAvoidanceMatches/${FRIEND}`]: { targetUid: FRIEND },
      [`users/${FRIEND}/contactAvoidanceMatches/${ME}`]: { targetUid: ME },
      [`contactAvoidancePairs/${pairId}`]: { participants: [ME, FRIEND].sort() },
    },
  });
  await sync({
    data: { enabled: true, contactDigests: [] },
    db: withReciprocal,
  });
  assert.equal(
    withReciprocal.store.has(`users/${ME}/contactAvoidanceMatches/${FRIEND}`),
    false,
    'owner relation은 제거된다',
  );
  assert.equal(
    withReciprocal.store.has(`contactAvoidancePairs/${pairId}`),
    true,
    '상대가 여전히 보유하므로 pair는 유지',
  );

  // 15. 양쪽 모두 보유하지 않으면 pair가 삭제된다.
  const withoutReciprocal = createFakeDb({
    docs: {
      ...baseDocs(),
      [`users/${ME}/contactAvoidanceMatches/${FRIEND}`]: { targetUid: FRIEND },
      [`contactAvoidancePairs/${pairId}`]: { participants: [ME, FRIEND].sort() },
    },
  });
  await sync({
    data: { enabled: true, contactDigests: [] },
    db: withoutReciprocal,
  });
  assert.equal(
    withoutReciprocal.store.has(`contactAvoidancePairs/${pairId}`),
    false,
  );
});

test('16~17. settings 요약 갱신과 끄기', async () => {
  const db = createFakeDb({ docs: baseDocs() });
  await sync({
    data: { enabled: true, contactDigests: [digestOf(PHONE_FRIEND)] },
    db,
  });
  let settings = db.store.get(
    `users/${ME}/contactAvoidanceSettings/current`,
  );
  assert.equal(settings.enabled, true);
  assert.equal(settings.contactCount, 1);
  assert.equal(settings.hiddenCount, 1);

  // 17~18. 끄기는 cooldown과 무관하게 즉시 허용된다.
  const { result } = await sync({
    data: { enabled: false, contactDigests: [] },
    db,
    now: Date.now(),
  });
  assert.deepEqual(result, { enabled: false, contactCount: 0, hiddenCount: 0 });
  settings = db.store.get(`users/${ME}/contactAvoidanceSettings/current`);
  assert.equal(settings.enabled, false);
  assert.equal(settings.contactCount, 0);
  assert.equal(
    db.store.has(`users/${ME}/contactAvoidanceMatches/${FRIEND}`),
    false,
  );
});

test('19. 30초 안에 다시 동기화하면 거부된다(끄기는 허용)', async () => {
  const db = createFakeDb({ docs: baseDocs() });
  const start = Date.now();
  await sync({ data: { enabled: true, contactDigests: [] }, db, now: start });

  await assert.rejects(
    () =>
      sync({
        data: { enabled: true, contactDigests: [] },
        db,
        now: start + SYNC_COOLDOWN_MS - 1000,
      }),
    (error) => error.code === 'resource-exhausted',
  );

  // 끄기는 cooldown 무관
  await assert.doesNotReject(() =>
    sync({
      data: { enabled: false, contactDigests: [] },
      db,
      now: start + 1000,
    }),
  );

  // cooldown이 지나면 다시 허용
  await assert.doesNotReject(() =>
    sync({
      data: { enabled: true, contactDigests: [] },
      db,
      now: start + SYNC_COOLDOWN_MS + 1000,
    }),
  );
});

// ── 개인정보 ────────────────────────────────────────────────────────────
test('20~21. 응답·로그에 UID/digest/pairId/전화번호가 없다', async () => {
  const digest = digestOf(PHONE_FRIEND);
  const { result, logger } = await sync({
    data: { enabled: true, contactDigests: [digest] },
  });

  assert.deepEqual(Object.keys(result).sort(), [
    'contactCount',
    'enabled',
    'hiddenCount',
  ]);
  const serialized = JSON.stringify(result);
  for (const secret of [
    ME,
    FRIEND,
    digest,
    PHONE_FRIEND,
    contactAvoidancePairId(ME, FRIEND),
    contactHashFromDigest(digest, PEPPER),
  ]) {
    assert.equal(serialized.includes(secret), false);
  }

  const joined = logger.lines.join('\n');
  for (const secret of [
    ME,
    FRIEND,
    digest,
    PHONE_FRIEND,
    contactAvoidancePairId(ME, FRIEND),
    contactHashFromDigest(digest, PEPPER),
  ]) {
    assert.equal(joined.includes(secret), false);
  }
  assert.ok(/uidHash=[0-9a-f]{8}/.test(joined));
  assert.ok(joined.includes('contactCount=1'));
});

// ── private identifier ──────────────────────────────────────────────────
test('22~23. 전화 인증 상태에 따라 identifier를 만들고 지운다', async () => {
  const db = createFakeDb();
  // 22. 인증 완료 → 생성
  await syncPrivatePhoneIdentifier({
    uid: ME,
    phoneNumber: PHONE_FRIEND,
    phoneVerified: true,
    pepper: PEPPER,
    db,
    serverTimestamp: () => fakeTimestamp(Date.now()),
  });
  const stored = db.store.get(`privatePhoneIdentifiers/${ME}`);
  assert.equal(stored.uid, ME);
  assert.equal(
    stored.contactHash,
    contactHashFromPhoneNumber(PHONE_FRIEND, PEPPER),
  );
  // 원문·단순 digest는 저장되지 않는다.
  const serialized = JSON.stringify(stored);
  assert.equal(serialized.includes(PHONE_FRIEND), false);
  assert.equal(serialized.includes(digestOf(PHONE_FRIEND)), false);

  // 23. 인증이 풀리면 삭제
  await syncPrivatePhoneIdentifier({
    uid: ME,
    phoneNumber: PHONE_FRIEND,
    phoneVerified: false,
    pepper: PEPPER,
    db,
    serverTimestamp: () => fakeTimestamp(Date.now()),
  });
  assert.equal(db.store.has(`privatePhoneIdentifiers/${ME}`), false);

  // 번호가 없으면 만들지 않는다.
  await syncPrivatePhoneIdentifier({
    uid: ME,
    phoneNumber: null,
    phoneVerified: true,
    pepper: PEPPER,
    db,
    serverTimestamp: () => fakeTimestamp(Date.now()),
  });
  assert.equal(db.store.has(`privatePhoneIdentifiers/${ME}`), false);
});

// ── like/match 차단 판정 ────────────────────────────────────────────────
test('25~26. pair가 있으면 차단 판정, 없으면 통과', async () => {
  const pairId = contactAvoidancePairId(ME, FRIEND);
  const db = createFakeDb({
    docs: {
      [`contactAvoidancePairs/${pairId}`]: { participants: [ME, FRIEND].sort() },
    },
  });

  assert.equal(
    await isContactAvoidancePair({ db, uidA: ME, uidB: FRIEND }),
    true,
  );
  // 순서가 바뀌어도 같은 판정
  assert.equal(
    await isContactAvoidancePair({ db, uidA: FRIEND, uidB: ME }),
    true,
  );
  // pair가 없는 상대는 통과
  assert.equal(
    await isContactAvoidancePair({ db, uidA: ME, uidB: OTHER }),
    false,
  );
  assert.equal(await isContactAvoidancePair({ db, uidA: ME, uidB: ME }), false);
  assert.equal(await isContactAvoidancePair({ db, uidA: ME, uidB: '' }), false);
});

test('pairId는 순서와 무관하게 같고 UID를 노출하지 않는다', () => {
  const a = contactAvoidancePairId(ME, FRIEND);
  const b = contactAvoidancePairId(FRIEND, ME);
  assert.equal(a, b);
  assert.match(a, /^[0-9a-f]{64}$/);
  assert.equal(a.includes(ME), false);
  assert.equal(a.includes(FRIEND), false);
});

test('normalizePhoneNumber는 E.164만 통과시킨다', () => {
  assert.equal(normalizePhoneNumber('+8210 1234-5678'), '+821012345678');
  for (const bad of ['01012345678', '821012345678', '', null, undefined, '+123']) {
    assert.equal(normalizePhoneNumber(bad), null);
  }
});
