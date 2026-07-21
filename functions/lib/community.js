'use strict';

// Phase 4-2: 라운지 커뮤니티 서버 전용 쓰기 경로.
//
// 개인정보/안전 원칙:
// - 작성자 정보는 publicProfiles/{uid}에서만 만든다(비공개 users/{uid} 금지).
// - 클라이언트는 author snapshot·status·count·timestamp를 보내지 못한다.
// - 공개 글에 전화번호/인증번호/송금 요청이 들어가면 서버가 거부한다.
// - 로그에는 uid hash와 분류 code만 남긴다(원문·탐지 문자열·대상 UID 금지).
// - 응답에는 새 문서 id 또는 bool/count만 담는다.

const crypto = require('crypto');

const POSTS_COLLECTION = 'communityPosts';
const COMMENTS_SUBCOLLECTION = 'comments';
const REACTIONS_SUBCOLLECTION = 'reactions';
const REPORTS_COLLECTION = 'communityReports';
const WRITE_LIMITS_COLLECTION = 'communityWriteLimits';
const PUBLIC_PROFILES_COLLECTION = 'publicProfiles';

const SCHEMA_VERSION = 1;
const SURFACE_LOUNGE = 'lounge';
const VISIBILITY_AUTHENTICATED = 'authenticated';
const STATUS_ACTIVE = 'active';
const STATUS_REMOVED = 'removed';
const REACTION_TYPE_LIKE = 'like';

const POST_TEXT_MAX_LENGTH = 1000;
const COMMENT_TEXT_MAX_LENGTH = 500;
const REPORT_DETAIL_MAX_LENGTH = 500;
const DISPLAY_NAME_MAX_LENGTH = 40;
const PHOTO_URL_MAX_LENGTH = 2048;

/** 최소 작성 간격(서버 전용 rate limit). */
const POST_COOLDOWN_MS = 10 * 1000;
const COMMENT_COOLDOWN_MS = 3 * 1000;
const REPORT_COOLDOWN_MS = 5 * 1000;

const DELETED_AUTHOR_DISPLAY_NAME = '탈퇴한 사용자';

/** 허용 신고 사유. 자유 입력 key는 받지 않는다. */
const REPORT_REASONS = Object.freeze([
  'abusive_language',
  'sexual_content',
  'hate_threat',
  'spam_scam',
  'personal_info',
  'impersonation',
  'other',
]);

const REPORT_TARGET_TYPES = Object.freeze(['post', 'comment']);

/** 사용자에게 보여줄 고정 문구. 내부 원인·원문은 절대 넣지 않는다. */
const MESSAGES = Object.freeze({
  unauthenticated: '로그인이 필요해요.',
  invalidRequest: '요청 형식이 올바르지 않습니다.',
  forbiddenText: '개인정보·인증번호·송금 요청이 포함된 글은 올릴 수 없어요.',
  rateLimited: '잠시 후 다시 시도해주세요.',
  profileRequired: '프로필을 먼저 완성한 뒤 이용할 수 있어요.',
  notFound: '이미 삭제됐거나 볼 수 없는 글이에요.',
  permissionDenied: '권한이 없어요.',
});

// ── 오류 ───────────────────────────────────────────────────────────────────

/** 금지 내용 거부를 클라이언트가 구분할 수 있게 하는 고정 내부 code. */
const FORBIDDEN_TEXT_ERROR_CODE = 'community/forbidden_text';

function makeError(HttpsError, code, message, details) {
  const error = details === undefined
    ? new HttpsError(code, message)
    : new HttpsError(code, message, details);
  error.__communitySafeError = true;
  return error;
}

function safeUidHash(uid) {
  return crypto.createHash('sha256').update(String(uid)).digest('hex').slice(0, 8);
}

function safeLog(logger, functionName, meta = {}) {
  if (!logger || typeof logger.log !== 'function') return;
  logger.log({ functionName, ...meta });
}

