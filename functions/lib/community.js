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
const SURFACE_FEED = 'feed';
/** 상호작용(댓글·공감·신고·삭제)을 허용하는 표면. */
const INTERACTABLE_SURFACES = Object.freeze([SURFACE_LOUNGE, SURFACE_FEED]);
const VISIBILITY_AUTHENTICATED = 'authenticated';
const STATUS_ACTIVE = 'active';
const STATUS_REMOVED = 'removed';
const REACTION_TYPE_LIKE = 'like';

const POST_TEXT_MAX_LENGTH = 1000;
const COMMENT_TEXT_MAX_LENGTH = 500;
const REPORT_DETAIL_MAX_LENGTH = 500;
const DISPLAY_NAME_MAX_LENGTH = 40;
const PHOTO_URL_MAX_LENGTH = 2048;

// ── Feed 이미지 제약(Phase 4-3) ────────────────────────────────────────────
//
// 이미지의 download URL·token은 Firestore에 저장하지 않는다. 내부 Storage
// 경로만 저장하고, 표시할 때 인증된 사용자가 bytes를 읽는다.

const FEED_STORAGE_ROOT = 'communityFeed';
const FEED_MIN_IMAGES = 1;
const FEED_MAX_IMAGES = 4;
const FEED_IMAGE_PATH_MAX_LENGTH = 512;
const FEED_MAX_IMAGE_BYTES = 5 * 1024 * 1024;
const FEED_MAX_TOTAL_BYTES = 20 * 1024 * 1024;

/** HEIC/HEIF는 기기 간 decode 호환성 때문에 받지 않는다. */
const FEED_ALLOWED_EXTENSIONS = Object.freeze(['jpg', 'jpeg', 'png']);
const FEED_ALLOWED_CONTENT_TYPES = Object.freeze(['image/jpeg', 'image/png']);

/** Firestore auto-ID 형식(20자리 영문·숫자)만 허용한다. */
const AUTO_ID_PATTERN = /^[A-Za-z0-9]{20}$/;

/** 이미지 파일명: {imageId}.{ext} 하나. 하위 경로·상대 경로는 허용하지 않는다. */
const FEED_IMAGE_FILE_NAME_PATTERN = /^[A-Za-z0-9_-]{1,64}\.(jpg|jpeg|png)$/;

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
  invalidImages: '사진을 다시 선택한 뒤 올려주세요.',
  alreadyExists: '이미 올라간 글이에요.',
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

/**
 * 클라이언트가 미리 만든 문서 id. Firestore auto-ID 형식만 허용한다.
 *
 * Storage 경로에 그대로 들어가므로 임의 문자열을 받지 않는다(경로 조작·추측
 * 가능한 짧은 id 방지).
 */
