'use strict';

const DELETE_ACTION = Object.freeze({
  HARD_DELETE: 'HARD_DELETE',
  REMOVE_RELATION: 'REMOVE_RELATION',
  ANONYMIZE: 'ANONYMIZE',
  RETAIN_SERVER_ONLY: 'RETAIN_SERVER_ONLY',
  MANUAL_POLICY_REQUIRED: 'MANUAL_POLICY_REQUIRED',
});

const DELETION_JOB_STAGE = Object.freeze({
  REQUESTED: 'REQUESTED',
  INVENTORIED: 'INVENTORIED',
  RELATIONS_CLEANED: 'RELATIONS_CLEANED',
  STORAGE_CLEANED: 'STORAGE_CLEANED',
  PROFILE_CLEANED: 'PROFILE_CLEANED',
  AUTH_DELETED: 'AUTH_DELETED',
  COMPLETED: 'COMPLETED',
  FAILED_RETRYABLE: 'FAILED_RETRYABLE',
  MANUAL_REVIEW_REQUIRED: 'MANUAL_REVIEW_REQUIRED',
});

const SHARED_DATA_POLICY = Object.freeze({
  ANONYMIZE_DELETED_PARTICIPANT: 'ANONYMIZE_DELETED_PARTICIPANT',
});

const DELETE_MY_ACCOUNT_CONTRACT = Object.freeze({
  functionName: 'deleteMyAccount',
  authRequired: true,
  targetUidSource: 'request.auth.uid',
  acceptsTargetUidFromClient: false,
  explicitUserConfirmationRequired: true,
  recentReauthenticationRequired: true,
  authTimeVerifiedServerSide: true,
  idempotentByUid: true,
  adminDeletesUseSeparateTooling: true,
  appCheckEnforcementRequiredForThisPhase: false,
  logRawUidOrPii: false,
});

const EXECUTION_SEQUENCE = Object.freeze([
  'VERIFY_RECENT_AUTH',
  'CHECK_DELETION_JOB_IDEMPOTENCY',
  'REVERIFY_INVENTORY',
  'MARK_DELETION_IN_PROGRESS',
  'DELETE_STORAGE_USER_FILES',
  'DELETE_USER_OWNED_SUBCOLLECTIONS',
  'REMOVE_LIKES_SWIPES_BLOCKS_RELATIONS',
  'APPLY_SHARED_MATCH_CHAT_POLICY',
  'RETAIN_OR_ANONYMIZE_REPORTS_AND_PURCHASES',
  'DELETE_USERS_AND_PUBLIC_PROFILES',
  'DELETE_AUTH_USER_LAST',
  'WRITE_DELETION_TOMBSTONE',
  'RETRY_PARTIAL_FAILURES',
]);

