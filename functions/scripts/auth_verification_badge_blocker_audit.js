'use strict';

// Read-only forensic audit of the Phase 0-D-3 migration blockers: orphan
// users/publicProfiles documents (no matching Auth account) and malformed
// users.verifications maps. This tool NEVER writes and NEVER deletes: no
// Firestore mutation API and no Auth mutation API is used here or in
// ../lib/auth_verification_badge_blocker_audit.

const { execFileSync } = require('node:child_process');
const path = require('node:path');
const admin = require('firebase-admin');
const {
  MALFORMED_SHAPES,
  classifyOrphans,
  computeOrphanSets,
  diagnoseMalformedUser,
  aggregateOrphanReferences,
} = require('../lib/auth_verification_badge_blocker_audit');
const forensics = require('../lib/auth_verification_badge_unknown_orphan_forensics');

const EXPECTED_PROJECT_ID = 'cvr-dating-app';
const DEFAULT_PAGE_SIZE = 100;
const MAX_PAGE_SIZE = 1000;

// Historical file that created the fixed dummy_001..010 seed accounts.
const DUMMY_SERVICE_PATH = 'lib/dev/dummy_data_service.dart';
const REPO_ROOT = path.join(__dirname, '..', '..');

function usage() {
  return [
    'Usage:',
    '  npm --prefix functions run audit:auth-verification-badge-blockers -- --project cvr-dating-app [options]',
    '',
    'Options:',
    '  --project <projectId>   Required Firebase project ID (must be cvr-dating-app)',
    '  --page-size <number>    Page size for Auth/collection scan, max 1000 (default 100)',
    '  --forensic-unknown      Deep read-only forensic classification of the single',
    '                          unknown orphan pair (aborts unless exactly 1 exists)',
    '  --help                  Show this help',
    '',
    'This tool is read-only. It performs no writes, deletes, or migration.',
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
    help: false,
    forensicUnknown: false,
  };
  const seen = new Set();
  const forbidden = new Set([
    '--apply',
    '--write',
    '--fix',
    '--migrate',
    '--update',
    '--delete',
    '--cleanup',
  ]);

  function markSeen(option) {
    if (seen.has(option)) throw new Error(`Duplicate argument: ${option}`);
    seen.add(option);
  }

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (forbidden.has(arg)) {
      throw new Error(`Unsupported write-mode flag: ${arg}. This tool is read-only.`);
    }
    if (arg === '--help') {
      markSeen(arg);
      args.help = true;
    } else if (arg === '--forensic-unknown') {
      markSeen(arg);
      args.forensicUnknown = true;
    } else if (arg === '--project') {
      markSeen(arg);
      index += 1;
      if (!argv[index]) throw new Error('--project requires a value');
      args.project = argv[index];
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
    for (const key of ['code', 'name', 'details', 'message']) {
      const value = item[key];
      if (typeof value === 'string' || typeof value === 'number') {
        parts.push(String(value));
      }
    }
  }
  return parts.join(' ').toLowerCase();
}

function classifyReadError(error) {
  const text = rawDiagnosticText(error);
  if (/invalid_grant|reauth/.test(text)) return 'ADC_REFRESH_FAILED';
  if (/could not load the default credentials|application default credentials|default credentials/.test(text)) {
    return 'ADC_UNAVAILABLE';
  }
  if (/\b(7|permission[-_\s]?denied)\b/.test(text)) return 'PERMISSION_DENIED';
  if (/\b(16|unauthenticated)\b/.test(text)) return 'UNAUTHENTICATED';
  if (/enotfound|eai_again/.test(text)) return 'DNS_FAILURE';
  if (/econnrefused|econnreset|network unavailable/.test(text)) return 'NETWORK_UNAVAILABLE';
  if (/etimedout|deadline exceeded|timeout/.test(text)) return 'CONNECTION_TIMEOUT';
  if (/auth\/|identitytoolkit/.test(text)) return 'AUTH_API_UNAVAILABLE';
  if (/project not found/.test(text)) return 'PROJECT_NOT_FOUND';
  if (/resource exhausted|quota/.test(text)) return 'RESOURCE_EXHAUSTED';
  if (/unavailable|service unavailable|api has not been used|service disabled/.test(text)) {
    return 'FIRESTORE_API_UNAVAILABLE';
  }
  return 'UNKNOWN_RUNTIME_ERROR';
}

async function listAuthUsers(auth, pageSize) {
  const authIds = new Set();
  const recordEntries = [];
  let pageToken;
  do {
    const page = await auth.listUsers(pageSize, pageToken);
    for (const record of page.users) {
      authIds.add(record.uid);
      recordEntries.push([record.uid, record]);
    }
    pageToken = page.pageToken;
  } while (pageToken);
  return { authIds, userRecords: new Map(recordEntries) };
}

