'use strict';

// Phase 4-3 — 커뮤니티 Feed(이미지 게시물) 서버 core 테스트.
//
// 확인 범위: postId 형식, 이미지 개수/소유자/경로 검증, Storage metadata
// 재확인(크기·MIME·총합), canonical author snapshot, imageUrls 미저장,
// 실패 시 draft object 정리, 멱등성, 삭제 시 실제 파일 제거, 응답·로그의
// 개인정보 미노출.

const assert = require('node:assert/strict');
const { test } = require('node:test');

const {
  FEED_MAX_IMAGE_BYTES,
  createFeedPostCore,
  deleteCommunityPostCore,
  feedImagePathPrefix,
} = require('../lib/community');

const ME = 'me-uid';
const OTHER = 'other-uid';
const POST_ID = 'abcdefghij0123456789'; // 20자리 auto-ID 형식

class FakeHttpsError extends Error {
  constructor(code, message, details) {
    super(message);
    this.code = code;
    this.details = details;
  }
}

function fakeTimestamp(millis) {
  return { toMillis: () => millis, __serverTimestamp: true };
}

/** community.test.js와 같은 최소 fake Firestore(필요한 기능만). */
function createFakeDb({ docs = {} } = {}) {
  const store = new Map(Object.entries(docs));
  let chain = Promise.resolve();

  function snapshotOf(path) {
    return {
      exists: store.has(path),
      id: path.split('/').pop(),
      ref: docRef(path),
      data: () => store.get(path),
    };
  }
  function docRef(path) {
    return {
      path,
      id: path.split('/').pop(),
      get: async () => snapshotOf(path),
      set: async (data, options) => {
        const prev = options?.merge ? store.get(path) || {} : {};
        store.set(path, { ...prev, ...data });
      },
      update: async (data) => {
        store.set(path, { ...(store.get(path) || {}), ...data });
      },
      collection: (name) => collectionRef(`${path}/${name}`),
    };
  }
  function collectionRef(prefix) {
    return { doc: (id) => docRef(`${prefix}/${id ?? 'auto'}`) };
  }

  return {
    store,
    collection: (name) => collectionRef(name),
    runTransaction: async (fn) => {
      const run = chain.then(() =>
        fn({
          get: (ref) => ref.get(),
          set: (ref, data, options) => {
            const prev = options?.merge ? store.get(ref.path) || {} : {};
            store.set(ref.path, { ...prev, ...data });
          },
          update: (ref, data) => {
            store.set(ref.path, { ...(store.get(ref.path) || {}), ...data });
          },
        }),
      );
      chain = run.then(
        () => undefined,
        () => undefined,
      );
      return run;
    },
  };
}

/**
 * 최소 fake Storage bucket.
 * - files: path → { size, contentType }
 * - deleted: 실제로 삭제 요청된 경로 목록
 */
function createFakeBucket(files = {}) {
  const store = new Map(Object.entries(files));
  const deleted = [];
  return {
    store,
    deleted,
    file: (path) => ({
      getMetadata: async () => {
        if (!store.has(path)) {
          const error = new Error('not found');
          error.code = 404;
          throw error;
        }
        return [store.get(path)];
      },
      delete: async () => {
        if (!store.has(path)) {
          const error = new Error('not found');
          error.code = 404;
          throw error;
        }
        store.delete(path);
        deleted.push(path);
      },
    }),
  };
}

function baseDocs(overrides = {}) {
  return {
    [`publicProfiles/${ME}`]: {
      displayName: '나',
      photoUrls: ['https://example.test/me.jpg'],
      verifications: { photo: true, work: false, school: true },
      birthDate: '1999-01-01',
    },
    ...overrides,
  };
}

function imagePath(index, { uid = ME, postId = POST_ID, ext = 'jpg' } = {}) {
  return `${feedImagePathPrefix(uid, postId)}image${index}.${ext}`;
}

function okImage(size = 1024) {
  return { size: String(size), contentType: 'image/jpeg' };
}