const RESOURCE_CONTRACTS = Object.freeze({
  authUser: Object.freeze({
    path: 'Auth user',
    uidStorage: 'Auth record uid',
    ownership: 'user-owned identity',
    shared: false,
    subcollections: false,
    rulesAccess: 'Firebase Auth only',
    cascade: false,
    withdrawalAction: 'AUTH_DELETE_LAST',
  }),
  users: Object.freeze({
    path: 'users/{uid}',
    uidStorage: 'document id',
    ownership: 'user-owned private profile',
    shared: false,
    subcollections: true,
    rulesAccess: 'owner read/create/update; client delete denied',
    cascade: false,
    withdrawalAction: DELETE_ACTION.HARD_DELETE,
  }),
  publicProfiles: Object.freeze({
    path: 'publicProfiles/{uid}',
    uidStorage: 'document id',
    ownership: 'user-owned public profile',
    shared: false,
    subcollections: false,
    rulesAccess: 'authenticated read; owner create/update; client delete denied',
    cascade: false,
    withdrawalAction: DELETE_ACTION.HARD_DELETE,
  }),
  dailyFortune: Object.freeze({
    path: 'users/{uid}/dailyFortune/{date}',
    uidStorage: 'ancestor document id',
    ownership: 'user-owned AI cache',
    shared: false,
    subcollections: false,
    rulesAccess: 'owner read; client write denied',
    cascade: false,
    withdrawalAction: DELETE_ACTION.HARD_DELETE,
  }),
  swipesAuthored: Object.freeze({
    path: 'users/{uid}/swipes/{targetUid}',
    uidStorage: 'ancestor id plus actorUid/targetUid fields',
    ownership: 'relationship edge',
    shared: true,
    subcollections: false,
    rulesAccess: 'owner read/write; collectionGroup target read',
    cascade: false,
    withdrawalAction: DELETE_ACTION.REMOVE_RELATION,
  }),
  swipesTargetingUser: Object.freeze({
    path: 'users/{actorUid}/swipes/{uid}',
    uidStorage: 'document id plus targetUid field',
    ownership: 'relationship edge owned by another user',
    shared: true,
    subcollections: false,
    rulesAccess: 'actor owner write; target collectionGroup read',
    cascade: false,
    withdrawalAction: DELETE_ACTION.REMOVE_RELATION,
  }),
  blocksAuthored: Object.freeze({
    path: 'users/{uid}/blocks/{blockedUid}',
    uidStorage: 'ancestor id plus blockerUid/blockedUid fields',
    ownership: 'safety relationship edge',
    shared: true,
    subcollections: false,
    rulesAccess: 'owner read/write/delete; collectionGroup blocked read',
    cascade: false,
    withdrawalAction: DELETE_ACTION.REMOVE_RELATION,
  }),
  blocksTargetingUser: Object.freeze({
    path: 'users/{blockerUid}/blocks/{uid}',
    uidStorage: 'document id plus blockedUid field',
    ownership: 'safety relationship edge owned by another user',
    shared: true,
    subcollections: false,
    rulesAccess: 'blocker owner write; blocked collectionGroup read',
    cascade: false,
    withdrawalAction: DELETE_ACTION.REMOVE_RELATION,
  }),
  jellyTransactions: Object.freeze({
    path: 'users/{uid}/jellyTransactions/{txId}',
    uidStorage: 'ancestor document id',
    ownership: 'payment and balance audit trail',
    shared: false,
    subcollections: false,
    rulesAccess: 'owner read; client charge/update/delete denied',
    cascade: false,
    withdrawalAction: DELETE_ACTION.RETAIN_SERVER_ONLY,
  }),
  storageUserFiles: Object.freeze({
    path: 'Storage users/{uid}/**',
    uidStorage: 'object path segment',
    ownership: 'user-owned files',
    shared: false,
    subcollections: false,
    rulesAccess: 'authenticated read; owner write',
    cascade: false,
    withdrawalAction: DELETE_ACTION.HARD_DELETE,
  }),
  matches: Object.freeze({
    path: 'matches/{matchId}',
    uidStorage: 'participants array, uid1, uid2, status/read arrays/maps',
    ownership: 'shared match/chat container',
    shared: true,
    subcollections: true,
    rulesAccess: 'participants read; limited participant updates',
    cascade: false,
    withdrawalAction: DELETE_ACTION.MANUAL_POLICY_REQUIRED,
  }),
  matchMessages: Object.freeze({
    path: 'matches/{matchId}/messages/{messageId}',
    uidStorage: 'senderId field',
    ownership: 'shared chat content',
    shared: true,
    subcollections: false,
    rulesAccess: 'match participants read/create; update/delete denied',
    cascade: false,
    withdrawalAction: DELETE_ACTION.MANUAL_POLICY_REQUIRED,
  }),
  reportsAuthored: Object.freeze({
    path: 'reports/{reportId}',
    uidStorage: 'reporterUid field',
    ownership: 'safety and moderation record',
    shared: false,
    subcollections: false,
    rulesAccess: 'client create only; read/update/delete denied',
    cascade: false,
    withdrawalAction: DELETE_ACTION.RETAIN_SERVER_ONLY,
  }),
  reportsTargetingUser: Object.freeze({
    path: 'reports/{reportId}',
    uidStorage: 'reportedUid field',
    ownership: 'safety and moderation record',
    shared: false,
    subcollections: false,
    rulesAccess: 'client create only; read/update/delete denied',
    cascade: false,
    withdrawalAction: DELETE_ACTION.RETAIN_SERVER_ONLY,
  }),
  purchaseReceipts: Object.freeze({
    path: '_purchaseReceipts/{receiptHash}',
    uidStorage: 'uid field; document id is receipt hash',
    ownership: 'server-only purchase audit',
    shared: false,
    subcollections: false,
    rulesAccess: 'not matched by client rules; Admin SDK only',
    cascade: false,
    withdrawalAction: DELETE_ACTION.RETAIN_SERVER_ONLY,
  }),
  purchaseVerificationUsage: Object.freeze({
    path: '_purchaseVerificationUsage/{uid}',
    uidStorage: 'document id',
    ownership: 'server-only abuse control state',
    shared: false,
    subcollections: false,
    rulesAccess: 'not matched by client rules; Admin SDK only',
    cascade: false,
    withdrawalAction: DELETE_ACTION.HARD_DELETE,
  }),
  internalAiUsage: Object.freeze({
    path: '_internalAiUsage/{uid}/functions/{functionName}',
    uidStorage: 'document id',
    ownership: 'server-only AI usage state',
    shared: false,
    subcollections: true,
    rulesAccess: 'not matched by client rules; Admin SDK only',
    cascade: false,
    withdrawalAction: DELETE_ACTION.HARD_DELETE,
  }),
  internalAiLeases: Object.freeze({
    path: '_internalAiLeases/{leaseId}',
    uidStorage: 'hashed lease id derived from caller uid/target uid/input hash',
    ownership: 'server-only AI lease state',
    shared: false,
    subcollections: false,
    rulesAccess: 'not matched by client rules; Admin SDK only',
    cascade: false,
    withdrawalAction: DELETE_ACTION.HARD_DELETE,
  }),
});

