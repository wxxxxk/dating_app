'use strict';

// Pure migration planner for the auth verification badge server-only migration
// APPLY tool. This module performs NO Firestore/Auth I/O and NEVER writes — it
// produces a plan (which of the two documents to update, with what payload) and
// folds per-user results into aggregate counters. The Firestore transaction and
// the actual transaction.update calls live in ../scripts/auth_verification_badge_apply.
//
// Canonical badge derivation and stored-shape/compare policy are delegated to
// the existing helpers so the apply tool can never drift from the dry-run audit
// or the production callable policy.

const {
  deriveAuthVerificationBadges,
  normalizeVerificationMap,
  safeUidHash,
} = require('./auth_verification_badges');
const {
  VERIFICATION_KEYS,
  normalizeStoredVerifications,
  compareVerificationBadges,
} = require('./auth_verification_badge_audit');

// Mutually-exclusive, exhaustive per-user results (section 10). NORMALIZED_*
// means a document was rewritten only because its stored shape was malformed but
// value-equivalent to canonical; UPDATED_* means at least one boolean value
// actually changed.
const RESULTS = Object.freeze({
  UNCHANGED: 'UNCHANGED',
  UPDATED_USERS_ONLY: 'UPDATED_USERS_ONLY',
  UPDATED_PUBLIC_PROFILE_ONLY: 'UPDATED_PUBLIC_PROFILE_ONLY',
  UPDATED_BOTH: 'UPDATED_BOTH',
  NORMALIZED_USERS_ONLY: 'NORMALIZED_USERS_ONLY',
  NORMALIZED_PUBLIC_PROFILE_ONLY: 'NORMALIZED_PUBLIC_PROFILE_ONLY',
  NORMALIZED_BOTH: 'NORMALIZED_BOTH',
  MISSING_USERS_DOCUMENT: 'MISSING_USERS_DOCUMENT',
  MISSING_PUBLIC_PROFILE_DOCUMENT: 'MISSING_PUBLIC_PROFILE_DOCUMENT',
  MISSING_BOTH_DOCUMENTS: 'MISSING_BOTH_DOCUMENTS',
  AUTH_READ_ERROR: 'AUTH_READ_ERROR',
  FIRESTORE_READ_ERROR: 'FIRESTORE_READ_ERROR',
  WRITE_ERROR: 'WRITE_ERROR',
});

const ERROR_RESULTS = Object.freeze([
  RESULTS.AUTH_READ_ERROR,
  RESULTS.FIRESTORE_READ_ERROR,
  RESULTS.WRITE_ERROR,
]);

function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

// Build the canonical verifications map for a document write. Always a fresh
// object with exactly the three canonical keys — never mutates canonical.
function canonicalMap(canonical) {
  return { email: canonical.email, phone: canonical.phone, photo: canonical.photo };
}

