'use strict';

const crypto = require('crypto');

const {
  SHARED_DATA_POLICY,
  planAccountDeletion,
} = require('./account_deletion_plan');

const FUNCTION_NAME = 'deleteMyAccount';
const CONFIRMATION_TEXT = 'DELETE_MY_ACCOUNT';
const USER_ERROR_MESSAGE =
  '계정 삭제를 완료하지 못했습니다. 잠시 후 다시 시도해 주세요.';
const RECENT_AUTH_MAX_AGE_SECONDS = 300;
const DEFAULT_LEASE_TTL_MS = 5 * 60 * 1000;

const JOB_STATUS = Object.freeze({
  REQUESTED: 'REQUESTED',
  INVENTORIED: 'INVENTORIED',
  STORAGE_CLEANED: 'STORAGE_CLEANED',
  RELATIONS_CLEANED: 'RELATIONS_CLEANED',
  SHARED_DATA_ANONYMIZED: 'SHARED_DATA_ANONYMIZED',
  PROFILE_CLEANED: 'PROFILE_CLEANED',
  AUTH_DELETE_PENDING: 'AUTH_DELETE_PENDING',
  AUTH_DELETED: 'AUTH_DELETED',
  COMPLETED: 'COMPLETED',
  FAILED_RETRYABLE: 'FAILED_RETRYABLE',
  MANUAL_REVIEW_REQUIRED: 'MANUAL_REVIEW_REQUIRED',
});

class AccountDeletionError extends Error {
  constructor(code, category, retryable = false) {
    super(code);
    this.name = 'AccountDeletionError';
    this.code = code;
    this.category = category;
    this.retryable = retryable === true;
  }
}

function toHttpsError(error, HttpsError) {
  if (error instanceof AccountDeletionError) {
    return new HttpsError(error.code, USER_ERROR_MESSAGE);
  }
  return new HttpsError('internal', USER_ERROR_MESSAGE);
}

function sha256Hex(value) {
  return crypto.createHash('sha256').update(String(value)).digest('hex');
}

function uidHashFor(uid) {
  return sha256Hex(uid);
}

function shortHash(value) {
  return sha256Hex(value).slice(0, 8);
}

function deletedIdentifierForUid(uid) {
  return `deleted:${uidHashFor(uid).slice(0, 24)}`;
}

function fail(code, category, retryable = false) {
  throw new AccountDeletionError(code, category, retryable);
}

function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function safeLog(logger, step, meta = {}) {
  if (!logger || typeof logger.log !== 'function') return;
  logger.log({
    functionName: FUNCTION_NAME,
    step,
    ...meta,
  });
}

function parseAndValidateRequest({ request, nowMs = Date.now }) {
  if (!request || !request.auth || typeof request.auth.uid !== 'string') {
    fail('unauthenticated', 'missing_auth', false);
  }
  const data = request.data;
  if (!isPlainObject(data)) {
    fail('invalid-argument', 'payload_malformed', false);
  }
  const keys = Object.keys(data);
  if (keys.length !== 1 || keys[0] !== 'confirmation') {
    fail('invalid-argument', 'payload_keys_forbidden', false);
  }
  if (data.confirmation !== CONFIRMATION_TEXT) {
    fail('invalid-argument', 'confirmation_mismatch', false);
  }
  const authTime = request.auth.token?.auth_time;
  if (!Number.isFinite(authTime) || authTime <= 0) {
    fail('failed-precondition', 'auth_time_missing_or_malformed', false);
  }
  const nowSeconds = Math.floor(nowMs() / 1000);
  if (authTime > nowSeconds) {
    fail('failed-precondition', 'auth_time_in_future', false);
  }
  if (nowSeconds - authTime > RECENT_AUTH_MAX_AGE_SECONDS) {
    fail('failed-precondition', 'auth_time_stale', false);
  }
  return {
    uid: request.auth.uid,
    uidHash: uidHashFor(request.auth.uid),
    deletedIdentifier: deletedIdentifierForUid(request.auth.uid),
  };
}

function serverTime(serverTimestamp) {
  return typeof serverTimestamp === 'function' ? serverTimestamp() : new Date();
}

function deleteValue(fieldDelete) {
  return typeof fieldDelete === 'function' ? fieldDelete() : null;
}

function refPath(ref) {
  return String(ref?.path || '');
}

function assertPathUnder(ref, prefix) {
  const path = refPath(ref);
  if (!path.startsWith(prefix)) {
    fail('failed-precondition', 'unsafe_reference_path', false);
  }
}

