'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const {
  sajuCacheMetadata,
  sajuEvidenceCacheMetadata,
  isCurrentSajuCache,
  matchEvidenceCacheMetadata,
  isCurrentMatchEvidenceCache,
} = require('../lib/saju/evidence_cache');
const { SAJU_EVIDENCE_VERSION } = require('../lib/saju/saju_evidence_v1');

// Phase 5-3 — 캐시 버전 계약과 AI payload 계약.

const INTERPRETATION = 2;
const PROFILE_A = { inputFingerprint: 'a'.repeat(64) };
const PROFILE_B = { inputFingerprint: 'b'.repeat(64) };

function source() {
  return fs.readFileSync(path.join(__dirname, '..', 'index.js'), 'utf8');
}

function functionSlice(src, name) {
  const start = src.indexOf(`exports.${name} = onCall`);
  assert.ok(start >= 0, `${name}을 찾지 못했다`);
  const next = src.indexOf('\nexports.', start + 1);
  return src.slice(start, next === -1 ? undefined : next);
}

// ── 개인 캐시 ────────────────────────────────────────────────────────────

test('evidence metadata에 네 버전 축과 지문이 모두 들어간다', () => {
  const meta = sajuEvidenceCacheMetadata(PROFILE_A, INTERPRETATION);
  assert.equal(meta.calculationVersion, 3);
  assert.equal(meta.conventionVersion, 2);
  assert.equal(meta.evidenceVersion, SAJU_EVIDENCE_VERSION);
  assert.equal(meta.interpretationVersion, INTERPRETATION);
  assert.equal(meta.inputFingerprint, PROFILE_A.inputFingerprint);
});

test('캐시 metadata에 raw 출생정보가 저장되지 않는다', () => {
  const serialized = JSON.stringify(
    sajuEvidenceCacheMetadata(PROFILE_A, INTERPRETATION),
  );
  for (const banned of ['birthDate', 'birthTimeMinutes', 'birthTimeZone', 'year']) {
    assert.ok(!serialized.includes(banned), `개인정보 흔적: ${banned}`);
  }
});

test('evidenceVersion이 없는 기존 캐시는 miss다', () => {
  // Phase 5-2A까지 저장된 캐시에는 evidenceVersion이 없다.
  const legacy = sajuCacheMetadata(PROFILE_A, INTERPRETATION);
  assert.equal(legacy.evidenceVersion, undefined);
  assert.equal(
    isCurrentSajuCache(legacy, PROFILE_A, INTERPRETATION, {
      requireEvidenceVersion: true,
    }),
    false,
  );
  // evidence를 쓰지 않는 callable에서는 여전히 hit이다.
  assert.equal(isCurrentSajuCache(legacy, PROFILE_A, INTERPRETATION), true);
});

test('evidenceVersion 1 캐시는 hit이다', () => {
  const current = sajuEvidenceCacheMetadata(PROFILE_A, INTERPRETATION);
  assert.equal(
    isCurrentSajuCache(current, PROFILE_A, INTERPRETATION, {
      requireEvidenceVersion: true,
    }),
    true,
  );
});

test('지문이 다르면 miss다 — 생년월일·출생시간 변경', () => {
  const current = sajuEvidenceCacheMetadata(PROFILE_A, INTERPRETATION);
  assert.equal(
    isCurrentSajuCache(current, PROFILE_B, INTERPRETATION, {
      requireEvidenceVersion: true,
    }),
    false,
  );
});

test('버전 축이 하나라도 다르면 miss다', () => {
  const current = sajuEvidenceCacheMetadata(PROFILE_A, INTERPRETATION);
  const variants = [
    { ...current, calculationVersion: 2 },
    { ...current, conventionVersion: 1 },
    { ...current, evidenceVersion: 0 },
    { ...current, interpretationVersion: INTERPRETATION + 1 },
  ];
  for (const variant of variants) {
    assert.equal(
      isCurrentSajuCache(variant, PROFILE_A, INTERPRETATION, {
        requireEvidenceVersion: true,
      }),
      false,
      JSON.stringify(variant),
    );
  }
  assert.equal(isCurrentSajuCache(null, PROFILE_A, INTERPRETATION), false);
  assert.equal(isCurrentSajuCache({}, PROFILE_A, INTERPRETATION), false);
});

// ── 궁합 캐시 ────────────────────────────────────────────────────────────

test('궁합 캐시 key에 실제 UID를 쓰지 않는다', () => {
  const meta = matchEvidenceCacheMetadata({
    firstFingerprint: PROFILE_A.inputFingerprint,
    secondFingerprint: PROFILE_B.inputFingerprint,
    interpretationVersion: INTERPRETATION,
  });
  assert.deepEqual(Object.keys(meta.participantFingerprints).sort(), [
    'first',
    'second',
  ]);
  const serialized = JSON.stringify(meta);
  assert.ok(!serialized.includes('uid'));
  assert.ok(!serialized.includes('birthDate'));
});

