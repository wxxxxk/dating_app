'use strict';

// Phase 3-2: 사진 인증 수동 검토(admin 전용).
//
// 자동 얼굴 인식·생체 판정·유사도 점수를 만들지 않는다. 운영자가 프로필 사진과
// 인증 사진을 눈으로 비교한 결과(approved/rejected)만 반영한다.
//
// 개인정보 원칙:
// - raw uid / storagePath / 이미지 URL을 로그에 남기지 않는다(uid hash만).
// - 응답에 storagePath나 사용자 데이터를 담지 않는다.

const crypto = require('crypto');

const REQUEST_COLLECTION = 'photoVerificationRequests';

const DECISIONS = Object.freeze(['approved', 'rejected']);

const REJECTION_REASONS = Object.freeze([
  'face_not_clear',
  'photo_mismatch',
  'face_covered',
  'image_quality',
  'other',
]);

function safeUidHash(uid) {
  return crypto.createHash('sha256').update(String(uid)).digest('hex').slice(0, 8);
}

function makeError(HttpsError, code, message) {
  const error = new HttpsError(code, message);
  error.__photoVerificationSafeError = true;
  return error;
}

function isSafeError(error) {
  return error?.__photoVerificationSafeError === true;
}

/** verifications map을 3개 키 bool로 정규화한다(다른 키는 버린다). */
function normalizeVerifications(value) {
  return {
    email: value?.email === true,
    phone: value?.phone === true,
    photo: value?.photo === true,
  };
}

/** admin custom claim이 있는 호출자만 통과시킨다. */
function requirePhotoVerificationAdmin(request, HttpsError) {
  const uid = request?.auth?.uid;
  if (typeof uid !== 'string' || uid.trim() === '') {
    throw makeError(HttpsError, 'unauthenticated', '로그인이 필요합니다.');
  }
  if (request?.auth?.token?.admin !== true) {
    throw makeError(HttpsError, 'permission-denied', '관리자 권한이 필요합니다.');
  }
  return uid;
}

/** 입력값 검증(순수 함수). 잘못된 입력은 invalid-argument로 거부한다. */
function validateReviewInput(data, HttpsError) {
  const uid = data?.uid;
  if (typeof uid !== 'string' || uid.trim() === '') {
    throw makeError(HttpsError, 'invalid-argument', '대상 uid가 필요합니다.');
  }

  const decision = data?.decision;
  if (!DECISIONS.includes(decision)) {
    throw makeError(HttpsError, 'invalid-argument', '허용되지 않는 검토 결과입니다.');
  }

  const rawReason = data?.rejectionReason;
  if (decision === 'rejected') {
    if (!REJECTION_REASONS.includes(rawReason)) {
      throw makeError(HttpsError, 'invalid-argument', '허용되지 않는 반려 사유입니다.');
    }
    return { uid: uid.trim(), decision, rejectionReason: rawReason };
  }

  // 승인에는 반려 사유를 담을 수 없다.
  if (rawReason !== null && rawReason !== undefined) {
    throw makeError(HttpsError, 'invalid-argument', '승인에는 반려 사유를 넣을 수 없습니다.');
  }
  return { uid: uid.trim(), decision, rejectionReason: null };
}

/**
 * pending 요청 하나를 승인/반려한다.
 *
 * - 승인 시 users/{uid} 와 publicProfiles/{uid} 의 verifications.photo만 true로
 *   바꾸고 email/phone 등 기존 값은 보존한다.
 * - 반려는 배지를 건드리지 않는다.
 * - Firestore 처리가 끝난 뒤 인증 사진을 Storage에서 삭제한다. 삭제 실패나
 *   파일 없음은 검토 결과를 되돌리지 않는다.
 */
