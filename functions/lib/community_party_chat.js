'use strict';

// Phase 4-5: 파티 기반 그룹 채팅 서버 전용 쓰기 경로.
//
// 권한의 source of truth는 **communityParties/{partyId}/members/{uid}**다.
// users/{uid}/partyMemberships mirror는 목록 표시용이고, 서버 판정에 쓰지
// 않는다(mirror가 뒤처져 있어도 권한이 새지 않게 한다).
//
// 개인정보/안전 원칙(Phase 4-2/4-4 계약을 그대로 따른다):
// - 작성자 snapshot은 publicProfiles/{uid} 공개 6개 필드로만 서버가 만든다.
// - 인증번호·계좌·송금 요청은 서버가 hard block한다.
// - 전화번호·외부 메신저는 클라이언트 경고 후 확인해야 통과한다.
// - 로그에는 uid hash와 분류 code만 남긴다(원문·탐지 문자열 금지).
// - 응답에는 messageId 또는 bool만 담는다.

const crypto = require('crypto');

const {
  MESSAGES: COMMUNITY_MESSAGES,
  REPORT_REASONS,
  SCHEMA_VERSION,
  buildCommunityAuthorSnapshot,
  deletedAuthorSnapshot,
  detectForbiddenCommunityText,
  makeError,
  millisOf,
  requireAuthUid,
  requireDocId,
  requireExactObject,
  safeLog,
  safeUidHash,
} = require('./community');

const {
  PARTIES_COLLECTION,
  isVisibleParty,
} = require('./community_party');

const MEMBERS_SUBCOLLECTION = 'members';
const GROUP_MESSAGES_SUBCOLLECTION = 'groupMessages';
const MESSAGE_REPORTS_COLLECTION = 'partyMessageReports';
const MESSAGE_WRITE_LIMITS_COLLECTION = 'partyMessageWriteLimits';
const PUBLIC_PROFILES_COLLECTION = 'publicProfiles';

const MEMBER_STATUS_ACTIVE = 'active';
const MESSAGE_STATUS_ACTIVE = 'active';
const MESSAGE_STATUS_REMOVED = 'removed';

const MESSAGE_TEXT_MAX_LENGTH = 1000;
const REPORT_DETAIL_MAX_LENGTH = 500;

/** 서버 전용 rate limit 간격. */
const MESSAGE_COOLDOWN_MS = 1000;
const REPORT_COOLDOWN_MS = 5 * 1000;

/**
 * 외부 메신저/SNS로 옮기려는 표현(클라이언트 chat_safety.dart와 같은 집합).
 *
 * '라인'은 '온라인·가이드라인·라인업'과 겹치므로 앞뒤 글자를 확인한다.
 */
const EXTERNAL_CONTACT_PATTERN =
  /카카오톡|카톡|오픈\s*채팅|오픈\s*카톡|인스타|텔레그램|telegram|왓츠앱|whatsapp|디스코드|discord|스냅챗|snapchat|(?<![가-힣A-Za-z])라인(?!업)|(?<![A-Za-z])LINE(?![A-Za-z])/i;

/** 내부 분류 code. 사용자 응답에는 넣지 않는다(로그 분류용). */
const ACKNOWLEDGEABLE_CODES = Object.freeze({
  phoneNumber: 'phone_number',
  externalContact: 'external_contact',
});

/** 확인 없이는 보낼 수 없다는 것을 클라이언트가 구분하는 고정 code. */
const ACK_REQUIRED_ERROR_CODE = 'party_chat/ack_required';

const MESSAGES = Object.freeze({
  ...COMMUNITY_MESSAGES,
  notMember: '이 파티의 참여자만 대화할 수 있어요.',
  partyClosed: '이미 종료됐거나 참여할 수 없는 파티예요.',
  messageNotFound: '이미 삭제된 메시지예요.',
  forbiddenChatText: '인증번호·계좌·송금 요청은 파티 대화에 보낼 수 없어요.',
  contactShareWarning:
    '연락처를 공유하면 원하지 않는 연락을 받을 수 있어요.\n'
    + '파티 참여자에게만 보내는 내용인지 다시 확인해주세요.',
});

// ── 입력 검증 ──────────────────────────────────────────────────────────────

