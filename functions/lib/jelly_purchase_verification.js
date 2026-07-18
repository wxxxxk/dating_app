'use strict';

const crypto = require('crypto');

const PURCHASE_FUNCTION_NAME = 'verifyJellyPurchase';
const USER_PURCHASE_ERROR_MESSAGE =
  '구매 정보를 확인하지 못했습니다. 잠시 후 다시 시도해 주세요.';
const ANDROID_PACKAGE_NAME = 'com.cvrlab.dating_app';
const IOS_BUNDLE_ID = 'com.cvrlab.datingApp';
const GOOGLE_PLAY_SCOPE = 'https://www.googleapis.com/auth/androidpublisher';
const PURCHASE_VERIFICATION_RATE_LIMIT = Object.freeze({
  hourlyLimit: 20,
  dailyLimit: 50,
  cooldownMs: 3 * 1000,
  hourMs: 60 * 60 * 1000,
  dayMs: 24 * 60 * 60 * 1000,
});

const JELLY_PRODUCTS = Object.freeze({
  jelly_30: Object.freeze({
    jellyAmount: 30,
    platform: 'android',
    type: 'consumable',
  }),
  jelly_100: Object.freeze({
    jellyAmount: 100,
    platform: 'android',
    type: 'consumable',
  }),
  jelly_300: Object.freeze({
    jellyAmount: 300,
    platform: 'android',
    type: 'consumable',
  }),
});

function readJellyBalance(data) {
  return typeof data?.jelly === 'number' && Number.isInteger(data.jelly)
    ? data.jelly
    : 0;
}

class PurchaseVerificationError extends Error {
  constructor(code, logMeta = {}) {
    super(code);
    this.name = 'PurchaseVerificationError';
    this.code = code;
    this.logMeta = Object.freeze({ ...logMeta });
  }
}

function toHttpsError(error, HttpsError) {
  if (error instanceof PurchaseVerificationError) {
    return new HttpsError(error.code, USER_PURCHASE_ERROR_MESSAGE);
  }
  return new HttpsError('internal', USER_PURCHASE_ERROR_MESSAGE);
}

function sha256Hex(value) {
  return crypto.createHash('sha256').update(String(value)).digest('hex');
}

function shortHash(value) {
  return sha256Hex(value).slice(0, 8);
}

function receiptHashForAndroid(purchaseToken) {
  return sha256Hex(purchaseToken);
}

function buildObfuscatedExternalAccountId(uid) {
  return sha256Hex(uid);
}

function sanitizeCount(value) {
  return typeof value === 'number' && Number.isFinite(value) && value > 0
    ? Math.floor(value)
    : 0;
}

function sanitizeTimestamp(value) {
  return typeof value === 'number' && Number.isFinite(value) && value >= 0
    ? Math.floor(value)
    : 0;
}

function normalizeUsageDoc(data, nowMs) {
  const normalized = {
    hourWindowStartMs: sanitizeTimestamp(data?.hourWindowStartMs),
    hourCount: sanitizeCount(data?.hourCount),
    dayWindowStartMs: sanitizeTimestamp(data?.dayWindowStartMs),
    dayCount: sanitizeCount(data?.dayCount),
    lastAttemptAtMs: sanitizeTimestamp(data?.lastAttemptAtMs),
  };

  if (
    normalized.hourWindowStartMs > nowMs ||
    nowMs - normalized.hourWindowStartMs >=
      PURCHASE_VERIFICATION_RATE_LIMIT.hourMs
  ) {
    normalized.hourWindowStartMs = nowMs;
    normalized.hourCount = 0;
  }
  if (
    normalized.dayWindowStartMs > nowMs ||
    nowMs - normalized.dayWindowStartMs >=
      PURCHASE_VERIFICATION_RATE_LIMIT.dayMs
  ) {
    normalized.dayWindowStartMs = nowMs;
    normalized.dayCount = 0;
  }
  if (normalized.lastAttemptAtMs > nowMs) {
    normalized.lastAttemptAtMs = 0;
  }

  return normalized;
}

