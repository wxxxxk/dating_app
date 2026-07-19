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
  arrayUnion,
  serverTimestamp,
  Timestamp,
  setLogLevel,
  writeBatch,
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
function fullExistingPublicDoc(overrides = {}) {
  return {
    ...validOwnerProfile(),
    verifications: { email: false, phone: false, photo: false },
    rankingBoostUntil: Timestamp.fromDate(new Date('2030-01-01T00:00:00Z')),
    profileUpdatedAt: Timestamp.now(),
    schemaVersion: 1,
    ...overrides,
  };
}

function validUserDoc(overrides = {}) {
  return {
    displayName: '지민',
    birthDate: Timestamp.fromDate(new Date('1995-06-15T00:00:00Z')),
    gender: 'female',
    bio: '안녕하세요',
    photoUrls: ['https://example.com/a.jpg'],
    createdAt: Timestamp.now(),
    updatedAt: Timestamp.now(),
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
    verifications: { email: false, phone: false, photo: false },
    discoveryFilter: {
      ageMin: 24,
      ageMax: 38,
      maxDistanceKm: 20,
      gender: 'male',
      relationshipGoal: 'serious_relationship',
    },
    ...overrides,
  };
}

function existingUserDoc(overrides = {}) {
  return {
    ...validUserDoc(),
    jelly: 50,
    boostUntil: Timestamp.fromDate(new Date('2030-01-01T00:00:00Z')),
    likesUnlocked: false,
    fortuneNarrative: { title: 'cached' },
    ...overrides,
  };
}

