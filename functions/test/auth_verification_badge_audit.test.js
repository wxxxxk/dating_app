'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const admin = require('firebase-admin');

const {
  STORED_SHAPES,
  CLASSIFICATIONS,
  normalizeStoredVerifications,
  compareVerificationBadges,
  analyzeUser,
  createEmptyAggregate,
  recordAnalysis,
  classificationInvariantHolds,
  countOrphanDocumentIds,
} = require('../lib/auth_verification_badge_audit');

const dryRun = require('../scripts/auth_verification_badge_dry_run');

const VERIFIED_EMAIL_RECORD = Object.freeze({
  email: 'audit-user@example.test',
  emailVerified: true,
});
const VERIFIED_PHONE_RECORD = Object.freeze({
  phoneNumber: '+821099998888',
  providerData: [{ providerId: 'phone' }],
});

function badges(email, phone, photo) {
  return { email, phone, photo };
}

function analyze(overrides = {}) {
  return analyzeUser({
    uid: 'audit-uid',
    userRecord: {},
    usersExists: true,
    usersData: { verifications: badges(false, false, false) },
    publicExists: true,
    publicData: { verifications: badges(false, false, false) },
    ...overrides,
  });
}

// 1
test('verified email -> canonical email true', () => {
  const result = analyze({ userRecord: VERIFIED_EMAIL_RECORD });
  assert.equal(result.canonical.email, true);
});

// 2
test('unverified email -> canonical email false', () => {
  const result = analyze({
    userRecord: { email: 'x@example.test', emailVerified: false },
  });
  assert.equal(result.canonical.email, false);
});

// 3
test('phoneNumber + phone provider -> canonical phone true', () => {
  const result = analyze({ userRecord: VERIFIED_PHONE_RECORD });
  assert.equal(result.canonical.phone, true);
});

// 4
test('phoneNumber only, no provider -> canonical phone false', () => {
  const result = analyze({
    userRecord: { phoneNumber: '+821099998888', providerData: [] },
  });
  assert.equal(result.canonical.phone, false);
});

// 5
test('photo canonical is always false', () => {
  const result = analyze({
    userRecord: {
      ...VERIFIED_EMAIL_RECORD,
      ...VERIFIED_PHONE_RECORD,
      photo: true,
    },
  });
  assert.equal(result.canonical.photo, false);
});

// 6
test('users and public match canonical -> IN_SYNC', () => {
  const result = analyze({
    userRecord: VERIFIED_EMAIL_RECORD,
    usersData: { verifications: badges(true, false, false) },
    publicData: { verifications: badges(true, false, false) },
  });
  assert.equal(result.classification, CLASSIFICATIONS.IN_SYNC);
});

// 7
test('only users differs -> WOULD_UPDATE_USERS_ONLY', () => {
  const result = analyze({
    userRecord: VERIFIED_EMAIL_RECORD,
    usersData: { verifications: badges(false, false, false) },
    publicData: { verifications: badges(true, false, false) },
  });
  assert.equal(result.classification, CLASSIFICATIONS.WOULD_UPDATE_USERS_ONLY);
  assert.deepEqual(result.users.changedKeys, ['email']);
});

// 8
test('only public differs -> WOULD_UPDATE_PUBLIC_PROFILE_ONLY', () => {
  const result = analyze({
    userRecord: VERIFIED_EMAIL_RECORD,
    usersData: { verifications: badges(true, false, false) },
    publicData: { verifications: badges(false, false, false) },
  });
  assert.equal(
    result.classification,
    CLASSIFICATIONS.WOULD_UPDATE_PUBLIC_PROFILE_ONLY,
  );
});

// 9
test('both differ -> WOULD_UPDATE_BOTH', () => {
  const result = analyze({
    userRecord: VERIFIED_EMAIL_RECORD,
    usersData: { verifications: badges(false, false, false) },
    publicData: { verifications: badges(false, false, false) },
  });
  assert.equal(result.classification, CLASSIFICATIONS.WOULD_UPDATE_BOTH);
});

// 10
test('missing users document classification', () => {
  const result = analyze({ usersExists: false, usersData: undefined });
  assert.equal(result.classification, CLASSIFICATIONS.MISSING_USERS_DOCUMENT);
});

// 11
test('missing publicProfiles document classification', () => {
  const result = analyze({ publicExists: false, publicData: undefined });
  assert.equal(
    result.classification,
    CLASSIFICATIONS.MISSING_PUBLIC_PROFILE_DOCUMENT,
  );
});