const SENSITIVE_KEYS = new Set([
  'uid',
  'rawUid',
  'targetUid',
  'actorUid',
  'blockerUid',
  'blockedUid',
  'reporterUid',
  'reportedUid',
  'senderId',
  'uid1',
  'uid2',
  'email',
  'phone',
  'phoneNumber',
  'displayName',
  'name',
  'birthDate',
  'photoUrl',
  'photoUrls',
  'fcmToken',
  'fcmTokens',
]);

function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function clonePlain(value) {
  return JSON.parse(JSON.stringify(value));
}

function hasSensitiveKey(value) {
  if (Array.isArray(value)) return value.some((item) => hasSensitiveKey(item));
  if (!isPlainObject(value)) return false;
  return Object.entries(value).some(([key, child]) => {
    return SENSITIVE_KEYS.has(key) || hasSensitiveKey(child);
  });
}

function isUidHash(value) {
  return typeof value === 'string' && /^[a-f0-9]{8,64}$/.test(value);
}

function readCount(value) {
  if (value == null || value === false) return { ok: true, count: 0 };
  if (value === true) return { ok: true, count: 1 };
  if (Number.isInteger(value) && value >= 0) return { ok: true, count: value };
  if (!isPlainObject(value)) return { ok: false, count: 0 };
  if ('count' in value) {
    return Number.isInteger(value.count) && value.count >= 0
      ? { ok: true, count: value.count }
      : { ok: false, count: 0 };
  }
  if ('exists' in value) {
    return typeof value.exists === 'boolean'
      ? { ok: true, count: value.exists ? 1 : 0 }
      : { ok: false, count: 0 };
  }
  return { ok: true, count: 0 };
}

