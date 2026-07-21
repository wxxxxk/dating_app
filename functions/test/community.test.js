'use strict';

// Phase 4-2 — 라운지 커뮤니티 서버 core 테스트.
//
// Firestore를 fake로 주입해 입력 검증, 작성자 snapshot 계약, 공개 글 금지
// 내용 차단, rate limit, 카운트 정합성, soft delete 멱등성, 신고 중복 방지,
// 회원 탈퇴 수명주기, 응답·로그의 개인정보 미노출을 확인한다.

const assert = require('node:assert/strict');
const { test } = require('node:test');

const {
  COMMENT_COOLDOWN_MS,
  FORBIDDEN_TEXT_ERROR_CODE,
  POST_COOLDOWN_MS,
  buildCommunityAuthorSnapshot,
  cleanupCommunityContentForUser,
  createCommunityCommentCore,
  createLoungePostCore,
  deleteCommunityCommentCore,
  deleteCommunityPostCore,
  detectForbiddenCommunityText,
  reportCommunityContentCore,
  toggleCommunityReactionCore,
} = require('../lib/community');

const ME = 'me-uid';
const OTHER = 'other-uid';

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

/**
 * 최소 fake Firestore.
 * - 경로 → data 맵
 * - collection/doc/subcollection/collectionGroup/where/runTransaction 지원
 * - runTransaction은 mutex로 직렬화해 실제 트랜잭션 격리를 흉내 낸다.
 */
function createFakeDb({ docs = {}, nowMs = () => 1_000_000 } = {}) {
  const store = new Map(Object.entries(docs));
  let autoId = 0;
  let chain = Promise.resolve();

  function snapshotOf(path) {
    return {
      exists: store.has(path),
      id: path.split('/').pop(),
      ref: docRef(path),
      data: () => store.get(path),
    };
  }

  function collectionRef(prefix) {
    const parentPath = prefix.includes('/')
      ? prefix.slice(0, prefix.lastIndexOf('/'))
      : null;
    return {
      id: prefix.split('/').pop(),
      parent: parentPath ? docRef(parentPath) : null,
      doc: (id) => docRef(`${prefix}/${id ?? `auto-${++autoId}`}`),
      where: (field, op, value) => queryOn(
        (path) =>
          path.startsWith(`${prefix}/`) &&
          !path.slice(prefix.length + 1).includes('/'),
        field,
        op,
        value,
      ),
    };
  }

  function queryOn(pathMatches, field, op, value) {
    return {
      get: async () => {
        const docsOut = [];
        for (const [path, data] of store.entries()) {
          if (!pathMatches(path)) continue;
          const actual = data?.[field];
          const hit = op === '==' ? actual === value : false;
          if (hit) docsOut.push(snapshotOf(path));
        }
        return { docs: docsOut, empty: docsOut.length === 0 };
      },
    };
  }

  function docRef(path) {
    const segments = path.split('/');
    const parentCollectionPath = segments.slice(0, -1).join('/');
    return {
      path,
      id: segments[segments.length - 1],
      get parent() {
        return collectionRef(parentCollectionPath);
      },
      get: async () => snapshotOf(path),
      set: async (data, options) => {
        const prev = options?.merge ? store.get(path) || {} : {};
        store.set(path, { ...prev, ...data });
      },
      update: async (data) => {
        store.set(path, { ...(store.get(path) || {}), ...data });
      },
      delete: async () => {
        store.delete(path);
      },
      collection: (name) => collectionRef(`${path}/${name}`),
    };
  }

  const db = {
    store,
    collection: (name) => collectionRef(name),
    collectionGroup: (name) => ({
      where: (field, op, value) =>
        queryOn((path) => {
          const parts = path.split('/');
          return parts.length >= 2 && parts[parts.length - 2] === name;
        }, field, op, value),
    }),
    runTransaction: async (fn) => {
      // Firestore의 직렬화 격리를 흉내 낸다(동시 toggle 정합성 검증용).
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
          delete: (ref) => {
            store.delete(ref.path);
          },
        }),
      );
      chain = run.then(
        () => undefined,
        () => undefined,
      );
      return run;
    },
    nowMs,
  };
  return db;
}

