'use strict';

// Phase 3-4: 연락처 기반 지인 피하기.
//
// 개인정보 원칙:
// - 클라이언트는 정규화된 전화번호의 SHA-256 digest만 보낸다(원문·이름 미전송).
// - 서버는 digest를 그대로 저장하지 않고 secret pepper로 HMAC한 값만 저장한다.
// - 로그에는 uid hash와 개수만 남긴다. digest/HMAC/대상 UID/pairId 금지.
// - 응답에는 개수만 담는다.

const crypto = require('crypto');

const PRIVATE_IDENTIFIERS_COLLECTION = 'privatePhoneIdentifiers';
const PAIRS_COLLECTION = 'contactAvoidancePairs';
const SYNC_LIMITS_COLLECTION = 'contactAvoidanceSyncLimits';
const OWNER_MATCHES_SUBCOLLECTION = 'contactAvoidanceMatches';
const SETTINGS_SUBCOLLECTION = 'contactAvoidanceSettings';
const SETTINGS_DOC_ID = 'current';

const MAX_CONTACT_DIGESTS = 2000;
/** Firestore `in` 쿼리 최대 값 개수. */
const IN_QUERY_CHUNK = 30;
/** batch write 상한(500)보다 여유 있게 잡는다. */
const BATCH_CHUNK = 400;
/** 재동기화 최소 간격. */
const SYNC_COOLDOWN_MS = 30 * 1000;

const DIGEST_PATTERN = /^[0-9a-f]{64}$/;

function safeUidHash(uid) {
  return crypto.createHash('sha256').update(String(uid)).digest('hex').slice(0, 8);
}

function makeError(HttpsError, code, message) {
  const error = new HttpsError(code, message);
  error.__contactAvoidanceSafeError = true;
  return error;
}

function isSafeError(error) {
  return error?.__contactAvoidanceSafeError === true;
}

/** 전화번호 digest → 저장용 HMAC. secret 없이는 역산/대조가 불가능하다. */
function contactHashFromDigest(digest, pepper) {
  return crypto
    .createHmac('sha256', String(pepper))
    .update(String(digest))
    .digest('hex');
}

/** Firebase Auth 전화번호(E.164) → 저장용 contactHash. */
function contactHashFromPhoneNumber(phoneNumber, pepper) {
  const normalized = normalizePhoneNumber(phoneNumber);
  if (!normalized) return null;
  const digest = crypto.createHash('sha256').update(normalized).digest('hex');
  return contactHashFromDigest(digest, pepper);
}

/**
 * Auth phoneNumber 정규화. Firebase Auth는 이미 E.164로 저장하므로 표기 문자만
 * 제거하고 형식을 확인한다(클라이언트 정규화 결과와 같은 형태여야 한다).
 */
function normalizePhoneNumber(raw) {
  if (typeof raw !== 'string') return null;
  const value = raw.replace(/[\s\-().]/g, '');
  if (!/^\+[0-9]{8,15}$/.test(value)) return null;
  return value;
}

/** 두 uid에 대해 순서와 무관하게 같은 pairId를 만든다. */
function contactAvoidancePairId(uidA, uidB) {
  const [first, second] = [String(uidA), String(uidB)].sort();
  return crypto.createHash('sha256').update(`${first}|${second}`).digest('hex');
}

function sortedParticipants(uidA, uidB) {
  return [String(uidA), String(uidB)].sort();
}

/** 입력 검증(순수 함수). 잘못된 입력은 invalid-argument로 거부한다. */
function validateSyncInput(data, HttpsError) {
  if (data === null || typeof data !== 'object' || Array.isArray(data)) {
    throw makeError(HttpsError, 'invalid-argument', '요청 형식이 올바르지 않습니다.');
  }

  const allowedKeys = ['enabled', 'contactDigests'];
  for (const key of Object.keys(data)) {
    if (!allowedKeys.includes(key)) {
      throw makeError(HttpsError, 'invalid-argument', '요청 형식이 올바르지 않습니다.');
    }
  }

  if (typeof data.enabled !== 'boolean') {
    throw makeError(HttpsError, 'invalid-argument', '요청 형식이 올바르지 않습니다.');
  }

  const rawDigests = data.contactDigests;
  if (rawDigests !== undefined && !Array.isArray(rawDigests)) {
    throw makeError(HttpsError, 'invalid-argument', '요청 형식이 올바르지 않습니다.');
  }
  const list = Array.isArray(rawDigests) ? rawDigests : [];

  if (!data.enabled) {
    if (list.length > 0) {
      throw makeError(HttpsError, 'invalid-argument', '요청 형식이 올바르지 않습니다.');
    }
    return { enabled: false, digests: [] };
  }

  if (list.length > MAX_CONTACT_DIGESTS) {
    throw makeError(
      HttpsError,
      'invalid-argument',
      '동기화할 수 있는 연락처 수를 초과했습니다.',
    );
  }

  const digests = new Set();
  for (const value of list) {
    if (typeof value !== 'string' || !DIGEST_PATTERN.test(value)) {
      throw makeError(HttpsError, 'invalid-argument', '요청 형식이 올바르지 않습니다.');
    }
    digests.add(value);
  }
  return { enabled: true, digests: [...digests] };
}

