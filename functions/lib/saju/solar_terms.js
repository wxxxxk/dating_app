'use strict';

/**
 * 절기(태양 황경) 계산 — Phase 5-2.
 *
 * Flutter가 쓰는 `saju` 패키지(lib/src/utils/solar_longitude.dart,
 * lib/src/core/four_pillars.dart)와 **같은 알고리즘**을 서버로 옮긴 것이다.
 * 서버가 사주 계산의 source of truth가 되려면 연주(입춘 경계)와 월주(절기 경계)를
 * 서버에서 직접 구할 수 있어야 한다.
 *
 * 두 구현이 어긋나면 사용자가 보는 값이 흔들리므로, 동일 입력에 대한 parity를
 * test/saju_engine_v2.test.js의 고정 fixture로 검증한다.
 *
 * 시간대: Asia/Seoul만 지원한다. 다만 한국 표준시는 역사적으로 바뀌었으므로
 * (1954~1961 UTC+8:30, 1987~1988 서머타임 UTC+10:00) 고정 +9시간으로
 * 계산하지 않고, Intl의 IANA 시간대 데이터에서 그 시점의 실제 offset을 찾는다.
 */

const SEOUL = 'Asia/Seoul';

const _offsetFormatter = new Intl.DateTimeFormat('en-US', {
  timeZone: SEOUL,
  timeZoneName: 'longOffset',
});

/** 주어진 UTC 시점에서 Asia/Seoul의 UTC offset(분). 예: 1955년 → 570(+09:30). */
function seoulOffsetMinutes(dateUtc) {
  const part = _offsetFormatter
    .formatToParts(dateUtc)
    .find((p) => p.type === 'timeZoneName');
  const match = /GMT([+-])(\d{2}):(\d{2})/.exec(part ? part.value : '');
  // longOffset은 UTC와 같을 때 'GMT'만 내보낸다 — 한국에는 없는 경우지만 방어한다.
  if (!match) return 0;
  const sign = match[1] === '-' ? -1 : 1;
  return sign * (Number(match[2]) * 60 + Number(match[3]));
}

/**
 * 서울 벽시계 시각(연/월/일 + 자정으로부터의 분)을 UTC Date로 바꾼다.
 *
 * offset 자체가 시점에 따라 달라지므로 한 번에 풀 수 없다. UTC로 가정한 값에서
 * offset을 추정하고 그 offset으로 보정한 시점의 offset을 다시 확인하는
 * 고정점 반복을 쓴다(2회면 수렴한다).
 */
function seoulWallClockToUtc(year, month, day, minutesOfDay = 0) {
  const naiveUtcMs = Date.UTC(year, month - 1, day) + minutesOfDay * 60000;
  let offset = seoulOffsetMinutes(new Date(naiveUtcMs));
  for (let i = 0; i < 3; i += 1) {
    const candidate = new Date(naiveUtcMs - offset * 60000);
    const next = seoulOffsetMinutes(candidate);
    if (next === offset) return candidate;
    offset = next;
  }
  return new Date(naiveUtcMs - offset * 60000);
}

/** 각도를 0~360 범위로 정규화한다. */
function normDeg(x) {
  const v = x % 360;
  return v < 0 ? v + 360 : v;
}

function deg2rad(deg) {
  return (deg * Math.PI) / 180;
}

/**
 * 주어진 UTC 시점의 태양 겉보기 황경(도).
 *
 * saju 패키지 `sunApparentLongitude`와 같은 식(Meeus 저정밀 해)을 쓴다.
 */
function sunApparentLongitude(dateUtc) {
  let y = dateUtc.getUTCFullYear();
  let m = dateUtc.getUTCMonth() + 1;
  const d =
    dateUtc.getUTCDate() +
    (dateUtc.getUTCHours() +
      (dateUtc.getUTCMinutes() + dateUtc.getUTCSeconds() / 60) / 60) /
      24;

  if (m <= 2) {
    y -= 1;
    m += 12;
  }

  const a = Math.floor(y / 100);
  const b = 2 - a + Math.floor(a / 4);
  const jd =
    Math.floor(365.25 * (y + 4716)) +
    Math.floor(30.6001 * (m + 1)) +
    d +
    b -
    1524.5;

  const t = (jd - 2451545.0) / 36525.0;

  const l0 = normDeg(280.46646 + 36000.76983 * t + 0.0003032 * t * t);
  const mAnomaly = normDeg(357.52911 + 35999.05029 * t - 0.0001537 * t * t);

  const c =
    (1.914602 - 0.004817 * t - 0.000014 * t * t) * Math.sin(deg2rad(mAnomaly)) +
    (0.019993 - 0.000101 * t) * Math.sin(deg2rad(2 * mAnomaly)) +
    0.000289 * Math.sin(deg2rad(3 * mAnomaly));

  const trueLong = l0 + c;
  const omega = 125.04 - 1934.136 * t;
  const lambda = trueLong - 0.00569 - 0.00478 * Math.sin(deg2rad(omega));

  return normDeg(lambda);
}

/** 두 각도의 차이를 -180~180으로 표현한다. */
function angleDiffDeg(a, b) {
  return ((a - b + 540) % 360) - 180;
}

/** 이분법으로 태양 황경이 [targetDeg]가 되는 UTC 시점을 찾는다. */
function findTermUtc(targetDeg, startUtc, endUtc) {
  let a = startUtc;
  let b = endUtc;
  const f = (dt) => angleDiffDeg(sunApparentLongitude(dt), targetDeg);

  let fa = f(a);

  // 60회면 밀리초 단위까지 좁혀진다.
  for (let i = 0; i < 60; i += 1) {
    const midMs = Math.floor((a.getTime() + b.getTime()) / 2);
    const mid = new Date(midMs);
    const fm = f(mid);
    if (fa <= 0 ? fm <= 0 : fm > 0) {
      a = mid;
      fa = fm;
    } else {
      b = mid;
    }
  }
  return new Date(Math.floor((a.getTime() + b.getTime()) / 2));
}

/** [year]년 입춘(태양 황경 315°)의 UTC 시점. 2월 초 근방에서만 탐색한다. */
function lichunUtc(year) {
  const start = new Date(Date.UTC(year, 0, 28));
  const end = new Date(Date.UTC(year, 1, 10));
  return findTermUtc(315, start, end);
}

/**
 * 태양 황경에서 월지(月支) index를 구한다.
 * saju 패키지 `_monthBranchIndexFromSunLon`과 동일하다.
 */
function monthBranchIndexFromSunLon(lon) {
  return ((Math.floor(normDeg(lon + 45) / 30) + 2) % 12 + 12) % 12;
}

module.exports = {
  SEOUL,
  seoulOffsetMinutes,
  seoulWallClockToUtc,
  normDeg,
  sunApparentLongitude,
  angleDiffDeg,
  findTermUtc,
  lichunUtc,
  monthBranchIndexFromSunLon,
};
