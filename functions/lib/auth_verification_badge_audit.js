'use strict';

// Read-only audit helpers for the auth verification badge server-only
// migration. This module is pure: it performs no Firestore/Auth I/O and never
// writes. Canonical badge derivation is intentionally delegated to
// ../lib/auth_verification_badges so the migration audit can never drift from
// the production callable policy.

const {
  deriveAuthVerificationBadges,
  normalizeVerificationMap,
  safeUidHash,
} = require('./auth_verification_badges');

const VERIFICATION_KEYS = Object.freeze(['email', 'phone', 'photo']);

const STORED_SHAPES = Object.freeze({
  VALID: 'VALID',
  MISSING: 'MISSING',
  NOT_A_MAP: 'NOT_A_MAP',
  MISSING_KEYS: 'MISSING_KEYS',
  EXTRA_KEYS: 'EXTRA_KEYS',
  NON_BOOLEAN_VALUES: 'NON_BOOLEAN_VALUES',
});

const CLASSIFICATIONS = Object.freeze({
  IN_SYNC: 'IN_SYNC',
  WOULD_UPDATE_USERS_ONLY: 'WOULD_UPDATE_USERS_ONLY',
  WOULD_UPDATE_PUBLIC_PROFILE_ONLY: 'WOULD_UPDATE_PUBLIC_PROFILE_ONLY',
  WOULD_UPDATE_BOTH: 'WOULD_UPDATE_BOTH',
  MISSING_USERS_DOCUMENT: 'MISSING_USERS_DOCUMENT',
  MISSING_PUBLIC_PROFILE_DOCUMENT: 'MISSING_PUBLIC_PROFILE_DOCUMENT',
  MISSING_BOTH_DOCUMENTS: 'MISSING_BOTH_DOCUMENTS',
  MALFORMED_USERS_VERIFICATIONS: 'MALFORMED_USERS_VERIFICATIONS',
  MALFORMED_PUBLIC_PROFILE_VERIFICATIONS: 'MALFORMED_PUBLIC_PROFILE_VERIFICATIONS',
  MALFORMED_BOTH_VERIFICATIONS: 'MALFORMED_BOTH_VERIFICATIONS',
  READ_ERROR: 'READ_ERROR',
});

function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

// Classify the stored `verifications` field shape without ever coercing a
// malformed value into a trusted `true`. Returns a shape label, a `malformed`
// flag (anything other than VALID), and a safe boolean normalization reusing
// the production callable's normalizeVerificationMap so comparison semantics
// cannot drift.
function normalizeStoredVerifications(rawVerifications) {
  let shape;
  if (rawVerifications === undefined || rawVerifications === null) {
    shape = STORED_SHAPES.MISSING;
  } else if (!isPlainObject(rawVerifications)) {
    shape = STORED_SHAPES.NOT_A_MAP;
  } else {
    const keys = Object.keys(rawVerifications);
    const knownKeys = keys.filter((key) => VERIFICATION_KEYS.includes(key));
    const extraKeys = keys.filter((key) => !VERIFICATION_KEYS.includes(key));
    const missingKeys = VERIFICATION_KEYS.filter((key) => !keys.includes(key));
    const nonBooleanKeys = knownKeys.filter(
      (key) => typeof rawVerifications[key] !== 'boolean',
    );

    if (nonBooleanKeys.length > 0) {
      shape = STORED_SHAPES.NON_BOOLEAN_VALUES;
    } else if (missingKeys.length > 0) {
      shape = STORED_SHAPES.MISSING_KEYS;
    } else if (extraKeys.length > 0) {
      shape = STORED_SHAPES.EXTRA_KEYS;
    } else {
      shape = STORED_SHAPES.VALID;
    }
  }

  return {
    shape,
    malformed: shape !== STORED_SHAPES.VALID,
    normalized: normalizeVerificationMap(rawVerifications),
  };
}

// Compare canonical Auth badges against a normalized stored map. Returns the
// keys that would change during migration and whether any change is needed.
function compareVerificationBadges(canonical, storedNormalized) {
  const changedKeys = VERIFICATION_KEYS.filter(
    (key) => canonical[key] !== storedNormalized[key],
  );
  return { changedKeys, changed: changedKeys.length > 0 };
}

function analyzeStoredSide(exists, rawVerifications, canonical) {
  if (!exists) {
    return {
      exists: false,
      shape: null,
      malformed: false,
      normalized: null,
      changedKeys: [],
    };
  }
  const { shape, malformed, normalized } =
    normalizeStoredVerifications(rawVerifications);
  const { changedKeys } = compareVerificationBadges(canonical, normalized);
  return { exists: true, shape, malformed, normalized, changedKeys };
}

