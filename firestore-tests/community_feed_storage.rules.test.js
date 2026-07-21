'use strict';

// Storage 보안 규칙 테스트 — 커뮤니티 Feed 이미지 (Phase 4-3).
//
// communityFeed/{uid}/{postId}/{fileName} 경로가
// - 본인만 create할 수 있고(크기·형식 제한),
// - read는 Firestore의 대응 게시물이 살아 있을 때만 열리며(cross-service),
// - update/delete는 항상 막히는지 검증한다.
//
// 게시물이 removed가 되는 즉시 이미지 read가 막히는 것이 이 Phase의 핵심
// 계약이다(download URL을 저장하지 않는 이유).

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
const { doc, setDoc, Timestamp } = require('firebase/firestore');

const A = 'userA';
const B = 'userB';
const POST_ID = 'abcdefghij0123456789';
const OTHER_POST_ID = 'zyxwvutsrq9876543210';

let testEnv;

function jpeg(sizeBytes = 1024) {
  return new Uint8Array(sizeBytes);
}

function feedPath(uid = A, postId = POST_ID, name = 'imageOne.jpg') {
  return `communityFeed/${uid}/${postId}/${name}`;
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

function authorSnapshot(uid) {
  return {
    uid,
    displayName: '작성자',
    photoUrl: '',
    photoVerified: false,
    workVerified: false,
    schoolVerified: false,
  };
}

/** Firestore에 대응 Feed 게시물을 심는다(Rules 우회). */
async function seedFeedPost(
  postId,
  { authorUid = A, status = 'active', imagePaths, ...overrides } = {},
) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), 'communityPosts', postId), {
      surface: 'feed',
      authorUid,
      authorSnapshot: authorSnapshot(authorUid),
      text: '사진 게시물',
      imageUrls: [],
      imagePaths: imagePaths ?? [feedPath(authorUid, postId)],
      status,
      visibility: 'authenticated',
      reactionCount: 0,
      commentCount: 0,
      createdAt: Timestamp.now(),
      updatedAt: Timestamp.now(),
      schemaVersion: 1,
      ...overrides,
    });
  });
}

/** Rules를 우회해 실제 이미지 파일을 올려둔다. */
async function seedFeedFile(path) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await uploadBytes(ref(ctx.storage(), path), jpeg(), {
      contentType: 'image/jpeg',
    });
  });
}

