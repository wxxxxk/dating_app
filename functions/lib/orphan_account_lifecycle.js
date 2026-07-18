'use strict';

const crypto = require('node:crypto');

const ACCOUNT_CATEGORY = Object.freeze({
  AUTH_ONLY: 'AUTH_ONLY',
  AUTH_WITH_PRIVATE_ONLY: 'AUTH_WITH_PRIVATE_ONLY',
  AUTH_WITH_PUBLIC_ONLY: 'AUTH_WITH_PUBLIC_ONLY',
  FIRESTORE_ONLY: 'FIRESTORE_ONLY',
  PROFILE_SHAPE_INVALID: 'PROFILE_SHAPE_INVALID',
  HEALTHY: 'HEALTHY',
});

const CLEANUP_RECOMMENDATION = Object.freeze({
  RETAIN: 'RETAIN',
  REPAIR: 'REPAIR',
  DISABLE_THEN_REVIEW: 'DISABLE_THEN_REVIEW',
  SAFE_DELETE_CANDIDATE: 'SAFE_DELETE_CANDIDATE',
  MANUAL_REVIEW_REQUIRED: 'MANUAL_REVIEW_REQUIRED',
});

const CLEANUP_ERROR = Object.freeze({
  EXECUTION_NOT_IMPLEMENTED: 'EXECUTION_NOT_IMPLEMENTED',
});

const REQUIRED_VERIFICATION_KEYS = ['email', 'phone', 'photo'];
const KNOWN_TEST_ACCOUNT_PATTERN = /^dummy_/;

function sha256Hex(value) {
  return crypto.createHash('sha256').update(String(value)).digest('hex');
}

function safeUidHash(uid) {
  return sha256Hex(uid).slice(0, 8);
}

function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function isTimestampLike(value) {
  return value instanceof Date ||
    (value && typeof value.toMillis === 'function') ||
    (value && Number.isInteger(value.seconds)) ||
    (value && Number.isInteger(value._seconds));
}

function millisFromTimestampLike(value) {
  if (!value) return null;
  if (value instanceof Date) return value.getTime();
  if (typeof value.toMillis === 'function') return value.toMillis();
  if (Number.isInteger(value.seconds)) return value.seconds * 1000;
  if (Number.isInteger(value._seconds)) return value._seconds * 1000;
  const parsed = Date.parse(String(value));
  return Number.isFinite(parsed) ? parsed : null;
}

function ageBucketFromMillis(timestampMs, nowMs) {
  if (!Number.isFinite(timestampMs) || !Number.isFinite(nowMs)) return 'unknown';
  const ageMs = nowMs - timestampMs;
  if (ageMs < 0) return 'future';
  const dayMs = 24 * 60 * 60 * 1000;
  const days = Math.floor(ageMs / dayMs);
  if (days < 1) return 'lt_1d';
  if (days < 7) return 'lt_7d';
  if (days < 30) return 'lt_30d';
  if (days < 90) return 'lt_90d';
  if (days < 365) return 'lt_365d';
  return 'gte_365d';
}

function authCreatedMillis(record) {
  return millisFromTimestampLike(record?.metadata?.creationTime);
}

function authLastSignInMillis(record) {
  return millisFromTimestampLike(record?.metadata?.lastSignInTime);
}

function hasValidVerificationMap(value) {
  return isPlainObject(value) &&
    REQUIRED_VERIFICATION_KEYS.every((key) => typeof value[key] === 'boolean') &&
    Object.keys(value).every((key) => REQUIRED_VERIFICATION_KEYS.includes(key));
}

function hasValidPrivateProfileShape(data) {
  return privateProfileShapeIssues(data).length === 0;
}

function hasValidPublicProfileShape(data) {
  return publicProfileShapeIssues(data).length === 0;
}

function privateProfileShapeIssues(data) {
  const issues = [];
  if (!isPlainObject(data)) return ['users:not_map'];
  if (typeof data.displayName !== 'string') issues.push('users.displayName:not_string');
  if (!isTimestampLike(data.birthDate)) issues.push('users.birthDate:not_timestamp');
  if (typeof data.gender !== 'string') issues.push('users.gender:not_string');
  if (typeof data.bio !== 'string') issues.push('users.bio:not_string');
  if (!Array.isArray(data.photoUrls)) issues.push('users.photoUrls:not_array');
  if (!isTimestampLike(data.createdAt)) issues.push('users.createdAt:not_timestamp');
  if (!isTimestampLike(data.updatedAt)) issues.push('users.updatedAt:not_timestamp');
  if (!hasValidVerificationMap(data.verifications)) {
    issues.push('users.verifications:invalid_shape');
  }
  if (!isPlainObject(data.discoveryFilter)) issues.push('users.discoveryFilter:not_map');
  return issues;
}

