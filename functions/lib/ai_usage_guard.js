'use strict';

// ============================================================================
// AI usage guard — 서버 전용 호출 남용 방지 (Phase 0-E-2)
//
// generateProfileInsight 같은 외부 AI(비용 발생) callable이 임의 targetUid /
// refresh 반복 호출로 과금 폭증하지 않도록 서버 측에서 원자적으로 제한한다.
//
// 세 가지를 한 곳에서 담당한다.
//   1) caller UID 기준 rate limit (시간당/일일 quota + 연속 호출 cooldown)
//   2) refresh 신뢰 제거 (같은 caller+target+inputHash refresh cooldown)
//   3) 동시 중복 생성 방지 (caller+target+inputHash 서버 lease)
//
// 원칙:
//   - Admin SDK 전용 경로(_internalAiUsage / _internalAiLeases)에만 쓴다.
//     이 컬렉션은 firestore.rules 어떤 match에도 걸리지 않아 클라이언트가
//     직접 읽거나 쓸 수 없다(기본 deny).
//   - 모든 시간 비교는 서버 시각(now())만 신뢰한다. 클라이언트 시간은 쓰지 않는다.
//   - 숫자/타임스탬프는 방어적으로 정규화한다(NaN/음수/미래값/비정상 shape).
//   - 로그에는 raw uid/targetUid/PII를 남기지 않고 해시(uidHash)만 남긴다.
//
// 순수 결정 로직(evaluateGenerationSlot 등)은 I/O와 분리해 단위 테스트가 쉽다.
// ============================================================================

const crypto = require('crypto');

const PROFILE_INSIGHT_USAGE_POLICY = Object.freeze({
  functionName: 'generateProfileInsight',
  hourlyLimit: 10,
  dailyLimit: 30,
  cooldownMs: 10 * 1000, // 연속 호출 최소 간격
  refreshCooldownMs: 24 * 60 * 60 * 1000, // 같은 target+inputHash refresh 재생성 간격
  leaseTtlMs: 60 * 1000, // 진행 중 lease 만료(비정상 종료 대비)
  hourMs: 60 * 60 * 1000,
  dayMs: 24 * 60 * 60 * 1000,
});

const SLOT_DECISION = Object.freeze({
  ALLOW: 'ALLOW', // 새 외부 AI 호출 허용 (quota 소비됨)
  RETURN_CACHE: 'RETURN_CACHE', // refresh cooldown 미충족 — 캐시로
  REJECT_INFLIGHT: 'REJECT_INFLIGHT', // 동일 요청 진행 중 — 중복 호출 금지
  REJECT_COOLDOWN: 'REJECT_COOLDOWN', // 연속 호출 cooldown 미충족
  REJECT_HOURLY: 'REJECT_HOURLY', // 시간당 quota 초과
  REJECT_DAILY: 'REJECT_DAILY', // 일일 quota 초과
});

// 호출부가 결정을 어떻게 처리할지로 축약: 생성 / 캐시반환 / 거부.
const SLOT_OUTCOME = Object.freeze({
  GENERATE: 'GENERATE',
  RETURN_CACHE: 'RETURN_CACHE',
  REJECT: 'REJECT',
});

/** 음수/NaN/비정상 값을 0으로 정규화한 정수 카운트. */
function sanitizeCount(value) {
  return Number.isFinite(value) && value > 0 ? Math.floor(value) : 0;
}

/** 음수/NaN/비정상 값을 0으로 정규화한 epoch(ms) 타임스탬프. */
function sanitizeTimestamp(value) {
  return Number.isFinite(value) && value > 0 ? Math.floor(value) : 0;
}

/** 로그용 안전 uid 해시(원문 uid 노출 금지). */
function safeUidHash(uid) {
  return crypto.createHash('sha256').update(String(uid)).digest('hex').slice(0, 8);
}

/**
 * lease 문서 ID. raw uid/targetUid를 경로에 그대로 넣지 않도록 deterministic
 * 해시를 쓴다. 같은 (function, caller, target, inputHash)면 항상 같은 ID.
 */
function buildLeaseId(functionName, callerUid, targetUid, inputHash) {
  return crypto
    .createHash('sha256')
    .update(`${functionName} ${callerUid} ${targetUid} ${inputHash}`)
    .digest('hex');
}

