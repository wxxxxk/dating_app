'use strict';

// APPLY tool for the auth verification badge server-only migration. Firebase
// Auth is the ONLY source of the target user set: orphan Firestore documents
// (dummy seeds, the deleted-real-user-likely orphan, any doc without an Auth
// account) are never read or written here. Each Auth user's users/{uid} and
// publicProfiles/{uid} verifications are synced to the canonical Auth-derived
// value inside a single Firestore transaction.
//
// The ONLY write surface is transaction.update on those two documents with the
// canonical `verifications` map (and publicProfiles.profileUpdatedAt when the
// public value actually changed). No create, no delete, no other collection.

const admin = require('firebase-admin');
const {
  RESULTS,
  planUserMigration,
  createEmptyApplyAggregate,
  recordCommittedPlan,
  recordAuthReadError,
  recordTransactionError,
  classificationInvariantHolds,
  countersInvariantHold,
} = require('../lib/auth_verification_badge_migration');

const EXPECTED_PROJECT_ID = 'cvr-dating-app';
const DEFAULT_PAGE_SIZE = 100;
const MAX_PAGE_SIZE = 1000;

function usage() {
  return [
    'Usage:',
    '  npm --prefix functions run migrate:auth-verification-badges:apply -- \\',
    '    --project cvr-dating-app --confirm-project cvr-dating-app --apply [options]',
    '',
    'Options:',
    '  --project <projectId>          Required Firebase project ID (must be cvr-dating-app)',
    '  --confirm-project <projectId>  Must exactly match --project',
    '  --apply                        Required; without it nothing is initialized',
    '  --uid <uid>                    Apply to exactly one Auth user',
    '  --limit <number>               Maximum Auth users to process',
    '  --page-size <number>           Auth listUsers page size, max 1000 (default 100)',
    '  --help                         Show this help',
    '',
    'Target set is Firebase Auth users only. Orphan Firestore documents are never',
    'touched. The only write is verifications on users/{uid} and publicProfiles/{uid}.',
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
    confirmProject: null,
    apply: false,
    uid: null,
    limit: null,
    pageSize: DEFAULT_PAGE_SIZE,
    help: false,
  };
  const seen = new Set();

  function markSeen(option) {
    if (seen.has(option)) throw new Error(`Duplicate argument: ${option}`);
    seen.add(option);
  }

  // Destructive / scope-expanding flags are explicitly rejected — this tool can
  // never delete, force, or touch non-Auth Firestore documents.
  const forbidden = new Set([
    '--include-orphans',
    '--cleanup',
    '--delete',
    '--force',
    '--all-firestore-users',
    '--write',
    '--fix',
  ]);

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (forbidden.has(arg)) {
      throw new Error(`Unsupported flag: ${arg}. This tool never deletes or expands scope.`);
    }
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
  return args;
}

