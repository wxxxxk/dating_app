'use strict';

// Read-only forensic helpers for the auth verification badge migration
// blockers found in Phase 0-D-3 (orphan documents + malformed users
// verifications). Pure: no Firestore/Auth I/O, no writes. Canonical badge
// derivation and shape normalization are reused from the existing audit chain
// so this forensic tool can never drift from the migration policy.

const {
  deriveAuthVerificationBadges,
  normalizeVerificationMap,
  safeUidHash,
} = require('./auth_verification_badges');
const { VERIFICATION_KEYS } = require('./auth_verification_badge_audit');

// Dummy seed accounts were created as dummy_001 .. dummy_010 by the removed
// lib/dev/dummy_data_service.dart and guarded by the removed
// firestore.rules `uid.matches('dummy_.*')` exception. Anything else is not a
// known dummy and must not be assumed to be one.
const KNOWN_DUMMY_ID_PATTERN = /^dummy_/;

const ORPHAN_CLASSES = Object.freeze({
  KNOWN_DUMMY_ID_PATTERN: 'KNOWN_DUMMY_ID_PATTERN',
  UNKNOWN_ORPHAN_ID: 'UNKNOWN_ORPHAN_ID',
});

const MALFORMED_SHAPES = Object.freeze({
  MISSING: 'MISSING',
  NOT_A_MAP: 'NOT_A_MAP',
  MISSING_KEYS: 'MISSING_KEYS',
  EXTRA_KEYS: 'EXTRA_KEYS',
  NON_BOOLEAN_VALUES: 'NON_BOOLEAN_VALUES',
  MULTIPLE_SHAPE_ERRORS: 'MULTIPLE_SHAPE_ERRORS',
  VALID: 'VALID',
});

const MALFORMED_MIGRATION = Object.freeze({
  USERS_ONLY: 'USERS_ONLY',
  PUBLIC_ONLY: 'PUBLIC_ONLY',
  BOTH: 'BOTH',
  ALREADY_CANONICAL: 'ALREADY_CANONICAL',
});

function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function toSet(ids) {
  return ids instanceof Set ? ids : new Set(ids);
}

function classifyOrphanId(id) {
  return KNOWN_DUMMY_ID_PATTERN.test(String(id))
    ? ORPHAN_CLASSES.KNOWN_DUMMY_ID_PATTERN
    : ORPHAN_CLASSES.UNKNOWN_ORPHAN_ID;
}

// Compute orphan document ID sets: document IDs that have no matching Auth
// account. Returns pairing metadata but never raw IDs to callers that print.
function computeOrphanSets(authIds, userDocIds, publicDocIds) {
  const auth = toSet(authIds);
  const orphanUserIds = [...toSet(userDocIds)].filter((id) => !auth.has(id));
  const orphanPublicIds = [...toSet(publicDocIds)].filter((id) => !auth.has(id));
  const orphanUserSet = new Set(orphanUserIds);
  const orphanPublicSet = new Set(orphanPublicIds);

  const paired = orphanUserIds.filter((id) => orphanPublicSet.has(id));
  const usersOnly = orphanUserIds.filter((id) => !orphanPublicSet.has(id));
  const publicOnly = orphanPublicIds.filter((id) => !orphanUserSet.has(id));

  const exactlyEqual =
    orphanUserIds.length === orphanPublicIds.length &&
    orphanUserIds.every((id) => orphanPublicSet.has(id));

  return {
    orphanUserIds,
    orphanPublicIds,
    orphanUserCount: orphanUserIds.length,
    orphanPublicCount: orphanPublicIds.length,
    pairedOrphanCount: paired.length,
    usersOnlyOrphanCount: usersOnly.length,
    publicOnlyOrphanCount: publicOnly.length,
    orphanIdSetsExactlyEqual: exactlyEqual,
  };
}

// Classify a set of orphan IDs by the known dummy pattern. Returns aggregate
// counts and privacy-safe per-id entries (uidHash + class only).
function classifyOrphans(orphanIds) {
  let knownDummy = 0;
  let unknown = 0;
  const entries = [];
  for (const id of orphanIds) {
    const orphanClass = classifyOrphanId(id);
    if (orphanClass === ORPHAN_CLASSES.KNOWN_DUMMY_ID_PATTERN) {
      knownDummy += 1;
    } else {
      unknown += 1;
    }
    entries.push({ uidHash: safeUidHash(id), orphanClass });
  }
  return { knownDummy, unknown, entries };
}

// Diagnose the shape of a stored verifications map, distinguishing multiple
// concurrent defects (MULTIPLE_SHAPE_ERRORS). Never coerces a malformed value
// into a trusted true.
function diagnoseMalformedVerifications(rawVerifications) {
  if (rawVerifications === undefined || rawVerifications === null) {
    return {
      shape: MALFORMED_SHAPES.MISSING,
      missingKeys: [...VERIFICATION_KEYS],
      extraKeys: [],
      nonBooleanKeys: [],
    };
  }
  if (!isPlainObject(rawVerifications)) {
    return {
      shape: MALFORMED_SHAPES.NOT_A_MAP,
      missingKeys: [],
      extraKeys: [],
      nonBooleanKeys: [],
    };
  }

  const keys = Object.keys(rawVerifications);
  const extraKeys = keys.filter((key) => !VERIFICATION_KEYS.includes(key)).sort();
  const missingKeys = VERIFICATION_KEYS.filter((key) => !keys.includes(key));
  const nonBooleanKeys = VERIFICATION_KEYS.filter(
    (key) => keys.includes(key) && typeof rawVerifications[key] !== 'boolean',
  );

  const defectCount =
    (missingKeys.length > 0 ? 1 : 0) +
    (extraKeys.length > 0 ? 1 : 0) +
    (nonBooleanKeys.length > 0 ? 1 : 0);

  let shape;
  if (defectCount > 1) {
    shape = MALFORMED_SHAPES.MULTIPLE_SHAPE_ERRORS;
  } else if (nonBooleanKeys.length > 0) {
    shape = MALFORMED_SHAPES.NON_BOOLEAN_VALUES;
  } else if (missingKeys.length > 0) {
    shape = MALFORMED_SHAPES.MISSING_KEYS;
  } else if (extraKeys.length > 0) {
    shape = MALFORMED_SHAPES.EXTRA_KEYS;
  } else {
    shape = MALFORMED_SHAPES.VALID;
  }

  return { shape, missingKeys, extraKeys, nonBooleanKeys };
}

