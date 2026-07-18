'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const admin = require('firebase-admin');

const {
  JOB_STATUS,
  deleteMyAccountCore,
  deletedIdentifierForUid,
  uidHashFor,
} = require('../lib/account_deletion');
const {
  PurchaseVerificationError,
  buildObfuscatedExternalAccountId,
  receiptHashForAndroid,
  verifyJellyPurchaseCore,
} = require('../lib/jelly_purchase_verification');

const PROJECT_ID = 'demo-cvr-dating-app';
const BUCKET_NAME = `${PROJECT_ID}.appspot.com`;
const RUN_EMULATOR_TESTS = process.env.RUN_ACCOUNT_DELETION_EMULATOR_TESTS === '1';

function requireEmulatorEnvironment() {
  assert.equal(process.env.GCLOUD_PROJECT || PROJECT_ID, PROJECT_ID);
  assert.ok(process.env.FIRESTORE_EMULATOR_HOST, 'FIRESTORE_EMULATOR_HOST is required');
  assert.ok(process.env.FIREBASE_AUTH_EMULATOR_HOST, 'FIREBASE_AUTH_EMULATOR_HOST is required');
  assert.ok(process.env.FIREBASE_STORAGE_EMULATOR_HOST, 'FIREBASE_STORAGE_EMULATOR_HOST is required');
}

function initAdmin() {
  requireEmulatorEnvironment();
  const existing = admin.apps.find((app) => app.name === 'account-deletion-e2e');
  if (existing) return existing;
  return admin.initializeApp({
    projectId: PROJECT_ID,
    storageBucket: BUCKET_NAME,
  }, 'account-deletion-e2e');
}

async function clearAuth(auth) {
  let nextPageToken;
  do {
    const page = await auth.listUsers(1000, nextPageToken);
    await Promise.all(page.users.map((user) => auth.deleteUser(user.uid).catch(() => {})));
    nextPageToken = page.pageToken;
  } while (nextPageToken);
}

async function clearFirestore(db) {
  const collections = await db.listCollections();
  for (const collection of collections) {
    const snapshot = await collection.get();
    for (const doc of snapshot.docs) {
      await db.recursiveDelete(doc.ref);
    }
  }
}

async function clearStorage(bucket) {
  const [files] = await bucket.getFiles();
  await Promise.all(files.map((file) => file.delete().catch(() => {})));
}

async function clearAll({ auth, db, bucket }) {
  await Promise.all([
    clearAuth(auth),
    clearFirestore(db),
    clearStorage(bucket),
  ]);
}

function serverTimestamp() {
  return admin.firestore.FieldValue.serverTimestamp();
}

function fieldDelete() {
  return admin.firestore.FieldValue.delete();
}

function request(uid, authTimeSeconds) {
  return {
    auth: { uid, token: { auth_time: authTimeSeconds } },
    data: { confirmation: 'DELETE_MY_ACCOUNT' },
  };
}

