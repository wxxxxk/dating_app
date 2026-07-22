'use strict';

/**
 * 절기(태양 황경) 계산 — Phase 5-2 / 5-2A.
 *
 * 서버가 사주 계산의 source of truth이므로, 연주(입춘 경계)와 월주(절기 경계)를
 * 서버에서 직접 구한다.
 *
 * Phase 5-2A 변경: 태양 황경을 Meeus 저정밀 해(Flutter `saju` 패키지와 동일)에서
 * VSOP87D 절단판(solar_longitude_vsop.js)으로 교체했다. 저정밀 해는 절입 시각이
 * 공표값과 **최대 7분** 어긋나, 절입 직전·직후에 태어난 사용자의 월주(입춘이면
 * 연주까지)가 틀렸다. 지금은 공표값과 1분 이내로 일치한다.
 *
 * 그 결과 Flutter `saju` 패키지와는 **절입 전후 약 ±7분 구간에서만** 결과가
 * 갈릴 수 있다. 서버 계산이 canonical이고, Flutter 계산은 오행 레이더 표시용
 * 보조값이라 이 차이를 허용한다(test/saju_engine_v2.test.js의 parity 테스트가
 * 경계 구간을 제외하고 대조한다).
 *
 * 시간대: Asia/Seoul만 지원한다. 다만 한국 표준시는 역사적으로 바뀌었으므로
 * (1954~1961 UTC+8:30, 1987~1988 서머타임 UTC+10:00) 고정 +9시간으로
 * 계산하지 않고, Intl의 IANA 시간대 데이터에서 그 시점의 실제 offset을 찾는다.
 */

const { sunApparentLongitude } = require('./solar_longitude_vsop');

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