/** 전화 인증 완료 사용자만 지인 피하기를 쓸 수 있다(UI만 믿지 않는다). */
async function requirePhoneVerifiedUser({ uid, auth, db, HttpsError }) {
  let userRecord;
  try {
    userRecord = await auth.getUser(uid);
  } catch (_) {
    throw makeError(HttpsError, 'failed-precondition', '전화 인증이 필요합니다.');
  }
  const phoneNumber = normalizePhoneNumber(userRecord?.phoneNumber);
  if (!phoneNumber) {
    throw makeError(HttpsError, 'failed-precondition', '전화 인증이 필요합니다.');
  }

  const userSnap = await db.collection('users').doc(uid).get();
  if (userSnap.data()?.verifications?.phone !== true) {
    throw makeError(HttpsError, 'failed-precondition', '전화 인증이 필요합니다.');
  }
  return phoneNumber;
}

/** 재동기화 cooldown. 끄기(enabled=false)는 안전을 위해 항상 허용한다. */
async function enforceSyncCooldown({
  uid,
  db,
  now,
  HttpsError,
  serverTimestamp,
}) {
  const ref = db.collection(SYNC_LIMITS_COLLECTION).doc(uid);
  const snap = await ref.get();
  const lastSyncAt = snap.data()?.lastSyncAt;
  const lastMillis =
    typeof lastSyncAt?.toMillis === 'function' ? lastSyncAt.toMillis() : 0;
  if (lastMillis && now - lastMillis < SYNC_COOLDOWN_MS) {
    throw makeError(
      HttpsError,
      'resource-exhausted',
      '잠시 후 다시 동기화해주세요.',
    );
  }
  await ref.set(
    { lastSyncAt: serverTimestamp(), updatedAt: serverTimestamp() },
    { merge: true },
  );
}

function chunk(list, size) {
  const out = [];
  for (let i = 0; i < list.length; i += size) {
    out.push(list.slice(i, i + size));
  }
  return out;
}

/** contactHash 목록으로 가입자 uid를 찾는다. 자기 자신은 제외한다. */
async function findMatchedUids({ uid, contactHashes, db }) {
  const matched = new Set();
  for (const part of chunk(contactHashes, IN_QUERY_CHUNK)) {
    const snap = await db
      .collection(PRIVATE_IDENTIFIERS_COLLECTION)
      .where('contactHash', 'in', part)
      .get();
    for (const doc of snap.docs) {
      const targetUid = doc.data()?.uid || doc.id;
      if (typeof targetUid === 'string' && targetUid && targetUid !== uid) {
        matched.add(targetUid);
      }
    }
  }
  return matched;
}

/**
 * 소유 관계(owner relation) diff를 적용하고 pair를 정리한다.
 *
 * pair는 "한쪽이라도 상대를 연락처로 보유하면 유지"가 계약이다. 따라서 관계를
 * 제거할 때는 반대쪽 소유 여부를 확인한 뒤에만 pair를 지운다.
 */
async function applyMatchDiff({
  uid,
  matchedUids,
  db,
  serverTimestamp,
  schemaVersion,
}) {
  const ownerRef = db
    .collection('users')
    .doc(uid)
    .collection(OWNER_MATCHES_SUBCOLLECTION);
  const existingSnap = await ownerRef.get();
  const existing = new Set(existingSnap.docs.map((doc) => doc.id));

  const toAdd = [...matchedUids].filter((target) => !existing.has(target));
  const toRemove = [...existing].filter((target) => !matchedUids.has(target));

  // 제거 대상 중 상대가 여전히 나를 보유하고 있으면 pair는 유지한다.
  const reciprocalChecks = await Promise.all(
    toRemove.map(async (target) => {
      const snap = await db
        .collection('users')
        .doc(target)
        .collection(OWNER_MATCHES_SUBCOLLECTION)
        .doc(uid)
        .get();
      return { target, reciprocal: snap.exists };
    }),
  );

  const writes = [];
  for (const target of toAdd) {
    const pairId = contactAvoidancePairId(uid, target);
    writes.push({
      ref: ownerRef.doc(target),
      op: 'set',
      data: {
        targetUid: target,
        pairId,
        updatedAt: serverTimestamp(),
        schemaVersion,
      },
    });
    writes.push({
      ref: db.collection(PAIRS_COLLECTION).doc(pairId),
      op: 'set',
      data: {
        participants: sortedParticipants(uid, target),
        updatedAt: serverTimestamp(),
        schemaVersion,
      },
    });
  }
  for (const { target, reciprocal } of reciprocalChecks) {
    writes.push({ ref: ownerRef.doc(target), op: 'delete' });
    if (!reciprocal) {
      writes.push({
        ref: db.collection(PAIRS_COLLECTION).doc(contactAvoidancePairId(uid, target)),
        op: 'delete',
      });
    }
  }

  for (const part of chunk(writes, BATCH_CHUNK)) {
    const batch = db.batch();
    for (const write of part) {
      if (write.op === 'delete') {
        batch.delete(write.ref);
      } else {
        batch.set(write.ref, write.data, { merge: true });
      }
    }
    await batch.commit();
  }

  return { added: toAdd.length, removed: toRemove.length };
}

