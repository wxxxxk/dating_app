'use strict';

// Firestore 보안 규칙 테스트 — 약속 안전 확인 (Phase 2-5).
//
// matches/{matchId}/appointments/{appointmentId}/safetyCheckins/{uid} 규칙을
// Firestore Emulator에서 검증한다. 실제 프로젝트 데이터에는 접근하지 않는다.

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
  setDoc,
  updateDoc,
  deleteDoc,
  getDoc,
  serverTimestamp,
  Timestamp,
  setLogLevel,
} = require('firebase/firestore');

const A = 'userA'; // participant
const B = 'userB'; // participant
const C = 'userC'; // non-participant
const MATCH = 'match1';
const APT_ACCEPTED = 'aptAccepted'; // 과거 시각으로 수락된 약속
const APT_FUTURE = 'aptFuture'; // 미래 시각으로 수락된 약속
const APT_PENDING = 'aptPending';
const APT_DECLINED = 'aptDeclined';

let testEnv;

function pastTs(hours = 3) {
  return Timestamp.fromDate(new Date(Date.now() - hours * 3600 * 1000));
}
function futureTs(days = 2) {
  return Timestamp.fromDate(new Date(Date.now() + days * 24 * 3600 * 1000));
}

/** 만남 전 확인만 담은 create payload. */
function preCheckDoc(uid = A, overrides = {}) {
  return {
    uid,
    preCheckCompletedAt: serverTimestamp(),
    postStatus: null,
    postCheckedAt: null,
    updatedAt: serverTimestamp(),
    ...overrides,
  };
}

/** 만남 후 상태만 담은 create payload. */
function postCheckDoc(status, uid = A, overrides = {}) {
  return {
    uid,
    preCheckCompletedAt: null,
    postStatus: status,
    postCheckedAt: serverTimestamp(),
    updatedAt: serverTimestamp(),
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

function checkinRef(db, uid, appointmentId = APT_ACCEPTED) {
  return doc(
    db,
    'matches',
    MATCH,
    'appointments',
    appointmentId,
    'safetyCheckins',
    uid,
  );
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

async function seedAppointment(id, status, scheduledAt) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), 'matches', MATCH, 'appointments', id), {
      proposerUid: B,
      recipientUid: A,
      scheduledAt,
      place: '성수역 3번 출구',
      note: '',
      status,
      createdAt: Timestamp.now(),
      respondedAt: status === 'pending' ? null : Timestamp.now(),
      respondedBy: status === 'pending' ? null : A,
    });
  });
}

async function seedCheckin(uid, data, appointmentId = APT_ACCEPTED) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(checkinRef(ctx.firestore(), uid, appointmentId), data);
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
  await seedAppointment(APT_ACCEPTED, 'accepted', pastTs());
  await seedAppointment(APT_FUTURE, 'accepted', futureTs());
  await seedAppointment(APT_PENDING, 'pending', futureTs());
  await seedAppointment(APT_DECLINED, 'declined', futureTs());
});

// ── read ────────────────────────────────────────────────────────────────
test('1. 본인 checkin은 read할 수 있다', async () => {
  await seedCheckin(A, {
    uid: A,
    preCheckCompletedAt: Timestamp.now(),
    postStatus: null,
    postCheckedAt: null,
    updatedAt: Timestamp.now(),
  });
  await assertSucceeds(getDoc(checkinRef(aDb(), A)));
});

test('2. 같은 match의 상대도 남의 checkin은 read할 수 없다', async () => {
  await seedCheckin(A, {
    uid: A,
    preCheckCompletedAt: Timestamp.now(),
    postStatus: null,
    postCheckedAt: null,
    updatedAt: Timestamp.now(),
  });
  await assertFails(getDoc(checkinRef(bDb(), A)));
});

test('3. non-participant는 read할 수 없다', async () => {
  await seedCheckin(C, {
    uid: C,
    preCheckCompletedAt: Timestamp.now(),
    postStatus: null,
    postCheckedAt: null,
    updatedAt: Timestamp.now(),
  });
  await assertFails(getDoc(checkinRef(cDb(), C)));
});

// ── create ──────────────────────────────────────────────────────────────
test('4. 본인 pre check를 create할 수 있다', async () => {
  await assertSucceeds(setDoc(checkinRef(aDb(), A), preCheckDoc()));
  // 미래 약속에도 pre check는 가능하다.
  await assertSucceeds(
    setDoc(checkinRef(aDb(), A, APT_FUTURE), preCheckDoc()),
  );
});

test('5. 타인 uid 문서는 create할 수 없다', async () => {
  await assertFails(setDoc(checkinRef(aDb(), B), preCheckDoc(B)));
  await assertFails(setDoc(checkinRef(cDb(), C), preCheckDoc(C)));
});

test('6~7. pending·declined 약속에는 create할 수 없다', async () => {
  await assertFails(
    setDoc(checkinRef(aDb(), A, APT_PENDING), preCheckDoc()),
  );
  await assertFails(
    setDoc(checkinRef(aDb(), A, APT_DECLINED), preCheckDoc()),
  );
});

test('8. unknown field는 거부된다', async () => {
  await assertFails(
    setDoc(checkinRef(aDb(), A), preCheckDoc(A, { location: 'seoul' })),
  );
  // 필수 필드 누락도 거부
  await assertFails(
    setDoc(checkinRef(aDb(), A), {
      uid: A,
      preCheckCompletedAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
    }),
  );
  // 아무 상태도 담기지 않은 빈 껍데기도 거부
  await assertFails(
    setDoc(checkinRef(aDb(), A), preCheckDoc(A, { preCheckCompletedAt: null })),
  );
});

