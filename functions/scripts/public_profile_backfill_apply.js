'use strict';

const admin = require('firebase-admin');
const {
  buildPublicProfileCandidate,
  toLogRecord,
} = require('../lib/public_profile_backfill');
const {
  classifyDryRunError,
} = require('./public_profile_backfill_dry_run');

const EXPECTED_PROJECT_ID = 'cvr-dating-app';
const DEFAULT_PAGE_SIZE = 100;
const MAX_PAGE_SIZE = 500;

function usage() {
  return [
    'Usage:',
    '  npm --prefix functions run backfill:public-profiles:apply -- --project cvr-dating-app --confirm-project cvr-dating-app --apply [options]',
    '',
    'Options:',
    '  --project <projectId>          Required Firebase project ID',
    '  --confirm-project <projectId>  Required project confirmation',
    '  --apply                        Required to perform create-only writes',
    '  --uid <uid>                    Create one public profile if missing',
    '  --limit <number>               Maximum users to inspect',
    '  --page-size <number>           Page size for collection scan, max 500 (default 100)',
    '  --help                         Show this help',
  ].join('\n');
}

function parsePositiveInteger(raw, name) {
  if (!/^[1-9]\d*$/.test(String(raw))) {
    throw new Error(`${name} must be a positive integer`);
  }
  return Number(raw);
}