function ownerDb() {
  return testEnv.authenticatedContext(OWNER).firestore();
}
function emailVerifiedOwnerDb() {
  return testEnv
    .authenticatedContext(OWNER, { email_verified: true })
    .firestore();
}
function phoneVerifiedOwnerDb() {
  return testEnv
    .authenticatedContext(OWNER, { phone_number: '+821012345678' })
    .firestore();
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
  await assertFails(
    setDoc(
      doc(ownerDb(), 'publicProfiles', OWNER),
      validOwnerProfile({
        verifications: { email: false, phone: false, photo: false },
      }),
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

test('17a. publicProfiles verifications true → false/null/key 변경도 거부', async () => {
  await seedPublic(
    OWNER,
    fullExistingPublicDoc({
      verifications: { email: true, phone: true, photo: true },
    }),
  );
  await assertFails(
    updateDoc(doc(ownerDb(), 'publicProfiles', OWNER), {
      verifications: { email: false, phone: true, photo: true },
    }),
  );
  await assertFails(
    updateDoc(doc(ownerDb(), 'publicProfiles', OWNER), {
      verifications: null,
    }),
  );
  await assertFails(
    updateDoc(doc(ownerDb(), 'publicProfiles', OWNER), {
      verifications: { email: true, phone: true },
    }),
  );
  await assertFails(
    updateDoc(doc(ownerDb(), 'publicProfiles', OWNER), {
      verifications: {
        email: true,
        phone: true,
        photo: true,
        approved: true,
      },
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

// ── users/{uid} private read 규칙 회귀 ───────────────────────────────────────

test('43. 인증된 다른 사용자의 users read 거부', async () => {
  await seedUser(OWNER, { displayName: '지민', bio: 'hi' });
  await assertFails(getDoc(doc(otherDb(), 'users', OWNER)));
});

test('44. 비로그인 users read 거부', async () => {
  await seedUser(OWNER, { displayName: '지민', bio: 'hi' });
  await assertFails(getDoc(doc(anonDb(), 'users', OWNER)));
});

test('45. 본인 users read 허용', async () => {
  await seedUser(OWNER, { displayName: '지민', bio: 'hi' });
  await assertSucceeds(getDoc(doc(ownerDb(), 'users', OWNER)));
});

test('46. 본인 users write 허용', async () => {
  await seedUser(OWNER, { displayName: '지민', bio: 'hi' });
  await assertSucceeds(
    updateDoc(doc(ownerDb(), 'users', OWNER), { bio: '새 소개' }),
  );
});

// ── Phase 0-C: users/{uid} write field whitelist ──────────────────────────

test('47. 본인이 정상 users 생성 payload를 create', async () => {
  await assertSucceeds(setDoc(doc(ownerDb(), 'users', OWNER), validUserDoc()));
});

test('48. users create에서 허용되지 않은 임의 필드 거부', async () => {
  await assertFails(
    setDoc(doc(ownerDb(), 'users', OWNER), validUserDoc({ unknownKey: true })),
  );
});

test('49. users create에서 jelly 생성 거부', async () => {
  await assertFails(
    setDoc(doc(ownerDb(), 'users', OWNER), validUserDoc({ jelly: 999 })),
  );
});

test('50. users create에서 관리자/역할 필드 조작 거부', async () => {
  await assertFails(
    setDoc(doc(ownerDb(), 'users', OWNER), validUserDoc({ admin: true })),
  );
  await assertFails(
    setDoc(doc(ownerDb(), 'users', OWNER), validUserDoc({ role: 'admin' })),
  );
});

test('51. 다른 사용자 users create 거부', async () => {
  await assertFails(setDoc(doc(ownerDb(), 'users', OTHER), validUserDoc()));
});

test('52. 본인이 허용된 users 프로필 필드 update', async () => {
  await seedUser(OWNER, existingUserDoc());
  await assertSucceeds(
    updateDoc(doc(ownerDb(), 'users', OWNER), {
      displayName: '수정',
      bio: '새 소개',
      updatedAt: Timestamp.now(),
    }),
  );
});

test('53. 본인이 users 위치와 필터 update', async () => {
  await seedUser(OWNER, existingUserDoc());
  await assertSucceeds(
    updateDoc(doc(ownerDb(), 'users', OWNER), {
      location: {
        lat: 37.5665,
        lng: 126.978,
        updatedAt: Timestamp.now(),
        label: '서울',
      },
      discoveryFilter: {
        ageMin: 20,
        ageMax: 40,
        maxDistanceKm: null,
        gender: 'all',
        relationshipGoal: null,
      },
    }),
  );
});

test('54. FCM 토큰 merge write 허용', async () => {
  await seedUser(OWNER, existingUserDoc());
  await assertSucceeds(
    setDoc(
      doc(ownerDb(), 'users', OWNER),
      {
        fcmTokens: arrayUnion('token-1'),
        fcmTokenUpdatedAt: serverTimestamp(),
      },
      { merge: true },
    ),
  );
});

test('54a. users create에서 정확한 false 인증 초기값만 허용', async () => {
  await assertSucceeds(
    setDoc(
      doc(ownerDb(), 'users', OWNER),
      validUserDoc({ verifications: { email: false, phone: false, photo: false } }),
    ),
  );
});

test('54b. users create에서 email/phone/photo true 직접 생성 거부', async () => {
  await assertFails(
    setDoc(
      doc(ownerDb(), 'users', OWNER),
      validUserDoc({ verifications: { email: true, phone: false, photo: false } }),
    ),
  );
  await assertFails(
    setDoc(
      doc(ownerDb(), 'users', OWNER),
      validUserDoc({ verifications: { email: false, phone: true, photo: false } }),
    ),
  );
  await assertFails(
    setDoc(
      doc(ownerDb(), 'users', OWNER),
      validUserDoc({ verifications: { email: false, phone: false, photo: true } }),
    ),
  );
});

test('54c. users create에서 token이 있어도 인증 완료 true는 클라이언트 거부', async () => {
  await assertFails(
    setDoc(
      doc(emailVerifiedOwnerDb(), 'users', OWNER),
      validUserDoc({ verifications: { email: true, phone: false, photo: false } }),
    ),
  );
  await assertFails(
    setDoc(
      doc(phoneVerifiedOwnerDb(), 'users', OWNER),
      validUserDoc({ verifications: { email: false, phone: true, photo: false } }),
    ),
  );
});

test('54d. users create에서 verification map 누락/null/비-map/키 누락 거부', async () => {
  const missing = validUserDoc();
  delete missing.verifications;
  await assertFails(setDoc(doc(ownerDb(), 'users', OWNER), missing));
  await assertFails(
    setDoc(doc(ownerDb(), 'users', OWNER), validUserDoc({ verifications: null })),
  );
  await assertFails(
    setDoc(doc(ownerDb(), 'users', OWNER), validUserDoc({ verifications: false })),
  );
  await assertFails(
    setDoc(
      doc(ownerDb(), 'users', OWNER),
      validUserDoc({ verifications: { email: false, phone: false } }),
    ),
  );
});

test('54e. users create에서 verification 추가 key 거부', async () => {
  await assertFails(
    setDoc(
      doc(ownerDb(), 'users', OWNER),
      validUserDoc({
        verifications: {
          email: false,
          phone: false,
          photo: false,
          approved: true,
        },
      }),
    ),
  );
});

test('54f. users update에서 인증 false → true 직접 전환 거부', async () => {
  await seedUser(OWNER, existingUserDoc());
  await assertFails(
    updateDoc(doc(ownerDb(), 'users', OWNER), {
      verifications: { email: true, phone: false, photo: false },
    }),
  );
});

test('54g. users update에서 verification 동일값 no-op은 실질 mutation이 아니다', async () => {
  await seedUser(OWNER, existingUserDoc());
  await assertSucceeds(
    updateDoc(doc(ownerDb(), 'users', OWNER), {
      verifications: { email: false, phone: false, photo: false },
    }),
  );
});

test('54h. users update에서 true → false, delete/null/key 변경 거부', async () => {
  await seedUser(
    OWNER,
    existingUserDoc({
      verifications: { email: true, phone: true, photo: true },
    }),
  );
  await assertFails(
    updateDoc(doc(ownerDb(), 'users', OWNER), {
      verifications: { email: false, phone: true, photo: true },
    }),
  );
  await assertFails(
    updateDoc(doc(ownerDb(), 'users', OWNER), {
      verifications: deleteField(),
    }),
  );
  await assertFails(
    updateDoc(doc(ownerDb(), 'users', OWNER), {
      verifications: null,
    }),
  );
  await assertFails(
    updateDoc(doc(ownerDb(), 'users', OWNER), {
      verifications: { email: true, phone: true },
    }),
  );
  await assertFails(
    updateDoc(doc(ownerDb(), 'users', OWNER), {
      verifications: {
        email: true,
        phone: true,
        photo: true,
        approved: true,
      },
    }),
  );
});

test('54i. users update에서 nested verification 변경도 거부', async () => {
  await seedUser(OWNER, existingUserDoc());
  await assertFails(
    updateDoc(doc(ownerDb(), 'users', OWNER), {
      'verifications.email': true,
    }),
  );
});

test('54j. users update에서 unrelated owner-editable field는 계속 허용', async () => {
  await seedUser(OWNER, existingUserDoc());
  await assertSucceeds(
    updateDoc(doc(ownerDb(), 'users', OWNER), {
      displayName: '수정',
    }),
  );
});

test('55. users update에서 birthDate/createdAt 변경 거부', async () => {
  await seedUser(OWNER, existingUserDoc());
  await assertFails(
    updateDoc(doc(ownerDb(), 'users', OWNER), {
      birthDate: Timestamp.fromDate(new Date('2000-01-01T00:00:00Z')),
    }),
  );
  await assertFails(
    updateDoc(doc(ownerDb(), 'users', OWNER), { createdAt: Timestamp.now() }),
  );
});

test('56. users update에서 허용 필드와 금지 필드 혼합 변경 거부', async () => {
  await seedUser(OWNER, existingUserDoc());
  await assertFails(
    updateDoc(doc(ownerDb(), 'users', OWNER), {
      bio: '정상 변경',
      admin: true,
    }),
  );
});

test('57. users update에서 jelly 증액 거부', async () => {
  await seedUser(OWNER, existingUserDoc({ jelly: 10 }));
  await assertFails(
    updateDoc(doc(ownerDb(), 'users', OWNER), { jelly: 999 }),
  );
});

test('58. users update에서 jelly 차감 패턴은 허용', async () => {
  await seedUser(OWNER, existingUserDoc({ jelly: 10 }));
  await assertSucceeds(
    updateDoc(doc(ownerDb(), 'users', OWNER), { jelly: 5 }),
  );
});

test('58a. users update에서 잘못된 jelly 차감액/음수/비정수 거부', async () => {
  await seedUser(OWNER, existingUserDoc({ jelly: 10 }));
  await assertFails(
    updateDoc(doc(ownerDb(), 'users', OWNER), { jelly: 6 }),
  );
  await assertFails(
    updateDoc(doc(ownerDb(), 'users', OWNER), { jelly: -1 }),
  );
  await assertFails(
    updateDoc(doc(ownerDb(), 'users', OWNER), { jelly: 5.5 }),
  );
});

test('59. users update에서 비용 없는 boostUntil/likesUnlocked 조작 거부', async () => {
  await seedUser(OWNER, existingUserDoc({ jelly: 50 }));
  await assertFails(
    updateDoc(doc(ownerDb(), 'users', OWNER), {
      boostUntil: Timestamp.fromDate(new Date('2099-01-01T00:00:00Z')),
    }),
  );
  await assertFails(
    updateDoc(doc(ownerDb(), 'users', OWNER), { likesUnlocked: true }),
  );
});

test('59a. users boost는 정확히 30 차감하고 짧은 만료만 허용', async () => {
  await seedUser(OWNER, existingUserDoc({ jelly: 50 }));
  await assertSucceeds(
    updateDoc(doc(ownerDb(), 'users', OWNER), {
      jelly: 20,
      boostUntil: Timestamp.fromDate(new Date(Date.now() + 30 * 60 * 1000)),
    }),
  );
});

test('59b. users boost 장기 만료나 부족 차감은 거부', async () => {
  await seedUser(OWNER, existingUserDoc({ jelly: 50 }));
  await assertFails(
    updateDoc(doc(ownerDb(), 'users', OWNER), {
      jelly: 49,
      boostUntil: Timestamp.fromDate(new Date('2099-01-01T00:00:00Z')),
    }),
  );
  await assertFails(
    updateDoc(doc(ownerDb(), 'users', OWNER), {
      jelly: 20,
      boostUntil: Timestamp.fromDate(new Date('2099-01-01T00:00:00Z')),
    }),
  );
});

test('59c. users likesUnlocked는 정확히 20 차감할 때만 허용', async () => {
  await seedUser(OWNER, existingUserDoc({ jelly: 50, likesUnlocked: false }));
  await assertSucceeds(
    updateDoc(doc(ownerDb(), 'users', OWNER), {
      jelly: 30,
      likesUnlocked: true,
    }),
  );
});

test('59d. users likesUnlocked 부족 차감이나 재획득은 거부', async () => {
  await seedUser(OWNER, existingUserDoc({ jelly: 50, likesUnlocked: false }));
  await assertFails(
    updateDoc(doc(ownerDb(), 'users', OWNER), {
      jelly: 49,
      likesUnlocked: true,
    }),
  );

  await testEnv.clearFirestore();
  await seedUser(OWNER, existingUserDoc({ jelly: 50, likesUnlocked: true }));
  await assertFails(
    updateDoc(doc(ownerDb(), 'users', OWNER), {
      jelly: 30,
      likesUnlocked: true,
    }),
  );
});

test('60. users update에서 AI 캐시/운영 필드 조작 거부', async () => {
  await seedUser(OWNER, existingUserDoc());
  await assertFails(
    updateDoc(doc(ownerDb(), 'users', OWNER), {
      fortuneNarrative: { title: '위조' },
    }),
  );
  await assertFails(
    updateDoc(doc(ownerDb(), 'users', OWNER), {
      moderationStatus: 'approved',
    }),
  );
});

test('61. users delete는 본인도 거부', async () => {
  await seedUser(OWNER, existingUserDoc());
  await assertFails(deleteDoc(doc(ownerDb(), 'users', OWNER)));
});

// ── Phase 0-C: publicProfiles privacy boundary additions ──────────────────

test('62. 공개 프로필 create에서 birthDate 원본 저장 거부', async () => {
  await assertFails(
    setDoc(
      doc(ownerDb(), 'publicProfiles', OWNER),
      validOwnerProfile({
        birthDate: Timestamp.fromDate(new Date('1995-06-15T00:00:00Z')),
      }),
    ),
  );
});

test('63. 공개 프로필 create에서 정밀 location 저장 거부', async () => {
  await assertFails(
    setDoc(
      doc(ownerDb(), 'publicProfiles', OWNER),
      validOwnerProfile({
        location: { lat: 37.56647, lng: 126.97796, updatedAt: Timestamp.now() },
      }),
    ),
  );
});

test('64. 공개 프로필 create에서 연락처 저장 거부', async () => {
  await assertFails(
    setDoc(
      doc(ownerDb(), 'publicProfiles', OWNER),
      validOwnerProfile({ email: 'owner@example.com' }),
    ),
  );
  await assertFails(
    setDoc(
      doc(ownerDb(), 'publicProfiles', OWNER),
      validOwnerProfile({ phoneNumber: '+821012345678' }),
    ),
  );
});

test('65. 공개 프로필 update에서 허용 필드와 금지 필드 혼합 변경 거부', async () => {
  await seedPublic(OWNER, fullExistingPublicDoc());
  await assertFails(
    updateDoc(doc(ownerDb(), 'publicProfiles', OWNER), {
      bio: '정상 변경',
      rankingBoostUntil: Timestamp.now(),
    }),
  );
});

test('66. 정상 users/publicProfiles dual-write batch 허용', async () => {
  const db = ownerDb();
  const userRef = doc(db, 'users', OWNER);
  const publicRef = doc(db, 'publicProfiles', OWNER);
  const batch = writeBatch(db);
  batch.set(userRef, validUserDoc());
  batch.set(publicRef, validOwnerProfile(), { merge: true });
  await assertSucceeds(batch.commit());
});

test('67. jellyTransactions 단독 충전 위조 create 거부', async () => {
  await assertFails(
    setDoc(doc(ownerDb(), 'users', OWNER, 'jellyTransactions', 'tx1'), {
      type: 'charge',
      amount: 999,
      reason: 'jelly_300',
      createdAt: serverTimestamp(),
    }),
  );
});

test('68. jellyTransactions 소비 내역 create 허용', async () => {
  await assertSucceeds(
    setDoc(doc(ownerDb(), 'users', OWNER, 'jellyTransactions', 'tx1'), {
      type: 'spend',
      amount: -5,
      reason: 'superlike',
      createdAt: serverTimestamp(),
    }),
  );
});

test('69. jellyTransactions amount 0/양수/미허용 음수 거부', async () => {
  await assertFails(
    setDoc(doc(ownerDb(), 'users', OWNER, 'jellyTransactions', 'tx1'), {
      type: 'spend',
      amount: 0,
      reason: 'superlike',
      createdAt: serverTimestamp(),
    }),
  );
  await assertFails(
    setDoc(doc(ownerDb(), 'users', OWNER, 'jellyTransactions', 'tx2'), {
      type: 'spend',
      amount: 5,
      reason: 'superlike',
      createdAt: serverTimestamp(),
    }),
  );
  await assertFails(
    setDoc(doc(ownerDb(), 'users', OWNER, 'jellyTransactions', 'tx3'), {
      type: 'spend',
      amount: -999,
      reason: 'superlike',
      createdAt: serverTimestamp(),
    }),
  );
});

test('70. jellyTransactions unknown field와 update/delete 거부', async () => {
  await assertFails(
    setDoc(doc(ownerDb(), 'users', OWNER, 'jellyTransactions', 'tx1'), {
      type: 'spend',
      amount: -5,
      reason: 'superlike',
      createdAt: serverTimestamp(),
      ownerUid: OWNER,
    }),
  );

  await seedUser(OWNER, existingUserDoc());
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), 'users', OWNER, 'jellyTransactions', 'tx2'), {
      type: 'spend',
      amount: -5,
      reason: 'superlike',
      createdAt: Timestamp.now(),
    });
  });

  await assertFails(
    updateDoc(doc(ownerDb(), 'users', OWNER, 'jellyTransactions', 'tx2'), {
      amount: -3,
    }),
  );
  await assertFails(
    deleteDoc(doc(ownerDb(), 'users', OWNER, 'jellyTransactions', 'tx2')),
  );
});

test('71. 서버 전용 deletion job/audit/purchase/usage 컬렉션은 본인도 접근 불가', async () => {
  const db = ownerDb();
  const blockedRefs = [
    doc(db, '_accountDeletionJobs', 'hash1'),
    doc(db, '_deletedAccountAudit', 'hash1'),
    doc(db, '_deletedAccountAudit', 'hash1', 'jellyTransactions', 'txhash'),
    doc(db, '_purchaseReceipts', 'receipthash'),
    doc(db, '_purchaseVerificationUsage', OWNER),
    doc(db, '_internalAiUsage', OWNER),
    doc(db, '_internalAiUsage', OWNER, 'functions', 'generateDailyFortune'),
    doc(db, '_internalAiLeases', 'lease1'),
  ];

  for (const ref of blockedRefs) {
    await assertFails(getDoc(ref));
    await assertFails(setDoc(ref, { ownerUid: OWNER, status: 'client-write' }));
  }
});

test('72. reports 생성 시 서버 전용 감사 필드를 끼워 넣을 수 없다', async () => {
  await assertSucceeds(
    setDoc(doc(ownerDb(), 'reports', 'report1'), {
      reporterUid: OWNER,
      reportedUid: OTHER,
      reason: 'spam_scam',
      detail: '반복 홍보',
      createdAt: serverTimestamp(),
    }),
  );

  await assertFails(
    setDoc(doc(ownerDb(), 'reports', 'report2'), {
      reporterUid: OWNER,
      reportedUid: OTHER,
      reason: 'spam_scam',
      deletedSubjectHash: 'hash',
    }),
  );
  await assertFails(
    setDoc(doc(ownerDb(), 'reports', 'report3'), {
      reporterUid: OWNER,
      reportedUid: OTHER,
      reason: 'spam_scam',
      reporterDeleted: true,
    }),
  );
});

test('73. hidden match에는 신규 메시지를 만들 수 없고 다른 match는 영향 없다', async () => {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    const adminDb = ctx.firestore();
    await setDoc(doc(adminDb, 'matches', 'hidden'), {
      participants: [OWNER, OTHER],
      uid1: OWNER,
      uid2: OTHER,
      matchedAt: Timestamp.now(),
      unmatchedBy: ['deleted:abc123'],
    });
    await setDoc(doc(adminDb, 'matches', 'active'), {
      participants: [OWNER, OTHER],
      uid1: OWNER,
      uid2: OTHER,
      matchedAt: Timestamp.now(),
      unmatchedBy: [],
    });
  });

  await assertFails(
    setDoc(doc(ownerDb(), 'matches', 'hidden', 'messages', 'm1'), {
      senderId: OWNER,
      text: '보내면 안 됨',
      createdAt: serverTimestamp(),
    }),
  );
  await assertSucceeds(
    setDoc(doc(ownerDb(), 'matches', 'active', 'messages', 'm1'), {
      senderId: OWNER,
      text: '안녕하세요',
      createdAt: serverTimestamp(),
    }),
  );
});

// ── valueAnswers (Phase 1-1-C) ──────────────────────────────────────────────
// 가치관 답변 화이트리스트: 6개 질문 key, 질문별 answer key. 부분 응답·빈 map
// 허용, 필드 부재 허용. 임의 key / 교차 answer key / 비문자열 값은 거부.

const VALID_ANSWERS = {
  contact_frequency: 'few_times',
  conflict_style: 'cool_down',
  date_style: 'culture',
  alone_time: 'some',
  affection_expression: 'words',
  life_rhythm: 'morning',
};

test('74. users create: valueAnswers 없어도 허용(구버전 호환)', async () => {
  await assertSucceeds(
    setDoc(doc(ownerDb(), 'users', OWNER), validUserDoc()),
  );
});

test('75. users create: 빈 valueAnswers map 허용', async () => {
  await assertSucceeds(
    setDoc(
      doc(ownerDb(), 'users', OWNER),
      validUserDoc({ valueAnswers: {} }),
    ),
  );
});

test('76. users create: 일부 질문만 정상 응답 허용', async () => {
  await assertSucceeds(
    setDoc(
      doc(ownerDb(), 'users', OWNER),
      validUserDoc({
        valueAnswers: { contact_frequency: 'few_times', date_style: 'cozy' },
      }),
    ),
  );
});

test('77. users create: 6문항 전체 정상 응답 허용', async () => {
  await assertSucceeds(
    setDoc(
      doc(ownerDb(), 'users', OWNER),
      validUserDoc({ valueAnswers: VALID_ANSWERS }),
    ),
  );
});

test('78. users create: 알 수 없는 question key 거부', async () => {
  await assertFails(
    setDoc(
      doc(ownerDb(), 'users', OWNER),
      validUserDoc({ valueAnswers: { not_a_question: 'few_times' } }),
    ),
  );
});

test('79. users create: 잘못된 answer key 거부', async () => {
  await assertFails(
    setDoc(
      doc(ownerDb(), 'users', OWNER),
      validUserDoc({ valueAnswers: { contact_frequency: 'not_real' } }),
    ),
  );
});

test('80. users create: 다른 질문의 answer key 교차 사용 거부', async () => {
  await assertFails(
    setDoc(
      doc(ownerDb(), 'users', OWNER),
      // 'talk_now'는 conflict_style 전용 — date_style에는 무효.
      validUserDoc({ valueAnswers: { date_style: 'talk_now' } }),
    ),
  );
});

test('81. users create: 비문자열 값(숫자/bool/list/map) 거부', async () => {
  await assertFails(
    setDoc(
      doc(ownerDb(), 'users', OWNER),
      validUserDoc({ valueAnswers: { contact_frequency: 3 } }),
    ),
  );
  await assertFails(
    setDoc(
      doc(ownerDb(), 'users', OWNER),
      validUserDoc({ valueAnswers: { contact_frequency: true } }),
    ),
  );
  await assertFails(
    setDoc(
      doc(ownerDb(), 'users', OWNER),
      validUserDoc({ valueAnswers: { contact_frequency: ['few_times'] } }),
    ),
  );
  await assertFails(
    setDoc(
      doc(ownerDb(), 'users', OWNER),
      validUserDoc({ valueAnswers: { contact_frequency: { k: 'v' } } }),
    ),
  );
});

test('82. users create: 6문항 + 7번째 임의 key 거부', async () => {
  await assertFails(
    setDoc(
      doc(ownerDb(), 'users', OWNER),
      validUserDoc({
        valueAnswers: { ...VALID_ANSWERS, extra_question: 'x' },
      }),
    ),
  );
});

test('83. users update: valueAnswers를 건드리지 않는 기존 update 허용', async () => {
  await seedUser(OWNER, existingUserDoc());
  await assertSucceeds(
    updateDoc(doc(ownerDb(), 'users', OWNER), {
      bio: '자기소개 수정',
      updatedAt: serverTimestamp(),
    }),
  );
});

test('84. users update: 정상 valueAnswers 저장 허용', async () => {
  await seedUser(OWNER, existingUserDoc());
  await assertSucceeds(
    updateDoc(doc(ownerDb(), 'users', OWNER), {
      valueAnswers: VALID_ANSWERS,
      updatedAt: serverTimestamp(),
    }),
  );
});

test('85. users update: 답변 전체 초기화는 {} 저장으로 허용', async () => {
  await seedUser(OWNER, existingUserDoc({ valueAnswers: VALID_ANSWERS }));
  await assertSucceeds(
    updateDoc(doc(ownerDb(), 'users', OWNER), {
      valueAnswers: {},
      updatedAt: serverTimestamp(),
    }),
  );
});

test('86. users update: valueAnswers 필드 삭제는 거부(초기화는 {} 사용)', async () => {
  await seedUser(OWNER, existingUserDoc({ valueAnswers: VALID_ANSWERS }));
  await assertFails(
    updateDoc(doc(ownerDb(), 'users', OWNER), {
      valueAnswers: deleteField(),
      updatedAt: serverTimestamp(),
    }),
  );
});

test('87. users update: 잘못된 valueAnswers 저장 거부', async () => {
  await seedUser(OWNER, existingUserDoc());
  await assertFails(
    updateDoc(doc(ownerDb(), 'users', OWNER), {
      valueAnswers: { date_style: 'talk_now' },
      updatedAt: serverTimestamp(),
    }),
  );
});

test('88. publicProfiles create: 정상 valueAnswers 허용', async () => {
  await assertSucceeds(
    setDoc(
      doc(ownerDb(), 'publicProfiles', OWNER),
      validOwnerProfile({ valueAnswers: VALID_ANSWERS }),
    ),
  );
});

test('89. publicProfiles create: 빈 valueAnswers 허용', async () => {
  await assertSucceeds(
    setDoc(
      doc(ownerDb(), 'publicProfiles', OWNER),
      validOwnerProfile({ valueAnswers: {} }),
    ),
  );
});

test('90. publicProfiles create: 잘못된 valueAnswers 거부', async () => {
  await assertFails(
    setDoc(
      doc(ownerDb(), 'publicProfiles', OWNER),
      validOwnerProfile({ valueAnswers: { date_style: 'talk_now' } }),
    ),
  );
});

test('91. publicProfiles update: 본인 valueAnswers 변경 허용', async () => {
  await seedPublic(OWNER, fullExistingPublicDoc());
  await assertSucceeds(
    updateDoc(doc(ownerDb(), 'publicProfiles', OWNER), {
      valueAnswers: VALID_ANSWERS,
    }),
  );
});

test('92. publicProfiles update: 다른 사용자의 valueAnswers 변경 거부', async () => {
  await seedPublic(OWNER, fullExistingPublicDoc());
  await assertFails(
    updateDoc(doc(otherDb(), 'publicProfiles', OWNER), {
      valueAnswers: VALID_ANSWERS,
    }),
  );
});

test('93. publicProfiles update: valueAnswers와 server-managed 필드 혼합 변경 거부', async () => {
  await seedPublic(OWNER, fullExistingPublicDoc());
  await assertFails(
    updateDoc(doc(ownerDb(), 'publicProfiles', OWNER), {
      valueAnswers: VALID_ANSWERS,
      rankingBoostUntil: Timestamp.now(),
    }),
  );
});