function ctx(db, bucket, { uid = ME, data = {}, now = 1_000_000, logger = null } = {}) {
  return {
    request: { auth: { uid }, data },
    db,
    bucket,
    HttpsError: FakeHttpsError,
    serverTimestamp: () => fakeTimestamp(now),
    nowMs: () => now,
    logger,
  };
}

async function expectError(promise, code) {
  await assert.rejects(promise, (error) => {
    assert.ok(error instanceof FakeHttpsError, `HttpsError 기대: ${error}`);
    assert.equal(error.code, code);
    return true;
  });
}

// ── 1, 11~13. 정상 작성 ───────────────────────────────────────────────────

test('1, 11~13. Feed 작성은 canonical snapshot과 imagePaths를 저장하고 imageUrls는 비운다', async () => {
  const db = createFakeDb({ docs: baseDocs() });
  const paths = [imagePath(1), imagePath(2)];
  const bucket = createFakeBucket({ [paths[0]]: okImage(), [paths[1]]: okImage() });

  const result = await createFeedPostCore(
    ctx(db, bucket, {
      data: { postId: POST_ID, text: '  오늘의 산책  ', imagePaths: paths },
    }),
  );

  assert.deepEqual(Object.keys(result), ['postId']);
  assert.equal(result.postId, POST_ID);

  const stored = db.store.get(`communityPosts/${POST_ID}`);
  assert.equal(stored.surface, 'feed');
  assert.equal(stored.authorUid, ME);
  assert.equal(stored.text, '오늘의 산책');
  assert.deepEqual(stored.imageUrls, []);
  assert.deepEqual(stored.imagePaths, paths);
  assert.equal(stored.status, 'active');
  assert.equal(stored.visibility, 'authenticated');
  assert.equal(stored.reactionCount, 0);
  assert.equal(stored.commentCount, 0);
  assert.equal(stored.schemaVersion, 1);
  // author snapshot은 공개 6개 필드만 담는다.
  assert.deepEqual(Object.keys(stored.authorSnapshot).sort(), [
    'displayName',
    'photoUrl',
    'photoVerified',
    'schoolVerified',
    'uid',
    'workVerified',
  ]);
  assert.equal(stored.authorSnapshot.birthDate, undefined);
});

// ── 2~10. 입력·경로·metadata 검증 ─────────────────────────────────────────

test('2. postId 형식이 어긋나면 거부한다', async () => {
  const db = createFakeDb({ docs: baseDocs() });
  const bucket = createFakeBucket();
  for (const badId of ['', 'short', 'a'.repeat(21), 'has/slash/xxxxxxxxxx', '한글아이디입니다한글아이디입니다한글아이']) {
    await expectError(
      createFeedPostCore(
        ctx(db, bucket, {
          data: { postId: badId, text: '본문', imagePaths: [imagePath(1)] },
        }),
      ),
      'invalid-argument',
    );
  }
});

test('3~4. 이미지 0개와 5개는 거부한다', async () => {
  const db = createFakeDb({ docs: baseDocs() });
  const bucket = createFakeBucket();
  await expectError(
    createFeedPostCore(
      ctx(db, bucket, { data: { postId: POST_ID, text: '본문', imagePaths: [] } }),
    ),
    'invalid-argument',
  );
  await expectError(
    createFeedPostCore(
      ctx(db, bucket, {
        data: {
          postId: POST_ID,
          text: '본문',
          imagePaths: [1, 2, 3, 4, 5].map((i) => imagePath(i)),
        },
      }),
    ),
    'invalid-argument',
  );
  // 이미지 필드 자체가 없거나 배열이 아니어도 거부한다.
  await expectError(
    createFeedPostCore(
      ctx(db, bucket, {
        data: { postId: POST_ID, text: '본문', imagePaths: 'communityFeed/x' },
      }),
    ),
    'invalid-argument',
  );
});

