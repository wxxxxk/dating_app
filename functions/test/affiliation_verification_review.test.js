'use strict';

// Phase 3-3 — reviewAffiliationVerification core 테스트.
//
// 권한 검사, type별 상태 전이, 배지 동기화(다른 배지 보존), 검토 후 이미지
// 삭제, 로그·응답의 개인정보 미노출을 fake 주입으로 확인한다.

const assert = require('node:assert/strict');
const { test } = require('node:test');

const {
  reviewAffiliationVerificationCore,
  validateReviewInput,
  normalizeVerifications,
} = require('../lib/affiliation_verification_review');

const UID = 'target-uid';
const ADMIN_UID = 'admin-uid';
const INSTITUTION = 'CVR Lab';
const STORAGE_PATH = `affiliationVerification/${UID}/work/1721000000000_abc123.jpg`;
const SERVER_TIMESTAMP = '__server_timestamp__';

class FakeHttpsError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

function adminRequest(data) {
  return { auth: { uid: ADMIN_UID, token: { admin: true } }, data };
}

function requestDoc(type = 'work', overrides = {}) {
  return {
    uid: UID,
    type,
    institutionName: INSTITUTION,
    affiliationDetail: '개발팀',
    proofType: type === 'work' ? 'employee_id' : 'student_id',
    status: 'pending',
    storagePath: `affiliationVerification/${UID}/${type}/upload1.jpg`,
    schemaVersion: 1,
    ...overrides,
  };
}

/** transaction만 지원하는 최소 fake Firestore(users 하위 서브컬렉션 포함). */
function createFakeDb({
  workRequest = requestDoc('work', { storagePath: STORAGE_PATH }),
  schoolRequest = requestDoc('school'),
  workExists = true,
  schoolExists = true,
  userData = {
    verifications: { email: true, phone: true, photo: true },
  },
  publicData = {
    verifications: { email: true, phone: true, photo: true },
  },
  userExists = true,
  publicExists = true,
} = {}) {
  const docs = {
    [`users/${UID}`]: { exists: userExists, data: userData },
    [`publicProfiles/${UID}`]: { exists: publicExists, data: publicData },
    [`users/${UID}/affiliationVerificationRequests/work`]: {
      exists: workExists,
      data: workRequest,
    },
    [`users/${UID}/affiliationVerificationRequests/school`]: {
      exists: schoolExists,
      data: schoolRequest,
    },
  };
  const calls = { updates: [], committedUpdates: [] };

  function makeDocRef(path) {
    return {
      path,
      collection: (name) => ({
        doc: (id) => makeDocRef(`${path}/${name}/${id}`),
      }),
    };
  }

  return {
    calls,
    collection(name) {
      return { doc: (id) => makeDocRef(`${name}/${id}`) };
    },
    async runTransaction(handler) {
      calls.updates.length = 0;
      const tx = {
        async get(ref) {
          const entry = docs[ref.path] || { exists: false, data: undefined };
          return { exists: entry.exists, data: () => entry.data };
        },
        update(ref, payload) {
          calls.updates.push({ path: ref.path, payload });
        },
      };
      const result = await handler(tx);
      calls.committedUpdates.push(...calls.updates);
      return result;
    },
  };
}

function createFakeBucket({ deleteError = null } = {}) {
  const calls = { deleted: [] };
  return {
    calls,
    file(path) {
      return {
        async delete() {
          calls.deleted.push(path);
          if (deleteError) throw deleteError;
        },
      };
    },
  };
}

function createLogger() {
  const lines = [];
  return {
    lines,
    log: (m) => lines.push(String(m)),
    warn: (m) => lines.push(String(m)),
    error: (m) => lines.push(String(m)),
  };
}

async function review({
  request,
  db = createFakeDb(),
  storageBucket = createFakeBucket(),
  logger = createLogger(),
} = {}) {
  const result = await reviewAffiliationVerificationCore({
    request,
    db,
    storageBucket,
    HttpsError: FakeHttpsError,
    serverTimestamp: () => SERVER_TIMESTAMP,
    logger,
  });
  return { result, db, storageBucket, logger };
}

function updateFor(db, path) {
  return db.calls.committedUpdates.find((u) => u.path === path);
}

// ── 권한 ────────────────────────────────────────────────────────────────
test('1. 미인증 호출은 거부된다', async () => {
  await assert.rejects(
    () =>
      review({
        request: { data: { uid: UID, type: 'work', decision: 'approved' } },
      }),
    (error) => error.code === 'unauthenticated',
  );
});