before(async () => {
  const storageHost =
    process.env.FIREBASE_STORAGE_EMULATOR_HOST || '127.0.0.1:9199';
  const [sh, sp] = storageHost.replace(/^https?:\/\//, '').split(':');
  const firestoreHost = process.env.FIRESTORE_EMULATOR_HOST || '127.0.0.1:8080';
  const [fh, fp] = firestoreHost.split(':');

  testEnv = await initializeTestEnvironment({
    projectId: 'demo-dating-app',
    storage: {
      rules: readFileSync(resolve(__dirname, '../storage.rules'), 'utf8'),
      host: sh,
      port: Number(sp),
    },
    firestore: {
      rules: readFileSync(resolve(__dirname, '../firestore.rules'), 'utf8'),
      host: fh,
      port: Number(fp),
    },
  });
});

after(async () => {
  if (testEnv) await testEnv.cleanup();
});

beforeEach(async () => {
  await testEnv.clearStorage();
  await testEnv.clearFirestore();
});

// ── create ──────────────────────────────────────────────────────────────
test('1~2. 본인 경로에 jpg/png를 올릴 수 있다', async () => {
  await assertSucceeds(
    uploadBytes(ref(aStorage(), feedPath()), jpeg(), {
      contentType: 'image/jpeg',
    }),
  );
  await assertSucceeds(
    uploadBytes(ref(aStorage(), feedPath(A, POST_ID, 'imageTwo.png')), jpeg(), {
      contentType: 'image/png',
    }),
  );
});

test('3~4. 다른 사용자 경로와 비로그인 업로드는 막힌다', async () => {
  await assertFails(
    uploadBytes(ref(bStorage(), feedPath(A)), jpeg(), {
      contentType: 'image/jpeg',
    }),
  );
  await assertFails(
    uploadBytes(ref(anonStorage(), feedPath(A)), jpeg(), {
      contentType: 'image/jpeg',
    }),
  );
});

test('5~6. 5MB 초과·빈 파일은 막힌다', async () => {
  await assertFails(
    uploadBytes(ref(aStorage(), feedPath()), jpeg(5 * 1024 * 1024 + 1), {
      contentType: 'image/jpeg',
    }),
  );
  await assertFails(
    uploadBytes(ref(aStorage(), feedPath()), jpeg(0), {
      contentType: 'image/jpeg',
    }),
  );
});

test('7~8. HEIC와 잘못된 확장자/타입은 막힌다', async () => {
  await assertFails(
    uploadBytes(ref(aStorage(), feedPath(A, POST_ID, 'a.heic')), jpeg(), {
      contentType: 'image/heic',
    }),
  );
  // 확장자는 맞지만 contentType이 다른 경우
  await assertFails(
    uploadBytes(ref(aStorage(), feedPath(A, POST_ID, 'a.jpg')), jpeg(), {
      contentType: 'image/gif',
    }),
  );
  // contentType은 맞지만 확장자가 다른 경우
  await assertFails(
    uploadBytes(ref(aStorage(), feedPath(A, POST_ID, 'a.gif')), jpeg(), {
      contentType: 'image/jpeg',
    }),
  );
  // postId가 auto-ID 형식이 아니면 막는다.
  await assertFails(
    uploadBytes(ref(aStorage(), feedPath(A, 'short', 'a.jpg')), jpeg(), {
      contentType: 'image/jpeg',
    }),
  );
});

// ── update / delete ─────────────────────────────────────────────────────
test('9~10. update와 delete는 항상 막힌다(삭제는 Admin SDK만)', async () => {
  const path = feedPath();
  await seedFeedFile(path);
  await seedFeedPost(POST_ID);

  await assertFails(
    updateMetadata(ref(aStorage(), path), { contentType: 'image/png' }),
  );
  await assertFails(deleteObject(ref(aStorage(), path)));
});

// ── read (cross-service) ────────────────────────────────────────────────
test('11. active Feed 게시물이 참조하는 이미지는 읽을 수 있다', async () => {
  const path = feedPath();
  await seedFeedFile(path);
  await seedFeedPost(POST_ID);

  // 작성자 본인과 다른 로그인 사용자 모두 읽을 수 있다(공개 커뮤니티).
  await assertSucceeds(getBytes(ref(aStorage(), path)));
  await assertSucceeds(getBytes(ref(bStorage(), path)));
});

test('12. removed 게시물의 이미지는 즉시 읽을 수 없다', async () => {
  const path = feedPath();
  await seedFeedFile(path);
  await seedFeedPost(POST_ID, { status: 'removed' });

  await assertFails(getBytes(ref(aStorage(), path)));
  await assertFails(getBytes(ref(bStorage(), path)));
});

test('13. 게시물이 참조하지 않는 경로는 읽을 수 없다', async () => {
  const orphan = feedPath(A, POST_ID, 'orphan.jpg');
  await seedFeedFile(orphan);
  // 게시물은 다른 파일만 참조한다.
  await seedFeedPost(POST_ID, { imagePaths: [feedPath(A, POST_ID)] });
  await assertFails(getBytes(ref(aStorage(), orphan)));

  // 대응 게시물 자체가 없는 경우도 막힌다.
  const noPost = feedPath(A, OTHER_POST_ID);
  await seedFeedFile(noPost);
  await assertFails(getBytes(ref(aStorage(), noPost)));
});

test('작성자와 경로 uid가 다르면 읽을 수 없다', async () => {
  // B의 경로에 있는 파일을 A가 작성한 글이 참조하는 위조 상황.
  const path = feedPath(B, POST_ID);
  await seedFeedFile(path);
  await seedFeedPost(POST_ID, { authorUid: A, imagePaths: [path] });

  await assertFails(getBytes(ref(aStorage(), path)));
});

test('14. 비로그인 사용자는 읽을 수 없다', async () => {
  const path = feedPath();
  await seedFeedFile(path);
  await seedFeedPost(POST_ID);

  await assertFails(getBytes(ref(anonStorage(), path)));
});

// ── 기존 경로 회귀 ──────────────────────────────────────────────────────
test('15. 기존 profile/photo/affiliation Storage 규칙은 그대로다', async () => {
  // users/{uid}: 인증 사용자 read, 본인만 write
  await assertSucceeds(
    uploadBytes(ref(aStorage(), `users/${A}/profile/p.jpg`), jpeg(), {
      contentType: 'image/jpeg',
    }),
  );
  await assertFails(
    uploadBytes(ref(bStorage(), `users/${A}/profile/p.jpg`), jpeg(), {
      contentType: 'image/jpeg',
    }),
  );
  await assertSucceeds(getBytes(ref(bStorage(), `users/${A}/profile/p.jpg`)));

  // photoVerification: 본인만 create/read, HEIC 허용 유지
  await assertSucceeds(
    uploadBytes(ref(aStorage(), `photoVerification/${A}/s.heic`), jpeg(), {
      contentType: 'image/heic',
    }),
  );
  await assertFails(getBytes(ref(bStorage(), `photoVerification/${A}/s.heic`)));

  // affiliationVerification: 본인만
  await assertSucceeds(
    uploadBytes(ref(aStorage(), `affiliationVerification/${A}/work/d.jpg`), jpeg(), {
      contentType: 'image/jpeg',
    }),
  );
  await assertFails(
    uploadBytes(ref(bStorage(), `affiliationVerification/${A}/work/d.jpg`), jpeg(), {
      contentType: 'image/jpeg',
    }),
  );
});