test('5~6. 다른 사용자·다른 게시물 경로는 거부한다', async () => {
  const db = createFakeDb({ docs: baseDocs() });
  const otherPath = imagePath(1, { uid: OTHER });
  const otherPostPath = imagePath(1, { postId: 'zzzzzzzzzz9876543210' });
  const bucket = createFakeBucket({
    [otherPath]: okImage(),
    [otherPostPath]: okImage(),
  });

  await expectError(
    createFeedPostCore(
      ctx(db, bucket, {
        data: { postId: POST_ID, text: '본문', imagePaths: [otherPath] },
      }),
    ),
    'invalid-argument',
  );
  await expectError(
    createFeedPostCore(
      ctx(db, bucket, {
        data: { postId: POST_ID, text: '본문', imagePaths: [otherPostPath] },
      }),
    ),
    'invalid-argument',
  );
  // 남의 파일은 검증 실패로 끝나고 삭제되지 않는다.
  assert.equal(bucket.deleted.length, 0);
  assert.ok(bucket.store.has(otherPath));
});

test('중복 경로와 허용되지 않은 확장자는 거부한다', async () => {
  const db = createFakeDb({ docs: baseDocs() });
  const dup = imagePath(1);
  const heic = imagePath(2, { ext: 'heic' });
  const bucket = createFakeBucket({ [dup]: okImage(), [heic]: okImage() });

  await expectError(
    createFeedPostCore(
      ctx(db, bucket, {
        data: { postId: POST_ID, text: '본문', imagePaths: [dup, dup] },
      }),
    ),
    'invalid-argument',
  );
  await expectError(
    createFeedPostCore(
      ctx(db, bucket, {
        data: { postId: POST_ID, text: '본문', imagePaths: [heic] },
      }),
    ),
    'invalid-argument',
  );
});

test('7~10. object 없음·초과 용량·MIME 오류·총합 초과는 거부하고 draft를 정리한다', async () => {
  const db = createFakeDb({ docs: baseDocs() });

  // 7. object 없음
  await expectError(
    createFeedPostCore(
      ctx(db, createFakeBucket(), {
        data: { postId: POST_ID, text: '본문', imagePaths: [imagePath(1)] },
      }),
    ),
    'invalid-argument',
  );

  // 8. 5MB 초과
  const bigPath = imagePath(1);
  const bigBucket = createFakeBucket({
    [bigPath]: { size: String(FEED_MAX_IMAGE_BYTES + 1), contentType: 'image/jpeg' },
  });
  await expectError(
    createFeedPostCore(
      ctx(db, bigBucket, {
        data: { postId: POST_ID, text: '본문', imagePaths: [bigPath] },
      }),
    ),
    'invalid-argument',
  );
  assert.deepEqual(bigBucket.deleted, [bigPath]);

  // 9. MIME 오류
  const gifPath = imagePath(1);
  const gifBucket = createFakeBucket({
    [gifPath]: { size: '1000', contentType: 'image/gif' },
  });
  await expectError(
    createFeedPostCore(
      ctx(db, gifBucket, {
        data: { postId: POST_ID, text: '본문', imagePaths: [gifPath] },
      }),
    ),
    'invalid-argument',
  );
  assert.deepEqual(gifBucket.deleted, [gifPath]);

  // 10. 총합 20MB 초과(각각은 5MB 이하)
  const totalPaths = [1, 2, 3, 4].map((i) => imagePath(i));
  const totalFiles = {};
  for (const path of totalPaths) {
    totalFiles[path] = { size: String(FEED_MAX_IMAGE_BYTES + 0), contentType: 'image/png' };
  }
  // 5MB * 4 = 20MB(경계). 1 byte만 더해 초과시킨다.
  totalFiles[totalPaths[0]] = {
    size: String(FEED_MAX_IMAGE_BYTES),
    contentType: 'image/png',
  };
  const totalBucket = createFakeBucket({
    ...totalFiles,
    [totalPaths[3]]: { size: String(FEED_MAX_IMAGE_BYTES), contentType: 'image/png' },
  });
  totalBucket.store.set(totalPaths[1], {
    size: String(FEED_MAX_IMAGE_BYTES),
    contentType: 'image/png',
  });
  totalBucket.store.set(totalPaths[2], {
    size: String(FEED_MAX_IMAGE_BYTES + 1),
    contentType: 'image/png',
  });
  await expectError(
    createFeedPostCore(
      ctx(db, totalBucket, {
        data: { postId: POST_ID, text: '본문', imagePaths: totalPaths },
      }),
    ),
    'invalid-argument',
  );
});