// Plan one Auth user's migration. `userRecord` is the Firebase Auth record (the
// only source of canonical truth). usersData/publicData are the raw Firestore
// document data (or undefined). Missing documents are never created.
function planUserMigration({
  uid,
  userRecord,
  usersExists,
  usersData,
  publicExists,
  publicData,
}) {
  const canonical = deriveAuthVerificationBadges(userRecord);
  const uidHash = safeUidHash(uid);

  const base = {
    uidHash,
    canonical,
    bothExist: false,
    usersUpdate: null,
    publicUpdate: null,
    bumpProfileUpdatedAt: false,
    writesPlanned: 0,
    usersStoredNormalized: null,
    publicStoredNormalized: null,
    usersNormalized: false,
    publicNormalized: false,
    changedKeys: { users: [], public: [] },
  };

  // Missing documents are a failed-precondition: we sync a pair atomically and
  // never fabricate a document that does not exist.
  if (!usersExists && !publicExists) {
    return { ...base, result: RESULTS.MISSING_BOTH_DOCUMENTS };
  }
  if (!usersExists) {
    return { ...base, result: RESULTS.MISSING_USERS_DOCUMENT };
  }
  if (!publicExists) {
    return { ...base, result: RESULTS.MISSING_PUBLIC_PROFILE_DOCUMENT };
  }

  const rawUsers = isPlainObject(usersData) ? usersData.verifications : undefined;
  const rawPublic = isPlainObject(publicData) ? publicData.verifications : undefined;

  const usersShape = normalizeStoredVerifications(rawUsers);
  const publicShape = normalizeStoredVerifications(rawPublic);
  const usersStoredNormalized = normalizeVerificationMap(rawUsers);
  const publicStoredNormalized = normalizeVerificationMap(rawPublic);

  const usersCompare = compareVerificationBadges(canonical, usersStoredNormalized);
  const publicCompare = compareVerificationBadges(canonical, publicStoredNormalized);

  const usersValueChanged = usersCompare.changed;
  const publicValueChanged = publicCompare.changed;

  // A document needs a write when its stored value differs from canonical OR its
  // stored shape is malformed (even if value-equivalent — the map must become a
  // clean canonical shape).
  const usersNeedsWrite = usersValueChanged || usersShape.malformed;
  const publicNeedsWrite = publicValueChanged || publicShape.malformed;

  // Reason per document: 'value' dominates 'shape' so a value change is never
  // mislabelled as a pure normalization.
  const usersReason = usersValueChanged
    ? 'value'
    : usersShape.malformed
      ? 'shape'
      : 'none';
  const publicReason = publicValueChanged
    ? 'value'
    : publicShape.malformed
      ? 'shape'
      : 'none';

  let result;
  if (!usersNeedsWrite && !publicNeedsWrite) {
    result = RESULTS.UNCHANGED;
  } else if (usersReason === 'value' || publicReason === 'value') {
    // Any value change classifies the user in the UPDATED family; the suffix
    // reflects which documents are actually written.
    if (usersNeedsWrite && publicNeedsWrite) result = RESULTS.UPDATED_BOTH;
    else if (usersNeedsWrite) result = RESULTS.UPDATED_USERS_ONLY;
    else result = RESULTS.UPDATED_PUBLIC_PROFILE_ONLY;
  } else {
    // Only shape normalizations, no value change.
    if (usersNeedsWrite && publicNeedsWrite) result = RESULTS.NORMALIZED_BOTH;
    else if (usersNeedsWrite) result = RESULTS.NORMALIZED_USERS_ONLY;
    else result = RESULTS.NORMALIZED_PUBLIC_PROFILE_ONLY;
  }

  const usersUpdate = usersNeedsWrite ? { verifications: canonicalMap(canonical) } : null;
  const publicUpdate = publicNeedsWrite ? { verifications: canonicalMap(canonical) } : null;

  return {
    ...base,
    result,
    bothExist: true,
    usersUpdate,
    publicUpdate,
    // profileUpdatedAt is bumped ONLY when the public value actually changed —
    // a pure shape normalization must not touch the timestamp.
    bumpProfileUpdatedAt: publicValueChanged,
    writesPlanned: (usersUpdate ? 1 : 0) + (publicUpdate ? 1 : 0),
    usersStoredNormalized,
    publicStoredNormalized,
    usersNormalized: usersReason === 'shape',
    publicNormalized: publicReason === 'shape',
    changedKeys: { users: usersCompare.changedKeys, public: publicCompare.changedKeys },
  };
}

function createEmptyApplyAggregate(project) {
  return {
    project,
    mode: 'apply',
    authUsersScanned: 0,

    // Per-user classification buckets (drive the classification invariant).
    unchanged: 0,
    updatedUsersOnly: 0,
    updatedPublicProfileOnly: 0,
    updatedBoth: 0,
    normalizedUsersOnly: 0,
    normalizedPublicProfileOnly: 0,
    normalizedBoth: 0,
    missingUsersDocuments: 0,
    missingPublicProfileDocuments: 0,
    missingBothDocuments: 0,
    errors: 0,

    // Document-level normalization tallies (a user may be UPDATED overall while
    // one of its documents was a pure shape normalization).
    normalizedUsers: 0,
    normalizedPublicProfiles: 0,

    canonicalEmailTrue: 0,
    canonicalPhoneTrue: 0,
    canonicalPhotoTrue: 0,

    usersEmailFalseToTrue: 0,
    usersEmailTrueToFalse: 0,
    usersPhoneFalseToTrue: 0,
    usersPhoneTrueToFalse: 0,
    usersPhotoTrueToFalse: 0,

    publicEmailFalseToTrue: 0,
    publicEmailTrueToFalse: 0,
    publicPhoneFalseToTrue: 0,
    publicPhoneTrueToFalse: 0,
    publicPhotoTrueToFalse: 0,

    writesAttempted: 0,
    writesSucceeded: 0,
    errorCodeCounts: {},
    durationMs: 0,
  };
}

