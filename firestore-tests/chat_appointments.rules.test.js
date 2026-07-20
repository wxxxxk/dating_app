'use strict';

// Firestore 보안 규칙 테스트 — 채팅 약속 (Phase 2-1).
//
// matches/{matchId}/appointments/{appointmentId} 규칙을 Firestore Emulator에서
// 검증한다. 실제 프로젝트 데이터에는 접근하지 않는다(demo-* projectId).

const { readFileSync } = require('node:fs');
const { resolve } = require('node:path');
const assert = require('node:assert/strict');
const { after, before, beforeEach, test } = require('node:test');

const {
  initializeTestEnvironment,
  assertSucceeds,
  assertFails,
} = require('@firebase/rules-unit-testing');
const {
  doc,
  setDoc,
  updateDoc,
  deleteDoc,
  getDoc,
  serverTimestamp,
  Timestamp,
  setLogLevel,
} = require('firebase/firestore');

const A = 'userA'; // proposer
const B = 'userB'; // recipient
const C = 'userC'; // non-participant
const MATCH = 'match1';

let testEnv;

function futureTs(daysAhead = 1) {
  return Timestamp.fromDate(new Date(Date.now() + daysAhead * 24 * 3600 * 1000));
}
function pastTs() {
  return Timestamp.fromDate(new Date(Date.now() - 24 * 3600 * 1000));
}

/** create용 정상 약속 payload(createdAt은 serverTimestamp == request.time). */
function validCreate(overrides = {}) {
  return {
    proposerUid: A,
    recipientUid: B,
    scheduledAt: futureTs(),
    place: '성수역 3번 출구',
    note: '카페에서 만나요',
    status: 'pending',
    createdAt: serverTimestamp(),
    respondedAt: null,
    respondedBy: null,
    ...overrides,
  };
}

/** seed용 기존 pending 약속(구체 createdAt Timestamp). */
function existingPending(overrides = {}) {
  return {
    proposerUid: A,
    recipientUid: B,
    scheduledAt: futureTs(),
    place: '성수역 3번 출구',
    note: '카페에서 만나요',
    status: 'pending',
    createdAt: Timestamp.now(),
    respondedAt: null,
    respondedBy: null,
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
function anonDb() {
  return testEnv.unauthenticatedContext().firestore();
}

function aptRef(db, id) {
  return doc(db, 'matches', MATCH, 'appointments', id);
}

async function seedMatch(overrides = {}) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), 'matches', MATCH), {
      participants: [A, B],
      uid1: A,
      uid2: B,
      matchedAt: Timestamp.now(),
      ...overrides,
    });
  });
}
async function seedAppointment(id, data) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(aptRef(ctx.firestore(), id), data);
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
  await seedMatch();
});

// ── read ────────────────────────────────────────────────────────────────
test('participant는 약속을 read할 수 있다', async () => {
  await seedAppointment('apt1', existingPending());
  await assertSucceeds(getDoc(aptRef(aDb(), 'apt1')));
  await assertSucceeds(getDoc(aptRef(bDb(), 'apt1')));
});

test('non-participant는 약속을 read할 수 없다', async () => {
  await seedAppointment('apt1', existingPending());
  await assertFails(getDoc(aptRef(cDb(), 'apt1')));
});

// ── create ──────────────────────────────────────────────────────────────
test('1. participant(proposer)의 약속 create 허용', async () => {
  await assertSucceeds(setDoc(aptRef(aDb(), 'apt1'), validCreate()));
});

test('2. non-participant의 create 거부', async () => {
  await assertFails(
    setDoc(aptRef(cDb(), 'apt1'), validCreate({ proposerUid: C })),
  );
});

test('3a. proposerUid를 본인이 아닌 값으로 위조하면 거부', async () => {
  // 인증은 A인데 proposerUid를 B로 위조.
  await assertFails(
    setDoc(aptRef(aDb(), 'apt1'), validCreate({ proposerUid: B })),
  );
});

test('3b. recipientUid가 다른 participant가 아니면(자기 자신) 거부', async () => {
  await assertFails(
    setDoc(aptRef(aDb(), 'apt1'), validCreate({ recipientUid: A })),
  );
});

test('3c. recipientUid가 match participant가 아니면 거부', async () => {
  await assertFails(
    setDoc(aptRef(aDb(), 'apt1'), validCreate({ recipientUid: C })),
  );
});

test('4. 과거 scheduledAt은 거부', async () => {
  await assertFails(
    setDoc(aptRef(aDb(), 'apt1'), validCreate({ scheduledAt: pastTs() })),
  );
});

test('4b. status가 pending이 아니면 create 거부', async () => {
  await assertFails(
    setDoc(aptRef(aDb(), 'apt1'), validCreate({ status: 'accepted' })),
  );
});