function isNotFoundError(error) {
  const code = String(error?.code || '').toLowerCase();
  const message = String(error?.message || '').toLowerCase();
  return code === '5' ||
    code === '404' ||
    code === 'not-found' ||
    code === 'auth/user-not-found' ||
    message.includes('not found') ||
    message.includes('no such object');
}

async function markJob({ jobRef, status, serverTimestamp, fieldDelete, payload = {} }) {
  const update = {
    status,
    updatedAt: serverTime(serverTimestamp),
    ...payload,
  };
  if (status === JOB_STATUS.COMPLETED) {
    update.subjectUid = deleteValue(fieldDelete);
    update.leaseExpiresAtMs = 0;
    update.leaseOwner = deleteValue(fieldDelete);
  }
  await jobRef.set(update, { merge: true });
}

async function failJob({
  jobRef,
  status = JOB_STATUS.FAILED_RETRYABLE,
  step,
  category,
  retryable,
  serverTimestamp,
}) {
  await jobRef.set({
    status,
    failedStep: step,
    failureCategory: category,
    retryable: retryable === true,
    updatedAt: serverTime(serverTimestamp),
  }, { merge: true });
}

async function acquireJobLease({
  db,
  jobRef,
  uid,
  uidHash,
  nowMs,
  serverTimestamp,
  leaseTtlMs,
}) {
  const leaseOwner = crypto.randomUUID();
  return db.runTransaction(async (tx) => {
    const snap = await tx.get(jobRef);
    const data = snap.exists ? snap.data() || {} : {};
    if (data.status === JOB_STATUS.COMPLETED) {
      return { completed: true, leaseOwner: null };
    }
    const leaseExpiresAtMs = Number(data.leaseExpiresAtMs || 0);
    if (leaseExpiresAtMs > nowMs) {
      fail('failed-precondition', 'deletion_already_in_progress', false);
    }
    tx.set(jobRef, {
      uidHash,
      subjectUid: uid,
      status: data.status && data.status !== JOB_STATUS.FAILED_RETRYABLE
        ? data.status
        : JOB_STATUS.REQUESTED,
      leaseOwner,
      leaseExpiresAtMs: nowMs + leaseTtlMs,
      updatedAt: serverTime(serverTimestamp),
      createdAt: data.createdAt || serverTime(serverTimestamp),
    }, { merge: true });
    return { completed: false, leaseOwner };
  });
}

async function releaseJobLease({ jobRef, leaseOwner, fieldDelete }) {
  if (!leaseOwner) return;
  await jobRef.set({
    leaseExpiresAtMs: 0,
    leaseOwner: deleteValue(fieldDelete),
  }, { merge: true });
}

async function listAllStorageFiles(bucket, prefix, options = {}) {
  const files = [];
  let query = { prefix, autoPaginate: false };
  do {
    let pageFiles;
    let nextQuery;
    try {
      [pageFiles, nextQuery] = await bucket.getFiles(query);
    } catch (error) {
      if (options.failureCategory) {
        fail('internal', options.failureCategory, true);
      }
      throw error;
    }
    for (const file of pageFiles || []) {
      if (!String(file.name || '').startsWith(prefix)) {
        fail('failed-precondition', 'unsafe_storage_path', false);
      }
      files.push(file);
    }
    query = nextQuery || null;
  } while (query);
  return files;
}

async function inventoryRead(category, fn) {
  try {
    return await fn();
  } catch (error) {
    if (error instanceof AccountDeletionError) throw error;
    fail('internal', category, true);
  }
}

/**
 * 이 사용자의 파일이 존재할 수 있는 모든 Storage prefix.
 *
 * - users/{uid}/                    프로필 사진·AI 이상형 이미지
 * - photoVerification/{uid}/        사진 인증 셀피 (Phase 3-2)
 * - affiliationVerification/{uid}/  직장·학교 증빙 (Phase 3-3)
 *
 * 검토가 끝나면 보통 서버가 지우지만, 검토 전에 탈퇴하면 남으므로 여기서
 * 함께 정리한다. prefix 밖 경로가 나오면 listAllStorageFiles가 즉시 중단한다.
 */
function storagePrefixesForUid(uid) {
  return [
    `users/${uid}/`,
    `photoVerification/${uid}/`,
    `affiliationVerification/${uid}/`,
  ];
}

async function deleteStoragePrefix({ bucket, uid }) {
  let filesDeleted = 0;
  for (const prefix of storagePrefixesForUid(uid)) {
    // 파일이 하나도 없으면 빈 목록이 돌아온다(성공).
    const files = await listAllStorageFiles(bucket, prefix);
    for (const file of files) {
      try {
        await file.delete();
      } catch (error) {
        if (!isNotFoundError(error)) throw error;
      }
    }
    filesDeleted += files.length;
  }
  // prefix 문자열은 반환하지 않고 개수만 돌려준다.
  return { filesDeleted };
}

