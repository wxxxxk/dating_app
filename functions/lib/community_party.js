'use strict';

// Phase 4-4: Party·Square 서버 전용 쓰기 경로.
//
// 하나의 파티 데이터 모델을 Square 탐색과 "내 파티" 관리가 함께 쓴다.
//
// 개인정보/안전 원칙(Phase 4-2 커뮤니티 계약을 그대로 따른다):
// - 호스트/요청자 정보는 publicProfiles/{uid}에서만 만든다(비공개 users/{uid} 금지).
// - 클라이언트는 snapshot·status·count·timestamp를 보내지 못한다.
// - 정확한 주소·위경도·참가비·금액 필드는 모델에 존재하지 않는다.
// - 차단·지인 피하기 관계는 요청 시점과 승인 transaction 안에서 각각 확인한다.
// - 로그에는 uid hash와 분류 code만 남긴다(원문·대상 UID 금지).
// - 응답에는 partyId 또는 bool/count/상태 문자열만 담는다.

const crypto = require('crypto');

const {
  MESSAGES: COMMUNITY_MESSAGES,
  REPORT_REASONS,
  SCHEMA_VERSION,
  assertAllowedCommunityText,
  buildCommunityAuthorSnapshot,
  deletedAuthorSnapshot,
  makeError,
  millisOf,
  requireAuthUid,
  requireDocId,
  requireExactObject,
  safeUidHash,
  safeLog,
} = require('./community');

const { isContactAvoidancePair } = require('./contact_avoidance');

const PARTIES_COLLECTION = 'communityParties';
const MEMBERS_SUBCOLLECTION = 'members';
const JOIN_REQUESTS_SUBCOLLECTION = 'joinRequests';
const MEMBERSHIPS_SUBCOLLECTION = 'partyMemberships';
const USERS_COLLECTION = 'users';
const BLOCKS_SUBCOLLECTION = 'blocks';
const PARTY_REPORTS_COLLECTION = 'partyReports';
const PARTY_WRITE_LIMITS_COLLECTION = 'partyWriteLimits';

const VISIBILITY_AUTHENTICATED = 'authenticated';

const PARTY_STATUS_OPEN = 'open';
const PARTY_STATUS_FULL = 'full';
const PARTY_STATUS_CANCELLED = 'cancelled';

const ROLE_HOST = 'host';
const ROLE_MEMBER = 'member';

const MEMBER_STATUS_ACTIVE = 'active';

const REQUEST_STATUS_PENDING = 'pending';
const REQUEST_STATUS_APPROVED = 'approved';
const REQUEST_STATUS_REJECTED = 'rejected';
const REQUEST_STATUS_WITHDRAWN = 'withdrawn';

const MEMBERSHIP_STATE_ACTIVE = 'active';
const MEMBERSHIP_STATE_PENDING = 'pending';

const TITLE_MIN_LENGTH = 1;
const TITLE_MAX_LENGTH = 60;
const DESCRIPTION_MIN_LENGTH = 1;
const DESCRIPTION_MAX_LENGTH = 500;
const JOIN_MESSAGE_MAX_LENGTH = 200;
const REPORT_DETAIL_MAX_LENGTH = 500;

const MIN_PARTICIPANTS = 3;
const MAX_PARTICIPANTS = 8;

/** 모임 시각은 서버 기준 최소 2시간 뒤, 최대 30일 이내여야 한다. */
const MIN_START_LEAD_MS = 2 * 60 * 60 * 1000;
const MAX_START_AHEAD_MS = 30 * 24 * 60 * 60 * 1000;

/** 서버 전용 rate limit 간격. */
const CREATE_COOLDOWN_MS = 30 * 1000;
const JOIN_REQUEST_COOLDOWN_MS = 5 * 1000;
const REVIEW_COOLDOWN_MS = 2 * 1000;
const REPORT_COOLDOWN_MS = 5 * 1000;

/** 파티 카테고리 allowlist. 자유 입력 key는 받지 않는다. */
const PARTY_CATEGORIES = Object.freeze([
  'coffee',
  'dining',
  'culture',
  'hobby',
  'exercise',
  'walk',
  'study',
  'other',
]);

/**
 * 광역 지역 allowlist.
 *
 * 시/도 단위까지만 받는다 — 상세 주소를 담을 수 있는 자유 문자열 필드는
 * 이 모델 어디에도 두지 않는다.
 */
const PARTY_AREAS = Object.freeze([
  'seoul',
  'gyeonggi',
  'incheon',
  'busan',
  'daegu',
  'daejeon',
  'gwangju',
  'ulsan',
  'sejong',
  'gangwon',
  'chungbuk',
  'chungnam',
  'jeonbuk',
  'jeonnam',
  'gyeongbuk',
  'gyeongnam',
  'jeju',
  'online',
]);

const PARTY_REVIEW_DECISIONS = Object.freeze(['approve', 'reject']);

