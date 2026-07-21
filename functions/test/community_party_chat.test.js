'use strict';

// Phase 4-5 — 파티 그룹 채팅 서버 core 테스트.
//
// Firestore를 fake로 주입해 진입 자격(active member만), 입력 검증,
// hard block과 확인 후 통과(acknowledgement) 분리, canonical snapshot,
// soft delete 멱등성, 신고 중복 방지, rate limit, 회원 탈퇴 수명주기,
// 응답·로그의 개인정보 미노출을 확인한다.

const assert = require('node:assert/strict');
const { test } = require('node:test');

const {
  ACK_REQUIRED_ERROR_CODE,
  MESSAGE_COOLDOWN_MS,
  MESSAGE_TEXT_MAX_LENGTH,
  REPORT_COOLDOWN_MS,
  classifyPartyChatText,
  cleanupPartyChatDataForUser,
  deletePartyGroupMessageCore,
  partyMessageReportId,
  reportPartyGroupMessageCore,
  sendPartyGroupMessageCore,
} = require('../lib/community_party_chat');

const HOST = 'host-uid';
const MEMBER = 'member-uid';
const PENDING = 'pending-uid';
const STRANGER = 'stranger-uid';

const NOW = 1_700_000_000_000;
const START_AT = NOW + 24 * 60 * 60 * 1000;

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