function baseDocs(overrides = {}) {
  return {
    [`publicProfiles/${ME}`]: {
      displayName: '나',
      photoUrls: ['https://example.test/me.jpg'],
      verifications: { photo: true, work: false, school: true, email: true },
      birthDate: '1999-01-01',
      gender: 'male',
    },
    [`publicProfiles/${OTHER}`]: {
      displayName: '상대',
      photoUrls: [],
      verifications: { photo: false, work: true, school: false },
    },
    ...overrides,
  };
}

function activePost(authorUid = OTHER, overrides = {}) {
  return {
    surface: 'lounge',
    authorUid,
    authorSnapshot: {
      uid: authorUid,
      displayName: '상대',
      photoUrl: '',
      photoVerified: false,
      workVerified: true,
      schoolVerified: false,
    },
    text: '안녕하세요',
    imageUrls: [],
    status: 'active',
    visibility: 'authenticated',
    reactionCount: 0,
    commentCount: 0,
    createdAt: fakeTimestamp(1000),
    updatedAt: fakeTimestamp(1000),
    schemaVersion: 1,
    ...overrides,
  };
}

function ctx(db, { uid = ME, data = {}, now = 1_000_000, logger = null } = {}) {
  return {
    request: { auth: { uid }, data },
    db,
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

// ── 1~2. 작성자 snapshot ──────────────────────────────────────────────────

test('1~2. author snapshot은 publicProfiles 공개 6개 필드만 담는다', () => {
  const snapshot = buildCommunityAuthorSnapshot({
    uid: ME,
    publicProfileData: {
      displayName: '  나  ',
      photoUrls: ['', 'https://example.test/me.jpg'],
      verifications: { photo: true, work: false, school: true, email: true, phone: true },
      birthDate: '1999-01-01',
      gender: 'male',
      location: { lat: 1, lng: 2 },
      jelly: 100,
    },
  });

  assert.deepEqual(Object.keys(snapshot).sort(), [
    'displayName',
    'photoUrl',
    'photoVerified',
    'schoolVerified',
    'uid',
    'workVerified',
  ]);
  assert.equal(snapshot.displayName, '나');
  assert.equal(snapshot.photoUrl, 'https://example.test/me.jpg');
  assert.equal(snapshot.photoVerified, true);
  assert.equal(snapshot.workVerified, false);
  assert.equal(snapshot.schoolVerified, true);

  // 표시 이름이 없으면 스냅샷을 만들지 않는다.
  assert.equal(
    buildCommunityAuthorSnapshot({ uid: ME, publicProfileData: { displayName: '  ' } }),
    null,
  );
});

// ── 3~11. 게시물 작성 ─────────────────────────────────────────────────────

test('3~4. 게시물 작성은 서버가 author/status/count/timestamp를 채운다', async () => {
  const db = createFakeDb({ docs: baseDocs() });
  const result = await createLoungePostCore(
    ctx(db, { data: { text: '  라운지 첫 글  ' } }),
  );

  assert.ok(typeof result.postId === 'string' && result.postId.length > 0);
  assert.deepEqual(Object.keys(result), ['postId']);

  const stored = db.store.get(`communityPosts/${result.postId}`);
  assert.equal(stored.text, '라운지 첫 글');
  assert.equal(stored.surface, 'lounge');
  assert.equal(stored.authorUid, ME);
  assert.equal(stored.status, 'active');
  assert.equal(stored.visibility, 'authenticated');
  assert.deepEqual(stored.imageUrls, []);
  assert.equal(stored.reactionCount, 0);
  assert.equal(stored.commentCount, 0);
  assert.equal(stored.schemaVersion, 1);
  assert.equal(stored.authorSnapshot.displayName, '나');
  assert.equal(stored.authorSnapshot.birthDate, undefined);
});

test('5~6. 빈 글과 1000자 초과는 거부한다', async () => {
  const db = createFakeDb({ docs: baseDocs() });
  await expectError(
    createLoungePostCore(ctx(db, { data: { text: '   ' } })),
    'invalid-argument',
  );
  await expectError(
    createLoungePostCore(ctx(db, { data: { text: 'a'.repeat(1001) } })),
    'invalid-argument',
  );
  // 알 수 없는 필드도 거부한다.
  await expectError(
    createLoungePostCore(ctx(db, { data: { text: '정상', status: 'active' } })),
    'invalid-argument',
  );
});

test('7~9. 전화번호·인증번호·송금 요청은 서버가 차단한다', async () => {
  const db = createFakeDb({ docs: baseDocs() });
  const blocked = [
    '연락처는 010-1234-5678 이에요',
    '01012345678 로 연락주세요',
    '+82 10 1234 5678',
    '인증번호 알려주시면 처리해드려요',
    '보안코드 좀 알려줘',
    '계좌번호 알려주세요',
    '입금해주시면 보내드릴게요',
    '돈 좀 보내줘',
  ];
  for (const text of blocked) {
    assert.ok(
      detectForbiddenCommunityText(text).length > 0,
      `차단 대상이어야 함: ${text}`,
    );
    await expectError(
      createLoungePostCore(ctx(db, { data: { text } })),
      'invalid-argument',
    );
  }

  // 거부 응답에는 고정 code만 담고 원문·탐지 문자열은 넣지 않는다.
  await assert.rejects(
    createLoungePostCore(ctx(db, { data: { text: '010-1234-5678' } })),
    (error) => {
      assert.deepEqual(error.details, { code: FORBIDDEN_TEXT_ERROR_CODE });
      assert.ok(!error.message.includes('010'));
      return true;
    },
  );
});

test('10. 날짜·시간·가격·일상 표현은 오탐하지 않는다', () => {
  const allowed = [
    '2026-07-21 저녁 7시에 만나요',
    '가격은 10,000원이었어요',
    '주문번호 20260721001 확인했어요',
    '돈까스 맛집 아시는 분',
    '요즘 돈이 아깝다는 생각이 들어요',
    'laptop 추천해주세요',
    '1234 네 자리 숫자',
  ];
  for (const text of allowed) {
    assert.deepEqual(
      detectForbiddenCommunityText(text),
      [],
      `오탐 발생: ${text}`,
    );
  }
});

test('11. 게시물 rate limit — 최소 간격 안에는 거부한다', async () => {
  const db = createFakeDb({ docs: baseDocs() });
  await createLoungePostCore(ctx(db, { data: { text: '첫 글' }, now: 1_000_000 }));

  await expectError(
    createLoungePostCore(ctx(db, { data: { text: '연속 글' }, now: 1_000_500 })),
    'resource-exhausted',
  );

  const later = 1_000_000 + POST_COOLDOWN_MS + 1;
  const ok = await createLoungePostCore(
    ctx(db, { data: { text: '충분히 기다린 글' }, now: later }),
  );
  assert.ok(ok.postId);
});

test('프로필이 없으면 작성할 수 없다', async () => {
  const db = createFakeDb({ docs: {} });
  await expectError(
    createLoungePostCore(ctx(db, { data: { text: '글' } })),
    'failed-precondition',
  );
});

// ── 12~15. 댓글 ──────────────────────────────────────────────────────────

test('12, 14. 댓글 작성은 성공하고 commentCount를 1 늘린다', async () => {
  const db = createFakeDb({
    docs: baseDocs({ 'communityPosts/p1': activePost() }),
  });
  const result = await createCommunityCommentCore(
    ctx(db, { data: { postId: 'p1', text: '  반가워요  ' } }),
  );

  assert.deepEqual(Object.keys(result), ['commentId']);
  const comment = db.store.get(
    `communityPosts/p1/comments/${result.commentId}`,
  );
  assert.equal(comment.text, '반가워요');
  assert.equal(comment.postId, 'p1');
  assert.equal(comment.authorUid, ME);
  assert.equal(comment.status, 'active');
  assert.equal(comment.schemaVersion, 1);

  const post = db.store.get('communityPosts/p1');
  assert.equal(post.commentCount, 1);
  // 댓글 때문에 게시물 updatedAt은 바뀌지 않는다.
  assert.equal(post.updatedAt.toMillis(), 1000);
});

test('13. 비활성/없는 부모 게시물에는 댓글을 달 수 없다', async () => {
  const db = createFakeDb({
    docs: baseDocs({
      'communityPosts/removed': activePost(OTHER, { status: 'removed' }),
      'communityPosts/removedFeed': activePost(OTHER, {
        surface: 'feed',
        status: 'removed',
      }),
    }),
  });
  await expectError(
    createCommunityCommentCore(ctx(db, { data: { postId: 'removed', text: '댓글' } })),
    'not-found',
  );
  await expectError(
    createCommunityCommentCore(
      ctx(db, { data: { postId: 'removedFeed', text: '댓글' } }),
    ),
    'not-found',
  );
  await expectError(
    createCommunityCommentCore(ctx(db, { data: { postId: 'nope', text: '댓글' } })),
    'not-found',
  );
});

// Phase 4-3: 댓글·공감·신고·삭제는 active feed 게시물에서도 동작해야 한다
// (Lounge 전용 계약을 두 표면 공통으로 일반화했다).
test('Phase 4-3. active feed 게시물에도 댓글·공감을 달 수 있다', async () => {
  const db = createFakeDb({
    docs: baseDocs({ 'communityPosts/feed1': activePost(OTHER, { surface: 'feed' }) }),
  });

  const comment = await createCommunityCommentCore(
    ctx(db, { data: { postId: 'feed1', text: '사진 좋네요' } }),
  );
  assert.ok(comment.commentId);
  assert.equal(db.store.get('communityPosts/feed1').commentCount, 1);

  const reaction = await toggleCommunityReactionCore(
    ctx(db, { data: { postId: 'feed1' } }),
  );
  assert.equal(reaction.reacted, true);
  assert.equal(reaction.reactionCount, 1);
});

test('15. 댓글 rate limit', async () => {
  const db = createFakeDb({
    docs: baseDocs({ 'communityPosts/p1': activePost() }),
  });
  await createCommunityCommentCore(
    ctx(db, { data: { postId: 'p1', text: '첫 댓글' }, now: 2_000_000 }),
  );
  await expectError(
    createCommunityCommentCore(
      ctx(db, { data: { postId: 'p1', text: '연속 댓글' }, now: 2_000_500 }),
    ),
    'resource-exhausted',
  );
  const ok = await createCommunityCommentCore(
    ctx(db, {
      data: { postId: 'p1', text: '기다린 댓글' },
      now: 2_000_000 + COMMENT_COOLDOWN_MS + 1,
    }),
  );
  assert.ok(ok.commentId);
  assert.equal(db.store.get('communityPosts/p1').commentCount, 2);
});

test('댓글은 500자를 넘을 수 없다', async () => {
  const db = createFakeDb({
    docs: baseDocs({ 'communityPosts/p1': activePost() }),
  });
  await expectError(
    createCommunityCommentCore(
      ctx(db, { data: { postId: 'p1', text: 'a'.repeat(501) } }),
    ),
    'invalid-argument',
  );
});

// ── 16~18. 공감 ──────────────────────────────────────────────────────────

test('16~17. 공감 추가와 취소', async () => {
  const db = createFakeDb({
    docs: baseDocs({ 'communityPosts/p1': activePost() }),
  });

  const added = await toggleCommunityReactionCore(
    ctx(db, { data: { postId: 'p1' } }),
  );
  assert.deepEqual(added, { reacted: true, reactionCount: 1 });
  assert.deepEqual(
    Object.keys(db.store.get(`communityPosts/p1/reactions/${ME}`)).sort(),
    ['createdAt', 'schemaVersion', 'type', 'uid'],
  );

  const removed = await toggleCommunityReactionCore(
    ctx(db, { data: { postId: 'p1' } }),
  );
  assert.deepEqual(removed, { reacted: false, reactionCount: 0 });
  assert.equal(db.store.has(`communityPosts/p1/reactions/${ME}`), false);
  assert.equal(db.store.get('communityPosts/p1').reactionCount, 0);
});

test('18. 동시 toggle에도 카운트가 틀어지지 않는다', async () => {
  const db = createFakeDb({
    docs: baseDocs({ 'communityPosts/p1': activePost() }),
  });

  await Promise.all([
    toggleCommunityReactionCore(ctx(db, { data: { postId: 'p1' } })),
    toggleCommunityReactionCore(ctx(db, { data: { postId: 'p1' } })),
  ]);
  // 같은 사용자가 두 번 눌렀으므로 추가 → 취소로 0이어야 한다.
  assert.equal(db.store.get('communityPosts/p1').reactionCount, 0);
  assert.equal(db.store.has(`communityPosts/p1/reactions/${ME}`), false);

  // 서로 다른 사용자 두 명이면 2가 된다.
  await toggleCommunityReactionCore(ctx(db, { data: { postId: 'p1' } }));
  await toggleCommunityReactionCore(
    ctx(db, { uid: OTHER, data: { postId: 'p1' } }),
  );
  assert.equal(db.store.get('communityPosts/p1').reactionCount, 2);
});

test('비활성 게시물에는 공감할 수 없다', async () => {
  const db = createFakeDb({
    docs: baseDocs({
      'communityPosts/p1': activePost(OTHER, { status: 'removed' }),
    }),
  });
  await expectError(
    toggleCommunityReactionCore(ctx(db, { data: { postId: 'p1' } })),
    'not-found',
  );
});

// ── 19~22. 삭제 ──────────────────────────────────────────────────────────

test('19~20. 본인 게시물만 soft delete할 수 있다', async () => {
  const db = createFakeDb({
    docs: baseDocs({
      'communityPosts/mine': activePost(ME),
      'communityPosts/theirs': activePost(OTHER),
      'communityPosts/mine/comments/c1': { authorUid: OTHER, status: 'active' },
    }),
  });

  const result = await deleteCommunityPostCore(
    ctx(db, { data: { postId: 'mine' } }),
  );
  assert.deepEqual(result, { deleted: true });

  const stored = db.store.get('communityPosts/mine');
  assert.equal(stored.status, 'removed');
  assert.equal(stored.text, '안녕하세요'); // 원문은 운영 검토용으로 남는다
  assert.ok(db.store.has('communityPosts/mine/comments/c1'));

  // 이미 삭제된 글은 멱등 성공.
  assert.deepEqual(
    await deleteCommunityPostCore(ctx(db, { data: { postId: 'mine' } })),
    { deleted: true },
  );

  await expectError(
    deleteCommunityPostCore(ctx(db, { data: { postId: 'theirs' } })),
    'permission-denied',
  );
});

test('21~22. 댓글 삭제는 commentCount를 한 번만 줄인다', async () => {
  const db = createFakeDb({
    docs: baseDocs({
      'communityPosts/p1': activePost(OTHER, { commentCount: 1 }),
      'communityPosts/p1/comments/c1': {
        postId: 'p1',
        authorUid: ME,
        status: 'active',
        text: '내 댓글',
        schemaVersion: 1,
      },
      'communityPosts/p1/comments/c2': {
        postId: 'p1',
        authorUid: OTHER,
        status: 'active',
        text: '남의 댓글',
        schemaVersion: 1,
      },
    }),
  });

  await deleteCommunityCommentCore(
    ctx(db, { data: { postId: 'p1', commentId: 'c1' } }),
  );
  assert.equal(db.store.get('communityPosts/p1/comments/c1').status, 'removed');
  assert.equal(db.store.get('communityPosts/p1').commentCount, 0);

  // 재호출해도 카운트를 다시 줄이지 않는다.
  await deleteCommunityCommentCore(
    ctx(db, { data: { postId: 'p1', commentId: 'c1' } }),
  );
  assert.equal(db.store.get('communityPosts/p1').commentCount, 0);

  await expectError(
    deleteCommunityCommentCore(
      ctx(db, { data: { postId: 'p1', commentId: 'c2' } }),
    ),
    'permission-denied',
  );
});

// ── 23~27. 신고 ──────────────────────────────────────────────────────────

test('23, 26. 신고는 id 참조만 저장하고 응답에 uid·본문을 담지 않는다', async () => {
  const db = createFakeDb({
    docs: baseDocs({ 'communityPosts/p1': activePost(OTHER) }),
  });

  const result = await reportCommunityContentCore(
    ctx(db, {
      data: {
        targetType: 'post',
        postId: 'p1',
        commentId: '',
        reason: 'spam_scam',
        detail: '  광고 같아요  ',
      },
    }),
  );
  assert.deepEqual(result, { reported: true });

  const reports = [...db.store.entries()].filter(([path]) =>
    path.startsWith('communityReports/'),
  );
  assert.equal(reports.length, 1);
  const [, report] = reports[0];
  assert.equal(report.reporterUid, ME);
  assert.equal(report.reportedUid, OTHER);
  assert.equal(report.targetType, 'post');
  assert.equal(report.postId, 'p1');
  assert.equal(report.commentId, '');
  assert.equal(report.reason, 'spam_scam');
  assert.equal(report.detail, '광고 같아요');
  assert.equal(report.schemaVersion, 1);
  // 원문/작성자 snapshot은 저장하지 않는다.
  assert.equal(report.text, undefined);
  assert.equal(report.authorSnapshot, undefined);
  // 신고만으로 상태·카운트는 바뀌지 않는다.
  assert.equal(db.store.get('communityPosts/p1').status, 'active');
});

test('24. 자기 콘텐츠는 신고할 수 없다', async () => {
  const db = createFakeDb({
    docs: baseDocs({ 'communityPosts/p1': activePost(ME) }),
  });
  await expectError(
    reportCommunityContentCore(
      ctx(db, {
        data: { targetType: 'post', postId: 'p1', commentId: '', reason: 'other' },
      }),
    ),
    'failed-precondition',
  );
});

test('25. 같은 대상 중복 신고는 멱등 성공한다', async () => {
  const db = createFakeDb({
    docs: baseDocs({
      'communityPosts/p1': activePost(OTHER),
      'communityPosts/p1/comments/c1': {
        postId: 'p1',
        authorUid: OTHER,
        status: 'active',
        text: '댓글',
        schemaVersion: 1,
      },
    }),
  });

  const payload = {
    targetType: 'comment',
    postId: 'p1',
    commentId: 'c1',
    reason: 'abusive_language',
  };
  await reportCommunityContentCore(ctx(db, { data: payload, now: 3_000_000 }));
  // rate limit 안이라도 같은 대상 재신고는 성공 처리(중복 문서를 만들지 않는다).
  await reportCommunityContentCore(ctx(db, { data: payload, now: 3_000_100 }));

  const reports = [...db.store.keys()].filter((path) =>
    path.startsWith('communityReports/'),
  );
  assert.equal(reports.length, 1);
});

test('허용되지 않은 사유·targetType은 거부한다', async () => {
  const db = createFakeDb({
    docs: baseDocs({ 'communityPosts/p1': activePost(OTHER) }),
  });
  await expectError(
    reportCommunityContentCore(
      ctx(db, {
        data: { targetType: 'post', postId: 'p1', commentId: '', reason: 'made_up' },
      }),
    ),
    'invalid-argument',
  );
  await expectError(
    reportCommunityContentCore(
      ctx(db, {
        data: { targetType: 'user', postId: 'p1', commentId: '', reason: 'other' },
      }),
    ),
    'invalid-argument',
  );
});

// ── 27~28. 인증·로그 ─────────────────────────────────────────────────────

test('27. 로그에는 uid hash와 분류 code만 남고 원문·uid는 남지 않는다', async () => {
  const entries = [];
  const logger = { log: (payload) => entries.push(payload) };
  const db = createFakeDb({ docs: baseDocs() });

  await createLoungePostCore(
    ctx(db, { data: { text: '오늘 날씨 좋네요' }, logger }),
  );
  await expectError(
    createLoungePostCore(
      ctx(db, { data: { text: '010-1234-5678' }, logger, now: 9_000_000 }),
    ),
    'invalid-argument',
  );

  const serialized = JSON.stringify(entries);
  assert.ok(!serialized.includes(ME));
  assert.ok(!serialized.includes('010-1234-5678'));
  assert.ok(!serialized.includes('오늘 날씨'));
  assert.ok(serialized.includes('phone_number'));
});

test('28. 인증되지 않은 요청은 모두 거부한다', async () => {
  const db = createFakeDb({ docs: baseDocs() });
  const anon = {
    request: { data: { text: '글' } },
    db,
    HttpsError: FakeHttpsError,
    serverTimestamp: () => fakeTimestamp(1),
  };
  await expectError(createLoungePostCore(anon), 'unauthenticated');
  await expectError(
    toggleCommunityReactionCore({ ...anon, request: { data: { postId: 'p1' } } }),
    'unauthenticated',
  );
});

// ── 회원 탈퇴 수명주기 ────────────────────────────────────────────────────

const DELETED_ID = 'deleted:abcdef';

function deletionDocs() {
  return {
    'communityPosts/mine': activePost(ME, { commentCount: 1, reactionCount: 1 }),
    'communityPosts/theirs': activePost(OTHER, {
      commentCount: 1,
      reactionCount: 1,
    }),
    'communityPosts/theirs/comments/c1': {
      postId: 'theirs',
      authorUid: ME,
      authorSnapshot: { uid: ME, displayName: '나' },
      status: 'active',
      text: '내 댓글',
      schemaVersion: 1,
    },
    'communityPosts/theirs/comments/c2': {
      postId: 'theirs',
      authorUid: OTHER,
      status: 'active',
      text: '남의 댓글',
      schemaVersion: 1,
    },
    'communityPosts/theirs/reactions/me-uid': { uid: ME, type: 'like' },
    'communityReports/r1': {
      reporterUid: ME,
      reportedUid: OTHER,
      targetType: 'post',
      postId: 'theirs',
      commentId: '',
      reason: 'other',
    },
    'communityReports/r2': {
      reporterUid: OTHER,
      reportedUid: ME,
      targetType: 'post',
      postId: 'mine',
      commentId: '',
      reason: 'other',
    },
    [`communityWriteLimits/${ME}`]: { lastPostAt: fakeTimestamp(1) },
  };
}

test('탈퇴 정리 — 게시물/댓글 익명화, 반응 삭제, 카운트 보정, 신고 pseudonym', async () => {
  const db = createFakeDb({ docs: deletionDocs() });
  const counts = await cleanupCommunityContentForUser({
    db,
    uid: ME,
    deletedIdentifier: DELETED_ID,
    serverTimestamp: () => fakeTimestamp(5_000),
  });

  assert.equal(counts.communityPostsRemoved, 1);
  assert.equal(counts.communityCommentsRemoved, 1);
  assert.equal(counts.communityReactionsRemoved, 1);
  assert.equal(counts.communityReportsAnonymized, 1);

  const post = db.store.get('communityPosts/mine');
  assert.equal(post.status, 'removed');
  assert.equal(post.authorUid, DELETED_ID);
  assert.equal(post.authorSnapshot.displayName, '탈퇴한 사용자');
  assert.equal(post.authorSnapshot.uid, DELETED_ID);
  assert.equal(post.authorSnapshot.photoUrl, '');
  assert.equal(post.authorSnapshot.photoVerified, false);

  const comment = db.store.get('communityPosts/theirs/comments/c1');
  assert.equal(comment.status, 'removed');
  assert.equal(comment.authorUid, DELETED_ID);
  assert.equal(comment.authorSnapshot.displayName, '탈퇴한 사용자');

  // 다른 사용자 콘텐츠는 그대로.
  assert.equal(db.store.get('communityPosts/theirs').status, 'active');
  assert.equal(
    db.store.get('communityPosts/theirs/comments/c2').status,
    'active',
  );
  assert.equal(db.store.get('communityReports/r2').reporterUid, OTHER);

  // 카운트 보정과 반응 삭제.
  const theirs = db.store.get('communityPosts/theirs');
  assert.equal(theirs.commentCount, 0);
  assert.equal(theirs.reactionCount, 0);
  assert.equal(db.store.has('communityPosts/theirs/reactions/me-uid'), false);

  // 신고자만 pseudonym으로 바뀐다.
  assert.equal(db.store.get('communityReports/r1').reporterUid, DELETED_ID);
  assert.equal(db.store.get('communityReports/r1').reportedUid, OTHER);
  assert.equal(db.store.has(`communityWriteLimits/${ME}`), false);
});

test('탈퇴 정리는 재실행해도 안전하다(멱등)', async () => {
  const db = createFakeDb({ docs: deletionDocs() });
  const serverTimestamp = () => fakeTimestamp(5_000);
  await cleanupCommunityContentForUser({
    db,
    uid: ME,
    deletedIdentifier: DELETED_ID,
    serverTimestamp,
  });
  const second = await cleanupCommunityContentForUser({
    db,
    uid: ME,
    deletedIdentifier: DELETED_ID,
    serverTimestamp,
  });

  assert.equal(second.communityPostsRemoved, 0);
  assert.equal(second.communityCommentsRemoved, 0);
  assert.equal(second.communityReactionsRemoved, 0);
  assert.equal(second.communityReportsAnonymized, 0);
  assert.equal(db.store.get('communityPosts/theirs').commentCount, 0);
  assert.equal(db.store.get('communityPosts/theirs').reactionCount, 0);
});
