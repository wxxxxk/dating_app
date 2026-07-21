// M4: 스와이프 생성 시 상호 like 판정 → matches 문서 자동 생성
// Cloud Functions v2 (2nd gen) — Firebase Functions SDK v6+
//
// 배포: firebase deploy --only functions
// 로그: firebase functions:log

const {
  onDocumentCreated,
  onDocumentWritten,
} = require('firebase-functions/v2/firestore');
const { setGlobalOptions } = require('firebase-functions/v2');
const { onCall, HttpsError } = require('firebase-functions/v2/https');
const { defineSecret } = require('firebase-functions/params');
const admin = require('firebase-admin');
const crypto = require('crypto');
const OpenAI = require('openai');
const {
  syncAuthVerificationBadgesCore,
} = require('./lib/auth_verification_badges');
const {
  createAiUsageGuard,
  PROFILE_INSIGHT_USAGE_POLICY,
  IDEAL_TYPE_IMAGE_USAGE_POLICY,
  MATCH_TEXT_AI_USAGE_POLICIES,
  SELF_TEXT_AI_USAGE_POLICIES,
  CHARM_REPORT_USAGE_POLICY,
  PROFILE_KEYWORD_SUMMARY_USAGE_POLICY,
} = require('./lib/ai_usage_guard');
const {
  PROFILE_KEYWORD_SUMMARY_MODEL,
  ProfileKeywordModelCallError,
  generateProfileKeywordSummaryCore,
  parseProfileKeywordModelCompletion,
} = require('./lib/profile_keyword_summary');
const {
  assertProfileInsightAccess,
  buildInsightSourceData,
  INSIGHT_USER_FIELD_MASK,
  safeUidHash,
} = require('./lib/profile_insight_access');
const {
  toHttpsError,
  verifyJellyPurchaseCore,
} = require('./lib/jelly_purchase_verification');
const {
  deleteMyAccountCore,
  toHttpsError: toAccountDeletionHttpsError,
} = require('./lib/account_deletion');
const {
  reviewAffiliationVerificationCore,
} = require('./lib/affiliation_verification_review');
const {
  contactAvoidancePairId,
  isContactAvoidancePair,
  syncAvoidContactsCore,
  syncPrivatePhoneIdentifier,
} = require('./lib/contact_avoidance');
const {
  reviewPhotoVerificationCore,
} = require('./lib/photo_verification_review');
const { tokensForRecipient } = require('./lib/push_tokens');
const {
  createLoungePostCore,
  createFeedPostCore,
  createCommunityCommentCore,
  toggleCommunityReactionCore,
  deleteCommunityPostCore,
  deleteCommunityCommentCore,
  reportCommunityContentCore,
} = require('./lib/community');
const {
  createCommunityPartyCore,
  requestPartyJoinCore,
  reviewPartyJoinRequestCore,
  withdrawPartyJoinRequestCore,
  leaveCommunityPartyCore,
  cancelCommunityPartyCore,
  reportCommunityPartyCore,
} = require('./lib/community_party');

setGlobalOptions({ region: 'asia-northeast3' });

admin.initializeApp();
const db = admin.firestore();

// generateProfileInsight 외부 AI(GPT-4o Vision) 호출 남용 방지용 서버 가드.
// rate limit + refresh cooldown + 동시 중복 생성 lease를 담당한다.
const profileInsightUsageGuard = createAiUsageGuard({
  db,
  policy: PROFILE_INSIGHT_USAGE_POLICY,
  logger: console,
});

// generateIdealTypeImage 외부 이미지 provider(fal.ai) 호출 남용 방지용 서버 가드.
// caller UID 기준 rate limit + 동시 중복 생성 lease. 이미지 생성은 오래/비싸므로
// profile insight 보다 낮은 quota(시간당 6/일일 15)와 긴 lease(180s)를 쓴다.
// generateIdealTypeImageProviderPreview(개발자 전용)에는 적용하지 않는다.
const idealTypeImageUsageGuard = createAiUsageGuard({
  db,
  policy: IDEAL_TYPE_IMAGE_USAGE_POLICY,
  logger: console,
});

const textAiUsageGuards = Object.freeze({
  generateFortuneNarrative: createAiUsageGuard({
    db,
    policy: SELF_TEXT_AI_USAGE_POLICIES.generateFortuneNarrative,
    logger: console,
  }),
  generateMatchNarrative: createAiUsageGuard({
    db,
    policy: MATCH_TEXT_AI_USAGE_POLICIES.generateMatchNarrative,
    logger: console,
  }),
  generateIcebreakers: createAiUsageGuard({
    db,
    policy: MATCH_TEXT_AI_USAGE_POLICIES.generateIcebreakers,
    logger: console,
  }),
  generateConversationTips: createAiUsageGuard({
    db,
    policy: MATCH_TEXT_AI_USAGE_POLICIES.generateConversationTips,
    logger: console,
  }),
  generateDailyFortune: createAiUsageGuard({
    db,
    policy: SELF_TEXT_AI_USAGE_POLICIES.generateDailyFortune,
    logger: console,
  }),
  generateCharmReport: createAiUsageGuard({
    db,
    policy: CHARM_REPORT_USAGE_POLICY,
    logger: console,
  }),
});

const profileKeywordSummaryUsageGuard = createAiUsageGuard({
  db,
  policy: PROFILE_KEYWORD_SUMMARY_USAGE_POLICY,
  logger: console,
});

const INVALID_FCM_TOKEN_CODES = new Set([
  'messaging/invalid-registration-token',
  'messaging/registration-token-not-registered',
]);

// M6: 사주/궁합 GPT 서사 생성에 쓰는 OpenAI API 키.
// 절대 코드에 하드코딩하지 않고 Firebase 시크릿으로만 주입한다.
// 등록: firebase functions:secrets:set OPENAI_API_KEY
const OPENAI_API_KEY = defineSecret('OPENAI_API_KEY');

// fal.ai FLUX API 키 — 기본 AI 이상형 이미지 provider(generateIdealTypeImage)와
// 개발자 preview callable(generateIdealTypeImageProviderPreview) 양쪽에서 쓴다.
// 절대 코드에 하드코딩하지 않고 Firebase 시크릿으로만 주입한다.
// 등록: firebase functions:secrets:set FAL_KEY
// 로컬 테스트는 functions/.secret.local(git-ignore 대상)에 FAL_KEY=... 로 둔다.
const FAL_KEY = defineSecret('FAL_KEY');

// Phase 3-4: 연락처 digest를 저장 가능한 값으로 바꾸는 pepper.
// 이 값이 없으면 전화번호 해시 대조 자체가 불가능하다(코드·저장소에 값 없음).
const CONTACT_AVOIDANCE_PEPPER = defineSecret('CONTACT_AVOIDANCE_PEPPER');

/**
 * users/{uid}/swipes/{targetUid} 문서가 생성/수정될 때 실행.
 *
 * 처리 흐름:
 * 1. 최신 action이 like/superlike가 아니면 즉시 종료 (pass 스와이프는 무시)
 * 2. 매칭 생성 직전 현재 swipe 문서가 아직 like/superlike인지 재확인
 * 3. 상대방(targetUid)이 현재 유저(uid)를 이미 like/superlike했는지 확인
 * 4. 상호 관심이면 matches/{matchId} 문서를 멱등적으로 생성
 *
 * matchId = [uid, targetUid].sort().join('_') — 항상 동일한 ID 보장
 */
