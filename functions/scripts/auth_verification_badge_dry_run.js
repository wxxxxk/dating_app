'use strict';

// Read-only production audit for the auth verification badge server-only
// migration. Uses Firebase Auth as the canonical source and compares against
// users/{uid}.verifications and publicProfiles/{uid}.verifications. This tool
// NEVER writes: no Firestore mutation API is used in this file or in
// ../lib/auth_verification_badge_audit.

const admin = require('firebase-admin');
const {
  VERIFICATION_KEYS,
  analyzeUser,
  createEmptyAggregate,
  recordAnalysis,
  classificationInvariantHolds,
  countOrphanDocumentIds,
} = require('../lib/auth_verification_badge_audit');

const EXPECTED_PROJECT_ID = 'cvr-dating-app';
const DEFAULT_PAGE_SIZE = 100;
const MAX_PAGE_SIZE = 1000;

function usage() {
  return [
    'Usage:',
    '  npm --prefix functions run audit:auth-verification-badges -- --project cvr-dating-app [options]',
    '',
    'Options:',
    '  --project <projectId>   Required Firebase project ID (must be cvr-dating-app)',
    '  --uid <uid>             Audit one user without scanning collections',
    '  --limit <number>        Maximum Auth users to audit',
    '  --page-size <number>    Page size for Auth/collection scan, max 1000 (default 100)',
    '  --help                  Show this help',
    '',
    'This tool is read-only. It performs no writes and applies no migration.',
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
    uid: null,
    limit: null,
    pageSize: DEFAULT_PAGE_SIZE,
    help: false,
  };
  const seen = new Set();

  function markSeen(option) {
    if (seen.has(option)) {
      throw new Error(`Duplicate argument: ${option}`);
    }
    seen.add(option);
  }

  const forbidden = new Set([
    '--apply',
    '--write',
    '--fix',
    '--migrate',
    '--update',
    '--delete',
  ]);

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (forbidden.has(arg)) {
      throw new Error(`Unsupported write-mode flag: ${arg}. This tool is read-only.`);
    }
    if (arg === '--help') {
      markSeen(arg);
      args.help = true;
    } else if (arg === '--project') {
      markSeen(arg);
      index += 1;
      if (!argv[index]) throw new Error('--project requires a value');
      args.project = argv[index];
    } else if (arg === '--uid') {
      markSeen(arg);
      index += 1;
      if (!argv[index]) throw new Error('--uid requires a value');
      args.uid = argv[index];
    } else if (arg === '--limit') {
      markSeen(arg);
      index += 1;
      if (!argv[index]) throw new Error('--limit requires a value');
      args.limit = parsePositiveInteger(argv[index], '--limit');
    } else if (arg === '--page-size') {
      markSeen(arg);
      index += 1;
      if (!argv[index]) throw new Error('--page-size requires a value');
      args.pageSize = parsePositiveInteger(argv[index], '--page-size');
      if (args.pageSize > MAX_PAGE_SIZE) {
        throw new Error(`--page-size must be ${MAX_PAGE_SIZE} or less`);
      }
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }

  if (!args.help && !args.project) {
    throw new Error('--project is required');
  }

  return args;
}

function assertProjectAllowed(projectId) {
  if (projectId !== EXPECTED_PROJECT_ID) {
    throw new Error(
      `Refusing to run against project ${projectId}; expected ${EXPECTED_PROJECT_ID}`,
    );
  }
}

function initializeFirebase(projectId) {
  if (admin.apps.length === 0) {
    admin.initializeApp({ projectId });
  }
  return { auth: admin.auth(), db: admin.firestore() };
}

function rawDiagnosticText(error) {
  const parts = [];
  const queue = [error, error && error.cause].filter(Boolean);
  for (const item of queue) {
    for (const key of ['code', 'errorInfo', 'name', 'details', 'message']) {
      const value = item[key];
      if (typeof value === 'string' || typeof value === 'number') {
        parts.push(String(value));
      } else if (value && typeof value === 'object' && typeof value.code === 'string') {
        parts.push(value.code);
      }
    }
  }
  return parts.join(' ').toLowerCase();
}