test('2~3. admin이 아니면(developer claim 포함) 거부된다', async () => {
  for (const token of [{}, { developer: true }, { admin: false }]) {
    await assert.rejects(
      () =>
        review({
          request: {
            auth: { uid: 'someone', token },
            data: { uid: UID, type: 'work', decision: 'approved' },
          },
        }),
      (error) => error.code === 'permission-denied',
    );
  }
});

// ── 입력 검증 ────────────────────────────────────────────────────────────
test('4. 허용되지 않는 type은 거부된다', async () => {
  for (const type of [undefined, null, 'company', 'WORK', 1]) {
    await assert.rejects(
      () =>
        review({
          request: adminRequest({ uid: UID, type, decision: 'approved' }),
        }),
      (error) => error.code === 'invalid-argument',
    );
  }
});

test('5. 허용되지 않는 decision은 거부된다', async () => {
  for (const decision of [undefined, null, 'pending', 'APPROVED']) {
    await assert.rejects(
      () =>
        review({
          request: adminRequest({ uid: UID, type: 'work', decision }),
        }),
      (error) => error.code === 'invalid-argument',
    );
  }
  await assert.rejects(
    () =>
      review({
        request: adminRequest({ uid: '', type: 'work', decision: 'approved' }),
      }),
    (error) => error.code === 'invalid-argument',
  );
});

test('6. 반려 사유 검증', async () => {
  for (const reason of [undefined, null, 'nope', 'face_covered']) {
    await assert.rejects(
      () =>
        review({
          request: adminRequest({
            uid: UID,
            type: 'work',
            decision: 'rejected',
            rejectionReason: reason,
          }),
        }),
      (error) => error.code === 'invalid-argument',
    );
  }
  // 승인에는 사유를 넣을 수 없다
  await assert.rejects(
    () =>
      review({
        request: adminRequest({
          uid: UID,
          type: 'work',
          decision: 'approved',
          rejectionReason: 'other',
        }),
      }),
    (error) => error.code === 'invalid-argument',
  );
  // 허용 사유는 모두 통과
  for (const reason of [
    'document_not_clear',
    'institution_not_visible',
    'affiliation_not_confirmed',
    'sensitive_info_visible',
    'expired_document',
    'other',
  ]) {
    const parsed = validateReviewInput(
      { uid: UID, type: 'school', decision: 'rejected', rejectionReason: reason },
      FakeHttpsError,
    );
    assert.equal(parsed.rejectionReason, reason);
  }
});

// ── 승인 ────────────────────────────────────────────────────────────────
test('7, 9~12. work 승인은 work 배지만 켜고 나머지를 보존한다', async () => {
  const db = createFakeDb({
    userData: {
      verifications: {
        email: true,
        phone: true,
        photo: true,
        work: false,
        school: true,
      },
    },
    publicData: {
      verifications: {
        email: true,
        phone: true,
        photo: true,
        work: false,
        school: true,
      },
    },
  });
  const { result } = await review({
    request: adminRequest({ uid: UID, type: 'work', decision: 'approved' }),
    db,
  });

  assert.deepEqual(result, { status: 'approved' });

  const requestUpdate = updateFor(
    db,
    `users/${UID}/affiliationVerificationRequests/work`,
  );
  assert.equal(requestUpdate.payload.status, 'approved');
  assert.equal(requestUpdate.payload.reviewedAt, SERVER_TIMESTAMP);
  assert.equal(requestUpdate.payload.rejectionReason, null);

  // 9. 비공개 / 10. 공개 배지 동기화, 11~12. 나머지 보존
  const expected = {
    email: true,
    phone: true,
    photo: true,
    work: true,
    school: true,
  };
  assert.deepEqual(updateFor(db, `users/${UID}`).payload.verifications, expected);
  assert.deepEqual(
    updateFor(db, `publicProfiles/${UID}`).payload.verifications,
    expected,
  );
});

test('8. school 승인은 school 배지만 켠다(legacy 3-key 문서도 안전)', async () => {
  // work/school 필드가 아예 없는 기존 문서
  const db = createFakeDb({
    userData: { verifications: { email: true, phone: false, photo: false } },
    publicData: { verifications: { email: true, phone: false, photo: false } },
  });
  const { result } = await review({
    request: adminRequest({ uid: UID, type: 'school', decision: 'approved' }),
    db,
  });

  assert.deepEqual(result, { status: 'approved' });
  const expected = {
    email: true,
    phone: false,
    photo: false,
    work: false,
    school: true,
  };
  assert.deepEqual(updateFor(db, `users/${UID}`).payload.verifications, expected);
  assert.deepEqual(
    updateFor(db, `publicProfiles/${UID}`).payload.verifications,
    expected,
  );
});