exports.onSwipeCreated = onDocumentWritten(
  'users/{uid}/swipes/{targetUid}',
  async (event) => {
    const { uid, targetUid } = event.params;
    const data = event.data?.after?.data();
    const previous = event.data?.before?.data();

    if (!data || !isPositiveSwipe(data.action)) return null;
    // 이미 긍정 반응이었던 문서가 다시 저장된 경우에는 매칭 판정을 반복하지 않는다.
    // pass 재노출 후 like/superlike로 바뀐 업데이트는 여기서 통과해 매칭을 만든다.
    if (isPositiveSwipe(previous?.action)) return null;

    // matchId는 정렬된 순서로 — 두 유저 어느 쪽이 먼저 like해도 같은 ID
    const participants = [uid, targetUid].sort();
    const matchId = participants.join('_');
    const matchRef = db.collection('matches').doc(matchId);
    const currentSwipeRef = db
      .collection('users')
      .doc(uid)
      .collection('swipes')
      .doc(targetUid);
    const reverseSwipeRef = db
      .collection('users')
      .doc(targetUid)
      .collection('swipes')
      .doc(uid);

    // Phase 3-4: 지인 피하기로 묶인 상대와는 새 매칭을 만들지 않는다.
    // 아래 사전 검사는 불필요한 transaction을 줄이는 최적화일 뿐이고,
    // 최종 방어는 transaction 안의 pairRef read다(3-4A).
    if (await isContactAvoidancePair({ db, uidA: uid, uidB: targetUid })) {
      return null;
    }

    // pairId는 두 uid 순서와 무관하게 같은 값이다.
    const pairRef = db
      .collection('contactAvoidancePairs')
      .doc(contactAvoidancePairId(uid, targetUid));

    const created = await db.runTransaction(async (transaction) => {
      const [existing, currentSwipe, reverseSwipe, pairSnap] = await Promise.all([
        transaction.get(matchRef),
        transaction.get(currentSwipeRef),
        transaction.get(reverseSwipeRef),
        transaction.get(pairRef),
      ]);

      // 이미 매칭됐으면 다시 만들지 않는다 (멱등 처리).
      if (existing.exists) return false;

      // transaction 도중 pair가 생성되면 Firestore가 충돌로 재시도하고,
      // 재시도에서 이 검사에 걸려 매칭이 만들어지지 않는다.
      // 기존 매치는 위 멱등 분기에서 이미 그대로 유지된다.
      if (pairSnap.exists) return false;

      // Rewind가 swipe 문서를 삭제했거나 action을 바꾼 뒤라면 이벤트의
      // 과거 after 데이터만 믿고 매칭을 만들면 안 된다.
      if (
        !currentSwipe.exists ||
        !isPositiveSwipe(currentSwipe.data()?.action)
      ) {
        return false;
      }

      if (
        !reverseSwipe.exists ||
        !isPositiveSwipe(reverseSwipe.data()?.action)
      ) {
        return false;
      }

      transaction.set(matchRef, {
        participants,
        uid1: participants[0],
        uid2: participants[1],
        matchedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      return true;
    });

    if (!created) return null;

    await sendPushToUsers({
      uids: participants,
      title: '새로운 매칭!',
      body: '서로의 마음이 통했어요. 지금 대화를 시작해보세요.',
      data: {
        type: 'match',
        matchId,
      },
    });

    return null;
  },
);

/** like와 superlike는 모두 매칭을 만들 수 있는 긍정 반응이다. */
function isPositiveSwipe(action) {
  return action === 'like' || action === 'superlike';
}

function stringData(data) {
  return Object.fromEntries(
    Object.entries(data || {}).map(([key, value]) => [key, String(value)]),
  );
}

async function userTokens(uid) {
  const snap = await db.collection('users').doc(uid).get();
  const tokens = snap.data()?.fcmTokens;
  if (!Array.isArray(tokens)) return [];
  return [...new Set(tokens.filter((token) => typeof token === 'string' && token))];
}

async function removeInvalidTokens(uid, tokens) {
  if (!tokens.length) return;
  await db
    .collection('users')
    .doc(uid)
    .set(
      {
        fcmTokens: admin.firestore.FieldValue.arrayRemove(...tokens),
      },
      { merge: true },
    );
}

async function sendPushToUser({ uid, title, body, data, excludeTokens = [] }) {
  // 발신자와 겹치는 token(같은 기기 계정 전환)을 제외해 자기 알림을 막는다.
  const tokens = tokensForRecipient({
    recipientTokens: await userTokens(uid),
    senderTokens: excludeTokens,
  });
  if (!tokens.length) return;

  const response = await admin.messaging().sendEachForMulticast({
    tokens,
    notification: { title, body },
    data: stringData({ click_action: 'FLUTTER_NOTIFICATION_CLICK', ...data }),
    android: {
      priority: 'high',
      notification: {
        clickAction: 'FLUTTER_NOTIFICATION_CLICK',
        sound: 'default',
      },
    },
    apns: {
      payload: {
        aps: {
          sound: 'default',
        },
      },
    },
  });

  const invalidTokens = [];
  response.responses.forEach((item, index) => {
    const code = item.error?.code;
    if (code && INVALID_FCM_TOKEN_CODES.has(code)) {
      invalidTokens.push(tokens[index]);
    }
  });
  await removeInvalidTokens(uid, invalidTokens);
}

async function sendPushToUsers({ uids, title, body, data }) {
  await Promise.all(
    [...new Set(uids)]
      .filter(Boolean)
      .map((uid) => sendPushToUser({ uid, title, body, data })),
  );
}

exports.onMessageCreated = onDocumentCreated(
  'matches/{matchId}/messages/{messageId}',
  async (event) => {
    const { matchId } = event.params;
    const message = event.data?.data();
    const senderId = message?.senderId;
    if (typeof senderId !== 'string' || !senderId) return null;

    const matchSnap = await db.collection('matches').doc(matchId).get();
    const participants = matchSnap.data()?.participants;
    if (!Array.isArray(participants)) return null;

    const receiverUid = participants.find((uid) => uid !== senderId);
    if (!receiverUid) return null;

    const senderSnap = await db.collection('users').doc(senderId).get();
    const senderName = senderSnap.data()?.displayName || '상대방';
    // 발신자의 현재 기기 token을 수신자 대상에서 제외한다(같은 기기 계정 전환 시
    // 발신자 token이 수신자 fcmTokens에도 남아 자기 알림이 되돌아오는 문제 방지).
    const senderTokens = await userTokens(senderId);
    await sendPushToUser({
      uid: receiverUid,
      title: '새 메시지',
      body: `${senderName}님이 메시지를 보냈어요.`,
      data: {
        type: 'chat',
        matchId,
        senderUid: senderId,
      },
      excludeTokens: senderTokens,
    });
    return null;
  },
);

// ============================================================================
// M6: 사주/통합운세 — 하이브리드(규칙 계산 + GPT 서사)
//
// 별자리/사주 원소 같은 "속성"은 앱(Dart)에서 결정론적으로 계산해 전달한다.
// 이 함수들은 그 속성을 근거로 GPT가 캐릭터/서사를 "해석"하게 할 뿐,
// 점수나 궁합도 같은 수치를 새로 만들어내지 않는다 — 발표 피드백("숫자만으론
// 공감 못 한다")에 따라 서사 중심으로 설계했다.
//
// 비용/키 보안:
// - OpenAI API 키는 앱에 절대 포함하지 않는다. 이 함수(서버)만 키를 쥐고 있다.
// - 키는 Firebase 시크릿에서 주입한다: firebase functions:secrets:set OPENAI_API_KEY
// - 같은 유저/매치에 대해 이미 생성된 서사는 Firestore에 캐싱해 재호출하지 않는다.
// ============================================================================

const FORTUNE_MODEL = 'gpt-4o-mini';
const PROFILE_INSIGHT_MODEL = 'gpt-4o';

// 사주·궁합·오늘의 운세·매력 리포트 결과 문구의 버전. 문구 품질을 개선할 때
// 이 값을 올리면, 이전 버전 문구로 캐시된 결과는 캐시 미스로 처리돼 한 번
// 재생성된다. Flutter 모델은 unknown 필드를 무시하므로 화면 모델 변경은 없다.
const TEXT_CONTENT_VERSION = 2;

/** 캐시된 텍스트 결과가 현재 문구 버전으로 생성된 것인지 확인한다. */
function isCurrentTextContent(value) {
  return !!value && value.contentVersion === TEXT_CONTENT_VERSION;
}

/** 개인 사주 서사 생성용 시스템 프롬프트. */
function fortuneSystemPrompt() {
  return [
    '당신은 별자리와 사주를 실마리 삼아, 데이팅 앱 사용자가 자기 연애 스타일을',
    '"내 얘기 같다"고 느끼도록 따뜻하게 풀어주는 카피라이터입니다.',
    '',
    '반드시 지킬 규칙:',
    '1. 사용자 메시지의 "속성" JSON에 주어진 값(별자리/원소/일간/오행)만 근거로 해석한다.',
    '   주어지지 않은 정보(정확한 생년월일, 이름, 성별 등)를 추측하거나 지어내지 않는다.',
    '2. 명리학 용어를 나열하지 말고, 연애·대화·관계에서 겪는 실제 상황으로 풀어 쓴다.',
    '   존댓말로, 조사와 문법이 자연스러운 완성 문장을 쓴다.',
    '3. 점수·퍼센트·순위 등 숫자 지표나 확정적 운명 예측은 만들지 않는다.',
    '   "~한 편이에요", "~할 수 있어요"처럼 여지를 남기는 표현을 쓴다.',
    '4. 반드시 아래 JSON 스키마로만 응답한다 (다른 설명, 마크다운, 코드블록 금지):',
    '{"characterType": string, "summary": string, "reasons": [{"icon": string, "text": string}], "relationshipStory": null}',
    '- characterType: 이모지 1개 + 한글 캐릭터 이름(4~10자), 예) "🔥 열정형"',
    '- summary: 2~3문장. 이 사람이 관계에서 보이는 태도를 구체적인 장면처럼 묘사한다',
    '- reasons: 2~4개 배열. 각 항목은 이모지 1개 + 한 줄. 서로 다른 관점을 담고,',
    '  "단서가 돼요" 같은 상투적 표현을 반복하지 않는다',
    '- relationshipStory: 개인 서사이므로 항상 null 고정',
  ].join('\n');
}

/** 두 사람 궁합 서사 생성용 시스템 프롬프트. */
function matchSystemPrompt() {
  return [
    '당신은 별자리와 사주를 실마리 삼아, 데이팅 앱에서 매칭된 두 사람이 서로를',
    '이해하는 데 도움이 될 궁합 이야기를 따뜻하게 들려주는 카피라이터입니다.',
    '',
    '반드시 지킬 규칙:',
    '1. 사용자 메시지의 "속성A"·"속성B" JSON에 주어진 두 사람의 값만 근거로 해석한다.',
    '   주어지지 않은 정보(이름, 나이, 외모 등)를 추측하거나 지어내지 않는다.',
    '2. 명리학 용어를 나열하기보다, 두 사람이 대화하고 가까워지는 실제 상황으로 풀어 쓴다.',
    '   존댓말로, 조사와 문법이 자연스러운 완성 문장을 쓴다.',
    '3. 점수·퍼센트·순위·궁합도 같은 숫자 지표나 확정적 예측은 만들지 않는다.',
    '   "~할 수 있어요", "~해보면 좋아요"처럼 가능성과 조언으로 표현한다.',
    '4. 반드시 아래 JSON 스키마로만 응답한다 (다른 설명, 마크다운, 코드블록 금지):',
    '{"characterType": string, "summary": string, "reasons": [{"icon": string, "text": string}], "relationshipStory": string}',
    '- characterType: 이모지 2개(두 사람을 상징) + 한글 조합 이름, 예) "🔥🌊 열정×안정 조합"',
    '- summary: 2~3문장. 두 사람이 함께 있을 때의 분위기를 구체적으로 그려준다',
    '- reasons: 2~4개 배열. 각 항목은 이모지 1개 + 한 줄. 서로 다른 관점을 담되',
    '  "균형을 만들어요" 같은 상투적 표현을 반복하지 않는다',
    '- relationshipStory: 3~5문장. 두 사람이 가까워질 때 도움이 될 만한 관계 흐름을',
    '  실제 대화 장면처럼 서술한다(확정적 예측·점수 금지)',
  ].join('\n');
}

/** 속성 JSON이 GPT 근거로 쓰기에 충분한 형태인지 검사. */
function isValidAttrs(attrs) {
  return !!(
    attrs &&
    typeof attrs.zodiac?.sign === 'string' &&
    typeof attrs.zodiac?.element === 'string' &&
    typeof attrs.saju?.dayMaster === 'string' &&
    typeof attrs.saju?.element === 'string'
  );
}

/** GPT가 돌려준 JSON이 기대한 서사 스키마를 갖췄는지 검사. */
function isValidNarrative(n) {
  return !!(
    n &&
    typeof n.characterType === 'string' &&
    typeof n.summary === 'string' &&
    Array.isArray(n.reasons) &&
    n.reasons.every(
      (r) => r && typeof r.icon === 'string' && typeof r.text === 'string',
    )
  );
}

/**
 * GPT 응답을 서사 스키마({characterType, summary, reasons, relationshipStory})에
 * 맞게 보정한다. 필드 누락/타입 불일치가 있어도 예외를 던지는 대신 안전한
 * 기본값으로 채워서 isValidNarrative()를 최대한 통과시킨다.
 *
 * @param {unknown} raw GPT 원본 응답
 * @param {{ requireStory: boolean }} opts relationshipStory를 문자열로 채울지(궁합)
 *   항상 null로 고정할지(내 사주) 결정한다.
 */
function sanitizeNarrative(raw, { requireStory }) {
  const reasons = (Array.isArray(raw?.reasons) ? raw.reasons : [])
    .map((r) => ({
      icon: typeof r?.icon === 'string' && r.icon.trim() ? r.icon.trim() : '✨',
      text: typeof r?.text === 'string' ? r.text.trim() : '',
    }))
    .filter((r) => r.text)
    .slice(0, 4);
  if (reasons.length === 0) {
    reasons.push({ icon: '✨', text: '주어진 속성을 바탕으로 해석했어요.' });
  }

  return {
    characterType: String(raw?.characterType || '').trim() || '🌙 균형형',
    summary:
      String(raw?.summary || '').trim() ||
      '오늘의 속성을 바탕으로 캐릭터를 해석했어요.',
    reasons,
    relationshipStory: requireStory
      ? String(raw?.relationshipStory || '').trim() ||
        '두 사람의 이야기를 조금씩 채워가는 중이에요.'
      : null,
  };
}

function safeAttrText(value, fallback) {
  const text = typeof value === 'string' ? value.trim() : '';
  return text || fallback;
}

function buildFallbackFortuneNarrative(attrs) {
  const zodiacSign = safeAttrText(attrs?.zodiac?.sign, '별자리');
  const zodiacElement = safeAttrText(attrs?.zodiac?.element, '균형');
  const dayMaster = safeAttrText(attrs?.saju?.dayMaster, '중심');
  const sajuElement = safeAttrText(attrs?.saju?.element, '오행');
  return {
    characterType: `${zodiacElement} 기운의 ${sajuElement} 밸런스형`,
    summary:
      `${zodiacSign}다운 ${zodiacElement}의 분위기가 있어서, 마음이 가도 처음부터 다 보여주기보다 ` +
      '대화를 나누며 천천히 편해지는 쪽에 가까워요. 상대가 솔직하게 반응해주면 따뜻한 면도 더 자연스럽게 드러나요.',
    reasons: [
      {
        icon: '💬',
        text: `대화가 편해질수록 ${zodiacElement} 특유의 분위기가 자연스럽게 나와요.`,
      },
      {
        icon: '🧭',
        text: `${dayMaster} 일간이라 결정을 서두르기보다 나에게 맞는 방식을 찾는 편이에요.`,
      },
      {
        icon: '🌱',
        text: `${sajuElement} 기운 덕분에 감정을 몰아붙이지 않고 상대의 속도도 함께 살펴요.`,
      },
    ],
    relationshipStory: null,
  };
}

function fallbackIndex(seedParts, length) {
  const hash = stableHash(seedParts);
  const value = Number.parseInt(hash.slice(0, 8), 16);
  return value % length;
}

function buildFallbackDailyFortune({ date, attrs }) {
  const seed = {
    date,
    zodiacSign: attrs?.zodiac?.sign || '',
    zodiacElement: attrs?.zodiac?.element || '',
    dayMaster: attrs?.saju?.dayMaster || '',
    sajuElement: attrs?.saju?.element || '',
  };
  const moods = ['잔잔한 설렘', '천천히 가까워짐', '다정한 관찰', '솔직한 대화', '편안한 호감'];
  const messages = [
    '오늘은 빠르게 결론을 내리기보다 상대의 말을 한 번 더 들어보면 좋은 날이에요. 작은 반응이 대화의 온도를 부드럽게 만들어줄 수 있어요.',
    '새로운 만남보다 이미 이어진 대화에서 좋은 흐름을 찾기 쉬워요. 부담 없는 질문 하나가 자연스러운 연결점이 될 수 있어요.',
    '마음이 앞서기 쉬운 순간에도 표현을 조금 담백하게 정리하면 매력이 더 잘 전해져요. 상대의 속도에 맞추는 태도가 도움이 돼요.',
    '오늘은 평소보다 솔직한 말이 잘 닿을 수 있어요. 다만 확정적인 표현보다 여지를 남기는 문장이 더 편안하게 느껴질 거예요.',
    '작은 배려가 눈에 띄는 날이에요. 약속이나 대화에서 세심한 확인을 더하면 신뢰감이 자연스럽게 쌓일 수 있어요.',
  ];
  const advice = [
    '짧은 안부를 먼저 건네보세요.',
    '상대가 좋아하는 주제를 하나 더 물어보세요.',
    '답장을 서두르기보다 톤을 부드럽게 정리해보세요.',
    '칭찬은 구체적으로, 부담은 가볍게 표현해보세요.',
    '오늘은 듣는 시간을 조금 더 길게 가져보세요.',
  ];
  const index = fallbackIndex(seed, moods.length);
  return {
    loveScore: (fallbackIndex({ ...seed, type: 'score' }, 5) + 1),
    mood: moods[index],
    message: messages[fallbackIndex({ ...seed, type: 'message' }, messages.length)],
    advice: advice[fallbackIndex({ ...seed, type: 'advice' }, advice.length)],
  };
}

function buildFallbackMatchNarrative({ firstAttrs, secondAttrs }) {
  const firstZodiacElement = safeAttrText(firstAttrs?.zodiac?.element, '서로 다른');
  const secondZodiacElement = safeAttrText(secondAttrs?.zodiac?.element, '보완되는');
  const firstDayMaster = safeAttrText(firstAttrs?.saju?.dayMaster, '한쪽');
  const secondDayMaster = safeAttrText(secondAttrs?.saju?.dayMaster, '상대');
  const firstSajuElement = safeAttrText(firstAttrs?.saju?.element, '균형');
  const secondSajuElement = safeAttrText(secondAttrs?.saju?.element, '조화');
  const isSameElement = firstZodiacElement === secondZodiacElement;
  return {
    characterType: isSameElement
      ? `${firstZodiacElement} 결이 닮은 두 사람`
      : `${firstZodiacElement}×${secondZodiacElement} 다른 매력의 두 사람`,
    summary:
      isSameElement
        ? `두 사람은 ${firstZodiacElement}다운 결이 닮아서 처음부터 말이 잘 통한다고 느끼기 쉬워요. 익숙함에 기대기보다 서로가 어떤 표현을 좋아하는지 확인하면 편안함이 오래 이어져요.`
        : `두 사람은 표현 속도가 조금 다를 수 있어요. 한쪽이 먼저 결론을 내리기보다 서로 어떻게 마음을 표현하는지 확인하면 대화가 훨씬 편해져요.`,
    reasons: [
      {
        icon: '💬',
        text: isSameElement
          ? '비슷한 결이라 첫 대화의 온도를 맞추기 어렵지 않아요.'
          : '표현 방식이 달라서 오히려 서로에게 새로운 이야기가 많아요.',
      },
      {
        icon: '🤝',
        text: `${firstDayMaster} 일간과 ${secondDayMaster} 일간이라, 결정할 때 서로의 방식을 존중하면 부딪힘이 줄어요.`,
      },
      {
        icon: '🌗',
        text: `${firstSajuElement}와 ${secondSajuElement} 기운이 만나면 한쪽이 앞설 때 다른 쪽이 여유를 채워줄 수 있어요.`,
      },
    ],
    relationshipStory:
      '처음엔 서로의 속도를 살피는 시간이 필요할 수 있어요. 한 사람이 분위기를 열면 다른 한 사람이 이야기를 이어가며 편해지는 흐름이에요. 중요한 얘기는 서두르지 말고, 어떤 만남을 바라는지 가볍게 나눠보면 두 사람의 좋은 면이 더 자연스럽게 드러날 거예요.',
  };
}

/**
 * OpenAI Chat Completions를 JSON 모드로 호출해 서사를 받아온다.
 * 응답이 비어있거나 JSON 파싱에 실패하면 HttpsError로 던진다.
 */
async function callOpenAiForNarrative({ systemPrompt, userPayload }) {
  const client = new OpenAI({ apiKey: OPENAI_API_KEY.value() });
  const completion = await client.chat.completions.create({
    model: FORTUNE_MODEL,
    response_format: { type: 'json_object' },
    temperature: 0.8,
    messages: [
      { role: 'system', content: systemPrompt },
      { role: 'user', content: JSON.stringify(userPayload) },
    ],
  });

  const raw = completion.choices?.[0]?.message?.content;
  if (!raw) {
    throw new HttpsError('internal', 'GPT 응답이 비어 있습니다.');
  }
  try {
    return JSON.parse(raw);
  } catch {
    throw new HttpsError('internal', 'GPT 응답을 JSON으로 해석하지 못했습니다.');
  }
}

async function callOpenAiForProfileKeywordSummary({ systemPrompt, userPayload }) {
  const client = new OpenAI({ apiKey: OPENAI_API_KEY.value() });
  let completion;
  try {
    completion = await client.chat.completions.create({
      model: PROFILE_KEYWORD_SUMMARY_MODEL,
      response_format: { type: 'json_object' },
      temperature: 0.3,
      messages: [
        { role: 'system', content: systemPrompt },
        { role: 'user', content: JSON.stringify(userPayload) },
      ],
    });
  } catch (error) {
    throw new ProfileKeywordModelCallError({
      stage: 'api_request',
      cause: error,
    });
  }

  return parseProfileKeywordModelCompletion(completion);
}

const TEXT_AI_RATE_LIMIT_MESSAGE = '요청이 잠시 많습니다. 잠시 후 다시 시도해 주세요.';

function textAiInputHash(value) {
  return stableHash(value);
}

function safeMatchHash(matchId) {
  return safeUidHash(matchId);
}

function logTextAiEvent(level, fn, category, fields = {}) {
  const payload = JSON.stringify({ fn, category, ...fields });
  if (level === 'warn') console.warn(payload);
  else if (level === 'error') console.error(payload);
  else console.log(payload);
}

function isUnmatchedMatchData(matchData) {
  return Array.isArray(matchData?.unmatchedBy) && matchData.unmatchedBy.length > 0;
}

function assertActiveMatchParticipant({ fn, matchId, matchData, callerUid }) {
  const participants = Array.isArray(matchData?.participants)
    ? matchData.participants
    : [];
  if (!participants.includes(callerUid)) {
    throw new HttpsError('permission-denied', '이 매치에 접근할 권한이 없습니다.');
  }
  if (isUnmatchedMatchData(matchData)) {
    logTextAiEvent('warn', fn, 'inactive_match', {
      callerHash: safeUidHash(callerUid),
      matchHash: safeMatchHash(matchId),
      retryable: false,
    });
    throw new HttpsError('failed-precondition', '이미 종료된 매치입니다.');
  }
  return participants;
}

async function assertNoMatchBlocks({ fn, matchId, participants, callerUid }) {
  const [uidA, uidB] = participants;
  if (!uidA || !uidB) {
    throw new HttpsError('failed-precondition', '상대 참가자를 찾을 수 없습니다.');
  }
  const [aBlocksB, bBlocksA] = await Promise.all([
    db.collection('users').doc(uidA).collection('blocks').doc(uidB).get(),
    db.collection('users').doc(uidB).collection('blocks').doc(uidA).get(),
  ]);
  if (aBlocksB.exists || bBlocksA.exists) {
    logTextAiEvent('warn', fn, 'access_denied_block', {
      callerHash: safeUidHash(callerUid),
      matchHash: safeMatchHash(matchId),
      retryable: false,
    });
    throw new HttpsError('permission-denied', '이 매치에 접근할 권한이 없습니다.');
  }
}

function attrsFromBirthDate({ birthDate, participantUid, callerUid, matchId, fn }) {
  const parts = datePartsInSeoul(birthDate);
  if (!parts || !parts.year || !parts.month || !parts.day) {
    logTextAiEvent('warn', fn, 'birth_date_missing', {
      callerHash: safeUidHash(callerUid),
      matchHash: safeMatchHash(matchId),
      participantHash: safeUidHash(participantUid),
      retryable: false,
    });
    throw new HttpsError('failed-precondition', '프로필 생년월일이 필요합니다.');
  }
  return {
    zodiac: getZodiacAttrs(parts),
    saju: getSajuAttrs(parts),
  };
}

async function readMatchParticipantAttrs({ fn, matchId, participants, callerUid }) {
  const refs = participants.map((uid) => db.collection('users').doc(uid));
  const snaps = await db.getAll(...refs, { fieldMask: ['birthDate'] });
  const participantAttrs = {};
  for (let i = 0; i < participants.length; i += 1) {
    const uid = participants[i];
    const snap = snaps[i];
    if (!snap?.exists) {
      logTextAiEvent('warn', fn, 'profile_missing', {
        callerHash: safeUidHash(callerUid),
        matchHash: safeMatchHash(matchId),
        participantHash: safeUidHash(uid),
        retryable: false,
      });
      throw new HttpsError('not-found', '프로필을 찾을 수 없습니다.');
    }
    participantAttrs[uid] = attrsFromBirthDate({
      birthDate: snap.data()?.birthDate,
      participantUid: uid,
      callerUid,
      matchId,
      fn,
    });
  }
  return participantAttrs;
}

async function acquireTextAiGenerationSlot({
  fn,
  guard,
  callerUid,
  matchId = null,
  inputHash,
  isRefresh = false,
  cacheValid = false,
  cachedValue = null,
}) {
  let slot;
  try {
    slot = await guard.acquireGenerationSlot({
      callerUid,
      targetUid: matchId,
      inputHash,
      isRefresh,
      cacheValid,
    });
  } catch {
    logTextAiEvent('error', fn, 'usage_guard_failed', {
      callerHash: safeUidHash(callerUid),
      matchHash: matchId ? safeMatchHash(matchId) : null,
      retryable: true,
    });
    throw new HttpsError('internal', 'AI 요청을 처리하지 못했습니다. 잠시 후 다시 시도해 주세요.');
  }

  if (slot.outcome === 'RETURN_CACHE') {
    return { shouldGenerate: false, cachedValue };
  }
  if (slot.outcome !== 'GENERATE') {
    logTextAiEvent('warn', fn, 'usage_rejected', {
      callerHash: safeUidHash(callerUid),
      matchHash: matchId ? safeMatchHash(matchId) : null,
      decision: slot.decision,
      retryable: true,
    });
    throw new HttpsError('resource-exhausted', TEXT_AI_RATE_LIMIT_MESSAGE);
  }
  return { shouldGenerate: true };
}

async function releaseTextAiGenerationSlot({
  fn,
  guard,
  callerUid,
  matchId = null,
  inputHash,
  success,
}) {
  try {
    await guard.releaseGenerationSlot({
      callerUid,
      targetUid: matchId,
      inputHash,
      success,
    });
  } catch {
    logTextAiEvent('warn', fn, 'lease_release_failed', {
      callerHash: safeUidHash(callerUid),
      matchHash: matchId ? safeMatchHash(matchId) : null,
      retryable: false,
    });
  }
}

/**
 * 내 사주 서사 생성 (callable).
 *
 * 입력: { attrs: { zodiac: {sign, element}, saju: {dayMaster, element} } }
 * 캐싱: users/{uid}.fortuneNarrative — 이미 있으면 GPT 호출 없이 그대로 반환한다.
 */
exports.generateFortuneNarrative = onCall(
  { secrets: [OPENAI_API_KEY] },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError('unauthenticated', '로그인이 필요합니다.');
    }
    const attrs = request.data?.attrs;
    if (!isValidAttrs(attrs)) {
      throw new HttpsError('invalid-argument', '별자리/사주 속성이 올바르지 않습니다.');
    }

    const userRef = db.collection('users').doc(request.auth.uid);
    const snap = await userRef.get();
    const cached = snap.data()?.fortuneNarrative;
    if (isValidNarrative(cached) && isCurrentTextContent(cached)) {
      logTextAiEvent('info', 'generateFortuneNarrative', 'cache_hit', {
        callerHash: safeUidHash(request.auth.uid),
        retryable: false,
      });
      return cached;
    }

    const inputHash = textAiInputHash({ attrs });
    await acquireTextAiGenerationSlot({
      fn: 'generateFortuneNarrative',
      guard: textAiUsageGuards.generateFortuneNarrative,
      callerUid: request.auth.uid,
      inputHash,
      cacheValid: false,
    });
    let success = false;
    try {
      let narrative;
      let generator = 'ai';
      try {
        const rawNarrative = await callOpenAiForNarrative({
          systemPrompt: fortuneSystemPrompt(),
          userPayload: { 속성: attrs },
        });
        narrative = sanitizeNarrative(rawNarrative, { requireStory: false });
        if (!isValidNarrative(narrative)) {
          logTextAiEvent('warn', 'generateFortuneNarrative', 'invalid_response', {
            callerHash: safeUidHash(request.auth.uid),
            retryable: true,
          });
          narrative = buildFallbackFortuneNarrative(attrs);
          generator = 'fallback';
        }
      } catch {
        logTextAiEvent('warn', 'generateFortuneNarrative', 'model_failed', {
          callerHash: safeUidHash(request.auth.uid),
          retryable: true,
        });
        narrative = buildFallbackFortuneNarrative(attrs);
        generator = 'fallback';
      }

      narrative.contentVersion = TEXT_CONTENT_VERSION;
      await userRef.set({ fortuneNarrative: narrative }, { merge: true });
      success = true;
      logTextAiEvent('info', 'generateFortuneNarrative', generator === 'ai' ? 'generated_ai' : 'generated_fallback', {
        callerHash: safeUidHash(request.auth.uid),
        count: narrative.reasons.length,
        retryable: false,
      });
      return narrative;
    } finally {
      await releaseTextAiGenerationSlot({
        fn: 'generateFortuneNarrative',
        guard: textAiUsageGuards.generateFortuneNarrative,
        callerUid: request.auth.uid,
        inputHash,
        success,
      });
    }
  },
);

