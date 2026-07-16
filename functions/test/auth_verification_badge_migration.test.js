'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const admin = require('firebase-admin');

const M = require('../lib/auth_verification_badge_migration');
const apply = require('../scripts/auth_verification_badge_apply');

// --- Fixtures -------------------------------------------------------------

// Auth record with verified email + verified phone provider.
function verifiedRecord(uid = 'authUid') {
  return {
    uid,
    email: 'u@example.test',
    emailVerified: true,
    phoneNumber: '+821012345678',
    providerData: [{ providerId: 'phone' }],
  };
}

// Auth record with no verification evidence at all.
function bareRecord(uid = 'authUid') {
  return { uid, email: '', emailVerified: false, phoneNumber: '', providerData: [] };
}

const canonicalAllFalse = { email: false, phone: false, photo: false };

// A fake Firestore transaction that records staged updates.
function makeFakeDb(snapsByPath, { commitFails = false } = {}) {
  const staged = [];
  const tx = {
    get: async (ref) => snapsByPath[ref._path] || { exists: false, data: () => undefined },
    update: (ref, data) => {
      staged.push({ path: ref._path, data });
    },
  };
  const db = {
    _staged: staged,
    _txUpdatesAtThrow: null,
    collection: (name) => ({
      doc: (uid) => ({ _path: `${name}/${uid}` }),
    }),
    runTransaction: async (fn) => {
      const result = await fn(tx);
      if (commitFails) {
        db._txUpdatesAtThrow = staged.length;
        throw new Error('10 ABORTED: too much contention on these documents');
      }
      return result;
    },
  };
  return db;
}

function snap(exists, data) {
  return { exists, data: () => data };
}

// --- 1. Auth list is the only source of the target set -------------------

test('1. migration source is Firebase Auth records only (planner keyed on userRecord)', () => {
  // planUserMigration derives canonical exclusively from userRecord; there is no
  // parameter that accepts a caller-provided target list of Firestore ids.
  const plan = M.planUserMigration({
    uid: 'authUid',
    userRecord: verifiedRecord(),
    usersExists: true,
    usersData: { verifications: { email: true, phone: true, photo: false } },
    publicExists: true,
    publicData: { verifications: { email: true, phone: true, photo: false } },
  });
  assert.equal(plan.result, M.RESULTS.UNCHANGED);
});

// --- 2 & 3. Orphan / caller-provided Firestore ids are never a source ----