async function seedE2EGraph({ auth, db, bucket }) {
  const uid = 'delete-user-e2e';
  const otherUid = 'other-user-e2e';
  const thirdUid = 'receipt-replay-user';
  const uidHash = uidHashFor(uid);
  const deletedIdentifier = deletedIdentifierForUid(uid);
  const matchId = 'delete-user-e2e_other-user-e2e';
  const activeMatchId = 'other-user-e2e_third-user-e2e';
  const receiptHash = receiptHashForAndroid('emulator-token-1');
  const unrelatedReceiptHash = receiptHashForAndroid('emulator-token-unrelated');

  await auth.createUser({ uid, email: 'delete@example.test', password: 'Password123!' });
  await auth.createUser({ uid: otherUid, email: 'other@example.test', password: 'Password123!' });
  await auth.createUser({ uid: thirdUid, email: 'third@example.test', password: 'Password123!' });

  await Promise.all([
    db.collection('users').doc(uid).set({ displayName: 'Delete', jelly: 30 }),
    db.collection('publicProfiles').doc(uid).set({ displayName: 'Delete', photoUrls: [] }),
    db.collection('users').doc(otherUid).set({ displayName: 'Other', jelly: 0 }),
    db.collection('publicProfiles').doc(otherUid).set({ displayName: 'Other', photoUrls: [] }),
    db.collection('users').doc(thirdUid).set({ displayName: 'Third', jelly: 0 }),
  ]);

  await Promise.all([
    db.collection('users').doc(uid).collection('dailyFortune').doc('2026-07-19').set({ message: 'private' }),
    db.collection('users').doc(uid).collection('swipes').doc(otherUid).set({
      actorUid: uid,
      targetUid: otherUid,
      action: 'like',
    }),
    db.collection('users').doc(uid).collection('blocks').doc('blocked-user').set({
      blockerUid: uid,
      blockedUid: 'blocked-user',
    }),
    db.collection('users').doc(uid).collection('jellyTransactions').doc('jelly-tx-1').set({
      amount: -5,
      type: 'spend',
      reason: 'superlike',
      createdAt: admin.firestore.Timestamp.fromMillis(1000),
      productId: 'jelly_30',
    }),
    db.collection('users').doc(otherUid).collection('swipes').doc(uid).set({
      actorUid: otherUid,
      targetUid: uid,
      action: 'like',
    }),
    db.collection('users').doc(otherUid).collection('blocks').doc(uid).set({
      blockerUid: otherUid,
      blockedUid: uid,
    }),
    db.collection('users').doc(otherUid).collection('swipes').doc('unrelated').set({
      actorUid: otherUid,
      targetUid: 'unrelated',
      action: 'pass',
    }),
    db.collection('users').doc(otherUid).collection('blocks').doc('unrelated').set({
      blockerUid: otherUid,
      blockedUid: 'unrelated',
    }),
    db.collection('_purchaseVerificationUsage').doc(uid).set({ hourCount: 3 }),
    db.collection('_internalAiUsage').doc(uid).collection('functions').doc('generateDailyFortune').set({ hourCount: 1 }),
  ]);

  await Promise.all([
    db.collection('matches').doc(matchId).set({
      participants: [uid, otherUid],
      uid1: uid,
      uid2: otherUid,
      matchedAt: admin.firestore.Timestamp.fromMillis(2000),
      lastMessage: {
        text: 'last content',
        senderId: uid,
        createdAt: admin.firestore.Timestamp.fromMillis(3000),
      },
      lastReadAtByUid: {
        [uid]: admin.firestore.Timestamp.fromMillis(3000),
        [otherUid]: admin.firestore.Timestamp.fromMillis(3500),
      },
      celebratedBy: [uid, otherUid],
      unmatchedBy: [],
    }),
    db.collection('matches').doc(matchId).collection('messages').doc('m1').set({
      senderId: uid,
      text: 'delete user message content',
      createdAt: admin.firestore.Timestamp.fromMillis(3100),
      senderName: 'Delete',
      senderPhotoUrl: 'https://example.test/photo.jpg',
    }),
    db.collection('matches').doc(matchId).collection('messages').doc('m2').set({
      senderId: otherUid,
      text: 'other user message content',
      createdAt: admin.firestore.Timestamp.fromMillis(3200),
    }),
    db.collection('matches').doc(activeMatchId).set({
      participants: [otherUid, thirdUid],
      uid1: otherUid,
      uid2: thirdUid,
      matchedAt: admin.firestore.Timestamp.fromMillis(2100),
      unmatchedBy: [],
    }),
    db.collection('matches').doc(activeMatchId).collection('messages').doc('m1').set({
      senderId: otherUid,
      text: 'unrelated active message',
      createdAt: admin.firestore.Timestamp.fromMillis(2200),
    }),
  ]);

  await Promise.all([
    db.collection('reports').doc('report-subject').set({
      reporterUid: otherUid,
      reportedUid: uid,
      reason: 'spam_scam',
      detail: 'safe retained detail',
    }),
    db.collection('reports').doc('report-reporter').set({
      reporterUid: uid,
      reportedUid: otherUid,
      reason: 'other',
      reporterName: 'Delete',
    }),
    db.collection('reports').doc('report-unrelated').set({
      reporterUid: otherUid,
      reportedUid: thirdUid,
      reason: 'spam_scam',
    }),
    db.collection('_purchaseReceipts').doc(receiptHash).set({
      uid,
      receiptHash,
      productId: 'jelly_30',
      platform: 'android',
      grantedJellyAmount: 30,
      status: 'granted',
    }),
    db.collection('_purchaseReceipts').doc(unrelatedReceiptHash).set({
      uid: otherUid,
      receiptHash: unrelatedReceiptHash,
      productId: 'jelly_30',
      platform: 'android',
      grantedJellyAmount: 30,
      status: 'granted',
    }),
  ]);

  await Promise.all([
    bucket.file(`${uid}/wrong-prefix.txt`).save('not targeted'),
    bucket.file(`users/${uid}/profile/a.jpg`).save('profile'),
    bucket.file(`users/${uid}/other/b.txt`).save('other'),
    bucket.file(`users/${otherUid}/profile/keep.jpg`).save('keep'),
  ]);

  return {
    uid,
    otherUid,
    thirdUid,
    uidHash,
    deletedIdentifier,
    matchId,
    activeMatchId,
    receiptHash,
    unrelatedReceiptHash,
  };
}