async function reviewPhotoVerificationCore({
  request,
  db,
  storageBucket,
  HttpsError,
  serverTimestamp,
  logger,
}) {
  requirePhotoVerificationAdmin(request, HttpsError);
  const { uid, decision, rejectionReason } = validateReviewInput(
    request?.data,
    HttpsError,
  );
  const uidHash = safeUidHash(uid);

  let storagePath = null;
  try {
    const requestRef = db.collection(REQUEST_COLLECTION).doc(uid);
    const userRef = db.collection('users').doc(uid);
    const publicRef = db.collection('publicProfiles').doc(uid);

    storagePath = await db.runTransaction(async (transaction) => {
      const requestSnap = await transaction.get(requestRef);
      if (!requestSnap.exists) {
        throw makeError(HttpsError, 'not-found', '사진 인증 요청을 찾을 수 없습니다.');
      }

      const data = requestSnap.data() || {};
      if (data.uid !== uid) {
        throw makeError(HttpsError, 'failed-precondition', '요청 정보가 올바르지 않습니다.');
      }
      if (data.status !== 'pending') {
        throw makeError(
          HttpsError,
          'failed-precondition',
          '이미 검토된 요청입니다.',
        );
      }
      if (typeof data.storagePath !== 'string' || data.storagePath.trim() === '') {
        throw makeError(HttpsError, 'failed-precondition', '요청 정보가 올바르지 않습니다.');
      }

      const now = serverTimestamp();
      transaction.update(requestRef, {
        status: decision,
        reviewedAt: now,
        updatedAt: now,
        rejectionReason: decision === 'rejected' ? rejectionReason : null,
      });

      if (decision === 'approved') {
        // 배지는 서버만 쓸 수 있다. 기존 email/phone 값은 반드시 보존한다.
        const [userSnap, publicSnap] = await Promise.all([
          transaction.get(userRef),
          transaction.get(publicRef),
        ]);
        if (!userSnap.exists || !publicSnap.exists) {
          throw makeError(
            HttpsError,
            'failed-precondition',
            '프로필 문서를 찾을 수 없습니다.',
          );
        }

        const userVerifications = {
          ...normalizeVerifications(userSnap.data()?.verifications),
          photo: true,
        };
        const publicVerifications = {
          ...normalizeVerifications(publicSnap.data()?.verifications),
          photo: true,
        };
        transaction.update(userRef, { verifications: userVerifications });
        transaction.update(publicRef, {
          verifications: publicVerifications,
          profileUpdatedAt: now,
        });
      }

      return data.storagePath;
    });
  } catch (error) {
    if (isSafeError(error)) throw error;
    if (logger?.error) {
      logger.error(
        `event=photo_verification_review uidHash=${uidHash} result=error`,
      );
    }
    throw makeError(
      HttpsError,
      'internal',
      '사진 인증을 처리하지 못했습니다. 잠시 후 다시 시도해주세요.',
    );
  }

  // 검토가 끝난 인증 사진은 보관하지 않는다. 삭제 실패는 결과를 되돌리지 않는다.
  let fileDeleted = false;
  try {
    await storageBucket.file(storagePath).delete();
    fileDeleted = true;
  } catch (error) {
    // 이미 삭제된 파일(404)도 정상으로 본다. 경로/URL은 로그에 남기지 않는다.
    const code = error?.code === 404 ? 'missing' : 'failed';
    if (logger?.warn) {
      logger.warn(
        `event=photo_verification_cleanup uidHash=${uidHash} result=${code}`,
      );
    }
  }

  if (logger?.log) {
    logger.log(
      `event=photo_verification_review uidHash=${uidHash} decision=${decision} cleanup=${
        fileDeleted ? 'deleted' : 'skipped'
      }`,
    );
  }

  return { status: decision };
}

module.exports = {
  DECISIONS,
  REJECTION_REASONS,
  REQUEST_COLLECTION,
  normalizeVerifications,
  requirePhotoVerificationAdmin,
  reviewPhotoVerificationCore,
  safeUidHash,
  validateReviewInput,
};