// ── 공개 텍스트 안전 검사 ──────────────────────────────────────────────────
//
// 오탐을 줄이는 쪽으로 보수적으로 잡는다. 날짜·시간·가격·주문번호·'돈까스'
// 같은 일상 표현이 걸리면 사용자가 안내 자체를 무시하게 된다.

/** 한국 휴대전화(국내 표기). 더 긴 숫자열의 일부이면 매칭하지 않는다. */
const KR_MOBILE_PATTERN = /(?<![0-9])01[016789][-. ]?[0-9]{3,4}[-. ]?[0-9]{4}(?![0-9])/;
/** +82 10 1234 5678 형태(국가번호 표기). */
const KR_MOBILE_INTL_PATTERN =
  /(?<![0-9])\+?82[-. ]?1[016789][-. ]?[0-9]{3,4}[-. ]?[0-9]{4}(?![0-9])/;

/** 인증/비밀 정보. 숫자가 없어도 차단 대상이다. */
const VERIFICATION_PATTERN =
  /인증\s*번호|인증\s*코드|승인\s*번호|보안\s*코드|비밀\s*번호|패스워드|(?<![A-Za-z])OTP(?![A-Za-z])/i;

/** 명확한 금전 요청만 넣는다('돈'처럼 단독으로 일상어인 단어는 제외). */
const FINANCIAL_PATTERNS = Object.freeze([
  /계좌\s*번호/,
  /계좌\s*(로|에|으로)\s*(보내|부쳐|입금|송금|이체)/,
  /선\s*입금/,
  /입금\s*(해|부탁|요청|바랍)/,
  /송금\s*(해|부탁|요청|바랍)/,
  /이체\s*(해|부탁|요청|바랍)/,
  /돈\s*(을|좀|만)?\s*(보내|부쳐|이체|송금|빌려)/,
]);

/** 내부 분류 code. 사용자 응답에는 넣지 않는다(로그 분류용). */
const FORBIDDEN_TEXT_CODES = Object.freeze({
  phoneNumber: 'phone_number',
  verificationCode: 'verification_code',
  financialRequest: 'financial_request',
});

/**
 * 공개 글에 올릴 수 없는 내용을 찾는다(순수 함수).
 * 반환값은 내부 code 배열이며, **탐지된 문자열이나 원문은 담지 않는다.**
 */
function detectForbiddenCommunityText(text) {
  if (typeof text !== 'string' || text.trim().length === 0) return [];
  const codes = [];
  if (KR_MOBILE_PATTERN.test(text) || KR_MOBILE_INTL_PATTERN.test(text)) {
    codes.push(FORBIDDEN_TEXT_CODES.phoneNumber);
  }
  if (VERIFICATION_PATTERN.test(text)) {
    codes.push(FORBIDDEN_TEXT_CODES.verificationCode);
  }
  if (FINANCIAL_PATTERNS.some((pattern) => pattern.test(text))) {
    codes.push(FORBIDDEN_TEXT_CODES.financialRequest);
  }
  return codes;
}

// ── 작성자 snapshot ────────────────────────────────────────────────────────

/**
 * publicProfiles 문서 → 커뮤니티 작성자 snapshot(순수 함수).
 *
 * 공개 6개 필드만 만든다. 생년월일·나이·성별·정확 위치·전화번호·이메일·
 * 기관명·젤리·FCM 토큰·인증 증빙 경로·연락처 해시는 담지 않는다.
 * email/phone 인증 여부도 커뮤니티에는 노출하지 않는다.
 *
 * 표시 이름이 유효하지 않으면 null을 반환한다(호출부가 작성을 거부한다).
 */