/**
 * 두 사람 궁합 서사 생성 (callable).
 *
 * 입력: { matchId }
 * 권한: 호출자가 해당 matchId의 active participants에 포함돼야 한다.
 * 캐싱: matches/{matchId}.fortuneMatch — 이미 있으면 GPT 호출 없이 그대로 반환한다.
 */
exports.generateMatchNarrative = onCall(
  { secrets: [OPENAI_API_KEY] },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError('unauthenticated', '로그인이 필요합니다.');
    }
    const payload = request.data || {};
    const { matchId } = payload;
    if (typeof matchId !== 'string' || !matchId.trim()) {
      throw new HttpsError('invalid-argument', '매치 ID가 올바르지 않습니다.');
    }
    const unsupportedKeys = Object.keys(payload).filter((key) => key !== 'matchId');
    if (unsupportedKeys.length > 0) {
      throw new HttpsError('invalid-argument', '지원하지 않는 요청 필드입니다.');
    }

    const matchRef = db.collection('matches').doc(matchId);
    const matchSnap = await matchRef.get();
    if (!matchSnap.exists) {
      throw new HttpsError('not-found', '매치를 찾을 수 없습니다.');
    }
    const matchData = matchSnap.data() || {};
    const participants = assertActiveMatchParticipant({
      fn: 'generateMatchNarrative',
      matchId,
      matchData,
      callerUid: request.auth.uid,
    });
    await assertNoMatchBlocks({
      fn: 'generateMatchNarrative',
      matchId,
      participants,
      callerUid: request.auth.uid,
    });

    const participantAttrs = await readMatchParticipantAttrs({
      fn: 'generateMatchNarrative',
      matchId,
      participants,
      callerUid: request.auth.uid,
    });
    const [uidA, uidB] = participants;
    const userA = participantAttrs[uidA];
    const userB = participantAttrs[uidB];

    const cached = matchData.fortuneMatch;
    if (isValidNarrative(cached) && isCurrentTextContent(cached)) {
      logTextAiEvent('info', 'generateMatchNarrative', 'cache_hit', {
        callerHash: safeUidHash(request.auth.uid),
        matchHash: safeMatchHash(matchId),
        count: cached.reasons.length,
        retryable: false,
      });
      return { narrative: cached, participantAttrs };
    }

    const inputHash = textAiInputHash({ matchId, participantAttrs });
    await acquireTextAiGenerationSlot({
      fn: 'generateMatchNarrative',
      guard: textAiUsageGuards.generateMatchNarrative,
      callerUid: request.auth.uid,
      matchId,
      inputHash,
      cacheValid: false,
    });
    let success = false;
    try {
      let narrative;
      let generator = 'ai';
      try {
        const rawNarrative = await callOpenAiForNarrative({
          systemPrompt: matchSystemPrompt(),
          userPayload: { 속성A: userA, 속성B: userB },
        });
        narrative = sanitizeNarrative(rawNarrative, { requireStory: true });
        if (!isValidNarrative(narrative) || typeof narrative.relationshipStory !== 'string') {
          logTextAiEvent('warn', 'generateMatchNarrative', 'invalid_response', {
            callerHash: safeUidHash(request.auth.uid),
            matchHash: safeMatchHash(matchId),
            retryable: true,
          });
          narrative = buildFallbackMatchNarrative({ firstAttrs: userA, secondAttrs: userB });
          generator = 'fallback';
        }
      } catch {
        logTextAiEvent('warn', 'generateMatchNarrative', 'model_failed', {
          callerHash: safeUidHash(request.auth.uid),
          matchHash: safeMatchHash(matchId),
          retryable: true,
        });
        narrative = buildFallbackMatchNarrative({ firstAttrs: userA, secondAttrs: userB });
        generator = 'fallback';
      }

      narrative.contentVersion = TEXT_CONTENT_VERSION;
      await matchRef.set({ fortuneMatch: narrative }, { merge: true });
      success = true;
      logTextAiEvent('info', 'generateMatchNarrative', generator === 'ai' ? 'generated_ai' : 'generated_fallback', {
        callerHash: safeUidHash(request.auth.uid),
        matchHash: safeMatchHash(matchId),
        count: narrative.reasons.length,
        retryable: false,
      });
      return { narrative, participantAttrs };
    } finally {
      await releaseTextAiGenerationSlot({
        fn: 'generateMatchNarrative',
        guard: textAiUsageGuards.generateMatchNarrative,
        callerUid: request.auth.uid,
        matchId,
        inputHash,
        success,
      });
    }
  },
);

// ============================================================================
// M7: 사주 기반 채팅 아이스브레이커
//
// 채팅방이 비어 있을 때만 앱에서 요청한다. 서버는 matchId만 받아 참가자 권한을
// 확인하고, users/{uid} 프로필에서 생년월일/태그를 읽어 GPT 입력을 만든다.
// 결과는 matches/{matchId}.icebreakers 배열로 캐싱해 같은 매치에서 재호출하지 않는다.
// ============================================================================

const TAG_LABELS = {
  movie: '영화',
  netflix: '넷플릭스',
  drama_binge: '드라마 정주행',
  tv_variety: 'TV 예능',
  home_cafe: '홈카페',
  chatting: '수다',
  dancing: '댄스',
  spacing_out: '멍 때리기',
  cooking: '요리',
  baking: '베이킹',
  drawing: '그림 그리기',
  plants: '반려식물',
  knitting: '뜨개질',
  music_instrument: '악기 연주',
  photography: '사진 찍기',
  webtoon: '웹툰',
  saju_tarot: '사주/타로',
  makeup: '메이크업',
  nail_art: '네일아트',
  interior: '인테리어',
  ballet: '발레',
  cleaning: '청소',
  scuba_diving: '스쿠버다이빙',
  skateboard: '스케이트보드',
  sneaker_collect: '신발 수집',
  stocks: '주식',
  bitcoin: '비트코인',
  anime: '애니메이션',
  good_looking: '깔끔하고 호감 가는 인상',
  older: '차분하고 성숙한 분위기',
  younger: '밝고 산뜻한 분위기',
  same_age: '편안한 또래 느낌',
  same_area: '친근한 동네 감성',
  near_work: '도시적인 일상 감성',
  same_hobby: '취미가 잘 맞는 분위기',
  easy_to_talk: '대화가 편한 분위기',
  petite: '아담한',
  dependable: '듬직한',
  cheerful: '잘 웃는',
  no_swearing: '욕 안하는',
  nice_voice: '목소리 좋은',
  initiates_talk: '먼저 말걸어주는',
  good_listener: '얘기를 잘 들어주는',
  stylish: '옷 잘입는',
  active: '활발한',
  quiet: '조용한',
  affectionate: '애교가 많은',
  mature: '어른스러운',
  passionate: '열정적인',
  calm: '차분한',
  quirky: '엉뚱한',
  polite: '예의 바른',
  witty: '재치있는',
  serious: '진지한',
  confident: '자신감 있는',
  humble: '허세 없는',
  whimsical: '엉뚱한',
  intellectual: '지적인',
  diligent: '성실한',
  free_spirited: '자유분방한',
  emotional: '감성적인',
  detail_oriented: '꼼꼼한',
  logical: '논리적인',
  spontaneous: '즉흥적인',
  sensitive: '섬세한',
  cool: '쿨한',
  responsible: '책임감이 강한',
  homebody: '집순이/집돌이',
  alpha: '상여자/상남자',
  loyal: '일편단심',
};

const STEM_ATTRS = [
  { dayMaster: '갑', element: '목' },
  { dayMaster: '을', element: '목' },
  { dayMaster: '병', element: '화' },
  { dayMaster: '정', element: '화' },
  { dayMaster: '무', element: '토' },
  { dayMaster: '기', element: '토' },
  { dayMaster: '경', element: '금' },
  { dayMaster: '신', element: '금' },
  { dayMaster: '임', element: '수' },
  { dayMaster: '계', element: '수' },
];

const ZODIAC_BOUNDARIES = [
  { month: 1, day: 20, sign: '물병자리', element: '공기' },
  { month: 2, day: 19, sign: '물고기자리', element: '물' },
  { month: 3, day: 21, sign: '양자리', element: '불' },
  { month: 4, day: 20, sign: '황소자리', element: '흙' },
  { month: 5, day: 21, sign: '쌍둥이자리', element: '공기' },
  { month: 6, day: 22, sign: '게자리', element: '물' },
  { month: 7, day: 23, sign: '사자자리', element: '불' },
  { month: 8, day: 23, sign: '처녀자리', element: '흙' },
  { month: 9, day: 23, sign: '천칭자리', element: '공기' },
  { month: 10, day: 23, sign: '전갈자리', element: '물' },
  { month: 11, day: 22, sign: '사수자리', element: '불' },
  { month: 12, day: 22, sign: '염소자리', element: '흙' },
];

/** 아이스브레이커 생성용 시스템 프롬프트. */
function icebreakerSystemPrompt() {
  return [
    '당신은 데이팅 앱에서 매칭된 두 사람이 첫 대화를 자연스럽게 시작하도록',
    '사주 궁합과 공통 관심사를 짧은 대화 문장으로 바꾸는 카피라이터입니다.',
    '',
    '반드시 지킬 규칙:',
    '1. 사용자 메시지의 "사용자A"와 "사용자B" JSON에 주어진 사주 속성(별자리/원소/일간/오행)과',
    '   프로필 태그(관심사/성향), 공통 관심사만 근거로 한다.',
    '2. 두 사람의 궁합과 공통 관심사를 근거로, 자연스러운 첫 대화 주제/멘트를 3개 제안한다.',
    '3. 각각 짧고 실제로 보낼 수 있는 문장으로 쓴다. 사용자가 탭해 입력창에 넣을 문장이다.',
    '4. matches 문서에 공용 캐시되므로 어느 참가자가 보내도 어색하지 않은 중립 문장으로 쓴다.',
    '5. 점수·퍼센트·순위·궁합도 같은 숫자 지표를 절대 언급하지 않는다.',
    '6. 따뜻하고 구체적으로 쓰되, 확정적 예언이나 과한 친밀감 표현은 피한다.',
    '7. 반드시 아래 JSON 스키마로만 응답한다 (다른 설명, 마크다운, 코드블록 금지):',
    '{"icebreakers": [{"topic": string, "message": string}]}',
    '- topic: 짧은 주제 라벨, 예) "여행 이야기"',
    '- message: 상대에게 실제로 보낼 수 있는 첫 메시지 한 문장',
  ].join('\n');
}

/** GPT가 돌려준 아이스브레이커 배열이 기대 스키마인지 검사. */
function isValidIcebreakerList(items) {
  return !!(
    Array.isArray(items) &&
    items.length === 3 &&
    items.every(
      (item) =>
        item &&
        typeof item.topic === 'string' &&
        item.topic.trim() &&
        typeof item.message === 'string' &&
        item.message.trim(),
    )
  );
}

/** GPT 응답에서 캐시 가능한 3개 배열만 정리한다. */
function sanitizeIcebreakers(result) {
  const items = result?.icebreakers;
  if (!Array.isArray(items)) return [];
  return items.slice(0, 3).map((item) => ({
    topic: String(item?.topic || '').trim(),
    message: String(item?.message || '').trim(),
  }));
}

/** 대화 재개 코치용 시스템 프롬프트. */
function conversationTipsSystemPrompt() {
  return [
    '당신은 데이팅 앱 채팅에서 대화가 잠시 끊겼을 때',
    '자연스럽게 다시 이어갈 수 있는 짧은 메시지를 제안하는 대화 코치입니다.',
    '',
    '반드시 지킬 규칙:',
    '1. 사용자 메시지의 최근대화, 두 사람의 사주 속성, 프로필 태그, 공통 관심사만 근거로 한다.',
    '2. 매칭 직후 첫 인사가 아니라, 이미 진행된 대화를 부드럽게 재개하는 문장을 제안한다.',
    '3. 최근 메시지를 반복하지 말고, 마지막 흐름을 살짝 이어가거나 부담 없는 새 화제로 전환한다.',
    '4. 어느 참가자가 보내도 어색하지 않은 중립적인 문장으로 쓴다.',
    '5. 각각 실제 입력창에 바로 넣을 수 있는 한 문장으로 쓴다.',
    '6. 외모 평가, 점수, 등급, 확정적 예언, 과한 친밀감 표현은 절대 쓰지 않는다.',
    '7. 반드시 아래 JSON 스키마로만 응답한다 (다른 설명, 마크다운, 코드블록 금지):',
    '{"suggestions": [string, string, string]}',
    '- suggestions: 2~3개의 짧은 대화 재개 문장',
  ].join('\n');
}

/** GPT가 돌려준 대화 코치 문장 배열이 기대 스키마인지 검사. */
function isValidConversationSuggestions(items) {
  return !!(
    Array.isArray(items) &&
    items.length >= 2 &&
    items.length <= 3 &&
    items.every((item) => typeof item === 'string' && item.trim())
  );
}

/** GPT 응답에서 캐시 가능한 대화 코치 문장 2~3개만 정리한다. */
function sanitizeConversationSuggestions(result) {
  const items = result?.suggestions;
  if (!Array.isArray(items)) return [];
  return items
    .slice(0, 3)
    .map((item) => String(item || '').trim())
    .filter(Boolean);
}

/** Firestore Timestamp를 앱 기준 날짜(Asia/Seoul)의 연/월/일로 변환한다. */
function datePartsInSeoul(timestamp) {
  if (!timestamp || typeof timestamp.toDate !== 'function') return null;
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone: 'Asia/Seoul',
    year: 'numeric',
    month: 'numeric',
    day: 'numeric',
  }).formatToParts(timestamp.toDate());
  const value = (type) => Number(parts.find((part) => part.type === type)?.value);
  return { year: value('year'), month: value('month'), day: value('day') };
}

/** Dart saju 패키지의 jdnFromDate/dayPillarFromDate와 같은 일간 계산. */
function getSajuAttrs(parts) {
  let { year, month, day } = parts;
  if (month <= 2) {
    year -= 1;
    month += 12;
  }
  const a = Math.floor(year / 100);
  const b = 2 - a + Math.floor(a / 4);
  const jd =
    Math.floor(365.25 * (year + 4716)) +
    Math.floor(30.6001 * (month + 1)) +
    day +
    b -
    1524.5;
  const jdn = Math.round(jd);
  const idx60 = (((jdn - 11) % 60) + 60) % 60;
  return STEM_ATTRS[idx60 % 10];
}

/** 생년월일의 월/일로 별자리와 4원소를 계산한다. */
function getZodiacAttrs(parts) {
  for (let i = ZODIAC_BOUNDARIES.length - 1; i >= 0; i -= 1) {
    const boundary = ZODIAC_BOUNDARIES[i];
    if (
      parts.month > boundary.month ||
      (parts.month === boundary.month && parts.day >= boundary.day)
    ) {
      return { sign: boundary.sign, element: boundary.element };
    }
  }
  return { sign: '염소자리', element: '흙' };
}

/** 프로필 태그 key를 GPT가 이해하기 쉬운 라벨로 바꾼다. */
function tagLabels(keys) {
  if (!Array.isArray(keys)) return [];
  return keys
    .map((key) => TAG_LABELS[key] || String(key))
    .filter(Boolean)
    .slice(0, 8);
}

function displayTagLabels(keys) {
  if (!Array.isArray(keys)) return [];
  return keys
    .map((key) => TAG_LABELS[key])
    .filter(Boolean)
    .slice(0, 8);
}

function parseProfileKeywordSummaryRequestData(data) {
  const payload = data === undefined || data === null ? {} : data;
  if (
    typeof payload !== 'object' ||
    Array.isArray(payload)
  ) {
    throw new HttpsError('invalid-argument', '요청 형식이 올바르지 않습니다.');
  }

  const keys = Object.keys(payload);
  if (keys.some((key) => key !== 'refresh')) {
    throw new HttpsError('invalid-argument', '지원하지 않는 요청 필드입니다.');
  }
  if (Object.prototype.hasOwnProperty.call(payload, 'refresh') &&
    typeof payload.refresh !== 'boolean') {
    throw new HttpsError('invalid-argument', 'refresh는 boolean이어야 합니다.');
  }

  return { refresh: payload.refresh === true };
}

exports.generateProfileKeywordSummary = onCall(
  { secrets: [OPENAI_API_KEY] },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError('unauthenticated', '로그인이 필요합니다.');
    }

    const { refresh } = parseProfileKeywordSummaryRequestData(request.data);
    const uid = request.auth.uid;
    return generateProfileKeywordSummaryCore({
      uid,
      refresh,
      publicProfileRef: db.collection('publicProfiles').doc(uid),
      guard: profileKeywordSummaryUsageGuard,
      callModel: callOpenAiForProfileKeywordSummary,
      tagLabels,
      timestampNow: () => admin.firestore.Timestamp.now(),
      createError: (code, message) => new HttpsError(code, message),
      logEvent: (level, category, fields = {}) =>
        logTextAiEvent(level, 'generateProfileKeywordSummary', category, {
          callerHash: safeUidHash(uid),
          ...fields,
        }),
    });
  },
);