/**
 * syncAvoidContacts 본체.
 *
 * 반환값은 개수 요약뿐이다 — 매칭된 UID·digest·pairId는 절대 반환하지 않는다.
 */
async function syncAvoidContactsCore({
  request,
  db,
  auth,
  pepper,
  HttpsError,
  serverTimestamp,
  logger,
  now = Date.now(),
  schemaVersion = 1,
}) {
  const uid = request?.auth?.uid;
  if (typeof uid !== 'string' || uid.trim() === '') {
    throw makeError(HttpsError, 'unauthenticated', '로그인이 필요합니다.');
  }
  const uidHash = safeUidHash(uid);
  const { enabled, digests } = validateSyncInput(request?.data, HttpsError);

  try {
    await requirePhoneVerifiedUser({ uid, auth, db, HttpsError });

    // 끄기는 cooldown과 무관하게 허용한다(안전 기능을 막지 않는다).
    if (enabled) {
      await enforceSyncCooldown({
        uid,
        db,
        now,
        HttpsError,
        serverTimestamp,
      });
    }

    const matchedUids = enabled
      ? await findMatchedUids({
          uid,
          contactHashes: digests.map((digest) =>
            contactHashFromDigest(digest, pepper),
          ),
          db,
        })
      : new Set();

    await applyMatchDiff({
      uid,
      matchedUids,
      db,
      serverTimestamp,
      schemaVersion,
    });

    const contactCount = enabled ? digests.length : 0;
    const hiddenCount = matchedUids.size;
    await db
      .collection('users')
      .doc(uid)
      .collection(SETTINGS_SUBCOLLECTION)
      .doc(SETTINGS_DOC_ID)
      .set(
        {
          enabled,
          contactCount,
          hiddenCount,
          syncedAt: serverTimestamp(),
          updatedAt: serverTimestamp(),
          schemaVersion,
        },
        { merge: true },
      );

    if (logger?.log) {
      logger.log(
        `event=contact_avoidance_sync uidHash=${uidHash} enabled=${enabled} contactCount=${contactCount} hiddenCount=${hiddenCount}`,
      );
    }

    return { enabled, contactCount, hiddenCount };
  } catch (error) {
    if (isSafeError(error)) throw error;
    if (logger?.error) {
      logger.error(
        `event=contact_avoidance_sync uidHash=${uidHash} result=error`,
      );
    }
    throw makeError(
      HttpsError,
      'internal',
      '동기화하지 못했습니다. 잠시 후 다시 시도해주세요.',
    );
  }
}

/**
 * 전화 인증 상태에 맞춰 privatePhoneIdentifiers/{uid}를 upsert/삭제한다.
 *
 * 전화 인증이 풀리거나 번호가 없으면 식별자를 지워, 더 이상 남의 연락처
 * 동기화에 매칭되지 않게 한다. raw 번호·digest·HMAC은 로그에 남기지 않는다.
 */
async function syncPrivatePhoneIdentifier({
  uid,
  phoneNumber,
  phoneVerified,
  pepper,
  db,
  serverTimestamp,
  schemaVersion = 1,
}) {
  const ref = db.collection(PRIVATE_IDENTIFIERS_COLLECTION).doc(uid);
  const contactHash = phoneVerified
    ? contactHashFromPhoneNumber(phoneNumber, pepper)
    : null;

  if (!contactHash) {
    await ref.delete().catch(() => {});
    return { updated: false, removed: true };
  }

  await ref.set(
    {
      uid,
      contactHash,
      updatedAt: serverTimestamp(),
      schemaVersion,
    },
    { merge: true },
  );
  return { updated: true, removed: false };
}

/** 두 사용자가 지인 피하기로 묶여 있는지(서버 차단 판정용). */
async function isContactAvoidancePair({ db, uidA, uidB }) {
  if (!uidA || !uidB || uidA === uidB) return false;
  const snap = await db
    .collection(PAIRS_COLLECTION)
    .doc(contactAvoidancePairId(uidA, uidB))
    .get();
  return snap.exists;
}

module.exports = {
  BATCH_CHUNK,
  IN_QUERY_CHUNK,
  MAX_CONTACT_DIGESTS,
  OWNER_MATCHES_SUBCOLLECTION,
  PAIRS_COLLECTION,
  PRIVATE_IDENTIFIERS_COLLECTION,
  SETTINGS_DOC_ID,
  SETTINGS_SUBCOLLECTION,
  SYNC_COOLDOWN_MS,
  SYNC_LIMITS_COLLECTION,
  contactAvoidancePairId,
  contactHashFromDigest,
  contactHashFromPhoneNumber,
  isContactAvoidancePair,
  normalizePhoneNumber,
  safeUidHash,
  syncAvoidContactsCore,
  syncPrivatePhoneIdentifier,
  validateSyncInput,
};
