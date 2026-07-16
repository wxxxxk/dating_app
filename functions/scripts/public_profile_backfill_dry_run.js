'use strict';

const admin = require('firebase-admin');
const {
  BACKFILL_KEYS,
  classifyPublicProfile,
  toLogRecord,
} = require('../lib/public_profile_backfill');

const EXPECTED_PROJECT_ID = 'cvr-dating-app';
const DEFAULT_PAGE_SIZE = 100;
const MAX_PAGE_SIZE = 500;

function usage() {
  return [
    'Usage:',
    '  npm --prefix functions run backfill:public-profiles:dry-run -- --project cvr-dating-app [options]',
    '',
    'Options:',
    '  --project <projectId>   Required Firebase project ID',
    '  --uid <uid>             Inspect one user without scanning users collection',
    '  --limit <number>        Maximum users to inspect',
    '  --page-size <number>    Page size for collection scan, max 500 (default 100)',
    '  --help                  Show this help',
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

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
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
  const emulatorHost = process.env.FIRESTORE_EMULATOR_HOST;
  if (!emulatorHost && projectId !== EXPECTED_PROJECT_ID) {
    throw new Error(`Refusing to run against project ${projectId}; expected ${EXPECTED_PROJECT_ID}`);
  }
}

function initializeFirestore(projectId) {
  if (admin.apps.length === 0) {
    admin.initializeApp({ projectId });
  }
  return admin.firestore();
}

function rawDiagnosticText(error) {
  const parts = [];
  const queue = [error, error && error.cause].filter(Boolean);
  for (const item of queue) {
    for (const key of ['code', 'name', 'details', 'message']) {
      if (typeof item[key] === 'string' || typeof item[key] === 'number') {
        parts.push(String(item[key]));
      }
    }
  }
  return parts.join(' ').toLowerCase();
}

function classifyDryRunError(error, phase = 'firestore_initial_read') {
  const text = rawDiagnosticText(error);
  let category = 'UNKNOWN_RUNTIME_ERROR';
  let retryable = false;

  if (/\b(7|permission[-_\s]?denied)\b/.test(text)) {
    category = 'PERMISSION_DENIED';
  } else if (/\b(16|unauthenticated)\b/.test(text)) {
    category = 'UNAUTHENTICATED';
  } else if (/invalid_grant|reauth/.test(text)) {
    category = 'ADC_REFRESH_FAILED';
  } else if (/could not load the default credentials|default credentials|application default credentials/.test(text)) {
    category = 'ADC_UNAVAILABLE';
  } else if (/enotfound|eai_again/.test(text)) {
    category = 'DNS_FAILURE';
    retryable = true;
  } else if (/econnrefused|econnreset|eperm|network unavailable/.test(text)) {
    category = 'NETWORK_UNAVAILABLE';
    retryable = true;
  } else if (/etimedout|deadline exceeded|timeout/.test(text)) {
    category = 'CONNECTION_TIMEOUT';
    retryable = true;
  } else if (/api has not been used|service disabled|api disabled/.test(text)) {
    category = 'FIRESTORE_API_DISABLED';
  } else if (/project not found/.test(text)) {
    category = 'PROJECT_NOT_FOUND';
  } else if (/resource exhausted|quota/.test(text)) {
    category = 'RESOURCE_EXHAUSTED';
    retryable = true;
  } else if (/unavailable|service unavailable/.test(text)) {
    category = 'FIRESTORE_API_UNAVAILABLE';
    retryable = true;
  }

  return { category, retryable, phase };
}

function formatDryRunError(error, phase) {
  return classifyDryRunError(error, phase).category;
}

function emptyStats(projectId) {
  return {
    project: projectId,
    scanned: 0,
    wouldCreate: 0,
    wouldUpdate: 0,
    unchanged: 0,
    skipped: 0,
    errors: 0,
    unexpectedPublicFieldsDocuments: 0,
    sensitiveUnexpectedPublicFieldsDocuments: 0,
    changedFieldCounts: {},
    errorCodeCounts: {},
    writesAttempted: 0,
  };
}

function recordErrorCategory(stats, diagnostic) {
  stats.errorCodeCounts[diagnostic.category] =
    (stats.errorCodeCounts[diagnostic.category] || 0) + 1;
}

function recordResult(stats, result) {
  stats.scanned += 1;
  if (result.status === 'wouldCreate') stats.wouldCreate += 1;
  if (result.status === 'wouldUpdate') stats.wouldUpdate += 1;
  if (result.status === 'unchanged') stats.unchanged += 1;
  if (result.status === 'skipped') stats.skipped += 1;
  if (result.status === 'error') stats.errors += 1;
  if (result.status === 'error') {
    const category = result.reason || 'UNKNOWN_RUNTIME_ERROR';
    stats.errorCodeCounts[category] = (stats.errorCodeCounts[category] || 0) + 1;
  }

  if (result.unexpectedPublicFields && result.unexpectedPublicFields.length > 0) {
    stats.unexpectedPublicFieldsDocuments += 1;
  }
  if (result.hasSensitiveUnexpectedPublicFields) {
    stats.sensitiveUnexpectedPublicFieldsDocuments += 1;
  }
  for (const field of result.changedFields || []) {
    stats.changedFieldCounts[field] = (stats.changedFieldCounts[field] || 0) + 1;
  }
}

function printResult(result) {
  const record = toLogRecord(result);
  const parts = [
    `uidHash=${record.uidHash}`,
    `status=${record.status}`,
  ];
  if (record.changedFields) {
    parts.push(`changedFields=[${record.changedFields.join(', ')}]`);
  }
  if (record.unexpectedPublicFields) {
    parts.push(`unexpectedPublicFields=[${record.unexpectedPublicFields.join(', ')}]`);
  }
  if (record.reason) {
    parts.push(`reason=${record.reason}`);
  }
  if (record.sensitiveUnexpectedPublicFields) {
    parts.push('sensitiveUnexpectedPublicFields=true');
  }
  if (record.refreshProfileUpdatedAtOnApply) {
    parts.push('refreshProfileUpdatedAtOnApply=true');
  }
  console.log(parts.join(' '));
}

async function classifySnapshotPair(userSnapshot, publicSnapshot, referenceDate) {
  if (!userSnapshot.exists) {
    return {
      uid: userSnapshot.id,
      status: 'skipped',
      reason: 'missing_user_document',
      changedFields: [],
      unexpectedPublicFields: [],
      hasSensitiveUnexpectedPublicFields: false,
      refreshProfileUpdatedAtOnApply: false,
    };
  }

  return classifyPublicProfile({
    uid: userSnapshot.id,
    userData: userSnapshot.data(),
    publicExists: publicSnapshot.exists,
    publicData: publicSnapshot.exists ? publicSnapshot.data() : null,
  }, { referenceDate });
}

async function inspectSingleUid(db, uid, referenceDate, stats) {
  const userRef = db.collection('users').doc(uid);
  const publicRef = db.collection('publicProfiles').doc(uid);
  const [userSnapshot, publicSnapshot] = await db.getAll(userRef, publicRef);
  const result = await classifySnapshotPair(userSnapshot, publicSnapshot, referenceDate);
  recordResult(stats, result);
  printResult(result);
}

async function inspectAllUsers(db, args, referenceDate, stats) {
  const documentId = admin.firestore.FieldPath.documentId();
  let lastSnapshot = null;
  let remaining = args.limit;

  while (remaining === null || remaining > 0) {
    const batchSize = remaining === null
      ? args.pageSize
      : Math.min(args.pageSize, remaining);
    let query = db.collection('users')
      .orderBy(documentId)
      .limit(batchSize);
    if (lastSnapshot) {
      query = query.startAfter(lastSnapshot);
    }

    const usersPage = await query.get();
    if (usersPage.empty) {
      break;
    }

    const publicRefs = usersPage.docs.map((doc) =>
      db.collection('publicProfiles').doc(doc.id),
    );
    const publicSnapshots = await db.getAll(...publicRefs);
    const publicById = new Map(publicSnapshots.map((snapshot) => [snapshot.id, snapshot]));

    for (const userSnapshot of usersPage.docs) {
      try {
        const publicSnapshot = publicById.get(userSnapshot.id);
        const result = await classifySnapshotPair(userSnapshot, publicSnapshot, referenceDate);
        recordResult(stats, result);
        printResult(result);
      } catch (error) {
        const result = {
          uid: userSnapshot.id,
          status: 'error',
          reason: 'UNKNOWN_RUNTIME_ERROR',
          changedFields: [],
          unexpectedPublicFields: [],
          hasSensitiveUnexpectedPublicFields: false,
          refreshProfileUpdatedAtOnApply: false,
        };
        recordResult(stats, result);
        printResult(result);
      }
    }

    lastSnapshot = usersPage.docs[usersPage.docs.length - 1];
    if (remaining !== null) {
      remaining -= usersPage.docs.length;
    }
    if (usersPage.size < batchSize) {
      break;
    }
  }
}

function printSummary(stats, durationMs) {
  const changedFieldCounts = {};
  for (const field of BACKFILL_KEYS) {
    if (stats.changedFieldCounts[field]) {
      changedFieldCounts[field] = stats.changedFieldCounts[field];
    }
  }

  console.log('=== Public Profile Backfill Dry Run ===');
  console.log(`project: ${stats.project}`);
  console.log('mode: dry-run');
  console.log(`scanned: ${stats.scanned}`);
  console.log(`wouldCreate: ${stats.wouldCreate}`);
  console.log(`wouldUpdate: ${stats.wouldUpdate}`);
  console.log(`unchanged: ${stats.unchanged}`);
  console.log(`skipped: ${stats.skipped}`);
  console.log(`errors: ${stats.errors}`);
  console.log(`unexpectedPublicFieldsDocuments: ${stats.unexpectedPublicFieldsDocuments}`);
  console.log(`sensitiveUnexpectedPublicFieldsDocuments: ${stats.sensitiveUnexpectedPublicFieldsDocuments}`);
  console.log(`changedFieldCounts: ${JSON.stringify(changedFieldCounts)}`);
  console.log(`errorCodeCounts: ${JSON.stringify(stats.errorCodeCounts)}`);
  console.log(`durationMs: ${durationMs}`);
  console.log(`writesAttempted: ${stats.writesAttempted}`);
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
  const stats = emptyStats(args.project);

  try {
    const db = initializeFirestore(args.project);
    const referenceDate = new Date();
    if (args.uid) {
      await inspectSingleUid(db, args.uid, referenceDate, stats);
    } else {
      await inspectAllUsers(db, args, referenceDate, stats);
    }
    printSummary(stats, Date.now() - startedAt);
    return stats.errors > 0 ? 1 : 0;
  } catch (error) {
    stats.errors += 1;
    const diagnostic = classifyDryRunError(error, 'firestore_initial_read');
    recordErrorCategory(stats, diagnostic);
    printSummary(stats, Date.now() - startedAt);
    console.error(`dry-run failed: ${diagnostic.category}`);
    return 1;
  }
}

if (require.main === module) {
  main().then((code) => {
    process.exitCode = code;
  });
}

module.exports = {
  assertProjectAllowed,
  classifyDryRunError,
  formatDryRunError,
  parseArgs,
  usage,
};
