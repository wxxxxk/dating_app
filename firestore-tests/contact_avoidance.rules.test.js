'use strict';

// Firestore 보안 규칙 테스트 — 지인 피하기 (Phase 3-4).
//
// 전화번호 식별자/동기화 제한/소유 관계는 클라이언트가 전혀 접근할 수 없고,
// pair는 participant만 읽을 수 있으며 write는 서버 전용인지 검증한다.
// 기존 users/publicProfiles 규칙 회귀도 함께 확인한다.

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
  collection,
  query,
  where,
  getDoc,
  getDocs,
  setDoc,
  updateDoc,
  deleteDoc,
  serverTimestamp,
  Timestamp,
  setLogLevel,
} = require('firebase/firestore');

const A = 'userA';
const B = 'userB';
const C = 'userC';
const PAIR_AB = 'pair-ab-hash';
const PAIR_BC = 'pair-bc-hash';

let testEnv;

function aDb() {
  return testEnv.authenticatedContext(A).firestore();
}
function bDb() {
  return testEnv.authenticatedContext(B).firestore();
}
function cDb() {
  return testEnv.authenticatedContext(C).firestore();
}

async function seed() {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await setDoc(doc(db, 'privatePhoneIdentifiers', A), {
      uid: A,
      contactHash: 'a'.repeat(64),
      updatedAt: Timestamp.now(),
      schemaVersion: 1,
    });
    await setDoc(doc(db, 'contactAvoidanceSyncLimits', A), {
      lastSyncAt: Timestamp.now(),
      updatedAt: Timestamp.now(),
    });
    await setDoc(
      doc(db, 'users', A, 'contactAvoidanceSettings', 'current'),
      {
        enabled: true,
        contactCount: 12,
        hiddenCount: 2,
        syncedAt: Timestamp.now(),
        updatedAt: Timestamp.now(),
        schemaVersion: 1,
      },
    );
    await setDoc(doc(db, 'users', A, 'contactAvoidanceMatches', B), {
      targetUid: B,
      pairId: PAIR_AB,
      updatedAt: Timestamp.now(),
      schemaVersion: 1,
    });
    await setDoc(doc(db, 'contactAvoidancePairs', PAIR_AB), {
      participants: [A, B],
      updatedAt: Timestamp.now(),
      schemaVersion: 1,
    });
    await setDoc(doc(db, 'contactAvoidancePairs', PAIR_BC), {
      participants: [B, C],
      updatedAt: Timestamp.now(),
      schemaVersion: 1,
    });
    // 기존 프로필 회귀 확인용
    await setDoc(doc(db, 'users', A), {
      displayName: '테스터',
      bio: '안녕하세요',
      verifications: { email: true, phone: true, photo: false },
      updatedAt: Timestamp.now(),
    });
    await setDoc(doc(db, 'publicProfiles', A), {
      displayName: '테스터',
      bio: '안녕하세요',
      verifications: { email: true, phone: true, photo: false },
      schemaVersion: 1,
    });
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
  await seed();
});

// ── private identifier / sync limit ─────────────────────────────────────
test('1~2. privatePhoneIdentifiers는 본인도 read/write할 수 없다', async () => {
  await assertFails(getDoc(doc(aDb(), 'privatePhoneIdentifiers', A)));
  await assertFails(getDoc(doc(bDb(), 'privatePhoneIdentifiers', A)));
  await assertFails(
    setDoc(doc(aDb(), 'privatePhoneIdentifiers', A), {
      uid: A,
      contactHash: 'b'.repeat(64),
      updatedAt: serverTimestamp(),
      schemaVersion: 1,
    }),
  );
  await assertFails(deleteDoc(doc(aDb(), 'privatePhoneIdentifiers', A)));
  // 목록 조회로 우회할 수 없다.
  await assertFails(getDocs(collection(aDb(), 'privatePhoneIdentifiers')));
});

test('3. contactAvoidanceSyncLimits는 클라이언트가 접근할 수 없다', async () => {
  await assertFails(getDoc(doc(aDb(), 'contactAvoidanceSyncLimits', A)));
  await assertFails(
    setDoc(doc(aDb(), 'contactAvoidanceSyncLimits', A), {
      lastSyncAt: serverTimestamp(),
    }),
  );
});

