'use strict';

// Read-only forensic classification helpers for the single UNKNOWN orphan
// user/publicProfiles pair surfaced by Phase 0-D-3A. Pure: no Firestore/Auth
// I/O, no git I/O, no writes. All production reads and git lookups happen in the
// script layer and are passed in as already-privacy-safe primitives so this
// module can be unit-tested without touching production or the filesystem.
//
// Privacy contract: this module never returns a raw document ID, e-mail, phone,
// name, bio, birth date, exact location value, photo URL, or FCM token. It only
// returns hashes, enum classes, buckets, booleans, and aggregate counts.

const { safeUidHash } = require('./auth_verification_badges');

// dummy_001 .. dummy_010 were created with FIXED ids by the removed
// lib/dev/dummy_data_service.dart. Anything else is not a known dummy.
const KNOWN_DUMMY_ID_PATTERN = /^dummy_/;

const DOCUMENT_ID_FORMAT = Object.freeze({
  DUMMY_PREFIX: 'DUMMY_PREFIX',
  CUSTOM_READABLE_ID: 'CUSTOM_READABLE_ID',
  FIREBASE_UID_LIKE: 'FIREBASE_UID_LIKE',
  UUID_LIKE: 'UUID_LIKE',
  OTHER_OPAQUE_ID: 'OTHER_OPAQUE_ID',
});

const TIME_BUCKET = Object.freeze({
  SAME_SECOND: 'SAME_SECOND',
  WITHIN_ONE_MINUTE: 'WITHIN_ONE_MINUTE',
  WITHIN_ONE_HOUR: 'WITHIN_ONE_HOUR',
  DIFFERENT_PERIOD: 'DIFFERENT_PERIOD',
  UNKNOWN: 'UNKNOWN',
});

const COHORT = Object.freeze({ TRUE: 'true', FALSE: 'false', UNKNOWN: 'unknown' });

const SIMILARITY = Object.freeze({
  EXACT: 'EXACT',
  HIGH: 'HIGH',
  MEDIUM: 'MEDIUM',
  LOW: 'LOW',
  NONE: 'NONE',
});

const PHOTO_STORAGE_CLASS = Object.freeze({
  NO_PHOTOS: 'NO_PHOTOS',
  FIREBASE_STORAGE: 'FIREBASE_STORAGE',
  EXTERNAL_URL: 'EXTERNAL_URL',
  MIXED: 'MIXED',
  MALFORMED: 'MALFORMED',
});

const PHOTO_COUNT_BUCKET = Object.freeze({
  ZERO: 'ZERO',
  ONE: 'ONE',
  TWO_TO_FOUR: 'TWO_TO_FOUR',
  FIVE_OR_MORE: 'FIVE_OR_MORE',
  UNKNOWN: 'UNKNOWN',
});

const ACTIVITY_COHORT = Object.freeze({
  WITH_DUMMY_SEED: 'WITH_DUMMY_SEED',
  WITH_REAL_ACTIVITY: 'WITH_REAL_ACTIVITY',
  MIXED: 'MIXED',
  UNKNOWN: 'UNKNOWN',
});

const CLASSIFICATION = Object.freeze({
  KNOWN_SEED_OR_TEST_DATA: 'KNOWN_SEED_OR_TEST_DATA',
  DELETED_REAL_USER_LIKELY: 'DELETED_REAL_USER_LIKELY',
  INCOMPLETE_SIGNUP_OR_ACCOUNT_CREATION: 'INCOMPLETE_SIGNUP_OR_ACCOUNT_CREATION',
  MANUAL_REVIEW_REQUIRED: 'MANUAL_REVIEW_REQUIRED',
});

const CONFIDENCE = Object.freeze({ HIGH: 'HIGH', MEDIUM: 'MEDIUM', LOW: 'LOW' });

const CLEANUP_DECISION = Object.freeze({
  SAFE: 'SAFE_TO_INCLUDE_IN_DUMMY_CLEANUP_DESIGN',
  MANUAL: 'DO_NOT_DELETE_WITHOUT_MANUAL_REVIEW',
  RECOVERY: 'REQUIRES_ACCOUNT_RECOVERY_POLICY',
});