async function scanCollectionIds(db, collectionName, pageSize) {
  const documentId = admin.firestore.FieldPath.documentId();
  const ids = [];
  let lastId = null;
  for (;;) {
    let query = db
      .collection(collectionName)
      .select()
      .orderBy(documentId)
      .limit(pageSize);
    if (lastId !== null) query = query.startAfter(lastId);
    const page = await query.get();
    if (page.empty) break;
    for (const doc of page.docs) ids.push(doc.id);
    lastId = page.docs[page.docs.length - 1].id;
    if (page.size < pageSize) break;
  }
  return ids;
}

// Read-only reference descriptors. Only the membership UID fields are pulled;
// message text, names, and other profile values are never read into memory.
async function collectReferences(db, orphanIds) {
  const swipesSnap = await db.collectionGroup('swipes').get();
  const swipes = swipesSnap.docs.map((doc) => ({
    actorUid: doc.get('actorUid'),
    targetUid: doc.get('targetUid'),
  }));

  const matchesSnap = await db.collection('matches').get();
  const matches = matchesSnap.docs.map((doc) => ({
    id: doc.id,
    participants: doc.get('participants'),
    uid1: doc.get('uid1'),
    uid2: doc.get('uid2'),
  }));

  let blocks = [];
  try {
    const blocksSnap = await db.collectionGroup('blocks').get();
    blocks = blocksSnap.docs.map((doc) => ({
      blockerUid: doc.get('blockerUid'),
      blockedUid: doc.get('blockedUid'),
    }));
  } catch (error) {
    // blocks collectionGroup may be absent; treat as no references.
    blocks = [];
  }

  let reports = [];
  try {
    const reportsSnap = await db.collection('reports').get();
    reports = reportsSnap.docs.map((doc) => ({
      reportedUid: doc.get('reportedUid'),
      reporterUid: doc.get('reporterUid'),
    }));
  } catch (error) {
    reports = [];
  }

  // Only read messages for matches that involve an orphan participant.
  const orphanSet = orphanIds instanceof Set ? orphanIds : new Set(orphanIds);
  const messages = [];
  for (const match of matches) {
    const participants = Array.isArray(match.participants) ? match.participants : [];
    const involvesOrphan =
      participants.some((id) => orphanSet.has(id)) ||
      orphanSet.has(match.uid1) ||
      orphanSet.has(match.uid2);
    if (!involvesOrphan) continue;
    const messagesSnap = await db
      .collection('matches')
      .doc(match.id)
      .collection('messages')
      .get();
    for (const doc of messagesSnap.docs) {
      messages.push({ senderId: doc.get('senderId') });
    }
  }

  return { swipes, matches, blocks, reports, messages };
}

async function diagnoseMalformed(db, authIds, userRecords) {
  const userRefs = [...authIds].map((uid) => db.collection('users').doc(uid));
  const publicRefs = [...authIds].map((uid) => db.collection('publicProfiles').doc(uid));
  const [userSnaps, publicSnaps] = await Promise.all([
    userRefs.length ? db.getAll(...userRefs) : Promise.resolve([]),
    publicRefs.length ? db.getAll(...publicRefs) : Promise.resolve([]),
  ]);
  const userById = new Map(userSnaps.map((snap) => [snap.id, snap]));
  const publicById = new Map(publicSnaps.map((snap) => [snap.id, snap]));

  const shapeCounts = {
    MISSING: 0,
    NOT_A_MAP: 0,
    MISSING_KEYS: 0,
    EXTRA_KEYS: 0,
    NON_BOOLEAN_VALUES: 0,
    MULTIPLE_SHAPE_ERRORS: 0,
  };
  const migrationCounts = {
    USERS_ONLY: 0,
    PUBLIC_ONLY: 0,
    BOTH: 0,
    ALREADY_CANONICAL: 0,
  };
  const malformedLines = [];
  let malformedUsersCount = 0;
  let safeToNormalizeAutomatically = 0;
  let manualRepairRequired = 0;

  for (const uid of authIds) {
    const userSnap = userById.get(uid);
    const publicSnap = publicById.get(uid);
    const usersDocExists = Boolean(userSnap && userSnap.exists);
    const publicDocExists = Boolean(publicSnap && publicSnap.exists);
    const rawUserVerifications = usersDocExists ? userSnap.data().verifications : undefined;
    const rawPublicVerifications = publicDocExists ? publicSnap.data().verifications : undefined;

    const diagnosis = diagnoseMalformedUser({
      uid,
      userRecord: userRecords.get(uid),
      rawUserVerifications,
      rawPublicVerifications,
    });

    if (diagnosis.usersShape !== MALFORMED_SHAPES.VALID) {
      malformedUsersCount += 1;
      if (shapeCounts[diagnosis.usersShape] !== undefined) {
        shapeCounts[diagnosis.usersShape] += 1;
      }
      migrationCounts[diagnosis.migration] += 1;
      // Auto-normalizable only when both target documents exist (the migration
      // transaction replaces the whole verifications map). Missing docs need
      // manual/backfill repair first.
      if (usersDocExists && publicDocExists) {
        safeToNormalizeAutomatically += 1;
      } else {
        manualRepairRequired += 1;
      }
      malformedLines.push(
        [
          `uidHash=${diagnosis.uidHash}`,
          `usersShape=${diagnosis.usersShape}`,
          `publicShape=${diagnosis.publicShape}`,
          `missingKeys=${diagnosis.missingKeys.join(',') || '-'}`,
          `extraKeys=${diagnosis.extraKeys.join(',') || '-'}`,
          `nonBooleanKeys=${diagnosis.nonBooleanKeys.join(',') || '-'}`,
          `canonicalChangedKeys=${diagnosis.canonicalChangedKeys.join(',') || '-'}`,
          `migration=${diagnosis.migration}`,
        ].join(' '),
      );
    }
  }

  return {
    malformedUsersCount,
    shapeCounts,
    migrationCounts,
    malformedLines,
    safeToNormalizeAutomatically,
    manualRepairRequired,
  };
}