const RESULT_COUNTER = Object.freeze({
  [RESULTS.UNCHANGED]: 'unchanged',
  [RESULTS.UPDATED_USERS_ONLY]: 'updatedUsersOnly',
  [RESULTS.UPDATED_PUBLIC_PROFILE_ONLY]: 'updatedPublicProfileOnly',
  [RESULTS.UPDATED_BOTH]: 'updatedBoth',
  [RESULTS.NORMALIZED_USERS_ONLY]: 'normalizedUsersOnly',
  [RESULTS.NORMALIZED_PUBLIC_PROFILE_ONLY]: 'normalizedPublicProfileOnly',
  [RESULTS.NORMALIZED_BOTH]: 'normalizedBoth',
  [RESULTS.MISSING_USERS_DOCUMENT]: 'missingUsersDocuments',
  [RESULTS.MISSING_PUBLIC_PROFILE_DOCUMENT]: 'missingPublicProfileDocuments',
  [RESULTS.MISSING_BOTH_DOCUMENTS]: 'missingBothDocuments',
  [RESULTS.AUTH_READ_ERROR]: 'errors',
  [RESULTS.FIRESTORE_READ_ERROR]: 'errors',
  [RESULTS.WRITE_ERROR]: 'errors',
});

function recordCanonical(aggregate, canonical) {
  if (canonical.email) aggregate.canonicalEmailTrue += 1;
  if (canonical.phone) aggregate.canonicalPhoneTrue += 1;
  if (canonical.photo) aggregate.canonicalPhotoTrue += 1;
}

// Increment exactly one per-user classification bucket.
function recordResult(aggregate, result) {
  const counter = RESULT_COUNTER[result];
  if (counter) aggregate[counter] += 1;
}

function recordTransitionsForSide(aggregate, prefix, canonical, storedNormalized) {
  for (const key of VERIFICATION_KEYS) {
    const stored = storedNormalized[key] === true;
    const target = canonical[key] === true;
    const cap = key.charAt(0).toUpperCase() + key.slice(1);
    if (!stored && target) aggregate[`${prefix}${cap}FalseToTrue`] += 1;
    if (stored && !target) aggregate[`${prefix}${cap}TrueToFalse`] += 1;
  }
}

// Fold a committed (successfully-read, successfully-applied or no-op) plan into
// the aggregate. Records canonical tallies, the classification bucket, value
// transitions, and document-level normalizations. Does NOT touch write counters
// (those depend on the transaction commit and are owned by the script).
function recordCommittedPlan(aggregate, plan) {
  aggregate.authUsersScanned += 1;
  recordCanonical(aggregate, plan.canonical);
  recordResult(aggregate, plan.result);
  if (plan.bothExist) {
    recordTransitionsForSide(aggregate, 'users', plan.canonical, plan.usersStoredNormalized);
    recordTransitionsForSide(aggregate, 'public', plan.canonical, plan.publicStoredNormalized);
    if (plan.usersNormalized) aggregate.normalizedUsers += 1;
    if (plan.publicNormalized) aggregate.normalizedPublicProfiles += 1;
  }
  return aggregate;
}

// Fold an Auth read failure (canonical is unknown — Auth was unreachable).
function recordAuthReadError(aggregate, category) {
  aggregate.authUsersScanned += 1;
  recordResult(aggregate, RESULTS.AUTH_READ_ERROR);
  aggregate.errorCodeCounts[category] = (aggregate.errorCodeCounts[category] || 0) + 1;
  return aggregate;
}

// Fold a transaction failure (Auth read succeeded, so canonical is known, but
// the Firestore read/write transaction did not commit).
function recordTransactionError(aggregate, canonical, result, category) {
  aggregate.authUsersScanned += 1;
  if (canonical) recordCanonical(aggregate, canonical);
  recordResult(aggregate, result);
  aggregate.errorCodeCounts[category] = (aggregate.errorCodeCounts[category] || 0) + 1;
  return aggregate;
}

function classificationTotal(aggregate) {
  return (
    aggregate.unchanged +
    aggregate.updatedUsersOnly +
    aggregate.updatedPublicProfileOnly +
    aggregate.updatedBoth +
    aggregate.normalizedUsersOnly +
    aggregate.normalizedPublicProfileOnly +
    aggregate.normalizedBoth +
    aggregate.missingUsersDocuments +
    aggregate.missingPublicProfileDocuments +
    aggregate.missingBothDocuments +
    aggregate.errors
  );
}

function classificationInvariantHolds(aggregate) {
  return classificationTotal(aggregate) === aggregate.authUsersScanned;
}

function countersInvariantHold(aggregate) {
  return (
    aggregate.canonicalPhotoTrue === 0 &&
    aggregate.writesSucceeded <= aggregate.writesAttempted &&
    classificationInvariantHolds(aggregate)
  );
}

module.exports = {
  RESULTS,
  ERROR_RESULTS,
  VERIFICATION_KEYS,
  planUserMigration,
  createEmptyApplyAggregate,
  recordCanonical,
  recordResult,
  recordCommittedPlan,
  recordAuthReadError,
  recordTransactionError,
  classificationTotal,
  classificationInvariantHolds,
  countersInvariantHold,
  safeUidHash,
};