/** 사용자에게 보여줄 고정 문구. 내부 원인·원문·상대 정보는 넣지 않는다. */
const MESSAGES = Object.freeze({
  ...COMMUNITY_MESSAGES,
  partyNotFound: '이미 종료됐거나 볼 수 없는 파티예요.',
  partyClosed: '지금은 참여 요청을 받지 않는 파티예요.',
  partyFull: '모집 인원이 모두 찼어요.',
  partyPast: '이미 시작한 파티예요.',
  joinNotAllowed: '지금은 이 파티에 참여할 수 없어요.',
  alreadyMember: '이미 참여 중인 파티예요.',
  hostCannotLeave: '호스트는 파티를 나갈 수 없어요. 파티를 취소해주세요.',
  requestNotFound: '처리할 참여 요청이 없어요.',
});

// ── 입력 검증 ──────────────────────────────────────────────────────────────

function normalizePartyText(value, { min, max }, HttpsError) {
  if (typeof value !== 'string') {
    throw makeError(HttpsError, 'invalid-argument', MESSAGES.invalidRequest);
  }
  const text = value.trim();
  if (text.length < min || text.length > max) {
    throw makeError(HttpsError, 'invalid-argument', MESSAGES.invalidRequest);
  }
  return text;
}

/** 선택 입력 문자열. 비어 있으면 ''를 반환한다. */
function normalizeOptionalText(value, maxLength, HttpsError) {
  if (value === undefined || value === null || value === '') return '';
  if (typeof value !== 'string') {
    throw makeError(HttpsError, 'invalid-argument', MESSAGES.invalidRequest);
  }
  const text = value.trim();
  if (text.length > maxLength) {
    throw makeError(HttpsError, 'invalid-argument', MESSAGES.invalidRequest);
  }
  return text;
}

function requireAllowedValue(value, allowlist, HttpsError) {
  if (typeof value !== 'string' || !allowlist.includes(value)) {
    throw makeError(HttpsError, 'invalid-argument', MESSAGES.invalidRequest);
  }
  return value;
}

function requireParticipantCapacity(value, HttpsError) {
  if (
    !Number.isInteger(value) ||
    value < MIN_PARTICIPANTS ||
    value > MAX_PARTICIPANTS
  ) {
    throw makeError(HttpsError, 'invalid-argument', MESSAGES.invalidRequest);
  }
  return value;
}

/**
 * 모임 시각 검증(순수 함수).
 *
 * 클라이언트 시계를 믿지 않는다 — 범위는 항상 **서버 now** 기준으로 본다.
 */
function requireStartAtMillis(value, nowMs, HttpsError) {
  if (!Number.isFinite(value) || !Number.isInteger(value)) {
    throw makeError(HttpsError, 'invalid-argument', MESSAGES.invalidRequest);
  }
  const delta = value - nowMs;
  if (delta < MIN_START_LEAD_MS || delta > MAX_START_AHEAD_MS) {
    throw makeError(HttpsError, 'invalid-argument', MESSAGES.invalidRequest);
  }
  return value;
}

function safeCount(value) {
  return Number.isInteger(value) && value > 0 ? value : 0;
}

/** participantCount는 host 포함이므로 최소 1이다. */
function clampParticipantCount(value) {
  const count = safeCount(value);
  return count < 1 ? 1 : count;
}

// ── rate limit ─────────────────────────────────────────────────────────────

function assertPartyRateLimit({ limitData, field, cooldownMs, nowMs, HttpsError }) {
  const last = millisOf(limitData?.[field]);
  if (last > 0 && nowMs - last < cooldownMs) {
    throw makeError(HttpsError, 'resource-exhausted', MESSAGES.rateLimited);
  }
}

// ── 관계 확인 ──────────────────────────────────────────────────────────────

/**
 * 두 사용자 사이에 차단(양방향) 또는 지인 피하기 관계가 있는지.
 *
 * 클라이언트 목록 필터는 표시용일 뿐이므로, 참여 요청과 승인 시점에 서버가
 * 각각 다시 확인한다. 어느 쪽 관계인지는 호출부에 알려주지 않는다 —
 * 상대에게 "차단당했다"는 사실이 새어나가지 않도록 결과는 bool 하나다.
 */
async function hasBlockedOrAvoidedRelation({ db, uidA, uidB }) {
  if (typeof uidA !== 'string' || typeof uidB !== 'string') return true;
  if (uidA.length === 0 || uidB.length === 0) return true;
  if (uidA === uidB) return false;

  const [forward, backward] = await Promise.all([
    db
      .collection(USERS_COLLECTION)
      .doc(uidA)
      .collection(BLOCKS_SUBCOLLECTION)
      .doc(uidB)
      .get(),
    db
      .collection(USERS_COLLECTION)
      .doc(uidB)
      .collection(BLOCKS_SUBCOLLECTION)
      .doc(uidA)
      .get(),
  ]);
  if (forward.exists || backward.exists) return true;

  return isContactAvoidancePair({ db, uidA, uidB });
}

// ── 공통 조회 ──────────────────────────────────────────────────────────────

async function loadPartyAuthorSnapshot({ db, uid, HttpsError }) {
  const snap = await db.collection('publicProfiles').doc(uid).get();
  const snapshot = snap.exists
    ? buildCommunityAuthorSnapshot({ uid, publicProfileData: snap.data() })
    : null;
  if (!snapshot) {
    throw makeError(HttpsError, 'failed-precondition', MESSAGES.profileRequired);
  }
  return snapshot;
}

