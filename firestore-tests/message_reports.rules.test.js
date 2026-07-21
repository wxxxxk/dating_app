'use strict';

// Firestore 보안 규칙 테스트 — 신고 (Phase 2-4).
//
// reports/{reportId}의 두 경로(사용자 신고 / 메시지 신고)를 Firestore
// Emulator에서 검증한다. 실제 프로젝트 데이터에는 접근하지 않는다(demo-*).

const { readFileSync } = require('node:fs');
const { resolve } = require('node:path');
const { after, before, beforeEach, test } = require('node:test');

const {
  initializeTestEnvironment,
  assertSucceeds,
  assertFails,
} = require('@firebase/rules-unit-testing');
const {
  doc,
  addDoc,
  collection,
  setDoc,
  updateDoc,
  deleteDoc,
  getDoc,
  serverTimestamp,
  Timestamp,
  setLogLevel,
} = require('firebase/firestore');

const A = 'userA'; // 신고자(participant)
const B = 'userB'; // 상대(participant, 메시지 작성자)
const C = 'userC'; // non-participant
const MATCH = 'match1';
const OTHER_MATCH = 'match2';

const MSG_FROM_B = 'msgFromB'; // B가 보낸 일반 텍스트
const MSG_FROM_A = 'msgFromA'; // A(신고자)가 보낸 일반 텍스트
const MSG_APPOINTMENT = 'msgAppointment';
const MSG_APPOINTMENT_RES = 'msgAppointmentRes';
const MSG_LEGACY = 'msgLegacy'; // type 필드가 없는 과거 메시지

let testEnv;

/** 정상 메시지 신고 payload. */
function validMessageReport(overrides = {}) {
  return {
    reportType: 'message',
    reporterUid: A,
    reportedUid: B,
    matchId: MATCH,
    messageId: MSG_FROM_B,
    reason: 'abusive_language',
    createdAt: serverTimestamp(),
    ...overrides,
  };
}

/** 정상 사용자 신고 payload(기존 경로). */
function validUserReport(overrides = {}) {
  return {
    reporterUid: A,
    reportedUid: B,
    reason: 'inappropriate_photo',
    createdAt: serverTimestamp(),
    ...overrides,
  };
}

function aDb() {
  return testEnv.authenticatedContext(A).firestore();
}
function bDb() {
  return testEnv.authenticatedContext(B).firestore();
}
function cDb() {
  return testEnv.authenticatedContext(C).firestore();
}

function reportsCol(db) {
  return collection(db, 'reports');
}

async function seedMatch(matchId, participants, overrides = {}) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), 'matches', matchId), {
      participants,
      uid1: participants[0],
      uid2: participants[1],
      matchedAt: Timestamp.now(),
      ...overrides,
    });
  });
}

async function seedMessage(matchId, messageId, data) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(
      doc(ctx.firestore(), 'matches', matchId, 'messages', messageId),
      data,
    );
  });
}

before(async () => {
  setLogLevel('error');
  const host = process.env.FIRESTORE_EMULATOR_HOST || '127.0.0.1:8080';
  const [h, p] = host.split(':');
  testEnv = await initializeTestEnvironment({
    projectId: 'demo-dating-app',
    firestore: {
      rules: readFileSync(resolve(__dirname, '../firestore.rules'), 'utf8'),
      host: h,
      port: Number(p),
    },
  });
});

after(async () => {
  if (testEnv) await testEnv.cleanup();
});

beforeEach(async () => {
  await testEnv.clearFirestore();
  await seedMatch(MATCH, [A, B]);
  await seedMatch(OTHER_MATCH, [A, C]);
  await seedMessage(MATCH, MSG_FROM_B, {
    senderId: B,
    text: '욕설 원문',
    createdAt: Timestamp.now(),
  });
  await seedMessage(MATCH, MSG_FROM_A, {
    senderId: A,
    text: '내 메시지',
    createdAt: Timestamp.now(),
  });
  await seedMessage(MATCH, MSG_APPOINTMENT, {
    senderId: B,
    text: '약속을 제안했어요.',
    type: 'appointment',
    appointmentId: 'apt1',
    createdAt: Timestamp.now(),
  });
  await seedMessage(MATCH, MSG_APPOINTMENT_RES, {
    senderId: B,
    text: '약속을 수락했어요.',
    type: 'appointment_response',
    appointmentId: 'apt1',
    appointmentStatus: 'accepted',
    createdAt: Timestamp.now(),
  });
  await seedMessage(MATCH, MSG_LEGACY, {
    senderId: B,
    text: 'type 필드 없는 과거 메시지',
    createdAt: Timestamp.now(),
  });
});

// ── 기존 사용자 신고 ────────────────────────────────────────────────────
test('1. 기존 사용자 신고는 그대로 허용된다', async () => {
  await assertSucceeds(addDoc(reportsCol(aDb()), validUserReport()));
  // detail(선택 필드) 포함도 허용
  await assertSucceeds(
    addDoc(reportsCol(aDb()), validUserReport({ detail: '사진이 부적절해요' })),
  );
});

test('2. 자기 자신 신고는 거부된다', async () => {
  await assertFails(
    addDoc(reportsCol(aDb()), validUserReport({ reportedUid: A })),
  );
  // 신고자 위조도 거부
  await assertFails(
    addDoc(reportsCol(aDb()), validUserReport({ reporterUid: B })),
  );
});

test('3. 사용자 신고의 unknown field는 거부된다', async () => {
  await assertFails(
    addDoc(reportsCol(aDb()), validUserReport({ matchId: MATCH })),
  );
  await assertFails(
    addDoc(reportsCol(aDb()), validUserReport({ evidence: 'x' })),
  );
});