function buildCommunityAuthorSnapshot({ uid, publicProfileData } = {}) {
  if (typeof uid !== 'string' || uid.length === 0) return null;
  if (publicProfileData === null || typeof publicProfileData !== 'object') return null;

  const rawName = publicProfileData.displayName;
  if (typeof rawName !== 'string') return null;
  const displayName = rawName.trim().slice(0, DISPLAY_NAME_MAX_LENGTH);
  if (displayName.length === 0) return null;

  let photoUrl = '';
  const photoUrls = publicProfileData.photoUrls;
  if (Array.isArray(photoUrls)) {
    for (const candidate of photoUrls) {
      if (typeof candidate === 'string' &&
        candidate.length > 0 &&
        candidate.length <= PHOTO_URL_MAX_LENGTH) {
        photoUrl = candidate;
        break;
      }
    }
  }

  const verifications =
    publicProfileData.verifications !== null &&
    typeof publicProfileData.verifications === 'object'
      ? publicProfileData.verifications
      : {};

  return {
    uid,
    displayName,
    photoUrl,
    photoVerified: verifications.photo === true,
    workVerified: verifications.work === true,
    schoolVerified: verifications.school === true,
  };
}

/** 탈퇴 계정용 익명 snapshot(회원 탈퇴 수명주기에서만 쓴다). */
function deletedAuthorSnapshot(deletedIdentifier) {
  return {
    uid: String(deletedIdentifier),
    displayName: DELETED_AUTHOR_DISPLAY_NAME,
    photoUrl: '',
    photoVerified: false,
    workVerified: false,
    schoolVerified: false,
  };
}

// ── 입력 검증 ──────────────────────────────────────────────────────────────

function requireAuthUid(request, HttpsError) {
  const uid = request?.auth?.uid;
  if (typeof uid !== 'string' || uid.length === 0) {
    throw makeError(HttpsError, 'unauthenticated', MESSAGES.unauthenticated);
  }
  return uid;
}

function requireExactObject(data, allowedKeys, HttpsError) {
  if (data === null || typeof data !== 'object' || Array.isArray(data)) {
    throw makeError(HttpsError, 'invalid-argument', MESSAGES.invalidRequest);
  }
  for (const key of Object.keys(data)) {
    if (!allowedKeys.includes(key)) {
      throw makeError(HttpsError, 'invalid-argument', MESSAGES.invalidRequest);
    }
  }
  return data;
}

function normalizeBodyText(value, maxLength, HttpsError) {
  if (typeof value !== 'string') {
    throw makeError(HttpsError, 'invalid-argument', MESSAGES.invalidRequest);
  }
  const text = value.trim();
  if (text.length === 0 || text.length > maxLength) {
    throw makeError(HttpsError, 'invalid-argument', MESSAGES.invalidRequest);
  }
  return text;
}

function requireDocId(value, HttpsError) {
  if (typeof value !== 'string') {
    throw makeError(HttpsError, 'invalid-argument', MESSAGES.invalidRequest);
  }
  const id = value.trim();
  if (id.length === 0 || id.length > 1500 || id.includes('/')) {
    throw makeError(HttpsError, 'invalid-argument', MESSAGES.invalidRequest);
  }
  return id;
}

/** 공개 글 금지 내용 확인. 원문·탐지 문자열은 로그/응답에 넣지 않는다. */
function assertAllowedCommunityText({ text, uid, functionName, logger, HttpsError }) {
  const codes = detectForbiddenCommunityText(text);
  if (codes.length === 0) return;
  safeLog(logger, functionName, {
    step: 'forbidden_text_blocked',
    callerHash: safeUidHash(uid),
    codes,
  });
  // details에는 고정 code만 넣는다(원문·탐지 문자열 금지).
  throw makeError(HttpsError, 'invalid-argument', MESSAGES.forbiddenText, {
    code: FORBIDDEN_TEXT_ERROR_CODE,
  });
}

// ── rate limit ─────────────────────────────────────────────────────────────

function millisOf(value) {
  if (value == null) return 0;
  if (typeof value.toMillis === 'function') {
    const millis = value.toMillis();
    return Number.isFinite(millis) ? millis : 0;
  }
  if (value instanceof Date) return value.getTime();
  if (typeof value === 'number' && Number.isFinite(value)) return value;
  return 0;
}