/** users/{uid} 문서에서 GPT 입력에 필요한 공개 프로필 조각만 뽑는다. */
function icebreakerProfileFromSnap(uid, snap) {
  const data = snap.data() || {};
  const parts = datePartsInSeoul(data.birthDate);
  if (!parts || !parts.year || !parts.month || !parts.day) {
    logTextAiEvent('warn', 'textAiProfileInput', 'birth_date_missing', {
      callerHash: safeUidHash(uid),
      retryable: false,
    });
    throw new HttpsError('failed-precondition', '프로필 생년월일이 필요합니다.');
  }

  return {
    uid,
    attrs: {
      zodiac: getZodiacAttrs(parts),
      saju: getSajuAttrs(parts),
    },
    profileTags: {
      interests: tagLabels(data.interests),
      personality: tagLabels(data.personalityTags),
    },
    rawInterestKeys: Array.isArray(data.interests) ? data.interests.map(String) : [],
  };
}

/**
 * 사주 기반 채팅 아이스브레이커 생성 (callable).
 *
 * 입력: { matchId }
 * 권한: 호출자가 해당 matchId의 participants에 포함돼야 한다.
 * 캐싱: matches/{matchId}.icebreakers — 이미 있으면 GPT 호출 없이 그대로 반환한다.
 */
exports.generateIcebreakers = onCall(
  { secrets: [OPENAI_API_KEY] },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError('unauthenticated', '로그인이 필요합니다.');
    }
    const { matchId } = request.data || {};
    if (typeof matchId !== 'string' || !matchId.trim()) {
      throw new HttpsError('invalid-argument', '매치 ID가 올바르지 않습니다.');
    }
    logTextAiEvent('info', 'generateIcebreakers', 'start', {
      callerHash: safeUidHash(request.auth.uid),
      matchHash: safeMatchHash(matchId),
      retryable: false,
    });

    const matchRef = db.collection('matches').doc(matchId);
    const matchSnap = await matchRef.get();
    if (!matchSnap.exists) {
      throw new HttpsError('not-found', '매치를 찾을 수 없습니다.');
    }

    const matchData = matchSnap.data() || {};
    const participants = assertActiveMatchParticipant({
      fn: 'generateIcebreakers',
      matchId,
      matchData,
      callerUid: request.auth.uid,
    });

    const cached = matchData.icebreakers;
    if (isValidIcebreakerList(cached)) {
      logTextAiEvent('info', 'generateIcebreakers', 'cache_hit', {
        callerHash: safeUidHash(request.auth.uid),
        matchHash: safeMatchHash(matchId),
        count: cached.length,
        retryable: false,
      });
      return { icebreakers: cached };
    }
    logTextAiEvent('info', 'generateIcebreakers', 'cache_miss', {
      callerHash: safeUidHash(request.auth.uid),
      matchHash: safeMatchHash(matchId),
      retryable: true,
    });

    const [uidA, uidB] = participants;
    if (!uidA || !uidB) {
      throw new HttpsError('failed-precondition', '상대 참가자를 찾을 수 없습니다.');
    }

    const [snapA, snapB] = await Promise.all([
      db.collection('users').doc(uidA).get(),
      db.collection('users').doc(uidB).get(),
    ]);
    if (!snapA.exists || !snapB.exists) {
      logTextAiEvent('warn', 'generateIcebreakers', 'profile_missing', {
        callerHash: safeUidHash(request.auth.uid),
        matchHash: safeMatchHash(matchId),
        uidAExists: snapA.exists,
        uidBExists: snapB.exists,
        retryable: false,
      });
      throw new HttpsError('not-found', '프로필을 찾을 수 없습니다.');
    }

    const userA = icebreakerProfileFromSnap(uidA, snapA);
    const userB = icebreakerProfileFromSnap(uidB, snapB);
    const userBInterestKeys = new Set(userB.rawInterestKeys);
    const commonInterestKeys = userA.rawInterestKeys.filter((key) =>
      userBInterestKeys.has(key),
    );

    const inputHash = textAiInputHash({
      matchId,
      userA: { attrs: userA.attrs, profileTags: userA.profileTags },
      userB: { attrs: userB.attrs, profileTags: userB.profileTags },
      commonInterestKeys: commonInterestKeys.map(String).sort(),
    });
    await acquireTextAiGenerationSlot({
      fn: 'generateIcebreakers',
      guard: textAiUsageGuards.generateIcebreakers,
      callerUid: request.auth.uid,
      matchId,
      inputHash,
      cacheValid: false,
    });
    let success = false;
    try {
      const result = await callOpenAiForNarrative({
        systemPrompt: icebreakerSystemPrompt(),
        userPayload: {
          사용자A: { 속성: userA.attrs, 프로필태그: userA.profileTags },
          사용자B: { 속성: userB.attrs, 프로필태그: userB.profileTags },
          공통관심사: tagLabels(commonInterestKeys),
        },
      });

      const icebreakers = sanitizeIcebreakers(result);
      if (!isValidIcebreakerList(icebreakers)) {
        logTextAiEvent('warn', 'generateIcebreakers', 'invalid_response', {
          callerHash: safeUidHash(request.auth.uid),
          matchHash: safeMatchHash(matchId),
          count: icebreakers.length,
          retryable: true,
        });
        throw new HttpsError('internal', 'GPT 응답 형식이 올바르지 않습니다.');
      }

      await matchRef.set({ icebreakers }, { merge: true });
      success = true;
      logTextAiEvent('info', 'generateIcebreakers', 'generated', {
        callerHash: safeUidHash(request.auth.uid),
        matchHash: safeMatchHash(matchId),
        count: icebreakers.length,
        retryable: false,
      });
      return { icebreakers };
    } finally {
      await releaseTextAiGenerationSlot({
        fn: 'generateIcebreakers',
        guard: textAiUsageGuards.generateIcebreakers,
        callerUid: request.auth.uid,
        matchId,
        inputHash,
        success,
      });
    }
  },
);

/**
 * 대화 도중 끊긴 흐름을 이어갈 추천 문장 생성 (callable).
 *
 * 입력: { matchId }
 * 권한: 호출자가 해당 matchId의 participants에 포함돼야 한다.
 * 맥락: matches/{matchId}/messages 최근 8개만 읽어 토큰 비용을 제한한다.
 * 캐싱: matches/{matchId}.conversationTips.lastMessageId가 최신 메시지 ID와
 * 같으면 GPT 호출 없이 suggestions를 반환한다.
 */
exports.generateConversationTips = onCall(
  { secrets: [OPENAI_API_KEY] },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError('unauthenticated', '로그인이 필요합니다.');
    }
    const { matchId } = request.data || {};
    if (typeof matchId !== 'string' || !matchId.trim()) {
      throw new HttpsError('invalid-argument', '매치 ID가 올바르지 않습니다.');
    }
    logTextAiEvent('info', 'generateConversationTips', 'start', {
      callerHash: safeUidHash(request.auth.uid),
      matchHash: safeMatchHash(matchId),
      retryable: false,
    });

    const matchRef = db.collection('matches').doc(matchId);
    const matchSnap = await matchRef.get();
    if (!matchSnap.exists) {
      throw new HttpsError('not-found', '매치를 찾을 수 없습니다.');
    }

    const matchData = matchSnap.data() || {};
    const participants = assertActiveMatchParticipant({
      fn: 'generateConversationTips',
      matchId,
      matchData,
      callerUid: request.auth.uid,
    });

    const [uidA, uidB] = participants;
    if (!uidA || !uidB) {
      throw new HttpsError('failed-precondition', '상대 참가자를 찾을 수 없습니다.');
    }

    const messageSnap = await matchRef
      .collection('messages')
      .orderBy('createdAt', 'desc')
      .limit(8)
      .get();
    if (messageSnap.empty) {
      throw new HttpsError('failed-precondition', '대화 메시지가 필요합니다.');
    }

    const latestMessageId = messageSnap.docs[0].id;
    const cached = matchData.conversationTips;
    if (
      cached?.lastMessageId === latestMessageId &&
      isValidConversationSuggestions(cached?.suggestions)
    ) {
      logTextAiEvent('info', 'generateConversationTips', 'cache_hit', {
        callerHash: safeUidHash(request.auth.uid),
        matchHash: safeMatchHash(matchId),
        count: cached.suggestions.length,
        retryable: false,
      });
      return { suggestions: cached.suggestions };
    }
    logTextAiEvent('info', 'generateConversationTips', 'cache_miss', {
      callerHash: safeUidHash(request.auth.uid),
      matchHash: safeMatchHash(matchId),
      retryable: true,
    });

    const [snapA, snapB] = await Promise.all([
      db.collection('users').doc(uidA).get(),
      db.collection('users').doc(uidB).get(),
    ]);
    if (!snapA.exists || !snapB.exists) {
      logTextAiEvent('warn', 'generateConversationTips', 'profile_missing', {
        callerHash: safeUidHash(request.auth.uid),
        matchHash: safeMatchHash(matchId),
        uidAExists: snapA.exists,
        uidBExists: snapB.exists,
        retryable: false,
      });
      throw new HttpsError('not-found', '프로필을 찾을 수 없습니다.');
    }

    const userA = icebreakerProfileFromSnap(uidA, snapA);
    const userB = icebreakerProfileFromSnap(uidB, snapB);
    const userBInterestKeys = new Set(userB.rawInterestKeys);
    const commonInterestKeys = userA.rawInterestKeys.filter((key) =>
      userBInterestKeys.has(key),
    );
    const recentMessages = messageSnap.docs
      .slice()
      .reverse()
      .map((doc) => {
        const data = doc.data() || {};
        return {
          sender: data.senderId === uidA ? '사용자A' : '사용자B',
          text: String(data.text || '').trim().slice(0, 300),
        };
      })
      .filter((message) => message.text);

    const inputHash = textAiInputHash({
      matchId,
      latestMessageId,
      userA: { attrs: userA.attrs, profileTags: userA.profileTags },
      userB: { attrs: userB.attrs, profileTags: userB.profileTags },
      commonInterestKeys: commonInterestKeys.map(String).sort(),
      recentMessages,
    });
    await acquireTextAiGenerationSlot({
      fn: 'generateConversationTips',
      guard: textAiUsageGuards.generateConversationTips,
      callerUid: request.auth.uid,
      matchId,
      inputHash,
      cacheValid: false,
    });
    let success = false;
    try {
      const result = await callOpenAiForNarrative({
        systemPrompt: conversationTipsSystemPrompt(),
        userPayload: {
          사용자A: { 속성: userA.attrs, 프로필태그: userA.profileTags },
          사용자B: { 속성: userB.attrs, 프로필태그: userB.profileTags },
          공통관심사: tagLabels(commonInterestKeys),
          최근대화: recentMessages,
        },
      });

      const suggestions = sanitizeConversationSuggestions(result);
      if (!isValidConversationSuggestions(suggestions)) {
        logTextAiEvent('warn', 'generateConversationTips', 'invalid_response', {
          callerHash: safeUidHash(request.auth.uid),
          matchHash: safeMatchHash(matchId),
          count: suggestions.length,
          retryable: true,
        });
        throw new HttpsError('internal', 'GPT 응답 형식이 올바르지 않습니다.');
      }

      await matchRef.set(
        {
          conversationTips: {
            lastMessageId: latestMessageId,
            suggestions,
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          },
        },
        { merge: true },
      );
      success = true;
      logTextAiEvent('info', 'generateConversationTips', 'generated', {
        callerHash: safeUidHash(request.auth.uid),
        matchHash: safeMatchHash(matchId),
        count: suggestions.length,
        retryable: false,
      });
      return { suggestions };
    } finally {
      await releaseTextAiGenerationSlot({
        fn: 'generateConversationTips',
        guard: textAiUsageGuards.generateConversationTips,
        callerUid: request.auth.uid,
        matchId,
        inputHash,
        success,
      });
    }
  },
);

/** 오늘의 운세(애정 중심) 생성용 시스템 프롬프트. */
function dailyFortuneSystemPrompt() {
  return [
    '당신은 데이팅 앱에서 "오늘의 운세"를 연애·관계 중심으로 들려주는',
    '따뜻하고 공감되는 카피라이터입니다.',
    '',
    '반드시 지킬 규칙:',
    '1. 사용자 메시지의 "속성" JSON(별자리/원소/일간/오행)과 "날짜"만 근거로 삼는다.',
    '   주어지지 않은 정보를 추측하거나 지어내지 않는다.',
    '2. 점술 설명문이 아니라 오늘 하루 참고할 수 있는 짧고 구체적인 연애 조언으로 쓴다.',
    '   존댓말로, 확정적 예언 대신 공감과 응원 위주로 표현한다.',
    '   매일 비슷한 generic 문구를 반복하지 말고 그날의 결을 담는다.',
    '3. 반드시 아래 JSON 스키마로만 응답한다 (다른 설명, 마크다운, 코드블록 금지):',
    '{"loveScore": number, "mood": string, "message": string, "advice": string}',
    '- loveScore: 1~5 사이 정수. 정밀한 확률이 아니라 오늘의 애정운 분위기를',
    '  하트 개수로 보여줄 값이다. 완전히 무작위로 고르지 말고, 주어진 속성과',
    '  날짜를 바탕으로 일관되게 판단한다.',
    '  최근 며칠 히스토리 그래프에서 흐름이 보이도록 날짜의 기운이 약한 날은',
    '  2~3도 자연스럽게 사용하고, 모든 날을 4~5로만 후하게 주지 않는다.',
    '- mood: 오늘의 애정운을 한 단어~4단어로 요약한 키워드, 예) "설렘 가득"',
    '- message: 2~3문장의 애정운 서사',
    '- advice: 오늘 하루를 위한 연애 조언 한 줄',
  ].join('\n');
}

/** GPT가 돌려준 JSON이 오늘의 운세 스키마를 갖췄는지 검사. */
function isValidDailyFortune(n) {
  if (!n || typeof n.mood !== 'string' || typeof n.message !== 'string' || typeof n.advice !== 'string') {
    return false;
  }
  const score = Number(n.loveScore);
  return Number.isInteger(score) && score >= 1 && score <= 5;
}

/**
 * GPT 응답을 오늘의 운세 스키마({loveScore, mood, message, advice})에 맞게
 * 보정한다. 필드 누락/타입 불일치가 있어도 예외 대신 안전한 기본값으로 채운다.
 */
function sanitizeDailyFortune(raw) {
  const score = Number(raw?.loveScore);
  const loveScore = Number.isFinite(score)
    ? Math.min(5, Math.max(1, Math.round(score)))
    : 3;
  return {
    loveScore,
    mood: String(raw?.mood || '').trim() || '잔잔한 하루',
    message:
      String(raw?.message || '').trim() ||
      '오늘은 마음이 이끄는 대로 편안하게 흘러가 보세요.',
    advice: String(raw?.advice || '').trim() || '먼저 인사를 건네보는 건 어때요?',
  };
}

/**
 * 오늘의 운세(애정 중심) 생성 (callable).
 *
 * 입력: { date: 'yyyy-MM-dd', attrs: { zodiac: {sign, element}, saju: {dayMaster, element} } }
 * 캐싱: users/{uid}/dailyFortune/{date} — 이미 있으면 GPT 호출 없이 그대로 반환한다.
 * 날짜는 클라이언트의 로컬 "오늘"을 그대로 캐시 키로 쓴다(사용자 체감 기준).
 */
exports.generateDailyFortune = onCall(
  { secrets: [OPENAI_API_KEY] },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError('unauthenticated', '로그인이 필요합니다.');
    }
    const { date, attrs } = request.data || {};
    if (typeof date !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(date)) {
      throw new HttpsError('invalid-argument', '날짜 형식이 올바르지 않습니다 (yyyy-MM-dd).');
    }
    if (!isValidAttrs(attrs)) {
      throw new HttpsError('invalid-argument', '별자리/사주 속성이 올바르지 않습니다.');
    }

    const dailyRef = db
      .collection('users')
      .doc(request.auth.uid)
      .collection('dailyFortune')
      .doc(date);

    const snap = await dailyRef.get();
    if (isValidDailyFortune(snap.data()) && isCurrentTextContent(snap.data())) {
      logTextAiEvent('info', 'generateDailyFortune', 'cache_hit', {
        callerHash: safeUidHash(request.auth.uid),
        retryable: false,
      });
      return snap.data();
    }

    const inputHash = textAiInputHash({ date, attrs });
    await acquireTextAiGenerationSlot({
      fn: 'generateDailyFortune',
      guard: textAiUsageGuards.generateDailyFortune,
      callerUid: request.auth.uid,
      inputHash,
      cacheValid: false,
    });
    let success = false;
    try {
      let fortune;
      let generator = 'ai';
      try {
        const rawFortune = await callOpenAiForNarrative({
          systemPrompt: dailyFortuneSystemPrompt(),
          userPayload: { 날짜: date, 속성: attrs },
        });
        fortune = sanitizeDailyFortune(rawFortune);
        if (!isValidDailyFortune(fortune)) {
          logTextAiEvent('warn', 'generateDailyFortune', 'invalid_response', {
            callerHash: safeUidHash(request.auth.uid),
            retryable: true,
          });
          fortune = buildFallbackDailyFortune({ date, attrs });
          generator = 'fallback';
        }
      } catch {
        logTextAiEvent('warn', 'generateDailyFortune', 'model_failed', {
          callerHash: safeUidHash(request.auth.uid),
          retryable: true,
        });
        fortune = buildFallbackDailyFortune({ date, attrs });
        generator = 'fallback';
      }

      fortune.contentVersion = TEXT_CONTENT_VERSION;
      await dailyRef.set(fortune);
      success = true;
      logTextAiEvent('info', 'generateDailyFortune', generator === 'ai' ? 'generated_ai' : 'generated_fallback', {
        callerHash: safeUidHash(request.auth.uid),
        status: fortune.loveScore,
        retryable: false,
      });
      return fortune;
    } finally {
      await releaseTextAiGenerationSlot({
        fn: 'generateDailyFortune',
        guard: textAiUsageGuards.generateDailyFortune,
        callerUid: request.auth.uid,
        inputHash,
        success,
      });
    }
  },
);

// ============================================================================
// M8: 매력 리포트 / 첫인상
//
// 사주처럼 타고난 기운을 해석하는 기능이 아니라, 현재 프로필이 다른 사람에게
// 줄 수 있는 인상을 분석한다. 앱은 키를 갖지 않고 callable만 호출하며,
// 결과는 users/{uid}.charmReport에 캐싱한다.
// ============================================================================

