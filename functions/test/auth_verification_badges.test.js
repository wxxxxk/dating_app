'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  deriveAuthVerificationBadges,
  syncAuthVerificationBadgesCore,
} = require('../lib/auth_verification_badges');

class FakeHttpsError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

const SERVER_TIMESTAMP = Object.freeze({ __serverTimestamp: true });

function createSnap(exists, data) {
  return {
    exists,
    data() {
      return data;
    },
  };
}

function createFakeDb({
  uid = 'caller-uid',
  userExists = true,
  publicExists = true,
  userData = { verifications: { email: false, phone: false, photo: false } },
  publicData = { verifications: { email: false, phone: false, photo: false } },
  throwOnUpdate = false,
} = {}) {
  const calls = {
    collections: [],
    docs: [],
    gets: [],
    pendingUpdates: [],
    committedUpdates: [],
    transactions: 0,
  };
  const refs = new Map();

  function refFor(collectionName, id) {
    const path = `${collectionName}/${id}`;
    if (!refs.has(path)) {
      refs.set(path, { collectionName, id, path });
    }
    return refs.get(path);
  }

  const db = {
    calls,
    collection(collectionName) {
      calls.collections.push(collectionName);
      return {
        doc(id) {
          calls.docs.push({ collectionName, id });
          return refFor(collectionName, id);
        },
      };
    },
    async runTransaction(callback) {
      calls.transactions += 1;
      const transaction = {
        async get(ref) {
          calls.gets.push(ref.path);
          if (ref.path === `users/${uid}`) {
            return createSnap(userExists, userData);
          }
          if (ref.path === `publicProfiles/${uid}`) {
            return createSnap(publicExists, publicData);
          }
          return createSnap(false, undefined);
        },
        update(ref, payload) {
          if (throwOnUpdate) {
            throw new Error('simulated transaction update failure');
          }
          calls.pendingUpdates.push({ path: ref.path, payload });
        },
      };
      const result = await callback(transaction);
      calls.committedUpdates.push(...calls.pendingUpdates);
      calls.pendingUpdates = [];
      return result;
    },
  };
  return db;
}

function createAuth(userRecord, calls = []) {
  return {
    async getUser(uid) {
      calls.push(uid);
      return userRecord;
    },
  };
}

function createLogger() {
  const records = [];
  return {
    records,
    log(message) {
      records.push(String(message));
    },
    error(message) {
      records.push(String(message));
    },
  };
}

async function callSync({
  request = { auth: { uid: 'caller-uid' }, data: undefined },
  userRecord = {},
  db = createFakeDb(),
  logger = createLogger(),
  authCalls = [],
} = {}) {
  const result = await syncAuthVerificationBadgesCore({
    request,
    auth: createAuth(userRecord, authCalls),
    db,
    HttpsError: FakeHttpsError,
    serverTimestamp: () => SERVER_TIMESTAMP,
    logger,
  });
  return { result, db, logger, authCalls };
}

test('verified email + email 존재 -> email true', () => {
  assert.deepEqual(
    deriveAuthVerificationBadges({
      email: 'user@example.test',
      emailVerified: true,
    }),
    { email: true, phone: false, photo: false },
  );
});

test('emailVerified true지만 email 없음 -> false', () => {
  assert.equal(
    deriveAuthVerificationBadges({ emailVerified: true }).email,
    false,
  );
});

test('email 존재하지만 emailVerified false -> false', () => {
  assert.equal(
    deriveAuthVerificationBadges({
      email: 'user@example.test',
      emailVerified: false,
    }).email,
    false,
  );
});

test('phoneNumber + phone provider -> phone true', () => {
  assert.equal(
    deriveAuthVerificationBadges({
      phoneNumber: '+821012345678',
      providerData: [{ providerId: 'phone' }],
    }).phone,
    true,
  );
});

test('phoneNumber만 있고 phone provider 없음 -> false', () => {
  assert.equal(
    deriveAuthVerificationBadges({
      phoneNumber: '+821012345678',
      providerData: [],
    }).phone,
    false,
  );
});

test('phone provider만 있고 phoneNumber 없음 -> false', () => {
  assert.equal(
    deriveAuthVerificationBadges({
      providerData: [{ providerId: 'phone' }],
    }).phone,
    false,
  );
});

test('photo는 항상 false이고 malformed userRecord도 모두 false', () => {
  assert.deepEqual(deriveAuthVerificationBadges(null), {
    email: false,
    phone: false,
    photo: false,
  });
  assert.deepEqual(
    deriveAuthVerificationBadges({
      email: 1,
      emailVerified: true,
      phoneNumber: '+821012345678',
      providerData: 'phone',
      photo: true,
    }),
    { email: false, phone: false, photo: false },
  );
});

test('request.auth 없음 -> unauthenticated', async () => {
  await assert.rejects(
    () => callSync({ request: { data: undefined } }),
    (error) => error.code === 'unauthenticated',
  );
});

test('targetUid 입력 -> invalid-argument', async () => {
  await assert.rejects(
    () =>
      callSync({
        request: { auth: { uid: 'caller-uid' }, data: { targetUid: 'other' } },
      }),
    (error) => error.code === 'invalid-argument',
  );
});

