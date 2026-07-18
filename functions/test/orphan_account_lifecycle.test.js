'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const {
  ACCOUNT_CATEGORY,
  CLEANUP_ERROR,
  CLEANUP_RECOMMENDATION,
  assertNoSensitiveOutput,
  classifyAccount,
  planCleanup,
  safeUidHash,
  summarizeClassifications,
} = require('../lib/orphan_account_lifecycle');
const auditScript = require('../scripts/audit_orphan_accounts');
const cleanupScript = require('../scripts/cleanup_orphan_accounts');

function ts() {
  return { toMillis: () => Date.UTC(2026, 0, 1) };
}

function authRecord(overrides = {}) {
  return {
    uid: 'auth-1',
    disabled: false,
    emailVerified: true,
    phoneNumber: '+821012345678',
    email: 'secret@example.test',
    metadata: {
      creationTime: '2025-01-01T00:00:00.000Z',
      lastSignInTime: '2025-02-01T00:00:00.000Z',
    },
    ...overrides,
  };
}

function usersData(overrides = {}) {
  return {
    displayName: 'Secret Name',
    birthDate: ts(),
    gender: 'female',
    bio: 'hidden',
    photoUrls: ['https://example.test/photo.jpg'],
    createdAt: ts(),
    updatedAt: ts(),
    verifications: { email: true, phone: true, photo: false },
    discoveryFilter: {
      ageMin: 18,
      ageMax: 80,
      maxDistanceKm: null,
      gender: 'all',
      relationshipGoal: null,
    },
    jelly: 0,
    ...overrides,
  };
}

function publicData(overrides = {}) {
  return {
    displayName: 'Secret Name',
    age: 25,
    gender: 'female',
    bio: 'hidden',
    photoUrls: ['https://example.test/photo.jpg'],
    verifications: { email: true, phone: true, photo: false },
    schemaVersion: 1,
    ...overrides,
  };
}

function classify(overrides = {}) {
  return classifyAccount({
    uid: 'auth-1',
    authRecord: authRecord(),
    usersData: usersData(),
    publicData: publicData(),
    nowMs: Date.UTC(2026, 6, 1),
    ...overrides,
  });
}

test('1. HEALTHY 계정 제외/RETAIN', () => {
  const result = classify();
  assert.equal(result.category, ACCOUNT_CATEGORY.HEALTHY);
  assert.equal(result.recommendation, CLEANUP_RECOMMENDATION.RETAIN);
  assert.equal(result.profileComplete, true);
});

test('2. AUTH_ONLY 분류', () => {
  const result = classify({ usersData: undefined, publicData: undefined });
  assert.equal(result.category, ACCOUNT_CATEGORY.AUTH_ONLY);
  assert.equal(result.recommendation, CLEANUP_RECOMMENDATION.DISABLE_THEN_REVIEW);
});

test('3. AUTH_WITH_PRIVATE_ONLY 분류', () => {
  const result = classify({ publicData: undefined });
  assert.equal(result.category, ACCOUNT_CATEGORY.AUTH_WITH_PRIVATE_ONLY);
  assert.equal(result.recommendation, CLEANUP_RECOMMENDATION.REPAIR);
});

test('4. AUTH_WITH_PUBLIC_ONLY 분류', () => {
  const result = classify({ usersData: undefined });
  assert.equal(result.category, ACCOUNT_CATEGORY.AUTH_WITH_PUBLIC_ONLY);
  assert.equal(result.recommendation, CLEANUP_RECOMMENDATION.REPAIR);
});

test('5. FIRESTORE_ONLY known test account는 참조 없을 때 SAFE_DELETE_CANDIDATE', () => {
  const result = classify({
    uid: 'dummy_001',
    authRecord: undefined,
  });
  assert.equal(result.category, ACCOUNT_CATEGORY.FIRESTORE_ONLY);
  assert.equal(result.knownTestAccount, true);
  assert.equal(result.recommendation, CLEANUP_RECOMMENDATION.SAFE_DELETE_CANDIDATE);
});