const RELATION_CATEGORY = Object.freeze({
  CURRENT_AUTH_USER: 'CURRENT_AUTH_USER',
  KNOWN_DUMMY_ORPHAN: 'KNOWN_DUMMY_ORPHAN',
  UNKNOWN_ORPHAN: 'UNKNOWN_ORPHAN',
  OTHER: 'OTHER',
});

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const FIREBASE_UID_PATTERN = /^[A-Za-z0-9]{28}$/;
const READABLE_ID_PATTERN = /^[a-z0-9]+(?:[_-][a-z0-9]+)+$/;

function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function toSet(ids) {
  return ids instanceof Set ? ids : new Set(ids);
}

// --------------------------------------------------------------------------
// Section 2 — select exactly one unknown orphan. Throws on 0 or >1.
// --------------------------------------------------------------------------

// An unknown orphan has: users doc present, publicProfiles doc present, no Auth
// account, and an id that does NOT match the known dummy pattern.
function selectUnknownOrphan({ authIds, userDocIds, publicDocIds }) {
  const auth = toSet(authIds);
  const users = toSet(userDocIds);
  const publics = toSet(publicDocIds);

  const unknown = [];
  for (const id of users) {
    if (auth.has(id)) continue;
    if (!publics.has(id)) continue;
    if (KNOWN_DUMMY_ID_PATTERN.test(String(id))) continue;
    unknown.push(id);
  }

  if (unknown.length === 0) {
    const error = new Error('No unknown orphan pair found; nothing to classify.');
    error.code = 'NO_UNKNOWN_ORPHAN';
    throw error;
  }
  if (unknown.length > 1) {
    const error = new Error(
      `Expected exactly 1 unknown orphan pair, found ${unknown.length}; aborting.`,
    );
    error.code = 'MULTIPLE_UNKNOWN_ORPHANS';
    error.count = unknown.length;
    throw error;
  }
  return unknown[0];
}

// --------------------------------------------------------------------------
// Section 3 — document id format class (never leaks the id itself).
// --------------------------------------------------------------------------

function classifyDocumentIdFormat(id) {
  const value = String(id);
  if (KNOWN_DUMMY_ID_PATTERN.test(value)) return DOCUMENT_ID_FORMAT.DUMMY_PREFIX;
  if (UUID_PATTERN.test(value)) return DOCUMENT_ID_FORMAT.UUID_LIKE;
  if (FIREBASE_UID_PATTERN.test(value)) return DOCUMENT_ID_FORMAT.FIREBASE_UID_LIKE;
  if (READABLE_ID_PATTERN.test(value)) return DOCUMENT_ID_FORMAT.CUSTOM_READABLE_ID;
  return DOCUMENT_ID_FORMAT.OTHER_OPAQUE_ID;
}

// --------------------------------------------------------------------------
// Section 4 — metadata time buckets and dummy-cohort membership.
// --------------------------------------------------------------------------

function metadataTimeBucket(absSeconds) {
  if (absSeconds === null || absSeconds === undefined || Number.isNaN(absSeconds)) {
    return TIME_BUCKET.UNKNOWN;
  }
  const s = Math.abs(absSeconds);
  if (s < 1) return TIME_BUCKET.SAME_SECOND;
  if (s < 60) return TIME_BUCKET.WITHIN_ONE_MINUTE;
  if (s < 3600) return TIME_BUCKET.WITHIN_ONE_HOUR;
  return TIME_BUCKET.DIFFERENT_PERIOD;
}

// Is the orphan's timestamp within the known-dummy cohort window (± tolerance)?
// cohortTimesSec: array of epoch-seconds for the 10 known dummy docs.
function cohortMembership(orphanTimeSec, cohortTimesSec, toleranceSec = 3600) {
  if (typeof orphanTimeSec !== 'number' || Number.isNaN(orphanTimeSec)) {
    return COHORT.UNKNOWN;
  }
  const valid = (cohortTimesSec || []).filter(
    (t) => typeof t === 'number' && !Number.isNaN(t),
  );
  if (valid.length === 0) return COHORT.UNKNOWN;
  const min = Math.min(...valid) - toleranceSec;
  const max = Math.max(...valid) + toleranceSec;
  return orphanTimeSec >= min && orphanTimeSec <= max ? COHORT.TRUE : COHORT.FALSE;
}