// Classify a single Auth user against the users/{uid} and publicProfiles/{uid}
// documents. Classification is mutually exclusive and exhaustive so aggregate
// counters can invariant-check against authUsersScanned.
function analyzeUser({
  uid,
  userRecord,
  usersExists,
  usersData,
  publicExists,
  publicData,
  readError = false,
}) {
  const canonical = deriveAuthVerificationBadges(userRecord);

  if (readError) {
    return {
      uidHash: safeUidHash(uid),
      classification: CLASSIFICATIONS.READ_ERROR,
      canonical,
      users: { exists: false, shape: null, malformed: false, normalized: null, changedKeys: [] },
      public: { exists: false, shape: null, malformed: false, normalized: null, changedKeys: [] },
    };
  }

  const rawUserVerifications = isPlainObject(usersData)
    ? usersData.verifications
    : undefined;
  const rawPublicVerifications = isPlainObject(publicData)
    ? publicData.verifications
    : undefined;

  const users = analyzeStoredSide(
    usersExists === true,
    rawUserVerifications,
    canonical,
  );
  const publicProfile = analyzeStoredSide(
    publicExists === true,
    rawPublicVerifications,
    canonical,
  );

  let classification;
  if (!users.exists && !publicProfile.exists) {
    classification = CLASSIFICATIONS.MISSING_BOTH_DOCUMENTS;
  } else if (!users.exists) {
    classification = CLASSIFICATIONS.MISSING_USERS_DOCUMENT;
  } else if (!publicProfile.exists) {
    classification = CLASSIFICATIONS.MISSING_PUBLIC_PROFILE_DOCUMENT;
  } else if (users.malformed && publicProfile.malformed) {
    classification = CLASSIFICATIONS.MALFORMED_BOTH_VERIFICATIONS;
  } else if (users.malformed) {
    classification = CLASSIFICATIONS.MALFORMED_USERS_VERIFICATIONS;
  } else if (publicProfile.malformed) {
    classification = CLASSIFICATIONS.MALFORMED_PUBLIC_PROFILE_VERIFICATIONS;
  } else {
    const usersChanged = users.changedKeys.length > 0;
    const publicChanged = publicProfile.changedKeys.length > 0;
    if (!usersChanged && !publicChanged) {
      classification = CLASSIFICATIONS.IN_SYNC;
    } else if (usersChanged && !publicChanged) {
      classification = CLASSIFICATIONS.WOULD_UPDATE_USERS_ONLY;
    } else if (!usersChanged && publicChanged) {
      classification = CLASSIFICATIONS.WOULD_UPDATE_PUBLIC_PROFILE_ONLY;
    } else {
      classification = CLASSIFICATIONS.WOULD_UPDATE_BOTH;
    }
  }

  return {
    uidHash: safeUidHash(uid),
    classification,
    canonical,
    users,
    public: publicProfile,
  };
}

function createEmptyAggregate(project) {
  return {
    project,
    mode: 'dry-run',
    authUsersScanned: 0,

    usersDocumentsFound: 0,
    publicProfilesDocumentsFound: 0,

    inSync: 0,
    wouldUpdateUsersOnly: 0,
    wouldUpdatePublicProfileOnly: 0,
    wouldUpdateBoth: 0,

    missingUsersDocuments: 0,
    missingPublicProfileDocuments: 0,
    missingBothDocuments: 0,

    malformedUsersVerifications: 0,
    malformedPublicProfileVerifications: 0,
    malformedBothVerifications: 0,

    orphanUsersDocuments: 0,
    orphanPublicProfileDocuments: 0,

    canonicalEmailTrue: 0,
    canonicalEmailFalse: 0,
    canonicalPhoneTrue: 0,
    canonicalPhoneFalse: 0,
    canonicalPhotoTrue: 0,
    canonicalPhotoFalse: 0,

    usersEmailTrue: 0,
    usersPhoneTrue: 0,
    usersPhotoTrue: 0,
    publicEmailTrue: 0,
    publicPhoneTrue: 0,
    publicPhotoTrue: 0,

    usersEmailFalseToTrue: 0,
    usersEmailTrueToFalse: 0,
    usersPhoneFalseToTrue: 0,
    usersPhoneTrueToFalse: 0,
    usersPhotoFalseToTrue: 0,
    usersPhotoTrueToFalse: 0,

    publicEmailFalseToTrue: 0,
    publicEmailTrueToFalse: 0,
    publicPhoneFalseToTrue: 0,
    publicPhoneTrueToFalse: 0,
    publicPhotoFalseToTrue: 0,
    publicPhotoTrueToFalse: 0,

    usersEmailTrueWithoutAuthEvidence: 0,
    publicEmailTrueWithoutAuthEvidence: 0,
    usersPhoneTrueWithoutAuthEvidence: 0,
    publicPhoneTrueWithoutAuthEvidence: 0,

    errors: 0,
    errorCodeCounts: {},
    writesAttempted: 0,
    durationMs: 0,
  };
}