function normalizeMessageText(value, HttpsError) {
  if (typeof value !== 'string') {
    throw makeError(HttpsError, 'invalid-argument', MESSAGES.invalidRequest);
  }
  const text = value.trim();
  if (text.length === 0 || text.length > MESSAGE_TEXT_MAX_LENGTH) {
    throw makeError(HttpsError, 'invalid-argument', MESSAGES.invalidRequest);
  }
  return text;
}

function normalizeOptionalDetail(value, HttpsError) {
  if (value === undefined || value === null || value === '') return '';
  if (typeof value !== 'string') {
    throw makeError(HttpsError, 'invalid-argument', MESSAGES.invalidRequest);
  }
  const detail = value.trim();
  if (detail.length > REPORT_DETAIL_MAX_LENGTH) {
    throw makeError(HttpsError, 'invalid-argument', MESSAGES.invalidRequest);
  }
  return detail;
}

function requireBoolean(value, HttpsError) {
  if (typeof value !== 'boolean') {
    throw makeError(HttpsError, 'invalid-argument', MESSAGES.invalidRequest);
  }
  return value;
}

// ── 안전 검사 ──────────────────────────────────────────────────────────────

/**
 * 그룹 채팅 본문 분류(순수 함수).
 *
 * 공개 글(라운지·피드)과 달리 전화번호·외부 메신저는 hard block이 아니다 —
 * 이미 함께 만나기로 한 참여자끼리는 정당한 공유일 수 있어서, 확인 후
 * 통과시킨다. 인증번호·계좌·송금 요청만 항상 막는다.
 *
 * 반환값에 원문이나 탐지 문자열은 담지 않는다.
 */
function classifyPartyChatText(text) {
  const communityCodes = detectForbiddenCommunityText(text);

  const blocked = communityCodes.filter(
    (code) => code !== ACKNOWLEDGEABLE_CODES.phoneNumber,
  );
  const acknowledgeable = communityCodes.filter(
    (code) => code === ACKNOWLEDGEABLE_CODES.phoneNumber,
  );
  if (typeof text === 'string' && EXTERNAL_CONTACT_PATTERN.test(text)) {
    acknowledgeable.push(ACKNOWLEDGEABLE_CODES.externalContact);
  }

  return { blocked, acknowledgeable };
}

function assertAllowedPartyChatText({
  text,
  safetyAcknowledged,
  uid,
  functionName,
  logger,
  HttpsError,
}) {
  const { blocked, acknowledgeable } = classifyPartyChatText(text);

  if (blocked.length > 0) {
    safeLog(logger, functionName, {
      step: 'forbidden_text_blocked',
      callerHash: safeUidHash(uid),
      codes: blocked,
    });
    throw makeError(HttpsError, 'invalid-argument', MESSAGES.forbiddenChatText);
  }

  if (acknowledgeable.length > 0 && safetyAcknowledged !== true) {
    safeLog(logger, functionName, {
      step: 'ack_required',
      callerHash: safeUidHash(uid),
      codes: acknowledgeable,
    });
    // details에는 고정 code만 넣는다(원문·탐지 문자열 금지).
    throw makeError(
      HttpsError,
      'failed-precondition',
      MESSAGES.contactShareWarning,
      { code: ACK_REQUIRED_ERROR_CODE },
    );
  }
}

// ── rate limit ─────────────────────────────────────────────────────────────

function assertChatRateLimit({ limitData, field, cooldownMs, nowMs, HttpsError }) {
  const last = millisOf(limitData?.[field]);
  if (last > 0 && nowMs - last < cooldownMs) {
    throw makeError(HttpsError, 'resource-exhausted', MESSAGES.rateLimited);
  }
}

// ── 참조 ───────────────────────────────────────────────────────────────────

function chatRefs(db, partyId) {
  const partyRef = db.collection(PARTIES_COLLECTION).doc(partyId);
  return {
    partyRef,
    memberRef: (uid) => partyRef.collection(MEMBERS_SUBCOLLECTION).doc(uid),
    messagesRef: () => partyRef.collection(GROUP_MESSAGES_SUBCOLLECTION),
    messageRef: (messageId) =>
      partyRef.collection(GROUP_MESSAGES_SUBCOLLECTION).doc(messageId),
  };
}

function limitRef(db, uid) {
  return db.collection(MESSAGE_WRITE_LIMITS_COLLECTION).doc(uid);
}