async function deleteRefs(refs, allowedPrefix = null) {
  let count = 0;
  for (const ref of refs) {
    if (allowedPrefix) assertPathUnder(ref, allowedPrefix);
    await ref.delete();
    count += 1;
  }
  return count;
}

async function snapshotRefs(queryOrCollection) {
  const snap = await queryOrCollection.get();
  return (snap.docs || []).map((doc) => doc.ref);
}

async function deleteRelations({ db, uid }) {
  const userPrefix = `users/${uid}/`;
  const userRef = db.collection('users').doc(uid);
  const outboundSwipeRefs = await snapshotRefs(userRef.collection('swipes'));
  const outboundBlockRefs = await snapshotRefs(userRef.collection('blocks'));
  const inboundSwipeRefs = await snapshotRefs(
    db.collectionGroup('swipes').where('targetUid', '==', uid),
  );
  const inboundBlockRefs = await snapshotRefs(
    db.collectionGroup('blocks').where('blockedUid', '==', uid),
  );

  const contactAvoidance = await deleteContactAvoidanceData({ db, uid });
  const verificationRequests = await deleteVerificationRequestDocs({ db, uid });

  return {
    outboundSwipesDeleted: await deleteRefs(outboundSwipeRefs, `${userPrefix}swipes/`),
    outboundBlocksDeleted: await deleteRefs(outboundBlockRefs, `${userPrefix}blocks/`),
    inboundSwipesDeleted: await deleteRefs(inboundSwipeRefs),
    inboundBlocksDeleted: await deleteRefs(inboundBlockRefs),
    ...contactAvoidance,
    ...verificationRequests,
  };
}

/** 문서가 이미 없어도 성공하는 삭제(멱등). */
async function deleteDocIfExists(ref) {
  try {
    await ref.delete();
    return true;
  } catch (error) {
    if (isNotFoundError(error)) return false;
    throw error;
  }
}

/**
 * 지인 피하기(Phase 3-4) 데이터 정리.
 *
 * - privatePhoneIdentifiers/{uid}: 전화번호 HMAC 식별자
 * - contactAvoidanceSyncLimits/{uid}: 재동기화 cooldown 기록
 * - users/{uid}/contactAvoidanceMatches/*: 내가 보유한 소유 관계(outbound)
 * - 상대가 나를 가리키는 소유 관계(inbound)
 * - 내가 참여한 pair 전부
 *
 * inbound 관계는 pair의 participants에서 상대를 뽑아 문서 경로로 직접 지운다.
 * 소유 관계가 생기면 pair도 함께 생기므로 이 경로로 빠짐없이 정리되고,
 * collectionGroup 인덱스를 새로 요구하지 않는다.
 *
 * 계정 삭제에서는 UID 자체가 사라지므로 reciprocal 여부와 무관하게 이 UID가
 * 포함된 pair를 모두 지운다. 다른 두 사용자만의 pair는 건드리지 않는다.
 */
async function deleteContactAvoidanceData({ db, uid }) {
  const userPrefix = `users/${uid}/`;
  const userRef = db.collection('users').doc(uid);

  const identifierDeleted = await deleteDocIfExists(
    db.collection('privatePhoneIdentifiers').doc(uid),
  );
  const syncLimitDeleted = await deleteDocIfExists(
    db.collection('contactAvoidanceSyncLimits').doc(uid),
  );

  const outboundRefs = await snapshotRefs(
    userRef.collection('contactAvoidanceMatches'),
  );
  const outboundDeleted = await deleteRefs(
    outboundRefs,
    `${userPrefix}contactAvoidanceMatches/`,
  );

  const pairSnap = await db
    .collection('contactAvoidancePairs')
    .where('participants', 'array-contains', uid)
    .get();

  let inboundDeleted = 0;
  const pairRefs = [];
  for (const doc of pairSnap.docs || []) {
    pairRefs.push(doc.ref);
    const participants = doc.data()?.participants;
    if (!Array.isArray(participants)) continue;
    for (const participant of participants) {
      if (typeof participant !== 'string' || !participant) continue;
      if (participant === uid) continue;
      const removed = await deleteDocIfExists(
        db
          .collection('users')
          .doc(participant)
          .collection('contactAvoidanceMatches')
          .doc(uid),
      );
      if (removed) inboundDeleted += 1;
    }
  }

  return {
    contactIdentifierDeleted: identifierDeleted,
    contactSyncLimitDeleted: syncLimitDeleted,
    contactOwnerRelationsDeleted: outboundDeleted,
    contactInboundRelationsDeleted: inboundDeleted,
    contactPairsDeleted: await deleteRefs(pairRefs),
  };
}