// ---------------------------------------------------------------------------
// Forensic classification of the single unknown orphan (read-only).
// ---------------------------------------------------------------------------

function timestampToSeconds(ts) {
  if (!ts) return null;
  if (typeof ts.seconds === 'number') return ts.seconds;
  if (typeof ts._seconds === 'number') return ts._seconds;
  if (typeof ts.toMillis === 'function') return ts.toMillis() / 1000;
  return null;
}

function absSecondsBetween(a, b) {
  if (typeof a !== 'number' || typeof b !== 'number') return null;
  return Math.abs(a - b);
}

// Read one users + publicProfiles document pair with snapshot metadata.
async function readDocPair(db, uid) {
  const [usersSnap, publicSnap] = await Promise.all([
    db.collection('users').doc(uid).get(),
    db.collection('publicProfiles').doc(uid).get(),
  ]);
  return {
    usersData: usersSnap.exists ? usersSnap.data() : undefined,
    publicData: publicSnap.exists ? publicSnap.data() : undefined,
    usersCreateSec: timestampToSeconds(usersSnap.createTime),
    usersUpdateSec: timestampToSeconds(usersSnap.updateTime),
    publicCreateSec: timestampToSeconds(publicSnap.createTime),
    publicUpdateSec: timestampToSeconds(publicSnap.updateTime),
    usersExists: usersSnap.exists,
    publicExists: publicSnap.exists,
  };
}

// Build a reference group: schema fingerprints (users + public) plus the users
// createTime seconds (for cohort windows). Only reads the given ids.
async function buildReferenceGroup(db, ids) {
  const userFps = [];
  const publicFps = [];
  const usersCreateSecs = [];
  for (const id of ids) {
    // eslint-disable-next-line no-await-in-loop
    const pair = await readDocPair(db, id);
    if (pair.usersExists) {
      userFps.push(forensics.schemaFingerprint(pair.usersData));
      if (typeof pair.usersCreateSec === 'number') {
        usersCreateSecs.push(pair.usersCreateSec);
      }
    }
    if (pair.publicExists) publicFps.push(forensics.schemaFingerprint(pair.publicData));
  }
  return { userFps, publicFps, usersCreateSecs };
}