/** 채팅에 참여할 수 있는 member 문서인지(순수 함수). */
function isActiveMember(data) {
  return (
    data != null &&
    data.status === MEMBER_STATUS_ACTIVE &&
    data.schemaVersion === SCHEMA_VERSION
  );
}

/**
 * 채팅 진입 자격을 확인한다.
 *
 * host도 members/{hostUid} 문서를 통해 같은 조건을 쓴다 — hostUid 비교로
 * 우회하는 경로를 만들지 않는다.
 */
async function assertChatAccess({ tx, partyRef, memberRef, HttpsError }) {
  const partySnap = await (tx ? tx.get(partyRef) : partyRef.get());
  if (!partySnap.exists) {
    throw makeError(HttpsError, 'not-found', MESSAGES.partyClosed);
  }
  const partyData = partySnap.data();
  if (!isVisibleParty(partyData)) {
    throw makeError(HttpsError, 'not-found', MESSAGES.partyClosed);
  }

  const memberSnap = await (tx ? tx.get(memberRef) : memberRef.get());
  if (!memberSnap.exists || !isActiveMember(memberSnap.data())) {
    // pending/rejected/withdrawn 사용자도 여기서 걸린다.
    throw makeError(HttpsError, 'permission-denied', MESSAGES.notMember);
  }
  return partyData;
}

async function loadSenderSnapshot({ db, uid, HttpsError }) {
  const snap = await db.collection(PUBLIC_PROFILES_COLLECTION).doc(uid).get();
  const snapshot = snap.exists
    ? buildCommunityAuthorSnapshot({ uid, publicProfileData: snap.data() })
    : null;
  if (!snapshot) {
    throw makeError(HttpsError, 'failed-precondition', MESSAGES.profileRequired);
  }
  return snapshot;
}

// ── sendPartyGroupMessage ──────────────────────────────────────────────────

async function sendPartyGroupMessageCore({
  request,
  db,
  HttpsError,
  serverTimestamp,
  nowMs = Date.now,
  logger = null,
} = {}) {
  const functionName = 'sendPartyGroupMessage';
  const uid = requireAuthUid(request, HttpsError);
  const data = requireExactObject(
    request?.data ?? {},
    ['partyId', 'text', 'safetyAcknowledged'],
    HttpsError,
  );
  const partyId = requireDocId(data.partyId, HttpsError);
  const text = normalizeMessageText(data.text, HttpsError);
  const safetyAcknowledged = requireBoolean(data.safetyAcknowledged, HttpsError);

  assertAllowedPartyChatText({
    text,
    safetyAcknowledged,
    uid,
    functionName,
    logger,
    HttpsError,
  });

  const { partyRef, memberRef, messagesRef } = chatRefs(db, partyId);

  // 자격을 먼저 확인해야 공개 프로필을 읽을 이유가 생긴다.
  await assertChatAccess({ partyRef, memberRef: memberRef(uid), HttpsError });
  const senderSnapshot = await loadSenderSnapshot({ db, uid, HttpsError });

  const messageRef = messagesRef().doc();
  const limits = limitRef(db, uid);
  const now = nowMs();

  await db.runTransaction(async (tx) => {
    // 파티가 취소되거나 멤버에서 빠지는 race를 막기 위해 다시 확인한다.
    await assertChatAccess({
      tx,
      partyRef,
      memberRef: memberRef(uid),
      HttpsError,
    });

    const limitSnap = await tx.get(limits);
    assertChatRateLimit({
      limitData: limitSnap.exists ? limitSnap.data() : null,
      field: 'lastMessageAt',
      cooldownMs: MESSAGE_COOLDOWN_MS,
      nowMs: now,
      HttpsError,
    });

    tx.set(messageRef, {
      senderUid: uid,
      senderSnapshot,
      text,
      status: MESSAGE_STATUS_ACTIVE,
      createdAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
      schemaVersion: SCHEMA_VERSION,
    });
    tx.set(
      limits,
      {
        lastMessageAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
        schemaVersion: SCHEMA_VERSION,
      },
      { merge: true },
    );
  });

  safeLog(logger, functionName, {
    step: 'sent',
    callerHash: safeUidHash(uid),
  });

  // 응답에는 새 문서 id만 담는다(UID·본문·snapshot 금지).
  return { messageId: messageRef.id };
}