function publicProfileShapeIssues(data) {
  const issues = [];
  if (!isPlainObject(data)) return ['publicProfiles:not_map'];
  if (typeof data.displayName !== 'string') {
    issues.push('publicProfiles.displayName:not_string');
  }
  if (!Number.isInteger(Number(data.age))) {
    issues.push('publicProfiles.age:not_integer');
  } else if (Number(data.age) < 0 || Number(data.age) > 130) {
    issues.push('publicProfiles.age:out_of_range');
  }
  if (typeof data.gender !== 'string') issues.push('publicProfiles.gender:not_string');
  if (typeof data.bio !== 'string') issues.push('publicProfiles.bio:not_string');
  if (!Array.isArray(data.photoUrls)) issues.push('publicProfiles.photoUrls:not_array');
  if (data.verifications !== undefined && !hasValidVerificationMap(data.verifications)) {
    issues.push('publicProfiles.verifications:invalid_shape');
  }
  if (data.schemaVersion !== undefined && Number(data.schemaVersion) !== 1) {
    issues.push('publicProfiles.schemaVersion:unsupported');
  }
  return issues;
}

function hasCompletedProfile(usersData, publicData) {
  const usersComplete = hasValidPrivateProfileShape(usersData) &&
    usersData.displayName.trim().length > 0 &&
    usersData.photoUrls.length > 0;
  const publicComplete = hasValidPublicProfileShape(publicData) &&
    publicData.displayName.trim().length > 0 &&
    publicData.photoUrls.length > 0;
  return usersComplete && publicComplete;
}

function readJellyBalance(usersData) {
  const value = usersData?.jelly;
  if (!Number.isInteger(value)) return 0;
  return value;
}

function hasBlockingReferences(references) {
  return Boolean(
    references?.hasMatchReference ||
      references?.hasChatOrMessageReference ||
      references?.hasLikeReference ||
      references?.hasBlockReference ||
      references?.hasReportReference ||
      references?.hasPurchaseReference ||
      references?.hasJellyTransactionReference,
  );
}

function classifyCategory({ authRecord, usersData, publicData, readError }) {
  const hasAuth = Boolean(authRecord);
  const hasUsers = Boolean(usersData);
  const hasPublic = Boolean(publicData);

  if (readError) return ACCOUNT_CATEGORY.PROFILE_SHAPE_INVALID;
  if (hasAuth && !hasUsers && !hasPublic) return ACCOUNT_CATEGORY.AUTH_ONLY;
  if (hasAuth && hasUsers && !hasPublic) return ACCOUNT_CATEGORY.AUTH_WITH_PRIVATE_ONLY;
  if (hasAuth && !hasUsers && hasPublic) return ACCOUNT_CATEGORY.AUTH_WITH_PUBLIC_ONLY;
  if (!hasAuth && (hasUsers || hasPublic)) return ACCOUNT_CATEGORY.FIRESTORE_ONLY;
  if (hasAuth && hasUsers && hasPublic) {
    return hasValidPrivateProfileShape(usersData) && hasValidPublicProfileShape(publicData)
      ? ACCOUNT_CATEGORY.HEALTHY
      : ACCOUNT_CATEGORY.PROFILE_SHAPE_INVALID;
  }
  return ACCOUNT_CATEGORY.PROFILE_SHAPE_INVALID;
}