// Read the swipes + matches that involve the orphan, with privacy-safe fields
// only (uids for membership, timestamp seconds, message counts).
async function readOrphanReferences(db, orphanUid) {
  const swipesSnap = await db.collectionGroup('swipes').get();
  const swipes = swipesSnap.docs
    .map((doc) => ({
      actorUid: doc.get('actorUid'),
      targetUid: doc.get('targetUid'),
      timestampSec: timestampToSeconds(doc.get('timestamp')),
    }))
    .filter((s) => s.actorUid === orphanUid || s.targetUid === orphanUid);

  const matchesSnap = await db.collection('matches').get();
  const matches = [];
  for (const doc of matchesSnap.docs) {
    const participants = doc.get('participants');
    const uid1 = doc.get('uid1');
    const uid2 = doc.get('uid2');
    const members = new Set([
      ...(Array.isArray(participants) ? participants : []),
      uid1,
      uid2,
    ]);
    if (!members.has(orphanUid)) continue;

    // Message existence/count only — message text is never read.
    // eslint-disable-next-line no-await-in-loop
    const messagesSnap = await doc.ref.collection('messages').select().get();
    // Detect non-message subcollections without reading their contents.
    let nonMessageSubcollections = 0;
    try {
      // eslint-disable-next-line no-await-in-loop
      const subcollections = await doc.ref.listCollections();
      nonMessageSubcollections = subcollections.filter(
        (col) => col.id !== 'messages',
      ).length;
    } catch (_) {
      nonMessageSubcollections = 0;
    }
    matches.push({
      participants: Array.isArray(participants) ? participants : [],
      uid1,
      uid2,
      timestampSec: timestampToSeconds(doc.get('matchedAt')),
      messageCount: messagesSnap.size,
      nonMessageSubcollections,
    });
  }
  return { swipes, matches };
}

// Search git history for the raw document id. Captured internally; only a
// boolean and safe commit hashes are ever surfaced (never the id itself).
function gitExactIdLookup(rawUid) {
  const commits = new Set();
  let found = false;
  const runGit = (gitArgs) => {
    try {
      return execFileSync('git', gitArgs, {
        cwd: REPO_ROOT,
        encoding: 'utf8',
        stdio: ['ignore', 'pipe', 'ignore'],
      });
    } catch (_) {
      return '';
    }
  };

  // 1) Pickaxe search across all history for the exact id string.
  const pickaxe = runGit(['log', '--all', '--oneline', `-S${rawUid}`]);
  for (const line of pickaxe.split('\n')) {
    const hash = line.trim().split(/\s+/)[0];
    if (hash) {
      commits.add(hash);
      found = true;
    }
  }

  // 2) Direct scan of every historical version of the dummy service file.
  const log = runGit(['log', '--all', '--format=%h', '--', DUMMY_SERVICE_PATH]);
  for (const hash of log.split('\n').map((l) => l.trim()).filter(Boolean)) {
    const content = runGit(['show', `${hash}:${DUMMY_SERVICE_PATH}`]);
    if (content && content.includes(rawUid)) {
      commits.add(hash);
      found = true;
    }
  }

  return { found, commits: [...commits] };
}