// 12
test('both documents missing classification', () => {
  const result = analyze({
    usersExists: false,
    usersData: undefined,
    publicExists: false,
    publicData: undefined,
  });
  assert.equal(result.classification, CLASSIFICATIONS.MISSING_BOTH_DOCUMENTS);
});

// 13
test('missing verification map is malformed', () => {
  const shape = normalizeStoredVerifications(undefined);
  assert.equal(shape.shape, STORED_SHAPES.MISSING);
  assert.equal(shape.malformed, true);
  const result = analyze({ usersData: {} });
  assert.equal(
    result.classification,
    CLASSIFICATIONS.MALFORMED_USERS_VERIFICATIONS,
  );
});

// 14
test('non-map verification is malformed', () => {
  assert.equal(
    normalizeStoredVerifications(['email']).shape,
    STORED_SHAPES.NOT_A_MAP,
  );
  const result = analyze({ usersData: { verifications: 'nope' } });
  assert.equal(
    result.classification,
    CLASSIFICATIONS.MALFORMED_USERS_VERIFICATIONS,
  );
});

// 15
test('missing key is malformed', () => {
  const shape = normalizeStoredVerifications({ email: true, phone: false });
  assert.equal(shape.shape, STORED_SHAPES.MISSING_KEYS);
  assert.equal(shape.malformed, true);
});

// 16
test('extra key is malformed', () => {
  const shape = normalizeStoredVerifications({
    email: true,
    phone: false,
    photo: false,
    extra: true,
  });
  assert.equal(shape.shape, STORED_SHAPES.EXTRA_KEYS);
});

// 17
test('non-boolean value is malformed', () => {
  const shape = normalizeStoredVerifications({
    email: 'yes',
    phone: false,
    photo: false,
  });
  assert.equal(shape.shape, STORED_SHAPES.NON_BOOLEAN_VALUES);
  // never coerced into a trusted true
  assert.equal(shape.normalized.email, false);
});

// 18
test('existing photo true is a true->false migration candidate', () => {
  const aggregate = createEmptyAggregate('cvr-dating-app');
  const result = analyze({
    userRecord: {},
    usersData: { verifications: badges(false, false, true) },
    publicData: { verifications: badges(false, false, true) },
  });
  recordAnalysis(aggregate, result);
  assert.equal(aggregate.usersPhotoTrue, 1);
  assert.equal(aggregate.usersPhotoTrueToFalse, 1);
  assert.equal(aggregate.usersPhotoFalseToTrue, 0);
  assert.equal(aggregate.publicPhotoTrue, 1);
  assert.equal(aggregate.publicPhotoTrueToFalse, 1);
});

// 19
test('email true without Auth evidence is detected', () => {
  const aggregate = createEmptyAggregate('cvr-dating-app');
  const result = analyze({
    userRecord: {},
    usersData: { verifications: badges(true, false, false) },
    publicData: { verifications: badges(true, false, false) },
  });
  recordAnalysis(aggregate, result);
  assert.equal(aggregate.usersEmailTrueWithoutAuthEvidence, 1);
  assert.equal(aggregate.publicEmailTrueWithoutAuthEvidence, 1);
});

// 20
test('phone true without Auth evidence is detected', () => {
  const aggregate = createEmptyAggregate('cvr-dating-app');
  const result = analyze({
    userRecord: {},
    usersData: { verifications: badges(false, true, false) },
    publicData: { verifications: badges(false, true, false) },
  });
  recordAnalysis(aggregate, result);
  assert.equal(aggregate.usersPhoneTrueWithoutAuthEvidence, 1);
  assert.equal(aggregate.publicPhoneTrueWithoutAuthEvidence, 1);
});

// 21
test('orphan users documents are counted', () => {
  const authUids = new Set(['a', 'b']);
  const result = countOrphanDocumentIds(['a', 'b', 'orphan1', 'orphan2'], authUids);
  assert.equal(result.total, 4);
  assert.equal(result.orphans, 2);
});

// 22
test('orphan publicProfiles documents are counted', () => {
  const authUids = new Set(['x']);
  const result = countOrphanDocumentIds(['x', 'y'], authUids);
  assert.equal(result.orphans, 1);
});

// 23
test('raw UID is never present in the analysis output', () => {
  const result = analyze({ uid: 'RAW-SECRET-UID-1234' });
  const text = JSON.stringify(result);
  assert.equal(text.includes('RAW-SECRET-UID-1234'), false);
  assert.match(result.uidHash, /^[0-9a-f]{8}$/);
});