function cleanString(value, maxLength = 4096) {
  return typeof value === 'string' && value.trim().length > 0 &&
    value.length <= maxLength
    ? value.trim()
    : null;
}

function logPurchaseDecision(logger, decision, meta = {}) {
  if (!logger || typeof logger.log !== 'function') return;
  logger.log({
    functionName: PURCHASE_FUNCTION_NAME,
    decision,
    ...meta,
  });
}

function fail(code, logMeta = {}) {
  throw new PurchaseVerificationError(code, logMeta);
}

function mapProviderError(error) {
  const status = Number(
    error?.code || error?.status || error?.response?.status || error?.statusCode,
  );
  if (status === 401 || status === 403) {
    return {
      code: 'failed-precondition',
      providerCategory: 'provider_auth_error',
      httpStatus: status,
      retryable: false,
    };
  }
  if (status === 429 || status >= 500) {
    return {
      code: 'unavailable',
      providerCategory: 'provider_retryable_error',
      httpStatus: status,
      retryable: true,
    };
  }
  return {
    code: 'failed-precondition',
    providerCategory: 'provider_rejected',
    httpStatus: Number.isFinite(status) ? status : undefined,
    retryable: false,
  };
}

function getCatalogProduct(productId) {
  return Object.prototype.hasOwnProperty.call(JELLY_PRODUCTS, productId)
    ? JELLY_PRODUCTS[productId]
    : null;
}

function parseRequestData(data) {
  const platform = cleanString(data?.platform, 16);
  const productId = cleanString(data?.productId, 128);
  const purchaseToken = cleanString(data?.purchaseToken, 8192);
  const transactionId = cleanString(data?.transactionId, 512);

  if (platform !== 'android' && platform !== 'ios') {
    fail('invalid-argument', {
      providerCategory: 'malformed_payload',
      retryable: false,
    });
  }
  if (!productId) {
    fail('invalid-argument', {
      platform,
      providerCategory: 'malformed_payload',
      retryable: false,
    });
  }
  const catalogProduct = getCatalogProduct(productId);
  if (!catalogProduct) {
    fail('invalid-argument', {
      platform,
      productId,
      providerCategory: 'unknown_product',
      retryable: false,
    });
  }
  if (
    data &&
    Object.prototype.hasOwnProperty.call(data, 'jellyAmount') &&
    Number(data.jellyAmount) !== catalogProduct.jellyAmount
  ) {
    fail('invalid-argument', {
      platform,
      productId,
      providerCategory: 'client_amount_mismatch',
      retryable: false,
    });
  }
  if (platform === 'ios') {
    fail('failed-precondition', {
      platform,
      productId,
      providerCategory: 'ios_not_configured',
      retryable: false,
    });
  }
  if (catalogProduct.platform !== platform) {
    fail('invalid-argument', {
      platform,
      productId,
      providerCategory: 'product_platform_mismatch',
      retryable: false,
    });
  }
  if (platform === 'android' && !purchaseToken) {
    fail('invalid-argument', {
      platform,
      productId,
      providerCategory: 'malformed_payload',
      retryable: false,
    });
  }

  return { platform, productId, purchaseToken, transactionId, catalogProduct };
}