/** 일반 사용자에게 보여도 되는 파티인지(취소된 파티는 제외). */
function isVisibleParty(data) {
  return (
    data != null &&
    data.visibility === VISIBILITY_AUTHENTICATED &&
    (data.status === PARTY_STATUS_OPEN || data.status === PARTY_STATUS_FULL)
  );
}

function partyRefs(db, partyId) {
  const partyRef = db.collection(PARTIES_COLLECTION).doc(partyId);
  return {
    partyRef,
    memberRef: (uid) => partyRef.collection(MEMBERS_SUBCOLLECTION).doc(uid),
    requestRef: (uid) =>
      partyRef.collection(JOIN_REQUESTS_SUBCOLLECTION).doc(uid),
  };
}

function membershipRef(db, uid, partyId) {
  return db
    .collection(USERS_COLLECTION)
    .doc(uid)
    .collection(MEMBERSHIPS_SUBCOLLECTION)
    .doc(partyId);
}

function limitRef(db, uid) {
  return db.collection(PARTY_WRITE_LIMITS_COLLECTION).doc(uid);
}

function membershipPayload({ partyId, role, state, serverTimestamp }) {
  return {
    partyId,
    role,
    state,
    updatedAt: serverTimestamp(),
    schemaVersion: SCHEMA_VERSION,
  };
}

// ── createCommunityParty ───────────────────────────────────────────────────

async function createCommunityPartyCore({
  request,
  db,
  HttpsError,
  serverTimestamp,
  timestampFromMillis,
  nowMs = Date.now,
  logger = null,
} = {}) {
  const functionName = 'createCommunityParty';
  const uid = requireAuthUid(request, HttpsError);
  const data = requireExactObject(
    request?.data ?? {},
    ['title', 'description', 'category', 'area', 'startAtMillis', 'maxParticipants'],
    HttpsError,
  );

  const now = nowMs();
  const title = normalizePartyText(
    data.title,
    { min: TITLE_MIN_LENGTH, max: TITLE_MAX_LENGTH },
    HttpsError,
  );
  const description = normalizePartyText(
    data.description,
    { min: DESCRIPTION_MIN_LENGTH, max: DESCRIPTION_MAX_LENGTH },
    HttpsError,
  );
  const category = requireAllowedValue(data.category, PARTY_CATEGORIES, HttpsError);
  const area = requireAllowedValue(data.area, PARTY_AREAS, HttpsError);
  const startAtMillis = requireStartAtMillis(data.startAtMillis, now, HttpsError);
  const maxParticipants = requireParticipantCapacity(data.maxParticipants, HttpsError);

  // 제목·설명 모두 공개 글이므로 같은 안전 검사를 받는다.
  assertAllowedCommunityText({
    text: `${title}\n${description}`,
    uid,
    functionName,
    logger,
    HttpsError,
  });

  const hostSnapshot = await loadPartyAuthorSnapshot({ db, uid, HttpsError });

  const { partyRef, memberRef } = partyRefs(db, db.collection(PARTIES_COLLECTION).doc().id);
  const mirrorRef = membershipRef(db, uid, partyRef.id);
  const limits = limitRef(db, uid);

  await db.runTransaction(async (tx) => {
    const limitSnap = await tx.get(limits);
    assertPartyRateLimit({
      limitData: limitSnap.exists ? limitSnap.data() : null,
      field: 'lastCreateAt',
      cooldownMs: CREATE_COOLDOWN_MS,
      nowMs: now,
      HttpsError,
    });

    tx.set(partyRef, {
      hostUid: uid,
      hostSnapshot,
      title,
      description,
      category,
      area,
      startAt: timestampFromMillis(startAtMillis),
      maxParticipants,
      // host를 포함해 1명으로 시작한다.
      participantCount: 1,
      status: PARTY_STATUS_OPEN,
      visibility: VISIBILITY_AUTHENTICATED,
      createdAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
      schemaVersion: SCHEMA_VERSION,
    });
    tx.set(memberRef(uid), {
      uid,
      role: ROLE_HOST,
      status: MEMBER_STATUS_ACTIVE,
      joinedAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
      schemaVersion: SCHEMA_VERSION,
    });
    tx.set(
      mirrorRef,
      membershipPayload({
        partyId: partyRef.id,
        role: ROLE_HOST,
        state: MEMBERSHIP_STATE_ACTIVE,
        serverTimestamp,
      }),
    );
    tx.set(
      limits,
      {
        lastCreateAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
        schemaVersion: SCHEMA_VERSION,
      },
      { merge: true },
    );
  });

  safeLog(logger, functionName, {
    step: 'created',
    callerHash: safeUidHash(uid),
    category,
    area,
  });

  // 응답에는 새 문서 id만 담는다(UID·본문·snapshot 금지).
  return { partyId: partyRef.id };
}

// ── requestPartyJoin ───────────────────────────────────────────────────────

