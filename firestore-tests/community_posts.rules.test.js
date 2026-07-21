'use strict';

// Firestore 보안 규칙 테스트 — 커뮤니티 기반 (Phase 4-1).
//
// 읽기는 로그인 사용자의 active/authenticated 게시물로만 열려 있고, 형태가
// 깨진 문서와 client write는 전면 차단되는지 검증한다.

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
  orderBy,
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
const AUTHOR = 'authorA';

let testEnv;

function authorSnapshot(overrides = {}) {
  return {
    uid: AUTHOR,
    displayName: '작성자',
    photoUrl: 'https://example.test/a.jpg',
    photoVerified: true,
    workVerified: false,
    schoolVerified: false,
    ...overrides,
  };
}

function postDoc(overrides = {}) {
  return {
    surface: 'lounge',
    authorUid: AUTHOR,
    authorSnapshot: authorSnapshot(),
    text: '오늘 라운지에서 만나요',
    imageUrls: [],
    status: 'active',
    visibility: 'authenticated',
    reactionCount: 2,
    commentCount: 1,
    createdAt: Timestamp.now(),
    updatedAt: Timestamp.now(),
    schemaVersion: 1,
    ...overrides,
  };
}

function aDb() {
  return testEnv.authenticatedContext(A).firestore();
}
function anonDb() {
  return testEnv.unauthenticatedContext().firestore();
}

function postRef(db, id) {
  return doc(db, 'communityPosts', id);
}

async function seedPost(id, data) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(postRef(ctx.firestore(), id), data);
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
test('1~2. 로그인 사용자는 active lounge/feed 게시물을 읽을 수 있다', async () => {
  await seedPost('lounge1', postDoc());
  await seedPost('feed1', postDoc({ surface: 'feed' }));

  await assertSucceeds(getDoc(postRef(aDb(), 'lounge1')));
  await assertSucceeds(getDoc(postRef(aDb(), 'feed1')));

  // 서비스가 쓰는 쿼리 형태도 통과해야 한다.
  await assertSucceeds(
    getDocs(
      query(
        collection(aDb(), 'communityPosts'),
        where('surface', '==', 'lounge'),
        where('status', '==', 'active'),
        where('visibility', '==', 'authenticated'),
        orderBy('createdAt', 'desc'),
      ),
    ),
  );
});

test('3. 비로그인 사용자는 읽을 수 없다', async () => {
  await seedPost('lounge1', postDoc());
  await assertFails(getDoc(postRef(anonDb(), 'lounge1')));
});

test('4~6. hidden/removed/잘못된 visibility는 읽을 수 없다', async () => {
  await seedPost('hidden1', postDoc({ status: 'hidden' }));
  await seedPost('removed1', postDoc({ status: 'removed' }));
  await seedPost('public1', postDoc({ visibility: 'public' }));

  await assertFails(getDoc(postRef(aDb(), 'hidden1')));
  await assertFails(getDoc(postRef(aDb(), 'removed1')));
  await assertFails(getDoc(postRef(aDb(), 'public1')));

  // status 필터 없는 전체 조회도 거부된다.
  await assertFails(getDocs(collection(aDb(), 'communityPosts')));
});

// 형태(shape) 검증은 get에서 이뤄진다. list는 쿼리로 보장 가능한 조건만
// 검사하므로(엔진 제약), 깨진 문서는 클라이언트 parser가 걸러낸다.
test('7~9. 형태가 깨진 문서는 get으로 읽을 수 없다', async () => {
  // 7. 알 수 없는 surface
  await seedPost('badSurface', postDoc({ surface: 'party' }));
  await assertFails(getDoc(postRef(aDb(), 'badSurface')));

  // 8. author snapshot 형태 오류(필드 누락 / 길이 초과 / 타입 오류)
  const noPhotoField = authorSnapshot();
  delete noPhotoField.photoVerified;
  await seedPost('badAuthor1', postDoc({ authorSnapshot: noPhotoField }));
  await assertFails(getDoc(postRef(aDb(), 'badAuthor1')));

  await seedPost(
    'badAuthor2',
    postDoc({ authorSnapshot: authorSnapshot({ displayName: 'ㄱ'.repeat(41) }) }),
  );
  await assertFails(getDoc(postRef(aDb(), 'badAuthor2')));

  await seedPost(
    'badAuthor3',
    postDoc({ authorSnapshot: authorSnapshot({ photoVerified: 'yes' }) }),
  );
  await assertFails(getDoc(postRef(aDb(), 'badAuthor3')));

  // 9. authorUid와 snapshot.uid 불일치
  await seedPost(
    'mismatch',
    postDoc({ authorSnapshot: authorSnapshot({ uid: 'someoneElse' }) }),
  );
  await assertFails(getDoc(postRef(aDb(), 'mismatch')));
});