function assertAndroidProviderResult({
  providerResult,
  productId,
  uid,
}) {
  if (!providerResult || typeof providerResult !== 'object') {
    fail('failed-precondition', {
      platform: 'android',
      productId,
      providerCategory: 'provider_malformed',
      retryable: false,
    });
  }
  if (providerResult.packageName !== ANDROID_PACKAGE_NAME) {
    fail('failed-precondition', {
      platform: 'android',
      productId,
      providerCategory: 'package_mismatch',
      retryable: false,
    });
  }
  if (providerResult.productId !== productId) {
    fail('failed-precondition', {
      platform: 'android',
      productId,
      providerCategory: 'product_mismatch',
      retryable: false,
    });
  }

  const purchaseState = Number(providerResult.purchaseState);
  if (purchaseState === 2) {
    fail('failed-precondition', {
      platform: 'android',
      productId,
      providerCategory: 'purchase_pending',
      retryable: true,
    });
  }
  if (purchaseState === 1) {
    fail('failed-precondition', {
      platform: 'android',
      productId,
      providerCategory: 'purchase_cancelled',
      retryable: false,
    });
  }
  if (purchaseState !== 0) {
    fail('failed-precondition', {
      platform: 'android',
      productId,
      providerCategory: 'purchase_not_purchased',
      retryable: false,
    });
  }

  const quantity = providerResult.quantity === undefined
    ? 1
    : Number(providerResult.quantity);
  if (!Number.isInteger(quantity) || quantity !== 1) {
    fail('failed-precondition', {
      platform: 'android',
      productId,
      providerCategory: 'quantity_not_allowed',
      retryable: false,
    });
  }

  if (providerResult.refundableQuantity !== undefined) {
    const refundableQuantity = Number(providerResult.refundableQuantity);
    if (!Number.isInteger(refundableQuantity) || refundableQuantity < 1) {
      fail('failed-precondition', {
        platform: 'android',
        productId,
        providerCategory: 'purchase_refunded',
        retryable: false,
      });
    }
  }

  const consumptionState = Number(providerResult.consumptionState);
  if (!Number.isInteger(consumptionState)) {
    fail('failed-precondition', {
      platform: 'android',
      productId,
      providerCategory: 'provider_malformed',
      retryable: false,
    });
  }
  if (consumptionState !== 0) {
    fail('failed-precondition', {
      platform: 'android',
      productId,
      providerCategory: 'purchase_already_consumed',
      retryable: false,
    });
  }

  if (
    typeof providerResult.obfuscatedExternalAccountId !== 'string' ||
    providerResult.obfuscatedExternalAccountId.length === 0
  ) {
    fail('failed-precondition', {
      platform: 'android',
      productId,
      providerCategory: 'account_binding_missing',
      retryable: false,
    });
  }

  if (
    providerResult.obfuscatedExternalAccountId !==
    buildObfuscatedExternalAccountId(uid)
  ) {
    fail('permission-denied', {
      platform: 'android',
      productId,
      providerCategory: 'account_mismatch',
      retryable: false,
    });
  }

  return {
    providerCategory: 'google_play_verified',
    purchaseTimeMillis: cleanString(providerResult.purchaseTimeMillis, 32),
    acknowledgementState: Number.isInteger(
      Number(providerResult.acknowledgementState),
    )
      ? Number(providerResult.acknowledgementState)
      : null,
    consumptionState,
    purchaseType: Number.isInteger(Number(providerResult.purchaseType))
      ? Number(providerResult.purchaseType)
      : null,
    hasOrderId: typeof providerResult.orderId === 'string' &&
      providerResult.orderId.length > 0,
  };
}

async function consumeProviderAttemptQuota({
  db,
  uid,
  nowMs,
}) {
  const usageRef = db.collection('_purchaseVerificationUsage').doc(uid);

  return db.runTransaction(async (transaction) => {
    const usageSnap = await transaction.get(usageRef);
    const usage = normalizeUsageDoc(usageSnap.data() || {}, nowMs);

    if (
      usage.lastAttemptAtMs > 0 &&
      nowMs - usage.lastAttemptAtMs <
        PURCHASE_VERIFICATION_RATE_LIMIT.cooldownMs
    ) {
      fail('resource-exhausted', {
        providerCategory: 'rate_limit_cooldown',
        retryable: true,
      });
    }
    if (usage.hourCount >= PURCHASE_VERIFICATION_RATE_LIMIT.hourlyLimit) {
      fail('resource-exhausted', {
        providerCategory: 'rate_limit_hourly',
        retryable: true,
      });
    }
    if (usage.dayCount >= PURCHASE_VERIFICATION_RATE_LIMIT.dailyLimit) {
      fail('resource-exhausted', {
        providerCategory: 'rate_limit_daily',
        retryable: true,
      });
    }

    const next = {
      hourWindowStartMs: usage.hourWindowStartMs,
      hourCount: usage.hourCount + 1,
      dayWindowStartMs: usage.dayWindowStartMs,
      dayCount: usage.dayCount + 1,
      lastAttemptAtMs: nowMs,
      updatedAtMs: nowMs,
    };
    transaction.set(usageRef, next, { merge: true });
    return next;
  });
}