// ── 반려 ────────────────────────────────────────────────────────────────
test('13. 반려는 사유만 저장하고 배지를 켜지 않는다', async () => {
  const db = createFakeDb();
  const { result } = await review({
    request: adminRequest({
      uid: UID,
      type: 'work',
      decision: 'rejected',
      rejectionReason: 'institution_not_visible',
    }),
    db,
  });

  assert.deepEqual(result, { status: 'rejected' });
  const requestUpdate = updateFor(
    db,
    `users/${UID}/affiliationVerificationRequests/work`,
  );
  assert.equal(requestUpdate.payload.status, 'rejected');
  assert.equal(requestUpdate.payload.rejectionReason, 'institution_not_visible');

  // 배지 문서는 전혀 건드리지 않는다.
  assert.equal(updateFor(db, `users/${UID}`), undefined);
  assert.equal(updateFor(db, `publicProfiles/${UID}`), undefined);
});

// ── 상태 전이 ───────────────────────────────────────────────────────────
test('14. pending 요청만 검토할 수 있다', async () => {
  for (const status of ['approved', 'rejected']) {
    await assert.rejects(
      () =>
        review({
          request: adminRequest({ uid: UID, type: 'work', decision: 'approved' }),
          db: createFakeDb({ workRequest: requestDoc('work', { status }) }),
        }),
      (error) => error.code === 'failed-precondition',
    );
  }
  // 요청 문서가 없는 경우
  await assert.rejects(
    () =>
      review({
        request: adminRequest({ uid: UID, type: 'work', decision: 'approved' }),
        db: createFakeDb({ workExists: false }),
      }),
    (error) => error.code === 'not-found',
  );
  // 문서 body의 type이 어긋나면 거부
  await assert.rejects(
    () =>
      review({
        request: adminRequest({ uid: UID, type: 'work', decision: 'approved' }),
        db: createFakeDb({ workRequest: requestDoc('work', { type: 'school' }) }),
      }),
    (error) => error.code === 'failed-precondition',
  );
});

// ── Storage 정리 ────────────────────────────────────────────────────────
test('15. 검토 후 증빙 이미지를 삭제한다', async () => {
  const bucket = createFakeBucket();
  await review({
    request: adminRequest({ uid: UID, type: 'work', decision: 'approved' }),
    storageBucket: bucket,
  });
  assert.deepEqual(bucket.calls.deleted, [STORAGE_PATH]);
});

test('16. 파일이 이미 없어도 검토는 성공한다', async () => {
  const missing = Object.assign(new Error('not found'), { code: 404 });
  const { result, logger } = await review({
    request: adminRequest({
      uid: UID,
      type: 'work',
      decision: 'rejected',
      rejectionReason: 'expired_document',
    }),
    storageBucket: createFakeBucket({ deleteError: missing }),
  });
  assert.deepEqual(result, { status: 'rejected' });
  assert.ok(logger.lines.some((line) => line.includes('result=missing')));
});

test('삭제 실패해도 검토 결과를 되돌리지 않는다', async () => {
  const { result } = await review({
    request: adminRequest({ uid: UID, type: 'work', decision: 'approved' }),
    storageBucket: createFakeBucket({ deleteError: new Error('boom') }),
  });
  assert.deepEqual(result, { status: 'approved' });
});

// ── 개인정보 ────────────────────────────────────────────────────────────
test('17~18. 응답·로그에 uid/기관명/storagePath가 없다', async () => {
  const { result, logger } = await review({
    request: adminRequest({ uid: UID, type: 'work', decision: 'approved' }),
  });

  assert.deepEqual(Object.keys(result), ['status']);
  const serialized = JSON.stringify(result);
  for (const secret of [UID, INSTITUTION, STORAGE_PATH, '개발팀']) {
    assert.equal(serialized.includes(secret), false);
  }

  const joined = logger.lines.join('\n');
  for (const secret of [UID, INSTITUTION, STORAGE_PATH, '개발팀']) {
    assert.equal(joined.includes(secret), false);
  }
  assert.equal(joined.includes('affiliationVerification/'), false);
  // uid는 hash로만 남는다.
  assert.ok(/uidHash=[0-9a-f]{8}/.test(joined));
});

test('normalizeVerifications는 5개 bool 키만 남긴다', () => {
  assert.deepEqual(
    normalizeVerifications({
      email: true,
      phone: 'yes',
      photo: 1,
      work: true,
      school: 'true',
      extra: true,
    }),
    { email: true, phone: false, photo: false, work: true, school: false },
  );
  // legacy 3-key 문서
  assert.deepEqual(
    normalizeVerifications({ email: true, phone: true, photo: true }),
    { email: true, phone: true, photo: true, work: false, school: false },
  );
});
