'use strict';

// Storage 보안 규칙 테스트 — 소속 인증 증빙 이미지 (Phase 3-3).
//
// affiliationVerification/{uid}/{type}/{fileName} 경로가 본인 전용이고,
// 이미지 타입/크기 제한과 update/delete 금지가 지켜지는지 검증한다.
// 사진 인증(Phase 3-2)·프로필 사진 경로 회귀도 함께 확인한다.

const { readFileSync } = require('node:fs');
const { resolve } = require('node:path');
const { after, before, beforeEach, test } = require('node:test');

const {
  initializeTestEnvironment,
  assertSucceeds,
  assertFails,
} = require('@firebase/rules-unit-testing');
const {
  ref,
  uploadBytes,
  getBytes,
  deleteObject,
  updateMetadata,
} = require('firebase/storage');

const A = 'userA';
const B = 'userB';

let testEnv;

function image(sizeBytes = 1024) {
  return new Uint8Array(sizeBytes);
}

function aStorage() {
  return testEnv.authenticatedContext(A).storage();
}
function bStorage() {
  return testEnv.authenticatedContext(B).storage();
}
function anonStorage() {
  return testEnv.unauthenticatedContext().storage();
}

function proofRef(storage, { uid = A, type = 'work', name = 'upload1.jpg' } = {}) {
  return ref(storage, `affiliationVerification/${uid}/${type}/${name}`);
}

async function seedProof(options = {}) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await uploadBytes(proofRef(ctx.storage(), options), image(), {
      contentType: 'image/jpeg',
    });
  });
}

before(async () => {
  const host = process.env.FIREBASE_STORAGE_EMULATOR_HOST || '127.0.0.1:9199';
  const [h, p] = host.replace(/^https?:\/\//, '').split(':');
  testEnv = await initializeTestEnvironment({
    projectId: 'demo-dating-app',
    storage: {
      rules: readFileSync(resolve(__dirname, '../storage.rules'), 'utf8'),
      host: h,
      port: Number(p),
    },
  });
});

after(async () => {
  if (testEnv) await testEnv.cleanup();
});

beforeEach(async () => {
  await testEnv.clearStorage();
});

// ── create ──────────────────────────────────────────────────────────────
test('1~2. 본인 work/school 경로에 증빙 이미지를 올릴 수 있다', async () => {
  await assertSucceeds(
    uploadBytes(proofRef(aStorage(), { type: 'work' }), image(), {
      contentType: 'image/jpeg',
    }),
  );
  await assertSucceeds(
    uploadBytes(
      proofRef(aStorage(), { type: 'school', name: 'a.png' }),
      image(),
      { contentType: 'image/png' },
    ),
  );
  await assertSucceeds(
    uploadBytes(
      proofRef(aStorage(), { type: 'work', name: 'a.heic' }),
      image(),
      { contentType: 'image/heic' },
    ),
  );
});

test('3. 다른 사용자 경로에는 올릴 수 없다', async () => {
  await assertFails(
    uploadBytes(proofRef(bStorage(), { uid: A }), image(), {
      contentType: 'image/jpeg',
    }),
  );
  await assertFails(
    uploadBytes(proofRef(anonStorage(), { uid: A }), image(), {
      contentType: 'image/jpeg',
    }),
  );
});

// ── read ────────────────────────────────────────────────────────────────
test('4. 다른 사용자는 증빙 이미지를 읽을 수 없다', async () => {
  await seedProof();
  await assertFails(getBytes(proofRef(bStorage(), { uid: A })));
  await assertFails(getBytes(proofRef(anonStorage(), { uid: A })));
});

test('5. 본인은 자신의 증빙 이미지를 읽을 수 있다', async () => {
  await seedProof();
  await assertSucceeds(getBytes(proofRef(aStorage())));
});

// ── 제한 ────────────────────────────────────────────────────────────────
test('6. 알 수 없는 type 경로는 거부된다', async () => {
  await assertFails(
    uploadBytes(proofRef(aStorage(), { type: 'company' }), image(), {
      contentType: 'image/jpeg',
    }),
  );
  await seedProof({ type: 'company' });
  await assertFails(getBytes(proofRef(aStorage(), { type: 'company' })));
});

test('7. 5MB를 초과하면 거부된다', async () => {
  await assertFails(
    uploadBytes(
      proofRef(aStorage(), { name: 'big.jpg' }),
      image(5 * 1024 * 1024 + 1),
      { contentType: 'image/jpeg' },
    ),
  );
  await assertSucceeds(
    uploadBytes(
      proofRef(aStorage(), { name: 'edge.jpg' }),
      image(5 * 1024 * 1024),
      { contentType: 'image/jpeg' },
    ),
  );
});

test('8~9. 비이미지 MIME/확장자는 거부된다', async () => {
  await assertFails(
    uploadBytes(proofRef(aStorage(), { name: 'a.pdf' }), image(), {
      contentType: 'application/pdf',
    }),
  );
  await assertFails(
    uploadBytes(proofRef(aStorage(), { name: 'a.jpg' }), image(), {
      contentType: 'text/plain',
    }),
  );
  await assertFails(
    uploadBytes(proofRef(aStorage(), { name: 'a.gif' }), image(), {
      contentType: 'image/jpeg',
    }),
  );
});

// ── update / delete ─────────────────────────────────────────────────────
test('10. 기존 파일 메타데이터 수정은 거부된다', async () => {
  await seedProof();
  await assertFails(
    updateMetadata(proofRef(aStorage()), { contentType: 'image/png' }),
  );
});

test('11. 클라이언트는 증빙 이미지를 삭제할 수 없다', async () => {
  await seedProof();
  await assertFails(deleteObject(proofRef(aStorage())));
});

// ── 기존 경로 회귀 ──────────────────────────────────────────────────────
test('12. 사진 인증·프로필 사진 경로 규칙은 그대로다', async () => {
  // 사진 인증: 본인 create 허용 / 타인 read 거부
  await assertSucceeds(
    uploadBytes(ref(aStorage(), `photoVerification/${A}/up1.jpg`), image(), {
      contentType: 'image/jpeg',
    }),
  );
  await assertFails(getBytes(ref(bStorage(), `photoVerification/${A}/up1.jpg`)));

  // 프로필 사진: 본인 쓰기 / 인증 사용자 읽기
  await assertSucceeds(
    uploadBytes(ref(aStorage(), `users/${A}/profile/main.jpg`), image(), {
      contentType: 'image/jpeg',
    }),
  );
  await assertSucceeds(getBytes(ref(bStorage(), `users/${A}/profile/main.jpg`)));
  await assertFails(
    uploadBytes(ref(bStorage(), `users/${A}/profile/main.jpg`), image(), {
      contentType: 'image/jpeg',
    }),
  );
});