function createGooglePlayPurchaseVerifier({
  googleapisModule,
  packageName = ANDROID_PACKAGE_NAME,
} = {}) {
  return async function verifyGooglePlayPurchase({ productId, purchaseToken }) {
    const { google } = googleapisModule || require('googleapis');
    const auth = await google.auth.getClient({ scopes: [GOOGLE_PLAY_SCOPE] });
    const androidpublisher = google.androidpublisher({
      version: 'v3',
      auth,
    });
    const response = await androidpublisher.purchases.products.get({
      packageName,
      productId,
      token: purchaseToken,
    });
    return {
      ...response.data,
      packageName,
    };
  };
}

async function verifyProvider({
  platform,
  productId,
  purchaseToken,
  uid,
  verifyAndroidPurchase,
}) {
  if (platform !== 'android') {
    fail('failed-precondition', {
      platform,
      productId,
      providerCategory: 'platform_not_configured',
      retryable: false,
    });
  }
  let providerResult;
  try {
    providerResult = await verifyAndroidPurchase({ productId, purchaseToken });
  } catch (error) {
    const mapped = mapProviderError(error);
    fail(mapped.code, {
      platform,
      productId,
      providerCategory: mapped.providerCategory,
      httpStatus: mapped.httpStatus,
      retryable: mapped.retryable,
    });
  }

  return assertAndroidProviderResult({ providerResult, productId, uid });
}

