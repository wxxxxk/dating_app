'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  BACKFILL_KEYS,
  COMPARISON_PAYLOAD_KEYS,
  CURRENT_SCHEMA_VERSION,
  OWNER_EDITABLE_KEYS,
  SERVER_MANAGED_KEYS,
  buildPublicProfileCandidate,
  classifyPublicProfile,
  normalizeFirestoreValue,
  toLogRecord,
} = require('../lib/public_profile_backfill');
const admin = require('firebase-admin');
const {
  assertProjectAllowed,
  classifyDryRunError,
  formatDryRunError,
  parseArgs,
} = require('../scripts/public_profile_backfill_dry_run');

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

function user(overrides = {}) {
  return {
    displayName: 'private name',
    birthDate: timestamp(new Date(1995, 5, 15)),
    gender: 'female',
    bio: 'private bio',
    photoUrls: ['https://example.test/a.jpg'],
    createdAt: timestamp(new Date(2024, 0, 1)),
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
    verifications: { email: true, phone: true, photo: false },
    ...overrides,
  };
}

function candidatePayload(overrides = {}, options = {}) {
  const built = buildPublicProfileCandidate(user(overrides), {
    referenceDate: new Date(2026, 6, 1),
    ...options,
  });
  assert.equal(built.ok, true);
  return built.payload;
}

test('candidate contains only public backfill allowlist fields', () => {
  const payload = candidatePayload();
  assert.deepEqual(new Set(Object.keys(payload)), new Set(COMPARISON_PAYLOAD_KEYS));
  assert.deepEqual(new Set(OWNER_EDITABLE_KEYS).size + new Set(SERVER_MANAGED_KEYS).size, BACKFILL_KEYS.length);
  assert.equal(Object.hasOwn(payload, 'profileUpdatedAt'), false);
});

test('candidate excludes private fields from users document', () => {
  const payload = candidatePayload({
    email: 'secret@example.test',
    phoneNumber: '+821000000000',
    fcmTokens: ['token'],
    jelly: 999,
    jellyBalance: 999,
    discoveryFilter: { gender: 'all' },
    location: {
      lat: 37.56647,
      lng: 126.97796,
      updatedAt: timestamp(new Date(2026, 5, 1)),
      label: 'private label',
    },
  });

  for (const forbidden of ['email', 'phoneNumber', 'fcmTokens', 'jelly', 'jellyBalance', 'discoveryFilter', 'location', 'birthDate']) {
    assert.equal(Object.hasOwn(payload, forbidden), false, forbidden);
  }
  assert.equal(payload.coarseLocation.lat, 37.57);
  assert.equal(payload.coarseLocation.lng, 126.98);
  assert.equal(Object.hasOwn(payload.coarseLocation, 'label'), false);
});

test('rankingBoostUntil trust boundary is preserved', () => {
  const existingRanking = timestamp(new Date(2026, 7, 1));
  const createPayload = candidatePayload({ boostUntil: timestamp(new Date(2030, 0, 1)) });
  assert.equal(createPayload.rankingBoostUntil, null);

  const existingPayload = candidatePayload(
    { boostUntil: timestamp(new Date(2030, 0, 1)) },
    { existingPublicData: { rankingBoostUntil: existingRanking } },
  );
  assert.deepEqual(
    normalizeFirestoreValue(existingPayload.rankingBoostUntil),
    normalizeFirestoreValue(existingRanking),
  );
});

test('users.verifications is not trusted for new public profile candidates', () => {
  const createPayload = candidatePayload({
    verifications: { email: true, phone: true, photo: true },
  });
  assert.deepEqual(createPayload.verifications, {
    email: false,
    phone: false,
    photo: false,
  });

  const existing = { verifications: { email: true, phone: false, photo: true } };
  const existingPayload = candidatePayload({
    verifications: { email: false, phone: false, photo: false },
  }, { existingPublicData: existing });
  assert.deepEqual(existingPayload.verifications, existing.verifications);
});

test('same public document is classified unchanged', () => {
  const payload = candidatePayload();
  const result = classifyPublicProfile({
    uid: 'user-1',
    userData: user(),
    publicExists: true,
    publicData: payload,
  }, { referenceDate: new Date(2026, 6, 1) });

  assert.equal(result.status, 'unchanged');
  assert.deepEqual(result.changedFields, []);
});

test('missing target document is classified wouldCreate', () => {
  const result = classifyPublicProfile({
    uid: 'user-1',
    userData: user(),
    publicExists: false,
  }, { referenceDate: new Date(2026, 6, 1) });

  assert.equal(result.status, 'wouldCreate');
  assert.ok(result.changedFields.includes('displayName'));
  assert.equal(result.changedFields.includes('profileUpdatedAt'), false);
  assert.equal(result.refreshProfileUpdatedAtOnApply, true);
});

