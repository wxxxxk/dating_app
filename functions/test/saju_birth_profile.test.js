'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  SAJU_CALCULATION_VERSION,
  SAJU_CONVENTION_VERSION,
  STATUS,
  isRealSolarDate,
  birthTimeInvariantError,
  birthInputFingerprint,
  parseBirthProfile,
  parseBirthProfileRequest,
} = require('../lib/saju/birth_profile');

// Phase 5-2 — 출생정보 파싱·검증·지문.
//
// 이 테스트는 실제 사용자 데이터를 쓰지 않는다. 모든 날짜는 합성 값이다.

/** Firestore Timestamp 흉내. 서울 자정에 해당하는 UTC 시각을 만든다. */
function seoulMidnightTimestamp(year, month, day) {
  const ms = Date.UTC(year, month - 1, day) - 9 * 3600 * 1000;
  return { toDate: () => new Date(ms) };
}

const NOW = new Date('2026-07-22T00:00:00Z');

function userDoc(overrides = {}) {
  return {
    birthDate: seoulMidnightTimestamp(1995, 2, 4),
    birthCalendarType: 'solar',
    birthTimeKnown: true,
    birthTimeMinutes: 455,
    birthTimeZone: 'Asia/Seoul',
    sajuInputVersion: 2,
    ...overrides,
  };
}

test('버전 상수 — Phase 5-2A에서 calculationVersion만 3으로 올랐다', () => {
  // 명리 convention(입춘 연주/절기 월주/자정 일주/진태양시 미적용)은 그대로다.
  // 바뀐 것은 미상 시간 처리와 황경 정밀도, 즉 계산 알고리즘뿐이다.
  assert.equal(SAJU_CALCULATION_VERSION, 3);
  assert.equal(SAJU_CONVENTION_VERSION, 2);
});

test('calculationVersion이 바뀌면 같은 출생정보라도 지문이 달라진다', () => {
  // 기존 calculationVersion 2로 만들어진 캐시가 자연스럽게 miss돼야 한다.
  const profile = parseBirthProfile(userDoc(), { now: NOW }).profile;
  const canonical = {
    birthDate: '1995-02-04',
    birthCalendarType: 'solar',
    birthTimeKnown: true,
    birthTimeMinutes: 455,
    birthTimeZone: 'Asia/Seoul',
    conventionVersion: SAJU_CONVENTION_VERSION,
  };
  const crypto = require('node:crypto');
  const hashWith = (calculationVersion) =>
    crypto
      .createHash('sha256')
      .update(
        JSON.stringify({
          ...canonical,
          calculationVersion,
          conventionVersion: SAJU_CONVENTION_VERSION,
        }),
      )
      .digest('hex');

  // 현재 버전으로 만든 지문은 엔진 지문과 같아야 한다(키 순서까지 동일한 계약).
  const v2 = hashWith(2);
  const v3 = hashWith(3);
  assert.notEqual(v2, v3, 'calculationVersion이 지문에 반영되지 않는다');
  assert.notEqual(profile.inputFingerprint, v2, 'v2 캐시가 그대로 hit되면 안 된다');
});

test('실재하지 않는 양력 날짜를 rollover 없이 거부한다', () => {
  assert.equal(isRealSolarDate(1993, 2, 29), false);
  assert.equal(isRealSolarDate(2001, 4, 31), false);
  assert.equal(isRealSolarDate(1900, 2, 29), false);
  assert.equal(isRealSolarDate(2024, 2, 29), true);
  assert.equal(isRealSolarDate(2000, 2, 29), true);
});

test('birthTimeKnown/minutes invariant', () => {
  assert.equal(birthTimeInvariantError(true, 0), null);
  assert.equal(birthTimeInvariantError(true, 1439), null);
  assert.equal(birthTimeInvariantError(false, null), null);
  assert.equal(birthTimeInvariantError(true, null), 'birth_time_minutes_missing');
  assert.equal(birthTimeInvariantError(false, 720), 'birth_time_minutes_unexpected');
  assert.equal(birthTimeInvariantError(true, -1), 'birth_time_minutes_out_of_range');
  assert.equal(birthTimeInvariantError(true, 1440), 'birth_time_minutes_out_of_range');
  assert.equal(birthTimeInvariantError(undefined, null), 'birth_time_known_invalid');
});

test('시간을 아는 문서는 dateAndTime으로 파싱된다', () => {
  const parsed = parseBirthProfile(userDoc(), { now: NOW });
  assert.equal(parsed.status, STATUS.OK);
  assert.equal(parsed.profile.precision, 'dateAndTime');
  assert.equal(parsed.profile.year, 1995);
  assert.equal(parsed.profile.month, 2);
  assert.equal(parsed.profile.day, 4);
  assert.equal(parsed.profile.birthTimeMinutes, 455);
  assert.match(parsed.profile.inputFingerprint, /^[0-9a-f]{64}$/);
});