const CLASSIFICATION_COUNTER = Object.freeze({
  [CLASSIFICATIONS.IN_SYNC]: 'inSync',
  [CLASSIFICATIONS.WOULD_UPDATE_USERS_ONLY]: 'wouldUpdateUsersOnly',
  [CLASSIFICATIONS.WOULD_UPDATE_PUBLIC_PROFILE_ONLY]: 'wouldUpdatePublicProfileOnly',
  [CLASSIFICATIONS.WOULD_UPDATE_BOTH]: 'wouldUpdateBoth',
  [CLASSIFICATIONS.MISSING_USERS_DOCUMENT]: 'missingUsersDocuments',
  [CLASSIFICATIONS.MISSING_PUBLIC_PROFILE_DOCUMENT]: 'missingPublicProfileDocuments',
  [CLASSIFICATIONS.MISSING_BOTH_DOCUMENTS]: 'missingBothDocuments',
  [CLASSIFICATIONS.MALFORMED_USERS_VERIFICATIONS]: 'malformedUsersVerifications',
  [CLASSIFICATIONS.MALFORMED_PUBLIC_PROFILE_VERIFICATIONS]: 'malformedPublicProfileVerifications',
  [CLASSIFICATIONS.MALFORMED_BOTH_VERIFICATIONS]: 'malformedBothVerifications',
  [CLASSIFICATIONS.READ_ERROR]: 'errors',
});

function recordCanonical(aggregate, canonical) {
  aggregate[canonical.email ? 'canonicalEmailTrue' : 'canonicalEmailFalse'] += 1;
  aggregate[canonical.phone ? 'canonicalPhoneTrue' : 'canonicalPhoneFalse'] += 1;
  aggregate[canonical.photo ? 'canonicalPhotoTrue' : 'canonicalPhotoFalse'] += 1;
}

function recordSide(aggregate, prefix, canonical, side) {
  if (!side.exists || side.normalized === null) return;
  for (const key of VERIFICATION_KEYS) {
    const stored = side.normalized[key] === true;
    const target = canonical[key] === true;
    const capitalized = key.charAt(0).toUpperCase() + key.slice(1);
    if (stored) {
      aggregate[`${prefix}${capitalized}True`] += 1;
    }
    if (!stored && target) {
      aggregate[`${prefix}${capitalized}FalseToTrue`] += 1;
    }
    if (stored && !target) {
      aggregate[`${prefix}${capitalized}TrueToFalse`] += 1;
      if (key === 'email' || key === 'phone') {
        aggregate[`${prefix}${capitalized}TrueWithoutAuthEvidence`] += 1;
      }
    }
  }
}

// Fold one per-user analysis into the aggregate. Mutates and returns the
// aggregate. Every scanned user increments exactly one classification counter.
function recordAnalysis(aggregate, analysis) {
  aggregate.authUsersScanned += 1;
  recordCanonical(aggregate, analysis.canonical);

  const counterKey = CLASSIFICATION_COUNTER[analysis.classification];
  if (counterKey) {
    aggregate[counterKey] += 1;
  }
  if (analysis.classification === CLASSIFICATIONS.READ_ERROR) {
    aggregate.errorCodeCounts.READ_ERROR =
      (aggregate.errorCodeCounts.READ_ERROR || 0) + 1;
  }

  recordSide(aggregate, 'users', analysis.canonical, analysis.users);
  recordSide(aggregate, 'public', analysis.canonical, analysis.public);
  return aggregate;
}

// Sum of the mutually exclusive per-user classification buckets. Must always
// equal authUsersScanned.
function classificationTotal(aggregate) {
  return (
    aggregate.inSync +
    aggregate.wouldUpdateUsersOnly +
    aggregate.wouldUpdatePublicProfileOnly +
    aggregate.wouldUpdateBoth +
    aggregate.missingUsersDocuments +
    aggregate.missingPublicProfileDocuments +
    aggregate.missingBothDocuments +
    aggregate.malformedUsersVerifications +
    aggregate.malformedPublicProfileVerifications +
    aggregate.malformedBothVerifications +
    aggregate.errors
  );
}

function classificationInvariantHolds(aggregate) {
  return classificationTotal(aggregate) === aggregate.authUsersScanned;
}

// Count how many document IDs have no matching Auth account. Pure so the orphan
// aggregation can be tested without Firestore.
function countOrphanDocumentIds(docIds, authUids) {
  let total = 0;
  let orphans = 0;
  for (const id of docIds) {
    total += 1;
    if (!authUids.has(id)) orphans += 1;
  }
  return { total, orphans };
}

module.exports = {
  VERIFICATION_KEYS,
  STORED_SHAPES,
  CLASSIFICATIONS,
  normalizeStoredVerifications,
  compareVerificationBadges,
  analyzeUser,
  createEmptyAggregate,
  recordAnalysis,
  classificationTotal,
  classificationInvariantHolds,
  countOrphanDocumentIds,
};