test('different public fields are classified wouldUpdate with field names only', () => {
  const publicData = candidatePayload();
  publicData.bio = 'different';
  publicData.photoUrls = ['https://example.test/b.jpg'];

  const result = classifyPublicProfile({
    uid: 'user-1',
    userData: user(),
    publicExists: true,
    publicData,
  }, { referenceDate: new Date(2026, 6, 1) });

  assert.equal(result.status, 'wouldUpdate');
  assert.deepEqual(result.changedFields.sort(), ['bio', 'photoUrls']);
  assert.equal(result.changedFields.includes('different'), false);
  assert.equal(result.refreshProfileUpdatedAtOnApply, true);
});

test('profileUpdatedAt alone does not cause wouldUpdate', () => {
  const publicData = candidatePayload();
  publicData.profileUpdatedAt = timestamp(new Date(1999, 0, 1));

  const result = classifyPublicProfile({
    uid: 'user-1',
    userData: user(),
    publicExists: true,
    publicData,
  }, { referenceDate: new Date(2026, 6, 1) });

  assert.equal(result.status, 'unchanged');
  assert.deepEqual(result.changedFields, []);
  assert.equal(result.refreshProfileUpdatedAtOnApply, false);
});

test('unexpected public fields are reported separately by field name', () => {
  const publicData = candidatePayload();
  publicData.email = 'secret@example.test';
  publicData.extraVisibleField = 'value';

  const result = classifyPublicProfile({
    uid: 'user-1',
    userData: user(),
    publicExists: true,
    publicData,
  }, { referenceDate: new Date(2026, 6, 1) });

  assert.equal(result.status, 'unchanged');
  assert.deepEqual(result.unexpectedPublicFields, ['email', 'extraVisibleField']);
  assert.equal(result.hasSensitiveUnexpectedPublicFields, true);
});

test('Firestore Timestamp, arrays, and maps compare deterministically', () => {
  const left = {
    arr: [timestamp(new Date(2026, 0, 1)), { b: 2, a: 1 }],
    map: { z: null, a: timestamp(new Date(2026, 0, 2)) },
  };
  const right = {
    map: { a: timestamp(new Date(2026, 0, 2)), z: null },
    arr: [timestamp(new Date(2026, 0, 1)), { a: 1, b: 2 }],
  };

  assert.deepEqual(normalizeFirestoreValue(left), normalizeFirestoreValue(right));
});

test('input objects are not mutated', () => {
  const input = user();
  const before = JSON.stringify(normalizeFirestoreValue(input));
  const built = buildPublicProfileCandidate(input, {
    referenceDate: new Date(2026, 6, 1),
    existingPublicData: { rankingBoostUntil: timestamp(new Date(2026, 7, 1)) },
  });

  assert.equal(built.ok, true);
  assert.equal(JSON.stringify(normalizeFirestoreValue(input)), before);
});

test('log record excludes sensitive values and raw uid', () => {
  const result = classifyPublicProfile({
    uid: 'raw-user-id',
    userData: user(),
    publicExists: true,
    publicData: {
      ...candidatePayload(),
      bio: 'changed secret bio',
      email: 'secret@example.test',
    },
  }, { referenceDate: new Date(2026, 6, 1) });
  const logRecord = toLogRecord(result);
  const serialized = JSON.stringify(logRecord);

  assert.equal(Object.hasOwn(logRecord, 'uid'), false);
  assert.equal(serialized.includes('raw-user-id'), false);
  assert.equal(serialized.includes('changed secret bio'), false);
  assert.equal(serialized.includes('secret@example.test'), false);
  assert.deepEqual(logRecord.changedFields, ['bio']);
  assert.deepEqual(logRecord.unexpectedPublicFields, ['email']);
});

test('invalid type or malformed document is skipped without throwing', () => {
  const invalidArray = classifyPublicProfile({
    uid: 'user-1',
    userData: user({ photoUrls: 'not-array' }),
    publicExists: false,
  }, { referenceDate: new Date(2026, 6, 1) });
  assert.equal(invalidArray.status, 'skipped');
  assert.equal(invalidArray.reason, 'invalid_field_type');

  const empty = classifyPublicProfile({
    uid: 'user-2',
    userData: {},
    publicExists: false,
  }, { referenceDate: new Date(2026, 6, 1) });
  assert.equal(empty.status, 'skipped');
  assert.equal(empty.reason, 'missing_profile_data');

  const malformedTimestamp = classifyPublicProfile({
    uid: 'user-3',
    userData: user({ birthDate: { toDate: () => new Date('invalid') } }),
    publicExists: false,
  }, { referenceDate: new Date(2026, 6, 1) });
  assert.equal(malformedTimestamp.status, 'skipped');
  assert.equal(malformedTimestamp.reason, 'invalid_field_type');
});