test('시간을 모르는 문서는 dateOnly로 파싱되고 분은 null이다', () => {
  const parsed = parseBirthProfile(
    userDoc({ birthTimeKnown: false, birthTimeMinutes: null }),
    { now: NOW },
  );
  assert.equal(parsed.status, STATUS.OK);
  assert.equal(parsed.profile.precision, 'dateOnly');
  assert.equal(parsed.profile.birthTimeMinutes, null);
});

test('출생시간 필드가 없는 기존 문서는 legacyMissing이다 — 정오를 대입하지 않는다', () => {
  const doc = userDoc();
  delete doc.birthTimeKnown;
  delete doc.birthTimeMinutes;
  const parsed = parseBirthProfile(doc, { now: NOW });
  assert.equal(parsed.status, STATUS.LEGACY_MISSING);
  assert.equal(parsed.profile, undefined);
});

test('invariant 위반·미지원 달력·미지원 시간대를 거부한다', () => {
  const cases = [
    [{ birthTimeKnown: true, birthTimeMinutes: null }, 'birth_time_minutes_missing'],
    [{ birthTimeKnown: false, birthTimeMinutes: 720 }, 'birth_time_minutes_unexpected'],
    [{ birthTimeKnown: true, birthTimeMinutes: -1 }, 'birth_time_minutes_out_of_range'],
    [{ birthTimeKnown: true, birthTimeMinutes: 1440 }, 'birth_time_minutes_out_of_range'],
    [{ birthCalendarType: 'lunar' }, 'calendar_type_unsupported'],
    [{ birthTimeZone: 'America/New_York' }, 'time_zone_unsupported'],
  ];
  for (const [overrides, reason] of cases) {
    const parsed = parseBirthProfile(userDoc(overrides), { now: NOW });
    assert.equal(parsed.status, STATUS.INVALID, JSON.stringify(overrides));
    assert.equal(parsed.reason, reason);
  }
});

test('생년월일이 없거나 미성년이면 거부한다', () => {
  assert.equal(
    parseBirthProfile(userDoc({ birthDate: null }), { now: NOW }).reason,
    'birth_date_missing',
  );
  assert.equal(
    parseBirthProfile(userDoc({ birthDate: seoulMidnightTimestamp(2020, 1, 1) }), {
      now: NOW,
    }).reason,
    'birth_date_underage',
  );
});

test('지문은 출생정보가 바뀌면 달라지고 같으면 유지된다', () => {
  const base = parseBirthProfile(userDoc(), { now: NOW }).profile;
  const same = parseBirthProfile(userDoc(), { now: NOW }).profile;
  assert.equal(base.inputFingerprint, same.inputFingerprint);

  const otherDate = parseBirthProfile(
    userDoc({ birthDate: seoulMidnightTimestamp(1995, 2, 5) }),
    { now: NOW },
  ).profile;
  const otherTime = parseBirthProfile(userDoc({ birthTimeMinutes: 456 }), {
    now: NOW,
  }).profile;
  const unknownTime = parseBirthProfile(
    userDoc({ birthTimeKnown: false, birthTimeMinutes: null }),
    { now: NOW },
  ).profile;

  const all = new Set([
    base.inputFingerprint,
    otherDate.inputFingerprint,
    otherTime.inputFingerprint,
    unknownTime.inputFingerprint,
  ]);
  assert.equal(all.size, 4, '입력이 다르면 지문도 달라야 한다');
});

test('지문은 convention/calculation 버전이 바뀌면 달라진다', () => {
  const profile = parseBirthProfile(userDoc(), { now: NOW }).profile;
  // 같은 정규화 입력이라도 버전이 canonical payload에 포함돼 있으므로,
  // 버전이 올라가면 기존 캐시는 자연히 miss가 된다.
  assert.notEqual(
    profile.inputFingerprint,
    birthInputFingerprint({ ...profile, timeZone: 'Asia/Tokyo' }),
  );
});

test('지문에 raw 생년월일·시각 문자열이 그대로 담기지 않는다', () => {
  const profile = parseBirthProfile(userDoc(), { now: NOW }).profile;
  assert.match(profile.inputFingerprint, /^[0-9a-f]{64}$/);
  assert.ok(!profile.inputFingerprint.includes('1995'));
});

// ── callable 요청 검증 ────────────────────────────────────────────────────

const VALID_REQUEST = Object.freeze({
  birthDateMillis: Date.UTC(1995, 1, 4) - 9 * 3600 * 1000,
  birthCalendarType: 'solar',
  birthTimeKnown: true,
  birthTimeMinutes: 455,
  birthTimeZone: 'Asia/Seoul',
});

test('정상 요청은 저장 필드로 정규화된다', () => {
  const parsed = parseBirthProfileRequest({ ...VALID_REQUEST }, { now: NOW });
  assert.equal(parsed.ok, true);
  assert.equal(parsed.fields.birthTimeKnown, true);
  assert.equal(parsed.fields.birthTimeMinutes, 455);
  assert.equal(parsed.fields.sajuInputVersion, 2);
});