async function runForensic({ db, authIds, orphan, userDocIds, publicDocIds }) {
  // Section 2 — select exactly one unknown orphan or abort.
  const unknownUid = forensics.selectUnknownOrphan({
    authIds,
    userDocIds,
    publicDocIds,
  });

  // Known dummy vs real (auth) reference id groups.
  const dummyOrphanIds = orphan.orphanUserIds.filter((id) =>
    forensics.KNOWN_DUMMY_ID_PATTERN.test(String(id)),
  );
  const otherUnknownOrphanIds = orphan.orphanUserIds.filter(
    (id) =>
      id !== unknownUid && !forensics.KNOWN_DUMMY_ID_PATTERN.test(String(id)),
  );
  const realIds = [...authIds];

  const sets = {
    authIds: new Set(authIds),
    dummyIds: new Set(dummyOrphanIds),
    otherOrphanIds: new Set([unknownUid, ...otherUnknownOrphanIds]),
  };

  const orphanPair = await readDocPair(db, unknownUid);
  const dummyGroup = await buildReferenceGroup(db, dummyOrphanIds);
  const realGroup = await buildReferenceGroup(db, realIds);
  const references = await readOrphanReferences(db, unknownUid);

  const usersFp = forensics.schemaFingerprint(orphanPair.usersData);
  const publicFp = forensics.schemaFingerprint(orphanPair.publicData);

  const usersSchemaSimilarityToDummy = forensics.schemaSimilarityToGroup(
    usersFp,
    dummyGroup.userFps,
  );
  const usersSchemaSimilarityToReal = forensics.schemaSimilarityToGroup(
    usersFp,
    realGroup.userFps,
  );
  const publicSchemaSimilarityToDummy = forensics.schemaSimilarityToGroup(
    publicFp,
    dummyGroup.publicFps,
  );
  const publicSchemaSimilarityToReal = forensics.schemaSimilarityToGroup(
    publicFp,
    realGroup.publicFps,
  );

  const createdWithDummyCohort = forensics.cohortMembership(
    orphanPair.usersCreateSec,
    dummyGroup.usersCreateSecs,
  );
  const updatedWithDummyCohort = forensics.cohortMembership(
    orphanPair.usersUpdateSec,
    dummyGroup.usersCreateSecs,
  );

  const characteristics = forensics.valueCharacteristics(orphanPair.usersData);
  const lifecycle = forensics.lifecycleMarkers(orphanPair.usersData);

  const swipeAgg = forensics.aggregateOrphanSwipes({
    orphanUid: unknownUid,
    swipes: references.swipes,
    sets,
    cohortTimesSec: dummyGroup.usersCreateSecs,
  });
  const matchAgg = forensics.aggregateOrphanMatches({
    orphanUid: unknownUid,
    matches: references.matches,
    sets,
    cohortTimesSec: dummyGroup.usersCreateSecs,
  });
  const relations = forensics.aggregateRelations({ swipeAgg, matchAgg });

  const git = gitExactIdLookup(unknownUid);
  const payloadPatternMatchesHistoricalDummy =
    forensics.payloadPatternMatchesHistoricalDummy(characteristics);
  const referencePatternMatchesHistoricalDummy =
    forensics.referencePatternMatchesHistoricalDummy(swipeAgg);

  const totalReferenceCount =
    swipeAgg.unknownAsSwipeActor +
    swipeAgg.unknownAsSwipeTarget +
    matchAgg.matchesContainingUnknown;

  const scoringSignals = {
    exactIdFoundInGitHistory: git.found,
    payloadPatternMatchesHistoricalDummy,
    referencePatternMatchesHistoricalDummy,
    createdWithDummyCohort,
    documentIdFormatClass: forensics.classifyDocumentIdFormat(unknownUid),
    usersSchemaSimilarityToDummy,
    usersSchemaSimilarityToReal,
    publicSchemaSimilarityToDummy,
    publicSchemaSimilarityToReal,
    photoStorageClass: characteristics.photoStorageClass,
    hasProfilePhotos: characteristics.hasProfilePhotos,
    hasNonEmptyDisplayName: characteristics.hasNonEmptyDisplayName,
    hasOnboardingCompletionState: characteristics.hasOnboardingCompletionState,
    hasFCMTokens: characteristics.hasFCMTokens,
    hasActivityTimestamp: lifecycle.hasActivityTimestamp,
    hasCompletedOnboardingMarker: lifecycle.hasCompletedOnboardingMarker,
    hasDeletionMarker: lifecycle.hasDeletionMarker,
    hasDeactivationMarker: lifecycle.hasDeactivationMarker,
    relatedCurrentAuthUsers: relations.relatedCurrentAuthUsers,
    relatedKnownDummyUsers: relations.relatedKnownDummyUsers,
    relatedOtherUnknownUsers: relations.relatedOtherUnknownUsers,
    matchesWithMessages: matchAgg.matchesWithMessages,
    totalReferenceCount,
  };

  const classification = forensics.scoreClassification(scoringSignals);
  const cleanup = forensics.cleanupDecision({
    classification: classification.classification,
    confidence: classification.confidence,
    signals: scoringSignals,
  });

  return {
    uidHash: forensics.safeUidHash(unknownUid),
    documentIdFormatClass: scoringSignals.documentIdFormatClass,
    documentIdLength: String(unknownUid).length,
    pairPresent: orphanPair.usersExists && orphanPair.publicExists,
    metadata: {
      usersCreateTimeExists: orphanPair.usersCreateSec != null,
      usersUpdateTimeExists: orphanPair.usersUpdateSec != null,
      publicCreateTimeExists: orphanPair.publicCreateSec != null,
      publicUpdateTimeExists: orphanPair.publicUpdateSec != null,
      createTimeDiffBucket: forensics.metadataTimeBucket(
        absSecondsBetween(orphanPair.usersCreateSec, orphanPair.publicCreateSec),
      ),
      updateTimeDiffBucket: forensics.metadataTimeBucket(
        absSecondsBetween(orphanPair.usersUpdateSec, orphanPair.publicUpdateSec),
      ),
      createdWithDummyCohort,
      updatedWithDummyCohort,
    },
    schema: {
      usersSchemaSimilarityToDummy,
      usersSchemaSimilarityToReal,
      publicSchemaSimilarityToDummy,
      publicSchemaSimilarityToReal,
    },
    characteristics,
    lifecycle,
    git,
    payloadPatternMatchesHistoricalDummy,
    referencePatternMatchesHistoricalDummy,
    swipeAgg,
    matchAgg,
    relations,
    classification,
    cleanup,
    dummyGroupSize: dummyGroup.userFps.length,
    realGroupSize: realGroup.userFps.length,
  };
}

