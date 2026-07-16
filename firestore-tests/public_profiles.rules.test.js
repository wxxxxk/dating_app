'use strict';

// Firestore 보안 규칙 동작 테스트 (Phase 0-B).
//
// Firestore Emulator에서 실제 요청 허용/거부를 검사한다. 실제 Firebase
// 프로젝트 데이터에는 접근하지 않는다(demo-* projectId 사용). 규칙은
// ../firestore.rules 파일을 그대로 읽어 emulator에 적용한다.

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
  setDoc,
  getDoc,
  updateDoc,
  deleteDoc,
  deleteField,
  Timestamp,
  setLogLevel,
} = require('firebase/firestore');

const OWNER = 'ownerUid';
const OTHER = 'otherUid';

let testEnv;

/** 정상 owner-editable 공개 프로필 payload(매번 새 Timestamp). */
function validOwnerProfile(overrides = {}) {
  return {
    displayName: '지민',
    age: 30,
    gender: 'female',
    bio: '안녕하세요',
    photoUrls: ['https://example.com/a.jpg'],
    height: 165,
    religion: 'none',
    smoking: 'non_smoker',
    drinking: 'socially',
    jobCategory: 'design',
    jobTitle: 'UX 디자이너',
    education: 'university',
    mbti: 'ENFP',
    interests: ['coffee'],
    personalityTags: ['warm'],
    idealTags: ['kind'],
    relationshipGoal: 'serious_relationship',
    coarseLocation: { lat: 37.57, lng: 126.98, updatedAt: Timestamp.now() },
    ...overrides,
  };
}

/** owner 필드 + server-managed 필드를 포함한 완전한 기존 공개 문서. */
function fullExistingPublicDoc() {
  return {
    ...validOwnerProfile(),
    verifications: { email: true, phone: false, photo: false },
    rankingBoostUntil: Timestamp.fromDate(new Date('2030-01-01T00:00:00Z')),
    profileUpdatedAt: Timestamp.now(),
    schemaVersion: 1,
  };
}

function ownerDb() {
  return testEnv.authenticatedContext(OWNER).firestore();
}
function otherDb() {
  return testEnv.authenticatedContext(OTHER).firestore();
}
function anonDb() {
  return testEnv.unauthenticatedContext().firestore();
}

async function seedPublic(uid, data) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), 'publicProfiles', uid), data);
  });
}
async function seedUser(uid, data) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), 'users', uid), data);
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

// ── 읽기 ──────────────────────────────────────────────────────────────────

test('1. 비로그인 사용자의 publicProfiles read 거부', async () => {
  await seedPublic(OWNER, validOwnerProfile());
  await assertFails(getDoc(doc(anonDb(), 'publicProfiles', OWNER)));
});

test('2. 로그인한 다른 사용자의 publicProfiles read 허용', async () => {
  await seedPublic(OWNER, validOwnerProfile());
  await assertSucceeds(getDoc(doc(otherDb(), 'publicProfiles', OWNER)));
});

test('3. 본인의 공개 프로필 read 허용', async () => {
  await seedPublic(OWNER, validOwnerProfile());
  await assertSucceeds(getDoc(doc(ownerDb(), 'publicProfiles', OWNER)));
});

// ── create ─────────────────────────────────────────────────────────────────

test('4. 본인이 정상 owner-editable 문서를 create', async () => {
  await assertSucceeds(
    setDoc(doc(ownerDb(), 'publicProfiles', OWNER), validOwnerProfile()),
  );
});

test('5. 다른 uid 경로에는 create 불가', async () => {
  await assertFails(
    setDoc(doc(ownerDb(), 'publicProfiles', OTHER), validOwnerProfile()),
  );
});

test('6. 비로그인은 create 불가', async () => {
  await assertFails(
    setDoc(doc(anonDb(), 'publicProfiles', OWNER), validOwnerProfile()),
  );
});

test('7. uid 본문 key를 포함하면 거부', async () => {
  await assertFails(
    setDoc(
      doc(ownerDb(), 'publicProfiles', OWNER),
      validOwnerProfile({ uid: OWNER }),
    ),
  );
});

test('8. verifications를 포함하면 거부', async () => {
  await assertFails(
    setDoc(
      doc(ownerDb(), 'publicProfiles', OWNER),
      validOwnerProfile({ verifications: { email: true } }),
    ),
  );
});

test('9. rankingBoostUntil을 포함하면 거부', async () => {
  await assertFails(
    setDoc(
      doc(ownerDb(), 'publicProfiles', OWNER),
      validOwnerProfile({ rankingBoostUntil: Timestamp.now() }),
    ),
  );
});

test('10. profileUpdatedAt을 포함하면 거부', async () => {
  await assertFails(
    setDoc(
      doc(ownerDb(), 'publicProfiles', OWNER),
      validOwnerProfile({ profileUpdatedAt: Timestamp.now() }),
    ),
  );
});

test('11. schemaVersion을 포함하면 거부', async () => {
  await assertFails(
    setDoc(
      doc(ownerDb(), 'publicProfiles', OWNER),
      validOwnerProfile({ schemaVersion: 1 }),
    ),
  );
});

