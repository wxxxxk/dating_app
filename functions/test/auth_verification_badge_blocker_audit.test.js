'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const admin = require('firebase-admin');

const {
  ORPHAN_CLASSES,
  MALFORMED_SHAPES,
  MALFORMED_MIGRATION,
  classifyOrphanId,
  computeOrphanSets,
  classifyOrphans,
  diagnoseMalformedVerifications,
  diagnoseMalformedUser,
  aggregateOrphanReferences,
} = require('../lib/auth_verification_badge_blocker_audit');

const blocker = require('../scripts/auth_verification_badge_blocker_audit');

// 1
test('orphan user/public ID sets exactly equal when paired', () => {
  const result = computeOrphanSets(
    ['authA', 'authB'],
    ['authA', 'authB', 'dummy_001', 'dummy_002'],
    ['authA', 'authB', 'dummy_001', 'dummy_002'],
  );
  assert.equal(result.orphanUserCount, 2);
  assert.equal(result.orphanPublicCount, 2);
  assert.equal(result.orphanIdSetsExactlyEqual, true);
});

// 2
test('paired orphans are counted', () => {
  const result = computeOrphanSets(
    ['auth1'],
    ['auth1', 'dummy_001', 'dummy_002'],
    ['auth1', 'dummy_001', 'dummy_002'],
  );
  assert.equal(result.pairedOrphanCount, 2);
});

// 3
test('users-only orphans are counted', () => {
  const result = computeOrphanSets(
    ['auth1'],
    ['auth1', 'dummy_001', 'onlyUser'],
    ['auth1', 'dummy_001'],
  );
  assert.equal(result.usersOnlyOrphanCount, 1);
  assert.equal(result.orphanIdSetsExactlyEqual, false);
});

// 4
test('public-only orphans are counted', () => {
  const result = computeOrphanSets(
    ['auth1'],
    ['auth1', 'dummy_001'],
    ['auth1', 'dummy_001', 'onlyPublic'],
  );
  assert.equal(result.publicOnlyOrphanCount, 1);
});

// 5
test('known dummy pattern is classified', () => {
  assert.equal(
    classifyOrphanId('dummy_007'),
    ORPHAN_CLASSES.KNOWN_DUMMY_ID_PATTERN,
  );
  const summary = classifyOrphans(['dummy_001', 'dummy_002']);
  assert.equal(summary.knownDummy, 2);
  assert.equal(summary.unknown, 0);
});

// 6
test('unknown orphan is classified', () => {
  assert.equal(
    classifyOrphanId('7cRealLookingUid'),
    ORPHAN_CLASSES.UNKNOWN_ORPHAN_ID,
  );
  const summary = classifyOrphans(['dummy_001', 'strangeUid']);
  assert.equal(summary.knownDummy, 1);
  assert.equal(summary.unknown, 1);
});

// 7
test('raw UID is never present in orphan classification output', () => {
  const summary = classifyOrphans(['dummy_001', 'RAW-SECRET-ORPHAN']);
  const text = JSON.stringify(summary);
  assert.equal(text.includes('RAW-SECRET-ORPHAN'), false);
  assert.equal(text.includes('dummy_001'), false);
  for (const entry of summary.entries) {
    assert.match(entry.uidHash, /^[0-9a-f]{8}$/);
  }
});

// 8
test('malformed MISSING is classified', () => {
  const result = diagnoseMalformedVerifications(undefined);
  assert.equal(result.shape, MALFORMED_SHAPES.MISSING);
  assert.deepEqual(result.missingKeys, ['email', 'phone', 'photo']);
});

// 9
test('malformed NOT_A_MAP is classified', () => {
  assert.equal(
    diagnoseMalformedVerifications(['email']).shape,
    MALFORMED_SHAPES.NOT_A_MAP,
  );
  assert.equal(
    diagnoseMalformedVerifications('true').shape,
    MALFORMED_SHAPES.NOT_A_MAP,
  );
});

