'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const admin = require('firebase-admin');

const F = require('../lib/auth_verification_badge_unknown_orphan_forensics');
const blocker = require('../scripts/auth_verification_badge_blocker_audit');

// Fingerprint helpers for schema-similarity tests.
const dummyUsersDoc = {
  displayName: '김서연',
  birthDate: { toDate: () => new Date() },
  gender: 'female',
  bio: 'x',
  photoUrls: ['https://i.pravatar.cc/400?img=1', 'https://picsum.photos/seed/a/1/1'],
  createdAt: { toDate: () => new Date() },
  updatedAt: { toDate: () => new Date() },
  height: 163,
  interests: ['a'],
  personalityTags: ['b'],
  idealTags: ['c'],
  relationshipGoal: 'serious_relationship',
  location: { lat: 37.5, lng: 127.0 },
  verifications: { email: true, phone: false, photo: false },
};

const realUsersDoc = {
  displayName: 'Real',
  birthDate: { toDate: () => new Date() },
  gender: 'male',
  bio: 'hi',
  photoUrls: ['https://firebasestorage.googleapis.com/v0/b/x/o/u%2Fp.png'],
  createdAt: { toDate: () => new Date() },
  updatedAt: { toDate: () => new Date() },
  height: 178,
  interests: ['a'],
  personalityTags: ['b'],
  idealTags: ['c'],
  relationshipGoal: 'serious_relationship',
  location: { lat: 37.5, lng: 127.0 },
  verifications: { email: true, phone: true, photo: false },
  fcmTokens: ['tok'],
  jelly: 30,
  onboardingCompleted: true,
  lastActiveAt: { toDate: () => new Date() },
};

// 1
test('selects exactly one unknown orphan pair', () => {
  const uid = F.selectUnknownOrphan({
    authIds: ['authA', 'authB'],
    userDocIds: ['authA', 'authB', 'dummy_001', 'realOrphan28chAAAAAAAAAAAAAAA'],
    publicDocIds: ['authA', 'authB', 'dummy_001', 'realOrphan28chAAAAAAAAAAAAAAA'],
  });
  assert.equal(uid, 'realOrphan28chAAAAAAAAAAAAAAA');
});

// 2
test('aborts when zero unknown orphans exist', () => {
  assert.throws(
    () =>
      F.selectUnknownOrphan({
        authIds: ['authA'],
        userDocIds: ['authA', 'dummy_001'],
        publicDocIds: ['authA', 'dummy_001'],
      }),
    (e) => e.code === 'NO_UNKNOWN_ORPHAN',
  );
});

// 3
test('aborts when two or more unknown orphans exist', () => {
  assert.throws(
    () =>
      F.selectUnknownOrphan({
        authIds: ['authA'],
        userDocIds: ['authA', 'orphanOne', 'orphanTwo'],
        publicDocIds: ['authA', 'orphanOne', 'orphanTwo'],
      }),
    (e) => e.code === 'MULTIPLE_UNKNOWN_ORPHANS' && e.count === 2,
  );
});

test('unpaired unknown (users-only) is not selected', () => {
  assert.throws(
    () =>
      F.selectUnknownOrphan({
        authIds: ['authA'],
        userDocIds: ['authA', 'lonelyUser'],
        publicDocIds: ['authA'],
      }),
    (e) => e.code === 'NO_UNKNOWN_ORPHAN',
  );
});

// 4
test('no raw UID appears in classification output', () => {
  const result = F.scoreClassification({
    documentIdFormatClass: F.DOCUMENT_ID_FORMAT.FIREBASE_UID_LIKE,
    usersSchemaSimilarityToReal: F.SIMILARITY.HIGH,
    usersSchemaSimilarityToDummy: F.SIMILARITY.LOW,
    publicSchemaSimilarityToReal: F.SIMILARITY.HIGH,
    publicSchemaSimilarityToDummy: F.SIMILARITY.LOW,
    hasActivityTimestamp: true,
    hasCompletedOnboardingMarker: true,
    relatedCurrentAuthUsers: 2,
    createdWithDummyCohort: F.COHORT.FALSE,
  });
  const text = JSON.stringify(result);
  assert.equal(text.includes('RAW'), false);
  assert.match(F.safeUidHash('RAW-SECRET-UID'), /^[0-9a-f]{8}$/);
});