test('궁합 캐시는 두 참가자 지문과 evidenceVersion을 모두 확인한다', () => {
  const meta = matchEvidenceCacheMetadata({
    firstFingerprint: PROFILE_A.inputFingerprint,
    secondFingerprint: PROFILE_B.inputFingerprint,
    interpretationVersion: INTERPRETATION,
  });
  assert.equal(isCurrentMatchEvidenceCache(meta, meta), true);

  // 상대 지문이 바뀌면 miss.
  const otherSecond = matchEvidenceCacheMetadata({
    firstFingerprint: PROFILE_A.inputFingerprint,
    secondFingerprint: 'c'.repeat(64),
    interpretationVersion: INTERPRETATION,
  });
  assert.equal(isCurrentMatchEvidenceCache(meta, otherSecond), false);

  // 본인 지문이 바뀌어도 miss.
  const otherFirst = matchEvidenceCacheMetadata({
    firstFingerprint: 'd'.repeat(64),
    secondFingerprint: PROFILE_B.inputFingerprint,
    interpretationVersion: INTERPRETATION,
  });
  assert.equal(isCurrentMatchEvidenceCache(meta, otherFirst), false);

  // evidenceVersion이 없는 기존 캐시는 miss.
  const legacy = { ...meta };
  delete legacy.evidenceVersion;
  assert.equal(isCurrentMatchEvidenceCache(legacy, meta), false);
  // participantFingerprints가 아예 없던 Phase 5-2A 캐시도 miss.
  const older = { ...meta };
  delete older.participantFingerprints;
  assert.equal(isCurrentMatchEvidenceCache(older, meta), false);
});

test('궁합 캐시는 참가자 자리 순서가 고정돼 있다', () => {
  // first/second를 뒤집으면 다른 캐시로 취급된다. 호출 순서가 아니라
  // 매치 문서의 canonical participants order를 쓰기 때문에 안전하다.
  const meta = matchEvidenceCacheMetadata({
    firstFingerprint: PROFILE_A.inputFingerprint,
    secondFingerprint: PROFILE_B.inputFingerprint,
    interpretationVersion: INTERPRETATION,
  });
  const swapped = matchEvidenceCacheMetadata({
    firstFingerprint: PROFILE_B.inputFingerprint,
    secondFingerprint: PROFILE_A.inputFingerprint,
    interpretationVersion: INTERPRETATION,
  });
  assert.equal(isCurrentMatchEvidenceCache(meta, swapped), false);

  // index.js는 participants 배열 순서(uidA, uidB)를 그대로 쓴다.
  const matchSrc = functionSlice(source(), 'generateMatchNarrative');
  assert.ok(matchSrc.includes('const [uidA, uidB] = participants'));
  assert.ok(matchSrc.includes('firstFingerprint: participantFingerprints[uidA]'));
  assert.ok(matchSrc.includes('secondFingerprint: participantFingerprints[uidB]'));
});

// ── AI payload 계약 ──────────────────────────────────────────────────────

test('개인 사주 prompt에 구조화된 원국 근거가 전달된다', () => {
  const slice = functionSlice(source(), 'generateFortuneNarrative');
  assert.ok(slice.includes('buildPersonalSajuEvidence(chart)'));
  assert.ok(slice.includes('원국근거: personalEvidence'));
  assert.ok(slice.includes('사주근거: evidence'));
});

test('궁합 prompt에 두 원국과 궁합 근거가 전달된다', () => {
  const slice = functionSlice(source(), 'generateMatchNarrative');
  assert.ok(slice.includes('buildCompatibilityEvidence({'));
  assert.ok(slice.includes('원국근거A: personalEvidenceA'));
  assert.ok(slice.includes('원국근거B: personalEvidenceB'));
  assert.ok(slice.includes('궁합근거: compatibilityEvidence'));
});

test('AI payload에 후보 pillar와 raw 출생정보가 들어가지 않는다', () => {
  const src = source();
  for (const name of ['generateFortuneNarrative', 'generateMatchNarrative']) {
    const slice = functionSlice(src, name);
    for (const banned of [
      'Candidates',
      'birthTimeMinutes',
      'birthDateMillis',
      'inputFingerprint:',
    ]) {
      assert.ok(!slice.includes(banned), `${name}에 ${banned}가 있다`);
    }
    // userPayload에 uid를 넣지 않는다.
    assert.ok(!/userPayload: \{[^}]*uid/s.test(slice), `${name} payload에 uid`);
  }
});

test('prompt에 근거 밖 관계 생성 금지 규칙이 있다', () => {
  const src = source();
  // 개인 사주.
  assert.ok(src.includes('여기 없는 관계(합·충·십성 등)를 새로 계산하거나 추가하지 않는다.'));
  assert.ok(src.includes('오행 개수는 존재 분포일 뿐 강약·용신 판정이 아니다.'));
  assert.ok(src.includes('합이 항상 좋고 충이 항상 나쁘다고 쓰지 않는다.'));
  // 궁합.
  assert.ok(src.includes('여기 없는 관계를 새로 만들지 않는다.'));
  assert.ok(
    src.includes('supports가 많다고 좋은 궁합, tensions가 있다고 나쁜 궁합이라고 쓰지 않는다.'),
  );
  // partial confidence 존중.
  assert.ok(src.includes('confidence가 partial이면'));
});

test('응답 JSON 스키마는 그대로 유지된다', () => {
  const src = source();
  // Phase 5-3은 근거만 추가한다 — 화면이 파싱하는 스키마는 건드리지 않는다.
  assert.ok(
    src.includes(
      '{"characterType": string, "summary": string, "reasons": [{"icon": string, "text": string}], "relationshipStory": null}',
    ),
  );
  assert.ok(
    src.includes(
      '{"characterType": string, "summary": string, "reasons": [{"icon": string, "text": string}], "relationshipStory": string}',
    ),
  );
});

test('오늘의 운세는 이번 Phase에서 구조화 근거를 쓰지 않는다', () => {
  // 짧은 하루 문구에 십성·지장간을 넣는 것은 범위 과잉이라 연결하지 않았다.
  // 따라서 evidenceVersion 조건도 걸지 않는다(기존 캐시가 불필요하게 깨지지 않음).
  const slice = functionSlice(source(), 'generateDailyFortune');
  assert.ok(!slice.includes('buildPersonalSajuEvidence'));
  assert.ok(!slice.includes('requireEvidenceVersion'));
});