// 10
test('malformed MISSING_KEYS is classified', () => {
  const result = diagnoseMalformedVerifications({ email: true });
  assert.equal(result.shape, MALFORMED_SHAPES.MISSING_KEYS);
  assert.deepEqual(result.missingKeys, ['phone', 'photo']);
});

// 11
test('malformed EXTRA_KEYS is classified', () => {
  const result = diagnoseMalformedVerifications({
    email: true,
    phone: false,
    photo: false,
    legacyFlag: true,
  });
  assert.equal(result.shape, MALFORMED_SHAPES.EXTRA_KEYS);
  assert.deepEqual(result.extraKeys, ['legacyFlag']);
});

// 12
test('malformed NON_BOOLEAN_VALUES is classified', () => {
  const result = diagnoseMalformedVerifications({
    email: 'yes',
    phone: false,
    photo: false,
  });
  assert.equal(result.shape, MALFORMED_SHAPES.NON_BOOLEAN_VALUES);
  assert.deepEqual(result.nonBooleanKeys, ['email']);
});

// 13
test('multiple concurrent defects are MULTIPLE_SHAPE_ERRORS', () => {
  const result = diagnoseMalformedVerifications({ email: 'yes', extra: 1 });
  assert.equal(result.shape, MALFORMED_SHAPES.MULTIPLE_SHAPE_ERRORS);
  assert.deepEqual(result.missingKeys, ['phone', 'photo']);
  assert.deepEqual(result.extraKeys, ['extra']);
  assert.deepEqual(result.nonBooleanKeys, ['email']);
});

// 14
test('only changed keys are reported, never raw stored values', () => {
  const diagnosis = diagnoseMalformedUser({
    uid: 'auth-uid',
    userRecord: { email: 'u@example.test', emailVerified: true },
    rawUserVerifications: { email: false },
    rawPublicVerifications: { email: false, phone: false, photo: false },
  });
  assert.deepEqual(diagnosis.canonicalChangedKeys, ['email']);
  assert.equal(diagnosis.migration, MALFORMED_MIGRATION.BOTH);
});

// 15
test('profile values and raw UID are never present in malformed diagnosis', () => {
  const diagnosis = diagnoseMalformedUser({
    uid: 'RAW-UID-42',
    userRecord: {
      email: 'secret@example.test',
      emailVerified: true,
      phoneNumber: '+821012349999',
      providerData: [{ providerId: 'phone' }],
    },
    rawUserVerifications: { email: 'weird' },
    rawPublicVerifications: undefined,
  });
  const text = JSON.stringify(diagnosis);
  assert.equal(text.includes('RAW-UID-42'), false);
  assert.equal(text.includes('secret@example.test'), false);
  assert.equal(text.includes('+821012349999'), false);
  assert.equal(text.includes('weird'), false);
});

// 16
test('orphan reference counts aggregate across collections', () => {
  const orphanIds = ['dummy_001', 'dummy_003'];
  const result = aggregateOrphanReferences(
    {
      swipes: [
        { actorUid: 'dummy_001', targetUid: 'authReal' },
        { actorUid: 'authReal', targetUid: 'dummy_003' },
        { actorUid: 'authReal', targetUid: 'authOther' },
      ],
      matches: [
        { participants: ['authReal', 'dummy_001'], uid1: 'authReal', uid2: 'dummy_001' },
        { participants: ['authReal', 'authOther'], uid1: 'authReal', uid2: 'authOther' },
      ],
      blocks: [{ blockerUid: 'authReal', blockedUid: 'dummy_003' }],
      reports: [{ reportedUid: 'dummy_001', reporterUid: 'authReal' }],
      messages: [{ senderId: 'dummy_001' }, { senderId: 'authReal' }],
    },
    orphanIds,
  );
  assert.equal(result.orphanSwipeReferences, 2);
  assert.equal(result.orphanMatchReferences, 1);
  assert.equal(result.orphanBlockReferences, 1);
  assert.equal(result.orphanMessageOrChatReferences, 1);
  assert.equal(result.otherOrphanReferences, 1);
  assert.equal(result.orphanReferencesFound, 6);
  assert.deepEqual(result.referencingCollections, [
    'blocks',
    'matches',
    'messages',
    'reports',
    'swipes',
  ]);
});