function classifyAccount({
  uid,
  authRecord,
  usersData,
  publicData,
  references = {},
  storageObjectCount = 0,
  nowMs = Date.now(),
  readError = null,
}) {
  const category = classifyCategory({ authRecord, usersData, publicData, readError });
  const hasAuth = Boolean(authRecord);
  const hasUsers = Boolean(usersData);
  const hasPublic = Boolean(publicData);
  const jellyBalance = readJellyBalance(usersData);
  const profileComplete = hasCompletedProfile(usersData, publicData);
  const knownTestAccount = KNOWN_TEST_ACCOUNT_PATTERN.test(String(uid));
  const createdMs = authCreatedMillis(authRecord);
  const lastSignInMs = authLastSignInMillis(authRecord);
  const hasStorage = Number(storageObjectCount) > 0;
  const hasNonZeroJelly = jellyBalance !== 0;
  const blockers = [];

  if (readError || references.hasReadError) blockers.push('READ_ERROR');
  if (references.hasMatchReference) blockers.push('MATCH_REFERENCE');
  if (references.hasChatOrMessageReference) blockers.push('CHAT_OR_MESSAGE_REFERENCE');
  if (references.hasLikeReference) blockers.push('LIKE_REFERENCE');
  if (references.hasBlockReference) blockers.push('BLOCK_REFERENCE');
  if (references.hasReportReference) blockers.push('REPORT_REFERENCE');
  if (hasNonZeroJelly) blockers.push('NON_ZERO_JELLY_BALANCE');
  if (references.hasPurchaseReference) blockers.push('PURCHASE_REFERENCE');
  if (references.hasJellyTransactionReference) blockers.push('JELLY_TRANSACTION_REFERENCE');
  if (hasStorage) blockers.push('STORAGE_OBJECTS');
  if (references.isRecent === true) blockers.push('RECENT_ACCOUNT');

  let recommendation;
  if (category === ACCOUNT_CATEGORY.HEALTHY) {
    recommendation = CLEANUP_RECOMMENDATION.RETAIN;
  } else if (
    readError ||
    references.hasReadError ||
    hasBlockingReferences(references) ||
    hasNonZeroJelly ||
    hasStorage
  ) {
    recommendation = CLEANUP_RECOMMENDATION.MANUAL_REVIEW_REQUIRED;
  } else if (category === ACCOUNT_CATEGORY.FIRESTORE_ONLY && knownTestAccount) {
    recommendation = CLEANUP_RECOMMENDATION.SAFE_DELETE_CANDIDATE;
  } else if (
    category === ACCOUNT_CATEGORY.AUTH_WITH_PRIVATE_ONLY ||
    category === ACCOUNT_CATEGORY.AUTH_WITH_PUBLIC_ONLY ||
    category === ACCOUNT_CATEGORY.PROFILE_SHAPE_INVALID
  ) {
    recommendation = CLEANUP_RECOMMENDATION.REPAIR;
  } else if (category === ACCOUNT_CATEGORY.AUTH_ONLY) {
    recommendation = CLEANUP_RECOMMENDATION.DISABLE_THEN_REVIEW;
  } else {
    recommendation = CLEANUP_RECOMMENDATION.MANUAL_REVIEW_REQUIRED;
  }

  if (blockers.includes('RECENT_ACCOUNT') && recommendation === CLEANUP_RECOMMENDATION.SAFE_DELETE_CANDIDATE) {
    recommendation = CLEANUP_RECOMMENDATION.MANUAL_REVIEW_REQUIRED;
  }

  return {
    uidHash: safeUidHash(uid),
    category,
    recommendation,
    shapeIssues: [
      ...(usersData ? privateProfileShapeIssues(usersData) : []),
      ...(publicData ? publicProfileShapeIssues(publicData) : []),
    ].sort(),
    knownTestAccount,
    authDisabled: authRecord?.disabled === true,
    emailVerified: authRecord?.emailVerified === true,
    hasPhone: typeof authRecord?.phoneNumber === 'string' &&
      authRecord.phoneNumber.trim().length > 0,
    hasUsers,
    hasPublic,
    profileComplete,
    createdAgeBucket: ageBucketFromMillis(createdMs, nowMs),
    lastSignInAgeBucket: ageBucketFromMillis(lastSignInMs, nowMs),
    storageObjectCount: Number.isInteger(storageObjectCount) ? storageObjectCount : 0,
    hasMatchReference: references.hasMatchReference === true,
    hasChatOrMessageReference: references.hasChatOrMessageReference === true,
    hasLikeReference: references.hasLikeReference === true,
    hasBlockReference: references.hasBlockReference === true,
    hasReportReference: references.hasReportReference === true,
    hasJellyBalance: hasNonZeroJelly,
    hasPurchaseReference: references.hasPurchaseReference === true,
    hasJellyTransactionReference: references.hasJellyTransactionReference === true,
    blockers: blockers.sort(),
  };
}