// --------------------------------------------------------------------------
// Section 5 — schema fingerprint and similarity (field names + types only).
// --------------------------------------------------------------------------

function firestoreTypeOf(value) {
  if (value === null || value === undefined) return 'null';
  if (Array.isArray(value)) return 'array';
  if (typeof value === 'object') {
    // Firestore Timestamp / GeoPoint duck-typing without importing admin types.
    if (typeof value.toDate === 'function') return 'timestamp';
    if (typeof value._seconds === 'number' && typeof value._nanoseconds === 'number') {
      return 'timestamp';
    }
    if (typeof value.latitude === 'number' && typeof value.longitude === 'number') {
      return 'geopoint';
    }
    return 'map';
  }
  return typeof value; // string | number | boolean
}

// Fingerprint = privacy-safe view of a document: sorted key set and sorted
// key:type tokens. Never includes any value.
function schemaFingerprint(data) {
  const obj = isPlainObject(data) ? data : {};
  const keys = Object.keys(obj).sort();
  const typed = keys.map((key) => `${key}:${firestoreTypeOf(obj[key])}`).sort();
  return { keys, typed };
}

function jaccard(setA, setB) {
  const a = toSet(setA);
  const b = toSet(setB);
  if (a.size === 0 && b.size === 0) return 1;
  let intersection = 0;
  for (const item of a) if (b.has(item)) intersection += 1;
  const union = a.size + b.size - intersection;
  return union === 0 ? 0 : intersection / union;
}

function similarityFromScore(score) {
  if (score >= 0.85) return SIMILARITY.HIGH;
  if (score >= 0.6) return SIMILARITY.MEDIUM;
  if (score > 0) return SIMILARITY.LOW;
  return SIMILARITY.NONE;
}

// Best similarity of the orphan fingerprint to any member of a reference group.
// EXACT requires an identical key+type token set with some member. Otherwise the
// best Jaccard over key names is bucketed. Empty group -> NONE.
function schemaSimilarityToGroup(orphanFp, groupFps) {
  const group = Array.isArray(groupFps) ? groupFps : [];
  if (group.length === 0) return SIMILARITY.NONE;
  const orphanTyped = orphanFp.typed.join('|');
  let best = 0;
  for (const memberFp of group) {
    if (memberFp.typed.join('|') === orphanTyped) return SIMILARITY.EXACT;
    const score = jaccard(orphanFp.keys, memberFp.keys);
    if (score > best) best = score;
  }
  return similarityFromScore(best);
}

// Ordinal so scoring can compare "closer to dummy" vs "closer to real".
const SIMILARITY_RANK = Object.freeze({
  EXACT: 4,
  HIGH: 3,
  MEDIUM: 2,
  LOW: 1,
  NONE: 0,
});

function similarityRank(similarity) {
  return SIMILARITY_RANK[similarity] ?? 0;
}

// --------------------------------------------------------------------------
// Section 6 — privacy-safe value characteristics.
// --------------------------------------------------------------------------

function nonEmptyString(value) {
  return typeof value === 'string' && value.trim() !== '';
}

function photoCountBucket(photoUrls) {
  if (!Array.isArray(photoUrls)) return PHOTO_COUNT_BUCKET.UNKNOWN;
  const count = photoUrls.length;
  if (count === 0) return PHOTO_COUNT_BUCKET.ZERO;
  if (count === 1) return PHOTO_COUNT_BUCKET.ONE;
  if (count <= 4) return PHOTO_COUNT_BUCKET.TWO_TO_FOUR;
  return PHOTO_COUNT_BUCKET.FIVE_OR_MORE;
}

// Classify a single URL without emitting it.
function classifySinglePhotoUrl(url) {
  if (!nonEmptyString(url)) return 'MALFORMED';
  let host;
  try {
    host = new URL(url).host.toLowerCase();
  } catch (_) {
    return 'MALFORMED';
  }
  if (
    host === 'firebasestorage.googleapis.com' ||
    host === 'storage.googleapis.com' ||
    host.endsWith('.firebasestorage.app') ||
    host.endsWith('.appspot.com')
  ) {
    return 'FIREBASE_STORAGE';
  }
  return 'EXTERNAL_URL';
}