function printForensicReport(f) {
  console.log('=== Unknown Orphan Forensic Classification (read-only) ===');
  console.log('--- B. Identity fingerprint ---');
  console.log(`uidHash: ${f.uidHash}`);
  console.log(`documentIdLength: ${f.documentIdLength}`);
  console.log(`documentIdFormatClass: ${f.documentIdFormatClass}`);
  console.log(`usersAndPublicPairPresent: ${f.pairPresent}`);
  console.log(`knownDummyGroupSize: ${f.dummyGroupSize}`);
  console.log(`realUserGroupSize: ${f.realGroupSize}`);

  console.log('--- Metadata ---');
  console.log(`usersCreateTimeExists: ${f.metadata.usersCreateTimeExists}`);
  console.log(`usersUpdateTimeExists: ${f.metadata.usersUpdateTimeExists}`);
  console.log(`publicCreateTimeExists: ${f.metadata.publicCreateTimeExists}`);
  console.log(`publicUpdateTimeExists: ${f.metadata.publicUpdateTimeExists}`);
  console.log(`createTimeDiffBucket: ${f.metadata.createTimeDiffBucket}`);
  console.log(`updateTimeDiffBucket: ${f.metadata.updateTimeDiffBucket}`);
  console.log(`createdWithDummyCohort: ${f.metadata.createdWithDummyCohort}`);
  console.log(`updatedWithDummyCohort: ${f.metadata.updatedWithDummyCohort}`);

  console.log('--- Schema similarity ---');
  console.log(`usersSchemaSimilarityToDummy: ${f.schema.usersSchemaSimilarityToDummy}`);
  console.log(`usersSchemaSimilarityToReal: ${f.schema.usersSchemaSimilarityToReal}`);
  console.log(`publicSchemaSimilarityToDummy: ${f.schema.publicSchemaSimilarityToDummy}`);
  console.log(`publicSchemaSimilarityToReal: ${f.schema.publicSchemaSimilarityToReal}`);

  console.log('--- C. Profile characteristics (privacy-safe) ---');
  const c = f.characteristics;
  console.log(`hasNonEmptyDisplayName: ${c.hasNonEmptyDisplayName}`);
  console.log(`hasProfilePhotos: ${c.hasProfilePhotos}`);
  console.log(`photoCountBucket: ${c.photoCountBucket}`);
  console.log(`photoStorageClass: ${c.photoStorageClass}`);
  console.log(`hasBio: ${c.hasBio}`);
  console.log(`hasBirthData: ${c.hasBirthData}`);
  console.log(`hasExactLocation: ${c.hasExactLocation}`);
  console.log(`hasCoarseLocation: ${c.hasCoarseLocation}`);
  console.log(`hasOnboardingCompletionState: ${c.hasOnboardingCompletionState}`);
  console.log(`hasAccountContactFields: ${c.hasAccountContactFields}`);
  console.log(`hasProviderOrAuthMetadataFields: ${c.hasProviderOrAuthMetadataFields}`);
  console.log(`hasFCMTokens: ${c.hasFCMTokens}`);
  console.log(`hasJellyOrTransactionState: ${c.hasJellyOrTransactionState}`);

  console.log('--- Lifecycle markers ---');
  console.log(`hasDeletionMarker: ${f.lifecycle.hasDeletionMarker}`);
  console.log(`hasDeactivationMarker: ${f.lifecycle.hasDeactivationMarker}`);
  console.log(`hasActivityTimestamp: ${f.lifecycle.hasActivityTimestamp}`);
  console.log(`hasCompletedOnboardingMarker: ${f.lifecycle.hasCompletedOnboardingMarker}`);

  console.log('--- D. Git history / seed clues ---');
  console.log(`exactIdFoundInGitHistory: ${f.git.found ? 'yes' : 'no'}`);
  console.log(`payloadPatternMatchesHistoricalDummy: ${f.payloadPatternMatchesHistoricalDummy}`);
  console.log(`referencePatternMatchesHistoricalDummy: ${f.referencePatternMatchesHistoricalDummy}`);
  console.log(`relevantHistoricalCommits: ${JSON.stringify(f.git.commits)}`);

  console.log('--- E. Swipe relations ---');
  console.log(`unknownAsSwipeActor: ${f.swipeAgg.unknownAsSwipeActor}`);
  console.log(`unknownAsSwipeTarget: ${f.swipeAgg.unknownAsSwipeTarget}`);
  console.log(`swipesWithCurrentAuthUsers: ${f.swipeAgg.swipesWithCurrentAuthUsers}`);
  console.log(`swipesWithKnownDummyUsers: ${f.swipeAgg.swipesWithKnownDummyUsers}`);
  console.log(`swipesWithOtherOrphans: ${f.swipeAgg.swipesWithOtherOrphans}`);
  console.log(`swipeTimestampCohort: ${f.swipeAgg.swipeTimestampCohort}`);

  console.log('--- F. Match relations ---');
  console.log(`matchesContainingUnknown: ${f.matchAgg.matchesContainingUnknown}`);
  console.log(`matchesWithCurrentAuthUsers: ${f.matchAgg.matchesWithCurrentAuthUsers}`);
  console.log(`matchesWithKnownDummyUsers: ${f.matchAgg.matchesWithKnownDummyUsers}`);
  console.log(`matchesWithOtherOrphans: ${f.matchAgg.matchesWithOtherOrphans}`);
  console.log(`matchesWithMessages: ${f.matchAgg.matchesWithMessages}`);
  console.log(`matchesWithNonMessageSubcollections: ${f.matchAgg.matchesWithNonMessageSubcollections}`);
  console.log(`matchTimestampCohort: ${f.matchAgg.matchTimestampCohort}`);

  console.log('--- G. Relationship summary ---');
  console.log(`relatedCurrentAuthUsers: ${f.relations.relatedCurrentAuthUsers}`);
  console.log(`relatedKnownDummyUsers: ${f.relations.relatedKnownDummyUsers}`);
  console.log(`relatedOtherUnknownUsers: ${f.relations.relatedOtherUnknownUsers}`);

  console.log('--- H. Classification ---');
  console.log(`classification: ${f.classification.classification}`);
  console.log(`confidence: ${f.classification.confidence}`);
  console.log(`supportingSignals: ${JSON.stringify(f.classification.supportingSignals)}`);
  console.log(`contradictingSignals: ${JSON.stringify(f.classification.contradictingSignals)}`);

  console.log('--- I. Cleanup decision ---');
  console.log(`cleanupDecision: ${f.cleanup}`);

  console.log('--- Forensic safety ---');
  console.log('forensicWritesAttempted: 0');
  console.log('forensicDeletesPerformed: 0');
}

