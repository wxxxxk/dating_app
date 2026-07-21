'use strict';

// Firestore 보안 규칙 테스트 — 파티 그룹 채팅 (Phase 4-5).
//
// 대화는 **승인된 active 멤버**에게만 열린다. 권한의 source of truth는
// members 서브컬렉션이며, partyMemberships mirror로는 열리지 않는다.
// 파티가 취소되면 즉시 닫히고, client write와 서버 전용 컬렉션은 전면
// 차단되는지 검증한다.

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
  limit,
  getDoc,
  getDocs,
  setDoc,
  updateDoc,
  deleteDoc,
  Timestamp,
  setLogLevel,
} = require('firebase/firestore');

const HOST = 'hostA';
const MEMBER = 'memberA';
const PENDING = 'pendingA';
const STRANGER = 'strangerA';

const PARTY = 'party1';

let testEnv;

function snapshotOf(uid, name = '작성자') {
  return {
    uid,
    displayName: name,
    photoUrl: 'https://example.test/p.jpg',
    photoVerified: false,
    workVerified: false,
    schoolVerified: false,
  };
}

function partyDoc(overrides = {}) {
  return {
    hostUid: HOST,
    hostSnapshot: snapshotOf(HOST, '호스트'),
    title: '한강 산책 같이 해요',
    description: '가볍게 걷고 커피 마셔요.',
    category: 'walk',
    area: 'seoul',
    startAt: Timestamp.fromMillis(Date.now() + 24 * 60 * 60 * 1000),
    maxParticipants: 4,
    participantCount: 2,
    status: 'open',
    visibility: 'authenticated',
    createdAt: Timestamp.now(),
    updatedAt: Timestamp.now(),
    schemaVersion: 1,
    ...overrides,
  };
}

function memberDoc(uid, overrides = {}) {
  return {
    uid,
    role: uid === HOST ? 'host' : 'member',
    status: 'active',
    joinedAt: Timestamp.now(),
    updatedAt: Timestamp.now(),
    schemaVersion: 1,
    ...overrides,
  };
}

function messageDoc(senderUid, overrides = {}) {
  return {
    senderUid,
    senderSnapshot: snapshotOf(senderUid),
    text: '오늘 3시에 만나요',
    status: 'active',
    createdAt: Timestamp.now(),
    updatedAt: Timestamp.now(),
    schemaVersion: 1,
    ...overrides,
  };
}

function dbOf(uid) {
  return testEnv.authenticatedContext(uid).firestore();
}
function anonDb() {
  return testEnv.unauthenticatedContext().firestore();
}

function messagesCol(db, partyId = PARTY) {
  return collection(db, 'communityParties', partyId, 'groupMessages');
}
function messageRef(db, id, partyId = PARTY) {
  return doc(db, 'communityParties', partyId, 'groupMessages', id);
}

/** 화면이 실제로 쓰는 쿼리와 같은 형태. */
function activeMessagesQuery(db, partyId = PARTY) {
  return query(
    messagesCol(db, partyId),
    where('status', '==', 'active'),
    orderBy('createdAt'),
    limit(100),
  );
}

async function seed(writer) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await writer(ctx.firestore());
  });
}