async function requestPartyJoinCore({
  request,
  db,
  HttpsError,
  serverTimestamp,
  nowMs = Date.now,
  logger = null,
} = {}) {
  const functionName = 'requestPartyJoin';
  const uid = requireAuthUid(request, HttpsError);
  const data = requireExactObject(
    request?.data ?? {},
    ['partyId', 'message'],
    HttpsError,
  );
  const partyId = requireDocId(data.partyId, HttpsError);
  const message = normalizeOptionalText(data.message, JOIN_MESSAGE_MAX_LENGTH, HttpsError);
  if (message.length > 0) {
    assertAllowedCommunityText({
      text: message,
      uid,
      functionName,
      logger,
      HttpsError,
    });
  }

  const now = nowMs();
  const { partyRef, memberRef, requestRef } = partyRefs(db, partyId);

  // transaction 밖에서 먼저 호스트를 확인해야 관계 조회를 할 수 있다.
  // 최종 판정은 transaction 안에서 다시 한다.
  const preSnap = await partyRef.get();
  if (!preSnap.exists) {
    throw makeError(HttpsError, 'not-found', MESSAGES.partyNotFound);
  }
  const preData = preSnap.data();
  if (!isVisibleParty(preData)) {
    throw makeError(HttpsError, 'not-found', MESSAGES.partyNotFound);
  }
  const hostUid = preData.hostUid;
  if (typeof hostUid !== 'string' || hostUid.length === 0) {
    throw makeError(HttpsError, 'not-found', MESSAGES.partyNotFound);
  }
  if (hostUid === uid) {
    throw makeError(HttpsError, 'failed-precondition', MESSAGES.joinNotAllowed);
  }

  const blocked = await hasBlockedOrAvoidedRelation({ db, uidA: uid, uidB: hostUid });
  if (blocked) {
    // 차단인지 지인 피하기인지 구분해 알리지 않는다.
    throw makeError(HttpsError, 'permission-denied', MESSAGES.joinNotAllowed);
  }

  const snapshot = await loadPartyAuthorSnapshot({ db, uid, HttpsError });
  const mirrorRef = membershipRef(db, uid, partyId);
  const limits = limitRef(db, uid);

  await db.runTransaction(async (tx) => {
    const partySnap = await tx.get(partyRef);
    if (!partySnap.exists) {
      throw makeError(HttpsError, 'not-found', MESSAGES.partyNotFound);
    }
    const partyData = partySnap.data();
    if (!isVisibleParty(partyData)) {
      throw makeError(HttpsError, 'not-found', MESSAGES.partyNotFound);
    }
    if (partyData.hostUid !== hostUid) {
      // 호스트가 바뀌었으면 관계 확인이 무효다. 다시 시도하게 한다.
      throw makeError(HttpsError, 'failed-precondition', MESSAGES.joinNotAllowed);
    }
    if (partyData.status !== PARTY_STATUS_OPEN) {
      throw makeError(HttpsError, 'failed-precondition', MESSAGES.partyClosed);
    }
    if (millisOf(partyData.startAt) <= now) {
      throw makeError(HttpsError, 'failed-precondition', MESSAGES.partyPast);
    }
    if (
      clampParticipantCount(partyData.participantCount) >=
      safeCount(partyData.maxParticipants)
    ) {
      throw makeError(HttpsError, 'failed-precondition', MESSAGES.partyFull);
    }

    const memberSnap = await tx.get(memberRef(uid));
    if (memberSnap.exists) {
      throw makeError(HttpsError, 'failed-precondition', MESSAGES.alreadyMember);
    }

    const requestSnap = await tx.get(requestRef(uid));
    const currentStatus = requestSnap.exists ? requestSnap.data().status : null;
    // 이미 승인된 요청은 다시 pending으로 되돌리지 않는다.
    if (currentStatus === REQUEST_STATUS_APPROVED) {
      throw makeError(HttpsError, 'failed-precondition', MESSAGES.alreadyMember);
    }
    // 같은 pending 요청 재호출은 아무것도 바꾸지 않고 성공한다(멱등).
    if (currentStatus === REQUEST_STATUS_PENDING) return;

    const limitSnap = await tx.get(limits);
    assertPartyRateLimit({
      limitData: limitSnap.exists ? limitSnap.data() : null,
      field: 'lastJoinRequestAt',
      cooldownMs: JOIN_REQUEST_COOLDOWN_MS,
      nowMs: now,
      HttpsError,
    });

    // rejected/withdrawn 이후 재요청은 새 updatedAt으로 pending 전환한다.
    tx.set(requestRef(uid), {
      requesterUid: uid,
      requesterSnapshot: snapshot,
      message,
      status: REQUEST_STATUS_PENDING,
      createdAt: requestSnap.exists
        ? requestSnap.data().createdAt ?? serverTimestamp()
        : serverTimestamp(),
      updatedAt: serverTimestamp(),
      schemaVersion: SCHEMA_VERSION,
    });
    tx.set(
      mirrorRef,
      membershipPayload({
        partyId,
        role: ROLE_MEMBER,
        state: MEMBERSHIP_STATE_PENDING,
        serverTimestamp,
      }),
    );
    tx.set(
      limits,
      {
        lastJoinRequestAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
        schemaVersion: SCHEMA_VERSION,
      },
      { merge: true },
    );
  });

  safeLog(logger, functionName, {
    step: 'requested',
    callerHash: safeUidHash(uid),
  });

  return { requested: true };
}

// ── reviewPartyJoinRequest ─────────────────────────────────────────────────