function photoStorageClass(photoUrls) {
  if (!Array.isArray(photoUrls) || photoUrls.length === 0) {
    return PHOTO_STORAGE_CLASS.NO_PHOTOS;
  }
  const allClasses = photoUrls.map(classifySinglePhotoUrl);
  // Ignore malformed entries when at least one valid class is present; only a
  // wholly-malformed photo list is reported as MALFORMED.
  const validClasses = new Set(allClasses.filter((c) => c !== 'MALFORMED'));
  if (validClasses.size === 0) return PHOTO_STORAGE_CLASS.MALFORMED;
  if (validClasses.size > 1) return PHOTO_STORAGE_CLASS.MIXED;
  return validClasses.has('FIREBASE_STORAGE')
    ? PHOTO_STORAGE_CLASS.FIREBASE_STORAGE
    : PHOTO_STORAGE_CLASS.EXTERNAL_URL;
}

function hasKey(obj, key) {
  return isPlainObject(obj) && Object.prototype.hasOwnProperty.call(obj, key);
}

function anyKey(obj, keys) {
  return keys.some((key) => hasKey(obj, key));
}

// Extract only booleans/buckets from a users doc; never returns raw values.
function valueCharacteristics(usersData) {
  const data = isPlainObject(usersData) ? usersData : {};
  const location = isPlainObject(data.location) ? data.location : null;
  const hasExactLocation =
    !!location &&
    typeof location.lat === 'number' &&
    typeof location.lng === 'number';
  const hasCoarseLocation =
    !hasExactLocation && !!location && nonEmptyString(location.label);
  return {
    hasNonEmptyDisplayName: nonEmptyString(data.displayName),
    hasProfilePhotos: Array.isArray(data.photoUrls) && data.photoUrls.length > 0,
    photoCountBucket: photoCountBucket(data.photoUrls),
    photoStorageClass: photoStorageClass(data.photoUrls),
    hasBio: nonEmptyString(data.bio),
    hasBirthData: hasKey(data, 'birthDate') && data.birthDate != null,
    hasExactLocation,
    hasCoarseLocation,
    hasOnboardingCompletionState: anyKey(data, [
      'onboardingCompleted',
      'profileCompleted',
      'onboardingStep',
    ]),
    hasAccountContactFields: anyKey(data, [
      'email',
      'phone',
      'phoneNumber',
      'contactEmail',
    ]),
    hasProviderOrAuthMetadataFields: anyKey(data, [
      'provider',
      'providerId',
      'authProvider',
      'signInProvider',
      'creationTime',
      'lastSignInTime',
    ]),
    hasFCMTokens: Array.isArray(data.fcmTokens) && data.fcmTokens.length > 0,
    hasJellyOrTransactionState: anyKey(data, [
      'jelly',
      'boostUntil',
      'likesUnlocked',
    ]),
  };
}

// --------------------------------------------------------------------------
// Section 12 — account lifecycle markers.
// --------------------------------------------------------------------------

function lifecycleMarkers(usersData) {
  const data = isPlainObject(usersData) ? usersData : {};
  const status =
    typeof data.accountStatus === 'string' ? data.accountStatus.toLowerCase() : '';
  return {
    hasDeletionMarker:
      hasKey(data, 'deletedAt') ||
      status === 'deleted' ||
      status === 'removed',
    hasDeactivationMarker:
      hasKey(data, 'deactivatedAt') ||
      status === 'deactivated' ||
      status === 'disabled' ||
      status === 'suspended',
    hasActivityTimestamp: anyKey(data, ['lastActiveAt', 'lastSeenAt', 'lastLoginAt']),
    hasCompletedOnboardingMarker:
      data.onboardingCompleted === true || data.profileCompleted === true,
  };
}

// --------------------------------------------------------------------------
// Section 8/9/10 — reference aggregation for the single unknown orphan.
// --------------------------------------------------------------------------