/** open 파티 + host/member + 메시지 두 건 + pending 요청자. */
async function seedChat(partyOverrides = {}, extra = null) {
  await seed(async (db) => {
    await setDoc(
      doc(db, 'communityParties', PARTY),
      partyDoc(partyOverrides),
    );
    await setDoc(
      doc(db, 'communityParties', PARTY, 'members', HOST),
      memberDoc(HOST),
    );
    await setDoc(
      doc(db, 'communityParties', PARTY, 'members', MEMBER),
      memberDoc(MEMBER),
    );
    await setDoc(
      doc(db, 'communityParties', PARTY, 'joinRequests', PENDING),
      {
        requesterUid: PENDING,
        requesterSnapshot: snapshotOf(PENDING, '대기자'),
        message: '',
        status: 'pending',
        createdAt: Timestamp.now(),
        updatedAt: Timestamp.now(),
        schemaVersion: 1,
      },
    );
    await setDoc(messageRef(db, 'm1'), messageDoc(HOST));
    await setDoc(messageRef(db, 'm2'), messageDoc(MEMBER));
    if (extra) await extra(db);
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

// ── 읽기 자격 ──────────────────────────────────────────────────────────────

test('1~2. active member와 host는 대화를 읽을 수 있다', async () => {
  await seedChat();

  await assertSucceeds(getDocs(activeMessagesQuery(dbOf(MEMBER))));
  await assertSucceeds(getDocs(activeMessagesQuery(dbOf(HOST))));
  await assertSucceeds(getDoc(messageRef(dbOf(MEMBER), 'm1')));
  await assertSucceeds(getDoc(messageRef(dbOf(HOST), 'm2')));
});

test('3~4. 비멤버·승인 대기 요청자·비로그인은 읽을 수 없다', async () => {
  await seedChat();

  // 3. 무관한 사용자
  await assertFails(getDocs(activeMessagesQuery(dbOf(STRANGER))));
  await assertFails(getDoc(messageRef(dbOf(STRANGER), 'm1')));
  // 4. 승인 대기 요청자 — joinRequests 문서만 있고 members 문서가 없다.
  await assertFails(getDocs(activeMessagesQuery(dbOf(PENDING))));
  await assertFails(getDoc(messageRef(dbOf(PENDING), 'm1')));
  // 비로그인
  await assertFails(getDocs(activeMessagesQuery(anonDb())));
  await assertFails(getDoc(messageRef(anonDb(), 'm1')));
});

test('4b. partyMemberships mirror만 있으면 열리지 않는다', async () => {
  // 권한의 source of truth는 members 서브컬렉션이다.
  await seedChat({}, async (db) => {
    await setDoc(doc(db, 'users', STRANGER, 'partyMemberships', PARTY), {
      partyId: PARTY,
      role: 'member',
      state: 'active',
      updatedAt: Timestamp.now(),
      schemaVersion: 1,
    });
  });

  await assertFails(getDocs(activeMessagesQuery(dbOf(STRANGER))));
  await assertFails(getDoc(messageRef(dbOf(STRANGER), 'm1')));
});

test('4c. member 문서의 status/schema가 다르면 읽을 수 없다', async () => {
  for (const override of [{ status: 'left' }, { schemaVersion: 2 }]) {
    await testEnv.clearFirestore();
    await seedChat({}, async (db) => {
      await setDoc(
        doc(db, 'communityParties', PARTY, 'members', MEMBER),
        memberDoc(MEMBER, override),
      );
    });

    await assertFails(getDocs(activeMessagesQuery(dbOf(MEMBER))));
    await assertFails(getDoc(messageRef(dbOf(MEMBER), 'm1')));
  }
});

test('5. 취소된 파티의 대화는 즉시 읽을 수 없다', async () => {
  await seedChat({ status: 'cancelled' });

  await assertFails(getDocs(activeMessagesQuery(dbOf(MEMBER))));
  await assertFails(getDocs(activeMessagesQuery(dbOf(HOST))));
  await assertFails(getDoc(messageRef(dbOf(MEMBER), 'm1')));
});

test('5b. 존재하지 않는 파티의 메시지는 읽을 수 없다', async () => {
  await seed(async (db) => {
    // 부모 파티 없이 하위 문서만 존재하는 상태.
    await setDoc(messageRef(db, 'm1', 'ghostParty'), messageDoc(MEMBER));
    await setDoc(
      doc(db, 'communityParties', 'ghostParty', 'members', MEMBER),
      memberDoc(MEMBER),
    );
  });

  await assertFails(getDoc(messageRef(dbOf(MEMBER), 'm1', 'ghostParty')));
  await assertFails(getDocs(activeMessagesQuery(dbOf(MEMBER), 'ghostParty')));
});

// ── 쿼리 제약 ──────────────────────────────────────────────────────────────

test('6. status 필터가 없는 쿼리는 거부된다', async () => {
  await seedChat();
  const db = dbOf(MEMBER);

  await assertFails(getDocs(messagesCol(db)));
  await assertFails(getDocs(query(messagesCol(db), orderBy('createdAt'))));
  // removed까지 훑는 조회
  await assertFails(
    getDocs(query(messagesCol(db), where('status', 'in', ['active', 'removed']))),
  );
  await assertFails(
    getDocs(query(messagesCol(db), where('status', '==', 'removed'))),
  );
});

test('7. removed 메시지는 get으로도 읽을 수 없다', async () => {
  await seedChat({}, async (db) => {
    await setDoc(messageRef(db, 'gone'), messageDoc(HOST, { status: 'removed' }));
  });

  await assertFails(getDoc(messageRef(dbOf(MEMBER), 'gone')));
  // 본인이 지운 메시지도 마찬가지다.
  await seed(async (db) => {
    await setDoc(
      messageRef(db, 'mineGone'),
      messageDoc(MEMBER, { status: 'removed' }),
    );
  });
  await assertFails(getDoc(messageRef(dbOf(MEMBER), 'mineGone')));

  // active 목록에는 removed가 섞이지 않는다.
  const snap = await getDocs(activeMessagesQuery(dbOf(MEMBER)));
  for (const d of snap.docs) {
    if (d.data().status !== 'active') {
      throw new Error('removed 메시지가 목록에 포함됐다');
    }
  }
});

// ── 형태 검증 ──────────────────────────────────────────────────────────────

test('8. 형태가 깨진 메시지는 get으로 읽을 수 없다', async () => {
  const noStatusField = messageDoc(HOST);
  delete noStatusField.schemaVersion;

  const fatSnapshot = messageDoc(HOST);
  fatSnapshot.senderSnapshot = {
    ...snapshotOf(HOST),
    phoneNumber: '010-1234-5678',
  };

  await seedChat({}, async (db) => {
    await setDoc(messageRef(db, 'noSchema'), noStatusField);
    await setDoc(
      messageRef(db, 'badSchema'),
      messageDoc(HOST, { schemaVersion: 2 }),
    );
    // 작성자 snapshot이 senderUid와 어긋남
    await setDoc(
      messageRef(db, 'spoofed'),
      messageDoc(HOST, { senderSnapshot: snapshotOf(STRANGER) }),
    );
    // snapshot에 비공개 필드가 섞임
    await setDoc(messageRef(db, 'fatSnapshot'), fatSnapshot);
    // allowlist 밖의 unknown field
    await setDoc(messageRef(db, 'unknownField'), {
      ...messageDoc(HOST),
      readBy: [MEMBER],
    });
    // 본문 길이 위반
    await setDoc(
      messageRef(db, 'tooLong'),
      messageDoc(HOST, { text: 'ㄱ'.repeat(1001) }),
    );
    await setDoc(messageRef(db, 'empty'), messageDoc(HOST, { text: '' }));
  });

  for (const id of [
    'noSchema',
    'badSchema',
    'spoofed',
    'fatSnapshot',
    'unknownField',
    'tooLong',
    'empty',
  ]) {
    await assertFails(getDoc(messageRef(dbOf(MEMBER), id)), id);
  }
});

// ── client write ───────────────────────────────────────────────────────────

test('9. 클라이언트는 메시지를 만들거나 고치거나 지울 수 없다', async () => {
  await seedChat();

  // 멤버 본인 명의라도 직접 쓸 수 없다(서버 callable 전용).
  await assertFails(
    setDoc(messageRef(dbOf(MEMBER), 'new1'), messageDoc(MEMBER)),
  );
  await assertFails(
    setDoc(messageRef(dbOf(HOST), 'new2'), messageDoc(HOST)),
  );
  // 본문 수정·상태 조작
  await assertFails(
    updateDoc(messageRef(dbOf(MEMBER), 'm2'), { text: '바꿔치기' }),
  );
  await assertFails(
    updateDoc(messageRef(dbOf(MEMBER), 'm2'), { status: 'removed' }),
  );
  // 남의 메시지 지우기
  await assertFails(deleteDoc(messageRef(dbOf(MEMBER), 'm1')));
  // 본인 메시지도 hard delete는 막힌다(soft delete는 서버가 한다).
  await assertFails(deleteDoc(messageRef(dbOf(MEMBER), 'm2')));
  await assertFails(deleteDoc(messageRef(dbOf(HOST), 'm1')));
});

// ── 서버 전용 컬렉션 ───────────────────────────────────────────────────────

test('10. partyMessageReports·partyMessageWriteLimits는 접근할 수 없다', async () => {
  await seedChat({}, async (db) => {
    await setDoc(doc(db, 'partyMessageReports', 'r1'), {
      reporterUid: MEMBER,
      reportedUid: HOST,
      partyId: PARTY,
      messageId: 'm1',
      reason: 'abusive_language',
      createdAt: Timestamp.now(),
      schemaVersion: 1,
    });
    await setDoc(doc(db, 'partyMessageWriteLimits', MEMBER), {
      lastMessageAt: Timestamp.now(),
      updatedAt: Timestamp.now(),
      schemaVersion: 1,
    });
  });

  for (const db of [dbOf(MEMBER), dbOf(HOST), dbOf(STRANGER), anonDb()]) {
    await assertFails(getDoc(doc(db, 'partyMessageReports', 'r1')));
    await assertFails(getDocs(collection(db, 'partyMessageReports')));
    await assertFails(getDoc(doc(db, 'partyMessageWriteLimits', MEMBER)));
    await assertFails(getDocs(collection(db, 'partyMessageWriteLimits')));
  }

  // 본인 uid 문서라도 쓰거나 지울 수 없다(rate limit 우회 방지).
  await assertFails(
    setDoc(doc(dbOf(MEMBER), 'partyMessageWriteLimits', MEMBER), {
      lastMessageAt: Timestamp.now(),
    }),
  );
  await assertFails(
    deleteDoc(doc(dbOf(MEMBER), 'partyMessageWriteLimits', MEMBER)),
  );
  await assertFails(
    setDoc(doc(dbOf(MEMBER), 'partyMessageReports', 'r2'), { reason: 'other' }),
  );
});

// ── 기존 파티 규칙 회귀 ────────────────────────────────────────────────────

test('11. 그룹 채팅 추가 후에도 기존 파티 규칙은 그대로다', async () => {
  await seedChat();

  // 파티 문서 read는 여전히 로그인 사용자에게 열려 있다.
  await assertSucceeds(getDoc(doc(dbOf(STRANGER), 'communityParties', PARTY)));
  // 멤버 목록은 호스트만.
  await assertSucceeds(
    getDocs(collection(dbOf(HOST), 'communityParties', PARTY, 'members')),
  );
  await assertFails(
    getDocs(collection(dbOf(MEMBER), 'communityParties', PARTY, 'members')),
  );
  // 참여 요청은 호스트의 pending 조회만.
  await assertSucceeds(
    getDocs(
      query(
        collection(dbOf(HOST), 'communityParties', PARTY, 'joinRequests'),
        where('status', '==', 'pending'),
        orderBy('createdAt'),
      ),
    ),
  );
  await assertFails(
    getDocs(collection(dbOf(MEMBER), 'communityParties', PARTY, 'joinRequests')),
  );
  // 파티 client write는 여전히 전면 차단.
  await assertFails(
    updateDoc(doc(dbOf(HOST), 'communityParties', PARTY), {
      participantCount: 8,
    }),
  );
});