// ── 메시지 신고 ─────────────────────────────────────────────────────────
test('4. participant는 상대의 텍스트 메시지를 신고할 수 있다', async () => {
  await assertSucceeds(addDoc(reportsCol(aDb()), validMessageReport()));
  // detail 포함
  await assertSucceeds(
    addDoc(reportsCol(aDb()), validMessageReport({ detail: '반복적이에요' })),
  );
  // type 필드가 없는 과거 메시지도 text로 간주해 허용
  await assertSucceeds(
    addDoc(reportsCol(aDb()), validMessageReport({ messageId: MSG_LEGACY })),
  );
});

test('5. 자기 메시지는 신고할 수 없다', async () => {
  // A가 보낸 메시지를 B 명의로 신고 시도 → 실제 senderId 불일치로 거부
  await assertFails(
    addDoc(reportsCol(aDb()), validMessageReport({ messageId: MSG_FROM_A })),
  );
  // reportedUid를 자기 자신으로 두는 것도 거부
  await assertFails(
    addDoc(
      reportsCol(aDb()),
      validMessageReport({ messageId: MSG_FROM_A, reportedUid: A }),
    ),
  );
});

test('6. non-participant는 신고할 수 없다', async () => {
  await assertFails(
    addDoc(
      reportsCol(cDb()),
      validMessageReport({ reporterUid: C, reportedUid: B }),
    ),
  );
});

test('7. reportedUid 위조는 거부된다(실제 senderId와 불일치)', async () => {
  // B가 보낸 메시지를 C가 보낸 것처럼 신고
  await assertFails(
    addDoc(reportsCol(aDb()), validMessageReport({ reportedUid: C })),
  );
  // 신고자를 위조
  await assertFails(
    addDoc(reportsCol(bDb()), validMessageReport({ reporterUid: A })),
  );
});

test('8. 다른 match의 messageId 조합은 거부된다', async () => {
  await assertFails(
    addDoc(reportsCol(aDb()), validMessageReport({ matchId: OTHER_MATCH })),
  );
});

test('9. 존재하지 않는 message/match는 거부된다', async () => {
  await assertFails(
    addDoc(reportsCol(aDb()), validMessageReport({ messageId: 'nope' })),
  );
  await assertFails(
    addDoc(
      reportsCol(aDb()),
      validMessageReport({ matchId: 'noMatch', messageId: 'nope' }),
    ),
  );
});

test('10. 약속 카드 메시지는 신고할 수 없다', async () => {
  await assertFails(
    addDoc(
      reportsCol(aDb()),
      validMessageReport({ messageId: MSG_APPOINTMENT }),
    ),
  );
});

test('11. 약속 응답 메시지는 신고할 수 없다', async () => {
  await assertFails(
    addDoc(
      reportsCol(aDb()),
      validMessageReport({ messageId: MSG_APPOINTMENT_RES }),
    ),
  );
});

test('12. 허용되지 않은 reason은 거부된다', async () => {
  await assertFails(
    addDoc(reportsCol(aDb()), validMessageReport({ reason: 'nope' })),
  );
  // 사용자 신고 전용 사유도 메시지 신고에서는 거부
  await assertFails(
    addDoc(
      reportsCol(aDb()),
      validMessageReport({ reason: 'inappropriate_photo' }),
    ),
  );
  // 메시지 전용 사유는 모두 허용
  for (const reason of [
    'abusive_language',
    'sexual_harassment',
    'hate_threat',
    'spam_scam',
    'personal_info',
    'other',
  ]) {
    await assertSucceeds(
      addDoc(reportsCol(aDb()), validMessageReport({ reason })),
    );
  }
});

test('13. detail 500자 초과는 거부된다', async () => {
  await assertSucceeds(
    addDoc(reportsCol(aDb()), validMessageReport({ detail: 'ㄱ'.repeat(500) })),
  );
  await assertFails(
    addDoc(reportsCol(aDb()), validMessageReport({ detail: 'ㄱ'.repeat(501) })),
  );
  // 빈 문자열 detail도 거부(생략하거나 1자 이상)
  await assertFails(
    addDoc(reportsCol(aDb()), validMessageReport({ detail: '' })),
  );
});

test('14. unknown field(메시지 원문 포함)는 거부된다', async () => {
  await assertFails(
    addDoc(reportsCol(aDb()), validMessageReport({ text: '욕설 원문' })),
  );
  await assertFails(
    addDoc(reportsCol(aDb()), validMessageReport({ senderId: B })),
  );
  // 필수 필드 누락도 거부
  const missing = validMessageReport();
  delete missing.messageId;
  await assertFails(addDoc(reportsCol(aDb()), missing));
});

test('15. createdAt 위조는 거부된다', async () => {
  await assertFails(
    addDoc(
      reportsCol(aDb()),
      validMessageReport({
        createdAt: Timestamp.fromDate(new Date(Date.now() - 86400000)),
      }),
    ),
  );
});

test('16. 매칭 해제 이후에도 메시지를 신고할 수 있다', async () => {
  await seedMatch(MATCH, [A, B], { unmatchedBy: [B] });
  await assertSucceeds(addDoc(reportsCol(aDb()), validMessageReport()));
});

// ── read / update / delete ──────────────────────────────────────────────
test('17~19. reports는 read/update/delete가 모두 금지된다', async () => {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), 'reports', 'r1'), {
      reportType: 'message',
      reporterUid: A,
      reportedUid: B,
      matchId: MATCH,
      messageId: MSG_FROM_B,
      reason: 'abusive_language',
      createdAt: Timestamp.now(),
    });
  });

  await assertFails(getDoc(doc(aDb(), 'reports', 'r1')));
  await assertFails(updateDoc(doc(aDb(), 'reports', 'r1'), { reason: 'other' }));
  await assertFails(deleteDoc(doc(aDb(), 'reports', 'r1')));
});