test('schemaVersion and nullable defaults match current public profile contract', () => {
  const payload = candidatePayload({
    height: null,
    religion: null,
    smoking: null,
    drinking: null,
    jobCategory: null,
    jobTitle: null,
    education: null,
    mbti: null,
    relationshipGoal: null,
    location: null,
  });

  assert.equal(payload.schemaVersion, CURRENT_SCHEMA_VERSION);
  assert.equal(payload.height, null);
  assert.equal(payload.coarseLocation, null);
});

test('log record exposes only safe metadata for profileUpdatedAt apply planning', () => {
  const result = classifyPublicProfile({
    uid: 'raw-user-id',
    userData: user(),
    publicExists: false,
  }, { referenceDate: new Date(2026, 6, 1) });
  const logRecord = toLogRecord(result);
  assert.equal(logRecord.refreshProfileUpdatedAtOnApply, true);
  assert.equal(JSON.stringify(logRecord).includes('updatedAt'), false);
});

test('CLI parser rejects unknown, missing, invalid, and duplicate arguments', () => {
  assert.throws(() => parseArgs(['--unknown']), /Unknown argument/);
  assert.throws(() => parseArgs(['--project']), /requires a value/);
  assert.throws(() => parseArgs(['--project', 'cvr-dating-app', '--limit', '0']), /positive integer/);
  assert.throws(() => parseArgs(['--project', 'cvr-dating-app', '--page-size', '501']), /500 or less/);
  assert.throws(() => parseArgs(['--project', 'a', '--project', 'b']), /Duplicate argument/);

  assert.deepEqual(parseArgs(['--project', 'cvr-dating-app', '--uid', 'u', '--limit', '2', '--page-size', '1']), {
    project: 'cvr-dating-app',
    uid: 'u',
    limit: 2,
    pageSize: 1,
    help: false,
  });
});

test('--help parsing works without Firebase initialization', () => {
  const appCountBefore = admin.apps.length;
  assert.deepEqual(parseArgs(['--help']), {
    project: null,
    uid: null,
    limit: null,
    pageSize: 100,
    help: true,
  });
  assert.equal(admin.apps.length, appCountBefore);
});

test('project guard rejects wrong production project before Firestore access', () => {
  const original = process.env.FIRESTORE_EMULATOR_HOST;
  delete process.env.FIRESTORE_EMULATOR_HOST;
  try {
    assert.doesNotThrow(() => assertProjectAllowed('cvr-dating-app'));
    assert.throws(() => assertProjectAllowed('wrong-project'), /Refusing to run/);
  } finally {
    if (original === undefined) {
      delete process.env.FIRESTORE_EMULATOR_HOST;
    } else {
      process.env.FIRESTORE_EMULATOR_HOST = original;
    }
  }
});

test('dry-run error diagnostics classify credential, auth, and network failures safely', () => {
  const cases = [
    [{ message: 'Could not load the default credentials' }, 'ADC_UNAVAILABLE'],
    [{ message: 'invalid_grant: reauth required' }, 'ADC_REFRESH_FAILED'],
    [{ code: 7, details: 'PERMISSION_DENIED' }, 'PERMISSION_DENIED'],
    [{ code: 16, details: 'UNAUTHENTICATED' }, 'UNAUTHENTICATED'],
    [{ cause: { code: 'ENOTFOUND' } }, 'DNS_FAILURE'],
    [{ cause: { code: 'EAI_AGAIN' } }, 'DNS_FAILURE'],
    [{ cause: { code: 'ECONNREFUSED' } }, 'NETWORK_UNAVAILABLE'],
    [{ cause: { code: 'ECONNRESET' } }, 'NETWORK_UNAVAILABLE'],
    [{ cause: { code: 'ETIMEDOUT' } }, 'CONNECTION_TIMEOUT'],
    [{ details: 'deadline exceeded' }, 'CONNECTION_TIMEOUT'],
    [{ message: 'API has not been used or service disabled' }, 'FIRESTORE_API_DISABLED'],
    [{ message: 'unknown failure' }, 'UNKNOWN_RUNTIME_ERROR'],
  ];

  for (const [error, expected] of cases) {
    assert.equal(classifyDryRunError(error).category, expected);
    assert.equal(formatDryRunError(error), expected);
  }
});

test('dry-run diagnostic object excludes raw error details and does not mutate input', () => {
  const error = {
    message: 'private message with /private/credential/path',
    stack: 'private stack',
    cause: { code: 'ENOTFOUND' },
  };
  const before = JSON.stringify(error);
  const diagnostic = classifyDryRunError(error);

  assert.deepEqual(Object.keys(diagnostic).sort(), ['category', 'phase', 'retryable']);
  assert.equal(diagnostic.category, 'DNS_FAILURE');
  assert.equal(JSON.stringify(diagnostic).includes('private'), false);
  assert.equal(JSON.stringify(diagnostic).includes('credential'), false);
  assert.equal(JSON.stringify(error), before);
});