// 5
test('document id format class enum', () => {
  assert.equal(F.classifyDocumentIdFormat('dummy_003'), F.DOCUMENT_ID_FORMAT.DUMMY_PREFIX);
  assert.equal(
    F.classifyDocumentIdFormat('abcDEF0123abcDEF0123abcDEF01'),
    F.DOCUMENT_ID_FORMAT.FIREBASE_UID_LIKE,
  );
  assert.equal(
    F.classifyDocumentIdFormat('123e4567-e89b-12d3-a456-426614174000'),
    F.DOCUMENT_ID_FORMAT.UUID_LIKE,
  );
  assert.equal(
    F.classifyDocumentIdFormat('john-doe-test'),
    F.DOCUMENT_ID_FORMAT.CUSTOM_READABLE_ID,
  );
  assert.equal(
    F.classifyDocumentIdFormat('X9$@!weird'),
    F.DOCUMENT_ID_FORMAT.OTHER_OPAQUE_ID,
  );
});

// 6
test('metadata time bucket', () => {
  assert.equal(F.metadataTimeBucket(0), F.TIME_BUCKET.SAME_SECOND);
  assert.equal(F.metadataTimeBucket(30), F.TIME_BUCKET.WITHIN_ONE_MINUTE);
  assert.equal(F.metadataTimeBucket(1800), F.TIME_BUCKET.WITHIN_ONE_HOUR);
  assert.equal(F.metadataTimeBucket(100000), F.TIME_BUCKET.DIFFERENT_PERIOD);
  assert.equal(F.metadataTimeBucket(null), F.TIME_BUCKET.UNKNOWN);
});

// 7
test('dummy cohort membership determination', () => {
  const cohort = [1000, 1005, 1010];
  assert.equal(F.cohortMembership(1007, cohort), F.COHORT.TRUE);
  assert.equal(F.cohortMembership(1000000, cohort), F.COHORT.FALSE);
  assert.equal(F.cohortMembership(null, cohort), F.COHORT.UNKNOWN);
  assert.equal(F.cohortMembership(1007, []), F.COHORT.UNKNOWN);
});

// 8
test('schema fingerprint similarity exact/high/medium/low/none', () => {
  const orphanFp = F.schemaFingerprint(dummyUsersDoc);
  const dummyFp = F.schemaFingerprint(dummyUsersDoc);
  assert.equal(F.schemaSimilarityToGroup(orphanFp, [dummyFp]), F.SIMILARITY.EXACT);

  // Different types on same keys -> not exact but identical key set -> HIGH.
  const typeShift = { ...dummyUsersDoc, height: '163' };
  assert.equal(
    F.schemaSimilarityToGroup(F.schemaFingerprint(typeShift), [dummyFp]),
    F.SIMILARITY.HIGH,
  );

  // Half-overlapping keys -> MEDIUM/LOW range.
  const partial = F.schemaFingerprint({ displayName: 'x', gender: 'f', height: 1 });
  const sim = F.schemaSimilarityToGroup(partial, [dummyFp]);
  assert.ok([F.SIMILARITY.LOW, F.SIMILARITY.MEDIUM].includes(sim));

  // Disjoint keys -> NONE.
  const disjoint = F.schemaFingerprint({ zzz: 1, yyy: 2 });
  assert.equal(F.schemaSimilarityToGroup(disjoint, [dummyFp]), F.SIMILARITY.NONE);

  // Empty group -> NONE.
  assert.equal(F.schemaSimilarityToGroup(orphanFp, []), F.SIMILARITY.NONE);
});

// 9
test('value characteristics never leak PII values', () => {
  const chars = F.valueCharacteristics({
    displayName: 'Alice Secret',
    bio: 'my private bio text',
    birthDate: { toDate: () => new Date() },
    photoUrls: ['https://i.pravatar.cc/400?img=1'],
    location: { lat: 37.5665, lng: 126.978 },
    email: 'secret@example.test',
  });
  const text = JSON.stringify(chars);
  assert.equal(text.includes('Alice Secret'), false);
  assert.equal(text.includes('private bio'), false);
  assert.equal(text.includes('secret@example.test'), false);
  assert.equal(text.includes('37.5665'), false);
  assert.equal(chars.hasNonEmptyDisplayName, true);
  assert.equal(chars.hasBio, true);
  assert.equal(chars.hasExactLocation, true);
  assert.equal(chars.hasAccountContactFields, true);
});