/** 최소 fake Firestore(community_party.test.js와 같은 계약). */
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

  function matchQuery(paths, field, op, value) {
    const out = [];
    for (const path of paths) {
      const actual = store.get(path)?.[field];
      if (op === '==' ? actual === value : false) out.push(snapshotOf(path));
    }
    return out;
  }

  function collectionRef(prefix) {
    return {
      id: prefix.split('/').pop(),
      doc: (id) => docRef(`${prefix}/${id ?? `auto${++autoId}`}`),
      get: async () => {
        const docsOut = directChildren(prefix).map(snapshotOf);
        return { docs: docsOut, empty: docsOut.length === 0 };
      },
      where: (field, op, value) => ({
        get: async () => {
          const docsOut = matchQuery(directChildren(prefix), field, op, value);
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
    collectionGroup: (name) => ({
      where: (field, op, value) => ({
        get: async () => {
          const paths = [];
          for (const path of store.keys()) {
            const parts = path.split('/');
            if (parts.length >= 2 && parts[parts.length - 2] === name) {
              paths.push(path);
            }
          }
          const docsOut = matchQuery(paths, field, op, value);
          return { docs: docsOut, empty: docsOut.length === 0 };
        },
      }),
    }),
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

function publicProfile(name, verifications = {}) {
  return {
    displayName: name,
    photoUrls: ['https://example.test/p.jpg'],
    verifications,
    birthDate: '1999-01-01',
    gender: 'male',
    phoneNumber: '010-1234-5678',
  };
}

function activeParty(overrides = {}) {
  return {
    hostUid: HOST,
    hostSnapshot: {
      uid: HOST,
      displayName: '호스트',
      photoUrl: '',
      photoVerified: false,
      workVerified: false,
      schoolVerified: false,
    },
    title: '한강 산책 같이 해요',
    description: '가볍게 걷고 커피 마셔요.',
    category: 'walk',
    area: 'seoul',
    startAt: fakeTimestamp(START_AT),
    maxParticipants: 4,
    participantCount: 2,
    status: 'open',
    visibility: 'authenticated',
    createdAt: fakeTimestamp(NOW - 1000),
    updatedAt: fakeTimestamp(NOW - 1000),
    schemaVersion: 1,
    ...overrides,
  };
}

function memberDoc(uid, overrides = {}) {
  return {
    uid,
    role: uid === HOST ? 'host' : 'member',
    status: 'active',
    joinedAt: fakeTimestamp(NOW - 1000),
    updatedAt: fakeTimestamp(NOW - 1000),
    schemaVersion: 1,
    ...overrides,
  };
}

function messageDoc(senderUid, overrides = {}) {
  return {
    senderUid,
    senderSnapshot: {
      uid: senderUid,
      displayName: '작성자',
      photoUrl: '',
      photoVerified: false,
      workVerified: false,
      schoolVerified: false,
    },
    text: '안녕하세요',
    status: 'active',
    createdAt: fakeTimestamp(NOW - 500),
    updatedAt: fakeTimestamp(NOW - 500),
    schemaVersion: 1,
    ...overrides,
  };
}

function chatDocs(overrides = {}) {
  return {
    [`publicProfiles/${HOST}`]: publicProfile('호스트', { photo: true }),
    [`publicProfiles/${MEMBER}`]: publicProfile('참여자', {
      work: true,
      email: true,
      phone: true,
    }),
    [`publicProfiles/${PENDING}`]: publicProfile('대기자'),
    [`publicProfiles/${STRANGER}`]: publicProfile('제3자'),
    'communityParties/p1': activeParty(),
    [`communityParties/p1/members/${HOST}`]: memberDoc(HOST),
    [`communityParties/p1/members/${MEMBER}`]: memberDoc(MEMBER),
    [`communityParties/p1/joinRequests/${PENDING}`]: {
      requesterUid: PENDING,
      requesterSnapshot: { uid: PENDING, displayName: '대기자' },
      message: '',
      status: 'pending',
      createdAt: fakeTimestamp(NOW - 5000),
      updatedAt: fakeTimestamp(NOW - 5000),
      schemaVersion: 1,
    },
    ...overrides,
  };
}

function ctx(db, { uid = MEMBER, data = {}, now = NOW, logger = null } = {}) {
  return {
    request: { auth: { uid }, data },
    db,
    HttpsError: FakeHttpsError,
    serverTimestamp: () => fakeTimestamp(now),
    nowMs: () => now,
    logger,
  };
}

function sendInput(overrides = {}) {
  return {
    partyId: 'p1',
    text: '오늘 몇 시에 만날까요?',
    safetyAcknowledged: false,
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

function messagePathsOf(db) {
  return [...db.store.keys()].filter((p) =>
    p.startsWith('communityParties/p1/groupMessages/'),
  );
}

// ── 진입 자격 ──────────────────────────────────────────────────────────────

test('send: active member는 메시지를 보낼 수 있다', async () => {
  const db = createFakeDb({ docs: chatDocs() });
  const result = await sendPartyGroupMessageCore(
    ctx(db, { uid: MEMBER, data: sendInput() }),
  );

  assert.equal(typeof result.messageId, 'string');
  // 응답에는 messageId만 담는다(UID·본문·snapshot 금지).
  assert.deepEqual(Object.keys(result), ['messageId']);

  const path = messagePathsOf(db)[0];
  const message = db.store.get(path);
  assert.equal(message.senderUid, MEMBER);
  assert.equal(message.text, '오늘 몇 시에 만날까요?');
  assert.equal(message.status, 'active');
  assert.equal(message.schemaVersion, 1);
});

test('send: host도 members 문서를 통해 보낼 수 있다', async () => {
  const db = createFakeDb({ docs: chatDocs() });
  await sendPartyGroupMessageCore(ctx(db, { uid: HOST, data: sendInput() }));
  assert.equal(messagePathsOf(db).length, 1);
});

test('send: 비멤버는 거부한다', async () => {
  const db = createFakeDb({ docs: chatDocs() });
  await expectError(
    sendPartyGroupMessageCore(ctx(db, { uid: STRANGER, data: sendInput() })),
    'permission-denied',
  );
  assert.equal(messagePathsOf(db).length, 0);
});

test('send: 승인 대기 요청자는 거부한다', async () => {
  const db = createFakeDb({ docs: chatDocs() });
  await expectError(
    sendPartyGroupMessageCore(ctx(db, { uid: PENDING, data: sendInput() })),
    'permission-denied',
  );
});

test('send: mirror만 있고 member 문서가 없으면 거부한다', async () => {
  // partyMemberships mirror는 권한 판단에 쓰지 않는다.
  const db = createFakeDb({
    docs: chatDocs({
      [`users/${STRANGER}/partyMemberships/p1`]: {
        partyId: 'p1',
        role: 'member',
        state: 'active',
        updatedAt: fakeTimestamp(NOW),
        schemaVersion: 1,
      },
    }),
  });
  await expectError(
    sendPartyGroupMessageCore(ctx(db, { uid: STRANGER, data: sendInput() })),
    'permission-denied',
  );
});

test('send: status/schema가 다른 member 문서는 거부한다', async () => {
  for (const override of [{ status: 'left' }, { schemaVersion: 2 }]) {
    const db = createFakeDb({
      docs: chatDocs({
        [`communityParties/p1/members/${MEMBER}`]: memberDoc(MEMBER, override),
      }),
    });
    await expectError(
      sendPartyGroupMessageCore(ctx(db, { uid: MEMBER, data: sendInput() })),
      'permission-denied',
    );
  }
});

test('send: cancelled 파티는 거부한다', async () => {
  const db = createFakeDb({
    docs: chatDocs({ 'communityParties/p1': activeParty({ status: 'cancelled' }) }),
  });
  await expectError(
    sendPartyGroupMessageCore(ctx(db, { uid: MEMBER, data: sendInput() })),
    'not-found',
  );
});

test('send: 존재하지 않는 파티는 거부한다', async () => {
  const db = createFakeDb({ docs: chatDocs() });
  await expectError(
    sendPartyGroupMessageCore(
      ctx(db, { uid: MEMBER, data: sendInput({ partyId: 'ghost' }) }),
    ),
    'not-found',
  );
});

// ── 입력 검증 ──────────────────────────────────────────────────────────────

test('send: 빈 본문과 1000자 초과는 거부한다', async () => {
  const db = createFakeDb({ docs: chatDocs() });
  for (const text of ['', '   ', 'ㄱ'.repeat(MESSAGE_TEXT_MAX_LENGTH + 1)]) {
    await expectError(
      sendPartyGroupMessageCore(ctx(db, { uid: MEMBER, data: sendInput({ text }) })),
      'invalid-argument',
    );
  }
  // 정확히 상한이면 통과한다.
  await sendPartyGroupMessageCore(
    ctx(db, {
      uid: MEMBER,
      data: sendInput({ text: 'ㄱ'.repeat(MESSAGE_TEXT_MAX_LENGTH) }),
    }),
  );
});

test('send: exact input이 아니면 거부한다', async () => {
  const db = createFakeDb({ docs: chatDocs() });
  // 클라이언트가 snapshot/status/createdAt을 보내는 경로는 없다.
  await expectError(
    sendPartyGroupMessageCore(
      ctx(db, {
        uid: MEMBER,
        data: { ...sendInput(), senderSnapshot: { displayName: '해커' } },
      }),
    ),
    'invalid-argument',
  );
  await expectError(
    sendPartyGroupMessageCore(
      ctx(db, { uid: MEMBER, data: { ...sendInput(), status: 'active' } }),
    ),
    'invalid-argument',
  );
  // safetyAcknowledged는 bool이어야 한다.
  await expectError(
    sendPartyGroupMessageCore(
      ctx(db, { uid: MEMBER, data: sendInput({ safetyAcknowledged: 'true' }) }),
    ),
    'invalid-argument',
  );
});

// ── 안전 검사 ──────────────────────────────────────────────────────────────

test('classify: 인증번호·송금은 hard block, 전화번호·외부 메신저는 확인 대상', () => {
  assert.deepEqual(classifyPartyChatText('인증번호 알려주세요').blocked, [
    'verification_code',
  ]);
  assert.deepEqual(classifyPartyChatText('계좌번호 알려주세요').blocked, [
    'financial_request',
  ]);

  const phone = classifyPartyChatText('제 번호 010-1234-5678이에요');
  assert.deepEqual(phone.blocked, []);
  assert.deepEqual(phone.acknowledgeable, ['phone_number']);

  const kakao = classifyPartyChatText('카톡으로 옮길까요?');
  assert.deepEqual(kakao.blocked, []);
  assert.deepEqual(kakao.acknowledgeable, ['external_contact']);

  // 일상 표현은 걸리지 않는다.
  assert.deepEqual(classifyPartyChatText('온라인으로 만나요').acknowledgeable, []);
  assert.deepEqual(classifyPartyChatText('가이드라인 확인했어요').acknowledgeable, []);
});

test('send: 인증번호·송금 요청은 확인해도 보낼 수 없다', async () => {
  const db = createFakeDb({ docs: chatDocs() });
  for (const text of ['인증번호 좀 알려주세요', '참가비 계좌로 입금해주세요']) {
    await expectError(
      sendPartyGroupMessageCore(
        ctx(db, {
          uid: MEMBER,
          // 확인했다고 주장해도 hard block은 뚫리지 않는다.
          data: sendInput({ text, safetyAcknowledged: true }),
        }),
      ),
      'invalid-argument',
    );
  }
  assert.equal(messagePathsOf(db).length, 0);
});

test('send: 전화번호·외부 메신저는 확인 전에는 거부하고 확인하면 통과한다', async () => {
  for (const text of ['제 번호 010-1234-5678이에요', '카톡으로 옮길까요?']) {
    const db = createFakeDb({ docs: chatDocs() });

    await assert.rejects(
      sendPartyGroupMessageCore(
        ctx(db, { uid: MEMBER, data: sendInput({ text }) }),
      ),
      (error) => {
        assert.equal(error.code, 'failed-precondition');
        // 클라이언트가 경고 후 재전송할 수 있게 고정 code를 준다.
        assert.equal(error.details.code, ACK_REQUIRED_ERROR_CODE);
        assert.match(error.message, /연락처를 공유하면/);
        return true;
      },
    );
    assert.equal(messagePathsOf(db).length, 0);

    await sendPartyGroupMessageCore(
      ctx(db, { uid: MEMBER, data: sendInput({ text, safetyAcknowledged: true }) }),
    );
    assert.equal(messagePathsOf(db).length, 1);
  }
});

// ── snapshot ───────────────────────────────────────────────────────────────

test('send: sender snapshot은 publicProfiles 공개 6개 필드만 담는다', async () => {
  const db = createFakeDb({ docs: chatDocs() });
  await sendPartyGroupMessageCore(ctx(db, { uid: MEMBER, data: sendInput() }));

  const snapshot = db.store.get(messagePathsOf(db)[0]).senderSnapshot;
  assert.deepEqual(Object.keys(snapshot).sort(), [
    'displayName',
    'photoUrl',
    'photoVerified',
    'schoolVerified',
    'uid',
    'workVerified',
  ]);
  assert.equal(snapshot.displayName, '참여자');
  assert.equal(snapshot.workVerified, true);
  // email/phone 인증 여부와 전화번호·생년월일·성별은 복사되지 않는다.
  for (const forbidden of ['emailVerified', 'phoneNumber', 'birthDate', 'gender']) {
    assert.equal(forbidden in snapshot, false, forbidden);
  }
});

test('send: 공개 프로필이 없으면 거부한다', async () => {
  const docs = chatDocs();
  delete docs[`publicProfiles/${MEMBER}`];
  const db = createFakeDb({ docs });
  await expectError(
    sendPartyGroupMessageCore(ctx(db, { uid: MEMBER, data: sendInput() })),
    'failed-precondition',
  );
});

// ── rate limit ─────────────────────────────────────────────────────────────

test('send: 쿨다운 안에 연속 전송하면 거부한다', async () => {
  const db = createFakeDb({ docs: chatDocs() });
  await sendPartyGroupMessageCore(ctx(db, { uid: MEMBER, data: sendInput() }));
  await expectError(
    sendPartyGroupMessageCore(
      ctx(db, { uid: MEMBER, data: sendInput(), now: NOW + MESSAGE_COOLDOWN_MS - 1 }),
    ),
    'resource-exhausted',
  );
  await sendPartyGroupMessageCore(
    ctx(db, { uid: MEMBER, data: sendInput(), now: NOW + MESSAGE_COOLDOWN_MS + 1 }),
  );
  assert.equal(messagePathsOf(db).length, 2);
});

// ── deletePartyGroupMessage ────────────────────────────────────────────────

function messageDocs(overrides = {}) {
  return chatDocs({
    'communityParties/p1/groupMessages/m1': messageDoc(MEMBER),
    'communityParties/p1/groupMessages/m2': messageDoc(HOST, { text: '반가워요' }),
    ...overrides,
  });
}

test('delete: 본인 메시지를 soft delete한다', async () => {
  const db = createFakeDb({ docs: messageDocs() });
  const result = await deletePartyGroupMessageCore(
    ctx(db, { uid: MEMBER, data: { partyId: 'p1', messageId: 'm1' } }),
  );
  assert.deepEqual(result, { deleted: true });

  const message = db.store.get('communityParties/p1/groupMessages/m1');
  assert.equal(message.status, 'removed');
  // 신고 검토를 위해 본문은 남는다(일반 read는 Rules가 막는다).
  assert.equal(message.text, '안녕하세요');
});

test('delete: 타인 메시지는 지울 수 없다(호스트도 마찬가지)', async () => {
  const db = createFakeDb({ docs: messageDocs() });
  await expectError(
    deletePartyGroupMessageCore(
      ctx(db, { uid: MEMBER, data: { partyId: 'p1', messageId: 'm2' } }),
    ),
    'permission-denied',
  );
  await expectError(
    deletePartyGroupMessageCore(
      ctx(db, { uid: HOST, data: { partyId: 'p1', messageId: 'm1' } }),
    ),
    'permission-denied',
  );
  assert.equal(
    db.store.get('communityParties/p1/groupMessages/m1').status,
    'active',
  );
});

test('delete: 재호출은 멱등이고, 없는 메시지는 not-found다', async () => {
  const db = createFakeDb({ docs: messageDocs() });
  await deletePartyGroupMessageCore(
    ctx(db, { uid: MEMBER, data: { partyId: 'p1', messageId: 'm1' } }),
  );
  await deletePartyGroupMessageCore(
    ctx(db, { uid: MEMBER, data: { partyId: 'p1', messageId: 'm1' } }),
  );
  assert.equal(
    db.store.get('communityParties/p1/groupMessages/m1').status,
    'removed',
  );

  await expectError(
    deletePartyGroupMessageCore(
      ctx(db, { uid: MEMBER, data: { partyId: 'p1', messageId: 'ghost' } }),
    ),
    'not-found',
  );
});

test('delete: 비멤버는 거부한다', async () => {
  const db = createFakeDb({ docs: messageDocs() });
  await expectError(
    deletePartyGroupMessageCore(
      ctx(db, { uid: STRANGER, data: { partyId: 'p1', messageId: 'm1' } }),
    ),
    'permission-denied',
  );
});

// ── reportPartyGroupMessage ────────────────────────────────────────────────

test('report: 같은 신고자·같은 메시지는 문서 하나만 만든다(멱등)', async () => {
  const db = createFakeDb({ docs: messageDocs() });
  const reportRef = `partyMessageReports/${partyMessageReportId({
    reporterUid: MEMBER,
    partyId: 'p1',
    messageId: 'm2',
  })}`;

  const result = await reportPartyGroupMessageCore(
    ctx(db, {
      uid: MEMBER,
      data: {
        partyId: 'p1',
        messageId: 'm2',
        reason: 'abusive_language',
        detail: '욕설이에요',
      },
    }),
  );
  assert.deepEqual(result, { reported: true });

  const report = db.store.get(reportRef);
  assert.equal(report.reportedUid, HOST);
  assert.equal(report.messageId, 'm2');
  assert.equal(report.reason, 'abusive_language');
  // 원문 snapshot은 저장하지 않는다.
  assert.equal('text' in report, false);
  assert.equal('messageSnapshot' in report, false);

  await reportPartyGroupMessageCore(
    ctx(db, {
      uid: MEMBER,
      data: { partyId: 'p1', messageId: 'm2', reason: 'other', detail: '' },
      now: NOW + REPORT_COOLDOWN_MS + 1,
    }),
  );
  assert.equal(db.store.get(reportRef).reason, 'abusive_language');

  // 신고만으로 메시지가 지워지거나 멤버가 빠지거나 파티가 취소되지 않는다.
  assert.equal(
    db.store.get('communityParties/p1/groupMessages/m2').status,
    'active',
  );
  assert.equal(db.store.has(`communityParties/p1/members/${HOST}`), true);
  assert.equal(db.store.get('communityParties/p1').status, 'open');
});

test('report: 본인 메시지 신고와 allowlist 밖 사유는 거부한다', async () => {
  const db = createFakeDb({ docs: messageDocs() });
  await expectError(
    reportPartyGroupMessageCore(
      ctx(db, {
        uid: MEMBER,
        data: { partyId: 'p1', messageId: 'm1', reason: 'other', detail: '' },
      }),
    ),
    'failed-precondition',
  );
  await expectError(
    reportPartyGroupMessageCore(
      ctx(db, {
        uid: MEMBER,
        data: { partyId: 'p1', messageId: 'm2', reason: '싫어요', detail: '' },
      }),
    ),
    'invalid-argument',
  );
});

test('report: 비멤버는 거부한다', async () => {
  const db = createFakeDb({ docs: messageDocs() });
  await expectError(
    reportPartyGroupMessageCore(
      ctx(db, {
        uid: STRANGER,
        data: { partyId: 'p1', messageId: 'm1', reason: 'other', detail: '' },
      }),
    ),
    'permission-denied',
  );
});

// ── 회원 탈퇴 수명주기 ─────────────────────────────────────────────────────

test('deletion: 본인 메시지는 removed·익명화되고 남의 메시지는 그대로다', async () => {
  const db = createFakeDb({ docs: messageDocs() });
  const summary = await cleanupPartyChatDataForUser({
    db,
    uid: MEMBER,
    deletedIdentifier: 'deleted_member',
    serverTimestamp: () => fakeTimestamp(NOW),
  });

  assert.equal(summary.partyMessagesRemoved, 1);
  assert.equal(summary.partyMessageWriteLimitsDeleted, true);

  const mine = db.store.get('communityParties/p1/groupMessages/m1');
  assert.equal(mine.status, 'removed');
  assert.equal(mine.senderUid, 'deleted_member');
  assert.equal(mine.senderSnapshot.uid, 'deleted_member');
  assert.equal(mine.senderSnapshot.displayName, '탈퇴한 사용자');
  assert.equal(mine.senderSnapshot.photoUrl, '');
  assert.equal(mine.senderSnapshot.photoVerified, false);
  assert.equal(mine.senderSnapshot.workVerified, false);
  assert.equal(mine.senderSnapshot.schoolVerified, false);

  // 무관한 메시지는 건드리지 않는다.
  const other = db.store.get('communityParties/p1/groupMessages/m2');
  assert.equal(other.status, 'active');
  assert.equal(other.senderUid, HOST);
});

test('deletion: 신고 reporter 익명화와 rate limit 삭제', async () => {
  const reportRef = `partyMessageReports/${partyMessageReportId({
    reporterUid: MEMBER,
    partyId: 'p1',
    messageId: 'm2',
  })}`;
  const db = createFakeDb({
    docs: messageDocs({
      [reportRef]: {
        reporterUid: MEMBER,
        reportedUid: HOST,
        partyId: 'p1',
        messageId: 'm2',
        reason: 'other',
        createdAt: fakeTimestamp(NOW),
        schemaVersion: 1,
      },
      [`partyMessageWriteLimits/${MEMBER}`]: {
        lastMessageAt: fakeTimestamp(NOW),
      },
    }),
  });

  const summary = await cleanupPartyChatDataForUser({
    db,
    uid: MEMBER,
    deletedIdentifier: 'deleted_member',
    serverTimestamp: () => fakeTimestamp(NOW),
  });

  assert.equal(summary.partyMessageReportsAnonymized, 1);
  assert.equal(db.store.get(reportRef).reporterUid, 'deleted_member');
  assert.equal(db.store.get(reportRef).reporterDeleted, true);
  assert.equal(db.store.has(`partyMessageWriteLimits/${MEMBER}`), false);
});

test('deletion: 재실행해도 결과가 같다(멱등)', async () => {
  const db = createFakeDb({ docs: messageDocs() });
  const args = {
    db,
    uid: MEMBER,
    deletedIdentifier: 'deleted_member',
    serverTimestamp: () => fakeTimestamp(NOW),
  };
  await cleanupPartyChatDataForUser(args);
  const second = await cleanupPartyChatDataForUser(args);
  // 익명 식별자로 바뀌었으므로 두 번째에는 잡히지 않는다.
  assert.equal(second.partyMessagesRemoved, 0);
  assert.equal(
    db.store.get('communityParties/p1/groupMessages/m1').senderUid,
    'deleted_member',
  );
});

// ── 인증·로그 위생 ─────────────────────────────────────────────────────────

test('모든 group chat callable은 로그인하지 않으면 거부한다', async () => {
  const db = createFakeDb({ docs: messageDocs() });
  const anonymous = { request: {}, db, HttpsError: FakeHttpsError };
  for (const core of [
    sendPartyGroupMessageCore,
    deletePartyGroupMessageCore,
    reportPartyGroupMessageCore,
  ]) {
    await expectError(core(anonymous), 'unauthenticated');
  }
});

test('응답과 로그에 UID·본문·탐지 문자열이 남지 않는다', async () => {
  const db = createFakeDb({ docs: chatDocs() });
  const entries = [];
  const logger = { log: (entry) => entries.push(entry) };

  const sent = await sendPartyGroupMessageCore(
    ctx(db, {
      uid: MEMBER,
      data: sendInput({ text: '오늘 3시에 2번 출구에서 만나요' }),
      logger,
    }),
  );

  // 확인이 필요한 본문도 로그에 원문을 남기지 않는다.
  await assert.rejects(
    sendPartyGroupMessageCore(
      ctx(db, {
        uid: MEMBER,
        data: sendInput({ text: '카톡 아이디 알려주세요' }),
        now: NOW + MESSAGE_COOLDOWN_MS + 1,
        logger,
      }),
    ),
  );
  // hard block 경로도 마찬가지다.
  await assert.rejects(
    sendPartyGroupMessageCore(
      ctx(db, {
        uid: MEMBER,
        data: sendInput({ text: '인증번호 알려주세요' }),
        now: NOW + MESSAGE_COOLDOWN_MS * 3,
        logger,
      }),
    ),
  );

  const serialized = JSON.stringify({ sent, entries });
  assert.equal(serialized.includes(MEMBER), false, '원문 UID 노출');
  assert.equal(serialized.includes('2번 출구'), false, '본문 노출');
  assert.equal(serialized.includes('카톡'), false, '탐지 문자열 노출');
  assert.equal(serialized.includes('인증번호'), false, '탐지 문자열 노출');
  // 분류 code는 남긴다(운영 통계용).
  assert.equal(serialized.includes('external_contact'), true);
  assert.equal(serialized.includes('verification_code'), true);
});

test('rate limit 상수는 명세와 같다', () => {
  assert.equal(MESSAGE_COOLDOWN_MS, 1000);
  assert.equal(REPORT_COOLDOWN_MS, 5 * 1000);
});
