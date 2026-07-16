'use strict';

const crypto = require('crypto');

const CURRENT_SCHEMA_VERSION = 1;
const UNKNOWN_AGE = -1;

const OWNER_EDITABLE_KEYS = Object.freeze([
  'displayName',
  'age',
  'gender',
  'bio',
  'photoUrls',
  'height',
  'religion',
  'smoking',
  'drinking',
  'jobCategory',
  'jobTitle',
  'education',
  'mbti',
  'interests',
  'personalityTags',
  'idealTags',
  'relationshipGoal',
  'coarseLocation',
]);

const SERVER_MANAGED_KEYS = Object.freeze([
  'verifications',
  'rankingBoostUntil',
  'profileUpdatedAt',
  'schemaVersion',
]);

const BACKFILL_KEYS = Object.freeze([
  ...OWNER_EDITABLE_KEYS,
  ...SERVER_MANAGED_KEYS,
]);

const PROFILE_UPDATED_AT_KEY = 'profileUpdatedAt';
const COMPARISON_PAYLOAD_KEYS = Object.freeze(
  BACKFILL_KEYS.filter((key) => key !== PROFILE_UPDATED_AT_KEY),
);
const SENSITIVE_UNEXPECTED_KEYS = Object.freeze(new Set([
  'email',
  'phone',
  'phoneNumber',
  'birthDate',
  'birthYear',
  'location',
  'fcmToken',
  'fcmTokens',
  'fcmTokenUpdatedAt',
  'jelly',
  'jellyBalance',
  'discoveryFilter',
  'swipes',
  'blockedUsers',
  'reportedUsers',
  'purchase',
  'purchases',
  'payment',
  'payments',
  'boostUntil',
  'likesUnlocked',
  'personaVector',
  'fortuneNarrative',
  'charmReport',
  'profileInsight',
  'idealTypeImage',
  'idealTypeImageProviderPreview',
]));

class SkipDocumentError extends Error {
  constructor(reason) {
    super(reason);
    this.name = 'SkipDocumentError';
    this.reason = reason;
  }
}

function isPlainObject(value) {
  return value !== null &&
    typeof value === 'object' &&
    !Array.isArray(value) &&
    !(value instanceof Date) &&
    !isTimestampLike(value);
}

function hasOwn(object, key) {
  return Object.prototype.hasOwnProperty.call(object, key);
}

function assertPlainObject(value, reason) {
  if (!isPlainObject(value)) {
    throw new SkipDocumentError(reason);
  }
}

function stringOrDefault(data, key, fallback) {
  if (!hasOwn(data, key) || data[key] === null || data[key] === undefined) {
    return fallback;
  }
  if (typeof data[key] !== 'string') {
    throw new SkipDocumentError('invalid_field_type');
  }
  return data[key];
}

function nullableString(data, key) {
  if (!hasOwn(data, key) || data[key] === null || data[key] === undefined) {
    return null;
  }
  if (typeof data[key] !== 'string') {
    throw new SkipDocumentError('invalid_field_type');
  }
  return data[key];
}

function nullableInteger(data, key) {
  if (!hasOwn(data, key) || data[key] === null || data[key] === undefined) {
    return null;
  }
  if (typeof data[key] !== 'number' || !Number.isFinite(data[key])) {
    throw new SkipDocumentError('invalid_field_type');
  }
  return Math.trunc(data[key]);
}

function stringList(data, key) {
  if (!hasOwn(data, key) || data[key] === null || data[key] === undefined) {
    return [];
  }
  if (!Array.isArray(data[key])) {
    throw new SkipDocumentError('invalid_field_type');
  }
  return data[key].map((entry) => String(entry));
}

function isTimestampLike(value) {
  return value !== null &&
    typeof value === 'object' &&
    typeof value.toDate === 'function';
}

function timestampParts(value) {
  if (value instanceof Date) {
    return {
      millis: value.getTime(),
      nanos: (value.getTime() % 1000) * 1000000,
    };
  }
  if (isTimestampLike(value)) {
    const date = value.toDate();
    const nanos = typeof value.nanoseconds === 'number'
      ? value.nanoseconds
      : 0;
    return { millis: date.getTime(), nanos };
  }
  if (value && typeof value === 'object') {
    const seconds = typeof value.seconds === 'number'
      ? value.seconds
      : value._seconds;
    const nanos = typeof value.nanoseconds === 'number'
      ? value.nanoseconds
      : value._nanoseconds;
    if (typeof seconds === 'number' && Number.isFinite(seconds)) {
      const safeNanos = typeof nanos === 'number' && Number.isFinite(nanos)
        ? nanos
        : 0;
      return {
        millis: (seconds * 1000) + Math.floor(safeNanos / 1000000),
        nanos: safeNanos,
      };
    }
  }
  return null;
}

function parseTimestampOrDefault(data, key, fallbackDate) {
  if (!hasOwn(data, key) || data[key] === null || data[key] === undefined) {
    return new Date(fallbackDate.getTime());
  }
  const parts = timestampParts(data[key]);
  if (!parts || !Number.isFinite(parts.millis)) {
    throw new SkipDocumentError('invalid_field_type');
  }
  return new Date(parts.millis);
}