/**
 * 인증 요청 문서 정리.
 *
 * photoVerificationRequests/{uid}는 top-level이라 users recursive delete로
 * 지워지지 않는다. 소속 인증 요청은 users/{uid} 하위라 recursive delete로
 * 정리되지만, 증빙 이미지는 Storage 단계에서 함께 지운다.
 */
async function deleteVerificationRequestDocs({ db, uid }) {
  const photoRequestDeleted = await deleteDocIfExists(
    db.collection('photoVerificationRequests').doc(uid),
  );
  return { photoVerificationRequestDeleted: photoRequestDeleted };
}

function normalizeMatchData(data, uid, deletedIdentifier, uidHash) {
  if (!isPlainObject(data) ||
    !Array.isArray(data.participants) ||
    typeof data.uid1 !== 'string' ||
    typeof data.uid2 !== 'string' ||
    !data.participants.includes(uid)) {
    fail('failed-precondition', 'malformed_match_shape', false);
  }

  const participants = data.participants.map((participant) =>
    participant === uid ? deletedIdentifier : participant);
  const update = {
    participants,
    uid1: data.uid1 === uid ? deletedIdentifier : data.uid1,
    uid2: data.uid2 === uid ? deletedIdentifier : data.uid2,
    deletedParticipants: Array.from(new Set([
      ...(Array.isArray(data.deletedParticipants) ? data.deletedParticipants : []),
      deletedIdentifier,
    ])),
    deletionSubjectHashes: Array.from(new Set([
      ...(Array.isArray(data.deletionSubjectHashes) ? data.deletionSubjectHashes : []),
      uidHash,
    ])),
  };

  update.unmatchedBy = Array.from(new Set([
    ...(Array.isArray(data.unmatchedBy)
      ? data.unmatchedBy.map((value) =>
          value === uid ? deletedIdentifier : value)
      : []),
    deletedIdentifier,
  ]));
  if (Array.isArray(data.celebratedBy)) {
    update.celebratedBy = data.celebratedBy.filter((value) => value !== uid);
  }
  if (isPlainObject(data.lastReadAtByUid)) {
    update.lastReadAtByUid = { ...data.lastReadAtByUid };
    delete update.lastReadAtByUid[uid];
  }
  if (isPlainObject(data.lastMessage) && data.lastMessage.senderId === uid) {
    update.lastMessage = {
      ...data.lastMessage,
      senderId: deletedIdentifier,
    };
  }
  return update;
}

function anonymizedMessageUpdate({ data, uid, deletedIdentifier, fieldDelete }) {
  if (!isPlainObject(data) || data.senderId !== uid) {
    fail('failed-precondition', 'malformed_message_shape', false);
  }
  const update = {
    senderId: deletedIdentifier,
    senderDeleted: true,
  };
  for (const key of ['senderName', 'senderDisplayName', 'senderPhotoUrl', 'senderPhotoURL', 'senderAvatarUrl']) {
    if (Object.prototype.hasOwnProperty.call(data, key)) {
      update[key] = deleteValue(fieldDelete);
    }
  }
  return update;
}

async function anonymizeSharedData({ db, uid, uidHash, deletedIdentifier, fieldDelete }) {
  const matchesSnap = await db
    .collection('matches')
    .where('participants', 'array-contains', uid)
    .get();
  let matchesUpdated = 0;
  let messagesUpdated = 0;
  for (const matchDoc of matchesSnap.docs || []) {
    const matchUpdate = normalizeMatchData(
      matchDoc.data(),
      uid,
      deletedIdentifier,
      uidHash,
    );
    await matchDoc.ref.update(matchUpdate);
    matchesUpdated += 1;

    const messagesSnap = await matchDoc.ref
      .collection('messages')
      .where('senderId', '==', uid)
      .get();
    for (const messageDoc of messagesSnap.docs || []) {
      await messageDoc.ref.update(
        anonymizedMessageUpdate({
          data: messageDoc.data(),
          uid,
          deletedIdentifier,
          fieldDelete,
        }),
      );
      messagesUpdated += 1;
    }
  }
  return { matchesUpdated, messagesUpdated };
}