function assertWithinRateLimit({ limitData, field, cooldownMs, nowMs, HttpsError }) {
  const last = millisOf(limitData?.[field]);
  if (last > 0 && nowMs - last < cooldownMs) {
    throw makeError(HttpsError, 'resource-exhausted', MESSAGES.rateLimited);
  }
}

// ── 공통 조회 ──────────────────────────────────────────────────────────────

async function loadAuthorSnapshot({ db, uid, HttpsError }) {
  const snap = await db.collection(PUBLIC_PROFILES_COLLECTION).doc(uid).get();
  const snapshot = snap.exists
    ? buildCommunityAuthorSnapshot({ uid, publicProfileData: snap.data() })
    : null;
  if (!snapshot) {
    throw makeError(HttpsError, 'failed-precondition', MESSAGES.profileRequired);
  }
  return snapshot;
}

/** 라운지 게시물로서 상호작용 가능한 상태인지. */
function isInteractablePost(data) {
  return (
    data != null &&
    data.surface === SURFACE_LOUNGE &&
    data.status === STATUS_ACTIVE &&
    data.visibility === VISIBILITY_AUTHENTICATED
  );
}

function safeCount(value) {
  return Number.isInteger(value) && value > 0 ? value : 0;
}

// ── createLoungePost ───────────────────────────────────────────────────────

async function createLoungePostCore({
  request,
  db,
  HttpsError,
  serverTimestamp,
  nowMs = Date.now,
  logger = null,
} = {}) {
  const functionName = 'createLoungePost';
  const uid = requireAuthUid(request, HttpsError);
  const data = requireExactObject(request?.data ?? {}, ['text'], HttpsError);
  const text = normalizeBodyText(data.text, POST_TEXT_MAX_LENGTH, HttpsError);
  assertAllowedCommunityText({ text, uid, functionName, logger, HttpsError });

  const authorSnapshot = await loadAuthorSnapshot({ db, uid, HttpsError });

  const postRef = db.collection(POSTS_COLLECTION).doc();
  const limitRef = db.collection(WRITE_LIMITS_COLLECTION).doc(uid);
  const now = nowMs();

  await db.runTransaction(async (tx) => {
    const limitSnap = await tx.get(limitRef);
    assertWithinRateLimit({
      limitData: limitSnap.exists ? limitSnap.data() : null,
      field: 'lastPostAt',
      cooldownMs: POST_COOLDOWN_MS,
      nowMs: now,
      HttpsError,
    });

    tx.set(postRef, {
      surface: SURFACE_LOUNGE,
      authorUid: uid,
      authorSnapshot,
      text,
      imageUrls: [],
      status: STATUS_ACTIVE,
      visibility: VISIBILITY_AUTHENTICATED,
      reactionCount: 0,
      commentCount: 0,
      createdAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
      schemaVersion: SCHEMA_VERSION,
    });
    tx.set(
      limitRef,
      {
        lastPostAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
        schemaVersion: SCHEMA_VERSION,
      },
      { merge: true },
    );
  });

  safeLog(logger, functionName, {
    step: 'created',
    callerHash: safeUidHash(uid),
  });

  return { postId: postRef.id };
}

// ── createCommunityComment ─────────────────────────────────────────────────

