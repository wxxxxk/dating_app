'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const admin = require('firebase-admin');
const {
  applyAllUsers,
  applySingleUid,
  applySnapshotPair,
  assertApplyProjectAllowed,
  buildApplyPayload,
  emptyApplyStats,
  isAlreadyExistsError,
  parseApplyArgs,
} = require('../scripts/public_profile_backfill_apply');
const {
  normalizeFirestoreValue,
  toLogRecord,
} = require('../lib/public_profile_backfill');

const SERVER_TIMESTAMP = Object.freeze({ __serverTimestamp: true });

function timestamp(date) {
  const millis = date.getTime();
  return {
    seconds: Math.floor(millis / 1000),
    nanoseconds: (millis % 1000) * 1000000,
    toDate() {
      return new Date(millis);
    },
  };
}

function userData(overrides = {}) {
  return {
    displayName: 'private name',
    birthDate: timestamp(new Date(1995, 5, 15)),
    gender: 'female',
    bio: 'private bio',
    photoUrls: ['https://example.test/a.jpg'],
    updatedAt: timestamp(new Date(2026, 6, 1)),
    height: 170,
    religion: 'none',
    smoking: 'non_smoker',
    drinking: 'socially',
    jobCategory: 'design',
    jobTitle: 'designer',
    education: 'university',
    mbti: 'ENFP',
    interests: ['coffee', 'travel'],
    personalityTags: ['warm'],
    idealTags: ['kind'],
    relationshipGoal: 'serious_relationship',
    location: {
      lat: 37.56647,
      lng: 126.97796,
      updatedAt: timestamp(new Date(2026, 5, 1)),
      label: 'private label',
    },
    verifications: { email: true, phone: true, photo: true },
    boostUntil: timestamp(new Date(2030, 0, 1)),
    jelly: 999,
    fcmTokens: ['token'],
    ...overrides,
  };
}

function snapshot(id, exists, data) {
  return {
    id,
    exists,
    data() {
      return data;
    },
  };
}

function createPublicRef(id, options = {}) {
  const calls = {
    create: [],
    set: 0,
    update: 0,
    delete: 0,
  };
  return {
    id,
    path: `publicProfiles/${id}`,
    __collection: 'publicProfiles',
    calls,
    async create(payload) {
      calls.create.push(payload);
      if (options.createError) throw options.createError;
    },
    async set() {
      calls.set += 1;
      throw new Error('set should not be called');
    },
    async update() {
      calls.update += 1;
      throw new Error('update should not be called');
    },
    async delete() {
      calls.delete += 1;
      throw new Error('delete should not be called');
    },
  };
}

function createFakeDb({ users, publicExistsById = {}, createErrorById = {} }) {
  const calls = {
    usersCollectionGets: 0,
    publicCreates: [],
    userDocWrites: 0,
  };
  const refs = new Map();
  const userSnapshots = users.map((entry) => snapshot(entry.id, true, entry.data));

  function publicRefFor(id) {
    if (!refs.has(id)) {
      const ref = createPublicRef(id, {
        createError: createErrorById[id],
      });
      const originalCreate = ref.create.bind(ref);
      ref.create = async (payload) => {
        calls.publicCreates.push({ id, path: ref.path, collection: ref.__collection, payload });
        await originalCreate(payload);
      };
      refs.set(id, ref);
    }
    return refs.get(id);
  }

  return {
    calls,
    collection(name) {
      if (name === 'users') {
        return {
          doc(id) {
            return {
              id,
              __collection: 'users',
              async create() {
                calls.userDocWrites += 1;
              },
              async set() {
                calls.userDocWrites += 1;
              },
              async update() {
                calls.userDocWrites += 1;
              },
              async delete() {
                calls.userDocWrites += 1;
              },
            };
          },
          orderBy() {
            calls.usersCollectionGets += 1;
            return {
              limit() {
                return {
                  async get() {
                    return {
                      empty: userSnapshots.length === 0,
                      size: userSnapshots.length,
                      docs: userSnapshots,
                    };
                  },
                };
              },
            };
          },
        };
      }
      if (name === 'publicProfiles') {
        return {
          doc(id) {
            return publicRefFor(id);
          },
        };
      }
      throw new Error(`unexpected collection ${name}`);
    },
    async getAll(...refsToRead) {
      return refsToRead.map((ref) => {
        if (ref.__collection === 'publicProfiles' && publicExistsById[ref.id]) {
          return snapshot(ref.id, true, publicExistsById[ref.id]);
        }
        const user = ref.__collection === 'users'
          ? users.find((entry) => entry.id === ref.id)
          : null;
        if (user) {
          return snapshot(ref.id, true, user.data);
        }
        return snapshot(ref.id, false, null);
      });
    },
  };
}