async function reviewPartyJoinRequestCore({
  request,
  db,
  HttpsError,
  serverTimestamp,
  nowMs = Date.now,
  logger = null,
} = {}) {
  const functionName = 'reviewPartyJoinRequest';
  const uid = requireAuthUid(request, HttpsError);
  const data = requireExactObject(
    request?.data ?? {},
    ['partyId', 'requesterUid', 'decision'],
    HttpsError,
  );
  const partyId = requireDocId(data.partyId, HttpsError);
  const requesterUid = requireDocId(data.requesterUid, HttpsError);
  const decision = requireAllowedValue(data.decision, PARTY_REVIEW_DECISIONS, HttpsError);
  if (requesterUid === uid) {
    throw makeError(HttpsError, 'failed-precondition', MESSAGES.invalidRequest);
  }

  const now = nowMs();
  const { partyRef, memberRef, requestRef } = partyRefs(db, partyId);

  const preSnap = await partyRef.get();
  if (!preSnap.exists) {
    throw makeError(HttpsError, 'not-found', MESSAGES.partyNotFound);
  }
  if (preSnap.data().hostUid !== uid) {
    throw makeError(HttpsError, 'permission-denied', MESSAGES.permissionDenied);
  }

  // 승인일 때만 관계를 미리 확인한다(거절은 관계와 무관하게 항상 가능).
  let relationBlocked = false;
  if (decision === 'approve') {
    relationBlocked = await hasBlockedOrAvoidedRelation({
      db,
      uidA: uid,
      uidB: requesterUid,
    });
  }

  const mirrorRef = membershipRef(db, requesterUid, partyId);
  const limits = limitRef(db, uid);

  const outcome = await db.runTransaction(async (tx) => {
    const partySnap = await tx.get(partyRef);
    if (!partySnap.exists) {
      throw makeError(HttpsError, 'not-found', MESSAGES.partyNotFound);
    }
    const partyData = partySnap.data();
    if (partyData.hostUid !== uid) {
      throw makeError(HttpsError, 'permission-denied', MESSAGES.permissionDenied);
    }
    if (partyData.status === PARTY_STATUS_CANCELLED) {
      throw makeError(HttpsError, 'failed-precondition', MESSAGES.partyNotFound);
    }

    const requestSnap = await tx.get(requestRef(requesterUid));
    if (!requestSnap.exists) {
      throw makeError(HttpsError, 'not-found', MESSAGES.requestNotFound);
    }
    if (requestSnap.data().status !== REQUEST_STATUS_PENDING) {
      throw makeError(HttpsError, 'failed-precondition', MESSAGES.requestNotFound);
    }

    const limitSnap = await tx.get(limits);
    assertPartyRateLimit({
      limitData: limitSnap.exists ? limitSnap.data() : null,
      field: 'lastReviewAt',
      cooldownMs: REVIEW_COOLDOWN_MS,
      nowMs: now,
      HttpsError,
    });

    if (decision === 'reject') {
      tx.update(requestRef(requesterUid), {
        status: REQUEST_STATUS_REJECTED,
        updatedAt: serverTimestamp(),
      });
      tx.delete(mirrorRef);
      tx.set(
        limits,
        {
          lastReviewAt: serverTimestamp(),
          updatedAt: serverTimestamp(),
          schemaVersion: SCHEMA_VERSION,
        },
        { merge: true },
      );
      return {
        decision,
        participantCount: clampParticipantCount(partyData.participantCount),
        status: partyData.status,
      };
    }

    // ── approve ──
    // 관계·정원·중복은 transaction 안에서 최종 확인한다.
    if (relationBlocked) {
      throw makeError(HttpsError, 'permission-denied', MESSAGES.joinNotAllowed);
    }
    const memberSnap = await tx.get(memberRef(requesterUid));
    if (memberSnap.exists) {
      throw makeError(HttpsError, 'failed-precondition', MESSAGES.alreadyMember);
    }
    const maxParticipants = safeCount(partyData.maxParticipants);
    const current = clampParticipantCount(partyData.participantCount);
    if (current >= maxParticipants) {
      throw makeError(HttpsError, 'failed-precondition', MESSAGES.partyFull);
    }

    const nextCount = current + 1;
    const nextStatus =
      nextCount >= maxParticipants ? PARTY_STATUS_FULL : PARTY_STATUS_OPEN;

    tx.update(requestRef(requesterUid), {
      status: REQUEST_STATUS_APPROVED,
      updatedAt: serverTimestamp(),
    });
    tx.set(memberRef(requesterUid), {
      uid: requesterUid,
      role: ROLE_MEMBER,
      status: MEMBER_STATUS_ACTIVE,
      joinedAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
      schemaVersion: SCHEMA_VERSION,
    });
    tx.set(
      mirrorRef,
      membershipPayload({
        partyId,
        role: ROLE_MEMBER,
        state: MEMBERSHIP_STATE_ACTIVE,
        serverTimestamp,
      }),
    );
    tx.update(partyRef, {
      participantCount: nextCount,
      status: nextStatus,
      updatedAt: serverTimestamp(),
    });
    tx.set(
      limits,
      {
        lastReviewAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
        schemaVersion: SCHEMA_VERSION,
      },
      { merge: true },
    );

    return { decision, participantCount: nextCount, status: nextStatus };
  });

  // 대상 UID는 로그에 남기지 않는다(호출자 hash와 결정만).
  safeLog(logger, functionName, {
    step: 'reviewed',
    callerHash: safeUidHash(uid),
    decision,
  });

  return outcome;
}

