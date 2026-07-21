'use strict';

// Firestore 보안 규칙 테스트 — 사진 인증 요청 (Phase 3-2).
//
// photoVerificationRequests/{uid} 규칙과, 인증 배지(verifications.photo)가
// 여전히 클라이언트 write 불가인지를 함께 검증한다.

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

const A = 'userA';
const B = 'userB';

let testEnv;

function storagePath(uid = A, upload = '1721000000000_abc123') {
  return `photoVerification/${uid}/${upload}.jpg`;
}

/** 정상 pending 제출 payload. */
function validRequest(uid = A, overrides = {}) {
  return {
    uid,
    status: 'pending',
    storagePath: storagePath(uid),
    submittedAt: serverTimestamp(),
    updatedAt: serverTimestamp(),
    reviewedAt: null,
    rejectionReason: null,
    schemaVersion: 1,
    ...overrides,
  };
}

function aDb() {
  return testEnv.authenticatedContext(A).firestore();
}
function bDb() {
  return testEnv.authenticatedContext(B).firestore();
}

function requestRef(db, uid = A) {
  return doc(db, 'photoVerificationRequests', uid);
}

async function seedRequest(uid, data) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(requestRef(ctx.firestore(), uid), data);
  });
}

async function seedProfiles(uid) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await setDoc(doc(db, 'users', uid), {
      displayName: '테스터',
      verifications: { email: true, phone: true, photo: false },
      updatedAt: Timestamp.now(),
    });
    await setDoc(doc(db, 'publicProfiles', uid), {
      displayName: '테스터',
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
});

// ── read ────────────────────────────────────────────────────────────────
test('1. 본인 요청은 read할 수 있다', async () => {
  await seedRequest(A, {
    uid: A,
    status: 'pending',
    storagePath: storagePath(),
    submittedAt: Timestamp.now(),
    updatedAt: Timestamp.now(),
    reviewedAt: null,
    rejectionReason: null,
    schemaVersion: 1,
  });
  await assertSucceeds(getDoc(requestRef(aDb())));
});

test('2. 다른 사용자의 요청은 read할 수 없다', async () => {
  await seedRequest(A, {
    uid: A,
    status: 'pending',
    storagePath: storagePath(),
    submittedAt: Timestamp.now(),
    updatedAt: Timestamp.now(),
    reviewedAt: null,
    rejectionReason: null,
    schemaVersion: 1,
  });
  await assertFails(getDoc(requestRef(bDb(), A)));
});

// ── create ──────────────────────────────────────────────────────────────
test('3. 본인 pending 요청을 create할 수 있다', async () => {
  await assertSucceeds(setDoc(requestRef(aDb()), validRequest()));
});

test('4. 다른 uid의 요청은 create할 수 없다', async () => {
  await assertFails(setDoc(requestRef(aDb(), B), validRequest(B)));
  // 경로는 본인인데 uid 필드만 위조한 경우
  await assertFails(setDoc(requestRef(aDb()), validRequest(A, { uid: B })));
});

test('5~6. approved/rejected 상태로는 create할 수 없다', async () => {
  await assertFails(
    setDoc(requestRef(aDb()), validRequest(A, { status: 'approved' })),
  );
  await assertFails(
    setDoc(requestRef(aDb()), validRequest(A, { status: 'rejected' })),
  );
});

test('7. reviewedAt 위조는 거부된다', async () => {
  await assertFails(
    setDoc(requestRef(aDb()), validRequest(A, { reviewedAt: serverTimestamp() })),
  );
  // 클라이언트 시각으로 submittedAt을 위조하는 것도 거부
  await assertFails(
    setDoc(
      requestRef(aDb()),
      validRequest(A, { submittedAt: Timestamp.fromDate(new Date(0)) }),
    ),
  );
});

test('8. rejectionReason 위조는 거부된다', async () => {
  await assertFails(
    setDoc(
      requestRef(aDb()),
      validRequest(A, { rejectionReason: 'photo_mismatch' }),
    ),
  );
});

test('9. unknown field / 필수 필드 누락은 거부된다', async () => {
  await assertFails(
    setDoc(
      requestRef(aDb()),
      validRequest(A, { downloadUrl: 'https://example.test/a.jpg' }),
    ),
  );
  const missing = validRequest();
  delete missing.schemaVersion;
  await assertFails(setDoc(requestRef(aDb()), missing));
});