function summarizeClassifications(entries) {
  const byCategory = {};
  const byRecommendation = {};
  for (const value of Object.values(ACCOUNT_CATEGORY)) byCategory[value] = 0;
  for (const value of Object.values(CLEANUP_RECOMMENDATION)) byRecommendation[value] = 0;
  let candidatesWithReferences = 0;

  for (const entry of entries) {
    byCategory[entry.category] = (byCategory[entry.category] || 0) + 1;
    byRecommendation[entry.recommendation] =
      (byRecommendation[entry.recommendation] || 0) + 1;
    if (
      entry.category !== ACCOUNT_CATEGORY.HEALTHY &&
      (
        entry.hasMatchReference ||
        entry.hasChatOrMessageReference ||
        entry.hasLikeReference ||
        entry.hasBlockReference ||
        entry.hasReportReference ||
        entry.hasPurchaseReference ||
        entry.hasJellyTransactionReference
      )
    ) {
      candidatesWithReferences += 1;
    }
  }
  return {
    totalAccounts: entries.length,
    byCategory,
    byRecommendation,
    candidatesWithReferences,
    safeDeleteCandidates: byRecommendation[CLEANUP_RECOMMENDATION.SAFE_DELETE_CANDIDATE],
    repairCandidates: byRecommendation[CLEANUP_RECOMMENDATION.REPAIR],
    manualReviewRequired: byRecommendation[CLEANUP_RECOMMENDATION.MANUAL_REVIEW_REQUIRED],
  };
}

function assertManifestAllowed({ manifest, currentEntries }) {
  if (!manifest || !Array.isArray(manifest.uidHashes) || manifest.uidHashes.length === 0) {
    throw Object.assign(new Error('Cleanup manifest with uidHashes is required.'), {
      code: 'MANIFEST_REQUIRED',
    });
  }
  const byHash = new Map(currentEntries.map((entry) => [entry.uidHash, entry]));
  for (const uidHash of manifest.uidHashes) {
    const entry = byHash.get(uidHash);
    if (!entry) {
      throw Object.assign(new Error('Manifest contains unknown uidHash.'), {
        code: 'MANIFEST_UNKNOWN_UID_HASH',
      });
    }
    if (entry.category === ACCOUNT_CATEGORY.HEALTHY) {
      throw Object.assign(new Error('Manifest contains a healthy account.'), {
        code: 'MANIFEST_CONTAINS_HEALTHY_ACCOUNT',
      });
    }
    if (entry.recommendation !== CLEANUP_RECOMMENDATION.SAFE_DELETE_CANDIDATE) {
      throw Object.assign(new Error('Manifest contains a non-safe candidate.'), {
        code: 'MANIFEST_CONTAINS_UNSAFE_ACCOUNT',
      });
    }
  }
}

function planCleanup({
  dryRun = true,
  execute = false,
  confirmExecute = false,
  manifest = null,
  currentEntries = [],
}) {
  if (!execute) {
    return {
      mode: 'dry-run',
      writesAttempted: 0,
      deletesAttempted: 0,
      authMutations: 0,
      firestoreMutations: 0,
      storageMutations: 0,
      plannedUidHashes: currentEntries
        .filter((entry) => entry.recommendation === CLEANUP_RECOMMENDATION.SAFE_DELETE_CANDIDATE)
        .map((entry) => entry.uidHash)
        .sort(),
    };
  }

  void dryRun;
  void confirmExecute;
  void manifest;
  void currentEntries;
  throw Object.assign(new Error('Orphan cleanup execution is not implemented in this phase.'), {
    code: CLEANUP_ERROR.EXECUTION_NOT_IMPLEMENTED,
  });
}

function assertNoSensitiveOutput(text, rawValues) {
  for (const value of rawValues) {
    if (value && String(value).length > 0 && text.includes(String(value))) {
      throw Object.assign(new Error('Sensitive value leaked in output.'), {
        code: 'SENSITIVE_OUTPUT_LEAK',
      });
    }
  }
}

module.exports = {
  ACCOUNT_CATEGORY,
  CLEANUP_RECOMMENDATION,
  CLEANUP_ERROR,
  KNOWN_TEST_ACCOUNT_PATTERN,
  ageBucketFromMillis,
  safeUidHash,
  hasValidPrivateProfileShape,
  hasValidPublicProfileShape,
  privateProfileShapeIssues,
  publicProfileShapeIssues,
  classifyAccount,
  summarizeClassifications,
  assertManifestAllowed,
  planCleanup,
  assertNoSensitiveOutput,
};