// 10
test('photo storage class never emits URLs', () => {
  assert.equal(F.photoStorageClass([]), F.PHOTO_STORAGE_CLASS.NO_PHOTOS);
  assert.equal(
    F.photoStorageClass(['https://i.pravatar.cc/1', 'https://picsum.photos/2']),
    F.PHOTO_STORAGE_CLASS.EXTERNAL_URL,
  );
  assert.equal(
    F.photoStorageClass(['https://firebasestorage.googleapis.com/v0/b/x/o/y.png']),
    F.PHOTO_STORAGE_CLASS.FIREBASE_STORAGE,
  );
  assert.equal(
    F.photoStorageClass([
      'https://firebasestorage.googleapis.com/v0/b/x/o/y.png',
      'https://i.pravatar.cc/1',
    ]),
    F.PHOTO_STORAGE_CLASS.MIXED,
  );
  assert.equal(F.photoStorageClass(['not a url']), F.PHOTO_STORAGE_CLASS.MALFORMED);
  const bucket = F.photoStorageClass(['https://i.pravatar.cc/secret-path-123']);
  assert.equal(bucket.includes('secret-path'), false);
});

// 11
test('swipe actor/target aggregate', () => {
  const sets = {
    authIds: new Set(['authReal']),
    dummyIds: new Set(['dummy_001']),
    otherOrphanIds: new Set(['orphanX']),
  };
  const agg = F.aggregateOrphanSwipes({
    orphanUid: 'orphanX',
    swipes: [
      { actorUid: 'orphanX', targetUid: 'authReal', timestampSec: 1000 },
      { actorUid: 'dummy_001', targetUid: 'orphanX', timestampSec: 1001 },
      { actorUid: 'authOther', targetUid: 'authOther' }, // unrelated
    ],
    sets,
    cohortTimesSec: [1000, 1002],
  });
  assert.equal(agg.unknownAsSwipeActor, 1);
  assert.equal(agg.unknownAsSwipeTarget, 1);
  assert.equal(agg.swipesWithCurrentAuthUsers, 1);
  assert.equal(agg.swipesWithKnownDummyUsers, 1);
  assert.equal(agg.swipeTimestampCohort, F.ACTIVITY_COHORT.WITH_DUMMY_SEED);
});

// 12
test('match aggregate with message existence only', () => {
  const sets = {
    authIds: new Set(['authReal']),
    dummyIds: new Set(['dummy_001']),
    otherOrphanIds: new Set(['orphanX']),
  };
  const agg = F.aggregateOrphanMatches({
    orphanUid: 'orphanX',
    matches: [
      {
        participants: ['orphanX', 'authReal'],
        uid1: 'orphanX',
        uid2: 'authReal',
        timestampSec: 5000,
        messageCount: 3,
        nonMessageSubcollections: 0,
      },
      {
        participants: ['dummy_001', 'authReal'], // no orphan -> ignored
        messageCount: 0,
      },
    ],
    sets,
    cohortTimesSec: [1000],
  });
  assert.equal(agg.matchesContainingUnknown, 1);
  assert.equal(agg.matchesWithCurrentAuthUsers, 1);
  assert.equal(agg.matchesWithMessages, 1);
  assert.equal(agg.matchTimestampCohort, F.ACTIVITY_COHORT.WITH_REAL_ACTIVITY);
});

// 13
test('relation category aggregate', () => {
  const swipeAgg = {
    swipesWithCurrentAuthUsers: 2,
    swipesWithKnownDummyUsers: 1,
    swipesWithOtherOrphans: 0,
  };
  const matchAgg = {
    matchesWithCurrentAuthUsers: 1,
    matchesWithKnownDummyUsers: 0,
    matchesWithOtherOrphans: 1,
  };
  const rel = F.aggregateRelations({ swipeAgg, matchAgg });
  assert.equal(rel.relatedCurrentAuthUsers, 3);
  assert.equal(rel.relatedKnownDummyUsers, 1);
  assert.equal(rel.relatedOtherUnknownUsers, 1);
});

// 14
test('historical dummy exact-id match feeds seed scoring', () => {
  const result = F.scoreClassification({
    exactIdFoundInGitHistory: true,
    payloadPatternMatchesHistoricalDummy: 'yes',
    referencePatternMatchesHistoricalDummy: 'yes',
    createdWithDummyCohort: F.COHORT.TRUE,
    photoStorageClass: F.PHOTO_STORAGE_CLASS.EXTERNAL_URL,
    usersSchemaSimilarityToDummy: F.SIMILARITY.EXACT,
    usersSchemaSimilarityToReal: F.SIMILARITY.LOW,
    publicSchemaSimilarityToDummy: F.SIMILARITY.EXACT,
    publicSchemaSimilarityToReal: F.SIMILARITY.LOW,
    relatedCurrentAuthUsers: 0,
    relatedKnownDummyUsers: 0,
    relatedOtherUnknownUsers: 0,
    totalReferenceCount: 0,
  });
  assert.equal(result.classification, F.CLASSIFICATION.KNOWN_SEED_OR_TEST_DATA);
  assert.equal(result.confidence, F.CONFIDENCE.HIGH);
});

