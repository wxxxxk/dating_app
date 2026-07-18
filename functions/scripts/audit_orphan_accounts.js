'use strict';

// Read-only orphan account lifecycle audit. This script performs Auth,
// Firestore, and Storage metadata reads only. It does not call callable
// functions and contains no production mutation API calls.

const admin = require('firebase-admin');
const {
  ACCOUNT_CATEGORY,
  CLEANUP_RECOMMENDATION,
  classifyAccount,
  summarizeClassifications,
} = require('../lib/orphan_account_lifecycle');

const EXPECTED_PROJECT_ID = 'cvr-dating-app';
const DEFAULT_PAGE_SIZE = 100;
const MAX_PAGE_SIZE = 1000;

function usage() {
  return [
    'Usage:',
    '  node functions/scripts/audit_orphan_accounts.js --project cvr-dating-app [options]',
    '',
    'Options:',
    '  --project <projectId>   Required Firebase project ID (must be cvr-dating-app)',
    '  --page-size <number>    Auth/Firestore page size, max 1000 (default 100)',
    '  --bucket <bucketName>   Optional Storage bucket name for users/{uid}/ metadata count',
    '  --help                  Show help',
    '',
    'Read-only only: Auth/Firestore/Storage metadata reads. No writes or deletes.',
  ].join('\n');
}

function parsePositiveInteger(raw, name) {
  if (!/^[1-9]\d*$/.test(String(raw))) {
    throw new Error(`${name} must be a positive integer`);
  }
  return Number(raw);
}