// Given a userRecord and the raw stored maps, produce a privacy-safe forensic
// diagnosis of a malformed user: which keys would change during migration and
// whether the fix is a safe automatic normalization.
function diagnoseMalformedUser({
  uid,
  userRecord,
  rawUserVerifications,
  rawPublicVerifications,
}) {
  const canonical = deriveAuthVerificationBadges(userRecord);
  const userShape = diagnoseMalformedVerifications(rawUserVerifications);
  const publicShape = diagnoseMalformedVerifications(rawPublicVerifications);
  const usersNormalized = normalizeVerificationMap(rawUserVerifications);
  const publicNormalized = normalizeVerificationMap(rawPublicVerifications);

  const usersChangedKeys = VERIFICATION_KEYS.filter(
    (key) => canonical[key] !== usersNormalized[key],
  );
  const publicChangedKeys = VERIFICATION_KEYS.filter(
    (key) => canonical[key] !== publicNormalized[key],
  );

  let migration;
  if (usersChangedKeys.length > 0 && publicChangedKeys.length > 0) {
    migration = MALFORMED_MIGRATION.BOTH;
  } else if (usersChangedKeys.length > 0) {
    migration = MALFORMED_MIGRATION.USERS_ONLY;
  } else if (publicChangedKeys.length > 0) {
    migration = MALFORMED_MIGRATION.PUBLIC_ONLY;
  } else {
    migration = MALFORMED_MIGRATION.ALREADY_CANONICAL;
  }

  return {
    uidHash: safeUidHash(uid),
    usersShape: userShape.shape,
    publicShape: publicShape.shape,
    missingKeys: userShape.missingKeys,
    extraKeys: userShape.extraKeys,
    nonBooleanKeys: userShape.nonBooleanKeys,
    canonicalChangedKeys: [...new Set([...usersChangedKeys, ...publicChangedKeys])],
    usersChangedKeys,
    publicChangedKeys,
    migration,
  };
}

function emptyReferenceAggregate() {
  return {
    orphanReferencesFound: 0,
    referencingCollections: [],
    orphanMatchReferences: 0,
    orphanSwipeReferences: 0,
    orphanBlockReferences: 0,
    orphanMessageOrChatReferences: 0,
    otherOrphanReferences: 0,
  };
}

function anyOrphan(orphanSet, ...ids) {
  return ids.some((id) => typeof id === 'string' && orphanSet.has(id));
}

// Aggregate references to orphan UIDs across the reference-bearing collections.
// Inputs are arrays of privacy-safe reference descriptors (only the UID fields
// needed for membership). Returns counts and the collection names that had at
// least one orphan reference. Pure and testable without Firestore.
function aggregateOrphanReferences(
  { swipes = [], matches = [], blocks = [], reports = [], messages = [] },
  orphanIds,
) {
  const orphanSet = toSet(orphanIds);
  const aggregate = emptyReferenceAggregate();
  const collections = new Set();

  for (const swipe of swipes) {
    if (anyOrphan(orphanSet, swipe.actorUid, swipe.targetUid)) {
      aggregate.orphanSwipeReferences += 1;
      collections.add('swipes');
    }
  }
  for (const match of matches) {
    const participants = Array.isArray(match.participants) ? match.participants : [];
    if (participants.some((id) => orphanSet.has(id)) ||
      anyOrphan(orphanSet, match.uid1, match.uid2)) {
      aggregate.orphanMatchReferences += 1;
      collections.add('matches');
    }
  }
  for (const block of blocks) {
    if (anyOrphan(orphanSet, block.blockerUid, block.blockedUid)) {
      aggregate.orphanBlockReferences += 1;
      collections.add('blocks');
    }
  }
  for (const message of messages) {
    if (anyOrphan(orphanSet, message.senderId)) {
      aggregate.orphanMessageOrChatReferences += 1;
      collections.add('messages');
    }
  }
  for (const report of reports) {
    if (anyOrphan(orphanSet, report.reportedUid, report.reporterUid)) {
      aggregate.otherOrphanReferences += 1;
      collections.add('reports');
    }
  }

  aggregate.referencingCollections = [...collections].sort();
  aggregate.orphanReferencesFound =
    aggregate.orphanSwipeReferences +
    aggregate.orphanMatchReferences +
    aggregate.orphanBlockReferences +
    aggregate.orphanMessageOrChatReferences +
    aggregate.otherOrphanReferences;
  return aggregate;
}

module.exports = {
  KNOWN_DUMMY_ID_PATTERN,
  ORPHAN_CLASSES,
  MALFORMED_SHAPES,
  MALFORMED_MIGRATION,
  classifyOrphanId,
  computeOrphanSets,
  classifyOrphans,
  diagnoseMalformedVerifications,
  diagnoseMalformedUser,
  aggregateOrphanReferences,
  emptyReferenceAggregate,
};