test('9. uid 필드가 문서 id와 다르면 거부된다', async () => {
  await assertFails(setDoc(checkinRef(aDb(), A), preCheckDoc(B)));
});

test('10. 클라이언트 시각 위조는 거부된다', async () => {
  await assertFails(
    setDoc(
      checkinRef(aDb(), A),
      preCheckDoc(A, { preCheckCompletedAt: pastTs(1) }),
    ),
  );
  await assertFails(
    setDoc(checkinRef(aDb(), A), preCheckDoc(A, { updatedAt: pastTs(1) })),
  );
});

test('11~13. safe·needs_support·cancelled를 create할 수 있다', async () => {
  for (const status of ['safe', 'needs_support', 'cancelled']) {
    await testEnv.clearFirestore();
    await seedMatch();
    await seedAppointment(APT_ACCEPTED, 'accepted', pastTs());
    await assertSucceeds(
      setDoc(checkinRef(aDb(), A), postCheckDoc(status)),
    );
  }
});

test('알 수 없는 postStatus는 거부된다', async () => {
  await assertFails(setDoc(checkinRef(aDb(), A), postCheckDoc('exploded')));
});

test('14. 약속 시간 전에는 post 상태를 기록할 수 없다', async () => {
  await assertFails(
    setDoc(checkinRef(aDb(), A, APT_FUTURE), postCheckDoc('safe')),
  );
});

// ── update ──────────────────────────────────────────────────────────────
test('15. pre는 null → 서버시각으로 1회 기록할 수 있다', async () => {
  await seedCheckin(A, {
    uid: A,
    preCheckCompletedAt: null,
    postStatus: 'safe',
    postCheckedAt: pastTs(1),
    updatedAt: pastTs(1),
  });
  await assertSucceeds(
    updateDoc(checkinRef(aDb(), A), {
      preCheckCompletedAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
    }),
  );
});

test('16. 기록된 pre 시각은 변경·초기화할 수 없다', async () => {
  const recorded = pastTs(2);
  await seedCheckin(A, {
    uid: A,
    preCheckCompletedAt: recorded,
    postStatus: null,
    postCheckedAt: null,
    updatedAt: recorded,
  });
  await assertFails(
    updateDoc(checkinRef(aDb(), A), {
      preCheckCompletedAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
    }),
  );
  await assertFails(
    updateDoc(checkinRef(aDb(), A), {
      preCheckCompletedAt: null,
      updatedAt: serverTimestamp(),
    }),
  );
});

test('17. post는 null → 상태로 1회 기록할 수 있다', async () => {
  await seedCheckin(A, {
    uid: A,
    preCheckCompletedAt: pastTs(4),
    postStatus: null,
    postCheckedAt: null,
    updatedAt: pastTs(4),
  });
  await assertSucceeds(
    updateDoc(checkinRef(aDb(), A), {
      postStatus: 'needs_support',
      postCheckedAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
    }),
  );
});

test('17-b. 약속 시간 전에는 post update도 거부된다', async () => {
  await seedCheckin(
    A,
    {
      uid: A,
      preCheckCompletedAt: pastTs(4),
      postStatus: null,
      postCheckedAt: null,
      updatedAt: pastTs(4),
    },
    APT_FUTURE,
  );
  await assertFails(
    updateDoc(checkinRef(aDb(), A, APT_FUTURE), {
      postStatus: 'safe',
      postCheckedAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
    }),
  );
});

test('18. 기록된 post 상태는 변경·초기화할 수 없다', async () => {
  const recorded = pastTs(1);
  await seedCheckin(A, {
    uid: A,
    preCheckCompletedAt: null,
    postStatus: 'needs_support',
    postCheckedAt: recorded,
    updatedAt: recorded,
  });
  await assertFails(
    updateDoc(checkinRef(aDb(), A), {
      postStatus: 'safe',
      postCheckedAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
    }),
  );
  await assertFails(
    updateDoc(checkinRef(aDb(), A), {
      postStatus: null,
      postCheckedAt: null,
      updatedAt: serverTimestamp(),
    }),
  );
});

test('19. updatedAt만 바꾸는 write는 거부된다', async () => {
  await seedCheckin(A, {
    uid: A,
    preCheckCompletedAt: pastTs(4),
    postStatus: null,
    postCheckedAt: null,
    updatedAt: pastTs(4),
  });
  await assertFails(
    updateDoc(checkinRef(aDb(), A), { updatedAt: serverTimestamp() }),
  );
});

test('타인의 checkin은 update할 수 없다', async () => {
  await seedCheckin(B, {
    uid: B,
    preCheckCompletedAt: null,
    postStatus: null,
    postCheckedAt: null,
    updatedAt: pastTs(4),
  });
  await assertFails(
    updateDoc(checkinRef(aDb(), B), {
      preCheckCompletedAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
    }),
  );
});

// ── unmatched / delete ──────────────────────────────────────────────────
test('20. 매칭 해제 이후에도 본인 안전 확인은 허용된다', async () => {
  await seedMatch({ unmatchedBy: [B] });
  await assertSucceeds(setDoc(checkinRef(aDb(), A), postCheckDoc('safe')));
});

test('21. checkin 문서는 삭제할 수 없다', async () => {
  await seedCheckin(A, {
    uid: A,
    preCheckCompletedAt: pastTs(4),
    postStatus: null,
    postCheckedAt: null,
    updatedAt: pastTs(4),
  });
  await assertFails(deleteDoc(checkinRef(aDb(), A)));
});