/** 매력 리포트 생성용 시스템 프롬프트. */
function charmReportSystemPrompt() {
  return [
    '당신은 데이팅 앱 프로필을 보고 "다른 사람이 받는 첫인상"과',
    '"지금 프로필에서 드러나는 매력"을 따뜻하게 분석하는 카피라이터입니다.',
    '',
    '반드시 지킬 규칙:',
    '1. 사용자 메시지의 프로필 JSON에 들어있는 소개, 관심사, 성향, 상세정보만 근거로 쓴다.',
    '   외모, 소득, 직장명, 학벌 수준, 실제 인기도 등 주어지지 않은 정보를 추측하지 않는다.',
    '2. "아담한", "깔끔하고 호감 가는 인상" 같은 외모·체형 계열 표현은 성격 첫인상의',
    '   근거로 쓰지 않는다. 주어지지 않은 성격을 단정하지도 않는다.',
    '3. 점수, 순위, 확률, 외모 평가를 만들지 않는다. 존댓말로 조사와 문법이 자연스러운',
    '   완성 문장을 쓰고, generic한 표현을 반복하지 않는다.',
    '4. 개선 팁은 지적이 아니라 "조금 더 잘 드러내는 방법" 톤으로 쓴다.',
    '5. 반드시 아래 JSON 스키마로만 응답한다 (다른 설명, 마크다운, 코드블록 금지):',
    '{"firstImpression": string, "charmPoints": [{"title": string, "description": string}], "appealTip": string}',
    '- firstImpression: 첫인상 한 줄. 35자 안팎의 자연스러운 문장',
    '- charmPoints: 정확히 3개. title은 짧은 라벨, description은 1~2문장',
    '- appealTip: 프로필을 더 매력적으로 보이게 하는 한 줄 팁',
  ].join('\n');
}

/** 매력 리포트 스키마 검사. */
function isValidCharmReport(report) {
  return !!(
    report &&
    typeof report.firstImpression === 'string' &&
    typeof report.appealTip === 'string' &&
    Array.isArray(report.charmPoints) &&
    report.charmPoints.length === 3 &&
    report.charmPoints.every(
      (p) =>
        p &&
        typeof p.title === 'string' &&
        typeof p.description === 'string',
    )
  );
}

/** GPT 응답을 앱 스키마에 맞게 다듬는다. */
function sanitizeCharmReport(raw) {
  const points = Array.isArray(raw?.charmPoints) ? raw.charmPoints : [];
  return {
    firstImpression: String(raw?.firstImpression || '').trim(),
    charmPoints: points.slice(0, 3).map((point) => ({
      title: String(point?.title || '').trim(),
      description: String(point?.description || '').trim(),
    })),
    appealTip: String(raw?.appealTip || '').trim(),
  };
}

/** users/{uid}에서 매력 리포트 입력에 필요한 프로필 조각만 추린다. */
function charmProfileFromData(data) {
  return {
    한줄소개: String(data.bio || '').slice(0, 500),
    관심사: tagLabels(data.interests),
    성향: tagLabels(data.personalityTags),
    이상형키워드: tagLabels(data.idealTags),
    찾는관계: data.relationshipGoal ? tagLabels([data.relationshipGoal])[0] : null,
    상세정보: {
      키: typeof data.height === 'number' ? `${data.height}cm` : null,
      mbti: data.mbti || null,
      직업카테고리: data.jobCategory || null,
      세부직업: data.jobTitle || null,
      흡연: data.smoking || null,
      음주: data.drinking || null,
      학력: data.education || null,
    },
  };
}

// 외모·체형·이상형 선호 계열 태그 key. 이 값들은 "상대에게 바라는 조건"이거나
// 외모 묘사라서, 사용자 본인의 성격 첫인상 근거로 쓰면 "아담한이 자연스럽게…"
// 같은 어색한 문장이나 근거 없는 외모 단정이 생긴다. 매력 리포트 fallback의
// 성격 신호에서는 제외한다.
const APPEARANCE_OR_IDEAL_TAG_KEYS = new Set([
  'good_looking', 'older', 'younger', 'same_age', 'same_area', 'near_work',
  'same_hobby', 'easy_to_talk', 'petite', 'dependable', 'cheerful',
  'no_swearing', 'nice_voice', 'initiates_talk', 'good_listener', 'stylish',
]);

/** 성격 첫인상 근거로 쓸 수 있는 태그 label만 남긴다(외모/이상형 계열 제외). */
function personalitySignalLabels(keys) {
  if (!Array.isArray(keys)) return [];
  return keys
    .filter((key) => !APPEARANCE_OR_IDEAL_TAG_KEYS.has(key))
    .map((key) => TAG_LABELS[key])
    .filter(Boolean)
    .slice(0, 8);
}

function buildFallbackCharmReport(data) {
  const bio = String(data?.bio || '').trim();
  const interests = displayTagLabels(data?.interests);
  const personalityLabels = personalitySignalLabels(data?.personalityTags);
  const hasRelationshipGoal =
    typeof data?.relationshipGoal === 'string' && data.relationshipGoal.trim();
  const mbti = typeof data?.mbti === 'string' ? data.mbti.trim().toUpperCase() : '';
  const hasJobCategory = typeof data?.jobCategory === 'string' && data.jobCategory.trim();

  // 첫인상: 성격 → 관심사 → 만남 방향 → MBTI → 소개 순으로, 신호 유형에 맞는
  // 완성 문장을 고른다. raw label 뒤에 조사("이")를 일괄로 붙이지 않는다.
  let firstImpression;
  if (personalityLabels.length > 0) {
    firstImpression = `${personalityLabels[0]} 분위기가 자연스럽게 느껴지는 프로필이에요.`;
  } else if (interests.length > 0) {
    firstImpression = `${interests[0]}에 대한 관심이 은근하게 드러나는 프로필이에요.`;
  } else if (hasRelationshipGoal) {
    firstImpression = '어떤 만남을 원하는지 방향이 비교적 분명한 프로필이에요.';
  } else if (mbti) {
    firstImpression = '프로필의 몇 가지 단서가 대화를 시작하기 편하게 만들어줘요.';
  } else if (bio) {
    firstImpression = '짧은 소개 속에서도 본인의 분위기가 담백하게 전해지는 프로필이에요.';
  } else {
    firstImpression = '꾸밈보다 천천히 알아가고 싶게 만드는 인상의 프로필이에요.';
  }

  const points = [];
  if (bio) {
    points.push({
      title: '소개에서 보이는 결',
      description: '짧은 소개 속에서도 어떤 대화를 편하게 여기는지 조금씩 전해져요.',
    });
  }
  if (interests.length > 0) {
    points.push({
      title: '먼저 말 걸기 좋은 지점',
      description: `${interests.slice(0, 2).join(', ')} 이야기는 상대가 부담 없이 첫 마디를 꺼내기 좋아요.`,
    });
  }
  if (personalityLabels.length > 0) {
    points.push({
      title: '대화에서 느껴질 온도',
      description: `${personalityLabels.slice(0, 2).join(', ')} 면이 있어 상대가 대화 분위기를 미리 그려보기 쉬워요.`,
    });
  }
  if (hasRelationshipGoal) {
    points.push({
      title: '만남의 방향',
      description: '원하는 만남의 결이 드러나 있어 서로의 기대를 맞춰가기 수월해요.',
    });
  }
  if (mbti || hasJobCategory) {
    points.push({
      title: '기억에 남는 단서',
      description: '프로필 속 작은 정보들이 상대가 당신을 더 또렷하게 떠올리도록 도와줘요.',
    });
  }
  while (points.length < 3) {
    const defaults = [
      {
        title: '편안한 첫인상',
        description: '무리해서 꾸미기보다 담백하게 자신을 보여주는 쪽이라 안정감이 느껴져요.',
      },
      {
        title: '대화의 여지',
        description: '상대가 이어서 물어볼 만한 단서를 하나만 더해도 매력이 더 또렷해져요.',
      },
      {
        title: '천천히 알아가는 재미',
        description: '한 번에 다 보여주기보다 대화하며 알아가고 싶게 만드는 프로필이에요.',
      },
    ];
    points.push(defaults[points.length]);
  }

  return {
    firstImpression,
    charmPoints: points.slice(0, 3),
    appealTip: '좋아하는 것 하나에 최근의 작은 순간을 한 문장만 덧붙여 보세요.',
  };
}

/**
 * 프로필 기반 매력 리포트 생성 (callable).
 *
 * 입력: { refresh?: boolean }
 * 캐싱: users/{uid}.charmReport — refresh가 true가 아니고 캐시가 있으면 그대로 반환한다.
 */
exports.generateCharmReport = onCall(
  { secrets: [OPENAI_API_KEY] },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError('unauthenticated', '로그인이 필요합니다.');
    }

    const refresh = request.data?.refresh === true;
    const userRef = db.collection('users').doc(request.auth.uid);
    const snap = await userRef.get();
    if (!snap.exists) {
      throw new HttpsError('not-found', '프로필을 찾을 수 없습니다.');
    }

    const data = snap.data() || {};
    const cached = data.charmReport;
    if (!refresh && isValidCharmReport(cached) && isCurrentTextContent(cached)) {
      logTextAiEvent('info', 'generateCharmReport', 'cache_hit', {
        callerHash: safeUidHash(request.auth.uid),
        count: cached.charmPoints.length,
        retryable: false,
      });
      return cached;
    }

    const profile = charmProfileFromData(data);
    const cacheValid = isValidCharmReport(cached) && isCurrentTextContent(cached);
    const inputHash = textAiInputHash({ profile });
    const slot = await acquireTextAiGenerationSlot({
      fn: 'generateCharmReport',
      guard: textAiUsageGuards.generateCharmReport,
      callerUid: request.auth.uid,
      inputHash,
      isRefresh: refresh,
      cacheValid,
      cachedValue: cached,
    });
    if (!slot.shouldGenerate) {
      return slot.cachedValue;
    }

    let success = false;
    try {
      let report;
      let generator = 'ai';
      try {
        const raw = await callOpenAiForNarrative({
          systemPrompt: charmReportSystemPrompt(),
          userPayload: { 프로필: profile },
        });
        report = sanitizeCharmReport(raw);
        if (!isValidCharmReport(report)) {
          logTextAiEvent('warn', 'generateCharmReport', 'invalid_response', {
            callerHash: safeUidHash(request.auth.uid),
            count: Array.isArray(report?.charmPoints) ? report.charmPoints.length : 0,
            retryable: true,
          });
          report = buildFallbackCharmReport(data);
          generator = 'fallback';
        }
      } catch {
        logTextAiEvent('warn', 'generateCharmReport', 'model_failed', {
          callerHash: safeUidHash(request.auth.uid),
          retryable: true,
        });
        report = buildFallbackCharmReport(data);
        generator = 'fallback';
      }

      report.contentVersion = TEXT_CONTENT_VERSION;
      await userRef.set(
        {
          charmReport: report,
          charmReportUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
      success = true;
      logTextAiEvent('info', 'generateCharmReport', generator === 'ai' ? 'generated_ai' : 'generated_fallback', {
        callerHash: safeUidHash(request.auth.uid),
        count: report.charmPoints.length,
        retryable: false,
      });
      return report;
    } finally {
      await releaseTextAiGenerationSlot({
        fn: 'generateCharmReport',
        guard: textAiUsageGuards.generateCharmReport,
        callerUid: request.auth.uid,
        inputHash,
        success,
      });
    }
  },
);

// ============================================================================
// M8.5: AI Profile Insight
//
// 상대 프로필 상세 화면에서 보여줄 비외모 기반 프로필 종합 분석.
// 사진은 표정/분위기 보조 신호로만 사용하고, 외모 평가·점수·등급은 금지한다.
// 결과는 users/{targetUid}.profileInsight에 inputHash와 함께 캐싱한다.
// ============================================================================

/** AI Profile Insight 생성용 시스템 프롬프트. */
function profileInsightSystemPrompt() {
  return [
    '당신은 데이팅 앱 프로필을 보고 비외모적 첫인상과 대화 힌트를 분석하는 카피라이터입니다.',
    '사진이 제공되면 표정, 자세에서 느껴지는 분위기, 사진 맥락 정도만 참고합니다.',
    '',
    '절대 금지:',
    '1. 잘생김, 예쁨, 외모 점수, 등급, 순위, 신체 평가, 얼굴 특징 평가를 절대 쓰지 않는다.',
    '2. 매력도를 숫자화하거나 "상위 n%" 같은 표현을 만들지 않는다.',
    '3. 주어지지 않은 직업, 소득, 학벌, 성격을 단정하지 않는다.',
    '',
    '분석 기준:',
    '- 자기소개, 관심사, 성향 태그, 관계 목표, MBTI, 사주/별자리 속성을 우선 근거로 쓴다.',
    '- 사진은 외모가 아니라 표정/분위기/상황 맥락을 보조 근거로만 사용한다.',
    '- 따뜻하지만 과장하지 않고, 상대 프로필을 보는 사람이 대화 시작에 참고할 수 있게 쓴다.',
    '',
    '반드시 아래 JSON 스키마로만 응답한다 (다른 설명, 마크다운, 코드블록 금지):',
    '{"firstImpression": string, "conversationStyle": string, "atmosphere": string, "goodMatchType": string}',
    '- firstImpression: 신뢰감/편안함/활기 등 비외모적 첫인상. 1~2문장',
    '- conversationStyle: 대화가 잘 풀릴 주제나 톤. 1~2문장',
    '- atmosphere: 프로필 전체에서 느껴지는 분위기. 1~2문장',
    '- goodMatchType: 잘 맞을 법한 사람 유형. 1~2문장',
  ].join('\n');
}

function profileInsightHashInput(data) {
  const parts = datePartsInSeoul(data.birthDate);
  return {
    photoUrl: Array.isArray(data.photoUrls) && data.photoUrls[0]
      ? String(data.photoUrls[0])
      : '',
    bio: String(data.bio || '').slice(0, 500),
    interests: Array.isArray(data.interests) ? data.interests.map(String) : [],
    personalityTags: Array.isArray(data.personalityTags)
      ? data.personalityTags.map(String)
      : [],
    idealTags: Array.isArray(data.idealTags) ? data.idealTags.map(String) : [],
    relationshipGoal: data.relationshipGoal ? String(data.relationshipGoal) : '',
    mbti: data.mbti ? String(data.mbti) : '',
    birthDate: parts && parts.year && parts.month && parts.day
      ? `${parts.year.toString().padStart(4, '0')}-${parts.month
          .toString()
          .padStart(2, '0')}-${parts.day.toString().padStart(2, '0')}`
      : '',
  };
}

function profileInsightHash(data) {
  return crypto
    .createHash('sha256')
    .update(JSON.stringify(profileInsightHashInput(data)))
    .digest('hex');
}

function profileInsightInputFromData(data) {
  const parts = datePartsInSeoul(data.birthDate);
  const attrs = parts && parts.year && parts.month && parts.day
    ? {
        zodiac: getZodiacAttrs(parts),
        saju: getSajuAttrs(parts),
      }
    : null;

  return {
    대표사진있음: Array.isArray(data.photoUrls) && !!data.photoUrls[0],
    한줄소개: String(data.bio || '').slice(0, 500),
    관심사: tagLabels(data.interests),
    성향: tagLabels(data.personalityTags),
    이상형키워드: tagLabels(data.idealTags),
    찾는관계: data.relationshipGoal ? tagLabels([data.relationshipGoal])[0] : null,
    mbti: data.mbti || null,
    사주정보: attrs,
  };
}

function isValidProfileInsight(insight) {
  return !!(
    insight &&
    typeof insight.firstImpression === 'string' &&
    typeof insight.conversationStyle === 'string' &&
    typeof insight.atmosphere === 'string' &&
    typeof insight.goodMatchType === 'string'
  );
}

function sanitizeProfileInsight(raw, inputHash) {
  return {
    inputHash,
    firstImpression: String(raw?.firstImpression || '').trim(),
    conversationStyle: String(raw?.conversationStyle || '').trim(),
    atmosphere: String(raw?.atmosphere || '').trim(),
    goodMatchType: String(raw?.goodMatchType || '').trim(),
  };
}

async function callOpenAiForProfileInsight({ systemPrompt, userPayload, imageUrl }) {
  const client = new OpenAI({ apiKey: OPENAI_API_KEY.value() });
  const content = [
    {
      type: 'text',
      text: JSON.stringify(userPayload),
    },
  ];
  if (imageUrl) {
    content.push({
      type: 'image_url',
      image_url: {
        url: imageUrl,
        detail: 'low',
      },
    });
  }

  const completion = await client.chat.completions.create({
    model: PROFILE_INSIGHT_MODEL,
    response_format: { type: 'json_object' },
    temperature: 0.6,
    messages: [
      { role: 'system', content: systemPrompt },
      { role: 'user', content },
    ],
  });

  const raw = completion.choices?.[0]?.message?.content;
  if (!raw) {
    throw new HttpsError('internal', 'GPT 응답이 비어 있습니다.');
  }
  try {
    return JSON.parse(raw);
  } catch {
    throw new HttpsError('internal', 'GPT 응답을 JSON으로 해석하지 못했습니다.');
  }
}

/** 캐시된 profileInsight를 callable 응답 형태로 변환한다(외부 AI 미호출). */
function profileInsightCacheResponse(cached) {
  return {
    inputHash: cached.inputHash,
    firstImpression: cached.firstImpression,
    conversationStyle: cached.conversationStyle,
    atmosphere: cached.atmosphere,
    goodMatchType: cached.goodMatchType,
    model: cached.model || PROFILE_INSIGHT_MODEL,
    updatedAt: null,
  };
}

/**
 * profile insight 전용 sanitized 로그. 원문 error.message / OpenAI 응답 /
 * URL / uid / 이메일 / 전화 / birthDate / prompt / token / stack 은 절대 남기지
 * 않는다. 허용: 함수명, 내부 category, caller/target uidHash, decision, retryable,
 * 안전한 HTTP status(number).
 */
function logInsightEvent(level, category, fields = {}) {
  const line = { fn: 'generateProfileInsight', category, ...fields };
  const payload = JSON.stringify(line);
  if (level === 'warn') console.warn(payload);
  else if (level === 'error') console.error(payload);
  else console.log(payload);
}