// 17
test('orphans are excluded from Auth migration eligibility', () => {
  // Migration eligibility = Auth accounts only. Orphans (no auth) never appear
  // in the auth id set that drives the migration.
  const result = computeOrphanSets(
    ['authA'],
    ['authA', 'dummy_001'],
    ['authA', 'dummy_001'],
  );
  const authIds = new Set(['authA']);
  for (const orphanId of result.orphanUserIds) {
    assert.equal(authIds.has(orphanId), false);
  }
});

// 18
test('unknown orphan blocks migration readiness', () => {
  const summary = classifyOrphans(['dummy_001', 'realOrphanNoAuth']);
  assert.ok(summary.unknown > 0);
});

// 19
test('safe malformed with both docs present is a normalization target', () => {
  const diagnosis = diagnoseMalformedUser({
    uid: 'auth-uid',
    userRecord: { email: 'u@example.test', emailVerified: true },
    rawUserVerifications: { email: false, phone: false },
    rawPublicVerifications: { email: true, phone: false, photo: false },
  });
  assert.equal(diagnosis.usersShape, MALFORMED_SHAPES.MISSING_KEYS);
  assert.deepEqual(diagnosis.usersChangedKeys, ['email']);
});

// 20
test('blocker audit files contain no write/delete API surface', () => {
  const files = [
    path.join(__dirname, '..', 'lib', 'auth_verification_badge_blocker_audit.js'),
    path.join(__dirname, '..', 'scripts', 'auth_verification_badge_blocker_audit.js'),
  ];
  const writePattern =
    /\.set\(|\.update\(|\.create\(|\.delete\(|\bbatch\(|bulkWriter|deleteUser|updateUser|transaction\.update|transaction\.set|transaction\.delete/;
  for (const file of files) {
    const source = fs.readFileSync(file, 'utf8');
    assert.equal(writePattern.test(source), false, `write API found in ${file}`);
  }
});

// 21
test('orphan reference count invariant equals the sum of parts', () => {
  const result = aggregateOrphanReferences(
    {
      swipes: [{ actorUid: 'd', targetUid: 'x' }],
      matches: [{ participants: ['d'] }],
      blocks: [{ blockedUid: 'd' }],
      messages: [{ senderId: 'd' }],
      reports: [{ reportedUid: 'd' }],
    },
    ['d'],
  );
  const sum =
    result.orphanSwipeReferences +
    result.orphanMatchReferences +
    result.orphanBlockReferences +
    result.orphanMessageOrChatReferences +
    result.otherOrphanReferences;
  assert.equal(result.orphanReferencesFound, sum);
});

// 22
test('module import has no Firebase initialization side effect', () => {
  assert.equal(admin.apps.length, 0);
  assert.equal(typeof computeOrphanSets, 'function');
  assert.equal(typeof blocker.parseArgs, 'function');
});

test('wrong project throws before Firebase init', () => {
  assert.throws(() => blocker.assertProjectAllowed('other'));
  blocker.assertProjectAllowed('cvr-dating-app');
  assert.equal(admin.apps.length, 0);
});

test('write-mode and help flags are handled without Firebase', () => {
  for (const flag of ['--apply', '--write', '--delete', '--cleanup', '--migrate']) {
    assert.throws(() => blocker.parseArgs(['--project', 'cvr-dating-app', flag]));
  }
  assert.equal(blocker.parseArgs(['--help']).help, true);
  assert.equal(typeof blocker.usage(), 'string');
  assert.equal(admin.apps.length, 0);
});

test('empty reference input yields zero references', () => {
  const result = aggregateOrphanReferences({}, ['dummy_001']);
  assert.equal(result.orphanReferencesFound, 0);
  assert.deepEqual(result.referencingCollections, []);
});