test('12. jelly 같은 알 수 없는 key를 포함하면 거부', async () => {
  await assertFails(
    setDoc(
      doc(ownerDb(), 'publicProfiles', OWNER),
      validOwnerProfile({ jelly: 999 }),
    ),
  );
});

test('13. coarseLocation만 포함하는 부분 문서 create 허용', async () => {
  await assertSucceeds(
    setDoc(doc(ownerDb(), 'publicProfiles', OWNER), {
      coarseLocation: { lat: 37.57, lng: 126.98, updatedAt: Timestamp.now() },
    }),
  );
});

test('14. 정상 owner 프로필 전체 payload create 허용', async () => {
  await assertSucceeds(
    setDoc(doc(ownerDb(), 'publicProfiles', OWNER), validOwnerProfile()),
  );
});

// ── update ─────────────────────────────────────────────────────────────────

test('15. 본인이 owner-editable 필드를 update', async () => {
  await seedPublic(OWNER, fullExistingPublicDoc());
  await assertSucceeds(
    updateDoc(doc(ownerDb(), 'publicProfiles', OWNER), { displayName: '수정' }),
  );
});

test('16. 다른 사용자는 owner-editable 필드도 update 불가', async () => {
  await seedPublic(OWNER, fullExistingPublicDoc());
  await assertFails(
    updateDoc(doc(otherDb(), 'publicProfiles', OWNER), { displayName: '수정' }),
  );
});

test('17. 본인이 verifications를 변경하려 하면 거부', async () => {
  await seedPublic(OWNER, fullExistingPublicDoc());
  await assertFails(
    updateDoc(doc(ownerDb(), 'publicProfiles', OWNER), {
      verifications: { email: true, phone: true, photo: true },
    }),
  );
});

test('18. 본인이 rankingBoostUntil을 변경하려 하면 거부', async () => {
  await seedPublic(OWNER, fullExistingPublicDoc());
  await assertFails(
    updateDoc(doc(ownerDb(), 'publicProfiles', OWNER), {
      rankingBoostUntil: Timestamp.now(),
    }),
  );
});

test('19. 본인이 schemaVersion을 변경하려 하면 거부', async () => {
  await seedPublic(OWNER, fullExistingPublicDoc());
  await assertFails(
    updateDoc(doc(ownerDb(), 'publicProfiles', OWNER), { schemaVersion: 2 }),
  );
});

test('20. 본인이 알 수 없는 key를 추가하려 하면 거부', async () => {
  await seedPublic(OWNER, fullExistingPublicDoc());
  await assertFails(
    updateDoc(doc(ownerDb(), 'publicProfiles', OWNER), { jelly: 999 }),
  );
});

test('21. server-managed 필드를 유지한 채 owner 필드만 수정하면 허용', async () => {
  await seedPublic(OWNER, fullExistingPublicDoc());
  await assertSucceeds(
    updateDoc(doc(ownerDb(), 'publicProfiles', OWNER), {
      displayName: '수정',
      bio: '새 소개',
    }),
  );
});

test('22. 기존 server-managed 필드를 삭제하려 하면 거부', async () => {
  await seedPublic(OWNER, fullExistingPublicDoc());
  await assertFails(
    updateDoc(doc(ownerDb(), 'publicProfiles', OWNER), {
      verifications: deleteField(),
    }),
  );
});

test('23. server-managed 필드 유지 채 displayName만 변경하면 허용', async () => {
  await seedPublic(OWNER, fullExistingPublicDoc());
  await assertSucceeds(
    updateDoc(doc(ownerDb(), 'publicProfiles', OWNER), { displayName: '지민2' }),
  );
});

// ── delete ─────────────────────────────────────────────────────────────────

test('24. 본인도 공개 프로필 delete 불가', async () => {
  await seedPublic(OWNER, validOwnerProfile());
  await assertFails(deleteDoc(doc(ownerDb(), 'publicProfiles', OWNER)));
});

test('25. 다른 사용자도 delete 불가', async () => {
  await seedPublic(OWNER, validOwnerProfile());
  await assertFails(deleteDoc(doc(otherDb(), 'publicProfiles', OWNER)));
});

// ── 타입과 범위 ──────────────────────────────────────────────────────────────

test('26. age = -1 거부', async () => {
  await assertFails(
    setDoc(
      doc(ownerDb(), 'publicProfiles', OWNER),
      validOwnerProfile({ age: -1 }),
    ),
  );
});

test('27. age = 131 거부', async () => {
  await assertFails(
    setDoc(
      doc(ownerDb(), 'publicProfiles', OWNER),
      validOwnerProfile({ age: 131 }),
    ),
  );
});

test('28. age가 문자열이면 거부', async () => {
  await assertFails(
    setDoc(
      doc(ownerDb(), 'publicProfiles', OWNER),
      validOwnerProfile({ age: '30' }),
    ),
  );
});

test('29. photoUrls가 list가 아니면 거부', async () => {
  await assertFails(
    setDoc(
      doc(ownerDb(), 'publicProfiles', OWNER),
      validOwnerProfile({ photoUrls: 'a' }),
    ),
  );
});