function parseLocationUpdatedAt(value) {
  const parts = timestampParts(value);
  if (parts && Number.isFinite(parts.millis)) {
    return new Date(parts.millis);
  }
  if (value !== null && value !== undefined) {
    const parsed = Date.parse(String(value));
    if (Number.isFinite(parsed)) {
      return new Date(parsed);
    }
  }
  return new Date(0);
}

function finiteNumber(value) {
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    return null;
  }
  return value;
}

function quantizeCoordinate(value) {
  return Math.round(value * 100) / 100;
}

function buildCoarseLocation(data) {
  if (!hasOwn(data, 'location') || data.location === null || data.location === undefined) {
    return null;
  }
  if (!isPlainObject(data.location)) {
    throw new SkipDocumentError('invalid_field_type');
  }
  const lat = finiteNumber(data.location.lat);
  const lng = finiteNumber(data.location.lng);
  if (lat === null || lng === null) {
    throw new SkipDocumentError('invalid_field_type');
  }
  return {
    lat: quantizeCoordinate(lat),
    lng: quantizeCoordinate(lng),
    updatedAt: parseLocationUpdatedAt(data.location.updatedAt),
  };
}

function ageAt(birthDate, referenceDate) {
  let years = referenceDate.getFullYear() - birthDate.getFullYear();
  const hadBirthday =
    referenceDate.getMonth() > birthDate.getMonth() ||
    (referenceDate.getMonth() === birthDate.getMonth() &&
      referenceDate.getDate() >= birthDate.getDate());
  if (!hadBirthday) {
    years -= 1;
  }
  return years;
}

function safeVerificationDefaults() {
  return { email: false, phone: false, photo: false };
}

function cloneSerializable(value) {
  if (value === null || value === undefined) {
    return value;
  }
  if (value instanceof Date) {
    return new Date(value.getTime());
  }
  if (Array.isArray(value)) {
    return value.map((entry) => cloneSerializable(entry));
  }
  if (typeof value === 'object') {
    const copy = {};
    for (const key of Object.keys(value)) {
      copy[key] = cloneSerializable(value[key]);
    }
    return copy;
  }
  return value;
}

function existingServerValue(existingPublicData, key, fallbackValue) {
  if (isPlainObject(existingPublicData) && hasOwn(existingPublicData, key)) {
    return cloneSerializable(existingPublicData[key]);
  }
  return fallbackValue;
}

function buildPublicProfileCandidate(userData, options = {}) {
  try {
    assertPlainObject(userData, 'unsupported_document_shape');
    if (Object.keys(userData).length === 0) {
      throw new SkipDocumentError('missing_profile_data');
    }

    const referenceDate = options.referenceDate instanceof Date
      ? options.referenceDate
      : new Date();
    const existingPublicData = options.existingPublicData;
    const birthDate = parseTimestampOrDefault(userData, 'birthDate', new Date(2000, 0, 1));
    const jobTitle = nullableString(userData, 'jobTitle') ??
      nullableString(userData, 'job');

    const payload = {
      displayName: stringOrDefault(userData, 'displayName', ''),
      age: ageAt(birthDate, referenceDate),
      gender: stringOrDefault(userData, 'gender', 'other'),
      bio: stringOrDefault(userData, 'bio', ''),
      photoUrls: stringList(userData, 'photoUrls'),
      height: nullableInteger(userData, 'height'),
      religion: nullableString(userData, 'religion'),
      smoking: nullableString(userData, 'smoking'),
      drinking: nullableString(userData, 'drinking'),
      jobCategory: nullableString(userData, 'jobCategory'),
      jobTitle,
      education: nullableString(userData, 'education'),
      mbti: nullableString(userData, 'mbti'),
      interests: stringList(userData, 'interests'),
      personalityTags: stringList(userData, 'personalityTags'),
      idealTags: stringList(userData, 'idealTags'),
      relationshipGoal: nullableString(userData, 'relationshipGoal'),
      coarseLocation: buildCoarseLocation(userData),
      verifications: existingServerValue(
        existingPublicData,
        'verifications',
        safeVerificationDefaults(),
      ),
      rankingBoostUntil: existingServerValue(
        existingPublicData,
        'rankingBoostUntil',
        null,
      ),
      schemaVersion: CURRENT_SCHEMA_VERSION,
    };

    return { ok: true, payload };
  } catch (error) {
    if (error instanceof SkipDocumentError) {
      return { ok: false, status: 'skipped', reason: error.reason };
    }
    return { ok: false, status: 'error', reason: 'UNKNOWN_RUNTIME_ERROR' };
  }
}