function assertNoRawUid(value, uid, path = 'value') {
  if (typeof value === 'string') {
    assert.notEqual(value, uid, `${path} contains raw uid`);
    assert.equal(value.includes(uid), false, `${path} embeds raw uid`);
    return;
  }
  if (Array.isArray(value)) {
    value.forEach((entry, index) => assertNoRawUid(entry, uid, `${path}[${index}]`));
    return;
  }
  if (value && typeof value === 'object') {
    for (const [key, entry] of Object.entries(value)) {
      assert.notEqual(key, uid, `${path} has raw uid key`);
      assertNoRawUid(entry, uid, `${path}.${key}`);
    }
  }
}

test('account deletion emulator E2E', { skip: !RUN_EMULATOR_TESTS }, async () => {
  const app = initAdmin();
  const auth = admin.auth(app);
  const db = admin.firestore(app);
  const bucket = admin.storage(app).bucket(BUCKET_NAME);
  await clearAll({ auth, db, bucket });

  const graph = await seedE2EGraph({ auth, db, bucket });
  const nowMs = Date.now();
  const result = await deleteMyAccountCore({
    request: request(graph.uid, Math.floor(nowMs / 1000)),
    db,
    auth,
    storageBucket: bucket,
    serverTimestamp,
    fieldDelete,
    nowMs: () => nowMs,
    logger: { log: () => {} },
  });

  assert.equal(result.status, JOB_STATUS.COMPLETED);
  await assert.rejects(auth.getUser(graph.uid), /no user record|not found/i);
  assert.equal((await db.collection('users').doc(graph.uid).get()).exists, false);
  assert.equal((await db.collection('publicProfiles').doc(graph.uid).get()).exists, false);
  assert.equal((await db.collection('users').doc(graph.uid).collection('dailyFortune').doc('2026-07-19').get()).exists, false);
  assert.equal((await db.collection('users').doc(graph.uid).collection('swipes').doc(graph.otherUid).get()).exists, false);
  assert.equal((await db.collection('users').doc(graph.uid).collection('blocks').doc('blocked-user').get()).exists, false);
  assert.equal((await db.collection('users').doc(graph.otherUid).collection('swipes').doc(graph.uid).get()).exists, false);
  assert.equal((await db.collection('users').doc(graph.otherUid).collection('blocks').doc(graph.uid).get()).exists, false);
  assert.equal((await db.collection('_purchaseVerificationUsage').doc(graph.uid).get()).exists, false);
  assert.equal((await db.collection('_internalAiUsage').doc(graph.uid).collection('functions').doc('generateDailyFortune').get()).exists, false);

  const [deletedFiles] = await bucket.getFiles({ prefix: `users/${graph.uid}/` });
  assert.equal(deletedFiles.length, 0);
  assert.equal((await bucket.file(`users/${graph.otherUid}/profile/keep.jpg`).exists())[0], true);

  assert.equal((await db.collection('users').doc(graph.otherUid).get()).exists, true);
  assert.equal((await db.collection('publicProfiles').doc(graph.otherUid).get()).exists, true);
  assert.equal((await db.collection('users').doc(graph.otherUid).collection('swipes').doc('unrelated').get()).exists, true);
  assert.equal((await db.collection('users').doc(graph.otherUid).collection('blocks').doc('unrelated').get()).exists, true);

  const match = (await db.collection('matches').doc(graph.matchId).get()).data();
  assert.ok(match);
  assert.deepEqual(match.participants.sort(), [graph.deletedIdentifier, graph.otherUid].sort());
  assert.equal(match.uid1, graph.deletedIdentifier);
  assert.equal(match.uid2, graph.otherUid);
  assert.ok(match.unmatchedBy.includes(graph.deletedIdentifier));
  assert.equal(Object.hasOwn(match.lastReadAtByUid, graph.uid), false);
  assert.equal(Object.hasOwn(match.lastReadAtByUid, graph.otherUid), true);
  assert.equal(match.lastMessage.senderId, graph.deletedIdentifier);
  assertNoRawUid(match, graph.uid, 'match');

  const deletedMessage = (await db.collection('matches').doc(graph.matchId).collection('messages').doc('m1').get()).data();
  const otherMessage = (await db.collection('matches').doc(graph.matchId).collection('messages').doc('m2').get()).data();
  assert.equal(deletedMessage.senderId, graph.deletedIdentifier);
  assert.equal(deletedMessage.senderDeleted, true);
  assert.equal(deletedMessage.text, 'delete user message content');
  assert.equal(Object.hasOwn(deletedMessage, 'senderName'), false);
  assert.equal(Object.hasOwn(deletedMessage, 'senderPhotoUrl'), false);
  assert.equal(otherMessage.senderId, graph.otherUid);
  assert.equal(otherMessage.text, 'other user message content');

  const activeMessage = await db.collection('matches').doc(graph.activeMatchId).collection('messages').doc('m1').get();
  assert.equal(activeMessage.exists, true);

  const reportSubject = (await db.collection('reports').doc('report-subject').get()).data();
  const reportReporter = (await db.collection('reports').doc('report-reporter').get()).data();
  const reportUnrelated = (await db.collection('reports').doc('report-unrelated').get()).data();
  assert.equal(reportSubject.reportedUid, graph.deletedIdentifier);
  assert.equal(reportSubject.reporterUid, graph.otherUid);
  assert.equal(reportReporter.reporterUid, graph.deletedIdentifier);
  assert.equal(reportReporter.reportedUid, graph.otherUid);
  assert.equal(Object.hasOwn(reportReporter, 'reporterName'), false);
  assert.equal(reportUnrelated.reporterUid, graph.otherUid);
  assert.equal(reportUnrelated.reportedUid, graph.thirdUid);

  const receipt = (await db.collection('_purchaseReceipts').doc(graph.receiptHash).get()).data();
  const unrelatedReceipt = (await db.collection('_purchaseReceipts').doc(graph.unrelatedReceiptHash).get()).data();
  assert.equal(Object.hasOwn(receipt, 'uid'), false);
  assert.equal(receipt.deletedSubjectHash, graph.uidHash);
  assert.equal(receipt.receiptHash, graph.receiptHash);
  assert.equal(receipt.productId, 'jelly_30');
  assert.equal(receipt.grantedJellyAmount, 30);
  assert.equal(unrelatedReceipt.uid, graph.otherUid);

  const auditTxs = await db.collection('_deletedAccountAudit').doc(graph.uidHash).collection('jellyTransactions').get();
  assert.equal(auditTxs.size, 1);
  const auditTx = auditTxs.docs[0].data();
  assert.equal(auditTx.amount, -5);
  assert.equal(auditTx.type, 'spend');
  assert.equal(auditTx.reason, 'superlike');
  assertNoRawUid(auditTx, graph.uid, 'auditTx');

  let providerCalls = 0;
  await assert.rejects(
    verifyJellyPurchaseCore({
      request: {
        auth: { uid: graph.thirdUid },
        data: {
          platform: 'android',
          productId: 'jelly_30',
          purchaseToken: 'emulator-token-1',
        },
      },
      db,
      serverTimestamp,
      logger: { log: () => {} },
      nowMs: () => nowMs + 10_000,
      verifyAndroidPurchase: async () => {
        providerCalls += 1;
        return {
          packageName: 'com.cvrlab.dating_app',
          productId: 'jelly_30',
          purchaseState: 0,
          consumptionState: 0,
          purchaseTimeMillis: String(nowMs),
          quantity: 1,
          obfuscatedExternalAccountId: buildObfuscatedExternalAccountId(graph.thirdUid),
        };
      },
    }),
    (error) => error instanceof PurchaseVerificationError && error.code === 'permission-denied',
  );
  assert.equal(providerCalls, 0);
  assert.equal((await db.collection('users').doc(graph.thirdUid).get()).data().jelly, 0);

  const second = await deleteMyAccountCore({
    request: request(graph.uid, Math.floor(nowMs / 1000)),
    db,
    auth,
    storageBucket: bucket,
    serverTimestamp,
    fieldDelete,
    nowMs: () => nowMs + 1000,
    logger: { log: () => {} },
  });
  assert.equal(second.alreadyCompleted, true);
});
