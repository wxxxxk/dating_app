'use strict';

// Firestore 보안 규칙 테스트 — 직장·학교 소속 인증 요청 (Phase 3-3).
//
// users/{uid}/affiliationVerificationRequests/{type} 규칙과, 인증 배지
// (verifications.work/school)가 클라이언트 write 불가인지, 기존 3-key
// verification 문서가 여전히 동작하는지를 함께 검증한다.

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

function storagePath(type = 'work', uid = A, upload = '1721000000000_abc') {
  return `affiliationVerification/${uid}/${type}/${upload}.jpg`;
}

/** 정상 pending 제출 payload. */
function validRequest(type = 'work', overrides = {}) {
  return {
    uid: A,
    type,
    institutionName: type === 'work' ? 'CVR Lab' : '서울과학기술대학교',
    affiliationDetail: type === 'work' ? '개발팀' : '전자IT미디어공학과',
    proofType: type === 'work' ? 'employee_id' : 'student_id',
    status: 'pending',
    storagePath: storagePath(type),
    submittedAt: serverTimestamp(),
    updatedAt: serverTimestamp(),
    reviewedAt: null,
    rejectionReason: null,
    schemaVersion: 1,
    ...overrides,
  };
}

/** seed용 기존 문서(구체 Timestamp). */
function seededRequest(type, status, overrides = {}) {
  return {
    ...validRequest(type),
    status,
    submittedAt: Timestamp.now(),
    updatedAt: Timestamp.now(),
    reviewedAt: status === 'pending' ? null : Timestamp.now(),
    rejectionReason: status === 'rejected' ? 'document_not_clear' : null,
    ...overrides,
  };
}

function aDb() {
  return testEnv.authenticatedContext(A).firestore();
}
function bDb() {
  return testEnv.authenticatedContext(B).firestore();
}

function requestRef(db, type = 'work', uid = A) {
  return doc(db, 'users', uid, 'affiliationVerificationRequests', type);
}

async function seedRequest(type, data, uid = A) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(requestRef(ctx.firestore(), type, uid), data);
  });
}

