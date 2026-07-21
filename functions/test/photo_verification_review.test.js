'use strict';

// Phase 3-2 — reviewPhotoVerification core 테스트.
//
// Firestore/Storage를 fake로 주입해 권한 검사, 상태 전이, 배지 동기화,
// 검토 후 이미지 삭제, 로그·응답의 개인정보 미노출을 확인한다.

const assert = require('node:assert/strict');
const { test } = require('node:test');

const {
  reviewPhotoVerificationCore,
  validateReviewInput,
  normalizeVerifications,
} = require('../lib/photo_verification_review');

const UID = 'target-uid';
const ADMIN_UID = 'admin-uid';
const STORAGE_PATH = 'photoVerification/target-uid/1721000000000_abc123def456.jpg';
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

/**
 * transaction만 지원하는 최소 fake Firestore.
 * 커밋된 update payload를 그대로 기록해 검증한다.
 */
function createFakeDb({
  requestData = {
    uid: UID,
    status: 'pending',
    storagePath: STORAGE_PATH,
    schemaVersion: 1,
  },
  requestExists = true,
  userData = { verifications: { email: true, phone: true, photo: false } },
  publicData = { verifications: { email: true, phone: true, photo: false } },
  userExists = true,
  publicExists = true,
} = {}) {
  const docs = {
    [`photoVerificationRequests/${UID}`]: {
      exists: requestExists,
      data: requestData,
    },
    [`users/${UID}`]: { exists: userExists, data: userData },
    [`publicProfiles/${UID}`]: { exists: publicExists, data: publicData },
  };
  const calls = { updates: [], committedUpdates: [] };

  const makeRef = (path) => ({ path });

  return {
    calls,
    collection(name) {
      return { doc: (id) => makeRef(`${name}/${id}`) };
    },
    async runTransaction(handler) {
      calls.updates.length = 0;
      const tx = {
        async get(ref) {
          const entry = docs[ref.path] || { exists: false, data: undefined };
          return {
            exists: entry.exists,
            data: () => entry.data,
          };
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
  const result = await reviewPhotoVerificationCore({
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
    () => review({ request: { data: { uid: UID, decision: 'approved' } } }),
    (error) => error.code === 'unauthenticated',
  );
});

test('2. admin claim이 없으면 거부된다', async () => {
  await assert.rejects(
    () =>
      review({
        request: {
          auth: { uid: 'normal-user', token: {} },
          data: { uid: UID, decision: 'approved' },
        },
      }),
    (error) => error.code === 'permission-denied',
  );
  // developer 등 다른 claim으로는 통과할 수 없다.
  await assert.rejects(
    () =>
      review({
        request: {
          auth: { uid: 'dev', token: { developer: true, admin: false } },
          data: { uid: UID, decision: 'approved' },
        },
      }),
    (error) => error.code === 'permission-denied',
  );
});

// ── 입력 검증 ────────────────────────────────────────────────────────────
test('3. 허용되지 않는 decision은 거부된다', async () => {
  for (const decision of [undefined, null, 'pending', 'APPROVED', 1]) {
    await assert.rejects(
      () => review({ request: adminRequest({ uid: UID, decision }) }),
      (error) => error.code === 'invalid-argument',
    );
  }
  await assert.rejects(
    () => review({ request: adminRequest({ uid: '', decision: 'approved' }) }),
    (error) => error.code === 'invalid-argument',
  );
});

test('4. 반려 사유 검증', async () => {
  // rejected인데 사유가 없거나 허용 목록 밖이면 거부
  for (const reason of [undefined, null, 'because', '기타']) {
    await assert.rejects(
      () =>
        review({
          request: adminRequest({
            uid: UID,
            decision: 'rejected',
            rejectionReason: reason,
          }),
        }),
      (error) => error.code === 'invalid-argument',
    );
  }
  // approved에는 사유를 넣을 수 없다
  await assert.rejects(
    () =>
      review({
        request: adminRequest({
          uid: UID,
          decision: 'approved',
          rejectionReason: 'other',
        }),
      }),
    (error) => error.code === 'invalid-argument',
  );

  // 허용 사유는 모두 통과한다(순수 검증 함수 기준)
  for (const reason of [
    'face_not_clear',
    'photo_mismatch',
    'face_covered',
    'image_quality',
    'other',
  ]) {
    const parsed = validateReviewInput(
      { uid: UID, decision: 'rejected', rejectionReason: reason },
      FakeHttpsError,
    );
    assert.equal(parsed.rejectionReason, reason);
  }
});

// ── 승인 ────────────────────────────────────────────────────────────────
test('5~8. pending 승인은 두 프로필의 photo 배지만 켜고 나머지는 보존한다', async () => {
  const db = createFakeDb({
    // work=true인 사용자의 사진 승인이 소속 인증 배지를 지우지 않아야 한다.
    userData: {
      verifications: { email: true, phone: false, photo: false, work: true },
    },
    publicData: {
      verifications: { email: true, phone: false, photo: false, work: true },
    },
  });
  const { result, storageBucket } = await review({
    request: adminRequest({ uid: UID, decision: 'approved', rejectionReason: null }),
    db,
  });

  assert.deepEqual(result, { status: 'approved' });

  const requestUpdate = updateFor(db, `photoVerificationRequests/${UID}`);
  assert.equal(requestUpdate.payload.status, 'approved');
  assert.equal(requestUpdate.payload.reviewedAt, SERVER_TIMESTAMP);
  assert.equal(requestUpdate.payload.rejectionReason, null);

  // 6. 비공개 프로필 배지
  const userUpdate = updateFor(db, `users/${UID}`);
  assert.deepEqual(userUpdate.payload.verifications, {
    email: true,
    phone: false,
    photo: true,
    work: true,
    school: false,
  });
  // 7. 공개 프로필 배지
  const publicUpdate = updateFor(db, `publicProfiles/${UID}`);
  assert.deepEqual(publicUpdate.payload.verifications, {
    email: true,
    phone: false,
    photo: true,
    work: true,
    school: false,
  });
  // 8. 다른 verification 값(email/phone)은 그대로 보존된다.
  assert.equal(userUpdate.payload.verifications.email, true);
  assert.equal(storageBucket.calls.deleted.length, 1);
});

// ── 반려 ────────────────────────────────────────────────────────────────
test('9~10. 반려는 사유를 저장하고 배지를 켜지 않는다', async () => {
  const db = createFakeDb();
  const { result } = await review({
    request: adminRequest({
      uid: UID,
      decision: 'rejected',
      rejectionReason: 'face_covered',
    }),
    db,
  });

  assert.deepEqual(result, { status: 'rejected' });
  const requestUpdate = updateFor(db, `photoVerificationRequests/${UID}`);
  assert.equal(requestUpdate.payload.status, 'rejected');
  assert.equal(requestUpdate.payload.rejectionReason, 'face_covered');

  // 배지 문서는 전혀 건드리지 않는다.
  assert.equal(updateFor(db, `users/${UID}`), undefined);
  assert.equal(updateFor(db, `publicProfiles/${UID}`), undefined);
});

// ── 상태 전이 ───────────────────────────────────────────────────────────
test('11. 이미 검토된 요청/없는 요청은 거부된다', async () => {
  for (const status of ['approved', 'rejected']) {
    await assert.rejects(
      () =>
        review({
          request: adminRequest({ uid: UID, decision: 'approved' }),
          db: createFakeDb({
            requestData: { uid: UID, status, storagePath: STORAGE_PATH },
          }),
        }),
      (error) => error.code === 'failed-precondition',
    );
  }
  await assert.rejects(
    () =>
      review({
        request: adminRequest({ uid: UID, decision: 'approved' }),
        db: createFakeDb({ requestExists: false }),
      }),
    (error) => error.code === 'not-found',
  );
});

// ── Storage 정리 ────────────────────────────────────────────────────────
test('12. 검토 후 인증 사진을 삭제한다', async () => {
  const bucket = createFakeBucket();
  await review({
    request: adminRequest({ uid: UID, decision: 'approved' }),
    storageBucket: bucket,
  });
  assert.deepEqual(bucket.calls.deleted, [STORAGE_PATH]);
});

test('13. 파일이 이미 없어도 검토는 성공한다', async () => {
  const missing = Object.assign(new Error('not found'), { code: 404 });
  const { result, logger } = await review({
    request: adminRequest({
      uid: UID,
      decision: 'rejected',
      rejectionReason: 'image_quality',
    }),
    storageBucket: createFakeBucket({ deleteError: missing }),
  });
  assert.deepEqual(result, { status: 'rejected' });
  assert.ok(logger.lines.some((line) => line.includes('result=missing')));
});

test('삭제 실패해도 검토 결과를 되돌리지 않는다', async () => {
  const { result } = await review({
    request: adminRequest({ uid: UID, decision: 'approved' }),
    storageBucket: createFakeBucket({ deleteError: new Error('boom') }),
  });
  assert.deepEqual(result, { status: 'approved' });
});

// ── 개인정보 ────────────────────────────────────────────────────────────
test('14~15. 응답·로그에 storagePath/raw uid가 없다', async () => {
  const { result, logger } = await review({
    request: adminRequest({ uid: UID, decision: 'approved' }),
  });

  assert.deepEqual(Object.keys(result), ['status']);
  assert.equal(JSON.stringify(result).includes(STORAGE_PATH), false);
  assert.equal(JSON.stringify(result).includes(UID), false);

  const joined = logger.lines.join('\n');
  assert.equal(joined.includes(STORAGE_PATH), false);
  assert.equal(joined.includes(UID), false);
  assert.equal(joined.includes('photoVerification/'), false);
  // uid는 hash로만 남는다.
  assert.ok(/uidHash=[0-9a-f]{8}/.test(joined));
});

test('normalizeVerifications는 허용 bool 키만 남긴다(work/school 포함)', () => {
  assert.deepEqual(
    normalizeVerifications({
      email: true,
      phone: 'yes',
      photo: 1,
      work: true,
      extra: true,
    }),
    { email: true, phone: false, photo: false, work: true, school: false },
  );
  // 기존 3-key 문서는 work/school을 false로 읽는다.
  assert.deepEqual(
    normalizeVerifications({ email: true, phone: true, photo: true }),
    { email: true, phone: true, photo: true, work: false, school: false },
  );
  assert.deepEqual(normalizeVerifications(undefined), {
    email: false,
    phone: false,
    photo: false,
    work: false,
    school: false,
  });
});