// Map any read error to a small, safe error code. Never surfaces the raw error
// object, stack, or credential path.
function classifyReadError(error, phase = 'read') {
  const text = rawDiagnosticText(error);
  let category = 'UNKNOWN_RUNTIME_ERROR';

  if (/invalid_grant|reauth/.test(text)) {
    category = 'ADC_REFRESH_FAILED';
  } else if (/could not load the default credentials|application default credentials|default credentials/.test(text)) {
    category = 'ADC_UNAVAILABLE';
  } else if (/\b(7|permission[-_\s]?denied)\b/.test(text)) {
    category = 'PERMISSION_DENIED';
  } else if (/\b(16|unauthenticated)\b/.test(text)) {
    category = 'UNAUTHENTICATED';
  } else if (/enotfound|eai_again/.test(text)) {
    category = 'DNS_FAILURE';
  } else if (/econnrefused|econnreset|eperm|network unavailable/.test(text)) {
    category = 'NETWORK_UNAVAILABLE';
  } else if (/etimedout|deadline exceeded|timeout/.test(text)) {
    category = 'CONNECTION_TIMEOUT';
  } else if (/auth\/|identitytoolkit|user-not-found/.test(text)) {
    category = 'AUTH_API_UNAVAILABLE';
  } else if (/api has not been used|service disabled|api disabled|firestore.*unavailable/.test(text)) {
    category = 'FIRESTORE_API_UNAVAILABLE';
  } else if (/project not found/.test(text)) {
    category = 'PROJECT_NOT_FOUND';
  } else if (/resource exhausted|quota/.test(text)) {
    category = 'RESOURCE_EXHAUSTED';
  } else if (/unavailable|service unavailable/.test(text)) {
    category = 'FIRESTORE_API_UNAVAILABLE';
  }

  return { category, phase };
}

function recordErrorCategory(aggregate, category) {
  aggregate.errorCodeCounts[category] =
    (aggregate.errorCodeCounts[category] || 0) + 1;
}

function snapshotData(snapshot) {
  return snapshot && snapshot.exists ? snapshot.data() : undefined;
}

function printPerUser(analysis) {
  const usersChanged = analysis.users.changedKeys.join(',') || '-';
  const publicChanged = analysis.public.changedKeys.join(',') || '-';
  console.log(
    [
      `uidHash=${analysis.uidHash}`,
      `classification=${analysis.classification}`,
      `usersChangedKeys=${usersChanged}`,
      `publicChangedKeys=${publicChanged}`,
      `usersVerificationShape=${analysis.users.shape || '-'}`,
      `publicProfileVerificationShape=${analysis.public.shape || '-'}`,
    ].join(' '),
  );
}

async function auditSingleUser(auth, db, uid, aggregate, { verbose }) {
  const userRecord = await auth.getUser(uid);
  const userRef = db.collection('users').doc(uid);
  const publicRef = db.collection('publicProfiles').doc(uid);
  const [userSnap, publicSnap] = await db.getAll(userRef, publicRef);

  const analysis = analyzeUser({
    uid,
    userRecord,
    usersExists: userSnap.exists,
    usersData: snapshotData(userSnap),
    publicExists: publicSnap.exists,
    publicData: snapshotData(publicSnap),
  });
  recordAnalysis(aggregate, analysis);
  aggregate.usersDocumentsFound = userSnap.exists ? 1 : 0;
  aggregate.publicProfilesDocumentsFound = publicSnap.exists ? 1 : 0;
  if (verbose) printPerUser(analysis);
}

async function auditAllUsers(auth, db, args, aggregate, authUids) {
  let pageToken;
  let remaining = args.limit;

  do {
    const batchSize =
      remaining === null ? args.pageSize : Math.min(args.pageSize, remaining);
    const page = await auth.listUsers(batchSize, pageToken);
    if (page.users.length === 0) break;

    const uids = page.users.map((user) => user.uid);
    const userRefs = uids.map((uid) => db.collection('users').doc(uid));
    const publicRefs = uids.map((uid) => db.collection('publicProfiles').doc(uid));
    const [userSnaps, publicSnaps] = await Promise.all([
      db.getAll(...userRefs),
      db.getAll(...publicRefs),
    ]);
    const userById = new Map(userSnaps.map((snap) => [snap.id, snap]));
    const publicById = new Map(publicSnaps.map((snap) => [snap.id, snap]));

    for (const userRecord of page.users) {
      const uid = userRecord.uid;
      authUids.add(uid);
      try {
        const userSnap = userById.get(uid);
        const publicSnap = publicById.get(uid);
        const analysis = analyzeUser({
          uid,
          userRecord,
          usersExists: Boolean(userSnap && userSnap.exists),
          usersData: snapshotData(userSnap),
          publicExists: Boolean(publicSnap && publicSnap.exists),
          publicData: snapshotData(publicSnap),
        });
        recordAnalysis(aggregate, analysis);
      } catch (error) {
        const analysis = analyzeUser({ uid, userRecord: null, readError: true });
        recordAnalysis(aggregate, analysis);
        recordErrorCategory(aggregate, classifyReadError(error, 'per_user_read').category);
      }
    }

    pageToken = page.pageToken;
    if (remaining !== null) {
      remaining -= page.users.length;
      if (remaining <= 0) break;
    }
  } while (pageToken);
}