test('6. invalid profile shape 분류', () => {
  const result = classify({ usersData: usersData({ verifications: { email: 'yes' } }) });
  assert.equal(result.category, ACCOUNT_CATEGORY.PROFILE_SHAPE_INVALID);
  assert.equal(result.recommendation, CLEANUP_RECOMMENDATION.REPAIR);
  assert.deepEqual(result.shapeIssues, ['users.verifications:invalid_shape']);
});

test('7. 최근 계정은 자동 삭제 후보에서 제외', () => {
  const result = classify({
    uid: 'dummy_002',
    authRecord: undefined,
    references: { isRecent: true },
  });
  assert.equal(result.category, ACCOUNT_CATEGORY.FIRESTORE_ONLY);
  assert.equal(result.recommendation, CLEANUP_RECOMMENDATION.MANUAL_REVIEW_REQUIRED);
  assert.ok(result.blockers.includes('RECENT_ACCOUNT'));
});

test('8. match 참조 시 수동 검토', () => {
  const result = classify({
    uid: 'dummy_003',
    authRecord: undefined,
    references: { hasMatchReference: true },
  });
  assert.equal(result.recommendation, CLEANUP_RECOMMENDATION.MANUAL_REVIEW_REQUIRED);
});

test('9. chat/message 참조 시 수동 검토', () => {
  const result = classify({
    uid: 'dummy_004',
    authRecord: undefined,
    references: { hasChatOrMessageReference: true },
  });
  assert.equal(result.recommendation, CLEANUP_RECOMMENDATION.MANUAL_REVIEW_REQUIRED);
});

test('10. like/block/report 참조 시 수동 검토', () => {
  for (const key of ['hasLikeReference', 'hasBlockReference', 'hasReportReference']) {
    const result = classify({
      uid: 'dummy_005',
      authRecord: undefined,
      references: { [key]: true },
    });
    assert.equal(result.recommendation, CLEANUP_RECOMMENDATION.MANUAL_REVIEW_REQUIRED);
  }
});

test('11. jelly 잔액 시 수동 검토', () => {
  const result = classify({
    uid: 'dummy_006',
    authRecord: undefined,
    usersData: usersData({ jelly: 5 }),
  });
  assert.equal(result.recommendation, CLEANUP_RECOMMENDATION.MANUAL_REVIEW_REQUIRED);
  assert.equal(result.hasJellyBalance, true);
});

test('12. purchase 기록 시 수동 검토', () => {
  const result = classify({
    uid: 'dummy_007',
    authRecord: undefined,
    references: {
      hasPurchaseReference: true,
      hasJellyTransactionReference: true,
    },
  });
  assert.equal(result.recommendation, CLEANUP_RECOMMENDATION.MANUAL_REVIEW_REQUIRED);
});

test('13. Storage 파일 시 수동 검토', () => {
  const result = classify({
    uid: 'dummy_008',
    authRecord: undefined,
    storageObjectCount: 1,
  });
  assert.equal(result.recommendation, CLEANUP_RECOMMENDATION.MANUAL_REVIEW_REQUIRED);
});

test('14. 조회 오류 시 fail-closed', () => {
  const result = classify({
    uid: 'dummy_009',
    authRecord: undefined,
    references: { hasReadError: true },
  });
  assert.equal(result.category, ACCOUNT_CATEGORY.FIRESTORE_ONLY);
  assert.equal(result.recommendation, CLEANUP_RECOMMENDATION.MANUAL_REVIEW_REQUIRED);
  assert.ok(result.blockers.includes('READ_ERROR'));
});

test('15. dry-run 변경 0', () => {
  const plan = planCleanup({
    currentEntries: [
      classify({ uid: 'dummy_010', authRecord: undefined }),
    ],
  });
  assert.equal(plan.mode, 'dry-run');
  assert.equal(plan.writesAttempted, 0);
  assert.equal(plan.deletesAttempted, 0);
  assert.equal(plan.authMutations, 0);
  assert.equal(plan.firestoreMutations, 0);
  assert.equal(plan.storageMutations, 0);
});

test('16. --execute 없는 변경 0', () => {
  const plan = planCleanup({
    dryRun: true,
    execute: false,
    currentEntries: [classify({ uid: 'dummy_011', authRecord: undefined })],
  });
  assert.equal(plan.mode, 'dry-run');
  assert.equal(plan.deletesAttempted, 0);
});