// 15
test('historical dummy payload pattern matching', () => {
  assert.equal(
    F.payloadPatternMatchesHistoricalDummy({
      photoStorageClass: F.PHOTO_STORAGE_CLASS.EXTERNAL_URL,
      hasExactLocation: true,
      hasBirthData: true,
      hasFCMTokens: false,
      hasAccountContactFields: false,
      hasOnboardingCompletionState: false,
    }),
    'yes',
  );
  assert.equal(
    F.payloadPatternMatchesHistoricalDummy({
      photoStorageClass: F.PHOTO_STORAGE_CLASS.FIREBASE_STORAGE,
      hasExactLocation: true,
      hasBirthData: true,
      hasFCMTokens: false,
    }),
    'partial',
  );
  assert.equal(
    F.payloadPatternMatchesHistoricalDummy({
      photoStorageClass: F.PHOTO_STORAGE_CLASS.FIREBASE_STORAGE,
      hasExactLocation: false,
      hasBirthData: false,
      hasFCMTokens: true,
      hasAccountContactFields: true,
      hasOnboardingCompletionState: true,
    }),
    'no',
  );
});

// 16
test('seed classification with high confidence', () => {
  const result = F.scoreClassification({
    payloadPatternMatchesHistoricalDummy: 'yes',
    referencePatternMatchesHistoricalDummy: 'yes',
    createdWithDummyCohort: F.COHORT.TRUE,
    photoStorageClass: F.PHOTO_STORAGE_CLASS.EXTERNAL_URL,
    usersSchemaSimilarityToDummy: F.SIMILARITY.EXACT,
    usersSchemaSimilarityToReal: F.SIMILARITY.MEDIUM,
    publicSchemaSimilarityToDummy: F.SIMILARITY.EXACT,
    publicSchemaSimilarityToReal: F.SIMILARITY.MEDIUM,
    relatedCurrentAuthUsers: 0,
    relatedKnownDummyUsers: 0,
    relatedOtherUnknownUsers: 0,
    totalReferenceCount: 0,
  });
  assert.equal(result.classification, F.CLASSIFICATION.KNOWN_SEED_OR_TEST_DATA);
  assert.equal(result.confidence, F.CONFIDENCE.HIGH);
});

// 17
test('deleted real-user classification', () => {
  const result = F.scoreClassification({
    documentIdFormatClass: F.DOCUMENT_ID_FORMAT.FIREBASE_UID_LIKE,
    usersSchemaSimilarityToDummy: F.SIMILARITY.LOW,
    usersSchemaSimilarityToReal: F.SIMILARITY.HIGH,
    publicSchemaSimilarityToDummy: F.SIMILARITY.LOW,
    publicSchemaSimilarityToReal: F.SIMILARITY.HIGH,
    createdWithDummyCohort: F.COHORT.FALSE,
    photoStorageClass: F.PHOTO_STORAGE_CLASS.FIREBASE_STORAGE,
    hasActivityTimestamp: true,
    hasCompletedOnboardingMarker: true,
    hasFCMTokens: true,
    relatedCurrentAuthUsers: 2,
    relatedKnownDummyUsers: 0,
    relatedOtherUnknownUsers: 0,
    matchesWithMessages: 1,
    totalReferenceCount: 3,
  });
  assert.equal(result.classification, F.CLASSIFICATION.DELETED_REAL_USER_LIKELY);
  assert.ok([F.CONFIDENCE.HIGH, F.CONFIDENCE.MEDIUM].includes(result.confidence));
});