// Read-only scan of a collection's document IDs (no field data) to count total
// documents and orphans whose ID has no matching Auth account.
async function scanCollectionIds(db, collectionName, authUids, pageSize) {
  const documentId = admin.firestore.FieldPath.documentId();
  let lastId = null;
  let total = 0;
  let orphans = 0;

  for (;;) {
    let query = db
      .collection(collectionName)
      .select()
      .orderBy(documentId)
      .limit(pageSize);
    if (lastId !== null) {
      query = query.startAfter(lastId);
    }
    const page = await query.get();
    if (page.empty) break;
    const pageResult = countOrphanDocumentIds(
      page.docs.map((doc) => doc.id),
      authUids,
    );
    total += pageResult.total;
    orphans += pageResult.orphans;
    lastId = page.docs[page.docs.length - 1].id;
    if (page.size < pageSize) break;
  }

  return { total, orphans };
}

function printSummary(aggregate) {
  const fields = [
    'project',
    'mode',
    'authUsersScanned',
    'usersDocumentsFound',
    'publicProfilesDocumentsFound',
    'inSync',
    'wouldUpdateUsersOnly',
    'wouldUpdatePublicProfileOnly',
    'wouldUpdateBoth',
    'missingUsersDocuments',
    'missingPublicProfileDocuments',
    'missingBothDocuments',
    'malformedUsersVerifications',
    'malformedPublicProfileVerifications',
    'malformedBothVerifications',
    'orphanUsersDocuments',
    'orphanPublicProfileDocuments',
    'canonicalEmailTrue',
    'canonicalEmailFalse',
    'canonicalPhoneTrue',
    'canonicalPhoneFalse',
    'canonicalPhotoTrue',
    'canonicalPhotoFalse',
    'usersEmailTrue',
    'usersPhoneTrue',
    'usersPhotoTrue',
    'publicEmailTrue',
    'publicPhoneTrue',
    'publicPhotoTrue',
    'usersEmailFalseToTrue',
    'usersEmailTrueToFalse',
    'usersPhoneFalseToTrue',
    'usersPhoneTrueToFalse',
    'usersPhotoFalseToTrue',
    'usersPhotoTrueToFalse',
    'publicEmailFalseToTrue',
    'publicEmailTrueToFalse',
    'publicPhoneFalseToTrue',
    'publicPhoneTrueToFalse',
    'publicPhotoFalseToTrue',
    'publicPhotoTrueToFalse',
    'usersEmailTrueWithoutAuthEvidence',
    'publicEmailTrueWithoutAuthEvidence',
    'usersPhoneTrueWithoutAuthEvidence',
    'publicPhoneTrueWithoutAuthEvidence',
    'errors',
    'writesAttempted',
    'durationMs',
  ];

  console.log('=== Auth Verification Badge Dry Run Audit ===');
  for (const field of fields) {
    console.log(`${field}: ${aggregate[field]}`);
  }
  console.log(`errorCodeCounts: ${JSON.stringify(aggregate.errorCodeCounts)}`);
  console.log(
    `classificationInvariant: ${classificationInvariantHolds(aggregate) ? 'OK' : 'VIOLATED'}`,
  );
  console.log(
    `canonicalPhotoTrueInvariant: ${aggregate.canonicalPhotoTrue === 0 ? 'OK' : 'VIOLATED'}`,
  );
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

  const startedAt = Date.now();
  const aggregate = createEmptyAggregate(args.project);

  try {
    const { auth, db } = initializeFirebase(args.project);

    if (args.uid) {
      await auditSingleUser(auth, db, args.uid, aggregate, { verbose: true });
    } else {
      const authUids = new Set();
      await auditAllUsers(auth, db, args, aggregate, authUids);
      const usersScan = await scanCollectionIds(db, 'users', authUids, args.pageSize);
      const publicScan = await scanCollectionIds(
        db,
        'publicProfiles',
        authUids,
        args.pageSize,
      );
      aggregate.usersDocumentsFound = usersScan.total;
      aggregate.publicProfilesDocumentsFound = publicScan.total;
      aggregate.orphanUsersDocuments = usersScan.orphans;
      aggregate.orphanPublicProfileDocuments = publicScan.orphans;
    }

    aggregate.durationMs = Date.now() - startedAt;
    printSummary(aggregate);
    return aggregate.errors > 0 ? 1 : 0;
  } catch (error) {
    aggregate.errors += 1;
    const category = classifyReadError(error, 'audit_read').category;
    recordErrorCategory(aggregate, category);
    aggregate.durationMs = Date.now() - startedAt;
    printSummary(aggregate);
    console.error(`audit failed: ${category}`);
    return 1;
  }
}

if (require.main === module) {
  main().then((code) => {
    process.exitCode = code;
  });
}

module.exports = {
  EXPECTED_PROJECT_ID,
  VERIFICATION_KEYS,
  assertProjectAllowed,
  classifyReadError,
  parseArgs,
  usage,
};
