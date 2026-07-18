'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const {
  DELETE_ACTION,
  DELETION_JOB_STAGE,
  DELETE_MY_ACCOUNT_CONTRACT,
  EXECUTION_SEQUENCE,
  RESOURCE_CONTRACTS,
  SHARED_DATA_POLICY,
  planAccountDeletion,
} = require('../lib/account_deletion_plan');

const UID_HASH = 'a'.repeat(64);

function plan(resources, overrides = {}) {
  return planAccountDeletion({
    uidHash: UID_HASH,
    resources,
    ...overrides,
  });
}

function actionsFor(entries) {
  return entries.map((entry) => `${entry.action}:${entry.resource}`);
}

function resourcesFor(entries) {
  return entries.map((entry) => entry.resource);
}

function allEntries(result) {
  return [
    ...result.hardDelete,
    ...result.removeRelations,
    ...result.anonymize,
    ...result.retainServerOnly,
    ...result.manualPolicyRequired,
    result.authDelete,
  ].filter(Boolean);
}

test('1. 완전 독립 사용자 -> 삭제 계획 가능', () => {
  const result = plan({
    authUser: { exists: true },
    users: { exists: true },
    publicProfiles: { exists: true },
    dailyFortune: { count: 2 },
    storageUserFiles: { count: 3 },
    internalAiUsage: { count: 1 },
    internalAiLeases: { count: 1 },
    purchaseVerificationUsage: { exists: true },
  });

  assert.equal(result.canProceed, true);
  assert.deepEqual(result.blockers, []);
  assert.deepEqual(result.manualPolicyRequired, []);
  assert.equal(result.authDeleteLast, true);
});

test('2. malformed inventory -> fail-closed', () => {
  const result = planAccountDeletion(null);
  assert.equal(result.canProceed, false);
  assert.equal(result.blockers[0].code, 'MALFORMED_INVENTORY');
});

test('3. unknown collection -> fail-closed', () => {
  const result = plan({ users: { exists: true }, unknownCollection: { count: 1 } });
  assert.equal(result.canProceed, false);
  assert.equal(result.blockers[0].code, 'UNKNOWN_COLLECTION');
  assert.deepEqual(result.blockers[0].resources, ['unknownCollection']);
});

test('4. private profile users/{uid} -> HARD_DELETE', () => {
  const result = plan({ users: { exists: true } });
  assert.ok(actionsFor(result.hardDelete).includes('HARD_DELETE:users'));
});

test('5. publicProfiles/{uid} -> HARD_DELETE', () => {
  const result = plan({ publicProfiles: { exists: true } });
  assert.ok(actionsFor(result.hardDelete).includes('HARD_DELETE:publicProfiles'));
});

test('6. Storage 사용자 파일 -> HARD_DELETE', () => {
  const result = plan({ storageUserFiles: { count: 4 } });
  const entry = result.hardDelete.find((item) => item.resource === 'storageUserFiles');
  assert.equal(entry.action, DELETE_ACTION.HARD_DELETE);
  assert.equal(entry.count, 4);
});

test('7. likes/swipes -> REMOVE_RELATION', () => {
  const result = plan({
    swipesAuthored: { count: 2 },
    swipesTargetingUser: { count: 3 },
  });
  assert.deepEqual(resourcesFor(result.removeRelations).sort(), [
    'swipesAuthored',
    'swipesTargetingUser',
  ]);
});

test('8. block 관계 -> REMOVE_RELATION', () => {
  const result = plan({
    blocksAuthored: { count: 1 },
    blocksTargetingUser: { count: 2 },
  });
  assert.deepEqual(resourcesFor(result.removeRelations).sort(), [
    'blocksAuthored',
    'blocksTargetingUser',
  ]);
});

test('9. shared match 존재 -> 상대 데이터 보존, 전체 삭제 금지', () => {
  const result = plan(
    { matches: { count: 1 } },
    { sharedDataPolicy: SHARED_DATA_POLICY.ANONYMIZE_DELETED_PARTICIPANT },
  );
  assert.equal(result.canProceed, true);
  assert.equal(result.hardDelete.some((entry) => entry.resource === 'matches'), false);
  assert.ok(result.anonymize.some((entry) => entry.resource === 'matches'));
});

test('10. shared chat 존재 -> 전체 chat 무조건 삭제 금지', () => {
  const result = plan({ matches: { count: 1 }, matchMessages: { count: 5 } });
  assert.equal(result.canProceed, false);
  assert.equal(result.hardDelete.some((entry) => entry.resource === 'matchMessages'), false);
  assert.ok(result.manualPolicyRequired.some((entry) => entry.resource === 'matchMessages'));
});

test('11. message 작성자 처리 정책 반영', () => {
  const result = plan(
    { matches: { count: 1 }, matchMessages: { count: 7 } },
    { sharedDataPolicy: SHARED_DATA_POLICY.ANONYMIZE_DELETED_PARTICIPANT },
  );
  const messagePlan = result.anonymize.find((entry) => entry.resource === 'matchMessages');
  assert.equal(messagePlan.action, DELETE_ACTION.ANONYMIZE);
  assert.deepEqual(messagePlan.details.fields, ['senderId']);
});

test('12. report 존재 -> HARD_DELETE 금지', () => {
  const result = plan({
    reportsAuthored: { count: 1 },
    reportsTargetingUser: { count: 1 },
  });
  assert.equal(result.hardDelete.some((entry) => entry.resource.startsWith('reports')), false);
  assert.deepEqual(resourcesFor(result.retainServerOnly).sort(), [
    'reportsAuthored',
    'reportsTargetingUser',
  ]);
});