// ── 14~15. 텍스트·rate limit ──────────────────────────────────────────────

test('14. 금지 텍스트는 거부하고 업로드된 draft를 정리한다', async () => {
  const db = createFakeDb({ docs: baseDocs() });
  const path = imagePath(1);
  const bucket = createFakeBucket({ [path]: okImage() });

  await expectError(
    createFeedPostCore(
      ctx(db, bucket, {
        data: {
          postId: POST_ID,
          text: '연락처 010-1234-5678로 주세요',
          imagePaths: [path],
        },
      }),
    ),
    'invalid-argument',
  );
  assert.equal(db.store.has(`communityPosts/${POST_ID}`), false);
  // 글이 되지 못한 업로드 파일은 남기지 않는다.
  assert.deepEqual(bucket.deleted, [path]);
  assert.equal(bucket.store.has(path), false);
});

test('15. rate limit 안에서는 거부하고 draft를 정리한다', async () => {
  const db = createFakeDb({
    docs: baseDocs({
      [`communityWriteLimits/${ME}`]: { lastPostAt: fakeTimestamp(999_000) },
    }),
  });
  const path = imagePath(1);
  const bucket = createFakeBucket({ [path]: okImage() });

  await expectError(
    createFeedPostCore(
      ctx(db, bucket, {
        data: { postId: POST_ID, text: '본문', imagePaths: [path] },
      }),
    ),
    'resource-exhausted',
  );
  // 18. 실패한 요청의 업로드 파일은 남기지 않는다.
  assert.deepEqual(bucket.deleted, [path]);
  assert.equal(bucket.store.has(path), false);
});

// ── 16~17. 멱등성·충돌 ────────────────────────────────────────────────────

test('16. 같은 postId 재호출은 멱등 성공하고 이미지를 지우지 않는다', async () => {
  const db = createFakeDb({ docs: baseDocs() });
  const path = imagePath(1);
  const bucket = createFakeBucket({ [path]: okImage() });
  const data = { postId: POST_ID, text: '본문', imagePaths: [path] };

  const first = await createFeedPostCore(ctx(db, bucket, { data }));
  // rate limit을 피하려고 시간을 충분히 뒤로 옮긴다.
  const second = await createFeedPostCore(
    ctx(db, bucket, { data, now: 2_000_000 }),
  );

  assert.equal(first.postId, second.postId);
  assert.equal(bucket.deleted.length, 0);
  assert.ok(bucket.store.has(path));
  assert.equal(db.store.get(`communityPosts/${POST_ID}`).text, '본문');
});

test('17. 다른 사용자의 기존 postId면 거부한다', async () => {
  const db = createFakeDb({
    docs: baseDocs({
      [`communityPosts/${POST_ID}`]: {
        surface: 'feed',
        authorUid: OTHER,
        status: 'active',
      },
    }),
  });
  const path = imagePath(1);
  const bucket = createFakeBucket({ [path]: okImage() });

  await expectError(
    createFeedPostCore(
      ctx(db, bucket, {
        data: { postId: POST_ID, text: '본문', imagePaths: [path] },
      }),
    ),
    'already-exists',
  );
  // 우리가 올린 draft는 정리한다(남의 글에 붙지 않는다).
  assert.deepEqual(bucket.deleted, [path]);
});

// ── 19. 응답·로그 개인정보 ────────────────────────────────────────────────

test('19. 응답·로그에 경로·본문·uid가 남지 않는다', async () => {
  const db = createFakeDb({ docs: baseDocs() });
  const path = imagePath(1);
  const bucket = createFakeBucket({ [path]: okImage() });
  const entries = [];
  const logger = { log: (entry) => entries.push(entry) };

  const result = await createFeedPostCore(
    ctx(db, bucket, {
      data: { postId: POST_ID, text: '비밀 본문', imagePaths: [path] },
      logger,
    }),
  );

  assert.deepEqual(Object.keys(result), ['postId']);
  const serialized = JSON.stringify(entries);
  assert.ok(!serialized.includes(ME));
  assert.ok(!serialized.includes('비밀 본문'));
  assert.ok(!serialized.includes('communityFeed/'));
  assert.ok(serialized.includes('callerHash'));
  assert.ok(serialized.includes('imageCount'));
});