async function anonymizeReports({ db, uid, uidHash, deletedIdentifier, fieldDelete }) {
  const byId = new Map();
  for (const field of ['reporterUid', 'reportedUid']) {
    const snap = await db.collection('reports').where(field, '==', uid).get();
    for (const doc of snap.docs || []) byId.set(doc.ref.path, doc);
  }

  let reportsUpdated = 0;
  for (const doc of byId.values()) {
    const data = doc.data() || {};
    const update = {};
    if (data.reporterUid === uid) {
      update.reporterUid = deletedIdentifier;
      update.reporterDeleted = true;
    }
    if (data.reportedUid === uid) {
      update.reportedUid = deletedIdentifier;
      update.reportedDeleted = true;
    }
    for (const key of [
      'reporterName',
      'reporterDisplayName',
      'reporterPhotoUrl',
      'reporterPhotoURL',
      'reportedName',
      'reportedDisplayName',
      'reportedPhotoUrl',
      'reportedPhotoURL',
    ]) {
      if (Object.prototype.hasOwnProperty.call(data, key)) {
        update[key] = deleteValue(fieldDelete);
      }
    }
    if (Object.keys(update).length > 0) {
      update.deletedSubjectHash = uidHash;
      await doc.ref.update(update);
      reportsUpdated += 1;
    }
  }
  return { reportsUpdated };
}

async function anonymizePurchaseReceipts({ db, uid, uidHash, deletedIdentifier, fieldDelete }) {
  const snap = await db.collection('_purchaseReceipts').where('uid', '==', uid).get();
  let receiptsUpdated = 0;
  for (const doc of snap.docs || []) {
    await doc.ref.update({
      uid: deleteValue(fieldDelete),
      deletedSubjectHash: uidHash,
      deletedIdentifier,
      subjectDeleted: true,
    });
    receiptsUpdated += 1;
  }
  return { receiptsUpdated };
}

function sanitizeJellyTransaction(data) {
  const result = {};
  if (typeof data.type === 'string') result.type = data.type;
  if (Number.isInteger(data.amount)) result.amount = data.amount;
  if (typeof data.reason === 'string') result.reason = data.reason;
  if (typeof data.platform === 'string') result.platform = data.platform;
  if (typeof data.productId === 'string') result.productId = data.productId;
  if (typeof data.receiptHash === 'string') result.receiptHash = data.receiptHash;
  if (typeof data.providerCategory === 'string') {
    result.providerCategory = data.providerCategory;
  }
  if (Number.isFinite(data.providerPurchaseTimeMillis)) {
    result.providerPurchaseTimeMillis = data.providerPurchaseTimeMillis;
  }
  if (data.createdAt != null) result.originalCreatedAt = data.createdAt;
  return result;
}

async function createIfAbsent(ref, payload) {
  try {
    await ref.create(payload);
    return true;
  } catch (error) {
    const code = String(error?.code || '').toLowerCase();
    if (code === '6' || code === 'already-exists' || code.includes('already')) {
      return false;
    }
    throw error;
  }
}

async function preserveAndDeleteJellyTransactions({
  db,
  uid,
  uidHash,
  serverTimestamp,
}) {
  const txSnap = await db
    .collection('users')
    .doc(uid)
    .collection('jellyTransactions')
    .get();
  let auditCreated = 0;
  const originalRefs = [];
  for (const doc of txSnap.docs || []) {
    const transactionHash = sha256Hex(doc.id);
    const auditRef = db
      .collection('_deletedAccountAudit')
      .doc(uidHash)
      .collection('jellyTransactions')
      .doc(transactionHash);
    const created = await createIfAbsent(auditRef, {
      ...sanitizeJellyTransaction(doc.data() || {}),
      transactionHash,
      deletedSubjectHash: uidHash,
      createdAt: serverTime(serverTimestamp),
    });
    if (created) auditCreated += 1;
    originalRefs.push(doc.ref);
  }
  const originalsDeleted = await deleteRefs(originalRefs, `users/${uid}/jellyTransactions/`);
  return { jellyAuditCreated: auditCreated, jellyTransactionsDeleted: originalsDeleted };
}

async function cleanupUsageState({ db, uid }) {
  let deleted = 0;
  const purchaseUsageRef = db.collection('_purchaseVerificationUsage').doc(uid);
  await purchaseUsageRef.delete();
  deleted += 1;

  const aiUsageRef = db.collection('_internalAiUsage').doc(uid);
  if (typeof db.recursiveDelete === 'function') {
    await db.recursiveDelete(aiUsageRef);
  } else {
    await aiUsageRef.delete();
  }
  deleted += 1;
  return {
    usageDocsDeleted: deleted,
    aiLeases: 'ttl_only_unselectable',
  };
}

async function cleanupProfiles({ db, uid }) {
  const userRef = db.collection('users').doc(uid);
  const publicRef = db.collection('publicProfiles').doc(uid);
  if (typeof db.recursiveDelete !== 'function') {
    fail('failed-precondition', 'recursive_delete_unavailable', false);
  }
  await db.recursiveDelete(userRef);
  await publicRef.delete();
  return { userProfileDeleted: true, publicProfileDeleted: true };
}