async function createCommunityCommentCore({
  request,
  db,
  HttpsError,
  serverTimestamp,
  nowMs = Date.now,
  logger = null,
} = {}) {
  const functionName = 'createCommunityComment';
  const uid = requireAuthUid(request, HttpsError);
  const data = requireExactObject(request?.data ?? {}, ['postId', 'text'], HttpsError);
  const postId = requireDocId(data.postId, HttpsError);
  const text = normalizeBodyText(data.text, COMMENT_TEXT_MAX_LENGTH, HttpsError);
  assertAllowedCommunityText({ text, uid, functionName, logger, HttpsError });

  const authorSnapshot = await loadAuthorSnapshot({ db, uid, HttpsError });

  const postRef = db.collection(POSTS_COLLECTION).doc(postId);
  const commentRef = postRef.collection(COMMENTS_SUBCOLLECTION).doc();
  const limitRef = db.collection(WRITE_LIMITS_COLLECTION).doc(uid);
  const now = nowMs();

  await db.runTransaction(async (tx) => {
    const postSnap = await tx.get(postRef);
    if (!postSnap.exists || !isInteractablePost(postSnap.data())) {
      throw makeError(HttpsError, 'not-found', MESSAGES.notFound);
    }
    const limitSnap = await tx.get(limitRef);
    assertWithinRateLimit({
      limitData: limitSnap.exists ? limitSnap.data() : null,
      field: 'lastCommentAt',
      cooldownMs: COMMENT_COOLDOWN_MS,
      nowMs: now,
      HttpsError,
    });

    tx.set(commentRef, {
      postId,
      authorUid: uid,
      authorSnapshot,
      text,
      status: STATUS_ACTIVE,
      createdAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
      schemaVersion: SCHEMA_VERSION,
    });
    // 댓글 때문에 게시물 updatedAt은 바꾸지 않는다(정렬/표시 기준 유지).
    tx.update(postRef, {
      commentCount: safeCount(postSnap.data().commentCount) + 1,
    });
    tx.set(
      limitRef,
      {
        lastCommentAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
        schemaVersion: SCHEMA_VERSION,
      },
      { merge: true },
    );
  });

  safeLog(logger, functionName, {
    step: 'created',
    callerHash: safeUidHash(uid),
  });

  return { commentId: commentRef.id };
}

// ── toggleCommunityReaction ────────────────────────────────────────────────

async function toggleCommunityReactionCore({
  request,
  db,
  HttpsError,
  serverTimestamp,
  logger = null,
} = {}) {
  const functionName = 'toggleCommunityReaction';
  const uid = requireAuthUid(request, HttpsError);
  const data = requireExactObject(request?.data ?? {}, ['postId'], HttpsError);
  const postId = requireDocId(data.postId, HttpsError);

  const postRef = db.collection(POSTS_COLLECTION).doc(postId);
  const reactionRef = postRef.collection(REACTIONS_SUBCOLLECTION).doc(uid);

  const result = await db.runTransaction(async (tx) => {
    const postSnap = await tx.get(postRef);
    if (!postSnap.exists || !isInteractablePost(postSnap.data())) {
      throw makeError(HttpsError, 'not-found', MESSAGES.notFound);
    }
    const reactionSnap = await tx.get(reactionRef);
    const current = safeCount(postSnap.data().reactionCount);

    if (!reactionSnap.exists) {
      const next = current + 1;
      tx.set(reactionRef, {
        uid,
        type: REACTION_TYPE_LIKE,
        createdAt: serverTimestamp(),
        schemaVersion: SCHEMA_VERSION,
      });
      tx.update(postRef, { reactionCount: next });
      return { reacted: true, reactionCount: next };
    }

    const next = current > 0 ? current - 1 : 0;
    tx.delete(reactionRef);
    tx.update(postRef, { reactionCount: next });
    return { reacted: false, reactionCount: next };
  });

  safeLog(logger, functionName, {
    step: result.reacted ? 'reacted' : 'unreacted',
    callerHash: safeUidHash(uid),
  });

  return result;
}

// ── deleteCommunityPost ────────────────────────────────────────────────────