function makeEntry({ action, resource, reason, uidHash, count, path, details }) {
  const entry = {
    action,
    resource,
    path: path || RESOURCE_CONTRACTS[resource]?.path || resource,
    reason,
    uidHash,
  };
  if (count != null) entry.count = count;
  if (details != null) entry.details = clonePlain(details);
  return entry;
}

function emptyPlan(uidHash = null) {
  return {
    canProceed: false,
    uidHash,
    blockers: [],
    hardDelete: [],
    removeRelations: [],
    anonymize: [],
    retainServerOnly: [],
    manualPolicyRequired: [],
    authDeleteLast: true,
    deletionJobStages: Object.values(DELETION_JOB_STAGE),
    executionSequence: [...EXECUTION_SEQUENCE],
  };
}

function addManual(plan, resource, reason, uidHash, count, details) {
  plan.manualPolicyRequired.push(
    makeEntry({
      action: DELETE_ACTION.MANUAL_POLICY_REQUIRED,
      resource,
      reason,
      uidHash,
      count,
      details,
    }),
  );
}

function addRetainAndAnonymize(plan, resource, reason, uidHash, count) {
  plan.retainServerOnly.push(
    makeEntry({
      action: DELETE_ACTION.RETAIN_SERVER_ONLY,
      resource,
      reason,
      uidHash,
      count,
    }),
  );
  plan.anonymize.push(
    makeEntry({
      action: DELETE_ACTION.ANONYMIZE,
      resource,
      reason: `${reason}: replace direct uid reference with deletion subject hash`,
      uidHash,
      count,
      details: { replacementField: 'deletionSubjectHash' },
    }),
  );
}

function planSharedMatchData({ plan, uidHash, matchCount, messageCount, policy }) {
  if (matchCount === 0 && messageCount === 0) return;

  if (policy !== SHARED_DATA_POLICY.ANONYMIZE_DELETED_PARTICIPANT) {
    addManual(plan, 'matches', 'shared match/chat policy is not finalized', uidHash, matchCount);
    if (messageCount > 0) {
      addManual(
        plan,
        'matchMessages',
        'shared messages must not be hard-deleted without a product/legal policy',
        uidHash,
        messageCount,
      );
    }
    return;
  }

  if (matchCount > 0) {
    plan.anonymize.push(
      makeEntry({
        action: DELETE_ACTION.ANONYMIZE,
        resource: 'matches',
        reason: 'mark deleted participant while preserving the other participant data',
        uidHash,
        count: matchCount,
        details: {
          fields: [
            'participants',
            'uid1',
            'uid2',
            'unmatchedBy',
            'celebratedBy',
            'lastReadAtByUid',
            'lastMessage.senderId',
          ],
        },
      }),
    );
  }
  if (messageCount > 0) {
    plan.anonymize.push(
      makeEntry({
        action: DELETE_ACTION.ANONYMIZE,
        resource: 'matchMessages',
        reason: 'replace deleted author senderId while preserving message order/content for the remaining participant',
        uidHash,
        count: messageCount,
        details: { fields: ['senderId'] },
      }),
    );
  }
}