test('17. 허용 manifest 없는 execute는 변경 없이 중단', () => {
  assert.throws(() => planCleanup({ dryRun: false, execute: true }), {
    code: CLEANUP_ERROR.EXECUTION_NOT_IMPLEMENTED,
  });
});

test('18. 정상 계정이 manifest에 있으면 중단', () => {
  const healthy = classify({ uid: 'healthy-user' });
  assert.throws(
    () => planCleanup({
      dryRun: false,
      execute: true,
      confirmExecute: true,
      manifest: { uidHashes: [healthy.uidHash] },
      currentEntries: [healthy],
    }),
    { code: CLEANUP_ERROR.EXECUTION_NOT_IMPLEMENTED },
  );
});

test('19. 반복 dry-run 결과 동일', () => {
  const entries = [
    classify({ uid: 'dummy_012', authRecord: undefined }),
    classify({ uid: 'healthy-user' }),
  ];
  assert.deepEqual(
    planCleanup({ currentEntries: entries }),
    planCleanup({ currentEntries: entries }),
  );
});

test('20. raw UID/PII 로그 없음', () => {
  const rawUid = 'RAW-USER-SECRET';
  const entry = classify({
    uid: rawUid,
    authRecord: authRecord({
      uid: rawUid,
      email: 'pii@example.test',
      phoneNumber: '+821099998888',
    }),
  });
  const text = JSON.stringify(entry);
  assertNoSensitiveOutput(text, [rawUid, 'pii@example.test', '+821099998888', 'Secret Name']);
  assert.match(entry.uidHash, /^[0-9a-f]{8}$/);
  assert.equal(entry.uidHash, safeUidHash(rawUid));
});

test('21. aggregate summary counts categories/recommendations', () => {
  const entries = [
    classify({ uid: 'healthy-user' }),
    classify({ uid: 'dummy_013', authRecord: undefined }),
    classify({ uid: 'auth-only', usersData: undefined, publicData: undefined }),
    classify({
      uid: 'dummy_014',
      authRecord: undefined,
      references: { hasMatchReference: true },
    }),
  ];
  const summary = summarizeClassifications(entries);
  assert.equal(summary.totalAccounts, 4);
  assert.equal(summary.byCategory.HEALTHY, 1);
  assert.equal(summary.safeDeleteCandidates, 1);
  assert.equal(summary.manualReviewRequired, 1);
  assert.equal(summary.candidatesWithReferences, 1);
});

test('22. CLI parsers reject unsafe modes and require project', () => {
  assert.throws(() => auditScript.parseArgs([]), /--project is required/);
  assert.throws(
    () => auditScript.parseArgs(['--project', 'cvr-dating-app', '--delete']),
    /Unsupported mutation-mode flag/,
  );
  const parsed = cleanupScript.parseArgs(['--project', 'cvr-dating-app', '--execute']);
  assert.equal(parsed.execute, true);
  assert.equal(parsed.manifestPath, null);
});

test('23. manifest 권한은 group/other 접근을 허용하지 않는다', () => {
  const file = path.join(os.tmpdir(), `orphan-manifest-${process.pid}.json`);
  fs.writeFileSync(file, JSON.stringify({ uidHashes: ['abcd1234'] }), { mode: 0o600 });
  assert.deepEqual(cleanupScript.readManifest(file), { uidHashes: ['abcd1234'] });
  fs.chmodSync(file, 0o644);
  assert.throws(() => cleanupScript.readManifest(file), /permissions/);
  fs.unlinkSync(file);
});

test('24. orphan scripts contain no production mutation API surface', () => {
  const root = path.join(__dirname, '..');
  const files = [
    path.join(root, 'scripts/audit_orphan_accounts.js'),
    path.join(root, 'scripts/cleanup_orphan_accounts.js'),
  ];
  const forbidden = /\.update\(|\.create\(|\.delete\(|\bbatch\(|bulkWriter|deleteUser|updateUser|disableUser|transaction\.set|transaction\.update|transaction\.delete/;
  for (const file of files) {
    const src = fs.readFileSync(file, 'utf8');
    assert.equal(forbidden.test(src), false, file);
  }
});