function printReport(report) {
  const {
    project,
    authUsersScanned,
    usersDocumentsFound,
    publicProfilesDocumentsFound,
    orphan,
    orphanUserClass,
    orphanPublicClass,
    references,
    malformed,
    discovery,
  } = report;

  console.log('=== Auth Verification Badge Blocker Audit (read-only) ===');
  console.log(`project: ${project}`);
  console.log('mode: dry-run');
  console.log(`authUsersScanned: ${authUsersScanned}`);
  console.log(`usersDocumentsFound: ${usersDocumentsFound}`);
  console.log(`publicProfilesDocumentsFound: ${publicProfilesDocumentsFound}`);

  console.log('--- Orphan sets ---');
  console.log(`orphanUserCount: ${orphan.orphanUserCount}`);
  console.log(`orphanPublicCount: ${orphan.orphanPublicCount}`);
  console.log(`pairedOrphanCount: ${orphan.pairedOrphanCount}`);
  console.log(`usersOnlyOrphanCount: ${orphan.usersOnlyOrphanCount}`);
  console.log(`publicOnlyOrphanCount: ${orphan.publicOnlyOrphanCount}`);
  console.log(`orphanIdSetsExactlyEqual: ${orphan.orphanIdSetsExactlyEqual}`);

  console.log('--- Orphan classification ---');
  console.log(`knownDummyOrphanUsers: ${orphanUserClass.knownDummy}`);
  console.log(`unknownOrphanUsers: ${orphanUserClass.unknown}`);
  console.log(`knownDummyOrphanPublicProfiles: ${orphanPublicClass.knownDummy}`);
  console.log(`unknownOrphanPublicProfiles: ${orphanPublicClass.unknown}`);

  console.log('--- Discovery exposure ---');
  console.log(`orphanPublicProfilesPotentiallyDiscoverable: ${discovery.potentiallyDiscoverable}`);
  console.log(`orphanPublicProfilesExcludedByCurrentQuery: ${discovery.excludedByCurrentQuery}`);
  console.log(`discoveryVerdict: ${discovery.verdict}`);

  console.log('--- Reference integrity ---');
  console.log(`orphanReferencesFound: ${references.orphanReferencesFound}`);
  console.log(`referencingCollections: ${JSON.stringify(references.referencingCollections)}`);
  console.log(`orphanMatchReferences: ${references.orphanMatchReferences}`);
  console.log(`orphanSwipeReferences: ${references.orphanSwipeReferences}`);
  console.log(`orphanBlockReferences: ${references.orphanBlockReferences}`);
  console.log(`orphanMessageOrChatReferences: ${references.orphanMessageOrChatReferences}`);
  console.log(`otherOrphanReferences: ${references.otherOrphanReferences}`);

  console.log('--- Malformed verifications ---');
  console.log(`malformedUsersCount: ${malformed.malformedUsersCount}`);
  console.log(`shapeCounts: ${JSON.stringify(malformed.shapeCounts)}`);
  console.log(`migrationImpact: ${JSON.stringify(malformed.migrationCounts)}`);
  console.log(`safeToNormalizeAutomatically: ${malformed.safeToNormalizeAutomatically}`);
  console.log(`manualRepairRequired: ${malformed.manualRepairRequired}`);
  for (const line of malformed.malformedLines) {
    console.log(`  ${line}`);
  }

  console.log('--- Safety ---');
  console.log('writesAttempted: 0');
  console.log('deletesPerformed: 0');
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
    const { auth, db } = initializeFirebase(args.project);
    const { authIds, userRecords } = await listAuthUsers(auth, args.pageSize);
    const userDocIds = await scanCollectionIds(db, 'users', args.pageSize);
    const publicDocIds = await scanCollectionIds(db, 'publicProfiles', args.pageSize);

    const orphan = computeOrphanSets(authIds, userDocIds, publicDocIds);
    const orphanUserClass = classifyOrphans(orphan.orphanUserIds);
    const orphanPublicClass = classifyOrphans(orphan.orphanPublicIds);
    const orphanUnion = new Set([...orphan.orphanUserIds, ...orphan.orphanPublicIds]);

    const referenceInput = await collectReferences(db, orphanUnion);
    const references = aggregateOrphanReferences(referenceInput, orphanUnion);

    const malformed = await diagnoseMalformed(db, authIds, userRecords);

    // Discovery has no Auth-existence filter (see lib/services/discovery/
    // discovery_service.dart): every orphan public profile is a potential
    // candidate, filtered only per-viewer by age/gender/goal/distance/swipe.
    const discovery = {
      potentiallyDiscoverable: orphan.orphanPublicCount,
      excludedByCurrentQuery: 0,
      verdict: orphan.orphanPublicCount > 0 ? 'DISCOVERABLE' : 'NOT_DISCOVERABLE',
    };

    printReport({
      project: args.project,
      authUsersScanned: authIds.size,
      usersDocumentsFound: userDocIds.length,
      publicProfilesDocumentsFound: publicDocIds.length,
      orphan,
      orphanUserClass,
      orphanPublicClass,
      references,
      malformed,
      discovery,
    });

    const migrationReady =
      orphanUserClass.unknown === 0 &&
      orphanPublicClass.unknown === 0 &&
      malformed.manualRepairRequired === 0;
    console.log(
      `verdict: ${migrationReady ? 'ALL_ORPHANS_KNOWN_DUMMY_AND_MALFORMED_SAFE' : 'UNKNOWN_ORPHAN_OR_MANUAL_REPAIR'}`,
    );
    // Note: known dummy orphans are still excluded from the auth badge
    // migration; this verdict only reports whether unknown orphans or unsafe
    // malformed docs would block the apply-tool design.

    if (args.forensicUnknown) {
      console.log('');
      try {
        const forensicReport = await runForensic({
          db,
          authIds,
          orphan,
          userDocIds,
          publicDocIds,
        });
        printForensicReport(forensicReport);
        const cls = forensicReport.classification.classification;
        let nextStep;
        if (
          cls === forensics.CLASSIFICATION.KNOWN_SEED_OR_TEST_DATA &&
          forensicReport.cleanup === forensics.CLEANUP_DECISION.SAFE
        ) {
          nextStep = 'UNKNOWN ORPHAN CLASSIFIED — CLEANUP DESIGN READY';
        } else if (forensicReport.cleanup === forensics.CLEANUP_DECISION.RECOVERY) {
          nextStep = 'UNKNOWN ORPHAN ACCOUNT LIFECYCLE REVIEW REQUIRED';
        } else {
          nextStep = 'UNKNOWN ORPHAN MANUAL REVIEW REQUIRED';
        }
        console.log(`forensicNextStep: ${nextStep}`);
      } catch (forensicError) {
        if (
          forensicError.code === 'NO_UNKNOWN_ORPHAN' ||
          forensicError.code === 'MULTIPLE_UNKNOWN_ORPHANS'
        ) {
          console.error(`forensic aborted: ${forensicError.code}`);
          return 3;
        }
        throw forensicError;
      }
    }
    return 0;
  } catch (error) {
    const category = classifyReadError(error);
    console.error(`blocker audit failed: ${category}`);
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
  assertProjectAllowed,
  classifyReadError,
  parseArgs,
  usage,
};