// ── 23~25. 삭제 수명주기 ──────────────────────────────────────────────────

test('23~24. Feed soft delete는 상태를 바꾸고 실제 이미지도 지운다', async () => {
  const paths = [imagePath(1), imagePath(2)];
  const db = createFakeDb({
    docs: {
      [`communityPosts/${POST_ID}`]: {
        surface: 'feed',
        authorUid: ME,
        status: 'active',
        visibility: 'authenticated',
        imagePaths: paths,
      },
    },
  });
  const bucket = createFakeBucket({ [paths[0]]: okImage(), [paths[1]]: okImage() });

  const result = await deleteCommunityPostCore(
    ctx(db, bucket, { data: { postId: POST_ID } }),
  );

  assert.deepEqual(result, { deleted: true });
  assert.equal(db.store.get(`communityPosts/${POST_ID}`).status, 'removed');
  assert.deepEqual(bucket.deleted.sort(), [...paths].sort());
});

test('25. 파일이 이미 없어도 삭제는 성공하고 재호출도 안전하다', async () => {
  const paths = [imagePath(1)];
  const db = createFakeDb({
    docs: {
      [`communityPosts/${POST_ID}`]: {
        surface: 'feed',
        authorUid: ME,
        status: 'active',
        visibility: 'authenticated',
        imagePaths: paths,
      },
    },
  });
  // 파일이 없는 상태에서 시작한다.
  const bucket = createFakeBucket();

  const first = await deleteCommunityPostCore(
    ctx(db, bucket, { data: { postId: POST_ID } }),
  );
  const second = await deleteCommunityPostCore(
    ctx(db, bucket, { data: { postId: POST_ID } }),
  );

  assert.deepEqual(first, { deleted: true });
  assert.deepEqual(second, { deleted: true });
  assert.equal(db.store.get(`communityPosts/${POST_ID}`).status, 'removed');
});

test('타인의 Feed 게시물은 삭제할 수 없고 파일도 건드리지 않는다', async () => {
  const path = imagePath(1, { uid: OTHER });
  const db = createFakeDb({
    docs: {
      [`communityPosts/${POST_ID}`]: {
        surface: 'feed',
        authorUid: OTHER,
        status: 'active',
        visibility: 'authenticated',
        imagePaths: [path],
      },
    },
  });
  const bucket = createFakeBucket({ [path]: okImage() });

  await expectError(
    deleteCommunityPostCore(ctx(db, bucket, { data: { postId: POST_ID } })),
    'permission-denied',
  );
  assert.equal(bucket.deleted.length, 0);
  assert.ok(bucket.store.has(path));
});

test('Lounge 게시물 삭제는 Storage를 건드리지 않는다(회귀)', async () => {
  const db = createFakeDb({
    docs: {
      [`communityPosts/${POST_ID}`]: {
        surface: 'lounge',
        authorUid: ME,
        status: 'active',
        visibility: 'authenticated',
        imageUrls: [],
      },
    },
  });
  const bucket = createFakeBucket();

  const result = await deleteCommunityPostCore(
    ctx(db, bucket, { data: { postId: POST_ID } }),
  );
  assert.deepEqual(result, { deleted: true });
  assert.equal(db.store.get(`communityPosts/${POST_ID}`).status, 'removed');
  assert.equal(bucket.deleted.length, 0);
});

test('인증되지 않은 Feed 작성 요청은 거부한다', async () => {
  const db = createFakeDb({ docs: baseDocs() });
  await expectError(
    createFeedPostCore({
      request: { data: { postId: POST_ID, text: '본문', imagePaths: [imagePath(1)] } },
      db,
      bucket: createFakeBucket(),
      HttpsError: FakeHttpsError,
      serverTimestamp: () => fakeTimestamp(1),
    }),
    'unauthenticated',
  );
});