// ── deletePartyGroupMessage ────────────────────────────────────────────────

async function deletePartyGroupMessageCore({
  request,
  db,
  HttpsError,
  serverTimestamp,
  logger = null,
} = {}) {
  const functionName = 'deletePartyGroupMessage';
  const uid = requireAuthUid(request, HttpsError);
  const data = requireExactObject(
    request?.data ?? {},
    ['partyId', 'messageId'],
    HttpsError,
  );
  const partyId = requireDocId(data.partyId, HttpsError);
  const messageId = requireDocId(data.messageId, HttpsError);

  const { partyRef, memberRef, messageRef } = chatRefs(db, partyId);

  await db.runTransaction(async (tx) => {
    await assertChatAccess({
      tx,
      partyRef,
      memberRef: memberRef(uid),
      HttpsError,
    });

    const messageSnap = await tx.get(messageRef(messageId));
    if (!messageSnap.exists) {
      throw makeError(HttpsError, 'not-found', MESSAGES.messageNotFound);
    }
    const messageData = messageSnap.data();
    if (messageData.senderUid !== uid) {
      throw makeError(HttpsError, 'permission-denied', MESSAGES.permissionDenied);
    }
    // 이미 지운 메시지면 아무것도 바꾸지 않고 성공한다(멱등).
    if (messageData.status === MESSAGE_STATUS_REMOVED) return;

    // 본문은 남긴다 — 커뮤니티 게시물·댓글과 같은 정책으로, 신고 검토를 위해
    // 운영이 Admin SDK로만 참조할 수 있게 두고 일반 read에서는 가린다.
    tx.update(messageRef(messageId), {
      status: MESSAGE_STATUS_REMOVED,
      updatedAt: serverTimestamp(),
    });
  });

  safeLog(logger, functionName, {
    step: 'removed',
    callerHash: safeUidHash(uid),
  });

  return { deleted: true };
}

// ── reportPartyGroupMessage ────────────────────────────────────────────────

/** 같은 신고자·같은 메시지면 항상 같은 문서 id(중복 신고 멱등 처리). */
function partyMessageReportId({ reporterUid, partyId, messageId }) {
  return crypto
    .createHash('sha256')
    .update(`${reporterUid}|${partyId}|${messageId}`)
    .digest('hex');
}

async function reportPartyGroupMessageCore({
  request,
  db,
  HttpsError,
  serverTimestamp,
  nowMs = Date.now,
  logger = null,
} = {}) {
  const functionName = 'reportPartyGroupMessage';
  const uid = requireAuthUid(request, HttpsError);
  const data = requireExactObject(
    request?.data ?? {},
    ['partyId', 'messageId', 'reason', 'detail'],
    HttpsError,
  );
  const partyId = requireDocId(data.partyId, HttpsError);
  const messageId = requireDocId(data.messageId, HttpsError);
  const reason = data.reason;
  if (typeof reason !== 'string' || !REPORT_REASONS.includes(reason)) {
    throw makeError(HttpsError, 'invalid-argument', MESSAGES.invalidRequest);
  }
  const detail = normalizeOptionalDetail(data.detail, HttpsError);

  const { partyRef, memberRef, messageRef } = chatRefs(db, partyId);
  const reportRef = db
    .collection(MESSAGE_REPORTS_COLLECTION)
    .doc(partyMessageReportId({ reporterUid: uid, partyId, messageId }));
  const limits = limitRef(db, uid);
  const now = nowMs();

  await db.runTransaction(async (tx) => {
    await assertChatAccess({
      tx,
      partyRef,
      memberRef: memberRef(uid),
      HttpsError,
    });

    const messageSnap = await tx.get(messageRef(messageId));
    if (!messageSnap.exists) {
      throw makeError(HttpsError, 'not-found', MESSAGES.messageNotFound);
    }
    const reportedUid = messageSnap.data().senderUid;
    if (typeof reportedUid !== 'string' || reportedUid.length === 0) {
      throw makeError(HttpsError, 'not-found', MESSAGES.messageNotFound);
    }
    if (reportedUid === uid) {
      throw makeError(HttpsError, 'failed-precondition', MESSAGES.invalidRequest);
    }

    const reportSnap = await tx.get(reportRef);
    // 같은 메시지 재신고는 새 문서를 만들지 않고 성공 처리한다(멱등).
    if (reportSnap.exists) return;

    const limitSnap = await tx.get(limits);
    assertChatRateLimit({
      limitData: limitSnap.exists ? limitSnap.data() : null,
      field: 'lastReportAt',
      cooldownMs: REPORT_COOLDOWN_MS,
      nowMs: now,
      HttpsError,
    });

    // 원문 snapshot은 저장하지 않는다. 운영 검토는 id 참조로 한다.
    // 신고만으로 메시지를 지우거나 멤버를 빼거나 파티를 취소하지 않는다.
    tx.set(reportRef, {
      reporterUid: uid,
      reportedUid,
      partyId,
      messageId,
      reason,
      ...(detail.length > 0 ? { detail } : {}),
      createdAt: serverTimestamp(),
      schemaVersion: SCHEMA_VERSION,
    });
    tx.set(
      limits,
      {
        lastReportAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
        schemaVersion: SCHEMA_VERSION,
      },
      { merge: true },
    );
  });

  safeLog(logger, functionName, {
    step: 'reported',
    callerHash: safeUidHash(uid),
    reason,
  });

  // report id·대상 UID는 응답에 넣지 않는다.
  return { reported: true };
}