// ── withdrawPartyJoinRequest ───────────────────────────────────────────────

async function withdrawPartyJoinRequestCore({
  request,
  db,
  HttpsError,
  serverTimestamp,
  logger = null,
} = {}) {
  const functionName = 'withdrawPartyJoinRequest';
  const uid = requireAuthUid(request, HttpsError);
  const data = requireExactObject(request?.data ?? {}, ['partyId'], HttpsError);
  const partyId = requireDocId(data.partyId, HttpsError);

  const { requestRef } = partyRefs(db, partyId);
  const mirrorRef = membershipRef(db, uid, partyId);

  await db.runTransaction(async (tx) => {
    const requestSnap = await tx.get(requestRef(uid));
    // 요청이 없거나 이미 종료된 상태면 아무것도 바꾸지 않고 성공한다(멱등).
    if (!requestSnap.exists) {
      tx.delete(mirrorRef);
      return;
    }
    const status = requestSnap.data().status;
    if (status === REQUEST_STATUS_APPROVED) {
      // 이미 멤버가 된 요청은 leaveCommunityParty로만 정리한다.
      throw makeError(HttpsError, 'failed-precondition', MESSAGES.alreadyMember);
    }
    if (status !== REQUEST_STATUS_PENDING) {
      tx.delete(mirrorRef);
      return;
    }

    tx.update(requestRef(uid), {
      status: REQUEST_STATUS_WITHDRAWN,
      updatedAt: serverTimestamp(),
    });
    tx.delete(mirrorRef);
  });

  safeLog(logger, functionName, {
    step: 'withdrawn',
    callerHash: safeUidHash(uid),
  });

  return { withdrawn: true };
}

// ── leaveCommunityParty ────────────────────────────────────────────────────

async function leaveCommunityPartyCore({
  request,
  db,
  HttpsError,
  serverTimestamp,
  logger = null,
} = {}) {
  const functionName = 'leaveCommunityParty';
  const uid = requireAuthUid(request, HttpsError);
  const data = requireExactObject(request?.data ?? {}, ['partyId'], HttpsError);
  const partyId = requireDocId(data.partyId, HttpsError);

  const { partyRef, memberRef, requestRef } = partyRefs(db, partyId);
  const mirrorRef = membershipRef(db, uid, partyId);

  await db.runTransaction(async (tx) => {
    const partySnap = await tx.get(partyRef);
    if (!partySnap.exists) {
      throw makeError(HttpsError, 'not-found', MESSAGES.partyNotFound);
    }
    const partyData = partySnap.data();
    if (partyData.hostUid === uid) {
      throw makeError(HttpsError, 'failed-precondition', MESSAGES.hostCannotLeave);
    }

    const memberSnap = await tx.get(memberRef(uid));
    // 이미 나갔으면 mirror만 정리하고 성공한다(멱등 재호출 가능).
    if (!memberSnap.exists) {
      tx.delete(mirrorRef);
      return;
    }

    const requestSnap = await tx.get(requestRef(uid));

    tx.delete(memberRef(uid));
    tx.delete(mirrorRef);

    // approved 요청은 별도 left 상태를 새로 만들지 않고 withdrawn으로 되돌려
    // 나중에 다시 요청할 수 있는 상태로 정리한다.
    if (requestSnap.exists) {
      tx.update(requestRef(uid), {
        status: REQUEST_STATUS_WITHDRAWN,
        updatedAt: serverTimestamp(),
      });
    }

    const maxParticipants = safeCount(partyData.maxParticipants);
    const nextCount = clampParticipantCount(
      clampParticipantCount(partyData.participantCount) - 1,
    );
    const update = {
      participantCount: nextCount,
      updatedAt: serverTimestamp(),
    };
    // 정원이 찼던 파티는 자리가 나면 다시 모집 상태로 돌아간다.
    if (partyData.status === PARTY_STATUS_FULL && nextCount < maxParticipants) {
      update.status = PARTY_STATUS_OPEN;
    }
    tx.update(partyRef, update);
  });

  safeLog(logger, functionName, { step: 'left', callerHash: safeUidHash(uid) });

  return { left: true };
}

// ── cancelCommunityParty ───────────────────────────────────────────────────

async function cancelCommunityPartyCore({
  request,
  db,
  HttpsError,
  serverTimestamp,
  logger = null,
} = {}) {
  const functionName = 'cancelCommunityParty';
  const uid = requireAuthUid(request, HttpsError);
  const data = requireExactObject(request?.data ?? {}, ['partyId'], HttpsError);
  const partyId = requireDocId(data.partyId, HttpsError);

  const { partyRef } = partyRefs(db, partyId);

  const alreadyCancelled = await db.runTransaction(async (tx) => {
    const partySnap = await tx.get(partyRef);
    if (!partySnap.exists) {
      throw makeError(HttpsError, 'not-found', MESSAGES.partyNotFound);
    }
    const partyData = partySnap.data();
    if (partyData.hostUid !== uid) {
      throw makeError(HttpsError, 'permission-denied', MESSAGES.permissionDenied);
    }
    if (partyData.status === PARTY_STATUS_CANCELLED) return true;

    tx.update(partyRef, {
      status: PARTY_STATUS_CANCELLED,
      updatedAt: serverTimestamp(),
    });
    return false;
  });

  // 취소 표시가 끝난 뒤 mirror를 정리한다. 실패해도 파티는 이미 취소 상태라
  // 목록/상세에서 사라지고, 재호출하면 남은 mirror를 마저 지운다(멱등).
  const cleaned = await cleanupPartyMembershipMirrors({ db, partyId });

  safeLog(logger, functionName, {
    step: alreadyCancelled ? 'already_cancelled' : 'cancelled',
    callerHash: safeUidHash(uid),
    mirrorsRemoved: cleaned,
  });

  return { cancelled: true };
}