// Classify a counterparty uid into a relation category. Sets are passed as
// membership tests only; no uid is ever returned.
function classifyRelation(uid, { authIds, dummyIds, otherOrphanIds }) {
  if (typeof uid !== 'string' || uid === '') return null;
  if (toSet(authIds).has(uid)) return RELATION_CATEGORY.CURRENT_AUTH_USER;
  if (toSet(dummyIds).has(uid)) return RELATION_CATEGORY.KNOWN_DUMMY_ORPHAN;
  if (toSet(otherOrphanIds).has(uid)) return RELATION_CATEGORY.UNKNOWN_ORPHAN;
  return RELATION_CATEGORY.OTHER;
}

// Decide a timestamp cohort for a set of activity epoch-seconds relative to the
// known-dummy creation window.
function activityCohort(activityTimesSec, cohortTimesSec, toleranceSec = 3600) {
  const times = (activityTimesSec || []).filter(
    (t) => typeof t === 'number' && !Number.isNaN(t),
  );
  if (times.length === 0) return ACTIVITY_COHORT.UNKNOWN;
  const valid = (cohortTimesSec || []).filter(
    (t) => typeof t === 'number' && !Number.isNaN(t),
  );
  if (valid.length === 0) return ACTIVITY_COHORT.UNKNOWN;
  const min = Math.min(...valid) - toleranceSec;
  const max = Math.max(...valid) + toleranceSec;
  let inWindow = 0;
  let outWindow = 0;
  for (const t of times) {
    if (t >= min && t <= max) inWindow += 1;
    else outWindow += 1;
  }
  if (inWindow > 0 && outWindow > 0) return ACTIVITY_COHORT.MIXED;
  if (inWindow > 0) return ACTIVITY_COHORT.WITH_DUMMY_SEED;
  return ACTIVITY_COHORT.WITH_REAL_ACTIVITY;
}

// swipes: privacy-safe descriptors { actorUid, targetUid, timestampSec } that
// involve the orphan (either as actor or target).
function aggregateOrphanSwipes({ orphanUid, swipes, sets, cohortTimesSec }) {
  const agg = {
    unknownAsSwipeActor: 0,
    unknownAsSwipeTarget: 0,
    swipesWithCurrentAuthUsers: 0,
    swipesWithKnownDummyUsers: 0,
    swipesWithOtherOrphans: 0,
    swipeTimestampCohort: ACTIVITY_COHORT.UNKNOWN,
  };
  const times = [];
  for (const swipe of swipes || []) {
    const isActor = swipe.actorUid === orphanUid;
    const isTarget = swipe.targetUid === orphanUid;
    if (!isActor && !isTarget) continue;
    if (isActor) agg.unknownAsSwipeActor += 1;
    if (isTarget) agg.unknownAsSwipeTarget += 1;
    const counterparty = isActor ? swipe.targetUid : swipe.actorUid;
    const category = classifyRelation(counterparty, sets);
    if (category === RELATION_CATEGORY.CURRENT_AUTH_USER) {
      agg.swipesWithCurrentAuthUsers += 1;
    } else if (category === RELATION_CATEGORY.KNOWN_DUMMY_ORPHAN) {
      agg.swipesWithKnownDummyUsers += 1;
    } else if (category === RELATION_CATEGORY.UNKNOWN_ORPHAN) {
      agg.swipesWithOtherOrphans += 1;
    }
    if (typeof swipe.timestampSec === 'number') times.push(swipe.timestampSec);
  }
  agg.swipeTimestampCohort = activityCohort(times, cohortTimesSec);
  return agg;
}