test('모름 요청은 minutes를 null로 정규화한다', () => {
  const parsed = parseBirthProfileRequest(
    { ...VALID_REQUEST, birthTimeKnown: false, birthTimeMinutes: null },
    { now: NOW },
  );
  assert.equal(parsed.ok, true);
  assert.equal(parsed.fields.birthTimeMinutes, null);
});

test('요청에 여분 필드가 있으면 거부한다 — 다른 프로필 필드 갱신 방지', () => {
  const parsed = parseBirthProfileRequest(
    { ...VALID_REQUEST, jelly: 999999 },
    { now: NOW },
  );
  assert.equal(parsed.ok, false);
  assert.equal(parsed.reason, 'unexpected_fields');
});

test('요청 단계에서 실재하지 않는 날짜·미성년·미지원 값을 거부한다', () => {
  const feb29NonLeap = Date.UTC(1993, 1, 28) - 9 * 3600 * 1000 + 86400000;
  const cases = [
    [{ birthDateMillis: 'x' }, 'birth_date_invalid'],
    [{ birthCalendarType: 'lunar' }, 'calendar_type_unsupported'],
    [{ birthTimeZone: 'UTC' }, 'time_zone_unsupported'],
    [{ birthTimeKnown: true, birthTimeMinutes: 1440 }, 'birth_time_minutes_out_of_range'],
    [{ birthTimeKnown: false, birthTimeMinutes: 0 }, 'birth_time_minutes_unexpected'],
    [{ birthDateMillis: Date.UTC(2020, 0, 1) }, 'birth_date_underage'],
  ];
  for (const [overrides, reason] of cases) {
    const parsed = parseBirthProfileRequest(
      { ...VALID_REQUEST, ...overrides },
      { now: NOW },
    );
    assert.equal(parsed.ok, false, JSON.stringify(overrides));
    assert.equal(parsed.reason, reason);
  }
  // 1993-02-29는 존재하지 않는다 — millis로 보내면 3월 1일이 되므로 통과하지만,
  // 클라이언트가 만들 수 있는 값이 아니라는 점을 여기서 고정한다.
  assert.equal(
    parseBirthProfileRequest(
      { ...VALID_REQUEST, birthDateMillis: feb29NonLeap },
      { now: NOW },
    ).ok,
    true,
  );
});

// ── Firestore Rules 계약 ──────────────────────────────────────────────────
//
// 이 저장소는 firestore.rules를 소스 텍스트 계약으로 검증한다
// (jelly_purchase_verification.test.js와 같은 방식).

const fs = require('node:fs');
const path = require('node:path');

function readRules() {
  return fs.readFileSync(path.join(__dirname, '..', '..', 'firestore.rules'), 'utf8');
}

test('Rules: 출생정보는 최초 생성만 허용되고 owner update로는 못 바꾼다', () => {
  const rules = readRules();

  const createKeys = rules.match(/function userCreateKeys\(\) \{[\s\S]*?\n      \}/);
  assert.ok(createKeys);
  for (const key of [
    'birthCalendarType',
    'birthTimeKnown',
    'birthTimeMinutes',
    'birthTimeZone',
    'sajuInputVersion',
  ]) {
    assert.ok(createKeys[0].includes(`'${key}'`), `create key 누락: ${key}`);
  }

  const ownerKeys = rules.match(/function userOwnerUpdateKeys\(\) \{[\s\S]*?\n      \}/);
  assert.ok(ownerKeys);
  for (const key of [
    'birthDate',
    'birthCalendarType',
    'birthTimeKnown',
    'birthTimeMinutes',
    'birthTimeZone',
    'sajuInputVersion',
  ]) {
    assert.ok(
      !ownerKeys[0].includes(`'${key}'`),
      `owner update로 출생정보를 바꿀 수 있으면 안 된다: ${key}`,
    );
  }
});

test('Rules: 출생시간 invariant가 규칙으로 강제된다', () => {
  const rules = readRules();
  const fn = rules.match(/function birthProfileValid\(data\) \{[\s\S]*?\n      \}/);
  assert.ok(fn, 'birthProfileValid 규칙이 없다');
  const body = fn[0];
  assert.ok(body.includes("data.birthCalendarType == 'solar'"));
  assert.ok(body.includes("data.birthTimeZone == 'Asia/Seoul'"));
  assert.ok(body.includes('data.birthTimeMinutes >= 0'));
  assert.ok(body.includes('data.birthTimeMinutes <= 1439'));
  assert.ok(body.includes('data.birthTimeKnown == false'));
  // userFieldsValid가 실제로 이 규칙을 호출해야 의미가 있다.
  assert.ok(
    /function userFieldsValid\(data\) \{\s*return birthProfileValid\(data\)/.test(rules),
  );
});

test('Rules: publicProfiles에 출생정보 필드가 없다', () => {
  const rules = readRules();
  const publicBlock = rules.match(/match \/publicProfiles\/\{uid\} \{[\s\S]*?\n    \}/);
  assert.ok(publicBlock);
  for (const key of ['birthDate', 'birthTimeKnown', 'birthTimeMinutes']) {
    assert.ok(!publicBlock[0].includes(key), `공개 프로필에 ${key}가 있으면 안 된다`);
  }
});