test('4c. place 빈 문자열/81자 초과 거부', async () => {
  await assertFails(
    setDoc(aptRef(aDb(), 'apt1'), validCreate({ place: '' })),
  );
  await assertFails(
    setDoc(aptRef(aDb(), 'apt2'), validCreate({ place: 'a'.repeat(81) })),
  );
});

test('4d. note 201자 초과 거부', async () => {
  await assertFails(
    setDoc(aptRef(aDb(), 'apt1'), validCreate({ note: 'a'.repeat(201) })),
  );
});

test('4e. respondedAt/respondedBy 초기값이 null이 아니면 거부', async () => {
  await assertFails(
    setDoc(aptRef(aDb(), 'apt1'), validCreate({ respondedBy: B })),
  );
});

test('4f. 허용되지 않은 추가 필드가 있으면 거부', async () => {
  await assertFails(
    setDoc(aptRef(aDb(), 'apt1'), validCreate({ evil: true })),
  );
});

test('5. unmatched match에서는 create 거부', async () => {
  await seedMatch({ unmatchedBy: [A] });
  await assertFails(setDoc(aptRef(aDb(), 'apt1'), validCreate()));
});

// ── update (respond) ──────────────────────────────────────────────────────
test('6. recipient의 accept 허용', async () => {
  await seedAppointment('apt1', existingPending());
  await assertSucceeds(
    updateDoc(aptRef(bDb(), 'apt1'), {
      status: 'accepted',
      respondedAt: serverTimestamp(),
      respondedBy: B,
    }),
  );
});

test('7. recipient의 decline 허용', async () => {
  await seedAppointment('apt1', existingPending());
  await assertSucceeds(
    updateDoc(aptRef(bDb(), 'apt1'), {
      status: 'declined',
      respondedAt: serverTimestamp(),
      respondedBy: B,
    }),
  );
});

test('8. proposer가 자기 제안에 응답하면 거부', async () => {
  await seedAppointment('apt1', existingPending());
  await assertFails(
    updateDoc(aptRef(aDb(), 'apt1'), {
      status: 'accepted',
      respondedAt: serverTimestamp(),
      respondedBy: A,
    }),
  );
});

test('8b. non-participant의 응답 거부', async () => {
  await seedAppointment('apt1', existingPending());
  await assertFails(
    updateDoc(aptRef(cDb(), 'apt1'), {
      status: 'accepted',
      respondedAt: serverTimestamp(),
      respondedBy: C,
    }),
  );
});

test('9. immutable 필드(scheduledAt/place)를 함께 바꾸면 거부', async () => {
  await seedAppointment('apt1', existingPending());
  await assertFails(
    updateDoc(aptRef(bDb(), 'apt1'), {
      status: 'accepted',
      respondedAt: serverTimestamp(),
      respondedBy: B,
      place: '다른 장소',
    }),
  );
});

test('9b. respondedBy를 본인이 아닌 값으로 위조하면 거부', async () => {
  await seedAppointment('apt1', existingPending());
  await assertFails(
    updateDoc(aptRef(bDb(), 'apt1'), {
      status: 'accepted',
      respondedAt: serverTimestamp(),
      respondedBy: A,
    }),
  );
});

test('9c. 이미 accepted된 약속은 다시 응답할 수 없다', async () => {
  await seedAppointment(
    'apt1',
    existingPending({
      status: 'accepted',
      respondedAt: Timestamp.now(),
      respondedBy: B,
    }),
  );
  await assertFails(
    updateDoc(aptRef(bDb(), 'apt1'), {
      status: 'declined',
      respondedAt: serverTimestamp(),
      respondedBy: B,
    }),
  );
});

test('9d. status를 pending/기타 값으로 바꾸는 update 거부', async () => {
  await seedAppointment('apt1', existingPending());
  await assertFails(
    updateDoc(aptRef(bDb(), 'apt1'), {
      status: 'pending',
      respondedAt: serverTimestamp(),
      respondedBy: B,
    }),
  );
});

test('9e. unmatched match에서는 응답 update 거부', async () => {
  await seedAppointment('apt1', existingPending());
  await seedMatch({ unmatchedBy: [A] });
  await assertFails(
    updateDoc(aptRef(bDb(), 'apt1'), {
      status: 'accepted',
      respondedAt: serverTimestamp(),
      respondedBy: B,
    }),
  );
});

// ── delete ────────────────────────────────────────────────────────────────
test('10. 약속 delete는 누구도 불가', async () => {
  await seedAppointment('apt1', existingPending());
  await assertFails(deleteDoc(aptRef(aDb(), 'apt1')));
  await assertFails(deleteDoc(aptRef(bDb(), 'apt1')));
});

test('10b. 비로그인은 read/create 모두 불가', async () => {
  await seedAppointment('apt1', existingPending());
  await assertFails(getDoc(aptRef(anonDb(), 'apt1')));
  await assertFails(setDoc(aptRef(anonDb(), 'apt2'), validCreate()));
});