// 24
test('email and phone values are never present in the analysis output', () => {
  const result = analyze({
    uid: 'audit-uid',
    userRecord: {
      email: 'private@example.test',
      emailVerified: true,
      phoneNumber: '+821012341234',
      providerData: [{ providerId: 'phone' }],
    },
  });
  const text = JSON.stringify(result);
  assert.equal(text.includes('private@example.test'), false);
  assert.equal(text.includes('+821012341234'), false);
});

// 25
test('audit files contain no Firestore write API surface', () => {
  const files = [
    path.join(__dirname, '..', 'lib', 'auth_verification_badge_audit.js'),
    path.join(__dirname, '..', 'scripts', 'auth_verification_badge_dry_run.js'),
  ];
  const writePattern =
    /\.set\(|\.update\(|\.create\(|\.delete\(|\bbatch\(|bulkWriter|transaction\.update|transaction\.set|transaction\.delete/;
  for (const file of files) {
    const source = fs.readFileSync(file, 'utf8');
    assert.equal(writePattern.test(source), false, `write API found in ${file}`);
  }
});

// 26
test('writesAttempted stays 0 after recording analyses', () => {
  const aggregate = createEmptyAggregate('cvr-dating-app');
  for (let i = 0; i < 10; i += 1) {
    recordAnalysis(aggregate, analyze());
  }
  assert.equal(aggregate.writesAttempted, 0);
});

// 27
test('classification counter invariant holds across mixed inputs', () => {
  const aggregate = createEmptyAggregate('cvr-dating-app');
  const scenarios = [
    analyze({ userRecord: VERIFIED_EMAIL_RECORD, usersData: { verifications: badges(true, false, false) }, publicData: { verifications: badges(true, false, false) } }),
    analyze({ userRecord: VERIFIED_EMAIL_RECORD, publicData: { verifications: badges(true, false, false) } }),
    analyze({ userRecord: VERIFIED_EMAIL_RECORD, usersData: { verifications: badges(true, false, false) } }),
    analyze(),
    analyze({ usersExists: false, usersData: undefined }),
    analyze({ publicExists: false, publicData: undefined }),
    analyze({ usersExists: false, usersData: undefined, publicExists: false, publicData: undefined }),
    analyze({ usersData: { verifications: 'bad' } }),
    analyze({ publicData: { verifications: ['bad'] } }),
    analyze({ usersData: { verifications: {} }, publicData: { verifications: {} } }),
    analyzeUser({ uid: 'err', userRecord: null, readError: true }),
  ];
  for (const scenario of scenarios) {
    recordAnalysis(aggregate, scenario);
  }
  assert.equal(aggregate.authUsersScanned, scenarios.length);
  assert.equal(classificationInvariantHolds(aggregate), true);
  assert.equal(aggregate.canonicalPhotoTrue, 0);
});

// 28
test('module import has no Firebase initialization side effect', () => {
  assert.equal(admin.apps.length, 0);
  assert.equal(typeof analyzeUser, 'function');
  assert.equal(typeof dryRun.parseArgs, 'function');
});

// 29
test('wrong project throws before Firebase initialization', () => {
  assert.throws(() => dryRun.assertProjectAllowed('some-other-project'));
  dryRun.assertProjectAllowed('cvr-dating-app');
  assert.equal(admin.apps.length, 0);
});

// 30
test('help parses without requiring Firebase init', () => {
  const parsed = dryRun.parseArgs(['--help']);
  assert.equal(parsed.help, true);
  assert.equal(typeof dryRun.usage(), 'string');
  assert.equal(admin.apps.length, 0);
});

test('write-mode flags are rejected', () => {
  for (const flag of ['--apply', '--write', '--fix', '--migrate', '--update', '--delete']) {
    assert.throws(() => dryRun.parseArgs(['--project', 'cvr-dating-app', flag]));
  }
});

test('read error classification maps to READ_ERROR bucket', () => {
  const result = analyzeUser({ uid: 'e', userRecord: null, readError: true });
  assert.equal(result.classification, CLASSIFICATIONS.READ_ERROR);
});

test('malformed both documents classification', () => {
  const result = analyze({
    usersData: { verifications: 'bad' },
    publicData: { verifications: ['bad'] },
  });
  assert.equal(result.classification, CLASSIFICATIONS.MALFORMED_BOTH_VERIFICATIONS);
});

test('compareVerificationBadges reports changed keys', () => {
  const cmp = compareVerificationBadges(
    badges(true, true, false),
    badges(true, false, false),
  );
  assert.deepEqual(cmp.changedKeys, ['phone']);
  assert.equal(cmp.changed, true);
});