function parseArgs(argv) {
  const args = {
    project: null,
    pageSize: DEFAULT_PAGE_SIZE,
    bucket: null,
    help: false,
  };
  const forbidden = new Set([
    '--apply',
    '--write',
    '--fix',
    '--migrate',
    '--update',
    '--delete',
    '--cleanup',
    '--execute',
  ]);
  const seen = new Set();
  const mark = (arg) => {
    if (seen.has(arg)) throw new Error(`Duplicate argument: ${arg}`);
    seen.add(arg);
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (forbidden.has(arg)) {
      throw new Error(`Unsupported mutation-mode flag: ${arg}. This tool is read-only.`);
    }
    if (arg === '--help') {
      mark(arg);
      args.help = true;
    } else if (arg === '--project') {
      mark(arg);
      index += 1;
      if (!argv[index]) throw new Error('--project requires a value');
      args.project = argv[index];
    } else if (arg === '--page-size') {
      mark(arg);
      index += 1;
      if (!argv[index]) throw new Error('--page-size requires a value');
      args.pageSize = parsePositiveInteger(argv[index], '--page-size');
      if (args.pageSize > MAX_PAGE_SIZE) {
        throw new Error(`--page-size must be ${MAX_PAGE_SIZE} or less`);
      }
    } else if (arg === '--bucket') {
      mark(arg);
      index += 1;
      if (!argv[index]) throw new Error('--bucket requires a value');
      args.bucket = argv[index];
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }

  if (!args.help && !args.project) throw new Error('--project is required');
  return args;
}

function assertProjectAllowed(projectId) {
  if (projectId !== EXPECTED_PROJECT_ID) {
    throw new Error(
      `Refusing to run against project ${projectId}; expected ${EXPECTED_PROJECT_ID}`,
    );
  }
}

function initializeFirebase(projectId, bucketName) {
  if (admin.apps.length === 0) {
    admin.initializeApp({ projectId, storageBucket: bucketName || undefined });
  }
  return {
    auth: admin.auth(),
    db: admin.firestore(),
    bucket: bucketName ? admin.storage().bucket(bucketName) : admin.storage().bucket(),
  };
}

function classifyReadError(error) {
  const text = [
    error?.code,
    error?.name,
    error?.details,
    error?.message,
  ].filter(Boolean).join(' ').toLowerCase();
  if (/invalid_grant|reauth/.test(text)) return 'ADC_REFRESH_FAILED';
  if (/default credentials|application default credentials/.test(text)) return 'ADC_UNAVAILABLE';
  if (/permission[-_\s]?denied|\b7\b/.test(text)) return 'PERMISSION_DENIED';
  if (/unauthenticated|\b16\b/.test(text)) return 'UNAUTHENTICATED';
  if (/enotfound|eai_again/.test(text)) return 'DNS_FAILURE';
  if (/econnrefused|econnreset|network unavailable/.test(text)) return 'NETWORK_UNAVAILABLE';
  if (/timeout|deadline exceeded|etimedout/.test(text)) return 'CONNECTION_TIMEOUT';
  if (/resource exhausted|quota/.test(text)) return 'RESOURCE_EXHAUSTED';
  if (/service disabled|api has not been used|unavailable/.test(text)) return 'SERVICE_UNAVAILABLE';
  return 'UNKNOWN_RUNTIME_ERROR';
}

async function listAuthUsers(auth, pageSize) {
  const records = new Map();
  let pageToken;
  do {
    const page = await auth.listUsers(pageSize, pageToken);
    for (const record of page.users) records.set(record.uid, record);
    pageToken = page.pageToken;
  } while (pageToken);
  return records;
}

async function scanCollectionDocs(db, collectionName, pageSize) {
  const documentId = admin.firestore.FieldPath.documentId();
  const docs = new Map();
  let lastId = null;
  for (;;) {
    let query = db
      .collection(collectionName)
      .orderBy(documentId)
      .limit(pageSize);
    if (lastId !== null) query = query.startAfter(lastId);
    const page = await query.get();
    if (page.empty) break;
    for (const doc of page.docs) docs.set(doc.id, doc.data());
    lastId = page.docs[page.docs.length - 1].id;
    if (page.size < pageSize) break;
  }
  return docs;
}

function ensureReference(refs, uid) {
  if (!refs.has(uid)) refs.set(uid, {});
  return refs.get(uid);
}

function markReference(refs, uid, key) {
  if (typeof uid !== 'string' || uid.length === 0) return;
  ensureReference(refs, uid)[key] = true;
}

async function collectReferenceMap(db, uidSet) {
  const refs = new Map();

  const swipesSnap = await db.collectionGroup('swipes').select('actorUid', 'targetUid').get();
  for (const doc of swipesSnap.docs) {
    const actorUid = doc.get('actorUid');
    const targetUid = doc.get('targetUid');
    if (uidSet.has(actorUid)) markReference(refs, actorUid, 'hasLikeReference');
    if (uidSet.has(targetUid)) markReference(refs, targetUid, 'hasLikeReference');
  }

  const matchesSnap = await db.collection('matches').select('participants', 'uid1', 'uid2').get();
  for (const doc of matchesSnap.docs) {
    const participants = doc.get('participants');
    const members = new Set([
      ...(Array.isArray(participants) ? participants : []),
      doc.get('uid1'),
      doc.get('uid2'),
    ].filter((uid) => typeof uid === 'string'));
    const involved = [...members].filter((uid) => uidSet.has(uid));
    if (involved.length === 0) continue;
    for (const uid of involved) markReference(refs, uid, 'hasMatchReference');
    const messagesSnap = await doc.ref.collection('messages').select('senderId').limit(1).get();
    if (!messagesSnap.empty) {
      for (const uid of involved) markReference(refs, uid, 'hasChatOrMessageReference');
    }
  }

  try {
    const blocksSnap = await db.collectionGroup('blocks').select('blockerUid', 'blockedUid').get();
    for (const doc of blocksSnap.docs) {
      const blockerUid = doc.get('blockerUid');
      const blockedUid = doc.get('blockedUid');
      if (uidSet.has(blockerUid)) markReference(refs, blockerUid, 'hasBlockReference');
      if (uidSet.has(blockedUid)) markReference(refs, blockedUid, 'hasBlockReference');
    }
  } catch (_) {
    // Absence of collectionGroup data is treated as no block references.
  }

  try {
    const reportsSnap = await db.collection('reports').select('reporterUid', 'reportedUid').get();
    for (const doc of reportsSnap.docs) {
      const reporterUid = doc.get('reporterUid');
      const reportedUid = doc.get('reportedUid');
      if (uidSet.has(reporterUid)) markReference(refs, reporterUid, 'hasReportReference');
      if (uidSet.has(reportedUid)) markReference(refs, reportedUid, 'hasReportReference');
    }
  } catch (_) {
    // Reports may be absent in early projects.
  }

  try {
    const receiptSnap = await db.collection('_purchaseReceipts').select('uid').get();
    for (const doc of receiptSnap.docs) {
      const uid = doc.get('uid');
      if (uidSet.has(uid)) markReference(refs, uid, 'hasPurchaseReference');
    }
  } catch (_) {
    // If the internal receipt collection is absent, there are no receipt docs.
  }

  for (const uid of uidSet) {
    const txSnap = await db
      .collection('users')
      .doc(uid)
      .collection('jellyTransactions')
      .select('type', 'amount')
      .limit(1)
      .get();
    if (!txSnap.empty) markReference(refs, uid, 'hasJellyTransactionReference');
  }

  return refs;
}

async function countStorageObjectsByUid(bucket, uidSet) {
  const result = new Map();
  let storageReadError = null;
  for (const uid of uidSet) {
    try {
      const [files] = await bucket.getFiles({ prefix: `users/${uid}/`, maxResults: 1000 });
      result.set(uid, files.length);
    } catch (error) {
      storageReadError = classifyReadError(error);
      result.set(uid, 0);
      break;
    }
  }
  return { storageCounts: result, storageReadError };
}

async function runAudit({ auth, db, bucket, pageSize, nowMs = Date.now() }) {
  const authRecords = await listAuthUsers(auth, pageSize);
  const usersDocs = await scanCollectionDocs(db, 'users', pageSize);
  const publicDocs = await scanCollectionDocs(db, 'publicProfiles', pageSize);
  const uidSet = new Set([
    ...authRecords.keys(),
    ...usersDocs.keys(),
    ...publicDocs.keys(),
  ]);
  const refs = await collectReferenceMap(db, uidSet);
  const { storageCounts, storageReadError } = await countStorageObjectsByUid(bucket, uidSet);

  const entries = [...uidSet].sort().map((uid) => {
    const reference = {
      ...(refs.get(uid) || {}),
      hasReadError: Boolean(storageReadError),
    };
    const storageObjectCount = storageCounts.get(uid) || 0;
    return classifyAccount({
      uid,
      authRecord: authRecords.get(uid),
      usersData: usersDocs.get(uid),
      publicData: publicDocs.get(uid),
      references: reference,
      storageObjectCount,
      nowMs,
    });
  });

  return {
    authUsersScanned: authRecords.size,
    usersDocumentsFound: usersDocs.size,
    publicProfilesDocumentsFound: publicDocs.size,
    storageReadError,
    entries,
    summary: summarizeClassifications(entries),
    writesAttempted: 0,
    deletesAttempted: 0,
    authMutations: 0,
    firestoreMutations: 0,
    storageMutations: 0,
  };
}

function printAudit(report, project) {
  console.log('=== Orphan Account Lifecycle Audit (read-only) ===');
  console.log(`project: ${project}`);
  console.log('mode: dry-run');
  console.log(`authUsersScanned: ${report.authUsersScanned}`);
  console.log(`usersDocumentsFound: ${report.usersDocumentsFound}`);
  console.log(`publicProfilesDocumentsFound: ${report.publicProfilesDocumentsFound}`);
  console.log(`storageReadError: ${report.storageReadError || '-'}`);
  console.log(`totalAccounts: ${report.summary.totalAccounts}`);
  console.log(`categoryCounts: ${JSON.stringify(report.summary.byCategory)}`);
  console.log(`recommendationCounts: ${JSON.stringify(report.summary.byRecommendation)}`);
  console.log(`candidatesWithReferences: ${report.summary.candidatesWithReferences}`);
  console.log(`safeDeleteCandidates: ${report.summary.safeDeleteCandidates}`);
  console.log(`repairCandidates: ${report.summary.repairCandidates}`);
  console.log(`manualReviewRequired: ${report.summary.manualReviewRequired}`);
  console.log('--- Entries ---');
  for (const entry of report.entries) {
    if (
      entry.category === ACCOUNT_CATEGORY.HEALTHY &&
      entry.recommendation === CLEANUP_RECOMMENDATION.RETAIN
    ) {
      continue;
    }
    console.log(JSON.stringify(entry));
  }
  console.log('--- Safety ---');
  console.log(`writesAttempted: ${report.writesAttempted}`);
  console.log(`deletesAttempted: ${report.deletesAttempted}`);
  console.log(`authMutations: ${report.authMutations}`);
  console.log(`firestoreMutations: ${report.firestoreMutations}`);
  console.log(`storageMutations: ${report.storageMutations}`);
}

async function main() {
  let args;
  try {
    args = parseArgs(process.argv.slice(2));
    if (args.help) {
      console.log(usage());
      return 0;
    }
    assertProjectAllowed(args.project);
  } catch (error) {
    console.error(error.message);
    console.error(usage());
    return 2;
  }

  try {
    const clients = initializeFirebase(args.project, args.bucket);
    const report = await runAudit({
      auth: clients.auth,
      db: clients.db,
      bucket: clients.bucket,
      pageSize: args.pageSize,
    });
    printAudit(report, args.project);
    return 0;
  } catch (error) {
    console.error(`auditFailedCategory: ${classifyReadError(error)}`);
    console.error('writesAttempted: 0');
    console.error('deletesAttempted: 0');
    return 1;
  }
}

if (require.main === module) {
  main().then((code) => {
    process.exitCode = code;
  });
}

module.exports = {
  parseArgs,
  assertProjectAllowed,
  classifyReadError,
  runAudit,
};