// 18
test('incomplete signup classification', () => {
  const result = F.scoreClassification({
    documentIdFormatClass: F.DOCUMENT_ID_FORMAT.FIREBASE_UID_LIKE,
    usersSchemaSimilarityToDummy: F.SIMILARITY.LOW,
    usersSchemaSimilarityToReal: F.SIMILARITY.MEDIUM,
    publicSchemaSimilarityToDummy: F.SIMILARITY.LOW,
    publicSchemaSimilarityToReal: F.SIMILARITY.MEDIUM,
    createdWithDummyCohort: F.COHORT.FALSE,
    photoStorageClass: F.PHOTO_STORAGE_CLASS.NO_PHOTOS,
    hasProfilePhotos: false,
    hasNonEmptyDisplayName: false,
    hasOnboardingCompletionState: true,
    hasCompletedOnboardingMarker: false,
    hasActivityTimestamp: false,
    relatedCurrentAuthUsers: 0,
    relatedKnownDummyUsers: 0,
    relatedOtherUnknownUsers: 0,
    matchesWithMessages: 0,
    totalReferenceCount: 0,
  });
  assert.equal(
    result.classification,
    F.CLASSIFICATION.INCOMPLETE_SIGNUP_OR_ACCOUNT_CREATION,
  );
});

// 19
test('conflicting evidence yields manual review', () => {
  const result = F.scoreClassification({
    // Two dummy signals ...
    payloadPatternMatchesHistoricalDummy: 'yes',
    createdWithDummyCohort: F.COHORT.TRUE,
    // ... and two deleted-real signals, plus a real user relationship.
    documentIdFormatClass: F.DOCUMENT_ID_FORMAT.FIREBASE_UID_LIKE,
    usersSchemaSimilarityToDummy: F.SIMILARITY.MEDIUM,
    usersSchemaSimilarityToReal: F.SIMILARITY.HIGH,
    publicSchemaSimilarityToDummy: F.SIMILARITY.MEDIUM,
    publicSchemaSimilarityToReal: F.SIMILARITY.HIGH,
    hasActivityTimestamp: true,
    photoStorageClass: F.PHOTO_STORAGE_CLASS.EXTERNAL_URL,
    relatedCurrentAuthUsers: 0,
    relatedKnownDummyUsers: 0,
    relatedOtherUnknownUsers: 0,
    totalReferenceCount: 0,
  });
  assert.equal(result.classification, F.CLASSIFICATION.MANUAL_REVIEW_REQUIRED);
});

// 20
test('unsafe cases never yield SAFE cleanup', () => {
  // Deleted-real -> RECOVERY.
  assert.equal(
    F.cleanupDecision({
      classification: F.CLASSIFICATION.DELETED_REAL_USER_LIKELY,
      confidence: F.CONFIDENCE.HIGH,
      signals: { relatedCurrentAuthUsers: 0, matchesWithMessages: 0 },
    }),
    F.CLEANUP_DECISION.RECOVERY,
  );
  // Seed but only MEDIUM confidence -> MANUAL.
  assert.equal(
    F.cleanupDecision({
      classification: F.CLASSIFICATION.KNOWN_SEED_OR_TEST_DATA,
      confidence: F.CONFIDENCE.MEDIUM,
      signals: { relatedCurrentAuthUsers: 0, matchesWithMessages: 0 },
    }),
    F.CLEANUP_DECISION.MANUAL,
  );
  // Seed + HIGH but a real-user relationship -> MANUAL.
  assert.equal(
    F.cleanupDecision({
      classification: F.CLASSIFICATION.KNOWN_SEED_OR_TEST_DATA,
      confidence: F.CONFIDENCE.HIGH,
      signals: { relatedCurrentAuthUsers: 1, matchesWithMessages: 0 },
    }),
    F.CLEANUP_DECISION.MANUAL,
  );
  // Seed + HIGH + clean -> SAFE.
  assert.equal(
    F.cleanupDecision({
      classification: F.CLASSIFICATION.KNOWN_SEED_OR_TEST_DATA,
      confidence: F.CONFIDENCE.HIGH,
      signals: {
        relatedCurrentAuthUsers: 0,
        matchesWithMessages: 0,
        hasDeletionMarker: false,
      },
    }),
    F.CLEANUP_DECISION.SAFE,
  );
  // Lifecycle marker forces RECOVERY even for otherwise-clean seed.
  assert.equal(
    F.cleanupDecision({
      classification: F.CLASSIFICATION.KNOWN_SEED_OR_TEST_DATA,
      confidence: F.CONFIDENCE.HIGH,
      signals: {
        relatedCurrentAuthUsers: 0,
        matchesWithMessages: 0,
        hasDeactivationMarker: true,
      },
    }),
    F.CLEANUP_DECISION.RECOVERY,
  );
});

