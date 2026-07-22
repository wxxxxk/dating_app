'use strict';

/**
 * 출생정보(private birth profile) 파싱·검증·지문 생성 — Phase 5-2.
 *
 * users/{uid} 비공개 문서에만 존재하는 출생정보를 읽어, 사주 계산 엔진이 쓸
 * 정규화된 입력으로 바꾼다. 클라이언트가 보낸 계산 결과(attrs)는 신뢰하지 않고
 * 항상 이 모듈이 만든 값만 근거로 쓴다.
 *
 * 로그 정책: 이 모듈이 다루는 값(생년월일·시각·지문 전체)은 절대 로그에 남기지
 * 않는다. 호출부는 status/precision/uidHash 수준만 기록한다.
 */

const crypto = require('crypto');

/** 계산 알고리즘 버전. 계산 결과가 달라지는 변경이면 올린다. */
const SAJU_CALCULATION_VERSION = 2;

/** 계산 convention 버전(입춘 연주 / 절기 월주 / 자정 일주 / 진태양시 미적용). */
const SAJU_CONVENTION_VERSION = 2;

/** 이 앱이 정식 지원하는 유일한 달력·시간대. */
const SUPPORTED_CALENDAR_TYPE = 'solar';
const SUPPORTED_TIME_ZONE = 'Asia/Seoul';

/** 회원가입 정책과 동일한 최소 나이. */
const MIN_AGE_YEARS = 18;

/** birthTimeMinutes 허용 범위(자정으로부터의 분). */
const MIN_BIRTH_TIME_MINUTES = 0;
const MAX_BIRTH_TIME_MINUTES = 1439;

const STATUS = Object.freeze({
  OK: 'ok',
  LEGACY_MISSING: 'legacyMissing',
  INVALID: 'invalid',
});

/** Firestore Timestamp를 Asia/Seoul 기준 연/월/일로 바꾼다. */
function datePartsInSeoul(timestamp) {
  if (!timestamp || typeof timestamp.toDate !== 'function') return null;
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone: SUPPORTED_TIME_ZONE,
    year: 'numeric',
    month: 'numeric',
    day: 'numeric',
  }).formatToParts(timestamp.toDate());
  const value = (type) => Number(parts.find((part) => part.type === type)?.value);
  const year = value('year');
  const month = value('month');
  const day = value('day');
  if (!year || !month || !day) return null;
  return { year, month, day };
}

/** 그레고리력에 실제로 존재하는 날짜인지. rollover에 의존하지 않는다. */
function isRealSolarDate(year, month, day) {
  if (!Number.isInteger(year) || !Number.isInteger(month) || !Number.isInteger(day)) {
    return false;
  }
  if (year < 1900 || year > 2200) return false;
  if (month < 1 || month > 12) return false;
  if (day < 1 || day > 31) return false;
  const probe = new Date(Date.UTC(year, month - 1, day));
  return (
    probe.getUTCFullYear() === year &&
    probe.getUTCMonth() === month - 1 &&
    probe.getUTCDate() === day
  );
}

/** [reference] 시점에 만 나이가 [MIN_AGE_YEARS] 이상인지. */
function meetsMinimumAge({ year, month, day }, reference = new Date()) {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone: SUPPORTED_TIME_ZONE,
    year: 'numeric',
    month: 'numeric',
    day: 'numeric',
  }).formatToParts(reference);
  const value = (type) => Number(parts.find((part) => part.type === type)?.value);
  const ry = value('year');
  const rm = value('month');
  const rd = value('day');
  let age = ry - year;
  const hadBirthday = rm > month || (rm === month && rd >= day);
  if (!hadBirthday) age -= 1;
  return age >= MIN_AGE_YEARS;
}

/** birthTimeKnown / birthTimeMinutes 조합이 계약을 지키는지. */
function birthTimeInvariantError(known, minutes) {
  if (typeof known !== 'boolean') return 'birth_time_known_invalid';
  if (known) {
    if (!Number.isInteger(minutes)) return 'birth_time_minutes_missing';
    if (minutes < MIN_BIRTH_TIME_MINUTES || minutes > MAX_BIRTH_TIME_MINUTES) {
      return 'birth_time_minutes_out_of_range';
    }
    return null;
  }
  if (minutes !== null && minutes !== undefined) return 'birth_time_minutes_unexpected';
  return null;
}

/**
 * 정규화된 출생정보의 SHA-256 지문.
 *
 * 캐시 유효성 판정에만 쓴다. raw 생년월일·시각을 캐시 문서에 중복 저장하지
 * 않기 위한 장치이므로, 지문 자체도 로그에 전체를 남기지 않는다.
 */
function birthInputFingerprint(normalized) {
  const canonical = {
    birthDate: `${String(normalized.year).padStart(4, '0')}-${String(
      normalized.month,
    ).padStart(2, '0')}-${String(normalized.day).padStart(2, '0')}`,
    birthCalendarType: normalized.calendarType,
    birthTimeKnown: normalized.birthTimeKnown,
    birthTimeMinutes: normalized.birthTimeKnown ? normalized.birthTimeMinutes : null,
    birthTimeZone: normalized.timeZone,
    calculationVersion: SAJU_CALCULATION_VERSION,
    conventionVersion: SAJU_CONVENTION_VERSION,
  };
  return crypto.createHash('sha256').update(JSON.stringify(canonical)).digest('hex');
}