async function deleteAuthLast({ auth, uid }) {
  try {
    await auth.deleteUser(uid);
    return { authDeleted: true, authAlreadyMissing: false };
  } catch (error) {
    if (isNotFoundError(error)) {
      return { authDeleted: true, authAlreadyMissing: true };
    }
    throw error;
  }
}

async function finalizeAuthDeletion({
  auth,
  uid,
  uidHash,
  deletedIdentifier,
  jobRef,
  serverTimestamp,
  fieldDelete,
  logger,
  callerHash,
}) {
  try {
    await markJob({
      jobRef,
      status: JOB_STATUS.AUTH_DELETE_PENDING,
      serverTimestamp,
      payload: {
        lastCompletedStep: 'auth_delete_pending',
        subjectUid: uid,
      },
    });
  } catch (_) {
    safeLog(logger, 'auth', {
      callerHash,
      status: JOB_STATUS.PROFILE_CLEANED,
      category: 'auth_delete_pending_write_failed',
      retryable: true,
    });
    fail('internal', 'auth_delete_pending_write_failed', true);
  }

  try {
    const result = await deleteAuthLast({ auth, uid });
    safeLog(logger, 'auth', {
      callerHash,
      status: JOB_STATUS.AUTH_DELETE_PENDING,
      category: result.authAlreadyMissing ? 'auth_user_not_found' : 'auth_deleted',
      retryable: false,
    });
  } catch (error) {
    await failJob({
      jobRef,
      step: 'auth',
      category: 'auth_delete_failed',
      retryable: true,
      serverTimestamp,
    });
    safeLog(logger, 'auth', {
      callerHash,
      status: JOB_STATUS.FAILED_RETRYABLE,
      category: 'auth_delete_failed',
      retryable: true,
    });
    fail('internal', 'auth_delete_failed', true);
  }

  try {
    await markJob({
      jobRef,
      status: JOB_STATUS.AUTH_DELETED,
      serverTimestamp,
      payload: { lastCompletedStep: 'auth' },
    });

    await markJob({
      jobRef,
      status: JOB_STATUS.COMPLETED,
      serverTimestamp,
      fieldDelete,
      payload: {
        completedAt: serverTime(serverTimestamp),
        deletedIdentifierHash: shortHash(deletedIdentifier),
        uidHash,
      },
    });
  } catch (_) {
    safeLog(logger, 'auth', {
      callerHash,
      status: JOB_STATUS.AUTH_DELETE_PENDING,
      category: 'auth_finalization_write_failed',
      retryable: true,
    });
    fail('internal', 'auth_finalization_write_failed', true);
  }
}

async function recoverPendingAuthDeletionCore({
  uidHash,
  db,
  auth,
  serverTimestamp,
  fieldDelete,
  logger = null,
} = {}) {
  if (!uidHash || !db || !auth) {
    throw new Error('recoverPendingAuthDeletionCore requires uidHash, db, and auth');
  }
  const jobRef = db.collection('_accountDeletionJobs').doc(uidHash);
  const snap = await jobRef.get();
  const job = snap.exists ? snap.data() || {} : {};
  if (job.status === JOB_STATUS.COMPLETED) {
    return { status: JOB_STATUS.COMPLETED, alreadyCompleted: true };
  }
  if (
    job.status !== JOB_STATUS.AUTH_DELETE_PENDING &&
    job.status !== JOB_STATUS.AUTH_DELETED
  ) {
    fail('failed-precondition', 'job_not_recoverable', false);
  }
  const uid = job.subjectUid;
  if (typeof uid !== 'string' || uid.length === 0) {
    fail('failed-precondition', 'missing_recovery_subject', false);
  }
  const deletedIdentifier = deletedIdentifierForUid(uid);
  await finalizeAuthDeletion({
    auth,
    uid,
    uidHash,
    deletedIdentifier,
    jobRef,
    serverTimestamp,
    fieldDelete,
    logger,
    callerHash: shortHash(uid),
  });
  return { status: JOB_STATUS.COMPLETED, alreadyCompleted: false };
}

