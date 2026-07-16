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

setGlobalOptions({ region: 'asia-northeast3' });

admin.initializeApp();
const db = admin.firestore();

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

    const created = await db.runTransaction(async (transaction) => {
      const [existing, currentSwipe, reverseSwipe] = await Promise.all([
        transaction.get(matchRef),
        transaction.get(currentSwipeRef),
        transaction.get(reverseSwipeRef),
      ]);

      // 이미 매칭됐으면 다시 만들지 않는다 (멱등 처리).
      if (existing.exists) return false;

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

async function sendPushToUser({ uid, title, body, data }) {
  const tokens = await userTokens(uid);
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
    await sendPushToUser({
      uid: receiverUid,
      title: '새 메시지',
      body: `${senderName}님이 메시지를 보냈어요.`,
      data: {
        type: 'chat',
        matchId,
        senderUid: senderId,
      },
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

/** 개인 사주 서사 생성용 시스템 프롬프트. */
function fortuneSystemPrompt() {
  return [
    '당신은 별자리와 사주 명리학 지식을 활용해 데이팅 앱 사용자에게',
    '재미있고 공감되는 캐릭터 해석을 제공하는 카피라이터입니다.',
    '',
    '반드시 지킬 규칙:',
    '1. 사용자 메시지의 "속성" JSON에 주어진 값(별자리/원소/일간/오행)만 근거로 해석한다.',
    '   주어지지 않은 정보(정확한 생년월일, 이름, 성별 등)를 추측하거나 지어내지 않는다.',
    '2. 점수·퍼센트·순위 등 숫자 지표를 절대 만들지 않는다. 서사와 캐릭터로만 표현한다.',
    '3. 반드시 아래 JSON 스키마로만 응답한다 (다른 설명, 마크다운, 코드블록 금지):',
    '{"characterType": string, "summary": string, "reasons": [{"icon": string, "text": string}], "relationshipStory": null}',
    '- characterType: 이모지 1개 + 한글 캐릭터 이름(4~10자), 예) "🔥 열정형"',
    '- summary: 2~3문장 요약 서사',
    '- reasons: 2~4개 배열, 각 항목은 이모지 1개 + 한 줄 근거(주어진 오행/별자리 속성 기반)',
    '- relationshipStory: 개인 서사이므로 항상 null 고정',
  ].join('\n');
}

/** 두 사람 궁합 서사 생성용 시스템 프롬프트. */
function matchSystemPrompt() {
  return [
    '당신은 별자리와 사주 명리학 지식을 활용해 데이팅 앱의 두 사용자 궁합을',
    '캐릭터와 이야기로 해석하는 카피라이터입니다.',
    '',
    '반드시 지킬 규칙:',
    '1. 사용자 메시지의 "속성A"·"속성B" JSON에 주어진 두 사람의 값만 근거로 해석한다.',
    '   주어지지 않은 정보(이름, 나이, 외모 등)를 추측하거나 지어내지 않는다.',
    '2. 점수·퍼센트·순위·궁합도 같은 숫자 지표를 절대 만들지 않는다. 서사와 캐릭터로만 표현한다.',
    '3. 반드시 아래 JSON 스키마로만 응답한다 (다른 설명, 마크다운, 코드블록 금지):',
    '{"characterType": string, "summary": string, "reasons": [{"icon": string, "text": string}], "relationshipStory": string}',
    '- characterType: 이모지 2개(두 사람을 상징) + 한글 조합 이름, 예) "🔥🌊 열정×안정 조합"',
    '- summary: 2~3문장 요약',
    '- reasons: 2~4개 배열, 각 항목은 이모지 1개 + 한 줄 근거(오행 상생상극, 별자리 원소 궁합 등)',
    '- relationshipStory: 3~5문장. 두 사람이 만들어갈 관계의 흐름을 이야기로 서술한다',
    '  (확정적 예측·점수 대신 "~할 수 있어요" 같은 가능성 있는 서사로 표현)',
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
    if (isValidNarrative(cached)) return cached;

    const rawNarrative = await callOpenAiForNarrative({
      systemPrompt: fortuneSystemPrompt(),
      userPayload: { 속성: attrs },
    });
    const narrative = sanitizeNarrative(rawNarrative, { requireStory: false });

    if (!isValidNarrative(narrative)) {
      console.error('[generateFortuneNarrative] GPT 응답 검증 실패', {
        raw: rawNarrative,
        sanitized: narrative,
      });
      throw new HttpsError('internal', 'GPT 응답 형식이 올바르지 않습니다.');
    }

    await userRef.set({ fortuneNarrative: narrative }, { merge: true });
    return narrative;
  },
);

/**
 * 두 사람 궁합 서사 생성 (callable).
 *
 * 입력: { matchId, userA: {zodiac, saju}, userB: {zodiac, saju} }
 * 권한: 호출자가 해당 matchId의 participants에 포함돼야 한다.
 * 캐싱: matches/{matchId}.fortuneMatch — 이미 있으면 GPT 호출 없이 그대로 반환한다.
 */
exports.generateMatchNarrative = onCall(
  { secrets: [OPENAI_API_KEY] },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError('unauthenticated', '로그인이 필요합니다.');
    }
    const { matchId, userA, userB } = request.data || {};
    if (!matchId || !isValidAttrs(userA) || !isValidAttrs(userB)) {
      throw new HttpsError('invalid-argument', '매치 ID/속성이 올바르지 않습니다.');
    }

    const matchRef = db.collection('matches').doc(matchId);
    const matchSnap = await matchRef.get();
    if (!matchSnap.exists) {
      throw new HttpsError('not-found', '매치를 찾을 수 없습니다.');
    }
    const participants = matchSnap.data()?.participants || [];
    if (!participants.includes(request.auth.uid)) {
      throw new HttpsError('permission-denied', '이 매치에 접근할 권한이 없습니다.');
    }

    const cached = matchSnap.data()?.fortuneMatch;
    if (isValidNarrative(cached)) return cached;

    const rawNarrative = await callOpenAiForNarrative({
      systemPrompt: matchSystemPrompt(),
      userPayload: { 속성A: userA, 속성B: userB },
    });
    const narrative = sanitizeNarrative(rawNarrative, { requireStory: true });

    if (!isValidNarrative(narrative) || typeof narrative.relationshipStory !== 'string') {
      console.error('[generateMatchNarrative] GPT 응답 검증 실패', {
        raw: rawNarrative,
        sanitized: narrative,
      });
      throw new HttpsError('internal', 'GPT 응답 형식이 올바르지 않습니다.');
    }

    await matchRef.set({ fortuneMatch: narrative }, { merge: true });
    return narrative;
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

/** users/{uid} 문서에서 GPT 입력에 필요한 공개 프로필 조각만 뽑는다. */
function icebreakerProfileFromSnap(uid, snap) {
  const data = snap.data() || {};
  const parts = datePartsInSeoul(data.birthDate);
  if (!parts || !parts.year || !parts.month || !parts.day) {
    console.warn('[generateIcebreakers] birthDate missing', { uid });
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
    console.log('[generateIcebreakers] start', {
      matchId,
      uid: request.auth.uid,
    });

    const matchRef = db.collection('matches').doc(matchId);
    const matchSnap = await matchRef.get();
    if (!matchSnap.exists) {
      throw new HttpsError('not-found', '매치를 찾을 수 없습니다.');
    }

    const matchData = matchSnap.data() || {};
    const participants = matchData.participants || [];
    if (!participants.includes(request.auth.uid)) {
      throw new HttpsError('permission-denied', '이 매치에 접근할 권한이 없습니다.');
    }

    const cached = matchData.icebreakers;
    if (isValidIcebreakerList(cached)) {
      console.log('[generateIcebreakers] cache hit', {
        matchId,
        count: cached.length,
      });
      return { icebreakers: cached };
    }
    console.log('[generateIcebreakers] cache miss', { matchId });

    const [uidA, uidB] = participants;
    if (!uidA || !uidB) {
      throw new HttpsError('failed-precondition', '상대 참가자를 찾을 수 없습니다.');
    }

    const [snapA, snapB] = await Promise.all([
      db.collection('users').doc(uidA).get(),
      db.collection('users').doc(uidB).get(),
    ]);
    if (!snapA.exists || !snapB.exists) {
      console.warn('[generateIcebreakers] profile missing', {
        matchId,
        uidAExists: snapA.exists,
        uidBExists: snapB.exists,
      });
      throw new HttpsError('not-found', '프로필을 찾을 수 없습니다.');
    }

    const userA = icebreakerProfileFromSnap(uidA, snapA);
    const userB = icebreakerProfileFromSnap(uidB, snapB);
    const userBInterestKeys = new Set(userB.rawInterestKeys);
    const commonInterestKeys = userA.rawInterestKeys.filter((key) =>
      userBInterestKeys.has(key),
    );

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
      console.warn('[generateIcebreakers] invalid response', {
        matchId,
        count: icebreakers.length,
      });
      throw new HttpsError('internal', 'GPT 응답 형식이 올바르지 않습니다.');
    }

    await matchRef.set({ icebreakers }, { merge: true });
    console.log('[generateIcebreakers] generated', {
      matchId,
      count: icebreakers.length,
    });
    return { icebreakers };
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
    console.log('[generateConversationTips] start', {
      matchId,
      uid: request.auth.uid,
    });

    const matchRef = db.collection('matches').doc(matchId);
    const matchSnap = await matchRef.get();
    if (!matchSnap.exists) {
      throw new HttpsError('not-found', '매치를 찾을 수 없습니다.');
    }

    const matchData = matchSnap.data() || {};
    const participants = matchData.participants || [];
    if (!participants.includes(request.auth.uid)) {
      throw new HttpsError('permission-denied', '이 매치에 접근할 권한이 없습니다.');
    }

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
      console.log('[generateConversationTips] cache hit', {
        matchId,
        lastMessageId: latestMessageId,
        count: cached.suggestions.length,
      });
      return { suggestions: cached.suggestions };
    }
    console.log('[generateConversationTips] cache miss', {
      matchId,
      lastMessageId: latestMessageId,
    });

    const [snapA, snapB] = await Promise.all([
      db.collection('users').doc(uidA).get(),
      db.collection('users').doc(uidB).get(),
    ]);
    if (!snapA.exists || !snapB.exists) {
      console.warn('[generateConversationTips] profile missing', {
        matchId,
        uidAExists: snapA.exists,
        uidBExists: snapB.exists,
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
      console.warn('[generateConversationTips] invalid response', {
        matchId,
        count: suggestions.length,
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
    console.log('[generateConversationTips] generated', {
      matchId,
      lastMessageId: latestMessageId,
      count: suggestions.length,
    });
    return { suggestions };
  },
);

/** 오늘의 운세(애정 중심) 생성용 시스템 프롬프트. */
function dailyFortuneSystemPrompt() {
  return [
    '당신은 데이팅 앱에서 "오늘의 운세"를 애정운/연애운 중심으로 들려주는',
    '따뜻하고 공감되는 카피라이터입니다.',
    '',
    '반드시 지킬 규칙:',
    '1. 사용자 메시지의 "속성" JSON(별자리/원소/일간/오행)과 "날짜"만 근거로 삼는다.',
    '   주어지지 않은 정보를 추측하거나 지어내지 않는다.',
    '2. 오늘 하루의 연애/관계에 대한 조언 톤으로 쓴다. 확정적 예언이 아니라',
    '   공감과 응원 위주로 표현한다.',
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
    if (isValidDailyFortune(snap.data())) return snap.data();

    const rawFortune = await callOpenAiForNarrative({
      systemPrompt: dailyFortuneSystemPrompt(),
      userPayload: { 날짜: date, 속성: attrs },
    });
    const fortune = sanitizeDailyFortune(rawFortune);

    if (!isValidDailyFortune(fortune)) {
      console.error('[generateDailyFortune] GPT 응답 검증 실패', {
        raw: rawFortune,
        sanitized: fortune,
      });
      throw new HttpsError('internal', 'GPT 응답 형식이 올바르지 않습니다.');
    }

    await dailyRef.set(fortune);
    return fortune;
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
    '2. 점수, 순위, 확률, 외모 평가를 만들지 않는다. 공감되는 첫인상 서사로 표현한다.',
    '3. 개선 팁은 지적이 아니라 "조금 더 잘 드러내는 방법" 톤으로 쓴다.',
    '4. 반드시 아래 JSON 스키마로만 응답한다 (다른 설명, 마크다운, 코드블록 금지):',
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
    if (!refresh && isValidCharmReport(cached)) return cached;

    const profile = charmProfileFromData(data);
    const hasProfileSignal =
      !!profile.한줄소개 ||
      profile.관심사.length > 0 ||
      profile.성향.length > 0 ||
      profile.이상형키워드.length > 0;
    if (!hasProfileSignal) {
      throw new HttpsError(
        'failed-precondition',
        '매력 리포트 생성을 위해 소개나 태그를 먼저 채워주세요.',
      );
    }

    const raw = await callOpenAiForNarrative({
      systemPrompt: charmReportSystemPrompt(),
      userPayload: { 프로필: profile },
    });
    const report = sanitizeCharmReport(raw);
    if (!isValidCharmReport(report)) {
      throw new HttpsError('internal', 'GPT 응답 형식이 올바르지 않습니다.');
    }

    await userRef.set(
      {
        charmReport: report,
        charmReportUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true },
    );
    return report;
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

/**
 * 상대 프로필 비외모 인사이트 생성 (callable).
 *
 * 입력: { targetUid: string, refresh?: boolean }
 * 캐싱: users/{targetUid}.profileInsight.inputHash가 같으면 그대로 반환한다.
 */
exports.generateProfileInsight = onCall(
  { secrets: [OPENAI_API_KEY] },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError('unauthenticated', '로그인이 필요합니다.');
    }

    const targetUid = String(request.data?.targetUid || '').trim();
    if (!targetUid) {
      throw new HttpsError('invalid-argument', '대상 유저 ID가 올바르지 않습니다.');
    }

    const refresh = request.data?.refresh === true;
    const userRef = db.collection('users').doc(targetUid);
    const snap = await userRef.get();
    if (!snap.exists) {
      throw new HttpsError('not-found', '프로필을 찾을 수 없습니다.');
    }

    const data = snap.data() || {};
    const inputHash = profileInsightHash(data);
    const cached = data.profileInsight;
    if (
      !refresh &&
      cached &&
      cached.inputHash === inputHash &&
      isValidProfileInsight(cached)
    ) {
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

    const profile = profileInsightInputFromData(data);
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

    const imageUrl = Array.isArray(data.photoUrls) && data.photoUrls[0]
      ? String(data.photoUrls[0])
      : null;
    let raw;
    try {
      raw = await callOpenAiForProfileInsight({
        systemPrompt: profileInsightSystemPrompt(),
        userPayload: { 프로필: profile },
        imageUrl,
      });
    } catch (error) {
      console.error('[generateProfileInsight] OpenAI profile insight error', {
        status: error?.status,
        code: error?.code,
        message: error?.message,
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
    return {
      ...insight,
      model: PROFILE_INSIGHT_MODEL,
      updatedAt: null,
    };
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
      message: error?.message,
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
      message: error?.message,
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
      message: error?.message,
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
      message: error?.message,
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
      message: error?.message,
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

async function generateIdealTypeImageResult({
  uid,
  data,
  provider,
  cacheField = 'idealTypeImage',
}) {
  const input = normalizeIdealImageInput(data || {});
  if (input.refinementBlocked) {
    // 원문은 로그에 남기지 않는다 — 어떤 요청이 막혔는지가 아니라 막혔다는
    // 사실만 남긴다.
    console.warn('[generateIdealTypeImage] refinementText blocked', {
      provider,
      stage: 'refinement_validation',
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
    return cached;
  }

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
    console.error('[generateIdealTypeImage] storage upload error', {
      provider,
      model: generation.model,
      stage: 'storage_upload',
      cacheField,
      message: error?.message,
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
    console.error('[generateIdealTypeImage] storage metadata write error', {
      provider,
      model: generation.model,
      stage: 'firestore_write',
      cacheField,
      message: error?.message,
    });
    throw new HttpsError('internal', 'AI 이미지 생성에 실패했어요. 잠시 후 다시 시도해주세요.');
  }
  return {
    ...result,
    createdAt: null,
  };
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

exports.syncAuthVerificationBadges = onCall(async (request) => {
  return syncAuthVerificationBadgesCore({
    request,
    auth: admin.auth(),
    db,
    HttpsError,
    serverTimestamp: admin.firestore.FieldValue.serverTimestamp,
    logger: console,
  });
});

// ============================================================================
// M10: 젤리 인앱결제(IAP) 영수증 검증 — 스켈레톤
//
// 클라이언트가 in_app_purchase로 스토어 결제를 완료하면 영수증/토큰을 이
// 함수로 보낸다. 함수는 (실제로는) App Store Server API / Google Play
// Developer API로 영수증을 검증한 뒤, 유효하면 admin SDK로 직접 젤리 잔액을
// 충전한다 — 클라이언트가 Firestore를 직접 쓰지 않게 해 위조를 막는 것이
// 목적이다(다른 GPT 함수들이 캐시를 admin SDK로만 쓰는 것과 같은 원칙).
//
// ⚠️ 스토어 등록 전 상태 — RELEASE-BLOCKER와 같은 성격의 위험:
// 지금은 스토어에 상품이 등록되지 않아 실제 검증 API를 호출할 자격증명
// (Apple 공유 비밀키/App Store Connect API 키, Google 서비스 계정 키)이 없다.
// verifyWithAppStore/verifyWithGooglePlay는 항상 성공을 반환하는
// 자리표시자이므로, 이 상태로는 절대 프로덕션에 배포하면 안 된다
// (누구나 결제 없이 젤리를 받을 수 있게 된다). 스토어 등록 후 두 함수 내부를
// 실제 API 호출로 교체할 것.
// ============================================================================

// jelly_service.dart의 JellyPurchaseCatalog와 productId·amount가 반드시 같아야 한다.
const JELLY_PRODUCTS = {
  jelly_30: 30,
  jelly_100: 100,
  jelly_300: 300,
};

/**
 * (스켈레톤) Apple App Store Server API로 영수증을 검증한다.
 *
 * 실제 구현 시: App Store Server API(JWT 서명, App Store Connect API 키)로
 * transactionId 기준 거래 내역을 조회해 productId/유효성을 대조해야 한다.
 * 참고: https://developer.apple.com/documentation/appstoreserverapi
 */
async function verifyWithAppStore({ productId, purchaseToken, transactionId }) {
  // TODO: 스토어 등록 후 App Store Server API 실제 호출로 교체.
  return { valid: true, productId };
}

/**
 * (스켈레톤) Google Play Developer API로 구매 토큰을 검증한다.
 *
 * 실제 구현 시: Google Play Developer API
 * (purchases.products.get, 서비스 계정 JSON 키 필요)로 purchaseToken을
 * 조회해 purchaseState/consumptionState를 확인해야 한다.
 * 참고: https://developers.google.com/android-publisher/api-ref/rest/v3/purchases.products
 */
async function verifyWithGooglePlay({ productId, purchaseToken }) {
  // TODO: 스토어 등록 후 Google Play Developer API 실제 호출로 교체.
  return { valid: true, productId };
}

/**
 * 젤리 IAP 영수증 검증 + 충전 (callable).
 *
 * 입력: { platform: 'ios' | 'android', productId, purchaseToken, transactionId }
 * 캐싱/멱등: users/{uid}/jellyTransactions/{transactionId} 문서를 트랜잭션
 * 안에서 확인해, 같은 거래가 재전송돼도 한 번만 충전한다.
 */
exports.verifyJellyPurchase = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError('unauthenticated', '로그인이 필요합니다.');
  }

  const { platform, productId, purchaseToken, transactionId } =
    request.data || {};
  if (platform !== 'ios' && platform !== 'android') {
    throw new HttpsError(
      'invalid-argument',
      'platform은 ios 또는 android여야 합니다.',
    );
  }
  const amount = JELLY_PRODUCTS[productId];
  if (!amount) {
    throw new HttpsError('invalid-argument', '알 수 없는 상품 ID입니다.');
  }
  if (
    typeof purchaseToken !== 'string' ||
    !purchaseToken ||
    typeof transactionId !== 'string' ||
    !transactionId
  ) {
    throw new HttpsError('invalid-argument', '영수증 정보가 올바르지 않습니다.');
  }

  const verification =
    platform === 'ios'
      ? await verifyWithAppStore({ productId, purchaseToken, transactionId })
      : await verifyWithGooglePlay({ productId, purchaseToken });

  if (!verification.valid) {
    throw new HttpsError('failed-precondition', '영수증 검증에 실패했습니다.');
  }

  const userRef = db.collection('users').doc(request.auth.uid);
  // transactionId를 문서 ID로 써서 같은 영수증이 중복 제출돼도 한 번만
  // 충전되게 한다(멱등 처리).
  const txRef = userRef.collection('jellyTransactions').doc(transactionId);

  const result = await db.runTransaction(async (t) => {
    const [userSnap, txSnap] = await Promise.all([
      t.get(userRef),
      t.get(txRef),
    ]);
    if (txSnap.exists) {
      // 이미 처리된 거래 — 중복 충전 방지.
      return { balance: userSnap.data()?.jelly || 0, duplicate: true };
    }
    const current = userSnap.data()?.jelly || 0;
    const next = current + amount;
    t.update(userRef, { jelly: next });
    t.set(txRef, {
      type: 'charge',
      amount,
      reason: `iap_${platform}_${productId}`,
      platform,
      productId,
      transactionId,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    return { balance: next, duplicate: false };
  });

  return { amount, balance: result.balance, duplicate: result.duplicate };
});