/**
 * 상대 프로필 비외모 인사이트 생성 (callable).
 *
 * 입력: { targetUid: string, refresh?: boolean }
 * 캐싱: users/{targetUid}.profileInsight.inputHash가 같으면 그대로 반환한다.
 *
 * 접근 계약(Phase 0-E-2B): caller 자신 또는 caller가 participant인 활성 match의
 * 상대방만 허용한다(그 외 permission-denied). 클라이언트 matchId는 신뢰하지 않고
 * 서버가 caller/target 쌍으로 matchId를 파생해 확인한다. 양방향 block, orphan
 * (Firebase Auth 미존재)도 차단한다. 이 검증은 users private 문서를 읽기 전에
 * 끝낸다. 검증 통과 후에도 공개 필드는 publicProfiles 를 쓰고, users 에서는 사주
 * 파생용 birthDate 와 캐시 필드만 최소로 읽는다. 원문 birthDate 는 프롬프트에
 * 넣지 않는다(파생 사주값만).
 *
 * 남용 방지(Phase 0-E-2): 외부 GPT-4o Vision 호출은 caller UID 기준 rate
 * limit(시간당/일일 quota + cooldown)과 동시 중복 생성 lease를 통과할 때만
 * 이뤄진다. cache hit 은 quota를 소비하지 않는다.
 */
exports.generateProfileInsight = onCall(
  { secrets: [OPENAI_API_KEY] },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError('unauthenticated', '로그인이 필요합니다.');
    }

    const callerUid = request.auth.uid;
    const targetUid = String(request.data?.targetUid || '').trim();
    if (!targetUid) {
      throw new HttpsError('invalid-argument', '대상 유저 ID가 올바르지 않습니다.');
    }

    const refresh = request.data?.refresh === true;

    try {
      // 1) 접근 계약 — users private 문서를 읽기 전에 통과해야 한다.
      //    self 또는 활성 match 상대 + block 없음 + Auth 존재.
      await assertProfileInsightAccess({
        callerUid,
        targetUid,
        HttpsError,
        getMatchDoc: (matchId) => db.collection('matches').doc(matchId).get(),
        blockExists: async (ownerUid, blockedUid) => {
          const blockSnap = await db
            .collection('users')
            .doc(ownerUid)
            .collection('blocks')
            .doc(blockedUid)
            .get();
          return blockSnap.exists;
        },
        // self 는 정의상 Auth 에 존재하므로 orphan 조회를 생략한다.
        getAuthUser:
          callerUid === targetUid
            ? async () => ({ uid: targetUid })
            : (uid) => admin.auth().getUser(uid),
        logger: console,
      });

      // 2) 검증 통과 후에만 데이터 읽기. 공개 필드는 publicProfiles,
      //    users 는 fieldMask(birthDate + profileInsight 캐시)로 최소 읽기.
      const userRef = db.collection('users').doc(targetUid);
      const [publicSnap, userMaskedSnap] = await Promise.all([
        db.collection('publicProfiles').doc(targetUid).get(),
        db.getAll(userRef, { fieldMask: INSIGHT_USER_FIELD_MASK }).then((docs) => docs[0]),
      ]);

      const publicData = publicSnap.exists ? publicSnap.data() || {} : {};
      const userMasked = userMaskedSnap && userMaskedSnap.exists
        ? userMaskedSnap.data() || {}
        : {};
      const cached = userMasked.profileInsight;

      // 공개 필드(publicProfiles) + birthDate(users 최소) 로 AI 입력 소스 조립.
      // 필드/타입이 기존 users 기반과 동일해 프롬프트/해시가 기존과 같다.
      const sourceData = buildInsightSourceData({
        publicData,
        birthDate: userMasked.birthDate,
      });

      const inputHash = profileInsightHash(sourceData);
      const cacheValid = !!(
        cached &&
        cached.inputHash === inputHash &&
        isValidProfileInsight(cached)
      );

      // 유효 캐시 + refresh 아님 → 외부 AI/quota 소비 없이 즉시 캐시 반환.
      if (cacheValid && !refresh) {
        return profileInsightCacheResponse(cached);
      }

      const profile = profileInsightInputFromData(sourceData);
      const hasProfileSignal =
        !!profile.대표사진있음 ||
        !!profile.한줄소개 ||
        profile.관심사.length > 0 ||
        profile.성향.length > 0 ||
        !!profile.mbti;
      if (!hasProfileSignal) {
        throw new HttpsError(
          'failed-precondition',
          '프로필 인사이트 생성을 위해 소개나 태그를 먼저 채워주세요.',
        );
      }

      // 외부 AI 호출 직전 서버측 원자적 슬롯 확보(rate limit + refresh cooldown +
      // 동시 중복 생성 lease). guard 자체 오류는 유효 캐시로 폴백한다.
      let slot;
      try {
        slot = await profileInsightUsageGuard.acquireGenerationSlot({
          callerUid,
          targetUid,
          inputHash,
          isRefresh: refresh,
          cacheValid,
        });
      } catch (error) {
        logInsightEvent('error', 'usage_guard_failed', {
          callerHash: safeUidHash(callerUid),
          targetHash: safeUidHash(targetUid),
          retryable: true,
        });
        if (cacheValid) return profileInsightCacheResponse(cached);
        throw new HttpsError('internal', '프로필 인사이트 생성에 실패했습니다.');
      }

      if (slot.outcome !== 'GENERATE') {
        // RETURN_CACHE(refresh cooldown/진행 중) 또는 REJECT(quota/cooldown 초과).
        if (cacheValid) return profileInsightCacheResponse(cached);
        throw new HttpsError(
          'resource-exhausted',
          '요청이 잠시 많습니다. 잠시 후 다시 시도해 주세요.',
        );
      }

      // 슬롯 확보됨 — 이 attempt는 성공/실패와 무관하게 이미 quota에 반영되었다.
      const imageUrl = Array.isArray(sourceData.photoUrls) && sourceData.photoUrls[0]
        ? String(sourceData.photoUrls[0])
        : null;
      let generationSucceeded = false;
      try {
        let raw;
        try {
          raw = await callOpenAiForProfileInsight({
            systemPrompt: profileInsightSystemPrompt(),
            userPayload: { 프로필: profile },
            imageUrl,
          });
        } catch (error) {
          // 외부 API 원문 message/응답은 남기지 않는다. status(number)만 안전 로그.
          logInsightEvent('warn', 'openai_call_failed', {
            callerHash: safeUidHash(callerUid),
            targetHash: safeUidHash(targetUid),
            status: typeof error?.status === 'number' ? error.status : null,
            retryable: true,
          });
          if (error instanceof HttpsError) throw error;
          throw new HttpsError(
            'internal',
            '프로필 인사이트 생성에 실패했습니다.',
          );
        }

        const insight = sanitizeProfileInsight(raw, inputHash);
        if (!isValidProfileInsight(insight)) {
          throw new HttpsError('internal', 'GPT 응답 형식이 올바르지 않습니다.');
        }

        const result = {
          ...insight,
          model: PROFILE_INSIGHT_MODEL,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        };
        await userRef.set({ profileInsight: result }, { merge: true });
        generationSucceeded = true;
        return {
          ...insight,
          model: PROFILE_INSIGHT_MODEL,
          updatedAt: null,
        };
      } finally {
        // lease 해제(성공 시 lastGeneratedAt 기록 → refresh cooldown 시작).
        try {
          await profileInsightUsageGuard.releaseGenerationSlot({
            callerUid,
            targetUid,
            inputHash,
            success: generationSucceeded,
          });
        } catch (releaseError) {
          logInsightEvent('warn', 'lease_release_failed', {
            callerHash: safeUidHash(callerUid),
            targetHash: safeUidHash(targetUid),
            retryable: false,
          });
        }
      }
    } catch (error) {
      // 예상된 HttpsError 는 이미 안전한 문구/카테고리 → 그대로 전달.
      if (error instanceof HttpsError) throw error;
      // 알 수 없는 오류는 고정된 internal category 만 기록(원문/스택 미노출).
      logInsightEvent('error', 'internal_unexpected', {
        callerHash: safeUidHash(callerUid),
        targetHash: safeUidHash(targetUid),
        retryable: true,
      });
      throw new HttpsError('internal', '프로필 인사이트 생성에 실패했습니다.');
    }
  },
);

// ============================================================================
// M9: AI 이상형 이미지 생성
//
// 사용자의 이상형 태그와 선택 옵션을 바탕으로 "가상의 인물" 초상 이미지를 만든다.
// 실존 인물/앱 사용자처럼 오해되지 않게 서버 프롬프트와 앱 UI 양쪽에서
// fictional person, not a real individual, 실제 앱 사용자가 아님을 명시한다.
// ============================================================================

// 성별 무관(neutral) 키는 그대로 둔다 — gender: 'all'일 때 그대로 쓰이므로
// 하나도 지우거나 이름을 바꾸지 않는다(기존 캐시/앱 버전과의 호환성).
// 성별별 taxonomy(IDEAL_MOOD/STYLE/IMPRESSION/HAIR_BY_GENDER, 클라이언트
// IdealTypeOptionSets와 대응)에서 쓰는 새 키들은 여기 추가만 한다 — 서버는
// gender와 mood/style/impression 키를 서로 검증하지 않는다(기존부터 그랬음,
// 하위 호환을 위해 이번에도 유지). 어떤 키가 들어와도 이 맵에 있으면 그대로
// 인정한다.
const IDEAL_IMAGE_OPTIONS = {
  mood: {
    pure: { ko: '청순한', en: 'soft and innocent mood' },
    chic: { ko: '시크한', en: 'chic and composed mood' },
    playful: { ko: '발랄한', en: 'bright and playful mood' },
    intellectual: { ko: '지적인', en: 'intellectual and thoughtful mood' },
    gentle: { ko: '부드러운', en: 'gentle and warm mood' },
    // 여성 전용 taxonomy
    refined: { ko: '세련된', en: 'polished and refined mood' },
    lovely: { ko: '러블리한', en: 'lovely and sweet mood' },
    calm: { ko: '차분한', en: 'calm and composed mood' },
    luxury: { ko: '고급스러운', en: 'elegant and luxurious mood' },
    mysterious: { ko: '신비로운', en: 'mysterious and alluring mood' },
    // 남성 전용 taxonomy
    dandy_mood: { ko: '댄디한', en: 'dandy and refined mood' },
    warm_hearted: { ko: '훈훈한', en: 'warm-hearted and approachable mood' },
    mature: { ko: '성숙한', en: 'mature and grounded mood' },
    sporty: { ko: '스포티한', en: 'sporty and energetic mood' },
  },
  style: {
    casual: { ko: '캐주얼', en: 'casual everyday outfit' },
    formal: { ko: '포멀', en: 'clean formal outfit' },
    street: { ko: '스트릿', en: 'modern street style outfit' },
    minimal: { ko: '미니멀', en: 'minimal and neat outfit' },
    // 여성 전용 taxonomy
    natural: { ko: '내추럴', en: 'natural and relaxed outfit' },
    feminine: { ko: '페미닌', en: 'feminine and soft outfit' },
    modern_casual: { ko: '모던 캐주얼', en: 'modern casual outfit' },
    sensitive: { ko: '감성적인', en: 'sensitive and tasteful outfit' },
    // 남성 전용 taxonomy
    dandy_casual: { ko: '댄디 캐주얼', en: 'dandy casual outfit' },
    clean_shirt: { ko: '깔끔한 셔츠 스타일', en: 'clean shirt-based outfit' },
  },
  hair: {
    long_straight: { ko: '긴 생머리', en: 'long straight hair' },
    bob: { ko: '단발', en: 'bob haircut' },
    wavy: { ko: '웨이브', en: 'soft wavy hair' },
    short: { ko: '숏컷', en: 'short haircut' },
    two_block: { ko: '투블럭', en: 'neat two-block haircut' },
    dandy: { ko: '댄디컷', en: 'clean dandy haircut' },
    medium: { ko: '미디엄 헤어', en: 'medium-length natural hair' },
    // 여성 전용 신규
    layered: { ko: '레이어드 컷', en: 'layered haircut' },
    // 남성 전용 신규
    regent: { ko: '리젠트', en: 'regent-style slicked back hair' },
  },
  impression: {
    bright_smile: { ko: '밝은 미소', en: 'bright friendly smile' },
    calm: { ko: '무심한', en: 'calm and understated expression' },
    warm: { ko: '따뜻한', en: 'warm and approachable expression' },
    // 여성 전용 taxonomy
    bright_clear: { ko: '맑은 인상', en: 'bright and clear impression' },
    clear_features: { ko: '또렷한 이목구비', en: 'distinct clear facial features' },
    calm_eyes: { ko: '차분한 눈빛', en: 'calm and composed eyes' },
    luxury_vibe: { ko: '고급스러운 분위기', en: 'elegant refined atmosphere' },
    // 남성 전용 taxonomy
    sharp_eyes: { ko: '선명한 눈매', en: 'sharp and clear eyes' },
    calm_smile: { ko: '차분한 미소', en: 'calm gentle smile' },
    mature_impression: { ko: '성숙한 인상', en: 'mature composed impression' },
    soft_impression: { ko: '부드러운 인상', en: 'soft gentle impression' },
    confident: { ko: '자신감 있는 분위기', en: 'confident self-assured atmosphere' },
  },
  background: {
    cafe: { ko: '카페', en: 'cozy cafe background' },
    outdoor: { ko: '야외', en: 'natural outdoor background' },
    studio: { ko: '스튜디오', en: 'simple studio background' },
    indoor: { ko: '실내', en: 'comfortable indoor background' },
  },
};

const IDEAL_HAIR_BY_GENDER = {
  male: ['short', 'two_block', 'dandy', 'medium', 'regent'],
  female: ['long_straight', 'bob', 'wavy', 'short', 'layered'],
  all: [
    'long_straight',
    'bob',
    'wavy',
    'short',
    'two_block',
    'dandy',
    'medium',
    'layered',
    'regent',
  ],
};

// OpenAI 계정/조직 권한에 따라 사용 가능한 이미지 모델은 달라질 수 있다.
// 배포 후 "model does not exist"가 계속되면 OpenAI 대시보드에서 접근 가능한 모델명을 확인한다.
const IDEAL_IMAGE_MODEL = 'gpt-image-1';

// ============================================================================
// AI 이상형 이미지 — provider abstraction
//
// generateIdealTypeImage 콜러블 자체(캐시 조회 → 생성 → Storage 업로드 →
// Firestore 저장)는 그대로 두고, "실제 이미지 생성 API를 호출하는 부분"만
// provider 함수로 분리한다. 일반 앱 기본 provider는 fal_flux다(2026-07-08
// 전환, ACTIVE_IDEAL_IMAGE_PROVIDER 참고). openai 구현은 롤백/비교용으로
// 남겨뒀고 generateIdealTypeImageProviderPreview에서 계속 호출 가능하다.
// 나머지 후보 provider는 명시적 스텁이다.
// ============================================================================

const IDEAL_IMAGE_PROVIDERS = Object.freeze({
  OPENAI: 'openai',
  FAL_FLUX: 'fal_flux',
  REPLICATE_FLUX: 'replicate_flux',
  GENERATED_PHOTOS: 'generated_photos',
  GETTY: 'getty',
  FIREFLY: 'firefly',
  BRIA: 'bria',
});

// 지금 실제로 사용하는 provider. fal.ai FLUX PoC 결과가 OpenAI보다 현실감
// 있는 데이팅 앱용 이상형 이미지를 만들어 기본 provider를 fal_flux로
// 전환했다(2026-07-08). OpenAI 구현은 generateIdealTypeImageWithOpenAI로
// 그대로 남아 있어 여기 값만 되돌리면 즉시 롤백 가능하다.
// openai 경로는 generateIdealTypeImageProviderPreview에서 비교용으로 계속
// 호출할 수 있다(custom claim이 있는 개발자/운영자 전용).
const ACTIVE_IDEAL_IMAGE_PROVIDER = IDEAL_IMAGE_PROVIDERS.FAL_FLUX;

// fal.ai 공식 FLUX.1 [schnell] endpoint.
// 문서 기준:
// - 모델 경로: fal-ai/flux/schnell
// - 호출: synchronous run 계열은 https://fal.run/{model}에 JSON body를 POST
// - 입력: prompt, image_size, num_images, enable_safety_checker, output_format 등
// - 출력: images[0].url/content_type, prompt
// PoC에서는 빠른 실험을 위해 schnell을 기본값으로 둔다. dev는 품질 비교 후보지만
// 기본 앱 provider로 전환하지 않는다.
const FAL_FLUX_MODEL = 'fal-ai/flux/schnell';
const FAL_FLUX_TIMEOUT_MS = 110000;

// 프롬프트(창작 지시문 + 안전 정책 문구) 구성 버전. provider나 프롬프트 문구가
// 바뀌면 올려서, 나중에 응답에 저장된 값만 보고 "어떤 프롬프트 규칙으로 생성된
// 이미지인지"를 구분할 수 있게 한다.
const IDEAL_IMAGE_PROMPT_POLICY_VERSION = 'v1';
const IDEAL_IMAGE_FAL_PROMPT_POLICY_VERSION = 'fal-flux-v3';

// 사용자가 직접 입력하는 짧은 수정 요청(refinementText). 클라이언트가 임의
// 문자열을 prompt에 그대로 꽂는 게 아니라, 서버가 항상 길이 제한 + 키워드
// 차단을 거친 뒤에만 prompt에 반영한다.
const IDEAL_IMAGE_REFINEMENT_MAX_LENGTH = 100;

// 완벽한 필터는 아니다 — 미성년 암시/실존 인물·연예인 닮기/노출·선정적 요청
// 같은 명백한 위험 표현을 걸러내는 최소한의 키워드 기반 방어선이다. 여기
// 없는 표현이 전부 안전하다는 뜻은 아니며, 우회 가능성이 있다.
const IDEAL_IMAGE_REFINEMENT_BLOCKED_PATTERNS = [
  /미성년/i, /초등학생/i, /중학생/i, /고등학생/i, /어린애/i, /아이처럼/i, /학생처럼/i,
  /child/i, /minor/i, /teen/i,
  /노출/i, /벗은/i, /알몸/i, /섹시하게/i, /야하게/i, /선정적/i, /성적으로/i,
  /nude/i, /naked/i, /sexy/i, /explicit/i,
  /연예인/i, /아이돌/i, /배우처럼/i, /실존.*인물/i, /닮게/i, /똑같이 생기/i,
  /celebrity/i, /resemble/i, /look like [a-z]/i,
  /실제.*회원/i, /진짜 사람처럼/i, /특정 인물/i,
];

