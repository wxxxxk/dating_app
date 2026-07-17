'use strict';

// ============================================================================
// Profile Insight 접근 계약 + 데이터 최소화 (Phase 0-E-2B)
//
// generateProfileInsight는 임의 targetUid의 private users 문서를 읽어 외부
// GPT-4o Vision을 호출할 수 있었다. 이 모듈은 그 전에 통과해야 하는 서버측
// 접근 계약과, 프롬프트에 넣을 입력 데이터를 최소 권한으로 조립하는 로직을
// 담는다. I/O(Firestore/Auth)는 의존성 주입으로 분리해 단위 테스트가 쉽다.
//
// 접근 계약(허용 대상):
//   1) caller 자신
//   2) caller가 participant인 "활성" match의 상대방
// 그 외는 permission-denied. match/block/orphan(Auth) 검증은 users private
// 문서를 읽기 전에 끝낸다.
// ============================================================================

const crypto = require('crypto');

/** 로그용 안전 uid 해시(원문 uid 노출 금지). */
function safeUidHash(uid) {
  return crypto.createHash('sha256').update(String(uid)).digest('hex').slice(0, 8);
}

/**
 * caller/target 한 쌍의 결정적 matchId.
 * onSwipeCreated가 만드는 규칙과 동일: 정렬 후 join('_').
 * 클라이언트가 보낸 matchId를 신뢰하지 않고 서버가 직접 계산한다.
 */
function deriveMatchId(a, b) {
  return [String(a), String(b)].sort().join('_');
}

/** match 문서 raw data(또는 snap)를 표준화된 평면 객체로. */
function matchDataOf(matchDoc) {
  if (!matchDoc) return null;
  if (typeof matchDoc.exists === 'boolean') {
    if (!matchDoc.exists) return null;
    return (typeof matchDoc.data === 'function' ? matchDoc.data() : matchDoc.data) || null;
  }
  return matchDoc;
}

/** caller와 target이 이 match의 활성 participant인지. */
function isActiveMatchFor(matchDoc, callerUid, targetUid) {
  const data = matchDataOf(matchDoc);
  if (!data) return false;
  const participants = Array.isArray(data.participants) ? data.participants : [];
  if (!participants.includes(callerUid) || !participants.includes(targetUid)) {
    return false;
  }
  // unmatch된(비활성) match는 차단. unmatchedBy에 하나라도 있으면 해제 상태.
  const unmatchedBy = Array.isArray(data.unmatchedBy) ? data.unmatchedBy : [];
  if (unmatchedBy.length > 0) return false;
  return true;
}

/**
 * 접근 계약 검증. 통과하면 { relation } 반환, 아니면 HttpsError throw.
 * users private 문서는 여기서 읽지 않는다(match 문서/blocks 서브컬렉션/Auth만).
 *
 * @param {object} p
 * @param {string} p.callerUid
 * @param {string} p.targetUid
 * @param {Function} p.HttpsError  생성자
 * @param {(matchId:string)=>Promise<any>} p.getMatchDoc
 * @param {(ownerUid:string, blockedUid:string)=>Promise<boolean>} p.blockExists
 * @param {(uid:string)=>Promise<any>} p.getAuthUser  orphan 판정용(존재 안 하면 throw)
 * @param {{warn?:Function}} [p.logger]
 */