test('10~11. 음수 count·unknown field·본문 길이 위반은 get으로 읽을 수 없다', async () => {
  await seedPost('neg1', postDoc({ reactionCount: -1 }));
  await seedPost('neg2', postDoc({ commentCount: -3 }));
  await seedPost('extra', postDoc({ internalScore: 5 }));
  await seedPost('longText', postDoc({ text: 'ㄱ'.repeat(1001) }));
  await seedPost('emptyText', postDoc({ text: '' }));
  await seedPost('manyImages', postDoc({ imageUrls: ['a', 'b', 'c', 'd', 'e'] }));
  await seedPost('badSchema', postDoc({ schemaVersion: 2 }));

  for (const id of [
    'neg1',
    'neg2',
    'extra',
    'longText',
    'emptyText',
    'manyImages',
    'badSchema',
  ]) {
    await assertFails(getDoc(postRef(aDb(), id)), id);
  }
});

// ── write ───────────────────────────────────────────────────────────────
test('12~14. 클라이언트는 게시물을 만들거나 고치거나 지울 수 없다', async () => {
  await seedPost('lounge1', postDoc());

  await assertFails(
    setDoc(postRef(aDb(), 'newPost'), {
      ...postDoc({ authorUid: A, authorSnapshot: authorSnapshot({ uid: A }) }),
      createdAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
    }),
  );
  await assertFails(updateDoc(postRef(aDb(), 'lounge1'), { text: '수정' }));
  await assertFails(
    updateDoc(postRef(aDb(), 'lounge1'), { reactionCount: 999 }),
  );
  await assertFails(deleteDoc(postRef(aDb(), 'lounge1')));
});

// ── comments ────────────────────────────────────────────────────────────
test('15~16. 댓글 서브컬렉션은 아직 열려 있지 않다', async () => {
  await seedPost('lounge1', postDoc());
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(
      doc(ctx.firestore(), 'communityPosts', 'lounge1', 'comments', 'c1'),
      {
        postId: 'lounge1',
        authorUid: AUTHOR,
        authorSnapshot: authorSnapshot(),
        text: '댓글',
        status: 'active',
        createdAt: Timestamp.now(),
        updatedAt: Timestamp.now(),
        schemaVersion: 1,
      },
    );
  });

  const commentRef = doc(
    aDb(),
    'communityPosts',
    'lounge1',
    'comments',
    'c1',
  );
  await assertFails(getDoc(commentRef));
  await assertFails(
    getDocs(collection(aDb(), 'communityPosts', 'lounge1', 'comments')),
  );
  await assertFails(updateDoc(commentRef, { text: '수정' }));
  await assertFails(deleteDoc(commentRef));
  await assertFails(
    setDoc(doc(aDb(), 'communityPosts', 'lounge1', 'comments', 'c2'), {
      postId: 'lounge1',
      authorUid: A,
      text: '새 댓글',
      status: 'active',
      createdAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
      schemaVersion: 1,
    }),
  );
});

// ── 기존 규칙 회귀 ──────────────────────────────────────────────────────
test('17. 기존 users/publicProfiles 규칙은 그대로다', async () => {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
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

  await assertSucceeds(getDoc(doc(aDb(), 'users', A)));
  await assertSucceeds(getDoc(doc(aDb(), 'publicProfiles', A)));
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