/**
 * refinementText를 길이 제한 + 키워드 차단으로 검사한다.
 * 반환값의 text는 항상 안전하게 다듬어진(또는 차단 시 빈) 문자열이고,
 * blocked가 true면 호출부에서 사용자에게 실패로 안내해야 한다.
 */
function sanitizeIdealImageRefinementText(raw) {
  if (typeof raw !== 'string') {
    return { text: '', blocked: false };
  }
  const trimmed = raw.trim().slice(0, IDEAL_IMAGE_REFINEMENT_MAX_LENGTH);
  if (!trimmed) {
    return { text: '', blocked: false };
  }
  const blocked = IDEAL_IMAGE_REFINEMENT_BLOCKED_PATTERNS.some((pattern) =>
    pattern.test(trimmed),
  );
  return { text: blocked ? '' : trimmed, blocked };
}

function optionValue(group, key, fallback) {
  const safeKey = typeof key === 'string' && IDEAL_IMAGE_OPTIONS[group]?.[key]
    ? key
    : fallback;
  return { key: safeKey, ...IDEAL_IMAGE_OPTIONS[group][safeKey] };
}

function normalizeIdealImageInput(data) {
  const gender = ['male', 'female', 'all'].includes(data?.gender)
    ? data.gender
    : 'all';
  const hairKeys = IDEAL_HAIR_BY_GENDER[gender] || IDEAL_HAIR_BY_GENDER.all;
  const fallbackHair = gender === 'male' ? 'short' : 'wavy';
  const requestedHair = typeof data?.hair === 'string' ? data.hair : fallbackHair;
  const hairKey = hairKeys.includes(requestedHair) ? requestedHair : fallbackHair;
  const idealTags = Array.isArray(data?.idealTags)
    ? data.idealTags.map(String).slice(0, 8)
    : [];
  const refinement = sanitizeIdealImageRefinementText(data?.refinementText);
  return {
    gender,
    idealTags,
    mood: optionValue('mood', data?.mood, 'gentle'),
    style: optionValue('style', data?.style, 'casual'),
    hair: optionValue('hair', hairKey, fallbackHair),
    impression: optionValue('impression', data?.impression, 'warm'),
    background: optionValue('background', data?.background, 'studio'),
    refinementText: refinement.text,
    refinementBlocked: refinement.blocked,
  };
}

function idealGenderPrompt(gender) {
  if (gender === 'male') return 'adult fictional man';
  if (gender === 'female') return 'adult fictional woman';
  return 'adult fictional person';
}

function idealImageSummary(input) {
  return [
    input.mood.ko,
    input.style.ko,
    input.hair.ko,
    input.impression.ko,
    input.background.ko,
  ].join(' · ');
}

function idealImageHashPayload(input) {
  return {
    gender: input.gender,
    idealTags: input.idealTags,
    mood: input.mood.key,
    style: input.style.key,
    hair: input.hair.key,
    impression: input.impression.key,
    background: input.background.key,
  };
}

function stableHash(value) {
  return crypto
    .createHash('sha256')
    .update(JSON.stringify(value))
    .digest('hex');
}

function legacyIdealImageHash(input) {
  return stableHash(idealImageHashPayload(input));
}

function idealImageHash(input, provider, promptVersion) {
  return stableHash({
    ...idealImageHashPayload(input),
    provider,
    promptVersion,
    // legacyIdealImageHash/idealImageHashPayload는 손대지 않는다 — refinementText는
    // 여기(신규 provider-aware 해시)에만 추가해 아주 오래된 openai 캐시의
    // backward-compat 경로에 영향을 주지 않는다.
    refinementText: input.refinementText || '',
  });
}

// provider가 바뀌어도 항상 함께 붙어야 하는 안전 정책 문구. 실존 인물
// 사칭/신원 특정 방지(PRIMARY)와 표현 수위·식별 정보 회피(TRAILING) 두
// 덩어리로 나눠 두면, 나중에 다른 provider의 프롬프트 포맷에 맞춰 순서를
// 조정해야 할 때도 문구 자체는 그대로 재사용할 수 있다.
// 문구는 기존 buildIdealImagePrompt에서 그대로 옮긴 것이라 최종 프롬프트
// 문자열은 이전과 완전히 동일하다(순서 포함).
const IDEAL_IMAGE_SAFETY_POLICY_PRIMARY =
  'The character is not a real individual, not a celebrity, not an app user, and not based on any identifiable person.';
const IDEAL_IMAGE_SAFETY_POLICY_TRAILING = [
  'Soft editorial illustration, tasteful, non-sexual, adult, single character, simple natural lighting.',
  'Avoid realistic identity details, biometric specificity, logos, names, usernames, or identifying marks.',
].join(' ');

// 사용자가 입력한 refinementText가 있으면 prompt 맨 끝(안전 문구 바로 앞)에
// 추가 절로 붙인다. 안전 문구보다 앞에 둬서, 모델이 "마지막 지시를 더 강하게
// 따르는" 경향이 있어도 안전 제약이 항상 이 요청보다 뒤에서 우선하게 한다.
function idealImageRefinementClause(input) {
  const text = input.refinementText;
  if (!text) return null;
  return `Additional user-requested styling refinement — apply only within all safety constraints above, never let it override them: "${text}"`;
}

function buildIdealImagePrompt(input) {
  const tagText = tagLabels(input.idealTags)
    .filter((label) => !['예쁘고 잘생긴'].includes(label))
    .join(', ');
  const tagClause = tagText
    ? `Preference cues interpreted as personality and styling mood only: ${tagText}.`
    : 'Preference cues should remain broad and non-specific.';
  const refinementClause = idealImageRefinementClause(input);
  return [
    `A gentle stylized portrait illustration of one ${idealGenderPrompt(input.gender)} as an original fictional character.`,
    IDEAL_IMAGE_SAFETY_POLICY_PRIMARY,
    `${input.mood.en}, ${input.style.en}, ${input.hair.en}, ${input.impression.en}, ${input.background.en}.`,
    tagClause,
    ...(refinementClause ? [refinementClause] : []),
    IDEAL_IMAGE_SAFETY_POLICY_TRAILING,
  ].join(' ');
}

function buildFalFluxIdealImagePrompt(input) {
  const tagText = tagLabels(input.idealTags)
    .filter((label) => !['예쁘고 잘생긴'].includes(label))
    .join(', ');
  const tagClause = tagText
    ? `Use these as broad personality and styling cues only: ${tagText}.`
    : 'Keep personality and styling cues broad and non-specific.';
  const refinementClause = idealImageRefinementClause(input);
  return [
    `A realistic AI-generated fictional person portrait of one ${idealGenderPrompt(input.gender)}.`,
    'The person is fictional, not a real person, not a celebrity, and has no resemblance to any specific real person.',
    'Adult, appears 20s or older, tasteful portrait, non-explicit, polished dating-app concept image.',
    `${input.mood.en}, ${input.style.en}, ${input.hair.en}, ${input.impression.en}, ${input.background.en}.`,
    tagClause,
    'Natural face proportions, warm approachable expression, high-quality portrait photography style, clean composition.',
    'Solo portrait, single person only, exactly one face in the entire frame.',
    'No other people, no background people, no additional faces, no crowd, no bystanders, no reflections of other people.',
    'No posters, no framed photos, no portraits, no screens showing faces anywhere in the background.',
    'Plain or softly blurred non-human background — architecture, foliage, fabric, or bokeh only, never another person or a depiction of a person.',
    'Even if the background setting normally implies other people nearby (e.g. a cafe or a street), render the person as completely alone there — empty of any other visible person, face, or figure, blurred into abstract bokeh if needed.',
    ...(refinementClause ? [refinementClause] : []),
    'No identifying marks, no logos, no name tags, no watermark, no text overlays, no usernames, no biometric specificity.',
  ].join(' ');
}

async function fetchImageBytes(imageUrl, { timeoutMs = 30000, requireImage = true } = {}) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  let response;
  try {
    response = await fetch(imageUrl, { signal: controller.signal });
  } finally {
    clearTimeout(timer);
  }
  if (!response.ok) {
    throw new Error(`이미지 URL 다운로드 실패 status=${response.status}`);
  }
  const contentType = response.headers.get('content-type') || '';
  if (requireImage && !contentType.toLowerCase().startsWith('image/')) {
    throw new Error(`이미지 URL content-type 오류 type=${contentType || 'unknown'}`);
  }
  const arrayBuffer = await response.arrayBuffer();
  return Buffer.from(arrayBuffer);
}

async function uploadIdealImage({ uid, inputHash, imageBuffer }) {
  const bucket = admin.storage().bucket();
  const path = `users/${uid}/idealType/${Date.now()}_${inputHash.slice(0, 12)}.png`;
  const token = crypto.randomUUID();
  const file = bucket.file(path);
  await file.save(imageBuffer, {
    metadata: {
      contentType: 'image/png',
      metadata: {
        firebaseStorageDownloadTokens: token,
      },
    },
  });
  const encodedPath = encodeURIComponent(path);
  const url = `https://firebasestorage.googleapis.com/v0/b/${bucket.name}/o/${encodedPath}?alt=media&token=${token}`;
  return { path, url };
}

function imageGenerationErrorMessage(error) {
  const message = String(error?.message || '');
  const lowerMessage = message.toLowerCase();
  if (
    lowerMessage.includes('model') &&
    (
      lowerMessage.includes('does not exist') ||
      lowerMessage.includes('not found') ||
      lowerMessage.includes('not available')
    )
  ) {
    return '이미지 생성 모델을 사용할 수 없습니다. OpenAI 대시보드에서 사용 가능한 이미지 모델명을 확인해주세요.';
  }
  if (
    message.includes('Unknown parameter') ||
    error?.code === 'invalid_request_error' ||
    error?.type === 'invalid_request_error'
  ) {
    return '이미지 API 요청 파라미터가 올바르지 않습니다. 배포된 함수를 최신 코드로 다시 배포해주세요.';
  }
  if (
    error?.code === 'moderation_blocked' ||
    lowerMessage.includes('policy') ||
    lowerMessage.includes('safety') ||
    lowerMessage.includes('moderation')
  ) {
    return '이미지 생성이 정책상 거부되었거나 실패했습니다. 옵션을 더 일반적인 분위기/스타일로 바꿔주세요.';
  }
  return '이미지 생성 서버 요청에 실패했습니다. 잠시 후 다시 시도해주세요.';
}

/**
 * OpenAI(gpt-image-1)로 실제 이미지를 생성해 바이트를 반환한다.
 * generateIdealTypeImage 콜러블 안에 있던 OpenAI 호출 코드를 동작 변경 없이
 * 그대로 옮긴 것이라 에러 처리/메시지가 이전과 동일하다.
 *
 * 반환: { imageBuffer: Buffer, model: string, revisedPrompt: string|null }
 */
async function generateIdealTypeImageWithOpenAI({ prompt }) {
  const client = new OpenAI({ apiKey: OPENAI_API_KEY.value() });
  let imageResponse;
  try {
    imageResponse = await client.images.generate({
      model: IDEAL_IMAGE_MODEL,
      prompt,
      n: 1,
      size: '1024x1024',
    });
  } catch (error) {
    console.error('[generateIdealTypeImage] OpenAI image error', {
      status: error?.status,
      code: error?.code,
    });
    throw new HttpsError(
      'failed-precondition',
      imageGenerationErrorMessage(error),
    );
  }

  const imageData = imageResponse.data?.[0];
  let imageBuffer;
  try {
    if (imageData?.b64_json) {
      imageBuffer = Buffer.from(imageData.b64_json, 'base64');
    } else if (imageData?.url) {
      imageBuffer = await fetchImageBytes(imageData.url, { requireImage: false });
    }
  } catch (error) {
    console.error('[generateIdealTypeImage] image download/parse error', {
    });
    throw new HttpsError(
      'internal',
      '생성된 이미지를 저장하기 위해 내려받는 중 실패했습니다.',
    );
  }

  if (!imageBuffer) {
    throw new HttpsError('internal', '이미지 응답이 비어 있습니다.');
  }

  return {
    imageBuffer,
    model: IDEAL_IMAGE_MODEL,
    revisedPrompt: imageData?.revised_prompt || null,
  };
}

function falFluxUserMessage() {
  return 'AI 이미지 생성에 실패했어요. 잠시 후 다시 시도해주세요.';
}

function mapFalFluxHttpsError(status) {
  if (status === 401 || status === 403) {
    return new HttpsError('failed-precondition', falFluxUserMessage());
  }
  if (status === 404) {
    return new HttpsError('failed-precondition', falFluxUserMessage());
  }
  if (status === 408 || status === 429 || status >= 500) {
    return new HttpsError('unavailable', falFluxUserMessage());
  }
  return new HttpsError('internal', falFluxUserMessage());
}