async function assertProfileInsightAccess({
  callerUid,
  targetUid,
  HttpsError,
  getMatchDoc,
  blockExists,
  getAuthUser,
  logger,
}) {
  const denyAccess = (category) => {
    if (logger && typeof logger.warn === 'function') {
      logger.warn(
        JSON.stringify({
          fn: 'generateProfileInsight',
          category,
          callerHash: safeUidHash(callerUid),
          targetHash: safeUidHash(targetUid),
          retryable: false,
        }),
      );
    }
    // target 존재 여부를 과도하게 노출하지 않도록 문구는 항상 일반적.
    return new HttpsError('permission-denied', '이 프로필에 접근할 권한이 없어요.');
  };

  // 1) self 는 항상 허용(정의상 Auth에 존재, block/무관).
  if (callerUid === targetUid) {
    return { relation: 'self' };
  }

  // 2) 활성 match participant 인지 — 서버 파생 matchId 로 확인.
  const matchId = deriveMatchId(callerUid, targetUid);
  const matchDoc = await getMatchDoc(matchId);
  if (!isActiveMatchFor(matchDoc, callerUid, targetUid)) {
    throw denyAccess('access_denied_no_active_match');
  }

  // 3) 양방향 block 관계면 차단.
  const [callerBlockedTarget, targetBlockedCaller] = await Promise.all([
    blockExists(callerUid, targetUid),
    blockExists(targetUid, callerUid),
  ]);
  if (callerBlockedTarget === true || targetBlockedCaller === true) {
    throw denyAccess('access_denied_block');
  }

  // 4) orphan 차단 — publicProfiles/users 문서 존재만으로 활성 계정이라 보지
  //    않고 Firebase Auth 에서 실제 존재를 확인한다. 원문 오류는 노출 금지.
  try {
    await getAuthUser(targetUid);
  } catch (error) {
    if (logger && typeof logger.warn === 'function') {
      logger.warn(
        JSON.stringify({
          fn: 'generateProfileInsight',
          category: 'access_denied_orphan',
          callerHash: safeUidHash(callerUid),
          targetHash: safeUidHash(targetUid),
          retryable: false,
        }),
      );
    }
    throw new HttpsError(
      'failed-precondition',
      '이 프로필은 지금 분석할 수 없어요.',
    );
  }

  return { relation: 'match' };
}

// profile insight 프롬프트/해시가 쓰는 공개 프로필 필드(사진 포함).
// birthDate 는 여기 없음 — 사주 파생에만 쓰고 users 에서 최소로 읽는다.
const INSIGHT_PUBLIC_FIELDS = Object.freeze([
  'photoUrls',
  'bio',
  'interests',
  'personalityTags',
  'idealTags',
  'relationshipGoal',
  'mbti',
]);

// users 문서에서 읽을 최소 필드(사주용 birthDate + 캐시 필드).
const INSIGHT_USER_FIELD_MASK = Object.freeze(['birthDate', 'profileInsight']);

/**
 * 프롬프트/해시 입력용 소스 데이터 조립.
 * 공개 필드는 publicProfiles 를 우선 사용하고, birthDate 만 users 에서 받는다.
 * 반환 객체의 필드/타입은 기존 users 문서 기반과 동일해, profileInsightHash /
 * profileInsightInputFromData 에 그대로 넘기면 AI 입력·해시가 기존과 같다.
 * email/phone/fcmTokens/location/jelly/boost/discoveryFilter 는 포함하지 않는다.
 */
function buildInsightSourceData({ publicData, birthDate }) {
  const p = publicData || {};
  return {
    photoUrls: Array.isArray(p.photoUrls) ? p.photoUrls : [],
    bio: typeof p.bio === 'string' ? p.bio : '',
    interests: Array.isArray(p.interests) ? p.interests : [],
    personalityTags: Array.isArray(p.personalityTags) ? p.personalityTags : [],
    idealTags: Array.isArray(p.idealTags) ? p.idealTags : [],
    relationshipGoal: p.relationshipGoal != null ? p.relationshipGoal : null,
    mbti: p.mbti != null ? p.mbti : null,
    // birthDate 는 users 원문(Timestamp) 그대로 — datePartsInSeoul 이 파싱한다.
    // 원문은 사주 파생에만 쓰이고 프롬프트에는 파생값만 들어간다.
    birthDate: birthDate != null ? birthDate : null,
  };
}

module.exports = {
  safeUidHash,
  deriveMatchId,
  isActiveMatchFor,
  assertProfileInsightAccess,
  buildInsightSourceData,
  INSIGHT_PUBLIC_FIELDS,
  INSIGHT_USER_FIELD_MASK,
};