// All guards run BEFORE any Firebase initialization. Throws on any violation.
function assertApplyPreconditions(args) {
  if (!args.apply) {
    throw new Error('--apply is required; refusing to run without explicit apply confirmation');
  }
  if (!args.project) {
    throw new Error('--project is required');
  }
  if (args.project !== EXPECTED_PROJECT_ID) {
    throw new Error(
      `Refusing to run against project ${args.project}; expected ${EXPECTED_PROJECT_ID}`,
    );
  }
  if (!args.confirmProject) {
    throw new Error('--confirm-project is required and must match --project');
  }
  if (args.confirmProject !== args.project) {
    throw new Error('--confirm-project does not match --project');
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

// Map any error to a small, safe error code. Never surfaces the raw error,
// stack, credential path, uid, or profile value.
function classifyError(error) {
  const text = rawDiagnosticText(error);
  if (/invalid_grant|reauth/.test(text)) return 'ADC_REFRESH_FAILED';
  if (/could not load the default credentials|application default credentials|default credentials/.test(text)) {
    return 'ADC_UNAVAILABLE';
  }
  if (/\b(7|permission[-_\s]?denied)\b/.test(text)) return 'PERMISSION_DENIED';
  if (/\b(16|unauthenticated)\b/.test(text)) return 'UNAUTHENTICATED';
  if (/enotfound|eai_again/.test(text)) return 'DNS_FAILURE';
  if (/econnrefused|econnreset|eperm|network unavailable/.test(text)) return 'NETWORK_UNAVAILABLE';
  if (/etimedout|deadline exceeded|timeout/.test(text)) return 'CONNECTION_TIMEOUT';
  if (/aborted|contention|too much contention|transaction/.test(text)) return 'TRANSACTION_FAILED';
  if (/auth\/|identitytoolkit|user-not-found/.test(text)) return 'AUTH_API_UNAVAILABLE';
  if (/project not found/.test(text)) return 'PROJECT_NOT_FOUND';
  if (/resource exhausted|quota/.test(text)) return 'RESOURCE_EXHAUSTED';
  if (/api has not been used|service disabled|api disabled|unavailable|service unavailable/.test(text)) {
    return 'FIRESTORE_API_UNAVAILABLE';
  }
  return 'UNKNOWN_RUNTIME_ERROR';
}

// Apply one Auth user's migration inside a single transaction. Auth is read
// first (canonical source). The transaction reads both documents, plans, and
// updates only when required. Returns a descriptor for aggregate folding.
async function applyUser(auth, db, userRecord) {
  const uid = userRecord.uid;
  const userRef = db.collection('users').doc(uid);
  const publicRef = db.collection('publicProfiles').doc(uid);

  // Track the last-attempted plan so a failed commit can still report the number
  // of writes that were planned (writesAttempted) without counting them as
  // succeeded.
  let attemptedWrites = 0;
  const canonicalHolder = {};

  try {
    const plan = await db.runTransaction(async (transaction) => {
      const [userSnap, publicSnap] = await Promise.all([
        transaction.get(userRef),
        transaction.get(publicRef),
      ]);

      const p = planUserMigration({
        uid,
        userRecord,
        usersExists: userSnap.exists,
        usersData: userSnap.exists ? userSnap.data() : undefined,
        publicExists: publicSnap.exists,
        publicData: publicSnap.exists ? publicSnap.data() : undefined,
      });
      attemptedWrites = p.writesPlanned;
      canonicalHolder.canonical = p.canonical;

      if (p.usersUpdate) {
        transaction.update(userRef, p.usersUpdate);
      }
      if (p.publicUpdate) {
        const payload = p.bumpProfileUpdatedAt
          ? { ...p.publicUpdate, profileUpdatedAt: admin.firestore.FieldValue.serverTimestamp() }
          : p.publicUpdate;
        transaction.update(publicRef, payload);
      }
      return p;
    });
    return { kind: 'committed', plan };
  } catch (error) {
    return {
      kind: 'transactionError',
      canonical: canonicalHolder.canonical || null,
      writesPlanned: attemptedWrites,
      category: classifyError(error),
    };
  }
}

// Fold an applyUser descriptor into the aggregate, owning the write counters.
function foldDescriptor(aggregate, descriptor) {
  if (descriptor.kind === 'committed') {
    const { plan } = descriptor;
    recordCommittedPlan(aggregate, plan);
    aggregate.writesAttempted += plan.writesPlanned;
    aggregate.writesSucceeded += plan.writesPlanned;
  } else {
    // Transaction failed after a successful Auth read. recordTransactionError
    // already increments the `errors` bucket via recordResult.
    recordTransactionError(
      aggregate,
      descriptor.canonical,
      RESULTS.WRITE_ERROR,
      descriptor.category,
    );
    aggregate.writesAttempted += descriptor.writesPlanned;
  }
}

async function processSingleUser(auth, db, uid, aggregate) {
  let userRecord;
  try {
    userRecord = await auth.getUser(uid);
  } catch (error) {
    // recordAuthReadError already increments the `errors` bucket via recordResult.
    recordAuthReadError(aggregate, classifyError(error));
    return;
  }
  const descriptor = await applyUser(auth, db, userRecord);
  foldDescriptor(aggregate, descriptor);
}

async function processAllUsers(auth, db, args, aggregate) {
  let pageToken;
  let remaining = args.limit;
  do {
    const batchSize =
      remaining === null ? args.pageSize : Math.min(args.pageSize, remaining);
    const page = await auth.listUsers(batchSize, pageToken);
    if (page.users.length === 0) break;

    for (const userRecord of page.users) {
      // Per-user isolation: one user's failure never aborts the run or triggers
      // an automatic retry/second write.
      // eslint-disable-next-line no-await-in-loop
      const descriptor = await applyUser(auth, db, userRecord);
      foldDescriptor(aggregate, descriptor);
    }

    pageToken = page.pageToken;
    if (remaining !== null) {
      remaining -= page.users.length;
      if (remaining <= 0) break;
    }
  } while (pageToken);
}

function printSummary(aggregate) {
  const fields = [
    'project',
    'mode',
    'authUsersScanned',
    'unchanged',
    'updatedUsersOnly',
    'updatedPublicProfileOnly',
    'updatedBoth',
    'normalizedUsersOnly',
    'normalizedPublicProfileOnly',
    'normalizedBoth',
    'normalizedUsers',
    'normalizedPublicProfiles',
    'missingUsersDocuments',
    'missingPublicProfileDocuments',
    'missingBothDocuments',
    'canonicalEmailTrue',
    'canonicalPhoneTrue',
    'canonicalPhotoTrue',
    'usersEmailFalseToTrue',
    'usersEmailTrueToFalse',
    'usersPhoneFalseToTrue',
    'usersPhoneTrueToFalse',
    'usersPhotoTrueToFalse',
    'publicEmailFalseToTrue',
    'publicEmailTrueToFalse',
    'publicPhoneFalseToTrue',
    'publicPhoneTrueToFalse',
    'publicPhotoTrueToFalse',
    'writesAttempted',
    'writesSucceeded',
    'errors',
    'durationMs',
  ];
  console.log('=== Auth Verification Badge Migration Apply ===');
  for (const field of fields) {
    console.log(`${field}: ${aggregate[field]}`);
  }
  console.log(`errorCodeCounts: ${JSON.stringify(aggregate.errorCodeCounts)}`);
  console.log(
    `classificationInvariant: ${classificationInvariantHolds(aggregate) ? 'OK' : 'VIOLATED'}`,
  );
  console.log(
    `countersInvariant: ${countersInvariantHold(aggregate) ? 'OK' : 'VIOLATED'}`,
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
    assertApplyPreconditions(args);
  } catch (error) {
    console.error(error.message);
    console.error(usage());
    return 2;
  }

  const startedAt = Date.now();
  const aggregate = createEmptyApplyAggregate(args.project);

  try {
    const { auth, db } = initializeFirebase(args.project);
    if (args.uid) {
      await processSingleUser(auth, db, args.uid, aggregate);
    } else {
      await processAllUsers(auth, db, args, aggregate);
    }
    aggregate.durationMs = Date.now() - startedAt;
    printSummary(aggregate);
    // Continue-on-error policy: a non-zero errors count yields a non-zero exit,
    // but the run itself never auto-retries or performs a second apply.
    return aggregate.errors > 0 ? 1 : 0;
  } catch (error) {
    aggregate.durationMs = Date.now() - startedAt;
    const category = classifyError(error);
    aggregate.errorCodeCounts[category] = (aggregate.errorCodeCounts[category] || 0) + 1;
    printSummary(aggregate);
    console.error(`apply failed: ${category}`);
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
  parseArgs,
  assertApplyPreconditions,
  classifyError,
  applyUser,
  foldDescriptor,
  processSingleUser,
  processAllUsers,
  usage,
};