async function deleteCommunityPostCore({
  request,
  db,
  HttpsError,
  serverTimestamp,
  logger = null,
} = {}) {
  const functionName = 'deleteCommunityPost';
  const uid = requireAuthUid(request, HttpsError);
  const data = requireExactObject(request?.data ?? {}, ['postId'], HttpsError);
  const postId = requireDocId(data.postId, HttpsError);

  const postRef = db.collection(POSTS_COLLECTION).doc(postId);

  await db.runTransaction(async (tx) => {
    const postSnap = await tx.get(postRef);
    if (!postSnap.exists) {
      throw makeError(HttpsError, 'not-found', MESSAGES.notFound);
    }
    const postData = postSnap.data();
    if (postData.authorUid !== uid) {
      throw makeError(HttpsError, 'permission-denied', MESSAGES.permissionDenied);
    }
    // 이미 지운 글은 멱등 성공. 댓글·반응·신고 참조는 그대로 보존한다.
    if (postData.status === STATUS_REMOVED) return;
    tx.update(postRef, {
      status: STATUS_REMOVED,
      updatedAt: serverTimestamp(),
    });
  });

  safeLog(logger, functionName, {
    step: 'removed',
    callerHash: safeUidHash(uid),
  });

  return { deleted: true };
}

// ── deleteCommunityComment ─────────────────────────────────────────────────

async function deleteCommunityCommentCore({
  request,
  db,
  HttpsError,
  serverTimestamp,
  logger = null,
} = {}) {
  const functionName = 'deleteCommunityComment';
  const uid = requireAuthUid(request, HttpsError);
  const data = requireExactObject(
    request?.data ?? {},
    ['postId', 'commentId'],
    HttpsError,
  );
  const postId = requireDocId(data.postId, HttpsError);
  const commentId = requireDocId(data.commentId, HttpsError);

  const postRef = db.collection(POSTS_COLLECTION).doc(postId);
  const commentRef = postRef.collection(COMMENTS_SUBCOLLECTION).doc(commentId);

  await db.runTransaction(async (tx) => {
    const postSnap = await tx.get(postRef);
    if (!postSnap.exists) {
      throw makeError(HttpsError, 'not-found', MESSAGES.notFound);
    }
    const commentSnap = await tx.get(commentRef);
    if (!commentSnap.exists) {
      throw makeError(HttpsError, 'not-found', MESSAGES.notFound);
    }
    const commentData = commentSnap.data();
    if (commentData.authorUid !== uid) {
      throw makeError(HttpsError, 'permission-denied', MESSAGES.permissionDenied);
    }
    // 이미 지운 댓글이면 count를 다시 줄이지 않는다(멱등).
    if (commentData.status === STATUS_REMOVED) return;

    tx.update(commentRef, {
      status: STATUS_REMOVED,
      updatedAt: serverTimestamp(),
    });
    const current = safeCount(postSnap.data().commentCount);
    tx.update(postRef, { commentCount: current > 0 ? current - 1 : 0 });
  });

  safeLog(logger, functionName, {
    step: 'removed',
    callerHash: safeUidHash(uid),
  });

  return { deleted: true };
}

// ── reportCommunityContent ─────────────────────────────────────────────────

/** 같은 신고자·같은 대상이면 항상 같은 문서 id(중복 신고 멱등 처리). */
function communityReportId({ reporterUid, targetType, postId, commentId }) {
  return crypto
    .createHash('sha256')
    .update(`${reporterUid}|${targetType}|${postId}|${commentId}`)
    .digest('hex');
}

