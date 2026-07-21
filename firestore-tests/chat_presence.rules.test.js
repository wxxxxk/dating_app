'use strict';

// Firestore 보안 규칙 테스트 — 채팅방 presence (Phase 2-2).
//
// matches/{matchId}/presence/{presenceUid} 규칙을 Firestore Emulator에서
// 검증한다. 실제 프로젝트 데이터에는 접근하지 않는다(demo-* projectId).

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

let testEnv;

/** create/update용 정상 presence payload(시각은 serverTimestamp == request.time). */
function validPresence(uid = A, overrides = {}) {
  return {
    uid,
    isOnline: true,
    isTyping: false,
    lastActiveAt: serverTimestamp(),
    updatedAt: serverTimestamp(),
    ...overrides,
  };
}

/** seed용 기존 presence 문서(구체 Timestamp). */
function existingPresence(uid = A, overrides = {}) {
  return {
    uid,
    isOnline: true,
    isTyping: false,
    lastActiveAt: Timestamp.now(),
    updatedAt: Timestamp.now(),
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

function presenceRef(db, uid) {
  return doc(db, 'matches', MATCH, 'presence', uid);
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

async function seedPresence(uid, data) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(presenceRef(ctx.firestore(), uid), data);
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
test('1. participant는 상대 presence를 read할 수 있다', async () => {
  await seedPresence(A, existingPresence(A));
  await assertSucceeds(getDoc(presenceRef(bDb(), A)));
  await assertSucceeds(getDoc(presenceRef(aDb(), A)));
});

test('2. non-participant는 presence를 read할 수 없다', async () => {
  await seedPresence(A, existingPresence(A));
  await assertFails(getDoc(presenceRef(cDb(), A)));
});

// ── create ──────────────────────────────────────────────────────────────
test('3. 본인 presence 문서를 create할 수 있다', async () => {
  await assertSucceeds(setDoc(presenceRef(aDb(), A), validPresence(A)));
});

test('4. 타인 uid의 presence 문서는 create할 수 없다', async () => {
  // 경로만 상대 uid인 경우
  await assertFails(setDoc(presenceRef(aDb(), B), validPresence(B)));
  // 경로는 본인인데 uid 필드만 위조한 경우
  await assertFails(
    setDoc(presenceRef(aDb(), A), validPresence(A, { uid: B })),
  );
});

test('5. allowlist 밖의 필드가 있으면 create할 수 없다', async () => {
  await assertFails(
    setDoc(presenceRef(aDb(), A), validPresence(A, { deviceId: 'pixel-8' })),
  );
  // 필수 필드 누락도 거부한다.
  await assertFails(
    setDoc(presenceRef(aDb(), A), {
      uid: A,
      isOnline: true,
      isTyping: false,
      updatedAt: serverTimestamp(),
    }),
  );
});

test('6. offline인데 isTyping true인 조합은 거부된다', async () => {
  await assertFails(
    setDoc(
      presenceRef(aDb(), A),
      validPresence(A, { isOnline: false, isTyping: true }),
    ),
  );
  // offline + typing false는 정상(채팅방 이탈 시 write).
  await assertSucceeds(
    setDoc(
      presenceRef(aDb(), A),
      validPresence(A, { isOnline: false, isTyping: false }),
    ),
  );
});

test('6-b. 시각을 클라이언트 값으로 위조하면 거부된다', async () => {
  await assertFails(
    setDoc(
      presenceRef(aDb(), A),
      validPresence(A, {
        lastActiveAt: Timestamp.fromDate(new Date(Date.now() + 600000)),
      }),
    ),
  );
});

test('7. 매칭이 해제된 방에는 presence를 create할 수 없다', async () => {
  await seedMatch({ unmatchedBy: [B] });
  await assertFails(setDoc(presenceRef(aDb(), A), validPresence(A)));
});

// ── update ──────────────────────────────────────────────────────────────
test('8. 본인 presence를 update할 수 있다', async () => {
  await seedPresence(A, existingPresence(A));
  await assertSucceeds(
    updateDoc(presenceRef(aDb(), A), {
      isOnline: true,
      isTyping: true,
      lastActiveAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
    }),
  );
});

test('9. 타인의 presence는 update할 수 없다', async () => {
  await seedPresence(B, existingPresence(B));
  await assertFails(
    updateDoc(presenceRef(aDb(), B), {
      isOnline: false,
      isTyping: false,
      lastActiveAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
    }),
  );
});

test('10. uid 필드는 변경할 수 없다', async () => {
  await seedPresence(A, existingPresence(A));
  await assertFails(
    updateDoc(presenceRef(aDb(), A), {
      uid: B,
      isOnline: true,
      isTyping: false,
      lastActiveAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
    }),
  );
});

test('11. 매칭이 해제되면 presence를 update할 수 없다', async () => {
  await seedPresence(A, existingPresence(A));
  await seedMatch({ unmatchedBy: [A] });
  await assertFails(
    updateDoc(presenceRef(aDb(), A), {
      isOnline: false,
      isTyping: false,
      lastActiveAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
    }),
  );
});

// ── delete ──────────────────────────────────────────────────────────────
test('12. presence 문서는 삭제할 수 없다', async () => {
  await seedPresence(A, existingPresence(A));
  await assertFails(deleteDoc(presenceRef(aDb(), A)));
});