async function verifyJellyPurchaseCore({
  request,
  db,
  serverTimestamp,
  logger = console,
  verifyAndroidPurchase = createGooglePlayPurchaseVerifier(),
  nowMs = () => Date.now(),
}) {
  const uid = request?.auth?.uid;
  if (!uid) {
    fail('unauthenticated', {
      providerCategory: 'unauthenticated',
      retryable: false,
    });
  }

  const parsed = parseRequestData(request.data || {});
  const {
    platform,
    productId,
    purchaseToken,
    transactionId,
    catalogProduct,
  } = parsed;
  const receiptHash = platform === 'android'
    ? receiptHashForAndroid(purchaseToken)
    : sha256Hex(transactionId);
  const callerHash = shortHash(uid);
  const receiptHashPrefix = receiptHash.slice(0, 12);
  const userRef = db.collection('users').doc(uid);
  const receiptRef = db.collection('_purchaseReceipts').doc(receiptHash);
  const txRef = userRef.collection('jellyTransactions').doc(receiptHash);

  logPurchaseDecision(logger, 'verification_started', {
    callerHash,
    receiptHashPrefix,
    platform,
    productId,
    providerCategory: 'provider_request',
    retryable: false,
  });

  const existingReceiptSnap = await receiptRef.get();
  if (existingReceiptSnap.exists) {
    const receipt = existingReceiptSnap.data() || {};
    if (receipt.deletedSubjectHash) {
      logPurchaseDecision(logger, 'rejected', {
        callerHash,
        receiptHashPrefix,
        platform,
        productId,
        providerCategory: 'receipt_deleted_subject',
        retryable: false,
      });
      fail('permission-denied', {
        platform,
        productId,
        providerCategory: 'receipt_deleted_subject',
        retryable: false,
      });
    }
    if (receipt.uid !== uid) {
      logPurchaseDecision(logger, 'rejected', {
        callerHash,
        receiptHashPrefix,
        platform,
        productId,
        providerCategory: 'receipt_owner_mismatch',
        retryable: false,
      });
      fail('permission-denied', {
        platform,
        productId,
        providerCategory: 'receipt_owner_mismatch',
        retryable: false,
      });
    }
    const userSnap = await userRef.get();
    const userData = userSnap.data() || {};
    const balance = readJellyBalance(userData);
    logPurchaseDecision(logger, 'duplicate', {
      callerHash,
      receiptHashPrefix,
      platform,
      productId,
      providerCategory: receipt.providerCategory || 'already_granted',
      retryable: false,
    });
    return {
      amount: catalogProduct.jellyAmount,
      balance,
      duplicate: true,
      alreadyProcessed: true,
    };
  }

  try {
    await consumeProviderAttemptQuota({
      db,
      uid,
      nowMs: nowMs(),
    });
  } catch (error) {
    if (error instanceof PurchaseVerificationError) {
      logPurchaseDecision(logger, 'rejected', {
        callerHash,
        receiptHashPrefix,
        platform,
        productId,
        ...error.logMeta,
      });
    }
    throw error;
  }

  let verification;
  try {
    verification = await verifyProvider({
      platform,
      productId,
      purchaseToken,
      uid,
      verifyAndroidPurchase,
    });
  } catch (error) {
    if (error instanceof PurchaseVerificationError) {
      logPurchaseDecision(logger, 'rejected', {
        callerHash,
        receiptHashPrefix,
        platform,
        productId,
        ...error.logMeta,
      });
    }
    throw error;
  }

  const grantedJellyAmount = catalogProduct.jellyAmount;

  const result = await db.runTransaction(async (transaction) => {
    const [userSnap, receiptSnap] = await Promise.all([
      transaction.get(userRef),
      transaction.get(receiptRef),
    ]);
    const userData = userSnap.data() || {};
    const current = readJellyBalance(userData);

    if (receiptSnap.exists) {
      const receipt = receiptSnap.data() || {};
      if (receipt.deletedSubjectHash) {
        fail('permission-denied', {
          platform,
          productId,
          providerCategory: 'receipt_deleted_subject',
          retryable: false,
        });
      }
      if (receipt.uid === uid) {
        return {
          balance: current,
          duplicate: true,
          alreadyProcessed: true,
        };
      }
      fail('permission-denied', {
        platform,
        productId,
        providerCategory: 'receipt_owner_mismatch',
        retryable: false,
      });
    }

    const next = current + grantedJellyAmount;
    const now = serverTimestamp();
    transaction.update(userRef, { jelly: next });
    transaction.set(receiptRef, {
      uid,
      receiptHash,
      platform,
      productId,
      type: catalogProduct.type,
      grantedJellyAmount,
      providerPurchaseTimeMillis: verification.purchaseTimeMillis,
      providerCategory: verification.providerCategory,
      acknowledgementState: verification.acknowledgementState,
      consumptionState: verification.consumptionState,
      purchaseType: verification.purchaseType,
      hasOrderId: verification.hasOrderId,
      status: 'granted',
      createdAt: now,
    });
    transaction.set(txRef, {
      type: 'charge',
      amount: grantedJellyAmount,
      reason: `iap_${platform}_${productId}`,
      platform,
      productId,
      receiptHash,
      providerPurchaseTimeMillis: verification.purchaseTimeMillis,
      providerCategory: verification.providerCategory,
      createdAt: now,
    });
    return {
      balance: next,
      duplicate: false,
      alreadyProcessed: false,
    };
  });

  logPurchaseDecision(logger, result.duplicate ? 'duplicate' : 'granted', {
    callerHash,
    receiptHashPrefix,
    platform,
    productId,
    providerCategory: verification.providerCategory,
    retryable: false,
  });

  return {
    amount: grantedJellyAmount,
    balance: result.balance,
    duplicate: result.duplicate,
    alreadyProcessed: result.alreadyProcessed,
  };
}

module.exports = {
  ANDROID_PACKAGE_NAME,
  IOS_BUNDLE_ID,
  JELLY_PRODUCTS,
  PURCHASE_FUNCTION_NAME,
  PURCHASE_VERIFICATION_RATE_LIMIT,
  USER_PURCHASE_ERROR_MESSAGE,
  PurchaseVerificationError,
  buildObfuscatedExternalAccountId,
  createGooglePlayPurchaseVerifier,
  normalizeUsageDoc,
  receiptHashForAndroid,
  toHttpsError,
  verifyJellyPurchaseCore,
};