// ── settings ────────────────────────────────────────────────────────────
test('4~6. settings는 본인만 read하고 write는 금지된다', async () => {
  await assertSucceeds(
    getDoc(doc(aDb(), 'users', A, 'contactAvoidanceSettings', 'current')),
  );
  await assertFails(
    getDoc(doc(bDb(), 'users', A, 'contactAvoidanceSettings', 'current')),
  );
  await assertFails(
    setDoc(doc(aDb(), 'users', A, 'contactAvoidanceSettings', 'current'), {
      enabled: false,
      contactCount: 0,
      hiddenCount: 0,
      syncedAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
      schemaVersion: 1,
    }),
  );
  await assertFails(
    updateDoc(doc(aDb(), 'users', A, 'contactAvoidanceSettings', 'current'), {
      hiddenCount: 0,
    }),
  );
  await assertFails(
    deleteDoc(doc(aDb(), 'users', A, 'contactAvoidanceSettings', 'current')),
  );
});

// ── owner relation ──────────────────────────────────────────────────────
test('7~8. contactAvoidanceMatches는 본인도 read/write할 수 없다', async () => {
  await assertFails(
    getDoc(doc(aDb(), 'users', A, 'contactAvoidanceMatches', B)),
  );
  await assertFails(
    getDocs(collection(aDb(), 'users', A, 'contactAvoidanceMatches')),
  );
  await assertFails(
    setDoc(doc(aDb(), 'users', A, 'contactAvoidanceMatches', C), {
      targetUid: C,
      pairId: 'x',
      updatedAt: serverTimestamp(),
      schemaVersion: 1,
    }),
  );
  await assertFails(
    deleteDoc(doc(aDb(), 'users', A, 'contactAvoidanceMatches', B)),
  );
});

// ── pair ────────────────────────────────────────────────────────────────
test('9~10. pair는 participant만 read할 수 있다', async () => {
  await assertSucceeds(getDoc(doc(aDb(), 'contactAvoidancePairs', PAIR_AB)));
  await assertSucceeds(getDoc(doc(bDb(), 'contactAvoidancePairs', PAIR_AB)));
  // 참여자가 아닌 사용자는 읽을 수 없다.
  await assertFails(getDoc(doc(cDb(), 'contactAvoidancePairs', PAIR_AB)));
  await assertFails(getDoc(doc(aDb(), 'contactAvoidancePairs', PAIR_BC)));
});

test('11. participants arrayContains 쿼리만 허용된다', async () => {
  await assertSucceeds(
    getDocs(
      query(
        collection(aDb(), 'contactAvoidancePairs'),
        where('participants', 'array-contains', A),
      ),
    ),
  );
  // 남의 pair를 훑는 쿼리는 거부된다.
  await assertFails(
    getDocs(
      query(
        collection(aDb(), 'contactAvoidancePairs'),
        where('participants', 'array-contains', B),
      ),
    ),
  );
  await assertFails(getDocs(collection(aDb(), 'contactAvoidancePairs')));
});

test('12~14. pair는 클라이언트가 만들거나 고치거나 지울 수 없다', async () => {
  await assertFails(
    setDoc(doc(aDb(), 'contactAvoidancePairs', 'forged-pair'), {
      participants: [A, C],
      updatedAt: serverTimestamp(),
      schemaVersion: 1,
    }),
  );
  await assertFails(
    updateDoc(doc(aDb(), 'contactAvoidancePairs', PAIR_AB), {
      participants: [A, C],
    }),
  );
  // 숨김을 스스로 풀 수도 없다.
  await assertFails(deleteDoc(doc(aDb(), 'contactAvoidancePairs', PAIR_AB)));
  await assertFails(deleteDoc(doc(bDb(), 'contactAvoidancePairs', PAIR_AB)));
});

// ── 기존 규칙 회귀 ──────────────────────────────────────────────────────
test('15. 기존 users/publicProfiles 규칙은 그대로다', async () => {
  await assertSucceeds(getDoc(doc(aDb(), 'users', A)));
  await assertFails(getDoc(doc(bDb(), 'users', A)));
  await assertSucceeds(getDoc(doc(bDb(), 'publicProfiles', A)));
  await assertSucceeds(
    updateDoc(doc(aDb(), 'users', A), {
      bio: '새 소개',
      updatedAt: serverTimestamp(),
    }),
  );
  await assertSucceeds(
    updateDoc(doc(aDb(), 'publicProfiles', A), { bio: '새 소개' }),
  );
  // 인증 배지는 여전히 서버 전용
  await assertFails(
    updateDoc(doc(aDb(), 'users', A), {
      verifications: { email: true, phone: true, photo: true },
    }),
  );
});