// ── 회원 탈퇴 수명주기 ─────────────────────────────────────────────────────

/**
 * 탈퇴 사용자의 그룹 채팅 메시지 정리(멱등).
 *
 * - 메시지: soft remove + 작성자 익명화(원문은 신고 검토용으로 남는다)
 * - 신고: reporterUid만 익명 식별자로 교체
 * - rate limit 문서 삭제
 *
 * senderUid를 익명 식별자로 바꾸므로 재실행 시 같은 문서가 다시 잡히지 않는다.
 */
async function cleanupPartyChatDataForUser({
  db,
  uid,
  deletedIdentifier,
  serverTimestamp,
} = {}) {
  if (!db || typeof uid !== 'string' || uid.length === 0) {
    throw new Error('cleanupPartyChatDataForUser requires db and uid');
  }
  const anonymousSnapshot = deletedAuthorSnapshot(deletedIdentifier);

  let partyMessagesRemoved = 0;
  const messagesSnap = await db
    .collectionGroup(GROUP_MESSAGES_SUBCOLLECTION)
    .where('senderUid', '==', uid)
    .get();
  for (const doc of messagesSnap.docs || []) {
    await doc.ref.update({
      status: MESSAGE_STATUS_REMOVED,
      senderUid: deletedIdentifier,
      senderSnapshot: anonymousSnapshot,
      updatedAt: serverTimestamp(),
    });
    partyMessagesRemoved += 1;
  }

  let partyMessageReportsAnonymized = 0;
  const reportsSnap = await db
    .collection(MESSAGE_REPORTS_COLLECTION)
    .where('reporterUid', '==', uid)
    .get();
  for (const doc of reportsSnap.docs || []) {
    await doc.ref.update({
      reporterUid: deletedIdentifier,
      reporterDeleted: true,
    });
    partyMessageReportsAnonymized += 1;
  }

  await db.collection(MESSAGE_WRITE_LIMITS_COLLECTION).doc(uid).delete();

  return {
    partyMessagesRemoved,
    partyMessageReportsAnonymized,
    partyMessageWriteLimitsDeleted: true,
  };
}

module.exports = {
  ACKNOWLEDGEABLE_CODES,
  ACK_REQUIRED_ERROR_CODE,
  GROUP_MESSAGES_SUBCOLLECTION,
  MESSAGES,
  MESSAGE_COOLDOWN_MS,
  MESSAGE_REPORTS_COLLECTION,
  MESSAGE_STATUS_ACTIVE,
  MESSAGE_STATUS_REMOVED,
  MESSAGE_TEXT_MAX_LENGTH,
  MESSAGE_WRITE_LIMITS_COLLECTION,
  REPORT_COOLDOWN_MS,
  classifyPartyChatText,
  cleanupPartyChatDataForUser,
  deletePartyGroupMessageCore,
  isActiveMember,
  partyMessageReportId,
  reportPartyGroupMessageCore,
  sendPartyGroupMessageCore,
};