test('13. purchase receipt 존재 -> HARD_DELETE 금지', () => {
  const result = plan({ purchaseReceipts: { count: 2 } });
  assert.equal(result.hardDelete.some((entry) => entry.resource === 'purchaseReceipts'), false);
  assert.ok(result.retainServerOnly.some((entry) => entry.resource === 'purchaseReceipts'));
});

test('14. jelly transaction 감사 기록 정책 반영', () => {
  const result = plan({ jellyTransactions: { count: 3 } });
  assert.equal(result.hardDelete.some((entry) => entry.resource === 'jellyTransactions'), false);
  assert.ok(result.retainServerOnly.some((entry) => entry.resource === 'jellyTransactions'));
  assert.ok(result.anonymize.some((entry) => entry.resource === 'jellyTransactions'));
});

test('15. AI usage/lease 문서 정리 대상', () => {
  const result = plan({
    internalAiUsage: { count: 2 },
    internalAiLeases: { count: 4 },
  });
  assert.deepEqual(resourcesFor(result.hardDelete).sort(), [
    'internalAiLeases',
    'internalAiUsage',
  ]);
});

test('16. Auth 삭제가 항상 마지막', () => {
  const result = plan({ authUser: { exists: true }, users: { exists: true } });
  assert.equal(result.authDeleteLast, true);
  assert.equal(result.authDelete.action, 'AUTH_DELETE_LAST');
  assert.equal(EXECUTION_SEQUENCE.at(-3), 'DELETE_AUTH_USER_LAST');
  assert.ok(result.deletionJobStages.includes(DELETION_JOB_STAGE.AUTH_DELETED));
});

test('17. manual policy 항목이 있으면 canProceed=false', () => {
  const result = plan({ matches: { count: 1 }, matchMessages: { count: 1 } });
  assert.equal(result.manualPolicyRequired.length > 0, true);
  assert.equal(result.canProceed, false);
});

test('18. UID 원문 입력 또는 출력 금지', () => {
  const result = planAccountDeletion({
    uidHash: UID_HASH,
    rawUid: 'raw-user-id',
    resources: { users: { exists: true } },
  });
  assert.equal(result.canProceed, false);
  assert.equal(result.blockers[0].code, 'RAW_UID_OR_PII_PRESENT');

  const serialized = JSON.stringify(result);
  assert.equal(serialized.includes('raw-user-id'), false);
  assert.equal(serialized.includes(UID_HASH), true);
});

test('19. 동일 입력 deterministic', () => {
  const input = {
    uidHash: UID_HASH,
    resources: {
      users: { exists: true },
      swipesAuthored: { count: 1 },
      purchaseReceipts: { count: 1 },
    },
  };
  assert.deepEqual(planAccountDeletion(input), planAccountDeletion(input));
});

test('20. 실제 Firebase mutation API 호출 0', () => {
  const source = fs.readFileSync(
    path.join(__dirname, '..', 'lib', 'account_deletion_plan.js'),
    'utf8',
  );
  assert.equal(source.includes('firebase-admin'), false);
  assert.equal(source.includes('firebase-functions'), false);
  assert.equal(source.includes('runTransaction'), false);
  assert.equal(source.includes('.collection('), false);
  assert.equal(source.includes('FieldValue'), false);
});

test('21. callable 보안 계약은 대상 UID를 클라이언트에서 받지 않는다', () => {
  assert.equal(DELETE_MY_ACCOUNT_CONTRACT.authRequired, true);
  assert.equal(DELETE_MY_ACCOUNT_CONTRACT.targetUidSource, 'request.auth.uid');
  assert.equal(DELETE_MY_ACCOUNT_CONTRACT.acceptsTargetUidFromClient, false);
  assert.equal(DELETE_MY_ACCOUNT_CONTRACT.recentReauthenticationRequired, true);
  assert.equal(DELETE_MY_ACCOUNT_CONTRACT.authTimeVerifiedServerSide, true);
});

test('22. 리소스 계약은 실제 확인된 UID 저장 경로만 포함한다', () => {
  assert.equal(RESOURCE_CONTRACTS.users.path, 'users/{uid}');
  assert.equal(RESOURCE_CONTRACTS.publicProfiles.path, 'publicProfiles/{uid}');
  assert.equal(RESOURCE_CONTRACTS.matches.path, 'matches/{matchId}');
  assert.equal(RESOURCE_CONTRACTS.matchMessages.path, 'matches/{matchId}/messages/{messageId}');
  assert.equal(RESOURCE_CONTRACTS.purchaseReceipts.path, '_purchaseReceipts/{receiptHash}');
});

test('23. malformed resource count -> fail-closed', () => {
  const result = plan({ users: { count: -1 } });
  assert.equal(result.canProceed, false);
  assert.equal(result.blockers[0].code, 'MALFORMED_RESOURCE_COUNT');
});

test('24. 출력 entry는 uidHash만 포함하고 raw uid 필드는 포함하지 않는다', () => {
  const result = plan(
    {
      users: { exists: true },
      matches: { count: 1 },
      matchMessages: { count: 1 },
      purchaseReceipts: { count: 1 },
    },
    { sharedDataPolicy: SHARED_DATA_POLICY.ANONYMIZE_DELETED_PARTICIPANT },
  );
  for (const entry of allEntries(result)) {
    assert.equal(entry.uidHash, UID_HASH);
    assert.equal(Object.hasOwn(entry, 'uid'), false);
    assert.equal(Object.hasOwn(entry, 'rawUid'), false);
  }
});