/** rate limit 카운터 문서를 window rollover까지 반영해 정규화한다. */
function normalizeUsageDoc(doc, now, policy) {
  let hourWindowStart = sanitizeTimestamp(doc && doc.hourWindowStart);
  let hourCount = sanitizeCount(doc && doc.hourCount);
  let dayWindowStart = sanitizeTimestamp(doc && doc.dayWindowStart);
  let dayCount = sanitizeCount(doc && doc.dayCount);
  const lastAttemptAt = sanitizeTimestamp(doc && doc.lastAttemptAt);

  // window가 없거나(0), 미래값(비정상)이거나, 지났으면 리셋.
  if (
    hourWindowStart === 0 ||
    hourWindowStart > now ||
    now - hourWindowStart >= policy.hourMs
  ) {
    hourWindowStart = now;
    hourCount = 0;
  }
  if (
    dayWindowStart === 0 ||
    dayWindowStart > now ||
    now - dayWindowStart >= policy.dayMs
  ) {
    dayWindowStart = now;
    dayCount = 0;
  }
  return { hourWindowStart, hourCount, dayWindowStart, dayCount, lastAttemptAt };
}

/** lease 문서를 정규화한다. */
function normalizeLeaseDoc(doc) {
  return {
    leaseExpiresAt: sanitizeTimestamp(doc && doc.leaseExpiresAt),
    lastGeneratedAt: sanitizeTimestamp(doc && doc.lastGeneratedAt),
  };
}

/**
 * 순수 결정 함수: usage/lease 문서와 now를 받아 슬롯 결정을 반환한다.
 * ALLOW일 때만 usageUpdate/leaseUpdate(적용할 쓰기 payload)를 함께 준다.
 *
 * @param {object|null} usageDoc  현재 rate limit 카운터 문서
 * @param {object|null} leaseDoc  현재 lease 문서
 * @param {number} now  서버 시각(ms)
 * @param {object} policy  PROFILE_INSIGHT_USAGE_POLICY 형태
 * @param {boolean} isRefresh  클라이언트 refresh 요청 여부(강제 아님)
 * @param {boolean} cacheValid  같은 inputHash 유효 캐시 존재 여부
 */
function evaluateGenerationSlot({
  usageDoc,
  leaseDoc,
  now,
  policy,
  isRefresh,
  cacheValid,
}) {
  const lease = normalizeLeaseDoc(leaseDoc);

  // 1) refresh cooldown — 같은 캐시를 최근에 이미 생성했으면 재생성하지 않는다.
  //    입력이 바뀐(cacheValid=false) 정상 신규 생성에는 적용하지 않는다.
  if (
    isRefresh &&
    cacheValid &&
    lease.lastGeneratedAt > 0 &&
    now - lease.lastGeneratedAt < policy.refreshCooldownMs
  ) {
    return { decision: SLOT_DECISION.RETURN_CACHE };
  }

  // 2) 동시 진행 중 lease가 살아있으면 새 외부 호출 금지(중복 방지).
  //    만료된(<= now) lease는 takeover 가능하므로 통과.
  if (lease.leaseExpiresAt > now) {
    return { decision: SLOT_DECISION.REJECT_INFLIGHT };
  }

  // 3) rate limit — cooldown / 시간당 / 일일.
  const usage = normalizeUsageDoc(usageDoc, now, policy);
  if (usage.lastAttemptAt > 0 && now - usage.lastAttemptAt < policy.cooldownMs) {
    return { decision: SLOT_DECISION.REJECT_COOLDOWN };
  }
  if (usage.hourCount >= policy.hourlyLimit) {
    return { decision: SLOT_DECISION.REJECT_HOURLY };
  }
  if (usage.dayCount >= policy.dailyLimit) {
    return { decision: SLOT_DECISION.REJECT_DAILY };
  }

  // 4) 허용 — 카운터 증가 + lease 획득.
  const usageUpdate = {
    hourWindowStart: usage.hourWindowStart,
    hourCount: usage.hourCount + 1,
    dayWindowStart: usage.dayWindowStart,
    dayCount: usage.dayCount + 1,
    lastAttemptAt: now,
  };
  const leaseUpdate = {
    leaseExpiresAt: now + policy.leaseTtlMs,
    lastGeneratedAt: lease.lastGeneratedAt, // 성공 시 release에서 갱신
  };
  return { decision: SLOT_DECISION.ALLOW, usageUpdate, leaseUpdate };
}

/** 슬롯 결정을 호출부 행동(생성/캐시/거부)으로 축약. */
function resolveSlotOutcome(decision, cacheValid) {
  if (decision === SLOT_DECISION.ALLOW) return SLOT_OUTCOME.GENERATE;
  if (cacheValid) return SLOT_OUTCOME.RETURN_CACHE;
  return SLOT_OUTCOME.REJECT;
}

