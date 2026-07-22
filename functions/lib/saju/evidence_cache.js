'use strict';

/**
 * 사주·궁합 캐시 유효성 판정 — Phase 5-3.
 *
 * index.js 안에 있던 판정 로직을 옮겼다. 순수 함수라 직접 테스트할 수 있고,
 * index.js는 callable orchestration에 집중한다.
 *
 * 버전 축이 넷이다:
 * - calculationVersion   4주 계산 알고리즘 (현재 3)
 * - conventionVersion    명리 convention (현재 2)
 * - evidenceVersion      구조화된 근거 계약 (현재 1)
 * - interpretationVersion 문구 버전 (index.js의 TEXT_CONTENT_VERSION)
 *
 * 어느 하나라도 올라가면 기존 캐시는 자연 miss된다. raw 생년월일·시각은 캐시
 * metadata에 넣지 않고 inputFingerprint만 저장한다.
 */

const {
  SAJU_CALCULATION_VERSION,
  SAJU_CONVENTION_VERSION,
} = require('./birth_profile');
const { SAJU_EVIDENCE_VERSION } = require('./saju_evidence_v1');

/** 개인 사주 캐시에 붙일 metadata. */
function sajuCacheMetadata(profile, interpretationVersion) {
  return {
    calculationVersion: SAJU_CALCULATION_VERSION,
    conventionVersion: SAJU_CONVENTION_VERSION,
    interpretationVersion,
    inputFingerprint: profile.inputFingerprint,
  };
}

/** 구조화된 근거를 쓰는 개인 캐시 metadata. evidenceVersion이 추가된다. */
function sajuEvidenceCacheMetadata(profile, interpretationVersion) {
  return {
    ...sajuCacheMetadata(profile, interpretationVersion),
    evidenceVersion: SAJU_EVIDENCE_VERSION,
  };
}

/**
 * 개인 캐시가 현재 버전·출생정보로 만들어졌는지.
 *
 * metadata가 아예 없는 옛 캐시는 항상 miss다 — production 캐시를 일괄 삭제하지
 * 않고 자연스럽게 재생성되게 하기 위함이다.
 */
function isCurrentSajuCache(
  cached,
  profile,
  interpretationVersion,
  { requireEvidenceVersion = false } = {},
) {
  const base = !!(
    cached &&
    cached.calculationVersion === SAJU_CALCULATION_VERSION &&
    cached.conventionVersion === SAJU_CONVENTION_VERSION &&
    cached.interpretationVersion === interpretationVersion &&
    typeof cached.inputFingerprint === 'string' &&
    cached.inputFingerprint === profile.inputFingerprint
  );
  if (!base) return false;
  if (!requireEvidenceVersion) return true;
  return cached.evidenceVersion === SAJU_EVIDENCE_VERSION;
}

/**
 * 궁합 캐시 metadata.
 *
 * 참가자 지문은 first/second 자리로만 저장한다 — **실제 UID를 key로 쓰지 않는다.**
 * 순서는 매치 문서의 canonical participants order를 그대로 따르므로,
 * 누가 호출했는지에 따라 캐시가 갈리지 않는다.
 */
function matchEvidenceCacheMetadata({
  firstFingerprint,
  secondFingerprint,
  interpretationVersion,
}) {
  return {
    calculationVersion: SAJU_CALCULATION_VERSION,
    conventionVersion: SAJU_CONVENTION_VERSION,
    evidenceVersion: SAJU_EVIDENCE_VERSION,
    interpretationVersion,
    participantFingerprints: {
      first: firstFingerprint,
      second: secondFingerprint,
    },
  };
}

/** 궁합 캐시가 현재 버전과 두 참가자의 출생정보로 만들어졌는지. */
function isCurrentMatchEvidenceCache(cached, expected) {
  const fingerprints = cached && cached.participantFingerprints;
  return !!(
    cached &&
    cached.calculationVersion === expected.calculationVersion &&
    cached.conventionVersion === expected.conventionVersion &&
    cached.evidenceVersion === expected.evidenceVersion &&
    cached.interpretationVersion === expected.interpretationVersion &&
    fingerprints &&
    fingerprints.first === expected.participantFingerprints.first &&
    fingerprints.second === expected.participantFingerprints.second
  );
}

module.exports = {
  sajuCacheMetadata,
  sajuEvidenceCacheMetadata,
  isCurrentSajuCache,
  matchEvidenceCacheMetadata,
  isCurrentMatchEvidenceCache,
};