function serverTimestamp() {
  return SERVER_TIMESTAMP;
}

function hasRecursiveUndefined(value) {
  if (value === undefined) return true;
  if (value === null) return false;
  if (Array.isArray(value)) return value.some((entry) => hasRecursiveUndefined(entry));
  if (typeof value === 'object') {
    return Object.values(value).some((entry) => hasRecursiveUndefined(entry));
  }
  return false;
}

function containsExactLocation(value) {
  const serialized = JSON.stringify(normalizeFirestoreValue(value));
  return serialized.includes('37.56647') ||
    serialized.includes('126.97796') ||
    serialized.includes('private label');
}

function assertCounterInvariants(stats) {
  assert.equal(stats.created, stats.writesSucceeded);
  assert.ok(stats.writesSucceeded <= stats.writesAttempted);
  assert.equal(
    stats.created + stats.alreadyExists + stats.skipped + stats.errors,
    stats.scanned,
  );
}

test('apply args require --apply before Firestore initialization', () => {
  assert.throws(
    () => parseApplyArgs(['--project', 'cvr-dating-app', '--confirm-project', 'cvr-dating-app']),
    /--apply is required/,
  );
});

test('apply args require confirm project', () => {
  assert.throws(
    () => parseApplyArgs(['--project', 'cvr-dating-app', '--apply']),
    /--confirm-project is required/,
  );
});

test('apply args reject project confirmation mismatch', () => {
  assert.throws(
    () => parseApplyArgs(['--project', 'cvr-dating-app', '--confirm-project', 'other', '--apply']),
    /must match/,
  );
});

test('apply project guard rejects wrong production project', () => {
  const original = process.env.FIRESTORE_EMULATOR_HOST;
  delete process.env.FIRESTORE_EMULATOR_HOST;
  try {
    assert.throws(() => assertApplyProjectAllowed('wrong-project'), /Refusing to apply/);
    assert.doesNotThrow(() => assertApplyProjectAllowed('cvr-dating-app'));
  } finally {
    if (original === undefined) {
      delete process.env.FIRESTORE_EMULATOR_HOST;
    } else {
      process.env.FIRESTORE_EMULATOR_HOST = original;
    }
  }
});

test('apply --help succeeds without Firebase initialization', () => {
  const before = admin.apps.length;
  assert.deepEqual(parseApplyArgs(['--help']), {
    project: null,
    confirmProject: null,
    apply: false,
    uid: null,
    limit: null,
    pageSize: 100,
    help: true,
  });
  assert.equal(admin.apps.length, before);
});

test('missing target creates one public profile', async () => {
  const ref = createPublicRef('user-1');
  const result = await applySnapshotPair(
    snapshot('user-1', true, userData()),
    snapshot('user-1', false, null),
    ref,
    { serverTimestamp },
  );
  assert.equal(result.status, 'created');
  assert.equal(ref.calls.create.length, 1);
  assert.equal(ref.path, 'publicProfiles/user-1');
});

test('existing target is alreadyExists and does not create', async () => {
  const ref = createPublicRef('user-1');
  const result = await applySnapshotPair(
    snapshot('user-1', true, userData()),
    snapshot('user-1', true, { schemaVersion: 1 }),
    ref,
    { serverTimestamp },
  );
  assert.equal(result.status, 'alreadyExists');
  assert.equal(ref.calls.create.length, 0);
});

