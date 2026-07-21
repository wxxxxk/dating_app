'use strict';

// Phase 4-4 — Party·Square 서버 core 테스트.
//
// Firestore를 fake로 주입해 입력 검증(시간·정원·allowlist), 공개 글 금지 내용
// 차단, canonical host/requester snapshot, 차단·지인 피하기 서버 재확인,
// 승인 transaction의 정원/관계 재검사, full↔open 전환, 멱등성, rate limit,
// 신고 중복 방지, 회원 탈퇴 수명주기, 응답·로그의 개인정보 미노출을 확인한다.

const assert = require('node:assert/strict');
const { test } = require('node:test');

const {
  CREATE_COOLDOWN_MS,
  JOIN_REQUEST_COOLDOWN_MS,
  REPORT_COOLDOWN_MS,
  REVIEW_COOLDOWN_MS,
  cancelCommunityPartyCore,
  cleanupPartyDataForUser,
  createCommunityPartyCore,
  leaveCommunityPartyCore,
  partyReportId,
  reportCommunityPartyCore,
  requestPartyJoinCore,
  reviewPartyJoinRequestCore,
  withdrawPartyJoinRequestCore,
} = require('../lib/community_party');

const { contactAvoidancePairId } = require('../lib/contact_avoidance');

const HOST = 'host-uid';
const GUEST = 'guest-uid';
const OTHER = 'other-uid';

const NOW = 1_700_000_000_000;
const START_AT = NOW + 24 * 60 * 60 * 1000; // 하루 뒤

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
 * 최소 fake Firestore(community.test.js와 같은 계약).
 * runTransaction은 mutex로 직렬화해 실제 트랜잭션 격리를 흉내 낸다.
 */