/**
 * users/{uid} 문서 데이터에서 출생정보를 읽어 정규화한다.
 *
 * 반환:
 * - `{ status: 'legacyMissing' }` — 출생시간 필드가 아직 없는 기존 사용자.
 *   **정오를 대입하거나 unknown으로 단정하지 않는다.** 호출부가 보완 안내를 띄운다.
 * - `{ status: 'invalid', reason }` — 계약을 어긴 값.
 * - `{ status: 'ok', profile }` — 계산 엔진에 넘길 정규화 입력.
 */
function parseBirthProfile(data, { now = new Date() } = {}) {
  const source = data || {};
  const parts = datePartsInSeoul(source.birthDate);
  if (!parts) return { status: STATUS.INVALID, reason: 'birth_date_missing' };
  if (!isRealSolarDate(parts.year, parts.month, parts.day)) {
    return { status: STATUS.INVALID, reason: 'birth_date_not_real' };
  }
  if (!meetsMinimumAge(parts, now)) {
    return { status: STATUS.INVALID, reason: 'birth_date_underage' };
  }

  // 출생시간 필드 자체가 없는 문서는 Phase 5-2 이전에 만들어진 것이다.
  if (source.birthTimeKnown === undefined || source.birthTimeKnown === null) {
    return { status: STATUS.LEGACY_MISSING };
  }

  const calendarType = source.birthCalendarType ?? SUPPORTED_CALENDAR_TYPE;
  if (calendarType !== SUPPORTED_CALENDAR_TYPE) {
    return { status: STATUS.INVALID, reason: 'calendar_type_unsupported' };
  }

  const timeZone = source.birthTimeZone ?? SUPPORTED_TIME_ZONE;
  if (timeZone !== SUPPORTED_TIME_ZONE) {
    return { status: STATUS.INVALID, reason: 'time_zone_unsupported' };
  }

  const known = source.birthTimeKnown;
  const minutes = source.birthTimeMinutes === undefined ? null : source.birthTimeMinutes;
  const invariantError = birthTimeInvariantError(known, minutes);
  if (invariantError) return { status: STATUS.INVALID, reason: invariantError };

  const normalized = {
    calendarType,
    year: parts.year,
    month: parts.month,
    day: parts.day,
    birthTimeKnown: known,
    birthTimeMinutes: known ? minutes : null,
    timeZone,
    precision: known ? 'dateAndTime' : 'dateOnly',
  };
  normalized.inputFingerprint = birthInputFingerprint(normalized);
  return { status: STATUS.OK, profile: normalized };
}

/**
 * 출생정보 저장 callable의 입력을 검증한다.
 *
 * 클라이언트가 보내는 값이므로 exact shape만 통과시킨다. 여분 key가 있으면
 * 거부해, 이 경로로 다른 필드가 함께 갱신되는 일이 없게 한다.
 */
const BIRTH_PROFILE_REQUEST_KEYS = Object.freeze([
  'birthDateMillis',
  'birthCalendarType',
  'birthTimeKnown',
  'birthTimeMinutes',
  'birthTimeZone',
]);

function parseBirthProfileRequest(data, { now = new Date() } = {}) {
  if (!data || typeof data !== 'object' || Array.isArray(data)) {
    return { ok: false, reason: 'payload_invalid' };
  }
  const extra = Object.keys(data).filter((k) => !BIRTH_PROFILE_REQUEST_KEYS.includes(k));
  if (extra.length > 0) return { ok: false, reason: 'unexpected_fields' };

  const millis = data.birthDateMillis;
  if (!Number.isInteger(millis)) return { ok: false, reason: 'birth_date_invalid' };

  const fakeTimestamp = { toDate: () => new Date(millis) };
  const parts = datePartsInSeoul(fakeTimestamp);
  if (!parts) return { ok: false, reason: 'birth_date_invalid' };
  if (!isRealSolarDate(parts.year, parts.month, parts.day)) {
    return { ok: false, reason: 'birth_date_not_real' };
  }
  if (!meetsMinimumAge(parts, now)) return { ok: false, reason: 'birth_date_underage' };

  const calendarType = data.birthCalendarType;
  if (calendarType !== SUPPORTED_CALENDAR_TYPE) {
    return { ok: false, reason: 'calendar_type_unsupported' };
  }
  const timeZone = data.birthTimeZone;
  if (timeZone !== SUPPORTED_TIME_ZONE) {
    return { ok: false, reason: 'time_zone_unsupported' };
  }

  const known = data.birthTimeKnown;
  const minutes = data.birthTimeMinutes === undefined ? null : data.birthTimeMinutes;
  const invariantError = birthTimeInvariantError(known, minutes);
  if (invariantError) return { ok: false, reason: invariantError };

  return {
    ok: true,
    fields: {
      birthDateMillis: millis,
      birthCalendarType: calendarType,
      birthTimeKnown: known,
      birthTimeMinutes: known ? minutes : null,
      birthTimeZone: timeZone,
      sajuInputVersion: SAJU_CONVENTION_VERSION,
    },
  };
}

module.exports = {
  SAJU_CALCULATION_VERSION,
  SAJU_CONVENTION_VERSION,
  SUPPORTED_CALENDAR_TYPE,
  SUPPORTED_TIME_ZONE,
  MIN_AGE_YEARS,
  MIN_BIRTH_TIME_MINUTES,
  MAX_BIRTH_TIME_MINUTES,
  BIRTH_PROFILE_REQUEST_KEYS,
  STATUS,
  datePartsInSeoul,
  isRealSolarDate,
  meetsMinimumAge,
  birthTimeInvariantError,
  birthInputFingerprint,
  parseBirthProfile,
  parseBirthProfileRequest,
};