function requireAutoId(value, HttpsError) {
  if (typeof value !== 'string' || !AUTO_ID_PATTERN.test(value)) {
    throw makeError(HttpsError, 'invalid-argument', MESSAGES.invalidRequest);
  }
  return value;
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

/** 댓글·공감·신고·삭제를 받을 수 있는 상태인지(lounge/feed 공통). */
function isInteractablePost(data) {
  return (
    data != null &&
    INTERACTABLE_SURFACES.includes(data.surface) &&
    data.status === STATUS_ACTIVE &&
    data.visibility === VISIBILITY_AUTHENTICATED
  );
}

// ── Feed 이미지 경로 검증 ──────────────────────────────────────────────────

/** communityFeed/{uid}/{postId}/ (순수 함수). */
function feedImagePathPrefix(uid, postId) {
  return `${FEED_STORAGE_ROOT}/${uid}/${postId}/`;
}

/**
 * 클라이언트가 보낸 imagePaths를 canonical 목록으로 검증한다(순수 함수).
 *
 * 모든 경로는 **호출자 본인의 uid + 이번 postId** 아래여야 한다. 다른
 * 사용자의 파일이나 다른 게시물의 파일을 자기 글에 붙일 수 없다.
 */
function normalizeFeedImagePaths({ value, uid, postId, HttpsError }) {
  if (!Array.isArray(value)) {
    throw makeError(HttpsError, 'invalid-argument', MESSAGES.invalidImages);
  }
  if (value.length < FEED_MIN_IMAGES || value.length > FEED_MAX_IMAGES) {
    throw makeError(HttpsError, 'invalid-argument', MESSAGES.invalidImages);
  }

  const prefix = feedImagePathPrefix(uid, postId);
  const paths = [];
  for (const item of value) {
    if (typeof item !== 'string') {
      throw makeError(HttpsError, 'invalid-argument', MESSAGES.invalidImages);
    }
    if (item.length === 0 || item.length > FEED_IMAGE_PATH_MAX_LENGTH) {
      throw makeError(HttpsError, 'invalid-argument', MESSAGES.invalidImages);
    }
    if (!item.startsWith(prefix)) {
      throw makeError(HttpsError, 'invalid-argument', MESSAGES.invalidImages);
    }
    const fileName = item.slice(prefix.length);
    if (!FEED_IMAGE_FILE_NAME_PATTERN.test(fileName)) {
      throw makeError(HttpsError, 'invalid-argument', MESSAGES.invalidImages);
    }
    // 같은 파일을 여러 번 넣어 개수 제한을 우회하지 못하게 한다.
    if (paths.includes(item)) {
      throw makeError(HttpsError, 'invalid-argument', MESSAGES.invalidImages);
    }
    paths.push(item);
  }
  return paths;
}

/**
 * 업로드된 object의 실제 metadata를 확인한다.
 *
 * 클라이언트가 보낸 크기·형식을 믿지 않는다. 파일이 없거나 비었거나 형식·
 * 용량이 어긋나면 거부한다. 경로·metadata 전체는 오류에 담지 않는다.
 */
async function assertFeedImageObjects({ bucket, paths, HttpsError }) {
  if (!bucket || typeof bucket.file !== 'function') {
    throw makeError(HttpsError, 'internal', MESSAGES.invalidRequest);
  }

  let totalBytes = 0;
  for (const path of paths) {
    let metadata;
    try {
      const [meta] = await bucket.file(path).getMetadata();
      metadata = meta;
    } catch (_) {
      // 존재하지 않거나 읽지 못하는 object는 모두 같은 거부로 취급한다.
      throw makeError(HttpsError, 'invalid-argument', MESSAGES.invalidImages);
    }

    const size = Number(metadata?.size ?? 0);
    if (!Number.isFinite(size) || size <= 0 || size > FEED_MAX_IMAGE_BYTES) {
      throw makeError(HttpsError, 'invalid-argument', MESSAGES.invalidImages);
    }
    if (!FEED_ALLOWED_CONTENT_TYPES.includes(metadata?.contentType)) {
      throw makeError(HttpsError, 'invalid-argument', MESSAGES.invalidImages);
    }
    totalBytes += size;
  }

  if (totalBytes > FEED_MAX_TOTAL_BYTES) {
    throw makeError(HttpsError, 'invalid-argument', MESSAGES.invalidImages);
  }
  return { totalBytes };
}

/**
 * 게시물로 이어지지 못한 업로드 object를 best-effort 삭제한다.
 *
 * 이미 검증이 끝난(=본인 uid + 이번 postId prefix) 경로만 지운다. 삭제 실패는
 * 원래 오류를 덮지 않고 고정 category로만 남긴다(raw path·UID 금지).
 */
async function cleanupFeedImageObjects({ bucket, paths, logger, functionName, uid }) {
  if (!bucket || !Array.isArray(paths) || paths.length === 0) return 0;
  let deleted = 0;
  let failed = 0;
  for (const path of paths) {
    try {
      await bucket.file(path).delete();
      deleted += 1;
    } catch (_) {
      // 이미 없으면 성공으로 본다(개수만 다르게 집계한다).
      failed += 1;
    }
  }
  if (failed > 0) {
    safeLog(logger, functionName, {
      step: 'draft_cleanup_partial',
      callerHash: safeUidHash(uid),
      imageCount: paths.length,
    });
  }
  return deleted;
}

/** 로그에 남길 용량 구간(정확한 byte 수를 남기지 않는다). */
function byteBucketOf(totalBytes) {
  if (!Number.isFinite(totalBytes) || totalBytes <= 0) return 'unknown';
  const mb = totalBytes / (1024 * 1024);
  if (mb <= 1) return 'le_1mb';
  if (mb <= 5) return 'le_5mb';
  if (mb <= 10) return 'le_10mb';
  return 'le_20mb';
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

// ── createFeedPost ─────────────────────────────────────────────────────────

/**
 * 이미지 게시물 작성(Phase 4-3).
 *
 * 클라이언트가 postId를 먼저 만들어 그 경로로 이미지를 올린 뒤 호출한다.
 * 서버는 경로 소유자·object metadata를 다시 확인하고, 실패하면 아직 글로
 * 이어지지 않은 업로드 파일을 best-effort로 정리한다.
 *
 * imageUrls는 **항상 빈 배열**로 저장한다(download URL 미저장 계약).
 */
async function createFeedPostCore({
  request,
  db,
  bucket,
  HttpsError,
  serverTimestamp,
  nowMs = Date.now,
  logger = null,
} = {}) {
  const functionName = 'createFeedPost';
  const uid = requireAuthUid(request, HttpsError);
  const data = requireExactObject(
    request?.data ?? {},
    ['postId', 'text', 'imagePaths'],
    HttpsError,
  );

  const postId = requireAutoId(data.postId, HttpsError);
  const text = normalizeBodyText(data.text, POST_TEXT_MAX_LENGTH, HttpsError);

  // 경로 검증이 끝나야 정리 대상으로 삼을 수 있다(임의 경로 삭제 금지).
  const imagePaths = normalizeFeedImagePaths({
    value: data.imagePaths,
    uid,
    postId,
    HttpsError,
  });

  // 여기서부터의 실패는 "업로드는 됐지만 글은 못 만든" 상태이므로 정리한다.
  // 금지 텍스트도 이 안에서 확인해, 거부된 글의 이미지가 남지 않게 한다.
  let created = false;
  let totalBytes = 0;
  try {
    assertAllowedCommunityText({ text, uid, functionName, logger, HttpsError });

    const metadata = await assertFeedImageObjects({
      bucket,
      paths: imagePaths,
      HttpsError,
    });
    totalBytes = metadata.totalBytes;

    const authorSnapshot = await loadAuthorSnapshot({ db, uid, HttpsError });

    const postRef = db.collection(POSTS_COLLECTION).doc(postId);
    const limitRef = db.collection(WRITE_LIMITS_COLLECTION).doc(uid);
    const now = nowMs();

    await db.runTransaction(async (tx) => {
      const existing = await tx.get(postRef);
      if (existing.exists) {
        const existingData = existing.data() || {};
        // 응답만 유실된 재호출이면 같은 글을 그대로 성공 처리한다(멱등).
        if (
          existingData.authorUid === uid &&
          existingData.surface === SURFACE_FEED
        ) {
          return;
        }
        throw makeError(HttpsError, 'already-exists', MESSAGES.alreadyExists);
      }

      const limitSnap = await tx.get(limitRef);
      assertWithinRateLimit({
        limitData: limitSnap.exists ? limitSnap.data() : null,
        field: 'lastPostAt',
        cooldownMs: POST_COOLDOWN_MS,
        nowMs: now,
        HttpsError,
      });

      tx.set(postRef, {
        surface: SURFACE_FEED,
        authorUid: uid,
        authorSnapshot,
        text,
        // download URL은 어떤 경우에도 저장하지 않는다.
        imageUrls: [],
        imagePaths,
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
    created = true;
  } catch (error) {
    if (!created) {
      // 정리 실패가 원래 오류를 덮지 않게 한다.
      await cleanupFeedImageObjects({
        bucket,
        paths: imagePaths,
        logger,
        functionName,
        uid,
      });
    }
    throw error;
  }

  safeLog(logger, functionName, {
    step: 'created',
    callerHash: safeUidHash(uid),
    imageCount: imagePaths.length,
    byteBucket: byteBucketOf(totalBytes),
  });

  // 경로·본문·작성자 정보는 응답에 담지 않는다.
  return { postId };
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
  bucket = null,
  HttpsError,
  serverTimestamp,
  logger = null,
} = {}) {
  const functionName = 'deleteCommunityPost';
  const uid = requireAuthUid(request, HttpsError);
  const data = requireExactObject(request?.data ?? {}, ['postId'], HttpsError);
  const postId = requireDocId(data.postId, HttpsError);

  const postRef = db.collection(POSTS_COLLECTION).doc(postId);

  // soft delete가 끝난 뒤에만 실제 파일을 지운다(문서 상태가 먼저다).
  let imagePathsToDelete = [];

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
    // 남아 있을 수 있는 이미지 파일은 아래에서 다시 지운다(멱등).
    imagePathsToDelete = safeOwnedFeedImagePaths({
      postData,
      uid,
      postId,
    });
    if (postData.status === STATUS_REMOVED) return;
    tx.update(postRef, {
      status: STATUS_REMOVED,
      updatedAt: serverTimestamp(),
    });
  });

  // status가 removed로 바뀌는 순간 Storage Rules가 read를 막고, 여기서 실제
  // 파일까지 지운다. 파일 삭제 실패는 soft delete를 되돌리지 않는다.
  let imagesDeleted = 0;
  if (imagePathsToDelete.length > 0) {
    imagesDeleted = await cleanupFeedImageObjects({
      bucket,
      paths: imagePathsToDelete,
      logger,
      functionName,
      uid,
    });
  }

  safeLog(logger, functionName, {
    step: 'removed',
    callerHash: safeUidHash(uid),
    imageCount: imagesDeleted,
  });

  return { deleted: true };
}

/**
 * 게시물 문서에 저장된 imagePaths 중 **본인 소유·이번 postId** 경로만 고른다.
 *
 * 문서가 어떤 이유로든 다른 경로를 담고 있어도 그 파일은 건드리지 않는다.
 */
function safeOwnedFeedImagePaths({ postData, uid, postId }) {
  const raw = postData?.imagePaths;
  if (!Array.isArray(raw)) return [];
  const prefix = feedImagePathPrefix(uid, postId);
  return raw.filter(
    (path) =>
      typeof path === 'string' &&
      path.length > 0 &&
      path.length <= FEED_IMAGE_PATH_MAX_LENGTH &&
      path.startsWith(prefix) &&
      FEED_IMAGE_FILE_NAME_PATTERN.test(path.slice(prefix.length)),
  );
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
  FEED_MAX_IMAGES,
  FEED_MAX_IMAGE_BYTES,
  FEED_MAX_TOTAL_BYTES,
  FEED_MIN_IMAGES,
  FEED_STORAGE_ROOT,
  SURFACE_FEED,
  SURFACE_LOUNGE,
  createFeedPostCore,
  feedImagePathPrefix,
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