async function runStep({
  step,
  status,
  jobRef,
  logger,
  callerHash,
  serverTimestamp,
  fn,
}) {
  try {
    const result = await fn();
    await markJob({
      jobRef,
      status,
      serverTimestamp,
      payload: { lastCompletedStep: step },
    });
    safeLog(logger, step, {
      callerHash,
      status,
      category: 'completed',
      counts: result,
      retryable: false,
    });
    return result;
  } catch (error) {
    const category = error instanceof AccountDeletionError
      ? error.category
      : `${step}_failed`;
    const retryable = !(error instanceof AccountDeletionError) || error.retryable;
    const failureStatus = retryable
      ? JOB_STATUS.FAILED_RETRYABLE
      : JOB_STATUS.MANUAL_REVIEW_REQUIRED;
    await failJob({
      jobRef,
      status: failureStatus,
      step,
      category,
      retryable,
      serverTimestamp,
    });
    safeLog(logger, step, {
      callerHash,
      status: failureStatus,
      category,
      retryable,
    });
    if (error instanceof AccountDeletionError) throw error;
    fail('internal', category, retryable);
  }
}

async function buildDeletionInventory({ db, uid, uidHash, bucket }) {
  const userRef = db.collection('users').doc(uid);
  const [
    userSnap,
    publicSnap,
    dailyFortuneSnap,
    outboundSwipeSnap,
    outboundBlockSnap,
    jellyTxSnap,
    inboundSwipeSnap,
    inboundBlockSnap,
    matchesSnap,
    reportsAuthoredSnap,
    reportsTargetingSnap,
    purchaseSnap,
  ] = await Promise.all([
    inventoryRead('inventory_user_failed', () => userRef.get()),
    inventoryRead(
      'inventory_public_profile_failed',
      () => db.collection('publicProfiles').doc(uid).get(),
    ),
    inventoryRead('inventory_daily_fortune_failed', () => userRef.collection('dailyFortune').get()),
    inventoryRead('inventory_outbound_swipes_failed', () => userRef.collection('swipes').get()),
    inventoryRead('inventory_outbound_blocks_failed', () => userRef.collection('blocks').get()),
    inventoryRead(
      'inventory_jelly_transactions_failed',
      () => userRef.collection('jellyTransactions').get(),
    ),
    inventoryRead(
      'inventory_inbound_swipes_failed',
      () => db.collectionGroup('swipes').where('targetUid', '==', uid).get(),
    ),
    inventoryRead(
      'inventory_inbound_blocks_failed',
      () => db.collectionGroup('blocks').where('blockedUid', '==', uid).get(),
    ),
    inventoryRead(
      'inventory_matches_failed',
      () => db.collection('matches').where('participants', 'array-contains', uid).get(),
    ),
    inventoryRead(
      'inventory_reports_reporter_failed',
      () => db.collection('reports').where('reporterUid', '==', uid).get(),
    ),
    inventoryRead(
      'inventory_reports_reported_failed',
      () => db.collection('reports').where('reportedUid', '==', uid).get(),
    ),
    inventoryRead(
      'inventory_receipts_failed',
      () => db.collection('_purchaseReceipts').where('uid', '==', uid).get(),
    ),
  ]);

  const storageFiles = bucket
    ? await listAllStorageFiles(bucket, `users/${uid}/`, {
      failureCategory: 'inventory_storage_list_failed',
    })
    : [];

  const matchDocs = matchesSnap.docs || [];
  let messageCount = 0;
  for (const matchDoc of matchDocs) {
    const messageSnap = await inventoryRead(
      'inventory_match_messages_failed',
      () => matchDoc.ref.collection('messages').where('senderId', '==', uid).get(),
    );
    messageCount += (messageSnap.docs || []).length;
  }

  return {
    uidHash,
    resources: {
      authUser: { exists: true },
      users: { exists: userSnap.exists === true },
      publicProfiles: { exists: publicSnap.exists === true },
      dailyFortune: { count: (dailyFortuneSnap.docs || []).length },
      swipesAuthored: { count: (outboundSwipeSnap.docs || []).length },
      swipesTargetingUser: { count: (inboundSwipeSnap.docs || []).length },
      blocksAuthored: { count: (outboundBlockSnap.docs || []).length },
      blocksTargetingUser: { count: (inboundBlockSnap.docs || []).length },
      jellyTransactions: { count: (jellyTxSnap.docs || []).length },
      storageUserFiles: { count: storageFiles.length },
      matches: { count: matchDocs.length },
      matchMessages: { count: messageCount },
      reportsAuthored: { count: (reportsAuthoredSnap.docs || []).length },
      reportsTargetingUser: { count: (reportsTargetingSnap.docs || []).length },
      purchaseReceipts: { count: (purchaseSnap.docs || []).length },
      purchaseVerificationUsage: { exists: true },
      internalAiUsage: { exists: true },
    },
    sharedDataPolicy: SHARED_DATA_POLICY.ANONYMIZE_DELETED_PARTICIPANT,
  };
}

