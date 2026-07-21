'use strict';

const crypto = require('crypto');

const VERIFICATION_KEYS = Object.freeze([
  'email',
  'phone',
  'photo',
  'work',
  'school',
]);
const DISALLOWED_REQUEST_KEYS = Object.freeze([
  'uid',
  'targetUid',
  'userId',
  'profileUid',
  'email',
  'phone',
  'phoneNumber',
  'verified',
  'emailVerified',
  'phoneVerified',
  'photoVerified',
  'verifications',
]);

function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function safeUidHash(uid) {
  return crypto.createHash('sha256').update(String(uid)).digest('hex').slice(0, 8);
}

// Firebase Auth로 확인 가능한 배지는 email/phone뿐이다. photo는 사진 인증
// (Phase 3-2), work/school은 소속 인증(Phase 3-3) 수동 검토가 소유하므로 여기서
// 파생하지 않고, 동기화 시 기존 저장값을 그대로 보존한다.
function deriveAuthVerificationBadges(userRecord) {
  const email =
    typeof userRecord?.email === 'string' &&
    userRecord.email.trim() !== '' &&
    userRecord.emailVerified === true;
  const providerData = Array.isArray(userRecord?.providerData)
    ? userRecord.providerData
    : [];
  const hasPhoneProvider = providerData.some(
    (provider) => provider?.providerId === 'phone',
  );
  const phone =
    typeof userRecord?.phoneNumber === 'string' &&
    userRecord.phoneNumber.trim() !== '' &&
    hasPhoneProvider;
  return { email, phone, photo: false, work: false, school: false };
}

// 기존 3-key(email/phone/photo) 문서는 work/school이 없으므로 false로 읽는다.
function normalizeVerificationMap(value) {
  return {
    email: value?.email === true,
    phone: value?.phone === true,
    photo: value?.photo === true,
    work: value?.work === true,
    school: value?.school === true,
  };
}

function verificationsEqual(left, right) {
  const a = normalizeVerificationMap(left);
  const b = normalizeVerificationMap(right);
  return VERIFICATION_KEYS.every((key) => a[key] === b[key]);
}

function makeHttpsError(HttpsError, code, message) {
  const error = new HttpsError(code, message);
  error.__authBadgeSafeError = true;
  return error;
}

function isSafeHttpsError(error) {
  return error?.__authBadgeSafeError === true;
}

function validateRequestData(data, HttpsError) {
  if (data === undefined || data === null) return;
  if (!isPlainObject(data)) {
    throw makeHttpsError(
      HttpsError,
      'invalid-argument',
      '이 함수는 입력값을 받지 않습니다.',
    );
  }
  const keys = Object.keys(data);
  if (keys.length === 0) return;
  const hasTargetOrTrustedInput = keys.some((key) =>
    DISALLOWED_REQUEST_KEYS.includes(key),
  );
  throw makeHttpsError(
    HttpsError,
    'invalid-argument',
    hasTargetOrTrustedInput
      ? '인증 배지 동기화 대상은 현재 로그인 사용자로만 고정됩니다.'
      : '이 함수는 입력값을 받지 않습니다.',
  );
}

async function syncAuthVerificationBadgesCore({
  request,
  auth,
  db,
  HttpsError,
  serverTimestamp,
  logger,
}) {
  const uid = request?.auth?.uid;
  if (typeof uid !== 'string' || uid.trim() === '') {
    throw makeHttpsError(HttpsError, 'unauthenticated', '로그인이 필요합니다.');
  }

  validateRequestData(request.data, HttpsError);
  const uidHash = safeUidHash(uid);

  try {
    const userRecord = await auth.getUser(uid);
    const verifications = deriveAuthVerificationBadges(userRecord);
    const userRef = db.collection('users').doc(uid);
    const publicRef = db.collection('publicProfiles').doc(uid);

    const result = await db.runTransaction(async (transaction) => {
      const [userSnap, publicSnap] = await Promise.all([
        transaction.get(userRef),
        transaction.get(publicRef),
      ]);

      if (!userSnap.exists) {
        throw makeHttpsError(
          HttpsError,
          'failed-precondition',
          '프로필 문서를 먼저 생성해야 합니다.',
        );
      }
      if (!publicSnap.exists) {
        throw makeHttpsError(
          HttpsError,
          'failed-precondition',
          '공개 프로필 문서를 먼저 생성해야 합니다.',
        );
      }

      const currentUserVerifications = normalizeVerificationMap(
        userSnap.data()?.verifications,
      );
      const currentPublicVerifications = normalizeVerificationMap(
        publicSnap.data()?.verifications,
      );
      // photo/work/school은 이 함수의 소유가 아니다(각각 사진 인증·소속 인증
      // 수동 검토가 소유). 승인된 배지를 덮어쓰지 않도록 비공개 프로필에
      // 저장된 현재 값을 그대로 유지하고, Auth 기반 email/phone만 교정한다.
      const merged = {
        ...verifications,
        photo: currentUserVerifications.photo,
        work: currentUserVerifications.work,
        school: currentUserVerifications.school,
      };
      const usersChanged = !verificationsEqual(currentUserVerifications, merged);
      const publicChanged = !verificationsEqual(
        currentPublicVerifications,
        merged,
      );

      if (!usersChanged && !publicChanged) {
        return { changed: false, writesPerformed: 0, verifications: merged };
      }

      transaction.update(userRef, { verifications: merged });
      const publicUpdate = { verifications: merged };
      if (publicChanged && typeof serverTimestamp === 'function') {
        publicUpdate.profileUpdatedAt = serverTimestamp();
      }
      transaction.update(publicRef, publicUpdate);
      return { changed: true, writesPerformed: 2, verifications: merged };
    });

    if (logger?.log) {
      logger.log(
        `event=auth_badge_sync uidHash=${uidHash} result=${
          result.changed ? 'changed' : 'unchanged'
        }`,
      );
    }

    return {
      verifications: result.verifications,
      changed: result.changed,
      writesPerformed: result.writesPerformed,
    };
  } catch (error) {
    if (isSafeHttpsError(error)) throw error;
    if (logger?.error) {
      logger.error(`event=auth_badge_sync uidHash=${uidHash} result=error`);
    }
    throw makeHttpsError(
      HttpsError,
      'internal',
      '인증 상태를 동기화하지 못했습니다. 잠시 후 다시 시도해주세요.',
    );
  }
}

module.exports = {
  deriveAuthVerificationBadges,
  normalizeVerificationMap,
  safeUidHash,
  syncAuthVerificationBadgesCore,
};