async function callFalFluxRun({ prompt, falKey }) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), FAL_FLUX_TIMEOUT_MS);
  let response;
  try {
    response = await fetch(`https://fal.run/${FAL_FLUX_MODEL}`, {
      method: 'POST',
      headers: {
        Authorization: `Key ${falKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        prompt,
        image_size: 'square_hd',
        num_inference_steps: 4,
        guidance_scale: 3.5,
        num_images: 1,
        enable_safety_checker: true,
        output_format: 'png',
      }),
      signal: controller.signal,
    });
  } catch (error) {
    const isTimeout = error?.name === 'AbortError';
    console.error('[generateIdealTypeImage] fal_flux request error', {
      provider: IDEAL_IMAGE_PROVIDERS.FAL_FLUX,
      model: FAL_FLUX_MODEL,
      stage: 'request',
      timeout: isTimeout,
    });
    throw new HttpsError(
      isTimeout ? 'deadline-exceeded' : 'unavailable',
      falFluxUserMessage(),
    );
  } finally {
    clearTimeout(timer);
  }

  if (!response.ok) {
    console.error('[generateIdealTypeImage] fal_flux API error', {
      provider: IDEAL_IMAGE_PROVIDERS.FAL_FLUX,
      model: FAL_FLUX_MODEL,
      stage: 'api',
      status: response.status,
    });
    throw mapFalFluxHttpsError(response.status);
  }

  try {
    return await response.json();
  } catch (error) {
    console.error('[generateIdealTypeImage] fal_flux response parse error', {
      provider: IDEAL_IMAGE_PROVIDERS.FAL_FLUX,
      model: FAL_FLUX_MODEL,
      stage: 'parse',
    });
    throw new HttpsError('internal', falFluxUserMessage());
  }
}

/**
 * fal.ai FLUX.1 [schnell]로 현실적인 가상 인물 초상을 생성한다.
 *
 * 반환: { imageBuffer: Buffer, model: string, revisedPrompt: string|null }
 */
async function generateIdealTypeImageWithFalFlux({ prompt }) {
  const falKey = FAL_KEY.value();
  if (!falKey) {
    console.error('[generateIdealTypeImage] fal_flux missing secret', {
      provider: IDEAL_IMAGE_PROVIDERS.FAL_FLUX,
      model: FAL_FLUX_MODEL,
      stage: 'secret',
    });
    throw new HttpsError('failed-precondition', falFluxUserMessage());
  }

  const data = await callFalFluxRun({ prompt, falKey });
  const image = Array.isArray(data?.images) ? data.images[0] : null;
  if (!image?.url || typeof image.url !== 'string') {
    console.error('[generateIdealTypeImage] fal_flux image URL missing', {
      provider: IDEAL_IMAGE_PROVIDERS.FAL_FLUX,
      model: FAL_FLUX_MODEL,
      stage: 'response',
      hasImages: Array.isArray(data?.images),
    });
    throw new HttpsError('internal', falFluxUserMessage());
  }

  let imageBuffer;
  try {
    imageBuffer = await fetchImageBytes(image.url, {
      timeoutMs: 30000,
      requireImage: true,
    });
  } catch (error) {
    console.error('[generateIdealTypeImage] fal_flux image fetch error', {
      provider: IDEAL_IMAGE_PROVIDERS.FAL_FLUX,
      model: FAL_FLUX_MODEL,
      stage: 'image_fetch',
      contentType: image.content_type || null,
    });
    throw new HttpsError('internal', falFluxUserMessage());
  }

  if (!imageBuffer) {
    throw new HttpsError('internal', falFluxUserMessage());
  }

  return {
    imageBuffer,
    model: FAL_FLUX_MODEL,
    revisedPrompt: typeof data?.prompt === 'string' ? data.prompt : prompt,
  };
}
async function generateIdealTypeImageWithReplicateFlux() {
  throw new HttpsError('unimplemented', 'Replicate FLUX provider는 아직 연동되지 않았습니다.');
}
async function generateIdealTypeImageWithGeneratedPhotos() {
  throw new HttpsError('unimplemented', 'Generated Photos provider는 아직 연동되지 않았습니다.');
}
async function generateIdealTypeImageWithGetty() {
  throw new HttpsError('unimplemented', 'Getty Generative AI provider는 아직 연동되지 않았습니다.');
}
async function generateIdealTypeImageWithFirefly() {
  throw new HttpsError('unimplemented', 'Adobe Firefly provider는 아직 연동되지 않았습니다.');
}
async function generateIdealTypeImageWithBria() {
  throw new HttpsError('unimplemented', 'BRIA provider는 아직 연동되지 않았습니다.');
}

/**
 * provider 이름으로 실제 생성 함수를 라우팅한다. 등록되지 않은 provider
 * 이름이 들어오면(설정 실수 등) 조용히 openai로 폴백하지 않고 즉시 에러를
 * 던진다 — 어떤 provider가 실제로 쓰였는지 항상 명확해야 한다.
 */
async function generateIdealTypeImageWithProvider(provider, { prompt }) {
  switch (provider) {
    case IDEAL_IMAGE_PROVIDERS.OPENAI:
      return generateIdealTypeImageWithOpenAI({ prompt });
    case IDEAL_IMAGE_PROVIDERS.FAL_FLUX:
      return generateIdealTypeImageWithFalFlux({ prompt });
    case IDEAL_IMAGE_PROVIDERS.REPLICATE_FLUX:
      return generateIdealTypeImageWithReplicateFlux({ prompt });
    case IDEAL_IMAGE_PROVIDERS.GENERATED_PHOTOS:
      return generateIdealTypeImageWithGeneratedPhotos({ prompt });
    case IDEAL_IMAGE_PROVIDERS.GETTY:
      return generateIdealTypeImageWithGetty({ prompt });
    case IDEAL_IMAGE_PROVIDERS.FIREFLY:
      return generateIdealTypeImageWithFirefly({ prompt });
    case IDEAL_IMAGE_PROVIDERS.BRIA:
      return generateIdealTypeImageWithBria({ prompt });
    default:
      throw new HttpsError('internal', `알 수 없는 이미지 provider: ${provider}`);
  }
}

function isReusableIdealImageCache(cached, { inputHash, legacyInputHash, provider }) {
  if (
    !cached ||
    typeof cached.imageUrl !== 'string' ||
    !cached.imageUrl ||
    typeof cached.inputHash !== 'string'
  ) {
    return false;
  }

  const cachedProvider = cached.provider || IDEAL_IMAGE_PROVIDERS.OPENAI;
  if (cachedProvider !== provider) {
    return false;
  }

  if (cached.inputHash === inputHash) {
    return true;
  }

  // provider 메타데이터가 없던 기존 OpenAI 캐시는 legacy hash로 계속 재사용한다.
  return (
    provider === IDEAL_IMAGE_PROVIDERS.OPENAI &&
    !cached.provider &&
    cached.inputHash === legacyInputHash
  );
}

function promptVersionForProvider(provider) {
  return provider === IDEAL_IMAGE_PROVIDERS.FAL_FLUX
    ? IDEAL_IMAGE_FAL_PROMPT_POLICY_VERSION
    : IDEAL_IMAGE_PROMPT_POLICY_VERSION;
}

function buildPromptForProvider(provider, input) {
  if (provider === IDEAL_IMAGE_PROVIDERS.FAL_FLUX) {
    return buildFalFluxIdealImagePrompt(input);
  }
  return buildIdealImagePrompt(input);
}

function requireIdealImagePreviewAccess(request) {
  const token = request.auth?.token || {};
  if (
    token.admin === true ||
    token.developer === true ||
    token.idealImageProviderPreview === true
  ) {
    return;
  }
  throw new HttpsError('permission-denied', '개발자 preview 권한이 필요합니다.');
}

function normalizeIdealImageProvider(value) {
  if (value === IDEAL_IMAGE_PROVIDERS.OPENAI) {
    return IDEAL_IMAGE_PROVIDERS.OPENAI;
  }
  if (value === IDEAL_IMAGE_PROVIDERS.FAL_FLUX) {
    return IDEAL_IMAGE_PROVIDERS.FAL_FLUX;
  }
  throw new HttpsError('invalid-argument', '지원하지 않는 provider입니다.');
}

/**
 * generateIdealTypeImage 전용 sanitized 로그. prompt/refinementText/이미지 URL/
 * UID/옵션 원문/외부 API 응답/error.message/API key/token/stack 은 절대 남기지
 * 않는다. 허용: 함수명, callerHash, 내부 category, decision, retryable, 안전한
 * status(number). provider/model 은 고정 식별자라 남겨도 민감정보가 아니다.
 */
function logIdealImageEvent(level, category, fields = {}) {
  const line = { fn: 'generateIdealTypeImage', category, ...fields };
  const payload = JSON.stringify(line);
  if (level === 'warn') console.warn(payload);
  else if (level === 'error') console.error(payload);
  else console.log(payload);
}

async function generateIdealTypeImageResult({
  uid,
  data,
  provider,
  cacheField = 'idealTypeImage',
  // 일반 사용자용 generateIdealTypeImage 만 guard 를 주입한다. 개발자 전용
  // generateIdealTypeImageProviderPreview 는 주입하지 않아 동작이 변하지 않는다.
  usageGuard = null,
}) {
  const input = normalizeIdealImageInput(data || {});
  if (input.refinementBlocked) {
    // 원문은 로그에 남기지 않는다 — 어떤 요청이 막혔는지가 아니라 막혔다는
    // 사실만 남긴다.
    logIdealImageEvent('warn', 'refinement_blocked', {
      callerHash: safeUidHash(uid),
      provider,
      retryable: false,
    });
    throw new HttpsError(
      'invalid-argument',
      '요청하신 수정 문구는 반영할 수 없어요. 다른 표현으로 다시 시도해주세요.',
    );
  }
  const promptVersion = promptVersionForProvider(provider);
  const inputHash = idealImageHash(input, provider, promptVersion);
  const legacyInputHash = legacyIdealImageHash(input);
  const userRef = db.collection('users').doc(uid);
  const userSnap = await userRef.get();
  if (!userSnap.exists) {
    throw new HttpsError('not-found', '프로필을 찾을 수 없습니다.');
  }

  const cached = userSnap.data()?.[cacheField];
  if (
    isReusableIdealImageCache(cached, {
      inputHash,
      legacyInputHash,
      provider,
    })
  ) {
    // 유효 캐시 재사용 — 외부 provider 미호출, quota/cooldown 미소비.
    return cached;
  }

  // 외부 이미지 provider 호출 직전 서버측 원자적 슬롯 확보(rate limit +
  // 동시 중복 생성 lease). self 전용이라 targetUid 는 없다(null). guard 자체
  // 오류는 내부 오류로 처리한다(캐시가 없으므로 폴백 없음).
  if (usageGuard) {
    let slot;
    try {
      slot = await usageGuard.acquireGenerationSlot({
        callerUid: uid,
        targetUid: null,
        inputHash,
        isRefresh: false,
        cacheValid: false,
      });
    } catch (error) {
      logIdealImageEvent('error', 'usage_guard_failed', {
        callerHash: safeUidHash(uid),
        provider,
        retryable: true,
      });
      throw new HttpsError(
        'internal',
        'AI 이미지 생성에 실패했어요. 잠시 후 다시 시도해주세요.',
      );
    }
    if (slot.outcome !== 'GENERATE') {
      // quota/cooldown 초과 또는 동일 요청 진행 중. 캐시가 없으므로 재시도 안내.
      throw new HttpsError(
        'resource-exhausted',
        '이미지 생성 요청이 잠시 많아요. 잠시 후 다시 시도해주세요.',
      );
    }
  }

  // 슬롯 확보됨 — 이 attempt 는 성공/실패와 무관하게 이미 quota 에 반영되었다.
  let generationSucceeded = false;
  try {
    const prompt = buildPromptForProvider(provider, input);
    const generation = await generateIdealTypeImageWithProvider(provider, { prompt });

    let uploaded;
    try {
      uploaded = await uploadIdealImage({
        uid,
        inputHash,
        imageBuffer: generation.imageBuffer,
      });
    } catch (error) {
      // Storage 업로드 실패 — 성공 캐시/응답을 만들지 않는다. 원문 미노출.
      logIdealImageEvent('warn', 'storage_upload_failed', {
        callerHash: safeUidHash(uid),
        provider,
        model: generation.model,
        retryable: true,
      });
      throw new HttpsError('internal', 'AI 이미지 생성에 실패했어요. 잠시 후 다시 시도해주세요.');
    }
    const result = {
      inputHash,
      imageUrl: uploaded.url,
      storagePath: uploaded.path,
      summary: idealImageSummary(input),
      safetyLabel: 'AI가 생성한 가상의 이미지입니다. 실제 앱 사용자가 아닙니다.',
      options: {
        gender: input.gender,
        idealTags: input.idealTags,
        mood: input.mood.key,
        style: input.style.key,
        hair: input.hair.key,
        impression: input.impression.key,
        background: input.background.key,
      },
      revisedPrompt: generation.revisedPrompt,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      provider,
      model: generation.model,
      promptVersion,
      safetyPolicyVersion: promptVersion,
      imageCount: 1,
      syntheticHuman: true,
    };

    try {
      await userRef.set({ [cacheField]: result }, { merge: true });
    } catch (error) {
      // 캐시 write 실패 — 성공 응답을 반환하지 않는다. 원문 미노출.
      logIdealImageEvent('warn', 'firestore_write_failed', {
        callerHash: safeUidHash(uid),
        provider,
        model: generation.model,
        retryable: true,
      });
      throw new HttpsError('internal', 'AI 이미지 생성에 실패했어요. 잠시 후 다시 시도해주세요.');
    }
    generationSucceeded = true;
    return {
      ...result,
      createdAt: null,
    };
  } finally {
    // lease 해제(성공 여부와 무관). 성공 시 캐시가 이미 저장돼 재생성이 안 일어난다.
    if (usageGuard) {
      try {
        await usageGuard.releaseGenerationSlot({
          callerUid: uid,
          targetUid: null,
          inputHash,
          success: generationSucceeded,
        });
      } catch (releaseError) {
        logIdealImageEvent('warn', 'lease_release_failed', {
          callerHash: safeUidHash(uid),
          provider,
          retryable: false,
        });
      }
    }
  }
}

/**
 * AI 이상형 이미지 생성 (callable).
 *
 * 입력: { gender, idealTags, mood, style, hair, impression, background }
 * provider: ACTIVE_IDEAL_IMAGE_PROVIDER(현재 fal_flux) 고정. openai로 롤백하려면
 * 이 값만 바꿔서 재배포하면 된다 — 나머지 로직/응답 schema는 provider에 무관하다.
 * 캐싱: users/{uid}.idealTypeImage.inputHash가 같으면 Storage URL을 재사용한다.
 */
exports.generateIdealTypeImage = onCall(
  { secrets: [OPENAI_API_KEY, FAL_KEY], timeoutSeconds: 120, memory: '1GiB' },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError('unauthenticated', '로그인이 필요합니다.');
    }

    return generateIdealTypeImageResult({
      uid: request.auth.uid,
      data: request.data || {},
      provider: ACTIVE_IDEAL_IMAGE_PROVIDER,
      cacheField: 'idealTypeImage',
      usageGuard: idealTypeImageUsageGuard,
    });
  },
);

/**
 * AI 이상형 이미지 provider preview (developer/PoC only).
 *
 * 입력: { provider: 'openai' | 'fal_flux', ...generateIdealTypeImage options }
 * 일반 앱 UI에서는 호출하지 않는다. custom claim(admin/developer/
 * idealImageProviderPreview) 중 하나가 있는 계정만 접근 가능하다.
 * 결과는 users/{uid}.idealTypeImageProviderPreview에 저장해 일반 앱 캐시와
 * 섞이지 않게 한다.
 */
exports.generateIdealTypeImageProviderPreview = onCall(
  {
    secrets: [OPENAI_API_KEY, FAL_KEY],
    timeoutSeconds: 120,
    memory: '1GiB',
  },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError('unauthenticated', '로그인이 필요합니다.');
    }
    requireIdealImagePreviewAccess(request);
    const provider = normalizeIdealImageProvider(request.data?.provider);
    return generateIdealTypeImageResult({
      uid: request.auth.uid,
      data: request.data || {},
      provider,
      cacheField: 'idealTypeImageProviderPreview',
    });
  },
);

// ============================================================================
// Phase 0-D: 인증 배지 서버 전용 동기화
// ============================================================================

exports.syncAuthVerificationBadges = onCall(
  { secrets: [CONTACT_AVOIDANCE_PEPPER] },
  async (request) => {
    const result = await syncAuthVerificationBadgesCore({
      request,
      auth: admin.auth(),
      db,
      HttpsError,
      serverTimestamp: admin.firestore.FieldValue.serverTimestamp,
      logger: console,
    });

    // Phase 3-4: 전화 인증 상태에 맞춰 지인 피하기용 private 식별자를 갱신한다.
    // 실패해도 배지 동기화 결과를 되돌리지 않는다(다음 호출에서 다시 시도).
    try {
      const userRecord = await admin.auth().getUser(request.auth.uid);
      await syncPrivatePhoneIdentifier({
        uid: request.auth.uid,
        phoneNumber: userRecord?.phoneNumber,
        phoneVerified: result?.verifications?.phone === true,
        pepper: CONTACT_AVOIDANCE_PEPPER.value(),
        db,
        serverTimestamp: admin.firestore.FieldValue.serverTimestamp,
      });
    } catch (_) {
      // uid hash 외 식별 정보를 남기지 않는다.
      console.error('event=contact_identifier_sync result=error');
    }

    return result;
  },
);

// ============================================================================
// Phase 3-4: 연락처 기반 지인 피하기
// ============================================================================
//
// 클라이언트는 정규화된 전화번호의 SHA-256 digest만 보낸다. 서버는 그 digest를
// secret pepper로 HMAC해 privatePhoneIdentifiers와 대조하고, 매칭된 상대와
// 양방향 숨김 pair를 만든다. 전화번호 원문·이름·digest는 저장하지 않는다.

exports.syncAvoidContacts = onCall(
  { secrets: [CONTACT_AVOIDANCE_PEPPER] },
  async (request) => {
    return syncAvoidContactsCore({
      request,
      db,
      auth: admin.auth(),
      pepper: CONTACT_AVOIDANCE_PEPPER.value(),
      HttpsError,
      serverTimestamp: admin.firestore.FieldValue.serverTimestamp,
      logger: console,
    });
  },
);

// ============================================================================
// Phase 3-2: 사진 인증 수동 검토 (admin 전용)
// ============================================================================
//
// 일반 사용자는 photoVerificationRequests 문서를 pending으로 만들 수만 있고,
// verifications.photo 배지는 이 함수(Admin SDK)만 켤 수 있다.
// 자동 얼굴 인식/생체 판정은 하지 않는다 — 운영자의 수동 검토 결과만 반영한다.

exports.reviewPhotoVerification = onCall(async (request) => {
  return reviewPhotoVerificationCore({
    request,
    db,
    storageBucket: admin.storage().bucket(),
    HttpsError,
    serverTimestamp: admin.firestore.FieldValue.serverTimestamp,
    logger: console,
  });
});

// ============================================================================
// Phase 3-3: 직장·학교 소속 인증 수동 검토 (admin 전용)
// ============================================================================
//
// 일반 사용자는 users/{uid}/affiliationVerificationRequests/{type} 문서를
// pending으로 만들 수만 있고, verifications.work/school 배지는 이 함수
// (Admin SDK)만 켤 수 있다. OCR·자동 판정은 하지 않는다.

exports.reviewAffiliationVerification = onCall(async (request) => {
  return reviewAffiliationVerificationCore({
    request,
    db,
    storageBucket: admin.storage().bucket(),
    HttpsError,
    serverTimestamp: admin.firestore.FieldValue.serverTimestamp,
    logger: console,
  });
});

// ============================================================================
// Phase 0-F-1: 젤리 인앱결제(IAP) 영수증 검증 + 서버 전용 지급
// ============================================================================

exports.verifyJellyPurchase = onCall(async (request) => {
  try {
    return await verifyJellyPurchaseCore({
      request,
      db,
      serverTimestamp: admin.firestore.FieldValue.serverTimestamp,
      logger: console,
    });
  } catch (error) {
    throw toHttpsError(error, HttpsError);
  }
});

// ============================================================================
// Phase 4-2: 라운지 커뮤니티 (게시물·댓글·공감·삭제·신고)
// ============================================================================
//
// 커뮤니티 write는 전부 서버 전용이다(firestore.rules는 client write 차단).
// 작성자 snapshot은 publicProfiles에서만 만들고, 공개 글의 전화번호/인증번호/
// 송금 요청은 서버가 거부한다. 응답에는 uid·본문·내부 경로를 담지 않는다.

/** core가 던진 안전한 HttpsError만 그대로 통과시키고 나머지는 감싼다. */
function toCommunityHttpsError(error) {
  if (error?.__communitySafeError === true) return error;
  return new HttpsError('internal', '잠시 후 다시 시도해주세요.');
}

function communityCallable(core, { withBucket = false } = {}) {
  return onCall(async (request) => {
    try {
      return await core({
        request,
        db,
        // Feed 이미지 object를 직접 확인·삭제해야 하는 core에만 넘긴다.
        ...(withBucket ? { bucket: admin.storage().bucket() } : {}),
        HttpsError,
        serverTimestamp: admin.firestore.FieldValue.serverTimestamp,
        logger: console,
      });
    } catch (error) {
      throw toCommunityHttpsError(error);
    }
  });
}

exports.createLoungePost = communityCallable(createLoungePostCore);
exports.createFeedPost = communityCallable(createFeedPostCore, {
  withBucket: true,
});
exports.createCommunityComment = communityCallable(createCommunityCommentCore);
exports.toggleCommunityReaction = communityCallable(toggleCommunityReactionCore);
exports.deleteCommunityPost = communityCallable(deleteCommunityPostCore, {
  withBucket: true,
});
exports.deleteCommunityComment = communityCallable(deleteCommunityCommentCore);
exports.reportCommunityContent = communityCallable(reportCommunityContentCore);

// ============================================================================
// Phase 4-4: Party·Square (파티 생성·참여 요청·승인·취소·신고)
// ============================================================================
//
// Party write도 전부 서버 전용이다. 하나의 파티 모델을 Square 탐색과 "내 파티"
// 관리가 함께 쓴다. 그룹 채팅은 Phase 4-5에서 승인된 멤버 기반으로 붙인다.
//
// 커뮤니티와 같은 오류 계약(__communitySafeError)을 쓰므로 같은 wrapper를
// 재사용한다 — core가 던진 안전한 HttpsError만 통과하고 나머지는 감춘다.

/** Timestamp 변환이 필요한 party core에만 넘긴다. */
function partyCallable(core) {
  return onCall(async (request) => {
    try {
      return await core({
        request,
        db,
        HttpsError,
        serverTimestamp: admin.firestore.FieldValue.serverTimestamp,
        timestampFromMillis: (millis) =>
          admin.firestore.Timestamp.fromMillis(millis),
        logger: console,
      });
    } catch (error) {
      throw toCommunityHttpsError(error);
    }
  });
}

exports.createCommunityParty = partyCallable(createCommunityPartyCore);
exports.requestPartyJoin = partyCallable(requestPartyJoinCore);
exports.reviewPartyJoinRequest = partyCallable(reviewPartyJoinRequestCore);
exports.withdrawPartyJoinRequest = partyCallable(withdrawPartyJoinRequestCore);
exports.leaveCommunityParty = partyCallable(leaveCommunityPartyCore);
exports.cancelCommunityParty = partyCallable(cancelCommunityPartyCore);
exports.reportCommunityParty = partyCallable(reportCommunityPartyCore);

// ============================================================================
// Phase 0-G-2B: 회원 탈퇴 서버 처리
// ============================================================================

exports.deleteMyAccount = onCall(
  { timeoutSeconds: 540, memory: '1GiB', maxInstances: 5 },
  async (request) => {
    try {
      return await deleteMyAccountCore({
        request,
        db,
        auth: admin.auth(),
        storageBucket: admin.storage().bucket(),
        serverTimestamp: admin.firestore.FieldValue.serverTimestamp,
        fieldDelete: admin.firestore.FieldValue.delete,
        logger: console,
      });
    } catch (error) {
      throw toAccountDeletionHttpsError(error, HttpsError);
    }
  },
);