test('30. photoUrls가 5개면 거부', async () => {
  await assertFails(
    setDoc(
      doc(ownerDb(), 'publicProfiles', OWNER),
      validOwnerProfile({ photoUrls: ['a', 'b', 'c', 'd', 'e'] }),
    ),
  );
});

test('31. interests가 9개면 거부', async () => {
  await assertFails(
    setDoc(
      doc(ownerDb(), 'publicProfiles', OWNER),
      validOwnerProfile({
        interests: ['1', '2', '3', '4', '5', '6', '7', '8', '9'],
      }),
    ),
  );
});

test('32. 잘못된 gender 거부', async () => {
  await assertFails(
    setDoc(
      doc(ownerDb(), 'publicProfiles', OWNER),
      validOwnerProfile({ gender: 'robot' }),
    ),
  );
});

test('33. 정상 gender 허용', async () => {
  await assertSucceeds(
    setDoc(
      doc(ownerDb(), 'publicProfiles', OWNER),
      validOwnerProfile({ gender: 'male' }),
    ),
  );
});

test('34. coarseLocation.lat 범위 밖 거부', async () => {
  await assertFails(
    setDoc(
      doc(ownerDb(), 'publicProfiles', OWNER),
      validOwnerProfile({
        coarseLocation: { lat: -91, lng: 0, updatedAt: Timestamp.now() },
      }),
    ),
  );
});

test('35. coarseLocation.lng 범위 밖 거부', async () => {
  await assertFails(
    setDoc(
      doc(ownerDb(), 'publicProfiles', OWNER),
      validOwnerProfile({
        coarseLocation: { lat: 0, lng: 181, updatedAt: Timestamp.now() },
      }),
    ),
  );
});

test('36. coarseLocation.updatedAt이 timestamp가 아니면 거부', async () => {
  await assertFails(
    setDoc(
      doc(ownerDb(), 'publicProfiles', OWNER),
      validOwnerProfile({
        coarseLocation: { lat: 37.5, lng: 127.0, updatedAt: 'not-ts' },
      }),
    ),
  );
});

// ── coarseLocation 구조 ─────────────────────────────────────────────────────

test('37. {lat}만 있는 Map 거부', async () => {
  await assertFails(
    setDoc(
      doc(ownerDb(), 'publicProfiles', OWNER),
      validOwnerProfile({ coarseLocation: { lat: 37.57 } }),
    ),
  );
});

test('38. {lat, lng}만 있는 Map 거부', async () => {
  await assertFails(
    setDoc(
      doc(ownerDb(), 'publicProfiles', OWNER),
      validOwnerProfile({ coarseLocation: { lat: 37.57, lng: 126.98 } }),
    ),
  );
});

test('39. {updatedAt}만 있는 Map 거부', async () => {
  await assertFails(
    setDoc(
      doc(ownerDb(), 'publicProfiles', OWNER),
      validOwnerProfile({ coarseLocation: { updatedAt: Timestamp.now() } }),
    ),
  );
});

test('40. label 같은 추가 key가 있으면 거부', async () => {
  await assertFails(
    setDoc(
      doc(ownerDb(), 'publicProfiles', OWNER),
      validOwnerProfile({
        coarseLocation: {
          lat: 37.57,
          lng: 126.98,
          updatedAt: Timestamp.now(),
          label: '서울',
        },
      }),
    ),
  );
});

test('41. lat/lng/updatedAt이 모두 정상인 Map 허용', async () => {
  await assertSucceeds(
    setDoc(
      doc(ownerDb(), 'publicProfiles', OWNER),
      validOwnerProfile({
        coarseLocation: { lat: 37.57, lng: 126.98, updatedAt: Timestamp.now() },
      }),
    ),
  );
});

test('42. coarseLocation: null 허용', async () => {
  await assertSucceeds(
    setDoc(
      doc(ownerDb(), 'publicProfiles', OWNER),
      validOwnerProfile({ coarseLocation: null }),
    ),
  );
});

// ── 기존 users/{uid} 전환 규칙 회귀 ──────────────────────────────────────────
// TRANSITIONAL: Phase 0-B read 전환 및 backfill 완료 전까지만 유지.
// 구버전 앱 호환을 위해 users/{uid} 타인 read를 아직 닫지 않는다.

test('TRANSITIONAL: 인증된 다른 사용자의 users read 허용', async () => {
  await seedUser(OWNER, { displayName: '지민', bio: 'hi' });
  await assertSucceeds(getDoc(doc(otherDb(), 'users', OWNER)));
});

test('TRANSITIONAL: 비로그인 users read 거부', async () => {
  await seedUser(OWNER, { displayName: '지민', bio: 'hi' });
  await assertFails(getDoc(doc(anonDb(), 'users', OWNER)));
});

test('TRANSITIONAL: 본인 users write 허용', async () => {
  await seedUser(OWNER, { displayName: '지민', bio: 'hi' });
  await assertSucceeds(
    updateDoc(doc(ownerDb(), 'users', OWNER), { bio: '새 소개' }),
  );
});