// matches: descriptors { participants[], uid1, uid2, timestampSec, messageCount,
// nonMessageSubcollections } for matches that involve the orphan.
function aggregateOrphanMatches({ orphanUid, matches, sets, cohortTimesSec }) {
  const agg = {
    matchesContainingUnknown: 0,
    matchesWithCurrentAuthUsers: 0,
    matchesWithKnownDummyUsers: 0,
    matchesWithOtherOrphans: 0,
    matchesWithMessages: 0,
    matchesWithNonMessageSubcollections: 0,
    matchTimestampCohort: ACTIVITY_COHORT.UNKNOWN,
  };
  const times = [];
  for (const match of matches || []) {
    const participants = Array.isArray(match.participants) ? match.participants : [];
    const members = new Set([...participants, match.uid1, match.uid2]);
    if (!members.has(orphanUid)) continue;
    agg.matchesContainingUnknown += 1;
    for (const member of members) {
      if (member === orphanUid || typeof member !== 'string') continue;
      const category = classifyRelation(member, sets);
      if (category === RELATION_CATEGORY.CURRENT_AUTH_USER) {
        agg.matchesWithCurrentAuthUsers += 1;
      } else if (category === RELATION_CATEGORY.KNOWN_DUMMY_ORPHAN) {
        agg.matchesWithKnownDummyUsers += 1;
      } else if (category === RELATION_CATEGORY.UNKNOWN_ORPHAN) {
        agg.matchesWithOtherOrphans += 1;
      }
    }
    if (typeof match.messageCount === 'number' && match.messageCount > 0) {
      agg.matchesWithMessages += 1;
    }
    if (
      typeof match.nonMessageSubcollections === 'number' &&
      match.nonMessageSubcollections > 0
    ) {
      agg.matchesWithNonMessageSubcollections += 1;
    }
    if (typeof match.timestampSec === 'number') times.push(match.timestampSec);
  }
  agg.matchTimestampCohort = activityCohort(times, cohortTimesSec);
  return agg;
}

// Section 10 — relationship summary across swipes + matches.
function aggregateRelations({ swipeAgg, matchAgg }) {
  return {
    relatedCurrentAuthUsers:
      swipeAgg.swipesWithCurrentAuthUsers + matchAgg.matchesWithCurrentAuthUsers,
    relatedKnownDummyUsers:
      swipeAgg.swipesWithKnownDummyUsers + matchAgg.matchesWithKnownDummyUsers,
    relatedOtherUnknownUsers:
      swipeAgg.swipesWithOtherOrphans + matchAgg.matchesWithOtherOrphans,
  };
}

// --------------------------------------------------------------------------
// Section 7 — historical dummy pattern matching (git-derived facts passed in).
// --------------------------------------------------------------------------

// Historical dummy payload signature (from removed dummy_data_service.dart):
// external stock photos (pravatar/picsum), has birthDate + exact location,
// no FCM tokens, no account contact fields, no onboarding-completion markers.
function payloadPatternMatchesHistoricalDummy(characteristics) {
  const c = characteristics || {};
  const signals = [
    c.photoStorageClass === PHOTO_STORAGE_CLASS.EXTERNAL_URL,
    c.hasExactLocation === true,
    c.hasBirthData === true,
    c.hasFCMTokens === false,
    c.hasAccountContactFields === false,
    c.hasOnboardingCompletionState === false,
  ];
  const matched = signals.filter(Boolean).length;
  // The external-stock-photo tell is decisive: real users upload to Firebase
  // Storage. Without it we never return a full match.
  if (c.photoStorageClass === PHOTO_STORAGE_CLASS.EXTERNAL_URL && matched >= 5) {
    return 'yes';
  }
  if (matched >= 3) return 'partial';
  return 'no';
}

// Historical dummy reference signature: the orphan acts as a swipe ACTOR toward
// a current Auth user (the reverse-seed swipe dummy_001/003/006 performed),
// created within the dummy cohort window.
function referencePatternMatchesHistoricalDummy(swipeAgg) {
  const a = swipeAgg || {};
  const seedShape = a.unknownAsSwipeActor > 0 && a.swipesWithCurrentAuthUsers > 0;
  if (seedShape && a.swipeTimestampCohort === ACTIVITY_COHORT.WITH_DUMMY_SEED) {
    return 'yes';
  }
  if (seedShape) return 'partial';
  return 'no';
}

// --------------------------------------------------------------------------
// Section 13 — classification scoring.
// --------------------------------------------------------------------------