function normalizeFirestoreValue(value) {
  if (value === undefined) {
    return { __type: 'undefined' };
  }
  if (value === null) {
    return null;
  }
  const parts = timestampParts(value);
  if (parts) {
    return {
      __type: 'timestamp',
      millis: parts.millis,
      nanos: parts.nanos,
    };
  }
  if (Array.isArray(value)) {
    return value.map((entry) => normalizeFirestoreValue(entry));
  }
  if (typeof value === 'object') {
    const normalized = {};
    for (const key of Object.keys(value).sort()) {
      normalized[key] = normalizeFirestoreValue(value[key]);
    }
    return normalized;
  }
  if (typeof value === 'number') {
    return Object.is(value, -0) ? 0 : value;
  }
  return value;
}

function normalizedEqual(left, right) {
  return JSON.stringify(normalizeFirestoreValue(left)) ===
    JSON.stringify(normalizeFirestoreValue(right));
}

function comparePublicProfile(candidatePayload, publicData) {
  assertPlainObject(candidatePayload, 'unsupported_document_shape');
  assertPlainObject(publicData, 'unsupported_document_shape');

  const allowedKeys = new Set(BACKFILL_KEYS);
  const changedFields = [];
  for (const key of COMPARISON_PAYLOAD_KEYS) {
    if (!normalizedEqual(candidatePayload[key], publicData[key])) {
      changedFields.push(key);
    }
  }

  const unexpectedPublicFields = Object.keys(publicData)
    .filter((key) => !allowedKeys.has(key))
    .sort();
  const hasSensitiveUnexpectedPublicFields = unexpectedPublicFields.some((key) =>
    SENSITIVE_UNEXPECTED_KEYS.has(key),
  );

  return {
    changedFields,
    unexpectedPublicFields,
    hasSensitiveUnexpectedPublicFields,
  };
}

function classifyPublicProfile(input, options = {}) {
  const uid = input.uid || '';
  const publicExists = input.publicExists === true;
  const publicData = publicExists ? input.publicData : null;
  const candidate = buildPublicProfileCandidate(input.userData, {
    referenceDate: options.referenceDate,
    existingPublicData: publicData,
  });

  if (!candidate.ok) {
    return {
      uid,
      status: candidate.status,
      reason: candidate.reason,
      changedFields: [],
      unexpectedPublicFields: [],
      hasSensitiveUnexpectedPublicFields: false,
      refreshProfileUpdatedAtOnApply: false,
    };
  }

  if (!publicExists) {
    return {
      uid,
      status: 'wouldCreate',
      changedFields: [...COMPARISON_PAYLOAD_KEYS],
      unexpectedPublicFields: [],
      hasSensitiveUnexpectedPublicFields: false,
      refreshProfileUpdatedAtOnApply: true,
    };
  }

  try {
    const comparison = comparePublicProfile(candidate.payload, publicData);
    return {
      uid,
      status: comparison.changedFields.length > 0 ? 'wouldUpdate' : 'unchanged',
      changedFields: comparison.changedFields,
      unexpectedPublicFields: comparison.unexpectedPublicFields,
      hasSensitiveUnexpectedPublicFields: comparison.hasSensitiveUnexpectedPublicFields,
      refreshProfileUpdatedAtOnApply: comparison.changedFields.length > 0,
    };
  } catch (error) {
    if (error instanceof SkipDocumentError) {
      return {
        uid,
        status: 'skipped',
        reason: error.reason,
        changedFields: [],
        unexpectedPublicFields: [],
        hasSensitiveUnexpectedPublicFields: false,
        refreshProfileUpdatedAtOnApply: false,
      };
    }
    return {
      uid,
      status: 'error',
      reason: 'UNKNOWN_RUNTIME_ERROR',
      changedFields: [],
      unexpectedPublicFields: [],
      hasSensitiveUnexpectedPublicFields: false,
      refreshProfileUpdatedAtOnApply: false,
    };
  }
}

function uidHash(uid) {
  return crypto.createHash('sha256').update(String(uid)).digest('hex').slice(0, 8);
}

function toLogRecord(result) {
  const record = {
    uidHash: uidHash(result.uid),
    status: result.status,
  };
  if (result.changedFields && result.changedFields.length > 0) {
    record.changedFields = [...result.changedFields].sort();
  }
  if (result.unexpectedPublicFields && result.unexpectedPublicFields.length > 0) {
    record.unexpectedPublicFields = [...result.unexpectedPublicFields].sort();
  }
  if (result.reason) {
    record.reason = result.reason;
  }
  if (result.hasSensitiveUnexpectedPublicFields === true) {
    record.sensitiveUnexpectedPublicFields = true;
  }
  if (result.refreshProfileUpdatedAtOnApply === true) {
    record.refreshProfileUpdatedAtOnApply = true;
  }
  return record;
}

module.exports = {
  BACKFILL_KEYS,
  COMPARISON_PAYLOAD_KEYS,
  CURRENT_SCHEMA_VERSION,
  OWNER_EDITABLE_KEYS,
  PROFILE_UPDATED_AT_KEY,
  SERVER_MANAGED_KEYS,
  SENSITIVE_UNEXPECTED_KEYS,
  UNKNOWN_AGE,
  buildPublicProfileCandidate,
  classifyPublicProfile,
  comparePublicProfile,
  normalizeFirestoreValue,
  toLogRecord,
  uidHash,
};