function parseApplyArgs(argv) {
  const args = {
    project: null,
    confirmProject: null,
    apply: false,
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
    } else if (arg === '--apply') {
      markSeen(arg);
      args.apply = true;
    } else if (arg === '--project') {
      markSeen(arg);
      index += 1;
      if (!argv[index]) throw new Error('--project requires a value');
      args.project = argv[index];
    } else if (arg === '--confirm-project') {
      markSeen(arg);
      index += 1;
      if (!argv[index]) throw new Error('--confirm-project requires a value');
      args.confirmProject = argv[index];
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

  if (args.help) {
    return args;
  }
  if (!args.apply) {
    throw new Error('--apply is required for create-only backfill');
  }
  if (!args.project) {
    throw new Error('--project is required');
  }
  if (!args.confirmProject) {
    throw new Error('--confirm-project is required');
  }
  if (args.project !== args.confirmProject) {
    throw new Error('--project and --confirm-project must match');
  }

  return args;
}

function assertApplyProjectAllowed(projectId) {
  const emulatorHost = process.env.FIRESTORE_EMULATOR_HOST;
  if (!emulatorHost && projectId !== EXPECTED_PROJECT_ID) {
    throw new Error(`Refusing to apply against project ${projectId}; expected ${EXPECTED_PROJECT_ID}`);
  }
}

function initializeFirestore(projectId) {
  if (admin.apps.length === 0) {
    admin.initializeApp({ projectId });
  }
  return admin.firestore();
}

function buildApplyPayload(userData, serverTimestamp) {
  const candidate = buildPublicProfileCandidate(userData);
  if (!candidate.ok) {
    return candidate;
  }
  return {
    ok: true,
    payload: {
      ...candidate.payload,
      profileUpdatedAt: serverTimestamp(),
    },
  };
}

function isAlreadyExistsError(error) {
  const diagnostic = classifyDryRunError(error, 'public_profile_create');
  const text = [
    error && error.code,
    error && error.name,
    error && error.details,
    error && error.message,
    error && error.cause && error.cause.code,
    error && error.cause && error.cause.name,
  ].filter((value) => value !== undefined && value !== null)
    .map((value) => String(value).toLowerCase())
    .join(' ');
  return diagnostic.category === 'ALREADY_EXISTS' ||
    /\b(6|already[-_\s]?exists|already exists)\b/.test(text);
}

function emptyApplyStats(projectId) {
  return {
    project: projectId,
    scanned: 0,
    created: 0,
    alreadyExists: 0,
    skipped: 0,
    errors: 0,
    errorCodeCounts: {},
    writesAttempted: 0,
    writesSucceeded: 0,
  };
}

function recordApplyError(stats, category) {
  stats.errorCodeCounts[category] = (stats.errorCodeCounts[category] || 0) + 1;
}

function recordApplyResult(stats, result) {
  stats.scanned += 1;
  if (result.status === 'created') stats.created += 1;
  if (result.status === 'alreadyExists') stats.alreadyExists += 1;
  if (result.status === 'skipped') stats.skipped += 1;
  if (result.status === 'error') {
    stats.errors += 1;
    recordApplyError(stats, result.reason || 'UNKNOWN_RUNTIME_ERROR');
  }
}

function printApplyResult(result) {
  const record = toLogRecord({
    uid: result.uid,
    status: result.status,
    reason: result.reason,
  });
  const parts = [
    `uidHash=${record.uidHash}`,
    `status=${record.status}`,
  ];
  if (record.reason) {
    parts.push(`reason=${record.reason}`);
  }
  console.log(parts.join(' '));
}

function printApplySummary(stats, durationMs) {
  console.log('=== Public Profile Backfill Apply ===');
  console.log(`project: ${stats.project}`);
  console.log('mode: apply');
  console.log(`scanned: ${stats.scanned}`);
  console.log(`created: ${stats.created}`);
  console.log(`alreadyExists: ${stats.alreadyExists}`);
  console.log(`skipped: ${stats.skipped}`);
  console.log(`errors: ${stats.errors}`);
  console.log(`errorCodeCounts: ${JSON.stringify(stats.errorCodeCounts)}`);
  console.log(`durationMs: ${durationMs}`);
  console.log(`writesAttempted: ${stats.writesAttempted}`);
  console.log(`writesSucceeded: ${stats.writesSucceeded}`);
}

async function applySnapshotPair(userSnapshot, publicSnapshot, publicRef, options = {}) {
  const serverTimestamp = options.serverTimestamp ||
    (() => admin.firestore.FieldValue.serverTimestamp());

  if (!userSnapshot.exists) {
    return {
      uid: userSnapshot.id,
      status: 'skipped',
      reason: 'missing_user_document',
      writeAttempted: false,
      writeSucceeded: false,
    };
  }

  if (publicSnapshot.exists) {
    return {
      uid: userSnapshot.id,
      status: 'alreadyExists',
      writeAttempted: false,
      writeSucceeded: false,
    };
  }

  const candidate = buildApplyPayload(userSnapshot.data(), serverTimestamp);
  if (!candidate.ok) {
    return {
      uid: userSnapshot.id,
      status: candidate.status,
      reason: candidate.reason,
      writeAttempted: false,
      writeSucceeded: false,
    };
  }

  try {
    await publicRef.create(candidate.payload);
    return {
      uid: userSnapshot.id,
      status: 'created',
      writeAttempted: true,
      writeSucceeded: true,
    };
  } catch (error) {
    if (isAlreadyExistsError(error)) {
      return {
        uid: userSnapshot.id,
        status: 'alreadyExists',
        writeAttempted: true,
        writeSucceeded: false,
      };
    }
    return {
      uid: userSnapshot.id,
      status: 'error',
      reason: classifyDryRunError(error, 'public_profile_create').category,
      writeAttempted: true,
      writeSucceeded: false,
    };
  }
}

async function applySingleUid(db, uid, stats, options = {}) {
  const userRef = db.collection('users').doc(uid);
  const publicRef = db.collection('publicProfiles').doc(uid);
  const [userSnapshot, publicSnapshot] = await db.getAll(userRef, publicRef);
  const result = await applySnapshotPair(userSnapshot, publicSnapshot, publicRef, options);
  if (result.writeAttempted) stats.writesAttempted += 1;
  if (result.writeSucceeded) stats.writesSucceeded += 1;
  recordApplyResult(stats, result);
  printApplyResult(result);
  return result;
}

async function applyAllUsers(db, args, stats, options = {}) {
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
    const publicRefById = new Map(publicRefs.map((ref) => [ref.id, ref]));

    for (const userSnapshot of usersPage.docs) {
      const publicSnapshot = publicById.get(userSnapshot.id);
      const publicRef = publicRefById.get(userSnapshot.id);
      const result = await applySnapshotPair(userSnapshot, publicSnapshot, publicRef, options);
      if (result.writeAttempted) stats.writesAttempted += 1;
      if (result.writeSucceeded) stats.writesSucceeded += 1;
      recordApplyResult(stats, result);
      printApplyResult(result);
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

async function main() {
  let args;
  try {
    args = parseApplyArgs(process.argv.slice(2));
    if (args.help) {
      console.log(usage());
      return 0;
    }
    assertApplyProjectAllowed(args.project);
  } catch (error) {
    console.error(error.message);
    console.error(usage());
    return 2;
  }

  const startedAt = Date.now();
  const stats = emptyApplyStats(args.project);
  try {
    const db = initializeFirestore(args.project);
    const environment = process.env.FIRESTORE_EMULATOR_HOST ? 'emulator' : 'production';
    console.log(`environment: ${environment}`);
    if (args.uid) {
      await applySingleUid(db, args.uid, stats);
    } else {
      await applyAllUsers(db, args, stats);
    }
    printApplySummary(stats, Date.now() - startedAt);
    return stats.errors > 0 ? 1 : 0;
  } catch (error) {
    stats.errors += 1;
    recordApplyError(stats, classifyDryRunError(error, 'firestore_initial_read').category);
    printApplySummary(stats, Date.now() - startedAt);
    console.error(`apply failed: ${classifyDryRunError(error, 'firestore_initial_read').category}`);
    return 1;
  }
}

if (require.main === module) {
  main().then((code) => {
    process.exitCode = code;
  });
}

module.exports = {
  applyAllUsers,
  applySingleUid,
  applySnapshotPair,
  assertApplyProjectAllowed,
  buildApplyPayload,
  emptyApplyStats,
  isAlreadyExistsError,
  parseApplyArgs,
  usage,
};
