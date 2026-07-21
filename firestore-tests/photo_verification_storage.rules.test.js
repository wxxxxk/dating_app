'use strict';

// Storage 보안 규칙 테스트 — 사진 인증 이미지 (Phase 3-2).
//
// photoVerification/{uid}/{fileName} 경로가 본인 전용이고, 이미지 타입/크기
// 제한과 update/delete 금지가 지켜지는지 Storage Emulator에서 검증한다.
// 기존 users/{uid} 경로 규칙 회귀도 함께 확인한다.

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

function jpeg(sizeBytes = 1024) {
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

function verificationRef(storage, uid = A, name = 'upload1.jpg') {
  return ref(storage, `photoVerification/${uid}/${name}`);
}

async function seedVerificationFile(uid = A, name = 'upload1.jpg') {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await uploadBytes(
      verificationRef(ctx.storage(), uid, name),
      jpeg(),
      { contentType: 'image/jpeg' },
    );
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
test('1. 본인 경로에 인증 이미지를 올릴 수 있다', async () => {
  await assertSucceeds(
    uploadBytes(verificationRef(aStorage()), jpeg(), {
      contentType: 'image/jpeg',
    }),
  );
  // 허용 확장자/타입 모두 통과
  await assertSucceeds(
    uploadBytes(verificationRef(aStorage(), A, 'a.png'), jpeg(), {
      contentType: 'image/png',
    }),
  );
  await assertSucceeds(
    uploadBytes(verificationRef(aStorage(), A, 'a.heic'), jpeg(), {
      contentType: 'image/heic',
    }),
  );
});

test('2. 다른 사용자 경로에는 올릴 수 없다', async () => {
  await assertFails(
    uploadBytes(verificationRef(bStorage(), A), jpeg(), {
      contentType: 'image/jpeg',
    }),
  );
  await assertFails(
    uploadBytes(verificationRef(anonStorage(), A), jpeg(), {
      contentType: 'image/jpeg',
    }),
  );
});

// ── read ────────────────────────────────────────────────────────────────
test('3. 다른 사용자는 인증 이미지를 읽을 수 없다', async () => {
  await seedVerificationFile();
  await assertFails(getBytes(verificationRef(bStorage())));
  await assertFails(getBytes(verificationRef(anonStorage())));
});

test('4. 본인은 자신의 인증 이미지를 읽을 수 있다', async () => {
  await seedVerificationFile();
  await assertSucceeds(getBytes(verificationRef(aStorage())));
});

// ── 제한 ────────────────────────────────────────────────────────────────
test('5. 5MB를 초과하면 거부된다', async () => {
  await assertFails(
    uploadBytes(verificationRef(aStorage(), A, 'big.jpg'), jpeg(5 * 1024 * 1024 + 1), {
      contentType: 'image/jpeg',
    }),
  );
  // 경계값(5MB)은 허용
  await assertSucceeds(
    uploadBytes(verificationRef(aStorage(), A, 'edge.jpg'), jpeg(5 * 1024 * 1024), {
      contentType: 'image/jpeg',
    }),
  );
});

test('6. 이미지가 아닌 파일/확장자는 거부된다', async () => {
  await assertFails(
    uploadBytes(verificationRef(aStorage(), A, 'a.pdf'), jpeg(), {
      contentType: 'application/pdf',
    }),
  );
  // 확장자는 이미지지만 contentType이 다른 경우
  await assertFails(
    uploadBytes(verificationRef(aStorage(), A, 'a.jpg'), jpeg(), {
      contentType: 'text/plain',
    }),
  );
  // contentType은 이미지지만 확장자가 허용 목록 밖인 경우
  await assertFails(
    uploadBytes(verificationRef(aStorage(), A, 'a.gif'), jpeg(), {
      contentType: 'image/jpeg',
    }),
  );
});

// ── update / delete ─────────────────────────────────────────────────────
test('7. 기존 파일 메타데이터 수정은 거부된다', async () => {
  await seedVerificationFile();
  await assertFails(
    updateMetadata(verificationRef(aStorage()), {
      contentType: 'image/png',
    }),
  );
});

test('8. 클라이언트는 인증 이미지를 삭제할 수 없다', async () => {
  await seedVerificationFile();
  await assertFails(deleteObject(verificationRef(aStorage())));
});

// ── 기존 경로 회귀 ──────────────────────────────────────────────────────
test('9. users/{uid} 프로필 사진 경로 규칙은 그대로다', async () => {
  // 본인 폴더 쓰기 허용
  await assertSucceeds(
    uploadBytes(ref(aStorage(), `users/${A}/profile/main.jpg`), jpeg(), {
      contentType: 'image/jpeg',
    }),
  );
  // 남의 폴더 쓰기 거부
  await assertFails(
    uploadBytes(ref(bStorage(), `users/${A}/profile/main.jpg`), jpeg(), {
      contentType: 'image/jpeg',
    }),
  );
  // 인증된 사용자는 프로필 사진을 읽을 수 있다(기존 계약)
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await uploadBytes(
      ref(ctx.storage(), `users/${A}/profile/seed.jpg`),
      jpeg(),
      { contentType: 'image/jpeg' },
    );
  });
  await assertSucceeds(getBytes(ref(bStorage(), `users/${A}/profile/seed.jpg`)));
});