/**
 * 파티의 member/pending mirror를 전부 지운다(멱등).
 *
 * members·joinRequests 문서 자체는 운영 검토를 위해 남긴다.
 */
async function cleanupPartyMembershipMirrors({ db, partyId }) {
  const { partyRef } = partyRefs(db, partyId);
  const uids = new Set();

  const membersSnap = await partyRef.collection(MEMBERS_SUBCOLLECTION).get();
  for (const doc of membersSnap.docs || []) uids.add(doc.id);

  const requestsSnap = await partyRef
    .collection(JOIN_REQUESTS_SUBCOLLECTION)
    .where('status', '==', REQUEST_STATUS_PENDING)
    .get();
  for (const doc of requestsSnap.docs || []) uids.add(doc.id);

  let removed = 0;
  for (const uid of uids) {
    await membershipRef(db, uid, partyId).delete();
    removed += 1;
  }
  return removed;
}

// ── reportCommunityParty ───────────────────────────────────────────────────

/** 같은 신고자·같은 파티면 항상 같은 문서 id(중복 신고 멱등 처리). */
function partyReportId({ reporterUid, partyId }) {
  return crypto
    .createHash('sha256')
    .update(`${reporterUid}|${partyId}`)
    .digest('hex');
}

async function reportCommunityPartyCore({
  request,
  db,
  HttpsError,
  serverTimestamp,
  nowMs = Date.now,
  logger = null,
} = {}) {
  const functionName = 'reportCommunityParty';
  const uid = requireAuthUid(request, HttpsError);
  const data = requireExactObject(
    request?.data ?? {},
    ['partyId', 'reason', 'detail'],
    HttpsError,
  );
  const partyId = requireDocId(data.partyId, HttpsError);
  const reason = requireAllowedValue(data.reason, REPORT_REASONS, HttpsError);
  const detail = normalizeOptionalText(data.detail, REPORT_DETAIL_MAX_LENGTH, HttpsError);

  const now = nowMs();
  const { partyRef } = partyRefs(db, partyId);
  const reportRef = db
    .collection(PARTY_REPORTS_COLLECTION)
    .doc(partyReportId({ reporterUid: uid, partyId }));
  const limits = limitRef(db, uid);

  await db.runTransaction(async (tx) => {
    const partySnap = await tx.get(partyRef);
    if (!partySnap.exists) {
      throw makeError(HttpsError, 'not-found', MESSAGES.partyNotFound);
    }
    const reportedUid = partySnap.data().hostUid;
    if (typeof reportedUid !== 'string' || reportedUid.length === 0) {
      throw makeError(HttpsError, 'not-found', MESSAGES.partyNotFound);
    }
    if (reportedUid === uid) {
      throw makeError(HttpsError, 'failed-precondition', MESSAGES.invalidRequest);
    }

    const reportSnap = await tx.get(reportRef);
    // 같은 파티 재신고는 새 문서를 만들지 않고 성공 처리한다(멱등).
    if (reportSnap.exists) return;

    const limitSnap = await tx.get(limits);
    assertPartyRateLimit({
      limitData: limitSnap.exists ? limitSnap.data() : null,
      field: 'lastReportAt',
      cooldownMs: REPORT_COOLDOWN_MS,
      nowMs: now,
      HttpsError,
    });

    // 신고만으로 파티를 지우거나 호스트를 차단하지 않고, 상대에게 알리지도
    // 않는다. 차단은 클라이언트가 별도로 SafetyService를 호출한다.
    tx.set(reportRef, {
      reporterUid: uid,
      reportedUid,
      partyId,
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
 * 탈퇴 사용자의 파티 관련 데이터 정리(멱등).
 *
 * - 호스트 파티: cancelled + hostUid/hostSnapshot 익명화, 관련 mirror 제거
 * - 참여 파티: member 문서 제거, participantCount 최소 1 보정, full → open 복원
 * - pending 요청: withdrawn 처리 + mirror 제거
 * - 신고: reporterUid만 익명 식별자로 교체
 * - partyWriteLimits/{uid} 삭제
 *
 * hostUid/requesterUid를 익명 식별자로 바꾸므로 재실행 시 같은 문서가 다시
 * 잡히지 않는다.
 */
async function cleanupPartyDataForUser({
  db,
  uid,
  deletedIdentifier,
  serverTimestamp,
} = {}) {
  if (!db || typeof uid !== 'string' || uid.length === 0) {
    throw new Error('cleanupPartyDataForUser requires db and uid');
  }
  const anonymousSnapshot = deletedAuthorSnapshot(deletedIdentifier);

  // ── 호스트 파티 ──
  let partiesCancelled = 0;
  const hostedSnap = await db
    .collection(PARTIES_COLLECTION)
    .where('hostUid', '==', uid)
    .get();
  for (const doc of hostedSnap.docs || []) {
    await cleanupPartyMembershipMirrors({ db, partyId: doc.id });
    await doc.ref.update({
      status: PARTY_STATUS_CANCELLED,
      hostUid: deletedIdentifier,
      hostSnapshot: anonymousSnapshot,
      updatedAt: serverTimestamp(),
    });
    partiesCancelled += 1;
  }

  // ── 참여/요청 mirror ──
  //
  // 사용자 본인 하위의 mirror를 기준점으로 삼는다. 여기가 "내가 관여한 파티"의
  // 단일 목록이라 collectionGroup 조회 없이 정리할 수 있다.
  let partyMembershipsRemoved = 0;
  // 요약 key에 'withdrawn'을 쓰지 않는다 — 계정 삭제 로그 위생 테스트가
  // 로그 문자열에 'raw'(=with-draw-n)가 섞이는 것을 잡아낸다.
  let partyRequestsClosed = 0;
  const mirrorsSnap = await db
    .collection(USERS_COLLECTION)
    .doc(uid)
    .collection(MEMBERSHIPS_SUBCOLLECTION)
    .get();

  for (const mirrorDoc of mirrorsSnap.docs || []) {
    const partyId = mirrorDoc.id;
    const { partyRef, memberRef, requestRef } = partyRefs(db, partyId);

    const memberSnap = await memberRef(uid).get();
    if (memberSnap.exists && (memberSnap.data() || {}).role !== ROLE_HOST) {
      await memberRef(uid).delete();
      const partySnap = await partyRef.get();
      if (partySnap.exists) {
        const partyData = partySnap.data() || {};
        const maxParticipants = safeCount(partyData.maxParticipants);
        const nextCount = clampParticipantCount(
          clampParticipantCount(partyData.participantCount) - 1,
        );
        const update = {
          participantCount: nextCount,
          updatedAt: serverTimestamp(),
        };
        if (partyData.status === PARTY_STATUS_FULL && nextCount < maxParticipants) {
          update.status = PARTY_STATUS_OPEN;
        }
        await partyRef.update(update);
      }
    }

    const requestSnap = await requestRef(uid).get();
    if (requestSnap.exists) {
      const status = (requestSnap.data() || {}).status;
      if (status === REQUEST_STATUS_PENDING || status === REQUEST_STATUS_APPROVED) {
        await requestRef(uid).update({
          status: REQUEST_STATUS_WITHDRAWN,
          requesterUid: deletedIdentifier,
          requesterSnapshot: anonymousSnapshot,
          updatedAt: serverTimestamp(),
        });
        partyRequestsClosed += 1;
      }
    }

    await mirrorDoc.ref.delete();
    partyMembershipsRemoved += 1;
  }

  // ── 신고 ──
  let partyReportsAnonymized = 0;
  const reportsSnap = await db
    .collection(PARTY_REPORTS_COLLECTION)
    .where('reporterUid', '==', uid)
    .get();
  for (const doc of reportsSnap.docs || []) {
    await doc.ref.update({
      reporterUid: deletedIdentifier,
      reporterDeleted: true,
    });
    partyReportsAnonymized += 1;
  }

  await db.collection(PARTY_WRITE_LIMITS_COLLECTION).doc(uid).delete();

  return {
    partiesCancelled,
    partyMembershipsRemoved,
    partyRequestsClosed,
    partyReportsAnonymized,
    partyWriteLimitsDeleted: true,
  };
}

module.exports = {
  CREATE_COOLDOWN_MS,
  DESCRIPTION_MAX_LENGTH,
  JOIN_MESSAGE_MAX_LENGTH,
  JOIN_REQUEST_COOLDOWN_MS,
  MAX_PARTICIPANTS,
  MAX_START_AHEAD_MS,
  MEMBERSHIP_STATE_ACTIVE,
  MEMBERSHIP_STATE_PENDING,
  MESSAGES,
  MIN_PARTICIPANTS,
  MIN_START_LEAD_MS,
  PARTIES_COLLECTION,
  PARTY_AREAS,
  PARTY_CATEGORIES,
  PARTY_REPORTS_COLLECTION,
  PARTY_REVIEW_DECISIONS,
  PARTY_STATUS_CANCELLED,
  PARTY_STATUS_FULL,
  PARTY_STATUS_OPEN,
  PARTY_WRITE_LIMITS_COLLECTION,
  REPORT_COOLDOWN_MS,
  REQUEST_STATUS_APPROVED,
  REQUEST_STATUS_PENDING,
  REQUEST_STATUS_REJECTED,
  REQUEST_STATUS_WITHDRAWN,
  REVIEW_COOLDOWN_MS,
  ROLE_HOST,
  ROLE_MEMBER,
  TITLE_MAX_LENGTH,
  cancelCommunityPartyCore,
  cleanupPartyDataForUser,
  cleanupPartyMembershipMirrors,
  createCommunityPartyCore,
  hasBlockedOrAvoidedRelation,
  isVisibleParty,
  leaveCommunityPartyCore,
  partyReportId,
  reportCommunityPartyCore,
  requestPartyJoinCore,
  requireStartAtMillis,
  reviewPartyJoinRequestCore,
  withdrawPartyJoinRequestCore,
};
