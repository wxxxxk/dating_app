'use strict';

// Orphan cleanup planner. Default mode is dry-run. This phase intentionally
// contains no Auth, Firestore, or Storage mutation API calls. Execute mode is
// explicitly not implemented and fails before Firebase initialization.

const fs = require('node:fs');
const admin = require('firebase-admin');
const audit = require('./audit_orphan_accounts');
const {
  CLEANUP_ERROR,
  planCleanup,
} = require('../lib/orphan_account_lifecycle');

const EXPECTED_PROJECT_ID = 'cvr-dating-app';
const EXECUTE_CONFIRMATION = 'I_UNDERSTAND_ORPHAN_ACCOUNT_CLEANUP';

function usage() {
  return [
    'Usage:',
    '  node functions/scripts/cleanup_orphan_accounts.js --project cvr-dating-app [--dry-run]',
    '  node functions/scripts/cleanup_orphan_accounts.js --project cvr-dating-app --execute --confirm-execute I_UNDERSTAND_ORPHAN_ACCOUNT_CLEANUP --manifest /private/tmp/orphan_manifest.json',
    '',
    'This phase is plan-only. It performs no production writes or deletes.',
  ].join('\n');
}

function parseArgs(argv) {
  const args = {
    project: null,
    bucket: null,
    pageSize: 100,
    dryRun: true,
    execute: false,
    confirmExecute: false,
    manifestPath: null,
    help: false,
  };
  const seen = new Set();
  const mark = (arg) => {
    if (seen.has(arg)) throw new Error(`Duplicate argument: ${arg}`);
    seen.add(arg);
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--help') {
      mark(arg);
      args.help = true;
    } else if (arg === '--project') {
      mark(arg);
      index += 1;
      if (!argv[index]) throw new Error('--project requires a value');
      args.project = argv[index];
    } else if (arg === '--bucket') {
      mark(arg);
      index += 1;
      if (!argv[index]) throw new Error('--bucket requires a value');
      args.bucket = argv[index];
    } else if (arg === '--page-size') {
      mark(arg);
      index += 1;
      if (!argv[index]) throw new Error('--page-size requires a value');
      args.pageSize = audit.parseArgs(['--project', EXPECTED_PROJECT_ID, '--page-size', argv[index]]).pageSize;
    } else if (arg === '--dry-run') {
      mark(arg);
      args.dryRun = true;
    } else if (arg === '--execute') {
      mark(arg);
      args.execute = true;
      args.dryRun = false;
    } else if (arg === '--confirm-execute') {
      mark(arg);
      index += 1;
      if (argv[index] !== EXECUTE_CONFIRMATION) {
        throw new Error('--confirm-execute value is invalid');
      }
      args.confirmExecute = true;
    } else if (arg === '--manifest') {
      mark(arg);
      index += 1;
      if (!argv[index]) throw new Error('--manifest requires a value');
      args.manifestPath = argv[index];
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }

  if (!args.help && !args.project) throw new Error('--project is required');
  return args;
}

function readManifest(manifestPath) {
  if (!manifestPath) return null;
  const stat = fs.statSync(manifestPath);
  const mode = stat.mode & 0o777;
  if ((mode & 0o077) !== 0) {
    throw new Error('Manifest permissions must not allow group/other access.');
  }
  const parsed = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
  if (!parsed || !Array.isArray(parsed.uidHashes)) {
    throw new Error('Manifest must contain uidHashes array.');
  }
  return parsed;
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

function printPlan(plan) {
  console.log('=== Orphan Account Cleanup Plan ===');
  console.log(`mode: ${plan.mode}`);
  console.log(`plannedUidHashes: ${JSON.stringify(plan.plannedUidHashes)}`);
  console.log(`writesAttempted: ${plan.writesAttempted}`);
  console.log(`deletesAttempted: ${plan.deletesAttempted}`);
  console.log(`authMutations: ${plan.authMutations}`);
  console.log(`firestoreMutations: ${plan.firestoreMutations}`);
  console.log(`storageMutations: ${plan.storageMutations}`);
}

async function main() {
  let args;
  try {
    args = parseArgs(process.argv.slice(2));
    if (args.help) {
      console.log(usage());
      return 0;
    }
    audit.assertProjectAllowed(args.project);
  } catch (error) {
    console.error(error.message);
    console.error(usage());
    return 2;
  }

  try {
    if (args.execute) {
      throw Object.assign(
        new Error('Orphan cleanup execution is not implemented in this phase.'),
        { code: CLEANUP_ERROR.EXECUTION_NOT_IMPLEMENTED },
      );
    }
    const clients = initializeFirebase(args.project, args.bucket);
    const report = await audit.runAudit({
      auth: clients.auth,
      db: clients.db,
      bucket: clients.bucket,
      pageSize: args.pageSize,
    });
    const manifest = readManifest(args.manifestPath);
    const plan = planCleanup({
      dryRun: args.dryRun,
      execute: args.execute,
      confirmExecute: args.confirmExecute,
      manifest,
      currentEntries: report.entries,
    });
    printPlan(plan);
    return 0;
  } catch (error) {
    console.error(`cleanupPlanFailed: ${error.code || 'UNKNOWN_RUNTIME_ERROR'}`);
    console.error('writesAttempted: 0');
    console.error('deletesAttempted: 0');
    console.error('authMutations: 0');
    console.error('firestoreMutations: 0');
    console.error('storageMutations: 0');
    return 1;
  }
}

if (require.main === module) {
  main().then((code) => {
    process.exitCode = code;
  });
}

module.exports = {
  EXECUTE_CONFIRMATION,
  parseArgs,
  readManifest,
};