test('create ALREADY_EXISTS is classified alreadyExists', async () => {
  const ref = createPublicRef('user-1', {
    createError: { code: 6, details: 'ALREADY_EXISTS' },
  });
  const result = await applySnapshotPair(
    snapshot('user-1', true, userData()),
    snapshot('user-1', false, null),
    ref,
    { serverTimestamp },
  );
  assert.equal(result.status, 'alreadyExists');
  assert.equal(result.writeAttempted, true);
  assert.equal(result.writeSucceeded, false);
  assert.equal(isAlreadyExistsError({ message: 'already exists' }), true);
  assert.equal(isAlreadyExistsError({ code: '6' }), true);
  assert.equal(isAlreadyExistsError({ code: 'already-exists' }), true);
  assert.equal(isAlreadyExistsError({ code: 'ALREADY_EXISTS' }), true);
});

test('create race alreadyExists updates counters without errors', async () => {
  const stats = emptyApplyStats('cvr-dating-app');
  const db = createFakeDb({
    users: [{ id: 'user-1', data: userData() }],
    createErrorById: {
      'user-1': { code: 'already-exists' },
    },
  });
  await applyAllUsers(db, { limit: 1, pageSize: 1 }, stats, { serverTimestamp });
  assert.equal(stats.scanned, 1);
  assert.equal(stats.alreadyExists, 1);
  assert.equal(stats.errors, 0);
  assert.equal(stats.writesAttempted, 1);
  assert.equal(stats.writesSucceeded, 0);
  assertCounterInvariants(stats);
});

test('apply never calls target update merge or delete', async () => {
  const ref = createPublicRef('user-1');
  await applySnapshotPair(
    snapshot('user-1', true, userData()),
    snapshot('user-1', false, null),
    ref,
    { serverTimestamp },
  );
  assert.equal(ref.calls.set, 0);
  assert.equal(ref.calls.update, 0);
  assert.equal(ref.calls.delete, 0);
});

test('apply does not modify users documents', async () => {
  const db = createFakeDb({ users: [{ id: 'user-1', data: userData() }] });
  const stats = emptyApplyStats('cvr-dating-app');
  await applySingleUid(db, 'user-1', stats, { serverTimestamp });
  assert.equal(db.calls.userDocWrites, 0);
});

test('apply payload uses safe verification defaults', () => {
  const payload = buildApplyPayload(userData(), serverTimestamp).payload;
  assert.deepEqual(payload.verifications, {
    email: false,
    phone: false,
    photo: false,
  });
});

test('apply payload keeps rankingBoostUntil null', () => {
  const payload = buildApplyPayload(userData(), serverTimestamp).payload;
  assert.equal(payload.rankingBoostUntil, null);
});

test('apply payload uses server timestamp marker', () => {
  const payload = buildApplyPayload(userData(), serverTimestamp).payload;
  assert.equal(payload.profileUpdatedAt, SERVER_TIMESTAMP);
});

test('apply payload excludes exact location and sensitive fields', () => {
  const payload = buildApplyPayload(userData(), serverTimestamp).payload;
  for (const forbidden of ['location', 'birthDate', 'boostUntil', 'jelly', 'fcmTokens']) {
    assert.equal(Object.hasOwn(payload, forbidden), false, forbidden);
  }
  assert.equal(payload.coarseLocation.lat, 37.57);
  assert.equal(payload.coarseLocation.lng, 126.98);
  assert.equal(Object.hasOwn(payload.coarseLocation, 'label'), false);
  assert.equal(containsExactLocation(payload), false);
});

test('apply payload has no recursive undefined values', () => {
  const payload = buildApplyPayload(userData({
    height: undefined,
    religion: undefined,
    location: undefined,
  }), serverTimestamp).payload;
  assert.equal(hasRecursiveUndefined(payload), false);
  assert.equal(payload.height, null);
  assert.equal(payload.religion, null);
  assert.equal(payload.coarseLocation, null);
});