// 21
test('forensic files contain no write/delete API surface', () => {
  const files = [
    path.join(__dirname, '..', 'lib', 'auth_verification_badge_unknown_orphan_forensics.js'),
    path.join(__dirname, '..', 'scripts', 'auth_verification_badge_blocker_audit.js'),
  ];
  const writePattern =
    /\.set\(|\.update\(|\.create\(|\.delete\(|\bbatch\(|bulkWriter|deleteUser|updateUser|transaction\.update|transaction\.set|transaction\.delete/;
  for (const file of files) {
    const source = fs.readFileSync(file, 'utf8');
    assert.equal(writePattern.test(source), false, `write API found in ${file}`);
  }
});

// 22
test('counter invariants: relations equal sum of swipe + match parts', () => {
  const swipeAgg = {
    swipesWithCurrentAuthUsers: 4,
    swipesWithKnownDummyUsers: 2,
    swipesWithOtherOrphans: 1,
  };
  const matchAgg = {
    matchesWithCurrentAuthUsers: 1,
    matchesWithKnownDummyUsers: 3,
    matchesWithOtherOrphans: 2,
  };
  const rel = F.aggregateRelations({ swipeAgg, matchAgg });
  assert.equal(
    rel.relatedCurrentAuthUsers,
    swipeAgg.swipesWithCurrentAuthUsers + matchAgg.matchesWithCurrentAuthUsers,
  );
  assert.equal(
    rel.relatedKnownDummyUsers,
    swipeAgg.swipesWithKnownDummyUsers + matchAgg.matchesWithKnownDummyUsers,
  );
  assert.equal(
    rel.relatedOtherUnknownUsers,
    swipeAgg.swipesWithOtherOrphans + matchAgg.matchesWithOtherOrphans,
  );
});

// 23
test('module import has no Firebase initialization side effect', () => {
  assert.equal(admin.apps.length, 0);
  assert.equal(typeof F.selectUnknownOrphan, 'function');
  assert.equal(typeof blocker.parseArgs, 'function');
  // The new forensic flag parses without touching Firebase.
  const parsed = blocker.parseArgs(['--project', 'cvr-dating-app', '--forensic-unknown']);
  assert.equal(parsed.forensicUnknown, true);
  assert.equal(admin.apps.length, 0);
});

test('activity cohort classification (dummy/real/mixed/unknown)', () => {
  assert.equal(F.activityCohort([1000], [1000, 1002]), F.ACTIVITY_COHORT.WITH_DUMMY_SEED);
  assert.equal(
    F.activityCohort([500000], [1000, 1002]),
    F.ACTIVITY_COHORT.WITH_REAL_ACTIVITY,
  );
  assert.equal(F.activityCohort([1000, 500000], [1000]), F.ACTIVITY_COHORT.MIXED);
  assert.equal(F.activityCohort([], [1000]), F.ACTIVITY_COHORT.UNKNOWN);
});

test('relation classifier maps counterparties to categories', () => {
  const sets = {
    authIds: new Set(['a']),
    dummyIds: new Set(['dummy_001']),
    otherOrphanIds: new Set(['orphanX']),
  };
  assert.equal(F.classifyRelation('a', sets), F.RELATION_CATEGORY.CURRENT_AUTH_USER);
  assert.equal(F.classifyRelation('dummy_001', sets), F.RELATION_CATEGORY.KNOWN_DUMMY_ORPHAN);
  assert.equal(F.classifyRelation('orphanX', sets), F.RELATION_CATEGORY.UNKNOWN_ORPHAN);
  assert.equal(F.classifyRelation('stranger', sets), F.RELATION_CATEGORY.OTHER);
  assert.equal(F.classifyRelation('', sets), null);
});

test('lifecycle deletion marker forces non-seed classification', () => {
  const result = F.scoreClassification({
    payloadPatternMatchesHistoricalDummy: 'yes',
    createdWithDummyCohort: F.COHORT.TRUE,
    photoStorageClass: F.PHOTO_STORAGE_CLASS.EXTERNAL_URL,
    usersSchemaSimilarityToDummy: F.SIMILARITY.EXACT,
    usersSchemaSimilarityToReal: F.SIMILARITY.LOW,
    publicSchemaSimilarityToDummy: F.SIMILARITY.EXACT,
    publicSchemaSimilarityToReal: F.SIMILARITY.LOW,
    relatedCurrentAuthUsers: 0,
    relatedKnownDummyUsers: 0,
    relatedOtherUnknownUsers: 0,
    totalReferenceCount: 0,
    hasDeletionMarker: true,
  });
  assert.equal(result.classification, F.CLASSIFICATION.MANUAL_REVIEW_REQUIRED);
});