function createFakeDb({ docs = {} } = {}) {
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

  function directChildren(prefix) {
    const out = [];
    for (const path of store.keys()) {
      if (!path.startsWith(`${prefix}/`)) continue;
      if (path.slice(prefix.length + 1).includes('/')) continue;
      out.push(path);
    }
    return out;
  }

  function collectionRef(prefix) {
    const parentPath = prefix.includes('/')
      ? prefix.slice(0, prefix.lastIndexOf('/'))
      : null;
    return {
      id: prefix.split('/').pop(),
      parent: parentPath ? docRef(parentPath) : null,
      doc: (id) => docRef(`${prefix}/${id ?? `auto${String(++autoId).padStart(18, '0')}`}`),
      get: async () => {
        const docsOut = directChildren(prefix).map(snapshotOf);
        return { docs: docsOut, empty: docsOut.length === 0 };
      },
      where: (field, op, value) => ({
        get: async () => {
          const docsOut = [];
          for (const path of directChildren(prefix)) {
            const actual = store.get(path)?.[field];
            if (op === '==' ? actual === value : false) {
              docsOut.push(snapshotOf(path));
            }
          }
          return { docs: docsOut, empty: docsOut.length === 0 };
        },
      }),
    };
  }

  function docRef(path) {
    const segments = path.split('/');
    return {
      path,
      id: segments[segments.length - 1],
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
  };
}

function baseDocs(overrides = {}) {
  return {
    [`publicProfiles/${HOST}`]: {
      displayName: '호스트',
      photoUrls: ['https://example.test/host.jpg'],
      verifications: { photo: true, work: false, school: true, email: true },
      birthDate: '1999-01-01',
      gender: 'male',
    },
    [`publicProfiles/${GUEST}`]: {
      displayName: '게스트',
      photoUrls: [],
      verifications: { photo: false, work: true, school: false, phone: true },
    },
    [`publicProfiles/${OTHER}`]: {
      displayName: '제3자',
      photoUrls: [],
      verifications: {},
    },
    ...overrides,
  };
}

function activeParty(overrides = {}) {
  return {
    hostUid: HOST,
    hostSnapshot: {
      uid: HOST,
      displayName: '호스트',
      photoUrl: 'https://example.test/host.jpg',
      photoVerified: true,
      workVerified: false,
      schoolVerified: true,
    },
    title: '한강 산책 같이 해요',
    description: '가볍게 걷고 커피 마셔요.',
    category: 'walk',
    area: 'seoul',
    startAt: fakeTimestamp(START_AT),
    maxParticipants: 4,
    participantCount: 1,
    status: 'open',
    visibility: 'authenticated',
    createdAt: fakeTimestamp(NOW - 1000),
    updatedAt: fakeTimestamp(NOW - 1000),
    schemaVersion: 1,
    ...overrides,
  };
}

function hostMember(overrides = {}) {
  return {
    uid: HOST,
    role: 'host',
    status: 'active',
    joinedAt: fakeTimestamp(NOW - 1000),
    updatedAt: fakeTimestamp(NOW - 1000),
    schemaVersion: 1,
    ...overrides,
  };
}

function ctx(db, { uid = HOST, data = {}, now = NOW, logger = null } = {}) {
  return {
    request: { auth: { uid }, data },
    db,
    HttpsError: FakeHttpsError,
    serverTimestamp: () => fakeTimestamp(now),
    timestampFromMillis: (millis) => fakeTimestamp(millis),
    nowMs: () => now,
    logger,
  };
}

function validCreateInput(overrides = {}) {
  return {
    title: '한강 산책 같이 해요',
    description: '가볍게 걷고 커피 마셔요.',
    category: 'walk',
    area: 'seoul',
    startAtMillis: START_AT,
    maxParticipants: 4,
    ...overrides,
  };
}

async function expectError(promise, code) {
  await assert.rejects(promise, (error) => {
    assert.ok(error instanceof FakeHttpsError, `HttpsError 기대: ${error}`);
    assert.equal(error.code, code);
    return true;
  });
}

function partyPathOf(db) {
  for (const path of db.store.keys()) {
    if (path.startsWith('communityParties/') && path.split('/').length === 2) {
      return path;
    }
  }
  throw new Error('party 문서를 찾지 못했다');
}

// ── createCommunityParty ───────────────────────────────────────────────────

test('create: 파티·host member·mirror·rate limit을 한 번에 만든다', async () => {
  const db = createFakeDb({ docs: baseDocs() });
  const result = await createCommunityPartyCore(
    ctx(db, { uid: HOST, data: validCreateInput() }),
  );

  assert.equal(typeof result.partyId, 'string');
  // 응답에는 partyId만 담는다(UID·본문·snapshot 금지).
  assert.deepEqual(Object.keys(result), ['partyId']);

  const party = db.store.get(`communityParties/${result.partyId}`);
  assert.equal(party.hostUid, HOST);
  assert.equal(party.status, 'open');
  assert.equal(party.visibility, 'authenticated');
  assert.equal(party.participantCount, 1, 'host 포함 1명으로 시작한다');
  assert.equal(party.maxParticipants, 4);
  assert.equal(party.schemaVersion, 1);
  // 정확 주소·위경도·참가비 필드는 존재하지 않는다.
  for (const forbidden of ['address', 'lat', 'lng', 'location', 'fee', 'price']) {
    assert.equal(forbidden in party, false, forbidden);
  }

  const member = db.store.get(
    `communityParties/${result.partyId}/members/${HOST}`,
  );
  assert.equal(member.role, 'host');
  assert.equal(member.status, 'active');

  const mirror = db.store.get(
    `users/${HOST}/partyMemberships/${result.partyId}`,
  );
  assert.equal(mirror.role, 'host');
  assert.equal(mirror.state, 'active');

  assert.ok(db.store.get(`partyWriteLimits/${HOST}`).lastCreateAt);
});

test('create: host snapshot은 publicProfiles 공개 6개 필드만 담는다', async () => {
  const db = createFakeDb({ docs: baseDocs() });
  const { partyId } = await createCommunityPartyCore(
    ctx(db, { uid: HOST, data: validCreateInput() }),
  );
  const snapshot = db.store.get(`communityParties/${partyId}`).hostSnapshot;

  assert.deepEqual(Object.keys(snapshot).sort(), [
    'displayName',
    'photoUrl',
    'photoVerified',
    'schoolVerified',
    'uid',
    'workVerified',
  ]);
  // email/phone 인증 여부와 생년월일·성별은 복사되지 않는다.
  assert.equal('emailVerified' in snapshot, false);
  assert.equal('birthDate' in snapshot, false);
  assert.equal('gender' in snapshot, false);
});

test('create: 클라이언트가 status/participantCount를 보내면 거부한다', async () => {
  const db = createFakeDb({ docs: baseDocs() });
  await expectError(
    createCommunityPartyCore(
      ctx(db, {
        uid: HOST,
        data: { ...validCreateInput(), participantCount: 8 },
      }),
    ),
    'invalid-argument',
  );
});

test('create: 모임 시각이 2시간 이내거나 30일을 넘으면 거부한다', async () => {
  const db = createFakeDb({ docs: baseDocs() });

  await expectError(
    createCommunityPartyCore(
      ctx(db, {
        uid: HOST,
        data: validCreateInput({ startAtMillis: NOW + 60 * 60 * 1000 }),
      }),
    ),
    'invalid-argument',
  );
  await expectError(
    createCommunityPartyCore(
      ctx(db, {
        uid: HOST,
        data: validCreateInput({ startAtMillis: NOW - 1000 }),
      }),
    ),
    'invalid-argument',
  );
  await expectError(
    createCommunityPartyCore(
      ctx(db, {
        uid: HOST,
        data: validCreateInput({
          startAtMillis: NOW + 31 * 24 * 60 * 60 * 1000,
        }),
      }),
    ),
    'invalid-argument',
  );
});

test('create: 정원이 3~8 밖이면 거부한다', async () => {
  const db = createFakeDb({ docs: baseDocs() });
  for (const maxParticipants of [2, 9, 4.5, '4']) {
    await expectError(
      createCommunityPartyCore(
        ctx(db, { uid: HOST, data: validCreateInput({ maxParticipants }) }),
      ),
      'invalid-argument',
    );
  }
});

test('create: category/area allowlist 밖이면 거부한다', async () => {
  const db = createFakeDb({ docs: baseDocs() });
  await expectError(
    createCommunityPartyCore(
      ctx(db, { uid: HOST, data: validCreateInput({ category: 'party' }) }),
    ),
    'invalid-argument',
  );
  await expectError(
    createCommunityPartyCore(
      ctx(db, { uid: HOST, data: validCreateInput({ area: '강남역 3번 출구' }) }),
    ),
    'invalid-argument',
  );
});

test('create: 전화번호·송금 요청이 들어간 제목·설명은 거부한다', async () => {
  const db = createFakeDb({ docs: baseDocs() });
  await expectError(
    createCommunityPartyCore(
      ctx(db, {
        uid: HOST,
        data: validCreateInput({ description: '연락처 010-1234-5678로 주세요' }),
      }),
    ),
    'invalid-argument',
  );
  await expectError(
    createCommunityPartyCore(
      ctx(db, {
        uid: HOST,
        data: validCreateInput({ title: '참가비 계좌로 입금해주세요' }),
      }),
    ),
    'invalid-argument',
  );
});

test('create: 공개 프로필이 없으면 거부한다', async () => {
  const db = createFakeDb({ docs: {} });
  await expectError(
    createCommunityPartyCore(ctx(db, { uid: HOST, data: validCreateInput() })),
    'failed-precondition',
  );
});

test('create: 쿨다운 안에 다시 만들면 거부한다', async () => {
  const db = createFakeDb({ docs: baseDocs() });
  await createCommunityPartyCore(
    ctx(db, { uid: HOST, data: validCreateInput() }),
  );
  await expectError(
    createCommunityPartyCore(
      ctx(db, {
        uid: HOST,
        data: validCreateInput(),
        now: NOW + CREATE_COOLDOWN_MS - 1,
      }),
    ),
    'resource-exhausted',
  );
  // 쿨다운이 지나면 다시 만들 수 있다.
  await createCommunityPartyCore(
    ctx(db, {
      uid: HOST,
      data: validCreateInput(),
      now: NOW + CREATE_COOLDOWN_MS + 1,
    }),
  );
});

// ── requestPartyJoin ───────────────────────────────────────────────────────

function partyDocs(overrides = {}) {
  return baseDocs({
    'communityParties/p1': activeParty(),
    [`communityParties/p1/members/${HOST}`]: hostMember(),
    [`users/${HOST}/partyMemberships/p1`]: {
      partyId: 'p1',
      role: 'host',
      state: 'active',
      updatedAt: fakeTimestamp(NOW - 1000),
      schemaVersion: 1,
    },
    ...overrides,
  });
}

test('request: pending 요청과 mirror를 만든다', async () => {
  const db = createFakeDb({ docs: partyDocs() });
  const result = await requestPartyJoinCore(
    ctx(db, { uid: GUEST, data: { partyId: 'p1', message: '함께 걷고 싶어요' } }),
  );
  assert.deepEqual(result, { requested: true });

  const request = db.store.get(`communityParties/p1/joinRequests/${GUEST}`);
  assert.equal(request.status, 'pending');
  assert.equal(request.requesterUid, GUEST);
  assert.equal(request.message, '함께 걷고 싶어요');
  // requester snapshot은 서버가 publicProfiles에서 만든다.
  assert.equal(request.requesterSnapshot.displayName, '게스트');
  assert.equal(request.requesterSnapshot.workVerified, true);

  const mirror = db.store.get(`users/${GUEST}/partyMemberships/p1`);
  assert.equal(mirror.state, 'pending');
  assert.equal(mirror.role, 'member');
});

test('request: 클라이언트가 보낸 snapshot은 무시하고 거부한다', async () => {
  const db = createFakeDb({ docs: partyDocs() });
  await expectError(
    requestPartyJoinCore(
      ctx(db, {
        uid: GUEST,
        data: {
          partyId: 'p1',
          message: '',
          requesterSnapshot: { displayName: '해커' },
        },
      }),
    ),
    'invalid-argument',
  );
});

test('request: 호스트 본인은 요청할 수 없다', async () => {
  const db = createFakeDb({ docs: partyDocs() });
  await expectError(
    requestPartyJoinCore(ctx(db, { uid: HOST, data: { partyId: 'p1', message: '' } })),
    'failed-precondition',
  );
});

test('request: 정원이 찬 파티는 거부한다', async () => {
  const db = createFakeDb({
    docs: partyDocs({
      'communityParties/p1': activeParty({
        participantCount: 4,
        status: 'full',
      }),
    }),
  });
  await expectError(
    requestPartyJoinCore(ctx(db, { uid: GUEST, data: { partyId: 'p1', message: '' } })),
    'failed-precondition',
  );
});

test('request: 취소된 파티는 볼 수 없는 상태로 거부한다', async () => {
  const db = createFakeDb({
    docs: partyDocs({
      'communityParties/p1': activeParty({ status: 'cancelled' }),
    }),
  });
  await expectError(
    requestPartyJoinCore(ctx(db, { uid: GUEST, data: { partyId: 'p1', message: '' } })),
    'not-found',
  );
});

test('request: 이미 시작한 파티는 거부한다', async () => {
  const db = createFakeDb({
    docs: partyDocs({
      'communityParties/p1': activeParty({
        startAt: fakeTimestamp(NOW - 1000),
      }),
    }),
  });
  await expectError(
    requestPartyJoinCore(ctx(db, { uid: GUEST, data: { partyId: 'p1', message: '' } })),
    'failed-precondition',
  );
});

test('request: 차단 관계면 어느 방향이든 거부한다', async () => {
  for (const blockPath of [
    `users/${GUEST}/blocks/${HOST}`,
    `users/${HOST}/blocks/${GUEST}`,
  ]) {
    const db = createFakeDb({
      docs: partyDocs({ [blockPath]: { blockedUid: 'x', createdAt: 1 } }),
    });
    await expectError(
      requestPartyJoinCore(
        ctx(db, { uid: GUEST, data: { partyId: 'p1', message: '' } }),
      ),
      'permission-denied',
    );
    assert.equal(
      db.store.has(`communityParties/p1/joinRequests/${GUEST}`),
      false,
    );
  }
});

test('request: 지인 피하기 pair면 거부한다', async () => {
  const pairId = contactAvoidancePairId(GUEST, HOST);
  const db = createFakeDb({
    docs: partyDocs({ [`contactAvoidancePairs/${pairId}`]: { createdAt: 1 } }),
  });
  await expectError(
    requestPartyJoinCore(ctx(db, { uid: GUEST, data: { partyId: 'p1', message: '' } })),
    'permission-denied',
  );
});

test('request: 같은 pending 요청 재호출은 멱등이다', async () => {
  const db = createFakeDb({ docs: partyDocs() });
  await requestPartyJoinCore(
    ctx(db, { uid: GUEST, data: { partyId: 'p1', message: '처음' } }),
  );
  const first = db.store.get(`communityParties/p1/joinRequests/${GUEST}`);

  const result = await requestPartyJoinCore(
    ctx(db, {
      uid: GUEST,
      data: { partyId: 'p1', message: '두번째' },
      now: NOW + JOIN_REQUEST_COOLDOWN_MS + 1,
    }),
  );
  assert.deepEqual(result, { requested: true });
  const second = db.store.get(`communityParties/p1/joinRequests/${GUEST}`);
  assert.equal(second.message, first.message, 'pending 요청은 덮어쓰지 않는다');
});

test('request: rejected/withdrawn 뒤에는 다시 pending이 된다', async () => {
  for (const previous of ['rejected', 'withdrawn']) {
    const db = createFakeDb({
      docs: partyDocs({
        [`communityParties/p1/joinRequests/${GUEST}`]: {
          requesterUid: GUEST,
          requesterSnapshot: { uid: GUEST, displayName: '게스트' },
          message: '',
          status: previous,
          createdAt: fakeTimestamp(NOW - 5000),
          updatedAt: fakeTimestamp(NOW - 5000),
          schemaVersion: 1,
        },
      }),
    });
    await requestPartyJoinCore(
      ctx(db, { uid: GUEST, data: { partyId: 'p1', message: '다시 신청해요' } }),
    );
    const request = db.store.get(`communityParties/p1/joinRequests/${GUEST}`);
    assert.equal(request.status, 'pending', previous);
    assert.equal(request.message, '다시 신청해요');
  }
});

test('request: approved 뒤 재요청은 거부한다', async () => {
  const db = createFakeDb({
    docs: partyDocs({
      [`communityParties/p1/joinRequests/${GUEST}`]: {
        requesterUid: GUEST,
        requesterSnapshot: { uid: GUEST, displayName: '게스트' },
        message: '',
        status: 'approved',
        createdAt: fakeTimestamp(NOW - 5000),
        updatedAt: fakeTimestamp(NOW - 5000),
        schemaVersion: 1,
      },
    }),
  });
  await expectError(
    requestPartyJoinCore(ctx(db, { uid: GUEST, data: { partyId: 'p1', message: '' } })),
    'failed-precondition',
  );
});

test('request: 요청 메시지에 인증번호가 있으면 거부한다', async () => {
  const db = createFakeDb({ docs: partyDocs() });
  await expectError(
    requestPartyJoinCore(
      ctx(db, {
        uid: GUEST,
        data: { partyId: 'p1', message: '인증번호 알려주시면 갈게요' },
      }),
    ),
    'invalid-argument',
  );
});

// ── reviewPartyJoinRequest ─────────────────────────────────────────────────

function pendingRequestDocs(overrides = {}) {
  return partyDocs({
    [`communityParties/p1/joinRequests/${GUEST}`]: {
      requesterUid: GUEST,
      requesterSnapshot: { uid: GUEST, displayName: '게스트' },
      message: '',
      status: 'pending',
      createdAt: fakeTimestamp(NOW - 5000),
      updatedAt: fakeTimestamp(NOW - 5000),
      schemaVersion: 1,
    },
    [`users/${GUEST}/partyMemberships/p1`]: {
      partyId: 'p1',
      role: 'member',
      state: 'pending',
      updatedAt: fakeTimestamp(NOW - 5000),
      schemaVersion: 1,
    },
    ...overrides,
  });
}

test('review: 호스트 승인이 멤버·mirror·카운트를 함께 바꾼다', async () => {
  const db = createFakeDb({ docs: pendingRequestDocs() });
  const result = await reviewPartyJoinRequestCore(
    ctx(db, {
      uid: HOST,
      data: { partyId: 'p1', requesterUid: GUEST, decision: 'approve' },
    }),
  );

  assert.deepEqual(result, {
    decision: 'approve',
    participantCount: 2,
    status: 'open',
  });
  assert.equal(
    db.store.get(`communityParties/p1/joinRequests/${GUEST}`).status,
    'approved',
  );
  assert.equal(
    db.store.get(`communityParties/p1/members/${GUEST}`).role,
    'member',
  );
  assert.equal(db.store.get(`users/${GUEST}/partyMemberships/p1`).state, 'active');
  assert.equal(db.store.get('communityParties/p1').participantCount, 2);
});

test('review: 정원이 차면 status가 full로 바뀐다', async () => {
  const db = createFakeDb({
    docs: pendingRequestDocs({
      'communityParties/p1': activeParty({
        maxParticipants: 3,
        participantCount: 2,
      }),
    }),
  });
  const result = await reviewPartyJoinRequestCore(
    ctx(db, {
      uid: HOST,
      data: { partyId: 'p1', requesterUid: GUEST, decision: 'approve' },
    }),
  );
  assert.equal(result.status, 'full');
  assert.equal(db.store.get('communityParties/p1').status, 'full');
});

test('review: 정원이 이미 찼으면 승인 transaction에서 거부한다', async () => {
  const db = createFakeDb({
    docs: pendingRequestDocs({
      'communityParties/p1': activeParty({
        maxParticipants: 3,
        participantCount: 3,
      }),
    }),
  });
  await expectError(
    reviewPartyJoinRequestCore(
      ctx(db, {
        uid: HOST,
        data: { partyId: 'p1', requesterUid: GUEST, decision: 'approve' },
      }),
    ),
    'failed-precondition',
  );
  assert.equal(db.store.has(`communityParties/p1/members/${GUEST}`), false);
});

test('review: 요청 후 생긴 차단 관계는 승인 시점에 다시 막는다', async () => {
  const db = createFakeDb({
    docs: pendingRequestDocs({
      [`users/${HOST}/blocks/${GUEST}`]: { blockedUid: GUEST, createdAt: 1 },
    }),
  });
  await expectError(
    reviewPartyJoinRequestCore(
      ctx(db, {
        uid: HOST,
        data: { partyId: 'p1', requesterUid: GUEST, decision: 'approve' },
      }),
    ),
    'permission-denied',
  );
  assert.equal(db.store.has(`communityParties/p1/members/${GUEST}`), false);
  assert.equal(db.store.get('communityParties/p1').participantCount, 1);
});

test('review: 지인 피하기 pair도 승인 시점에 다시 막는다', async () => {
  const pairId = contactAvoidancePairId(GUEST, HOST);
  const db = createFakeDb({
    docs: pendingRequestDocs({
      [`contactAvoidancePairs/${pairId}`]: { createdAt: 1 },
    }),
  });
  await expectError(
    reviewPartyJoinRequestCore(
      ctx(db, {
        uid: HOST,
        data: { partyId: 'p1', requesterUid: GUEST, decision: 'approve' },
      }),
    ),
    'permission-denied',
  );
});

test('review: 거절은 mirror를 지우고 카운트를 바꾸지 않는다', async () => {
  const db = createFakeDb({ docs: pendingRequestDocs() });
  const result = await reviewPartyJoinRequestCore(
    ctx(db, {
      uid: HOST,
      data: { partyId: 'p1', requesterUid: GUEST, decision: 'reject' },
    }),
  );
  assert.equal(result.decision, 'reject');
  assert.equal(result.participantCount, 1);
  assert.equal(
    db.store.get(`communityParties/p1/joinRequests/${GUEST}`).status,
    'rejected',
  );
  assert.equal(db.store.has(`users/${GUEST}/partyMemberships/p1`), false);
  assert.equal(db.store.get('communityParties/p1').participantCount, 1);
});

test('review: 호스트가 아니면 거부한다', async () => {
  const db = createFakeDb({ docs: pendingRequestDocs() });
  await expectError(
    reviewPartyJoinRequestCore(
      ctx(db, {
        uid: OTHER,
        data: { partyId: 'p1', requesterUid: GUEST, decision: 'approve' },
      }),
    ),
    'permission-denied',
  );
});

test('review: pending이 아닌 요청은 다시 처리하지 않는다', async () => {
  const db = createFakeDb({ docs: pendingRequestDocs() });
  await reviewPartyJoinRequestCore(
    ctx(db, {
      uid: HOST,
      data: { partyId: 'p1', requesterUid: GUEST, decision: 'approve' },
    }),
  );
  await expectError(
    reviewPartyJoinRequestCore(
      ctx(db, {
        uid: HOST,
        data: { partyId: 'p1', requesterUid: GUEST, decision: 'approve' },
        now: NOW + REVIEW_COOLDOWN_MS + 1,
      }),
    ),
    'failed-precondition',
  );
  assert.equal(db.store.get('communityParties/p1').participantCount, 2);
});

test('review: 쿨다운 안에 연속 처리하면 거부한다', async () => {
  const db = createFakeDb({
    docs: pendingRequestDocs({
      [`communityParties/p1/joinRequests/${OTHER}`]: {
        requesterUid: OTHER,
        requesterSnapshot: { uid: OTHER, displayName: '제3자' },
        message: '',
        status: 'pending',
        createdAt: fakeTimestamp(NOW - 5000),
        updatedAt: fakeTimestamp(NOW - 5000),
        schemaVersion: 1,
      },
    }),
  });
  await reviewPartyJoinRequestCore(
    ctx(db, {
      uid: HOST,
      data: { partyId: 'p1', requesterUid: GUEST, decision: 'approve' },
    }),
  );
  await expectError(
    reviewPartyJoinRequestCore(
      ctx(db, {
        uid: HOST,
        data: { partyId: 'p1', requesterUid: OTHER, decision: 'approve' },
        now: NOW + REVIEW_COOLDOWN_MS - 1,
      }),
    ),
    'resource-exhausted',
  );
});

test('review: 로그와 응답에 대상 UID를 남기지 않는다', async () => {
  const db = createFakeDb({ docs: pendingRequestDocs() });
  const entries = [];
  const result = await reviewPartyJoinRequestCore(
    ctx(db, {
      uid: HOST,
      data: { partyId: 'p1', requesterUid: GUEST, decision: 'approve' },
      logger: { log: (entry) => entries.push(entry) },
    }),
  );

  const serialized = JSON.stringify({ result, entries });
  assert.equal(serialized.includes(GUEST), false, '대상 UID 노출');
  assert.equal(serialized.includes(HOST), false, '호출자 UID 노출');
});

// ── withdrawPartyJoinRequest ───────────────────────────────────────────────

test('withdraw: pending 요청을 취소하고 mirror를 지운다', async () => {
  const db = createFakeDb({ docs: pendingRequestDocs() });
  const result = await withdrawPartyJoinRequestCore(
    ctx(db, { uid: GUEST, data: { partyId: 'p1' } }),
  );
  assert.deepEqual(result, { withdrawn: true });
  assert.equal(
    db.store.get(`communityParties/p1/joinRequests/${GUEST}`).status,
    'withdrawn',
  );
  assert.equal(db.store.has(`users/${GUEST}/partyMemberships/p1`), false);
});

test('withdraw: 이미 취소했거나 요청이 없어도 성공한다(멱등)', async () => {
  const db = createFakeDb({ docs: pendingRequestDocs() });
  await withdrawPartyJoinRequestCore(
    ctx(db, { uid: GUEST, data: { partyId: 'p1' } }),
  );
  await withdrawPartyJoinRequestCore(
    ctx(db, { uid: GUEST, data: { partyId: 'p1' } }),
  );
  await withdrawPartyJoinRequestCore(
    ctx(db, { uid: OTHER, data: { partyId: 'p1' } }),
  );
});

test('withdraw: 승인된 멤버는 leave를 쓰도록 거부한다', async () => {
  const db = createFakeDb({ docs: pendingRequestDocs() });
  await reviewPartyJoinRequestCore(
    ctx(db, {
      uid: HOST,
      data: { partyId: 'p1', requesterUid: GUEST, decision: 'approve' },
    }),
  );
  await expectError(
    withdrawPartyJoinRequestCore(ctx(db, { uid: GUEST, data: { partyId: 'p1' } })),
    'failed-precondition',
  );
});

// ── leaveCommunityParty ────────────────────────────────────────────────────

test('leave: 멤버가 나가면 카운트가 줄고 full이 open으로 돌아온다', async () => {
  const db = createFakeDb({
    docs: pendingRequestDocs({
      'communityParties/p1': activeParty({
        maxParticipants: 3,
        participantCount: 2,
      }),
    }),
  });
  await reviewPartyJoinRequestCore(
    ctx(db, {
      uid: HOST,
      data: { partyId: 'p1', requesterUid: GUEST, decision: 'approve' },
    }),
  );
  assert.equal(db.store.get('communityParties/p1').status, 'full');

  const result = await leaveCommunityPartyCore(
    ctx(db, { uid: GUEST, data: { partyId: 'p1' } }),
  );
  assert.deepEqual(result, { left: true });

  const party = db.store.get('communityParties/p1');
  assert.equal(party.participantCount, 2);
  assert.equal(party.status, 'open');
  assert.equal(db.store.has(`communityParties/p1/members/${GUEST}`), false);
  assert.equal(db.store.has(`users/${GUEST}/partyMemberships/p1`), false);
  // 다시 요청할 수 있는 상태로 정리된다.
  assert.equal(
    db.store.get(`communityParties/p1/joinRequests/${GUEST}`).status,
    'withdrawn',
  );
});

test('leave: 호스트는 나갈 수 없다', async () => {
  const db = createFakeDb({ docs: partyDocs() });
  await expectError(
    leaveCommunityPartyCore(ctx(db, { uid: HOST, data: { partyId: 'p1' } })),
    'failed-precondition',
  );
  assert.equal(db.store.get('communityParties/p1').participantCount, 1);
});

test('leave: 이미 나갔으면 카운트를 다시 줄이지 않는다(멱등)', async () => {
  const db = createFakeDb({ docs: pendingRequestDocs() });
  await reviewPartyJoinRequestCore(
    ctx(db, {
      uid: HOST,
      data: { partyId: 'p1', requesterUid: GUEST, decision: 'approve' },
    }),
  );
  await leaveCommunityPartyCore(ctx(db, { uid: GUEST, data: { partyId: 'p1' } }));
  await leaveCommunityPartyCore(ctx(db, { uid: GUEST, data: { partyId: 'p1' } }));
  assert.equal(db.store.get('communityParties/p1').participantCount, 1);
});

// ── cancelCommunityParty ───────────────────────────────────────────────────

test('cancel: 호스트가 취소하면 상태가 바뀌고 mirror가 정리된다', async () => {
  const db = createFakeDb({ docs: pendingRequestDocs() });
  const result = await cancelCommunityPartyCore(
    ctx(db, { uid: HOST, data: { partyId: 'p1' } }),
  );
  assert.deepEqual(result, { cancelled: true });

  assert.equal(db.store.get('communityParties/p1').status, 'cancelled');
  assert.equal(db.store.has(`users/${HOST}/partyMemberships/p1`), false);
  assert.equal(db.store.has(`users/${GUEST}/partyMemberships/p1`), false);
  // 운영 참조를 위해 members/joinRequests 문서 자체는 남긴다.
  assert.equal(db.store.has(`communityParties/p1/members/${HOST}`), true);
  assert.equal(db.store.has(`communityParties/p1/joinRequests/${GUEST}`), true);
});

test('cancel: 호스트가 아니면 거부하고, 재호출은 멱등이다', async () => {
  const db = createFakeDb({ docs: partyDocs() });
  await expectError(
    cancelCommunityPartyCore(ctx(db, { uid: GUEST, data: { partyId: 'p1' } })),
    'permission-denied',
  );
  await cancelCommunityPartyCore(ctx(db, { uid: HOST, data: { partyId: 'p1' } }));
  await cancelCommunityPartyCore(ctx(db, { uid: HOST, data: { partyId: 'p1' } }));
  assert.equal(db.store.get('communityParties/p1').status, 'cancelled');
});

// ── reportCommunityParty ───────────────────────────────────────────────────

test('report: 같은 신고자·같은 파티는 문서 하나만 만든다(멱등)', async () => {
  const db = createFakeDb({ docs: partyDocs() });
  const reportRef = `partyReports/${partyReportId({
    reporterUid: GUEST,
    partyId: 'p1',
  })}`;

  const result = await reportCommunityPartyCore(
    ctx(db, {
      uid: GUEST,
      data: { partyId: 'p1', reason: 'spam_scam', detail: '광고 같아요' },
    }),
  );
  assert.deepEqual(result, { reported: true });

  const report = db.store.get(reportRef);
  assert.equal(report.reportedUid, HOST);
  assert.equal(report.partyId, 'p1');
  assert.equal(report.reason, 'spam_scam');

  await reportCommunityPartyCore(
    ctx(db, {
      uid: GUEST,
      data: { partyId: 'p1', reason: 'other', detail: '' },
      now: NOW + REPORT_COOLDOWN_MS + 1,
    }),
  );
  assert.equal(db.store.get(reportRef).reason, 'spam_scam', '재신고가 덮어쓰지 않는다');

  // 신고만으로 파티가 사라지거나 호스트가 차단되지 않는다.
  assert.equal(db.store.get('communityParties/p1').status, 'open');
  assert.equal(db.store.has(`users/${GUEST}/blocks/${HOST}`), false);
});

test('report: 사유 allowlist 밖이거나 본인 파티면 거부한다', async () => {
  const db = createFakeDb({ docs: partyDocs() });
  await expectError(
    reportCommunityPartyCore(
      ctx(db, { uid: GUEST, data: { partyId: 'p1', reason: '싫어요', detail: '' } }),
    ),
    'invalid-argument',
  );
  await expectError(
    reportCommunityPartyCore(
      ctx(db, { uid: HOST, data: { partyId: 'p1', reason: 'other', detail: '' } }),
    ),
    'failed-precondition',
  );
});

test('report: 쿨다운 안에 다른 파티를 신고하면 거부한다', async () => {
  const db = createFakeDb({
    docs: partyDocs({ 'communityParties/p2': activeParty() }),
  });
  await reportCommunityPartyCore(
    ctx(db, { uid: GUEST, data: { partyId: 'p1', reason: 'other', detail: '' } }),
  );
  await expectError(
    reportCommunityPartyCore(
      ctx(db, {
        uid: GUEST,
        data: { partyId: 'p2', reason: 'other', detail: '' },
        now: NOW + REPORT_COOLDOWN_MS - 1,
      }),
    ),
    'resource-exhausted',
  );
});

// ── 회원 탈퇴 수명주기 ─────────────────────────────────────────────────────

test('deletion: 호스트 파티는 취소·익명화되고 mirror가 정리된다', async () => {
  const db = createFakeDb({ docs: pendingRequestDocs() });
  const deletedIdentifier = 'deleted_abc123';

  const summary = await cleanupPartyDataForUser({
    db,
    uid: HOST,
    deletedIdentifier,
    serverTimestamp: () => fakeTimestamp(NOW),
  });

  assert.equal(summary.partiesCancelled, 1);
  assert.equal(summary.partyWriteLimitsDeleted, true);

  const party = db.store.get('communityParties/p1');
  assert.equal(party.status, 'cancelled');
  assert.equal(party.hostUid, deletedIdentifier);
  assert.equal(party.hostSnapshot.displayName, '탈퇴한 사용자');
  assert.equal(party.hostSnapshot.uid, deletedIdentifier);

  assert.equal(db.store.has(`users/${HOST}/partyMemberships/p1`), false);
  assert.equal(db.store.has(`users/${GUEST}/partyMemberships/p1`), false);
});

test('deletion: 참여자는 멤버에서 빠지고 카운트가 보정된다', async () => {
  const db = createFakeDb({
    docs: pendingRequestDocs({
      'communityParties/p1': activeParty({
        maxParticipants: 3,
        participantCount: 2,
      }),
    }),
  });
  await reviewPartyJoinRequestCore(
    ctx(db, {
      uid: HOST,
      data: { partyId: 'p1', requesterUid: GUEST, decision: 'approve' },
    }),
  );
  assert.equal(db.store.get('communityParties/p1').status, 'full');

  const summary = await cleanupPartyDataForUser({
    db,
    uid: GUEST,
    deletedIdentifier: 'deleted_guest',
    serverTimestamp: () => fakeTimestamp(NOW),
  });

  assert.equal(summary.partyMembershipsRemoved, 1);
  const party = db.store.get('communityParties/p1');
  assert.equal(party.participantCount, 2);
  assert.equal(party.status, 'open', 'full이었다면 open으로 복원한다');
  assert.equal(db.store.has(`communityParties/p1/members/${GUEST}`), false);
  assert.equal(db.store.has(`users/${GUEST}/partyMemberships/p1`), false);

  const request = db.store.get(`communityParties/p1/joinRequests/${GUEST}`);
  assert.equal(request.status, 'withdrawn');
  assert.equal(request.requesterUid, 'deleted_guest');
  assert.equal(request.requesterSnapshot.displayName, '탈퇴한 사용자');
});

test('deletion: pending 요청·신고·rate limit도 정리한다', async () => {
  const reportRef = `partyReports/${partyReportId({
    reporterUid: GUEST,
    partyId: 'p1',
  })}`;
  const db = createFakeDb({
    docs: pendingRequestDocs({
      [`partyWriteLimits/${GUEST}`]: { lastReportAt: fakeTimestamp(NOW) },
      [reportRef]: {
        reporterUid: GUEST,
        reportedUid: HOST,
        partyId: 'p1',
        reason: 'other',
        createdAt: fakeTimestamp(NOW),
        schemaVersion: 1,
      },
    }),
  });

  const summary = await cleanupPartyDataForUser({
    db,
    uid: GUEST,
    deletedIdentifier: 'deleted_guest',
    serverTimestamp: () => fakeTimestamp(NOW),
  });

  assert.equal(summary.partyRequestsClosed, 1);
  assert.equal(summary.partyReportsAnonymized, 1);
  assert.equal(db.store.get(reportRef).reporterUid, 'deleted_guest');
  assert.equal(db.store.get(reportRef).reporterDeleted, true);
  assert.equal(db.store.has(`partyWriteLimits/${GUEST}`), false);
  assert.equal(db.store.has(`users/${GUEST}/partyMemberships/p1`), false);
});

test('deletion: 재실행해도 카운트가 더 줄지 않는다(멱등)', async () => {
  const db = createFakeDb({ docs: pendingRequestDocs() });
  await reviewPartyJoinRequestCore(
    ctx(db, {
      uid: HOST,
      data: { partyId: 'p1', requesterUid: GUEST, decision: 'approve' },
    }),
  );
  const args = {
    db,
    uid: GUEST,
    deletedIdentifier: 'deleted_guest',
    serverTimestamp: () => fakeTimestamp(NOW),
  };
  await cleanupPartyDataForUser(args);
  const after = db.store.get('communityParties/p1').participantCount;
  await cleanupPartyDataForUser(args);
  assert.equal(db.store.get('communityParties/p1').participantCount, after);
});

// ── 인증·로그 위생 ─────────────────────────────────────────────────────────

test('모든 party callable은 로그인하지 않으면 거부한다', async () => {
  const db = createFakeDb({ docs: partyDocs() });
  const anonymous = { request: {}, db, HttpsError: FakeHttpsError };
  const cores = [
    () => createCommunityPartyCore(anonymous),
    () => requestPartyJoinCore(anonymous),
    () => reviewPartyJoinRequestCore(anonymous),
    () => withdrawPartyJoinRequestCore(anonymous),
    () => leaveCommunityPartyCore(anonymous),
    () => cancelCommunityPartyCore(anonymous),
    () => reportCommunityPartyCore(anonymous),
  ];
  for (const core of cores) {
    await expectError(core(), 'unauthenticated');
  }
});

test('create 로그에는 uid hash와 분류 code만 남는다', async () => {
  const db = createFakeDb({ docs: baseDocs() });
  const entries = [];
  await createCommunityPartyCore(
    ctx(db, {
      uid: HOST,
      data: validCreateInput(),
      logger: { log: (entry) => entries.push(entry) },
    }),
  );
  const serialized = JSON.stringify(entries);
  assert.equal(serialized.includes(HOST), false, '원문 UID 노출');
  assert.equal(serialized.includes('한강 산책'), false, '본문 노출');
  assert.equal(serialized.includes('walk'), true, '분류 code는 남긴다');
});

test('파티 id는 서버가 정한다(클라이언트가 지정할 수 없다)', async () => {
  const db = createFakeDb({ docs: baseDocs() });
  // 클라이언트가 id를 보내는 경로 자체가 없다(exact input).
  await expectError(
    createCommunityPartyCore(
      ctx(db, { uid: HOST, data: { ...validCreateInput(), partyId: 'guess-me' } }),
    ),
    'invalid-argument',
  );

  const { partyId } = await createCommunityPartyCore(
    ctx(db, { uid: HOST, data: validCreateInput() }),
  );
  assert.equal(partyPathOf(db), `communityParties/${partyId}`);
  assert.equal(db.store.has('communityParties/guess-me'), false);
});

test('rate limit 상수는 명세와 같다', () => {
  assert.equal(CREATE_COOLDOWN_MS, 30 * 1000);
  assert.equal(JOIN_REQUEST_COOLDOWN_MS, 5 * 1000);
  assert.equal(REVIEW_COOLDOWN_MS, 2 * 1000);
  assert.equal(REPORT_COOLDOWN_MS, 5 * 1000);
});