/** 기존(legacy) 3-key verification 문서를 가진 프로필. */
async function seedLegacyProfiles(uid = A, verifications = {
  email: true,
  phone: true,
  photo: false,
}) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await setDoc(doc(db, 'users', uid), {
      displayName: '테스터',
      gender: 'male',
      bio: '안녕하세요',
      verifications,
      updatedAt: Timestamp.now(),
    });
    await setDoc(doc(db, 'publicProfiles', uid), {
      displayName: '테스터',
      gender: 'male',
      bio: '안녕하세요',
      verifications,
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
test('1~2. 본인 work/school 요청을 read할 수 있다', async () => {
  await seedRequest('work', seededRequest('work', 'pending'));
  await seedRequest('school', seededRequest('school', 'pending'));
  await assertSucceeds(getDoc(requestRef(aDb(), 'work')));
  await assertSucceeds(getDoc(requestRef(aDb(), 'school')));
});

test('3. 다른 사용자의 요청은 read할 수 없다', async () => {
  await seedRequest('work', seededRequest('work', 'pending'));
  await assertFails(getDoc(requestRef(bDb(), 'work', A)));
});

// ── create ──────────────────────────────────────────────────────────────
test('4~5. 본인 work/school pending 요청을 create할 수 있다', async () => {
  await assertSucceeds(setDoc(requestRef(aDb(), 'work'), validRequest('work')));
  await assertSucceeds(
    setDoc(requestRef(aDb(), 'school'), validRequest('school')),
  );
  // 상세 소속은 비워도 된다.
  await testEnv.clearFirestore();
  await assertSucceeds(
    setDoc(
      requestRef(aDb(), 'work'),
      validRequest('work', { affiliationDetail: '' }),
    ),
  );
});

test('6. path type과 body type이 다르면 거부된다', async () => {
  await assertFails(setDoc(requestRef(aDb(), 'work'), validRequest('school')));
  await assertFails(setDoc(requestRef(aDb(), 'school'), validRequest('work')));
  // 알 수 없는 type 문서 id도 거부
  await assertFails(
    setDoc(requestRef(aDb(), 'company'), validRequest('work')),
  );
});

test('7. type과 맞지 않는 proofType은 거부된다', async () => {
  await assertFails(
    setDoc(
      requestRef(aDb(), 'work'),
      validRequest('work', { proofType: 'student_id' }),
    ),
  );
  await assertFails(
    setDoc(
      requestRef(aDb(), 'school'),
      validRequest('school', { proofType: 'employee_id' }),
    ),
  );
  await assertFails(
    setDoc(
      requestRef(aDb(), 'work'),
      validRequest('work', { proofType: 'passport' }),
    ),
  );
  // 허용 조합은 모두 통과
  await assertSucceeds(
    setDoc(
      requestRef(aDb(), 'work'),
      validRequest('work', { proofType: 'employment_certificate' }),
    ),
  );
});

test('8. 다른 uid의 요청은 create할 수 없다', async () => {
  await assertFails(
    setDoc(requestRef(bDb(), 'work', A), validRequest('work', { uid: A })),
  );
  // 경로는 본인인데 uid 필드만 위조
  await assertFails(
    setDoc(requestRef(aDb(), 'work'), validRequest('work', { uid: B })),
  );
});

test('9~10. approved/rejected 상태로는 create할 수 없다', async () => {
  await assertFails(
    setDoc(requestRef(aDb(), 'work'), validRequest('work', { status: 'approved' })),
  );
  await assertFails(
    setDoc(requestRef(aDb(), 'work'), validRequest('work', { status: 'rejected' })),
  );
});

test('11~12. reviewedAt/rejectionReason 위조는 거부된다', async () => {
  await assertFails(
    setDoc(
      requestRef(aDb(), 'work'),
      validRequest('work', { reviewedAt: serverTimestamp() }),
    ),
  );
  await assertFails(
    setDoc(
      requestRef(aDb(), 'work'),
      validRequest('work', { rejectionReason: 'other' }),
    ),
  );
  // 시각 위조도 거부
  await assertFails(
    setDoc(
      requestRef(aDb(), 'work'),
      validRequest('work', { submittedAt: Timestamp.fromDate(new Date(0)) }),
    ),
  );
});

test('13. 잘못된 storagePath는 거부된다', async () => {
  for (const path of [
    storagePath('work', B), // 남의 경로
    storagePath('school'), // 다른 type 경로
    `affiliationVerification/${A}/work/nested/deep.jpg`, // 하위 디렉터리
    `photoVerification/${A}/a.jpg`, // 사진 인증 경로
    'users/userA/profile/main.jpg',
    '',
  ]) {
    await assertFails(
      setDoc(requestRef(aDb(), 'work'), validRequest('work', { storagePath: path })),
    );
  }
});

test('14. unknown field / 필수 필드 누락 / 길이 위반은 거부된다', async () => {
  await assertFails(
    setDoc(
      requestRef(aDb(), 'work'),
      validRequest('work', { downloadUrl: 'https://example.test/a.jpg' }),
    ),
  );
  const missing = validRequest('work');
  delete missing.schemaVersion;
  await assertFails(setDoc(requestRef(aDb(), 'work'), missing));

  // 기관명 2~80자
  await assertFails(
    setDoc(requestRef(aDb(), 'work'), validRequest('work', { institutionName: 'A' })),
  );
  await assertFails(
    setDoc(
      requestRef(aDb(), 'work'),
      validRequest('work', { institutionName: 'ㄱ'.repeat(81) }),
    ),
  );
  // 상세 소속 80자 초과
  await assertFails(
    setDoc(
      requestRef(aDb(), 'work'),
      validRequest('work', { affiliationDetail: 'ㄱ'.repeat(81) }),
    ),
  );
});

// ── update ──────────────────────────────────────────────────────────────
test('15~16. pending/approved 상태에서는 클라이언트가 update할 수 없다', async () => {
  await seedRequest('work', seededRequest('work', 'pending'));
  await assertFails(updateDoc(requestRef(aDb(), 'work'), validRequest('work')));
  await assertFails(
    updateDoc(requestRef(aDb(), 'work'), { status: 'approved' }),
  );

  await seedRequest('school', seededRequest('school', 'approved'));
  await assertFails(
    updateDoc(
      requestRef(aDb(), 'school'),
      validRequest('school', { storagePath: storagePath('school', A, 'new') }),
    ),
  );
});

test('17. rejected → pending 재제출은 허용된다', async () => {
  await seedRequest('work', seededRequest('work', 'rejected'));
  await assertSucceeds(
    updateDoc(
      requestRef(aDb(), 'work'),
      validRequest('work', {
        storagePath: storagePath('work', A, '1721999999999_new'),
        institutionName: '새 회사',
        proofType: 'employment_certificate',
      }),
    ),
  );
});

test('18. 같은 storagePath 재사용은 거부된다', async () => {
  await seedRequest('work', seededRequest('work', 'rejected'));
  await assertFails(
    updateDoc(requestRef(aDb(), 'work'), validRequest('work')),
  );
  // type을 바꾸려는 재제출도 거부
  await assertFails(
    updateDoc(
      requestRef(aDb(), 'work'),
      validRequest('work', {
        type: 'school',
        storagePath: storagePath('school', A, 'new'),
      }),
    ),
  );
});

// ── delete ──────────────────────────────────────────────────────────────
test('19. 요청 문서는 삭제할 수 없다', async () => {
  await seedRequest('work', seededRequest('work', 'rejected'));
  await assertFails(deleteDoc(requestRef(aDb(), 'work')));
});

// ── verification 배지 호환/보호 ──────────────────────────────────────────
test('20. legacy 3-key verification 문서도 일반 프로필 update가 된다', async () => {
  await seedLegacyProfiles();
  await assertSucceeds(
    updateDoc(doc(aDb(), 'users', A), {
      bio: '새 소개',
      updatedAt: serverTimestamp(),
    }),
  );
  await assertSucceeds(
    updateDoc(doc(aDb(), 'publicProfiles', A), { bio: '새 소개' }),
  );
});

test('21~22. 클라이언트는 work/school 배지를 켤 수 없다', async () => {
  await seedLegacyProfiles();
  for (const patch of [
    { verifications: { email: true, phone: true, photo: false, work: true } },
    { verifications: { email: true, phone: true, photo: false, school: true } },
  ]) {
    await assertFails(updateDoc(doc(aDb(), 'users', A), patch));
    await assertFails(updateDoc(doc(aDb(), 'publicProfiles', A), patch));
  }
  // 요청 문서를 만든 뒤에도 배지는 서버 전용이다.
  await assertSucceeds(setDoc(requestRef(aDb(), 'work'), validRequest('work')));
  await assertFails(
    updateDoc(doc(aDb(), 'users', A), {
      verifications: { email: true, phone: true, photo: false, work: true },
    }),
  );
});

test('23. 이미 승인된 work/school 배지를 클라이언트가 지울 수 없다', async () => {
  await seedLegacyProfiles(A, {
    email: true,
    phone: true,
    photo: true,
    work: true,
    school: true,
  });
  const cleared = {
    verifications: {
      email: true,
      phone: true,
      photo: true,
      work: false,
      school: false,
    },
  };
  await assertFails(updateDoc(doc(aDb(), 'users', A), cleared));
  await assertFails(updateDoc(doc(aDb(), 'publicProfiles', A), cleared));
});

test('신규 계정 생성 시 초기 verification은 3-key/5-key 모두 false만 허용', async () => {
  const base = {
    displayName: '신규',
    birthDate: Timestamp.fromDate(new Date('2000-01-01')),
    gender: 'male',
    bio: '',
    photoUrls: [],
    createdAt: serverTimestamp(),
    updatedAt: serverTimestamp(),
  };
  // legacy 3-key
  await assertSucceeds(
    setDoc(doc(aDb(), 'users', A), {
      ...base,
      verifications: { email: false, phone: false, photo: false },
    }),
  );
  await testEnv.clearFirestore();
  // 신버전 5-key
  await assertSucceeds(
    setDoc(doc(aDb(), 'users', A), {
      ...base,
      verifications: {
        email: false,
        phone: false,
        photo: false,
        work: false,
        school: false,
      },
    }),
  );
  await testEnv.clearFirestore();
  // true로 시작할 수 없다
  await assertFails(
    setDoc(doc(aDb(), 'users', A), {
      ...base,
      verifications: {
        email: false,
        phone: false,
        photo: false,
        work: true,
        school: false,
      },
    }),
  );
});
