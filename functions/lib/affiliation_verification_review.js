'use strict';

// Phase 3-3: 직장·학교 소속 인증 수동 검토(admin 전용).
//
// OCR·외부 AI·문서 위변조 자동 판정을 하지 않는다. 운영자가 증빙 이미지를 눈으로
// 확인한 결과(approved/rejected)만 반영한다.
//
// 개인정보 원칙:
// - raw uid / storagePath / institutionName / affiliationDetail을 로그에 남기지
//   않는다(uid hash와 고정 category만).
// - 응답에 uid/type/storagePath/기관명을 담지 않는다.

const crypto = require('crypto');

const REQUEST_SUBCOLLECTION = 'affiliationVerificationRequests';

const TYPES = Object.freeze(['work', 'school']);

const DECISIONS = Object.freeze(['approved', 'rejected']);

const REJECTION_REASONS = Object.freeze([
  'document_not_clear',
  'institution_not_visible',
  'affiliation_not_confirmed',
  'sensitive_info_visible',
  'expired_document',
  'other',
]);

const PROOF_TYPES_BY_TYPE = Object.freeze({
  work: Object.freeze(['employee_id', 'employment_certificate']),
  school: Object.freeze(['student_id', 'enrollment_certificate']),
});

function safeUidHash(uid) {
  return crypto.createHash('sha256').update(String(uid)).digest('hex').slice(0, 8);
}

function makeError(HttpsError, code, message) {
  const error = new HttpsError(code, message);
  error.__affiliationVerificationSafeError = true;
  return error;
}

function isSafeError(error) {
  return error?.__affiliationVerificationSafeError === true;
}

/**
 * verifications map을 5개 키 bool로 정규화한다.
 *
 * 기존 3-key(email/phone/photo) 문서는 work/school이 없으므로 false로 읽는다.
 * 알 수 없는 키는 버린다.
 */
function normalizeVerifications(value) {
  return {
    email: value?.email === true,
    phone: value?.phone === true,
    photo: value?.photo === true,
    work: value?.work === true,
    school: value?.school === true,
  };
}

/** admin custom claim이 있는 호출자만 통과시킨다(developer claim은 불충분). */
function requireAffiliationVerificationAdmin(request, HttpsError) {
  const uid = request?.auth?.uid;
  if (typeof uid !== 'string' || uid.trim() === '') {
    throw makeError(HttpsError, 'unauthenticated', '로그인이 필요합니다.');
  }
  if (request?.auth?.token?.admin !== true) {
    throw makeError(HttpsError, 'permission-denied', '관리자 권한이 필요합니다.');
  }
  return uid;
}

/** 입력값 검증(순수 함수). */
function validateReviewInput(data, HttpsError) {
  const uid = data?.uid;
  if (typeof uid !== 'string' || uid.trim() === '') {
    throw makeError(HttpsError, 'invalid-argument', '대상 uid가 필요합니다.');
  }

  const type = data?.type;
  if (!TYPES.includes(type)) {
    throw makeError(HttpsError, 'invalid-argument', '허용되지 않는 인증 종류입니다.');
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
    return { uid: uid.trim(), type, decision, rejectionReason: rawReason };
  }

  if (rawReason !== null && rawReason !== undefined) {
    throw makeError(HttpsError, 'invalid-argument', '승인에는 반려 사유를 넣을 수 없습니다.');
  }
  return { uid: uid.trim(), type, decision, rejectionReason: null };
}

/**
 * pending 소속 인증 요청 하나를 승인/반려한다.
 *
 * - 승인 시 users/{uid}와 publicProfiles/{uid}의 verifications에서 **해당 type
 *   하나만** true로 바꾸고 email/phone/photo와 반대 affiliation은 보존한다.
 * - 반려는 배지를 건드리지 않는다.
 * - Firestore 처리 후 증빙 이미지를 삭제한다. 삭제 실패·파일 없음은 검토 결과를
 *   되돌리지 않는다.
 */
async function reviewAffiliationVerificationCore({
  request,
  db,
  storageBucket,
  HttpsError,
  serverTimestamp,
  logger,
}) {
  requireAffiliationVerificationAdmin(request, HttpsError);
  const { uid, type, decision, rejectionReason } = validateReviewInput(
    request?.data,
    HttpsError,
  );
  const uidHash = safeUidHash(uid);

  let storagePath = null;
  try {
    const userRef = db.collection('users').doc(uid);
    const requestRef = userRef.collection(REQUEST_SUBCOLLECTION).doc(type);
    const publicRef = db.collection('publicProfiles').doc(uid);

    storagePath = await db.runTransaction(async (transaction) => {
      const requestSnap = await transaction.get(requestRef);
      if (!requestSnap.exists) {
        throw makeError(HttpsError, 'not-found', '인증 요청을 찾을 수 없습니다.');
      }

      const data = requestSnap.data() || {};
      if (data.uid !== uid || data.type !== type) {
        throw makeError(HttpsError, 'failed-precondition', '요청 정보가 올바르지 않습니다.');
      }
      if (data.status !== 'pending') {
        throw makeError(HttpsError, 'failed-precondition', '이미 검토된 요청입니다.');
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

        // 승인 대상 배지 하나만 켜고 나머지(email/phone/photo/반대 affiliation)는
        // 현재 값을 그대로 보존한다.
        const userVerifications = {
          ...normalizeVerifications(userSnap.data()?.verifications),
          [type]: true,
        };
        const publicVerifications = {
          ...normalizeVerifications(publicSnap.data()?.verifications),
          [type]: true,
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
        `event=affiliation_verification_review uidHash=${uidHash} type=${type} result=error`,
      );
    }
    throw makeError(
      HttpsError,
      'internal',
      '인증을 처리하지 못했습니다. 잠시 후 다시 시도해주세요.',
    );
  }

  // 검토가 끝난 증빙 이미지는 보관하지 않는다. 삭제 실패는 결과를 되돌리지 않는다.
  let fileDeleted = false;
  try {
    await storageBucket.file(storagePath).delete();
    fileDeleted = true;
  } catch (error) {
    const code = error?.code === 404 ? 'missing' : 'failed';
    if (logger?.warn) {
      logger.warn(
        `event=affiliation_verification_cleanup uidHash=${uidHash} type=${type} result=${code}`,
      );
    }
  }

  if (logger?.log) {
    logger.log(
      `event=affiliation_verification_review uidHash=${uidHash} type=${type} decision=${decision} cleanup=${
        fileDeleted ? 'deleted' : 'skipped'
      }`,
    );
  }

  return { status: decision };
}

module.exports = {
  DECISIONS,
  PROOF_TYPES_BY_TYPE,
  REJECTION_REASONS,
  REQUEST_SUBCOLLECTION,
  TYPES,
  normalizeVerifications,
  requireAffiliationVerificationAdmin,
  reviewAffiliationVerificationCore,
  safeUidHash,
  validateReviewInput,
};