/**
 * 실제 Firestore(db) 위에서 도는 guard 인스턴스.
 * transaction으로 usage/lease를 race-safe하게 다룬다.
 *
 * @param {object} params
 * @param {FirebaseFirestore.Firestore} params.db
 * @param {object} [params.policy]  기본 PROFILE_INSIGHT_USAGE_POLICY
 * @param {() => number} [params.now]  기본 Date.now (서버 시각)
 * @param {{log?:Function}} [params.logger]  선택 로거(해시만 기록)
 */
function createAiUsageGuard({
  db,
  policy = PROFILE_INSIGHT_USAGE_POLICY,
  now = () => Date.now(),
  logger = null,
} = {}) {
  if (!db) throw new Error('createAiUsageGuard: db is required');

  const usageCollection = '_internalAiUsage';
  const leaseCollection = '_internalAiLeases';

  function usageRefFor(callerUid) {
    return db
      .collection(usageCollection)
      .doc(callerUid)
      .collection('functions')
      .doc(policy.functionName);
  }

  function leaseRefFor(leaseId) {
    return db.collection(leaseCollection).doc(leaseId);
  }

  function record(callerUid, decision) {
    if (!logger || typeof logger.log !== 'function') return;
    logger.log(
      `event=ai_usage_guard fn=${policy.functionName} uidHash=${safeUidHash(
        callerUid,
      )} decision=${decision}`,
    );
  }

  /**
   * 외부 AI 호출 직전 슬롯을 원자적으로 확보한다.
   * @returns {Promise<{decision:string, outcome:string}>}
   */
  async function acquireGenerationSlot({
    callerUid,
    targetUid,
    inputHash,
    isRefresh,
    cacheValid,
  }) {
    const leaseId = buildLeaseId(
      policy.functionName,
      callerUid,
      targetUid,
      inputHash,
    );
    const usageRef = usageRefFor(callerUid);
    const leaseRef = leaseRefFor(leaseId);
    const nowMs = now();

    const decision = await db.runTransaction(async (tx) => {
      const [usageSnap, leaseSnap] = await Promise.all([
        tx.get(usageRef),
        tx.get(leaseRef),
      ]);
      const usageDoc = usageSnap.exists ? usageSnap.data() : null;
      const leaseDoc = leaseSnap.exists ? leaseSnap.data() : null;
      const result = evaluateGenerationSlot({
        usageDoc,
        leaseDoc,
        now: nowMs,
        policy,
        isRefresh: isRefresh === true,
        cacheValid: cacheValid === true,
      });
      if (result.decision === SLOT_DECISION.ALLOW) {
        tx.set(usageRef, result.usageUpdate, { merge: true });
        tx.set(leaseRef, result.leaseUpdate, { merge: true });
      }
      return result.decision;
    });

    record(callerUid, decision);
    return {
      decision,
      outcome: resolveSlotOutcome(decision, cacheValid === true),
    };
  }

  /**
   * 외부 AI 호출 종료 후 lease를 해제한다.
   * 성공 시 lastGeneratedAt을 서버 시각으로 기록해 refresh cooldown을 시작한다.
   * 실패 시 lease만 풀어(재시도 가능) lastGeneratedAt은 건드리지 않는다.
   */
  async function releaseGenerationSlot({
    callerUid,
    targetUid,
    inputHash,
    success,
  }) {
    const leaseId = buildLeaseId(
      policy.functionName,
      callerUid,
      targetUid,
      inputHash,
    );
    const leaseRef = leaseRefFor(leaseId);
    const payload = { leaseExpiresAt: 0 };
    if (success === true) {
      payload.lastGeneratedAt = now();
    }
    await leaseRef.set(payload, { merge: true });
  }

  return {
    policy,
    acquireGenerationSlot,
    releaseGenerationSlot,
    usageRefFor,
    leaseRefFor,
  };
}

module.exports = {
  PROFILE_INSIGHT_USAGE_POLICY,
  SLOT_DECISION,
  SLOT_OUTCOME,
  sanitizeCount,
  sanitizeTimestamp,
  safeUidHash,
  buildLeaseId,
  normalizeUsageDoc,
  normalizeLeaseDoc,
  evaluateGenerationSlot,
  resolveSlotOutcome,
  createAiUsageGuard,
};