function planAccountDeletion(inventory) {
  const plan = emptyPlan();
  if (!isPlainObject(inventory)) {
    plan.blockers.push({ code: 'MALFORMED_INVENTORY' });
    return plan;
  }
  if (!isUidHash(inventory.uidHash)) {
    plan.blockers.push({ code: 'UID_HASH_REQUIRED' });
    return plan;
  }
  if (hasSensitiveKey(inventory)) {
    plan.uidHash = inventory.uidHash;
    plan.blockers.push({ code: 'RAW_UID_OR_PII_PRESENT', uidHash: inventory.uidHash });
    return plan;
  }

  const uidHash = inventory.uidHash;
  plan.uidHash = uidHash;
  const resources = isPlainObject(inventory.resources) ? inventory.resources : null;
  if (!resources) {
    plan.blockers.push({ code: 'MALFORMED_INVENTORY', uidHash });
    return plan;
  }

  const unknownResources = Object.keys(resources).filter(
    (resource) => !Object.prototype.hasOwnProperty.call(RESOURCE_CONTRACTS, resource),
  );
  if (unknownResources.length > 0) {
    plan.blockers.push({
      code: 'UNKNOWN_COLLECTION',
      uidHash,
      resources: unknownResources.sort(),
    });
    return plan;
  }

  const counts = {};
  for (const [resource, value] of Object.entries(resources)) {
    const result = readCount(value);
    if (!result.ok) {
      plan.blockers.push({ code: 'MALFORMED_RESOURCE_COUNT', uidHash, resource });
      return plan;
    }
    counts[resource] = result.count;
  }

  function count(resource) {
    return counts[resource] || 0;
  }

  for (const resource of ['users', 'publicProfiles', 'dailyFortune', 'storageUserFiles']) {
    const resourceCount = count(resource);
    if (resourceCount > 0) {
      plan.hardDelete.push(
        makeEntry({
          action: DELETE_ACTION.HARD_DELETE,
          resource,
          reason: 'user-owned private/public data',
          uidHash,
          count: resourceCount,
        }),
      );
    }
  }

  for (const resource of [
    'swipesAuthored',
    'swipesTargetingUser',
    'blocksAuthored',
    'blocksTargetingUser',
  ]) {
    const resourceCount = count(resource);
    if (resourceCount > 0) {
      plan.removeRelations.push(
        makeEntry({
          action: DELETE_ACTION.REMOVE_RELATION,
          resource,
          reason: 'remove only the withdrawing user relationship edge',
          uidHash,
          count: resourceCount,
        }),
      );
    }
  }

  for (const resource of [
    'purchaseVerificationUsage',
    'internalAiUsage',
    'internalAiLeases',
  ]) {
    const resourceCount = count(resource);
    if (resourceCount > 0) {
      plan.hardDelete.push(
        makeEntry({
          action: DELETE_ACTION.HARD_DELETE,
          resource,
          reason: 'server-side per-user usage state',
          uidHash,
          count: resourceCount,
        }),
      );
    }
  }

  const jellyCount = count('jellyTransactions');
  if (jellyCount > 0) {
    addRetainAndAnonymize(plan, 'jellyTransactions', 'jelly balance audit trail', uidHash, jellyCount);
  }

  const purchaseCount = count('purchaseReceipts');
  if (purchaseCount > 0) {
    addRetainAndAnonymize(plan, 'purchaseReceipts', 'purchase receipt and anti-duplicate audit', uidHash, purchaseCount);
  }

  const reportAuthoredCount = count('reportsAuthored');
  if (reportAuthoredCount > 0) {
    addRetainAndAnonymize(plan, 'reportsAuthored', 'moderation report authored by deleted account', uidHash, reportAuthoredCount);
  }

  const reportTargetCount = count('reportsTargetingUser');
  if (reportTargetCount > 0) {
    addRetainAndAnonymize(plan, 'reportsTargetingUser', 'moderation report targeting deleted account', uidHash, reportTargetCount);
  }

  planSharedMatchData({
    plan,
    uidHash,
    matchCount: count('matches'),
    messageCount: count('matchMessages'),
    policy: inventory.sharedDataPolicy,
  });

  if (count('authUser') > 0) {
    plan.authDelete = makeEntry({
      action: 'AUTH_DELETE_LAST',
      resource: 'authUser',
      reason: 'Auth account must be removed only after Firestore and Storage cleanup succeeds',
      uidHash,
      count: count('authUser'),
      path: RESOURCE_CONTRACTS.authUser.path,
    });
  }

  plan.canProceed = plan.blockers.length === 0 && plan.manualPolicyRequired.length === 0;
  return plan;
}

module.exports = {
  DELETE_ACTION,
  DELETION_JOB_STAGE,
  DELETE_MY_ACCOUNT_CONTRACT,
  EXECUTION_SEQUENCE,
  RESOURCE_CONTRACTS,
  SHARED_DATA_POLICY,
  planAccountDeletion,
};