// Gather weighted signals for each hypothesis, then pick the classification and
// a confidence. Never includes raw values in signal strings.
function scoreClassification(signals) {
  const s = signals || {};
  const supporting = {
    [CLASSIFICATION.KNOWN_SEED_OR_TEST_DATA]: [],
    [CLASSIFICATION.DELETED_REAL_USER_LIKELY]: [],
    [CLASSIFICATION.INCOMPLETE_SIGNUP_OR_ACCOUNT_CREATION]: [],
  };

  const dummyRank = Math.max(
    similarityRank(s.usersSchemaSimilarityToDummy),
    similarityRank(s.publicSchemaSimilarityToDummy),
  );
  const realRank = Math.max(
    similarityRank(s.usersSchemaSimilarityToReal),
    similarityRank(s.publicSchemaSimilarityToReal),
  );

  // --- KNOWN_SEED_OR_TEST_DATA ---
  const seed = supporting[CLASSIFICATION.KNOWN_SEED_OR_TEST_DATA];
  if (s.exactIdFoundInGitHistory === true) seed.push('exactIdFoundInGitHistory');
  if (s.payloadPatternMatchesHistoricalDummy === 'yes') {
    seed.push('payloadPatternMatchesHistoricalDummy');
  }
  if (s.referencePatternMatchesHistoricalDummy === 'yes') {
    seed.push('referencePatternMatchesHistoricalDummy');
  }
  if (s.createdWithDummyCohort === COHORT.TRUE) seed.push('createdWithDummyCohort');
  if (dummyRank > realRank && dummyRank >= similarityRank(SIMILARITY.MEDIUM)) {
    seed.push('schemaCloserToDummy');
  }
  if (s.photoStorageClass === PHOTO_STORAGE_CLASS.EXTERNAL_URL) {
    seed.push('externalStockPhotos');
  }
  if (s.relatedCurrentAuthUsers === 0) seed.push('noCurrentAuthUserRelationship');

  // --- DELETED_REAL_USER_LIKELY ---
  const deleted = supporting[CLASSIFICATION.DELETED_REAL_USER_LIKELY];
  if (s.documentIdFormatClass === DOCUMENT_ID_FORMAT.FIREBASE_UID_LIKE) {
    deleted.push('firebaseUidLikeId');
  }
  if (realRank > dummyRank && realRank >= similarityRank(SIMILARITY.HIGH)) {
    deleted.push('schemaCloserToReal');
  }
  if (s.hasActivityTimestamp === true) deleted.push('hasActivityTimestamp');
  if (s.hasCompletedOnboardingMarker === true) {
    deleted.push('hasCompletedOnboardingMarker');
  }
  if (s.relatedCurrentAuthUsers > 0) deleted.push('interactedWithCurrentAuthUsers');
  if (s.createdWithDummyCohort === COHORT.FALSE) deleted.push('outsideDummyCohort');
  if (s.hasDeletionMarker === true || s.hasDeactivationMarker === true) {
    deleted.push('accountLifecycleMarker');
  }
  if (s.hasFCMTokens === true) deleted.push('hasFCMTokens');
  if (s.photoStorageClass === PHOTO_STORAGE_CLASS.FIREBASE_STORAGE) {
    deleted.push('firebaseStoragePhotos');
  }

  // --- INCOMPLETE_SIGNUP_OR_ACCOUNT_CREATION ---
  const incomplete = supporting[CLASSIFICATION.INCOMPLETE_SIGNUP_OR_ACCOUNT_CREATION];
  const noReferences =
    s.relatedCurrentAuthUsers === 0 &&
    s.relatedKnownDummyUsers === 0 &&
    s.relatedOtherUnknownUsers === 0 &&
    s.totalReferenceCount === 0;
  if (realRank >= similarityRank(SIMILARITY.LOW) && realRank < similarityRank(SIMILARITY.HIGH)) {
    incomplete.push('partialRealSchema');
  }
  if (s.hasCompletedOnboardingMarker === false && s.hasOnboardingCompletionState === true) {
    incomplete.push('onboardingNotCompleted');
  }
  if (noReferences) incomplete.push('noReferenceData');
  if (s.hasProfilePhotos === false) incomplete.push('noProfilePhotos');
  if (s.hasNonEmptyDisplayName === false) incomplete.push('noDisplayName');

  const scored = Object.entries(supporting)
    .map(([classification, list]) => ({ classification, count: list.length }))
    .sort((a, b) => b.count - a.count);

  const top = scored[0];
  const second = scored[1];

  // Build contradicting signals = the strongest competing hypothesis's support.
  const contradicting = second && second.count > 0 ? supporting[second.classification] : [];

  // Decide classification + confidence.
  let classification;
  let confidence;

  if (!top || top.count === 0) {
    classification = CLASSIFICATION.MANUAL_REVIEW_REQUIRED;
    confidence = CONFIDENCE.LOW;
  } else if (second && second.count > 0 && top.count - second.count <= 1) {
    // Genuinely conflicting evidence between two hypotheses.
    classification = CLASSIFICATION.MANUAL_REVIEW_REQUIRED;
    confidence = top.count >= 3 ? CONFIDENCE.MEDIUM : CONFIDENCE.LOW;
  } else {
    classification = top.classification;
    const margin = top.count - (second ? second.count : 0);
    if (top.count >= 4 && margin >= 3) confidence = CONFIDENCE.HIGH;
    else if (top.count >= 3 && margin >= 2) confidence = CONFIDENCE.MEDIUM;
    else confidence = CONFIDENCE.LOW;
  }

  // Hard override: any account lifecycle deletion/deactivation marker forces at
  // least manual review — never auto-classify a marked account as disposable.
  if (
    (s.hasDeletionMarker === true || s.hasDeactivationMarker === true) &&
    classification === CLASSIFICATION.KNOWN_SEED_OR_TEST_DATA
  ) {
    classification = CLASSIFICATION.MANUAL_REVIEW_REQUIRED;
    confidence = CONFIDENCE.LOW;
  }

  return {
    classification,
    confidence,
    supportingSignals:
      classification === CLASSIFICATION.MANUAL_REVIEW_REQUIRED
        ? Array.from(new Set([...(top ? supporting[top.classification] : []), ...contradicting]))
        : supporting[classification],
    contradictingSignals:
      classification === CLASSIFICATION.MANUAL_REVIEW_REQUIRED ? [] : contradicting,
  };
}