async function reportCommunityContentCore({
  request,
  db,
  HttpsError,
  serverTimestamp,
  nowMs = Date.now,
  logger = null,
} = {}) {
  const functionName = 'reportCommunityContent';
  const uid = requireAuthUid(request, HttpsError);
  const data = requireExactObject(
    request?.data ?? {},
    ['targetType', 'postId', 'commentId', 'reason', 'detail'],
    HttpsError,
  );

  const targetType = data.targetType;
  if (!REPORT_TARGET_TYPES.includes(targetType)) {
    throw makeError(HttpsError, 'invalid-argument', MESSAGES.invalidRequest);
  }
  const reason = data.reason;
  if (!REPORT_REASONS.includes(reason)) {
    throw makeError(HttpsError, 'invalid-argument', MESSAGES.invalidRequest);
  }
  const postId = requireDocId(data.postId, HttpsError);

  let commentId = '';
  if (targetType === 'comment') {
    commentId = requireDocId(data.commentId, HttpsError);
  } else if (data.commentId !== undefined && data.commentId !== '') {
    throw makeError(HttpsError, 'invalid-argument', MESSAGES.invalidRequest);
  }

  let detail = '';
  if (data.detail !== undefined && data.detail !== null) {
    if (typeof data.detail !== 'string') {
      throw makeError(HttpsError, 'invalid-argument', MESSAGES.invalidRequest);
    }
    detail = data.detail.trim();
    if (detail.length > REPORT_DETAIL_MAX_LENGTH) {
      throw makeError(HttpsError, 'invalid-argument', MESSAGES.invalidRequest);
    }
  }

  const postRef = db.collection(POSTS_COLLECTION).doc(postId);
  const commentRef = commentId
    ? postRef.collection(COMMENTS_SUBCOLLECTION).doc(commentId)
    : null;
  const reportRef = db
    .collection(REPORTS_COLLECTION)
    .doc(communityReportId({ reporterUid: uid, targetType, postId, commentId }));
  const limitRef = db.collection(WRITE_LIMITS_COLLECTION).doc(uid);
  const now = nowMs();

  await db.runTransaction(async (tx) => {
    const postSnap = await tx.get(postRef);
    if (!postSnap.exists) {
      throw makeError(HttpsError, 'not-found', MESSAGES.notFound);
    }
    let reportedUid = postSnap.data().authorUid;

    if (commentRef) {
      const commentSnap = await tx.get(commentRef);
      if (!commentSnap.exists) {
        throw makeError(HttpsError, 'not-found', MESSAGES.notFound);
      }
      reportedUid = commentSnap.data().authorUid;
    }

    if (typeof reportedUid !== 'string' || reportedUid.length === 0) {
      throw makeError(HttpsError, 'not-found', MESSAGES.notFound);
    }
    if (reportedUid === uid) {
      throw makeError(HttpsError, 'failed-precondition', MESSAGES.invalidRequest);
    }

    const reportSnap = await tx.get(reportRef);
    // 같은 대상 재신고는 새 문서를 만들지 않고 성공 처리한다.
    if (reportSnap.exists) return;

    const limitSnap = await tx.get(limitRef);
    assertWithinRateLimit({
      limitData: limitSnap.exists ? limitSnap.data() : null,
      field: 'lastReportAt',
      cooldownMs: REPORT_COOLDOWN_MS,
      nowMs: now,
      HttpsError,
    });

    // 원문(text)·작성자 프로필은 저장하지 않는다. 운영 검토는 id 참조로 한다.
    tx.set(reportRef, {
      reporterUid: uid,
      reportedUid,
      targetType,
      postId,
      commentId,
      reason,
      ...(detail.length > 0 ? { detail } : {}),
      createdAt: serverTimestamp(),
      schemaVersion: SCHEMA_VERSION,
    });
    tx.set(
      limitRef,
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
    targetType,
    reason,
  });

  // report id·대상 UID는 응답에 넣지 않는다.
  return { reported: true };
}

// ── 회원 탈퇴 수명주기 ─────────────────────────────────────────────────────

/**
 * 탈퇴 사용자의 커뮤니티 콘텐츠 정리(멱등).
 *
 * - 게시물/댓글: soft remove + 작성자 익명화(원문 참조는 운영 검토용으로 남는다)
 * - 반응: 삭제하고 부모 게시물 카운트를 최소 0으로 보정
 * - 신고: reporterUid만 익명 식별자로 교체(대상 신고 문서는 지우지 않는다)
 *
 * authorUid를 익명 식별자로 바꾸므로 재실행 시 같은 문서가 다시 잡히지 않는다.
 */
async function cleanupCommunityContentForUser({
  db,
  uid,
  deletedIdentifier,
  serverTimestamp,
} = {}) {
  if (!db || typeof uid !== 'string' || uid.length === 0) {
    throw new Error('cleanupCommunityContentForUser requires db and uid');
  }
  const anonymousSnapshot = deletedAuthorSnapshot(deletedIdentifier);

  let communityPostsRemoved = 0;
  const postsSnap = await db
    .collection(POSTS_COLLECTION)
    .where('authorUid', '==', uid)
    .get();
  for (const doc of postsSnap.docs || []) {
    await doc.ref.update({
      status: STATUS_REMOVED,
      authorUid: deletedIdentifier,
      authorSnapshot: anonymousSnapshot,
      updatedAt: serverTimestamp(),
    });
    communityPostsRemoved += 1;
  }

  let communityCommentsRemoved = 0;
  const commentsSnap = await db
    .collectionGroup(COMMENTS_SUBCOLLECTION)
    .where('authorUid', '==', uid)
    .get();
  for (const doc of commentsSnap.docs || []) {
    const wasActive = (doc.data() || {}).status === STATUS_ACTIVE;
    await doc.ref.update({
      status: STATUS_REMOVED,
      authorUid: deletedIdentifier,
      authorSnapshot: anonymousSnapshot,
      updatedAt: serverTimestamp(),
    });
    communityCommentsRemoved += 1;

    if (!wasActive) continue;
    const postRef = doc.ref.parent?.parent;
    if (!postRef) continue;
    const postSnap = await postRef.get();
    if (!postSnap.exists) continue;
    const current = safeCount((postSnap.data() || {}).commentCount);
    await postRef.update({ commentCount: current > 0 ? current - 1 : 0 });
  }

  let communityReactionsRemoved = 0;
  const reactionsSnap = await db
    .collectionGroup(REACTIONS_SUBCOLLECTION)
    .where('uid', '==', uid)
    .get();
  for (const doc of reactionsSnap.docs || []) {
    const postRef = doc.ref.parent?.parent;
    await doc.ref.delete();
    communityReactionsRemoved += 1;
    if (!postRef) continue;
    const postSnap = await postRef.get();
    if (!postSnap.exists) continue;
    const current = safeCount((postSnap.data() || {}).reactionCount);
    await postRef.update({ reactionCount: current > 0 ? current - 1 : 0 });
  }

  let communityReportsAnonymized = 0;
  const reportsSnap = await db
    .collection(REPORTS_COLLECTION)
    .where('reporterUid', '==', uid)
    .get();
  for (const doc of reportsSnap.docs || []) {
    await doc.ref.update({
      reporterUid: deletedIdentifier,
      reporterDeleted: true,
    });
    communityReportsAnonymized += 1;
  }

  // uid를 키로 갖는 서버 전용 rate-limit 문서도 함께 정리한다(재실행 안전).
  await db.collection(WRITE_LIMITS_COLLECTION).doc(uid).delete();

  return {
    communityPostsRemoved,
    communityCommentsRemoved,
    communityReactionsRemoved,
    communityReportsAnonymized,
    communityWriteLimitsDeleted: true,
  };
}

module.exports = {
  COMMENT_COOLDOWN_MS,
  COMMENT_TEXT_MAX_LENGTH,
  DELETED_AUTHOR_DISPLAY_NAME,
  FORBIDDEN_TEXT_CODES,
  FORBIDDEN_TEXT_ERROR_CODE,
  MESSAGES,
  POST_COOLDOWN_MS,
  POST_TEXT_MAX_LENGTH,
  REPORT_COOLDOWN_MS,
  REPORT_DETAIL_MAX_LENGTH,
  REPORT_REASONS,
  REPORT_TARGET_TYPES,
  SCHEMA_VERSION,
  buildCommunityAuthorSnapshot,
  cleanupCommunityContentForUser,
  communityReportId,
  createCommunityCommentCore,
  createLoungePostCore,
  deleteCommunityCommentCore,
  deleteCommunityPostCore,
  deletedAuthorSnapshot,
  detectForbiddenCommunityText,
  reportCommunityContentCore,
  toggleCommunityReactionCore,
};