async function deleteMyAccountCore({
  request,
  db,
  auth,
  storageBucket,
  serverTimestamp,
  fieldDelete,
  nowMs = Date.now,
  leaseTtlMs = DEFAULT_LEASE_TTL_MS,
  logger = null,
} = {}) {
  if (!db || !auth || !storageBucket) {
    throw new Error('deleteMyAccountCore requires db, auth, and storageBucket');
  }
  const { uid, uidHash, deletedIdentifier } = parseAndValidateRequest({
    request,
    nowMs,
  });
  const callerHash = shortHash(uid);
  const jobRef = db.collection('_accountDeletionJobs').doc(uidHash);

  const lease = await acquireJobLease({
    db,
    jobRef,
    uid,
    uidHash,
    nowMs: nowMs(),
    serverTimestamp,
    leaseTtlMs,
  });
  if (lease.completed) {
    return { status: JOB_STATUS.COMPLETED, alreadyCompleted: true };
  }

  try {
    await runStep({
      step: 'inventory',
      status: JOB_STATUS.INVENTORIED,
      jobRef,
      logger,
      callerHash,
      serverTimestamp,
      fn: async () => {
        const inventory = await buildDeletionInventory({
          db,
          uid,
          uidHash,
          bucket: storageBucket,
        });
        const plan = planAccountDeletion(inventory);
        if (!plan.canProceed) {
          await failJob({
            jobRef,
            status: JOB_STATUS.MANUAL_REVIEW_REQUIRED,
            step: 'inventory',
            category: 'planner_blocked',
            retryable: false,
            serverTimestamp,
          });
          fail('failed-precondition', 'planner_blocked', false);
        }
        return {
          hardDelete: plan.hardDelete.length,
          removeRelations: plan.removeRelations.length,
          anonymize: plan.anonymize.length,
          retainServerOnly: plan.retainServerOnly.length,
        };
      },
    });

    await runStep({
      step: 'storage',
      status: JOB_STATUS.STORAGE_CLEANED,
      jobRef,
      logger,
      callerHash,
      serverTimestamp,
      fn: () => deleteStoragePrefix({ bucket: storageBucket, uid }),
    });

    await runStep({
      step: 'relations',
      status: JOB_STATUS.RELATIONS_CLEANED,
      jobRef,
      logger,
      callerHash,
      serverTimestamp,
      fn: () => deleteRelations({ db, uid }),
    });

    await runStep({
      step: 'shared_data',
      status: JOB_STATUS.SHARED_DATA_ANONYMIZED,
      jobRef,
      logger,
      callerHash,
      serverTimestamp,
      fn: async () => {
        const shared = await anonymizeSharedData({
          db,
          uid,
          uidHash,
          deletedIdentifier,
          fieldDelete,
        });
        const reports = await anonymizeReports({
          db,
          uid,
          uidHash,
          deletedIdentifier,
          fieldDelete,
        });
        const purchases = await anonymizePurchaseReceipts({
          db,
          uid,
          uidHash,
          deletedIdentifier,
          fieldDelete,
        });
        const jelly = await preserveAndDeleteJellyTransactions({
          db,
          uid,
          uidHash,
          serverTimestamp,
        });
        const usage = await cleanupUsageState({ db, uid });
        return { ...shared, ...reports, ...purchases, ...jelly, ...usage };
      },
    });

    await runStep({
      step: 'profiles',
      status: JOB_STATUS.PROFILE_CLEANED,
      jobRef,
      logger,
      callerHash,
      serverTimestamp,
      fn: () => cleanupProfiles({ db, uid }),
    });

    await finalizeAuthDeletion({
      auth,
      uid,
      uidHash,
      deletedIdentifier,
      jobRef,
      serverTimestamp,
      fieldDelete,
      logger,
      callerHash,
    });

    safeLog(logger, 'completed', {
      callerHash,
      status: JOB_STATUS.COMPLETED,
      category: 'completed',
      retryable: false,
    });
    return {
      status: JOB_STATUS.COMPLETED,
      alreadyCompleted: false,
    };
  } finally {
    await releaseJobLease({
      jobRef,
      leaseOwner: lease.leaseOwner,
      fieldDelete,
    });
  }
}

module.exports = {
  CONFIRMATION_TEXT,
  FUNCTION_NAME,
  JOB_STATUS,
  RECENT_AUTH_MAX_AGE_SECONDS,
  USER_ERROR_MESSAGE,
  AccountDeletionError,
  anonymizedMessageUpdate,
  deletedIdentifierForUid,
  normalizeMatchData,
  parseAndValidateRequest,
  recoverPendingAuthDeletionCore,
  toHttpsError,
  uidHashFor,
  deleteMyAccountCore,
};