// --------------------------------------------------------------------------
// Section 14 — cleanup / deletion-eligibility decision (never deletes).
// --------------------------------------------------------------------------

function cleanupDecision({ classification, confidence, signals }) {
  const s = signals || {};
  const hasLifecycleMarker =
    s.hasDeletionMarker === true || s.hasDeactivationMarker === true;

  // SAFE only when ALL conditions hold — conservative by construction.
  const safe =
    classification === CLASSIFICATION.KNOWN_SEED_OR_TEST_DATA &&
    confidence === CONFIDENCE.HIGH &&
    s.relatedCurrentAuthUsers === 0 &&
    s.matchesWithMessages === 0 &&
    !hasLifecycleMarker;
  if (safe) return CLEANUP_DECISION.SAFE;

  if (
    classification === CLASSIFICATION.DELETED_REAL_USER_LIKELY ||
    hasLifecycleMarker
  ) {
    return CLEANUP_DECISION.RECOVERY;
  }

  return CLEANUP_DECISION.MANUAL;
}

module.exports = {
  KNOWN_DUMMY_ID_PATTERN,
  DOCUMENT_ID_FORMAT,
  TIME_BUCKET,
  COHORT,
  SIMILARITY,
  SIMILARITY_RANK,
  PHOTO_STORAGE_CLASS,
  PHOTO_COUNT_BUCKET,
  ACTIVITY_COHORT,
  CLASSIFICATION,
  CONFIDENCE,
  CLEANUP_DECISION,
  RELATION_CATEGORY,
  safeUidHash,
  selectUnknownOrphan,
  classifyDocumentIdFormat,
  metadataTimeBucket,
  cohortMembership,
  firestoreTypeOf,
  schemaFingerprint,
  jaccard,
  schemaSimilarityToGroup,
  similarityRank,
  photoCountBucket,
  photoStorageClass,
  valueCharacteristics,
  lifecycleMarkers,
  classifyRelation,
  activityCohort,
  aggregateOrphanSwipes,
  aggregateOrphanMatches,
  aggregateRelations,
  payloadPatternMatchesHistoricalDummy,
  referencePatternMatchesHistoricalDummy,
  scoreClassification,
  cleanupDecision,
};