test('malformed source is skipped', async () => {
  const ref = createPublicRef('user-1');
  const result = await applySnapshotPair(
    snapshot('user-1', true, userData({ photoUrls: 'not-array' })),
    snapshot('user-1', false, null),
    ref,
    { serverTimestamp },
  );
  assert.equal(result.status, 'skipped');
  assert.equal(result.reason, 'invalid_field_type');
  assert.equal(ref.calls.create.length, 0);
});

test('log result contains no raw uid or profile values', () => {
  const record = toLogRecord({
    uid: 'raw-user-id',
    status: 'created',
  });
  const serialized = JSON.stringify(record);
  assert.equal(serialized.includes('raw-user-id'), false);
  assert.equal(serialized.includes('private name'), false);
});

test('raw create error is converted to safe category', async () => {
  const ref = createPublicRef('user-1', {
    createError: { message: 'private credential path', cause: { code: 'ENOTFOUND' } },
  });
  const result = await applySnapshotPair(
    snapshot('user-1', true, userData()),
    snapshot('user-1', false, null),
    ref,
    { serverTimestamp },
  );
  assert.equal(result.status, 'error');
  assert.equal(result.reason, 'DNS_FAILURE');
  assert.equal(JSON.stringify(result).includes('private'), false);
});

test('write attempt and success counts are accurate', async () => {
  const stats = emptyApplyStats('cvr-dating-app');
  const db = createFakeDb({
    users: [
      { id: 'user-1', data: userData() },
      { id: 'user-2', data: userData() },
    ],
    publicExistsById: {
      'user-2': { schemaVersion: 1 },
    },
  });
  await applyAllUsers(db, { limit: 2, pageSize: 2 }, stats, { serverTimestamp });
  assert.equal(stats.scanned, 2);
  assert.equal(stats.created, 1);
  assert.equal(stats.alreadyExists, 1);
  assert.equal(stats.writesAttempted, 1);
  assert.equal(stats.writesSucceeded, 1);
  assert.deepEqual(db.calls.publicCreates.map((entry) => entry.path), ['publicProfiles/user-1']);
  assert.deepEqual(db.calls.publicCreates.map((entry) => entry.collection), ['publicProfiles']);
  assertCounterInvariants(stats);
});

test('one user is created at most once', async () => {
  const stats = emptyApplyStats('cvr-dating-app');
  const db = createFakeDb({ users: [{ id: 'user-1', data: userData() }] });
  await applyAllUsers(db, { limit: 1, pageSize: 1 }, stats, { serverTimestamp });
  assert.equal(db.calls.publicCreates.length, 1);
  assert.equal(db.calls.publicCreates[0].id, 'user-1');
});

test('ordinary create failure counts write attempt and error', async () => {
  const stats = emptyApplyStats('cvr-dating-app');
  const db = createFakeDb({
    users: [{ id: 'user-1', data: userData() }],
    createErrorById: {
      'user-1': { cause: { code: 'ECONNRESET' }, message: 'private detail' },
    },
  });
  await applyAllUsers(db, { limit: 1, pageSize: 1 }, stats, { serverTimestamp });
  assert.equal(stats.scanned, 1);
  assert.equal(stats.errors, 1);
  assert.equal(stats.writesAttempted, 1);
  assert.equal(stats.writesSucceeded, 0);
  assert.deepEqual(stats.errorCodeCounts, { NETWORK_UNAVAILABLE: 1 });
  assertCounterInvariants(stats);
});

test('apply does not mutate input user data', () => {
  const input = userData();
  const before = JSON.stringify(normalizeFirestoreValue(input));
  const result = buildApplyPayload(input, serverTimestamp);
  assert.equal(result.ok, true);
  assert.equal(JSON.stringify(normalizeFirestoreValue(input)), before);
});

test('--uid mode avoids collection scan', async () => {
  const stats = emptyApplyStats('cvr-dating-app');
  const db = createFakeDb({ users: [{ id: 'user-1', data: userData() }] });
  await applySingleUid(db, 'user-1', stats, { serverTimestamp });
  assert.equal(db.calls.usersCollectionGets, 0);
  assert.equal(stats.created, 1);
});

test('importing apply module does not initialize Firebase app', () => {
  assert.equal(admin.apps.length, 0);
});