test('caller UID만 Auth 조회하고 users/publicProfiles 동일 UID만 대상', async () => {
  const authCalls = [];
  const db = createFakeDb({
    userData: { verifications: { email: false, phone: false, photo: false } },
    publicData: { verifications: { email: false, phone: false, photo: false } },
  });
  await callSync({
    userRecord: {
      email: 'user@example.test',
      emailVerified: true,
    },
    db,
    authCalls,
  });
  assert.deepEqual(authCalls, ['caller-uid']);
  assert.deepEqual(db.calls.gets.sort(), [
    'publicProfiles/caller-uid',
    'users/caller-uid',
  ]);
});

test('users 문서가 없으면 failed-precondition', async () => {
  await assert.rejects(
    () => callSync({ db: createFakeDb({ userExists: false }) }),
    (error) => error.code === 'failed-precondition',
  );
});

test('publicProfiles 문서가 없으면 failed-precondition', async () => {
  await assert.rejects(
    () => callSync({ db: createFakeDb({ publicExists: false }) }),
    (error) => error.code === 'failed-precondition',
  );
});

test('두 문서 모두 canonical이면 write 없음', async () => {
  const db = createFakeDb({
    userData: { verifications: { email: true, phone: true, photo: false } },
    publicData: { verifications: { email: true, phone: true, photo: false } },
  });
  const { result } = await callSync({
    userRecord: {
      email: 'user@example.test',
      emailVerified: true,
      phoneNumber: '+821012345678',
      providerData: [{ providerId: 'phone' }],
    },
    db,
  });
  assert.equal(result.changed, false);
  assert.equal(result.writesPerformed, 0);
  assert.deepEqual(db.calls.committedUpdates, []);
});

test('한쪽 불일치 시 두 문서 모두 canonical update', async () => {
  const db = createFakeDb({
    userData: { verifications: { email: false, phone: false, photo: false } },
    publicData: { verifications: { email: true, phone: false, photo: false } },
  });
  const { result } = await callSync({
    userRecord: {
      email: 'user@example.test',
      emailVerified: true,
    },
    db,
  });
  assert.equal(result.changed, true);
  assert.equal(result.writesPerformed, 2);
  assert.deepEqual(
    db.calls.committedUpdates.map((entry) => entry.path).sort(),
    ['publicProfiles/caller-uid', 'users/caller-uid'],
  );
  const publicUpdate = db.calls.committedUpdates.find(
    (entry) => entry.path === 'publicProfiles/caller-uid',
  ).payload;
  assert.deepEqual(publicUpdate.verifications, {
    email: true,
    phone: false,
    photo: false,
  });
});

test('기존 true photo도 false로 교정', async () => {
  const db = createFakeDb({
    userData: { verifications: { email: false, phone: false, photo: true } },
    publicData: { verifications: { email: false, phone: false, photo: true } },
  });
  const { result } = await callSync({ db });
  assert.deepEqual(result.verifications, {
    email: false,
    phone: false,
    photo: false,
  });
  for (const update of db.calls.committedUpdates) {
    assert.equal(update.payload.verifications.photo, false);
  }
});

test('transaction 실패 시 partial write 없음', async () => {
  const db = createFakeDb({
    userData: { verifications: { email: false, phone: false, photo: true } },
    publicData: { verifications: { email: false, phone: false, photo: true } },
    throwOnUpdate: true,
  });
  await assert.rejects(
    () => callSync({ db }),
    (error) => error.code === 'internal',
  );
  assert.deepEqual(db.calls.committedUpdates, []);
});

test('안전한 반환 payload만 제공', async () => {
  const { result } = await callSync({
    userRecord: {
      email: 'user@example.test',
      emailVerified: true,
      phoneNumber: '+821012345678',
      providerData: [{ providerId: 'phone' }],
    },
  });
  assert.deepEqual(Object.keys(result).sort(), [
    'changed',
    'verifications',
    'writesPerformed',
  ]);
  assert.deepEqual(Object.keys(result.verifications).sort(), [
    'email',
    'phone',
    'photo',
  ]);
  assert.equal(JSON.stringify(result).includes('user@example.test'), false);
  assert.equal(JSON.stringify(result).includes('+821012345678'), false);
  assert.equal(JSON.stringify(result).includes('caller-uid'), false);
});

test('PII 로그 없음', async () => {
  const logger = createLogger();
  await callSync({
    request: { auth: { uid: 'raw-user-uid' }, data: undefined },
    userRecord: {
      email: 'private@example.test',
      emailVerified: true,
      phoneNumber: '+821012345678',
      providerData: [{ providerId: 'phone' }],
    },
    db: createFakeDb({
      uid: 'raw-user-uid',
      userData: { verifications: { email: false, phone: false, photo: false } },
      publicData: { verifications: { email: false, phone: false, photo: false } },
    }),
    logger,
  });
  const text = logger.records.join('\n');
  assert.equal(text.includes('raw-user-uid'), false);
  assert.equal(text.includes('private@example.test'), false);
  assert.equal(text.includes('+821012345678'), false);
  assert.match(text, /uidHash=[0-9a-f]{8}/);
});

test('module import side effect 없음', () => {
  assert.equal(typeof deriveAuthVerificationBadges, 'function');
});