test('2. orphan Firestore documents are not a processing source (apply reads Auth only)', () => {
  const source = fs.readFileSync(
    path.join(__dirname, '..', 'scripts', 'auth_verification_badge_apply.js'),
    'utf8',
  );
  // The target set comes from auth.getUser / auth.listUsers only.
  assert.match(source, /auth\.getUser\(/);
  assert.match(source, /auth\.listUsers\(/);
  // No collection-scan of users/publicProfiles to build the target set.
  assert.equal(/\.collection\('users'\)\.(get|listDocuments)\(/.test(source), false);
  assert.equal(/collectionGroup\(/.test(source), false);
});

test('3. planner never trusts a caller-provided Firestore uid list', () => {
  // The only identity input is userRecord.uid; passing extra fields is ignored.
  const plan = M.planUserMigration({
    uid: 'authUid',
    userRecord: verifiedRecord('authUid'),
    firestoreUserIds: ['dummy_001', 'orphanX'], // ignored — not a parameter
    usersExists: true,
    usersData: { verifications: canonicalAllFalse },
    publicExists: true,
    publicData: { verifications: canonicalAllFalse },
  });
  assert.match(plan.uidHash, /^[0-9a-f]{8}$/);
});

// --- 4, 5, 6. Canonical policy -------------------------------------------

test('4. verified email is canonical true', () => {
  const plan = M.planUserMigration({
    uid: 'a',
    userRecord: { uid: 'a', email: 'x@y.z', emailVerified: true, providerData: [] },
    usersExists: true,
    usersData: { verifications: canonicalAllFalse },
    publicExists: true,
    publicData: { verifications: canonicalAllFalse },
  });
  assert.equal(plan.canonical.email, true);
  assert.deepEqual(plan.usersUpdate.verifications, { email: true, phone: false, photo: false });
});

test('5. phone canonical requires phone provider AND phoneNumber', () => {
  const noProvider = M.planUserMigration({
    uid: 'a',
    userRecord: { uid: 'a', phoneNumber: '+82101234', providerData: [] },
    usersExists: true,
    usersData: { verifications: canonicalAllFalse },
    publicExists: true,
    publicData: { verifications: canonicalAllFalse },
  });
  assert.equal(noProvider.canonical.phone, false);

  const withProvider = M.planUserMigration({
    uid: 'a',
    userRecord: {
      uid: 'a',
      phoneNumber: '+82101234',
      providerData: [{ providerId: 'phone' }],
    },
    usersExists: true,
    usersData: { verifications: canonicalAllFalse },
    publicExists: true,
    publicData: { verifications: canonicalAllFalse },
  });
  assert.equal(withProvider.canonical.phone, true);
});

test('6. photo canonical is always false', () => {
  const plan = M.planUserMigration({
    uid: 'a',
    userRecord: verifiedRecord(),
    usersExists: true,
    usersData: { verifications: { email: true, phone: true, photo: true } },
    publicExists: true,
    publicData: { verifications: { email: true, phone: true, photo: true } },
  });
  assert.equal(plan.canonical.photo, false);
  // photo:true stored -> canonical false -> photo TrueToFalse write.
  assert.equal(plan.usersUpdate.verifications.photo, false);
});

// --- 7. No-op when canonical + valid ------------------------------------

test('7. both canonical and valid shape is a no-op', () => {
  const plan = M.planUserMigration({
    uid: 'a',
    userRecord: verifiedRecord(),
    usersExists: true,
    usersData: { verifications: { email: true, phone: true, photo: false } },
    publicExists: true,
    publicData: { verifications: { email: true, phone: true, photo: false } },
  });
  assert.equal(plan.result, M.RESULTS.UNCHANGED);
  assert.equal(plan.writesPlanned, 0);
  assert.equal(plan.usersUpdate, null);
  assert.equal(plan.publicUpdate, null);
});

// --- 8, 9, 10. Malformed normalization ----------------------------------

test('8. users MISSING map is a normalization write (value-equivalent)', () => {
  const plan = M.planUserMigration({
    uid: 'a',
    userRecord: bareRecord(), // canonical all-false
    usersExists: true,
    usersData: {}, // verifications MISSING
    publicExists: true,
    publicData: { verifications: canonicalAllFalse },
  });
  assert.equal(plan.result, M.RESULTS.NORMALIZED_USERS_ONLY);
  assert.equal(plan.usersNormalized, true);
  assert.deepEqual(plan.usersUpdate.verifications, canonicalAllFalse);
  assert.equal(plan.publicUpdate, null);
  assert.equal(plan.bumpProfileUpdatedAt, false);
});

test('9. public MISSING map is a normalization write', () => {
  const plan = M.planUserMigration({
    uid: 'a',
    userRecord: bareRecord(),
    usersExists: true,
    usersData: { verifications: canonicalAllFalse },
    publicExists: true,
    publicData: {},
  });
  assert.equal(plan.result, M.RESULTS.NORMALIZED_PUBLIC_PROFILE_ONLY);
  assert.equal(plan.publicNormalized, true);
  // Value-equivalent normalization must NOT bump the timestamp.
  assert.equal(plan.bumpProfileUpdatedAt, false);
});

test('10. both malformed normalizes both documents', () => {
  const plan = M.planUserMigration({
    uid: 'a',
    userRecord: bareRecord(),
    usersExists: true,
    usersData: { verifications: 'not-a-map' },
    publicExists: true,
    publicData: { verifications: { email: false, phone: false, photo: false, legacy: 1 } },
  });
  assert.equal(plan.result, M.RESULTS.NORMALIZED_BOTH);
  assert.equal(plan.writesPlanned, 2);
});

// --- 11, 12, 13. Value mismatches ---------------------------------------

test('11. users-only value mismatch', () => {
  const plan = M.planUserMigration({
    uid: 'a',
    userRecord: verifiedRecord(), // email true, phone true
    usersExists: true,
    usersData: { verifications: { email: false, phone: true, photo: false } },
    publicExists: true,
    publicData: { verifications: { email: true, phone: true, photo: false } },
  });
  assert.equal(plan.result, M.RESULTS.UPDATED_USERS_ONLY);
  assert.deepEqual(plan.changedKeys.users, ['email']);
  assert.equal(plan.publicUpdate, null);
});

test('12. public-only value mismatch bumps timestamp', () => {
  const plan = M.planUserMigration({
    uid: 'a',
    userRecord: verifiedRecord(),
    usersExists: true,
    usersData: { verifications: { email: true, phone: true, photo: false } },
    publicExists: true,
    publicData: { verifications: { email: false, phone: true, photo: false } },
  });
  assert.equal(plan.result, M.RESULTS.UPDATED_PUBLIC_PROFILE_ONLY);
  assert.equal(plan.bumpProfileUpdatedAt, true);
});

test('13. both value mismatch', () => {
  const plan = M.planUserMigration({
    uid: 'a',
    userRecord: verifiedRecord(),
    usersExists: true,
    usersData: { verifications: { email: false, phone: false, photo: false } },
    publicExists: true,
    publicData: { verifications: { email: false, phone: false, photo: false } },
  });
  assert.equal(plan.result, M.RESULTS.UPDATED_BOTH);
  assert.equal(plan.writesPlanned, 2);
  assert.equal(plan.bumpProfileUpdatedAt, true);
});

// --- 14, 15, 16. Missing documents (never created) ----------------------

test('14. missing users document is failed-precondition, no write', () => {
  const plan = M.planUserMigration({
    uid: 'a',
    userRecord: verifiedRecord(),
    usersExists: false,
    usersData: undefined,
    publicExists: true,
    publicData: { verifications: canonicalAllFalse },
  });
  assert.equal(plan.result, M.RESULTS.MISSING_USERS_DOCUMENT);
  assert.equal(plan.writesPlanned, 0);
  assert.equal(plan.usersUpdate, null);
  assert.equal(plan.publicUpdate, null);
});

test('15. missing public document is failed-precondition, no write', () => {
  const plan = M.planUserMigration({
    uid: 'a',
    userRecord: verifiedRecord(),
    usersExists: true,
    usersData: { verifications: canonicalAllFalse },
    publicExists: false,
    publicData: undefined,
  });
  assert.equal(plan.result, M.RESULTS.MISSING_PUBLIC_PROFILE_DOCUMENT);
  assert.equal(plan.writesPlanned, 0);
});

test('16. missing both documents', () => {
  const plan = M.planUserMigration({
    uid: 'a',
    userRecord: verifiedRecord(),
    usersExists: false,
    publicExists: false,
  });
  assert.equal(plan.result, M.RESULTS.MISSING_BOTH_DOCUMENTS);
  assert.equal(plan.writesPlanned, 0);
});

// --- 17, 18. Transaction atomicity --------------------------------------

test('17. both document updates happen inside a single transaction', async () => {
  const db = makeFakeDb({
    'users/authUid': snap(true, { verifications: { email: false, phone: false, photo: false } }),
    'publicProfiles/authUid': snap(true, { verifications: { email: false, phone: false, photo: false } }),
  });
  const descriptor = await apply.applyUser(null, db, verifiedRecord('authUid'));
  assert.equal(descriptor.kind, 'committed');
  // Exactly two staged updates, both to the two allowed paths, inside the tx.
  assert.equal(db._staged.length, 2);
  const paths = db._staged.map((u) => u.path).sort();
  assert.deepEqual(paths, ['publicProfiles/authUid', 'users/authUid']);
});

test('18. transaction failure yields no successful writes (no partial success)', async () => {
  const db = makeFakeDb(
    {
      'users/authUid': snap(true, { verifications: { email: false, phone: false, photo: false } }),
      'publicProfiles/authUid': snap(true, { verifications: { email: false, phone: false, photo: false } }),
    },
    { commitFails: true },
  );
  const descriptor = await apply.applyUser(null, db, verifiedRecord('authUid'));
  assert.equal(descriptor.kind, 'transactionError');
  assert.equal(descriptor.writesPlanned, 2);

  const agg = M.createEmptyApplyAggregate('cvr-dating-app');
  apply.foldDescriptor(agg, descriptor);
  assert.equal(agg.writesSucceeded, 0);
  assert.equal(agg.writesAttempted, 2);
  assert.equal(agg.errors, 1);
});

// --- 19, 20. Field scope and timestamp policy ---------------------------

test('19. update payload changes only the verifications field', async () => {
  const db = makeFakeDb({
    'users/authUid': snap(true, {
      displayName: 'Keep Me',
      photoUrls: ['x'],
      bio: 'keep',
      verifications: { email: false, phone: false, photo: false },
    }),
    'publicProfiles/authUid': snap(true, { verifications: { email: false, phone: false, photo: false } }),
  });
  await apply.applyUser(null, db, verifiedRecord('authUid'));
  for (const update of db._staged) {
    const keys = Object.keys(update.data);
    const allowed = new Set(['verifications', 'profileUpdatedAt']);
    for (const key of keys) assert.ok(allowed.has(key), `unexpected write key ${key}`);
    assert.equal('displayName' in update.data, false);
    assert.equal('photoUrls' in update.data, false);
    assert.equal('bio' in update.data, false);
  }
});

test('20. profileUpdatedAt is set only when the public value changes', async () => {
  // Value change on public -> timestamp present.
  const dbChange = makeFakeDb({
    'users/authUid': snap(true, { verifications: { email: true, phone: true, photo: false } }),
    'publicProfiles/authUid': snap(true, { verifications: { email: false, phone: true, photo: false } }),
  });
  await apply.applyUser(null, dbChange, verifiedRecord('authUid'));
  const publicWrite = dbChange._staged.find((u) => u.path === 'publicProfiles/authUid');
  assert.ok('profileUpdatedAt' in publicWrite.data);

  // Pure shape normalization on public (value-equivalent) -> no timestamp.
  const dbNorm = makeFakeDb({
    'users/authUid': snap(true, { verifications: canonicalAllFalse }),
    'publicProfiles/authUid': snap(true, {}), // MISSING map, canonical all-false
  });
  await apply.applyUser(null, dbNorm, bareRecord('authUid'));
  const normWrite = dbNorm._staged.find((u) => u.path === 'publicProfiles/authUid');
  assert.equal('profileUpdatedAt' in normWrite.data, false);
});

// --- 21. Second apply is a no-op ----------------------------------------

test('21. second apply over canonical documents is a no-op', () => {
  const plan = M.planUserMigration({
    uid: 'a',
    userRecord: verifiedRecord(),
    usersExists: true,
    usersData: { verifications: { email: true, phone: true, photo: false } },
    publicExists: true,
    publicData: { verifications: { email: true, phone: true, photo: false } },
  });
  assert.equal(plan.result, M.RESULTS.UNCHANGED);
  assert.equal(plan.writesPlanned, 0);
});

// --- 22. Counter invariants ---------------------------------------------

test('22. counter invariants hold after folding a mixed batch', () => {
  const agg = M.createEmptyApplyAggregate('cvr-dating-app');
  const plans = [
    M.planUserMigration({ uid: 'a', userRecord: verifiedRecord('a'),
      usersExists: true, usersData: { verifications: { email: true, phone: true, photo: false } },
      publicExists: true, publicData: { verifications: { email: true, phone: true, photo: false } } }),
    M.planUserMigration({ uid: 'b', userRecord: bareRecord('b'),
      usersExists: true, usersData: {}, publicExists: true, publicData: { verifications: canonicalAllFalse } }),
    M.planUserMigration({ uid: 'c', userRecord: verifiedRecord('c'),
      usersExists: false, publicExists: true, publicData: { verifications: canonicalAllFalse } }),
  ];
  for (const plan of plans) {
    M.recordCommittedPlan(agg, plan);
    agg.writesAttempted += plan.writesPlanned;
    agg.writesSucceeded += plan.writesPlanned;
  }
  assert.equal(agg.authUsersScanned, 3);
  assert.equal(agg.unchanged, 1);
  assert.equal(agg.normalizedUsersOnly, 1);
  assert.equal(agg.missingUsersDocuments, 1);
  assert.equal(agg.normalizedUsers, 1);
  assert.ok(M.classificationInvariantHolds(agg));
  assert.ok(M.countersInvariantHold(agg));
  assert.equal(agg.canonicalPhotoTrue, 0);
});

// --- 23, 24. Privacy-safe output ----------------------------------------

test('23. raw UID is never present in a plan', () => {
  const plan = M.planUserMigration({
    uid: 'RAW-SECRET-UID',
    userRecord: verifiedRecord('RAW-SECRET-UID'),
    usersExists: true,
    usersData: { verifications: canonicalAllFalse },
    publicExists: true,
    publicData: { verifications: canonicalAllFalse },
  });
  const text = JSON.stringify(plan);
  assert.equal(text.includes('RAW-SECRET-UID'), false);
  assert.match(plan.uidHash, /^[0-9a-f]{8}$/);
});

test('24. plan carries no PII (email/phone/name/photo values)', () => {
  const plan = M.planUserMigration({
    uid: 'a',
    userRecord: {
      uid: 'a',
      email: 'secret@example.test',
      emailVerified: true,
      phoneNumber: '+821099998888',
      providerData: [{ providerId: 'phone' }],
    },
    usersExists: true,
    usersData: {
      displayName: 'Alice Secret',
      photoUrls: ['https://cdn/secret.png'],
      verifications: { email: false, phone: false, photo: false },
    },
    publicExists: true,
    publicData: { verifications: { email: false, phone: false, photo: false } },
  });
  const text = JSON.stringify(plan);
  assert.equal(text.includes('secret@example.test'), false);
  assert.equal(text.includes('+821099998888'), false);
  assert.equal(text.includes('Alice Secret'), false);
  assert.equal(text.includes('secret.png'), false);
});

// --- 25, 26, 27, 28, 29. CLI guards (before Firebase init) --------------

test('25. wrong project is rejected before initialization', () => {
  assert.throws(() =>
    apply.assertApplyPreconditions({
      apply: true,
      project: 'some-other-project',
      confirmProject: 'some-other-project',
    }),
  );
  assert.equal(admin.apps.length, 0);
});

test('26. confirm-project mismatch is rejected before initialization', () => {
  assert.throws(() =>
    apply.assertApplyPreconditions({
      apply: true,
      project: 'cvr-dating-app',
      confirmProject: 'cvr-dating-app-staging',
    }),
  );
  assert.equal(admin.apps.length, 0);
});

test('27. missing --apply is rejected before initialization', () => {
  assert.throws(() =>
    apply.assertApplyPreconditions({
      apply: false,
      project: 'cvr-dating-app',
      confirmProject: 'cvr-dating-app',
    }),
  );
  // A valid all-present set passes.
  assert.doesNotThrow(() =>
    apply.assertApplyPreconditions({
      apply: true,
      project: 'cvr-dating-app',
      confirmProject: 'cvr-dating-app',
    }),
  );
  assert.equal(admin.apps.length, 0);
});

test('28. help parses without Firebase and exits cleanly', () => {
  const parsed = apply.parseArgs(['--help']);
  assert.equal(parsed.help, true);
  assert.equal(typeof apply.usage(), 'string');
  assert.equal(admin.apps.length, 0);
});

test('29. cleanup/delete/force/orphan options are rejected', () => {
  for (const flag of ['--cleanup', '--delete', '--force', '--include-orphans', '--all-firestore-users']) {
    assert.throws(() => apply.parseArgs(['--project', 'cvr-dating-app', flag]));
  }
  // A single-uid apply request parses fine.
  const parsed = apply.parseArgs([
    '--project', 'cvr-dating-app', '--confirm-project', 'cvr-dating-app', '--apply', '--uid', 'x',
  ]);
  assert.equal(parsed.uid, 'x');
  assert.equal(parsed.apply, true);
});

// --- 30. No import side effects -----------------------------------------

test('30. importing migration modules initializes no Firebase app', () => {
  assert.equal(admin.apps.length, 0);
  assert.equal(typeof M.planUserMigration, 'function');
  assert.equal(typeof apply.parseArgs, 'function');
});

// --- Static write-surface audit (defense in depth) ----------------------

test('migration files contain no forbidden write/delete API surface', () => {
  const files = [
    path.join(__dirname, '..', 'lib', 'auth_verification_badge_migration.js'),
    path.join(__dirname, '..', 'scripts', 'auth_verification_badge_apply.js'),
  ];
  const forbidden =
    /\.set\(|\.create\(|\.delete\(|\bbatch\(|bulkWriter|deleteUser|updateUser|transaction\.set|transaction\.delete/;
  for (const file of files) {
    const source = fs.readFileSync(file, 'utf8');
    assert.equal(forbidden.test(source), false, `forbidden write surface in ${file}`);
  }
});

test('only users and publicProfiles are transaction.update targets', () => {
  const source = fs.readFileSync(
    path.join(__dirname, '..', 'scripts', 'auth_verification_badge_apply.js'),
    'utf8',
  );
  const updateCalls = source.match(/transaction\.update\([^,]+/g) || [];
  // Two update call sites, one per allowed reference variable.
  assert.equal(updateCalls.length, 2);
  assert.ok(updateCalls.some((c) => c.includes('userRef')));
  assert.ok(updateCalls.some((c) => c.includes('publicRef')));
});

// --- Phase 0-D-4A audit fixtures ----------------------------------------

// The five current production Auth users, modelled from the read-only audit:
//  1: users+public both canonical valid              -> UNCHANGED
//  2: users canonical, public email false (Auth true) -> UPDATED_PUBLIC_PROFILE_ONLY
//  3: users canonical, public email false (Auth true) -> UPDATED_PUBLIC_PROFILE_ONLY
//  4: users verifications MISSING, public canonical all-false -> NORMALIZED_USERS_ONLY
//  5: users verifications MISSING, public canonical all-false -> NORMALIZED_USERS_ONLY
function productionFixture() {
  const emailVerified = (uid) => ({ uid, email: `${uid}@example.test`, emailVerified: true, providerData: [] });
  const noEvidence = (uid) => ({ uid, email: '', emailVerified: false, providerData: [] });
  return [
    {
      // User 1 is already in sync — canonical valid, all-false (no verifications).
      userRecord: noEvidence('u1'),
      usersExists: true, usersData: { verifications: { email: false, phone: false, photo: false } },
      publicExists: true, publicData: { verifications: { email: false, phone: false, photo: false } },
    },
    {
      userRecord: emailVerified('u2'),
      usersExists: true, usersData: { verifications: { email: true, phone: false, photo: false } },
      publicExists: true, publicData: { verifications: { email: false, phone: false, photo: false } },
    },
    {
      userRecord: emailVerified('u3'),
      usersExists: true, usersData: { verifications: { email: true, phone: false, photo: false } },
      publicExists: true, publicData: { verifications: { email: false, phone: false, photo: false } },
    },
    {
      userRecord: noEvidence('u4'),
      usersExists: true, usersData: {}, // verifications MISSING
      publicExists: true, publicData: { verifications: { email: false, phone: false, photo: false } },
    },
    {
      userRecord: noEvidence('u5'),
      usersExists: true, usersData: {}, // verifications MISSING
      publicExists: true, publicData: { verifications: { email: false, phone: false, photo: false } },
    },
  ];
}

// Fold a plan exactly as the apply CLI does on a committed transaction.
function foldCommitted(agg, plan) {
  M.recordCommittedPlan(agg, plan);
  agg.writesAttempted += plan.writesPlanned;
  agg.writesSucceeded += plan.writesPlanned;
}

test('AUDIT-11. first full apply matches the expected production plan', () => {
  const agg = M.createEmptyApplyAggregate('cvr-dating-app');
  for (const fx of productionFixture()) {
    foldCommitted(agg, M.planUserMigration({ uid: fx.userRecord.uid, ...fx }));
  }
  assert.equal(agg.authUsersScanned, 5);
  assert.equal(agg.unchanged, 1);
  assert.equal(agg.updatedUsersOnly, 0);
  assert.equal(agg.updatedPublicProfileOnly, 2);
  assert.equal(agg.updatedBoth, 0);
  assert.equal(agg.normalizedUsers, 2);
  assert.equal(agg.normalizedPublicProfiles, 0);
  assert.equal(agg.missingUsersDocuments, 0);
  assert.equal(agg.missingPublicProfileDocuments, 0);
  assert.equal(agg.missingBothDocuments, 0);
  assert.equal(agg.canonicalEmailTrue, 2);
  assert.equal(agg.canonicalPhoneTrue, 0);
  assert.equal(agg.canonicalPhotoTrue, 0);
  // The migration must NOT flip users.email — only public.email lags in prod.
  assert.equal(agg.usersEmailFalseToTrue, 0);
  assert.equal(agg.usersEmailTrueToFalse, 0);
  assert.equal(agg.publicEmailFalseToTrue, 2);
  assert.equal(agg.publicEmailTrueToFalse, 0);
  assert.equal(agg.usersPhoneFalseToTrue, 0);
  assert.equal(agg.usersPhotoTrueToFalse, 0);
  assert.equal(agg.publicPhoneFalseToTrue, 0);
  assert.equal(agg.publicPhotoTrueToFalse, 0);
  assert.equal(agg.writesAttempted, 4);
  assert.equal(agg.writesSucceeded, 4);
  assert.equal(agg.errors, 0);
  assert.ok(M.classificationInvariantHolds(agg));
  assert.ok(M.countersInvariantHold(agg));
});

test('AUDIT-12. second apply over the post-migration state is a full no-op', () => {
  // Apply the migration result to the fixture: public email becomes true, and
  // the two MISSING users maps become canonical all-false.
  const post = productionFixture().map((fx, index) => {
    const next = { ...fx };
    if (index === 1 || index === 2) {
      next.publicData = { verifications: { email: true, phone: false, photo: false } };
    }
    if (index === 3 || index === 4) {
      next.usersData = { verifications: { email: false, phone: false, photo: false } };
    }
    return next;
  });
  const agg = M.createEmptyApplyAggregate('cvr-dating-app');
  for (const fx of post) {
    foldCommitted(agg, M.planUserMigration({ uid: fx.userRecord.uid, ...fx }));
  }
  assert.equal(agg.authUsersScanned, 5);
  assert.equal(agg.unchanged, 5);
  assert.equal(
    agg.updatedUsersOnly + agg.updatedPublicProfileOnly + agg.updatedBoth,
    0,
  );
  assert.equal(agg.normalizedUsers, 0);
  assert.equal(agg.normalizedPublicProfiles, 0);
  assert.equal(agg.writesAttempted, 0);
  assert.equal(agg.writesSucceeded, 0);
  assert.equal(agg.errors, 0);
});

test('AUDIT-6. single --uid with no Auth account never touches Firestore', async () => {
  const notFound = Object.assign(new Error('auth/user-not-found'), { code: 'auth/user-not-found' });
  const fakeAuth = {
    getUser: async () => {
      throw notFound;
    },
  };
  let firestoreTouched = false;
  const fakeDb = {
    collection: () => {
      firestoreTouched = true;
      return { doc: () => ({}) };
    },
    runTransaction: async () => {
      firestoreTouched = true;
    },
  };
  const agg = M.createEmptyApplyAggregate('cvr-dating-app');
  await apply.processSingleUser(fakeAuth, fakeDb, 'orphan-uid-with-firestore-doc', agg);
  assert.equal(firestoreTouched, false);
  assert.equal(agg.writesAttempted, 0);
  assert.equal(agg.writesSucceeded, 0);
  assert.equal(agg.errors, 1);
  assert.equal(agg.authUsersScanned, 1);
  // Safe category recorded, never the raw error text.
  assert.ok(Object.keys(agg.errorCodeCounts).length >= 1);
});

test('AUDIT-14. transaction read failure yields no writes and a safe error', async () => {
  const db = makeFakeDb({});
  db.runTransaction = async () => {
    throw new Error('10 ABORTED: contention on the documents');
  };
  const descriptor = await apply.applyUser(null, db, verifiedRecord('authUid'));
  assert.equal(descriptor.kind, 'transactionError');
  assert.equal(descriptor.category, 'TRANSACTION_FAILED');
  const agg = M.createEmptyApplyAggregate('cvr-dating-app');
  apply.foldDescriptor(agg, descriptor);
  assert.equal(agg.writesSucceeded, 0);
  assert.equal(agg.errors, 1);
});

test('AUDIT-15. run output never leaks UID or PII', async () => {
  const sensitiveEmail = 'VERY-SECRET-EMAIL@leak.test';
  const sensitivePhone = '+82100007777';
  const sensitiveName = 'LEAKED_DISPLAY_NAME';
  const rawUid = 'RAW-LEAK-UID-9999';
  const record = {
    uid: rawUid,
    email: sensitiveEmail,
    emailVerified: true,
    phoneNumber: sensitivePhone,
    providerData: [{ providerId: 'phone' }],
  };
  const db = makeFakeDb({
    [`users/${rawUid}`]: snap(true, {
      displayName: sensitiveName,
      verifications: { email: false, phone: false, photo: false },
    }),
    [`publicProfiles/${rawUid}`]: snap(true, {
      verifications: { email: false, phone: false, photo: false },
    }),
  });
  const fakeAuth = {
    listUsers: async () => ({ users: [record], pageToken: undefined }),
  };

  const captured = [];
  const originalLog = console.log;
  const originalError = console.error;
  console.log = (...a) => captured.push(a.join(' '));
  console.error = (...a) => captured.push(a.join(' '));
  try {
    const agg = M.createEmptyApplyAggregate('cvr-dating-app');
    await apply.processAllUsers(fakeAuth, db, { pageSize: 100, limit: null }, agg);
    // The descriptor path already folds; nothing is printed per-user, but make a
    // summary-like dump to be sure no captured line carries PII.
    captured.push(JSON.stringify(agg));
  } finally {
    console.log = originalLog;
    console.error = originalError;
  }
  const output = captured.join('\n');
  assert.equal(output.includes(rawUid), false);
  assert.equal(output.includes(sensitiveEmail), false);
  assert.equal(output.includes(sensitivePhone), false);
  assert.equal(output.includes(sensitiveName), false);
});
