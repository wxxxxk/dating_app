'use strict';

// Firestore 보안 규칙 테스트 — Party·Square (Phase 4-4A).
//
// 파티 문서는 로그인 사용자의 open/full·authenticated 문서로만 열려 있고,
// 하위 컬렉션(members/joinRequests)은 본인 또는 호스트에게만, 그것도 부모
// 파티가 아직 살아 있을 때만 열린다. client write와 서버 전용 컬렉션은
// 전면 차단되는지 검증한다.

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
  Timestamp,
  setLogLevel,
} = require('firebase/firestore');

const HOST = 'hostA';
const MEMBER = 'memberA';
const REQUESTER = 'requesterA';
const STRANGER = 'strangerA';

const PARTY = 'party1';

let testEnv;

function hostSnapshot(overrides = {}) {
  return {
    uid: HOST,
    displayName: '호스트',
    photoUrl: 'https://example.test/host.jpg',
    photoVerified: true,
    workVerified: false,
    schoolVerified: false,
    ...overrides,
  };
}

function partyDoc(overrides = {}) {
  return {
    hostUid: HOST,
    hostSnapshot: hostSnapshot(),
    title: '한강 산책 같이 해요',
    description: '가볍게 걷고 커피 마셔요.',
    category: 'walk',
    area: 'seoul',
    startAt: Timestamp.fromMillis(Date.now() + 24 * 60 * 60 * 1000),
    maxParticipants: 4,
    participantCount: 1,
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

function joinRequestDoc(uid, overrides = {}) {
  return {
    requesterUid: uid,
    requesterSnapshot: hostSnapshot({ uid, displayName: '요청자' }),
    message: '함께 걷고 싶어요',
    status: 'pending',
    createdAt: Timestamp.now(),
    updatedAt: Timestamp.now(),
    schemaVersion: 1,
    ...overrides,
  };
}

function membershipDoc(partyId, overrides = {}) {
  return {
    partyId,
    role: 'member',
    state: 'active',
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

function partyRef(db, id = PARTY) {
  return doc(db, 'communityParties', id);
}
function memberRef(db, uid, partyId = PARTY) {
  return doc(db, 'communityParties', partyId, 'members', uid);
}
function requestRef(db, uid, partyId = PARTY) {
  return doc(db, 'communityParties', partyId, 'joinRequests', uid);
}
function membershipRef(db, uid, partyId = PARTY) {
  return doc(db, 'users', uid, 'partyMemberships', partyId);
}

async function seed(writer) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await writer(ctx.firestore());
  });
}

/** open 파티 + host/member 문서 + 대기 중 요청 하나. */
async function seedActiveParty(partyOverrides = {}) {
  await seed(async (db) => {
    await setDoc(partyRef(db), partyDoc(partyOverrides));
    await setDoc(memberRef(db, HOST), memberDoc(HOST));
    await setDoc(memberRef(db, MEMBER), memberDoc(MEMBER));
    await setDoc(requestRef(db, REQUESTER), joinRequestDoc(REQUESTER));
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

// ── A-2. 파티 문서 ─────────────────────────────────────────────────────────

test('A-2 1~3. open/full 파티는 로그인 사용자만 get할 수 있다', async () => {
  await seed(async (db) => {
    await setDoc(partyRef(db, 'openParty'), partyDoc());
    await setDoc(
      partyRef(db, 'fullParty'),
      partyDoc({ status: 'full', participantCount: 4 }),
    );
  });

  await assertSucceeds(getDoc(partyRef(dbOf(STRANGER), 'openParty')));
  await assertSucceeds(getDoc(partyRef(dbOf(STRANGER), 'fullParty')));
  await assertFails(getDoc(partyRef(anonDb(), 'openParty')));
});

test('A-2 4. cancelled 파티는 get할 수 없다', async () => {
  await seed(async (db) => {
    await setDoc(partyRef(db), partyDoc({ status: 'cancelled' }));
  });
  await assertFails(getDoc(partyRef(dbOf(STRANGER))));
  await assertFails(getDoc(partyRef(dbOf(HOST))));
});

test('A-2 5. Square 화면이 쓰는 쿼리는 통과한다', async () => {
  await seedActiveParty();

  await assertSucceeds(
    getDocs(
      query(
        collection(dbOf(STRANGER), 'communityParties'),
        where('visibility', '==', 'authenticated'),
        where('status', 'in', ['open', 'full']),
        where('startAt', '>=', Timestamp.now()),
        orderBy('startAt'),
      ),
    ),
  );
});

test('A-2 6~7. status/visibility 필터가 없는 쿼리는 거부된다', async () => {
  await seedActiveParty();
  const db = dbOf(STRANGER);

  // 6. 전체 훑기
  await assertFails(getDocs(collection(db, 'communityParties')));

  // 6. visibility만 있고 status가 없음
  await assertFails(
    getDocs(
      query(
        collection(db, 'communityParties'),
        where('visibility', '==', 'authenticated'),
      ),
    ),
  );

  // 7. status만 있고 visibility가 없음
  await assertFails(
    getDocs(
      query(
        collection(db, 'communityParties'),
        where('status', 'in', ['open', 'full']),
      ),
    ),
  );

  // cancelled를 포함한 status 조회도 거부된다.
  await assertFails(
    getDocs(
      query(
        collection(db, 'communityParties'),
        where('visibility', '==', 'authenticated'),
        where('status', 'in', ['open', 'full', 'cancelled']),
      ),
    ),
  );
});

test('A-2 8~10. malformed·unknown field·비공개 프로필 필드는 get할 수 없다', async () => {
  const missing = partyDoc();
  delete missing.description;

  await seed(async (db) => {
    // 8. 필수 필드 누락 / 타입 오류
    await setDoc(partyRef(db, 'missingField'), missing);
    await setDoc(
      partyRef(db, 'badStartAt'),
      partyDoc({ startAt: '2026-08-01' }),
    );
    await setDoc(
      partyRef(db, 'badSchema'),
      partyDoc({ schemaVersion: 2 }),
    );
    // 9. allowlist 밖의 unknown field
    await setDoc(
      partyRef(db, 'unknownField'),
      { ...partyDoc(), inviteCode: 'SECRET' },
    );
    // 10. 정확 주소·연락처 같은 비공개 정보를 얹은 문서
    await setDoc(
      partyRef(db, 'privateField'),
      { ...partyDoc(), address: '서울시 강남구 ...', hostPhone: '010-1234-5678' },
    );
  });

  for (const id of [
    'missingField',
    'badStartAt',
    'badSchema',
    'unknownField',
    'privateField',
  ]) {
    await assertFails(getDoc(partyRef(dbOf(STRANGER), id)), id);
  }
});

test('A-2 11. hostSnapshot.uid가 hostUid와 다르면 거부된다', async () => {
  await seed(async (db) => {
    await setDoc(
      partyRef(db, 'spoofed'),
      partyDoc({ hostSnapshot: hostSnapshot({ uid: STRANGER }) }),
    );
    // snapshot에 비공개 필드를 얹은 경우도 거부된다.
    await setDoc(
      partyRef(db, 'fatSnapshot'),
      partyDoc({
        hostSnapshot: { ...hostSnapshot(), birthDate: '1999-01-01' },
      }),
    );
  });

  await assertFails(getDoc(partyRef(dbOf(STRANGER), 'spoofed')));
  await assertFails(getDoc(partyRef(dbOf(STRANGER), 'fatSnapshot')));
});

test('A-2 12~13. participantCount 범위를 벗어나면 거부된다', async () => {
  await seed(async (db) => {
    await setDoc(partyRef(db, 'zero'), partyDoc({ participantCount: 0 }));
    await setDoc(partyRef(db, 'negative'), partyDoc({ participantCount: -1 }));
    await setDoc(
      partyRef(db, 'overflow'),
      partyDoc({ participantCount: 5, maxParticipants: 4 }),
    );
    await setDoc(
      partyRef(db, 'badCapacity'),
      partyDoc({ maxParticipants: 20, participantCount: 9 }),
    );
  });

  for (const id of ['zero', 'negative', 'overflow', 'badCapacity']) {
    await assertFails(getDoc(partyRef(dbOf(STRANGER), id)), id);
  }
});

test('A-2 14~15. category·area allowlist 밖의 값은 거부된다', async () => {
  await seed(async (db) => {
    await setDoc(partyRef(db, 'badCategory'), partyDoc({ category: 'party' }));
    await setDoc(
      partyRef(db, 'badArea'),
      partyDoc({ area: '서울시 강남구 테헤란로 1' }),
    );
    // allowlist 안의 값은 통과한다(회귀).
    await setDoc(
      partyRef(db, 'okOnline'),
      partyDoc({ category: 'study', area: 'online' }),
    );
  });

  await assertFails(getDoc(partyRef(dbOf(STRANGER), 'badCategory')));
  await assertFails(getDoc(partyRef(dbOf(STRANGER), 'badArea')));
  await assertSucceeds(getDoc(partyRef(dbOf(STRANGER), 'okOnline')));
});

test('A-2 16~18. 클라이언트는 파티를 만들거나 고치거나 지울 수 없다', async () => {
  await seedActiveParty();

  // 16. create — 호스트 본인 명의라도 막힌다.
  await assertFails(
    setDoc(partyRef(dbOf(HOST), 'newParty'), partyDoc()),
  );
  // 17. update — 정원·상태·참가자 수 조작 시도
  await assertFails(
    updateDoc(partyRef(dbOf(HOST)), { participantCount: 8 }),
  );
  await assertFails(updateDoc(partyRef(dbOf(HOST)), { status: 'open' }));
  await assertFails(
    updateDoc(partyRef(dbOf(STRANGER)), { maxParticipants: 8 }),
  );
  // 18. delete
  await assertFails(deleteDoc(partyRef(dbOf(HOST))));
});

// ── A-3. partyMemberships mirror ───────────────────────────────────────────

test('A-3 1~2. 본인 membership은 단일 get과 목록 조회가 된다', async () => {
  await seed(async (db) => {
    await setDoc(membershipRef(db, MEMBER), membershipDoc(PARTY));
    await setDoc(
      membershipRef(db, MEMBER, 'party2'),
      membershipDoc('party2', { state: 'pending' }),
    );
  });

  await assertSucceeds(getDoc(membershipRef(dbOf(MEMBER), MEMBER)));
  // 내 파티 화면이 쓰는 쿼리(state 필터 없이 updatedAt 정렬).
  await assertSucceeds(
    getDocs(
      query(
        collection(dbOf(MEMBER), 'users', MEMBER, 'partyMemberships'),
        orderBy('updatedAt', 'desc'),
      ),
    ),
  );
});

test('A-3 3~5. 다른 사용자의 membership은 읽을 수 없다', async () => {
  await seed(async (db) => {
    await setDoc(membershipRef(db, MEMBER), membershipDoc(PARTY));
  });

  // 3. 다른 사용자 단일 get — 호스트여도 볼 수 없다.
  await assertFails(getDoc(membershipRef(dbOf(STRANGER), MEMBER)));
  await assertFails(getDoc(membershipRef(dbOf(HOST), MEMBER)));
  // 4. 다른 사용자 목록
  await assertFails(
    getDocs(collection(dbOf(STRANGER), 'users', MEMBER, 'partyMemberships')),
  );
  // 5. 비로그인
  await assertFails(getDoc(membershipRef(anonDb(), MEMBER)));
});

test('A-3 6. client는 membership을 만들거나 고치거나 지울 수 없다', async () => {
  await seed(async (db) => {
    await setDoc(membershipRef(db, MEMBER), membershipDoc(PARTY));
  });

  // 본인 문서라도 write는 서버 전용이다(참여 상태 위조 방지).
  await assertFails(
    setDoc(membershipRef(dbOf(MEMBER), MEMBER, 'party9'), membershipDoc('party9')),
  );
  await assertFails(
    updateDoc(membershipRef(dbOf(MEMBER), MEMBER), { state: 'active' }),
  );
  await assertFails(
    updateDoc(membershipRef(dbOf(MEMBER), MEMBER), { role: 'host' }),
  );
  await assertFails(deleteDoc(membershipRef(dbOf(MEMBER), MEMBER)));
});

// ── A-4. party members ─────────────────────────────────────────────────────

test('A-4 1~3. 본인 member 문서와 호스트의 목록 조회는 허용된다', async () => {
  await seedActiveParty();

  // 1. 본인 문서
  await assertSucceeds(getDoc(memberRef(dbOf(MEMBER), MEMBER)));
  // 2. 호스트가 멤버 문서를 본다
  await assertSucceeds(getDoc(memberRef(dbOf(HOST), MEMBER)));
  // 3. 호스트가 멤버 목록을 본다
  await assertSucceeds(
    getDocs(collection(dbOf(HOST), 'communityParties', PARTY, 'members')),
  );
});

test('A-4 4~7. 일반 멤버·무관한 사용자·비로그인은 참여자를 훑을 수 없다', async () => {
  await seedActiveParty();

  // 4. 일반 멤버가 다른 멤버 문서를 본다
  await assertFails(getDoc(memberRef(dbOf(MEMBER), HOST)));
  // 5. 일반 멤버의 목록 조회
  await assertFails(
    getDocs(collection(dbOf(MEMBER), 'communityParties', PARTY, 'members')),
  );
  // 6. 무관한 사용자
  await assertFails(getDoc(memberRef(dbOf(STRANGER), MEMBER)));
  await assertFails(
    getDocs(collection(dbOf(STRANGER), 'communityParties', PARTY, 'members')),
  );
  // 7. 비로그인
  await assertFails(getDoc(memberRef(anonDb(), MEMBER)));
});

test('A-4 8. 클라이언트는 member 문서를 만들거나 고치거나 지울 수 없다', async () => {
  await seedActiveParty();

  // 스스로를 멤버로 추가하는 시도
  await assertFails(
    setDoc(memberRef(dbOf(STRANGER), STRANGER), memberDoc(STRANGER)),
  );
  await assertFails(
    updateDoc(memberRef(dbOf(MEMBER), MEMBER), { role: 'host' }),
  );
  // 호스트도 직접 멤버를 뺄 수 없다(서버 callable 전용).
  await assertFails(deleteDoc(memberRef(dbOf(HOST), MEMBER)));
});

test('A-4 9. 존재하지 않는 파티의 member는 읽을 수 없다', async () => {
  await seed(async (db) => {
    // 부모 파티 문서 없이 하위 문서만 존재하는 상태.
    await setDoc(memberRef(db, MEMBER, 'ghostParty'), memberDoc(MEMBER));
  });

  await assertFails(getDoc(memberRef(dbOf(MEMBER), MEMBER, 'ghostParty')));
  await assertFails(
    getDocs(collection(dbOf(HOST), 'communityParties', 'ghostParty', 'members')),
  );
});

test('A-4 10. cancelled 파티의 member는 호스트도 읽을 수 없다', async () => {
  await seedActiveParty({ status: 'cancelled' });

  await assertFails(getDoc(memberRef(dbOf(MEMBER), MEMBER)));
  await assertFails(getDoc(memberRef(dbOf(HOST), MEMBER)));
  await assertFails(
    getDocs(collection(dbOf(HOST), 'communityParties', PARTY, 'members')),
  );
});

test('A-4 10b. schema가 다른 파티의 하위 데이터도 열리지 않는다', async () => {
  await seedActiveParty({ schemaVersion: 2 });

  await assertFails(getDoc(memberRef(dbOf(MEMBER), MEMBER)));
  await assertFails(getDoc(requestRef(dbOf(REQUESTER), REQUESTER)));
});

// ── A-5. join requests ─────────────────────────────────────────────────────

test('A-5 1~3. 요청자 본인과 호스트만 요청을 볼 수 있다', async () => {
  await seedActiveParty();

  // 1. 요청자 본인 단일 get
  await assertSucceeds(getDoc(requestRef(dbOf(REQUESTER), REQUESTER)));
  // 2. 호스트 단일 get
  await assertSucceeds(getDoc(requestRef(dbOf(HOST), REQUESTER)));
  // 3. 호스트의 pending 목록 조회(실제 UI 쿼리)
  await assertSucceeds(
    getDocs(
      query(
        collection(dbOf(HOST), 'communityParties', PARTY, 'joinRequests'),
        where('status', '==', 'pending'),
        orderBy('createdAt'),
      ),
    ),
  );
});

test('A-5 4~7. 요청자·일반 멤버·무관한 사용자·비로그인은 목록을 훑을 수 없다', async () => {
  await seedActiveParty();

  const pendingQuery = (db) =>
    query(
      collection(db, 'communityParties', PARTY, 'joinRequests'),
      where('status', '==', 'pending'),
      orderBy('createdAt'),
    );

  // 4. 요청자 본인도 전체 목록은 못 본다(다른 신청자 노출 방지)
  await assertFails(getDocs(pendingQuery(dbOf(REQUESTER))));
  // 5. 일반 멤버
  await assertFails(getDocs(pendingQuery(dbOf(MEMBER))));
  await assertFails(getDoc(requestRef(dbOf(MEMBER), REQUESTER)));
  // 6. 무관한 사용자
  await assertFails(getDocs(pendingQuery(dbOf(STRANGER))));
  await assertFails(getDoc(requestRef(dbOf(STRANGER), REQUESTER)));
  // 7. 비로그인
  await assertFails(getDoc(requestRef(anonDb(), REQUESTER)));
});

test('A-5 8. 클라이언트는 요청을 만들거나 고치거나 지울 수 없다', async () => {
  await seedActiveParty();

  // 스스로 승인 상태를 만드는 시도
  await assertFails(
    setDoc(
      requestRef(dbOf(STRANGER), STRANGER),
      joinRequestDoc(STRANGER, { status: 'approved' }),
    ),
  );
  await assertFails(
    updateDoc(requestRef(dbOf(REQUESTER), REQUESTER), { status: 'approved' }),
  );
  // 호스트도 직접 상태를 바꿀 수 없다(서버 callable 전용).
  await assertFails(
    updateDoc(requestRef(dbOf(HOST), REQUESTER), { status: 'approved' }),
  );
  await assertFails(deleteDoc(requestRef(dbOf(REQUESTER), REQUESTER)));
});

test('A-5 9~10. cancelled·존재하지 않는 파티의 요청은 읽을 수 없다', async () => {
  // 9. cancelled
  await seedActiveParty({ status: 'cancelled' });
  await assertFails(getDoc(requestRef(dbOf(REQUESTER), REQUESTER)));
  await assertFails(getDoc(requestRef(dbOf(HOST), REQUESTER)));

  // 10. 부모 파티 문서 없음
  await seed(async (db) => {
    await setDoc(
      requestRef(db, REQUESTER, 'ghostParty'),
      joinRequestDoc(REQUESTER),
    );
  });
  await assertFails(
    getDoc(requestRef(dbOf(REQUESTER), REQUESTER, 'ghostParty')),
  );
});

test('A-5 11. status 조건이 없는 호스트 목록 조회는 거부된다', async () => {
  await seedActiveParty();
  await seed(async (db) => {
    await setDoc(
      requestRef(db, STRANGER),
      joinRequestDoc(STRANGER, { status: 'rejected' }),
    );
  });

  const requests = collection(
    dbOf(HOST),
    'communityParties',
    PARTY,
    'joinRequests',
  );

  // 필터 없는 전체 조회
  await assertFails(getDocs(requests));
  // pending 이외 상태를 훑는 조회
  await assertFails(
    getDocs(query(requests, where('status', '==', 'rejected'))),
  );
  await assertFails(
    getDocs(query(requests, where('status', 'in', ['pending', 'rejected']))),
  );

  // 요청자 본인의 단일 get은 상태와 무관하게 허용된다(결과 확인용).
  await assertSucceeds(getDoc(requestRef(dbOf(STRANGER), STRANGER)));
});

// ── A-6. 서버 전용 컬렉션 ──────────────────────────────────────────────────

test('A-6. partyReports·partyWriteLimits는 누구도 접근할 수 없다', async () => {
  await seed(async (db) => {
    await setDoc(doc(db, 'partyReports', 'r1'), {
      reporterUid: STRANGER,
      reportedUid: HOST,
      partyId: PARTY,
      reason: 'spam_scam',
      createdAt: Timestamp.now(),
      schemaVersion: 1,
    });
    await setDoc(doc(db, 'partyWriteLimits', STRANGER), {
      lastCreateAt: Timestamp.now(),
      updatedAt: Timestamp.now(),
      schemaVersion: 1,
    });
  });

  for (const db of [dbOf(STRANGER), dbOf(HOST), anonDb()]) {
    await assertFails(getDoc(doc(db, 'partyReports', 'r1')));
    await assertFails(getDocs(collection(db, 'partyReports')));
    await assertFails(getDoc(doc(db, 'partyWriteLimits', STRANGER)));
    await assertFails(getDocs(collection(db, 'partyWriteLimits')));
  }

  // 본인 uid 문서라도 쓰거나 지울 수 없다(rate limit 우회 방지).
  await assertFails(
    setDoc(doc(dbOf(STRANGER), 'partyWriteLimits', STRANGER), {
      lastCreateAt: Timestamp.now(),
    }),
  );
  await assertFails(
    deleteDoc(doc(dbOf(STRANGER), 'partyWriteLimits', STRANGER)),
  );
  await assertFails(
    setDoc(doc(dbOf(STRANGER), 'partyReports', 'r2'), { reason: 'other' }),
  );
});