test('13. 잘못된 storagePath는 거부된다', async () => {
  for (const path of [
    storagePath(B), // 남의 경로
    'users/userA/profile/main.jpg', // 공개 프로필 경로
    `photoVerification/${A}/nested/deep.jpg`, // 하위 디렉터리
    'photoVerificationX/userA/a.jpg',
    '',
  ]) {
    await assertFails(
      setDoc(requestRef(aDb()), validRequest(A, { storagePath: path })),
    );
  }
});

// ── update ──────────────────────────────────────────────────────────────
test('10. pending 상태에서는 클라이언트가 update할 수 없다', async () => {
  await seedRequest(A, {
    uid: A,
    status: 'pending',
    storagePath: storagePath(),
    submittedAt: Timestamp.now(),
    updatedAt: Timestamp.now(),
    reviewedAt: null,
    rejectionReason: null,
    schemaVersion: 1,
  });
  await assertFails(updateDoc(requestRef(aDb()), validRequest()));
  await assertFails(updateDoc(requestRef(aDb()), { status: 'approved' }));
});

test('11. approved 상태에서는 클라이언트가 update할 수 없다', async () => {
  await seedRequest(A, {
    uid: A,
    status: 'approved',
    storagePath: storagePath(),
    submittedAt: Timestamp.now(),
    updatedAt: Timestamp.now(),
    reviewedAt: Timestamp.now(),
    rejectionReason: null,
    schemaVersion: 1,
  });
  await assertFails(
    updateDoc(requestRef(aDb()), validRequest(A, { storagePath: storagePath(A, 'new') })),
  );
});

test('12. rejected → pending 재제출은 허용된다', async () => {
  await seedRequest(A, {
    uid: A,
    status: 'rejected',
    storagePath: storagePath(),
    submittedAt: Timestamp.now(),
    updatedAt: Timestamp.now(),
    reviewedAt: Timestamp.now(),
    rejectionReason: 'face_covered',
    schemaVersion: 1,
  });

  await assertSucceeds(
    updateDoc(
      requestRef(aDb()),
      validRequest(A, { storagePath: storagePath(A, '1721999999999_zzz') }),
    ),
  );
});

test('12-b. 재제출에서 approved로 바꾸거나 검토 필드를 남기면 거부된다', async () => {
  await seedRequest(A, {
    uid: A,
    status: 'rejected',
    storagePath: storagePath(),
    submittedAt: Timestamp.now(),
    updatedAt: Timestamp.now(),
    reviewedAt: Timestamp.now(),
    rejectionReason: 'face_covered',
    schemaVersion: 1,
  });

  await assertFails(
    updateDoc(requestRef(aDb()), validRequest(A, { status: 'approved' })),
  );
  await assertFails(
    updateDoc(
      requestRef(aDb()),
      validRequest(A, { rejectionReason: 'face_covered' }),
    ),
  );
  // status만 슬쩍 바꾸는 부분 업데이트도 거부(전체 필드 형태를 요구한다)
  await assertFails(updateDoc(requestRef(aDb()), { status: 'pending' }));
});

// ── delete ──────────────────────────────────────────────────────────────
test('14. 요청 문서는 삭제할 수 없다', async () => {
  await seedRequest(A, {
    uid: A,
    status: 'rejected',
    storagePath: storagePath(),
    submittedAt: Timestamp.now(),
    updatedAt: Timestamp.now(),
    reviewedAt: Timestamp.now(),
    rejectionReason: 'other',
    schemaVersion: 1,
  });
  await assertFails(deleteDoc(requestRef(aDb())));
});

// ── 배지 회귀 ───────────────────────────────────────────────────────────
test('15. 클라이언트는 여전히 photo 배지를 직접 켤 수 없다', async () => {
  await seedProfiles(A);

  // 비공개 프로필
  await assertFails(
    updateDoc(doc(aDb(), 'users', A), {
      verifications: { email: true, phone: true, photo: true },
    }),
  );
  // 공개 프로필
  await assertFails(
    updateDoc(doc(aDb(), 'publicProfiles', A), {
      verifications: { email: true, phone: true, photo: true },
    }),
  );
  // 요청 문서를 만든 뒤에도 배지는 여전히 서버 전용이다.
  await assertSucceeds(setDoc(requestRef(aDb()), validRequest()));
  await assertFails(
    updateDoc(doc(aDb(), 'users', A), {
      verifications: { email: true, phone: true, photo: true },
    }),
  );
});
