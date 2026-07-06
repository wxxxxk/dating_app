// M4: 스와이프 생성 시 상호 like 판정 → matches 문서 자동 생성
// Cloud Functions v2 (2nd gen) — Firebase Functions SDK v6+
//
// 배포: firebase deploy --only functions
// 로그: firebase functions:log

const { onDocumentWritten } = require('firebase-functions/v2/firestore');
const { onCall, HttpsError } = require('firebase-functions/v2/https');
const { defineSecret } = require('firebase-functions/params');
const admin = require('firebase-admin');
const crypto = require('crypto');
const OpenAI = require('openai');

admin.initializeApp();
const db = admin.firestore();

// M6: 사주/궁합 GPT 서사 생성에 쓰는 OpenAI API 키.
// 절대 코드에 하드코딩하지 않고 Firebase 시크릿으로만 주입한다.
// 등록: firebase functions:secrets:set OPENAI_API_KEY
const OPENAI_API_KEY = defineSecret('OPENAI_API_KEY');

/**
 * users/{uid}/swipes/{targetUid} 문서가 생성/수정될 때 실행.
 *
 * 처리 흐름:
 * 1. 최신 action이 like/superlike가 아니면 즉시 종료 (pass 스와이프는 무시)
 * 2. 상대방(targetUid)이 현재 유저(uid)를 이미 like/superlike했는지 확인
 * 3. 상호 관심이면 matches/{matchId} 문서를 멱등적으로 생성
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

    // 상대방의 역방향 스와이프 확인 (admin SDK → 보안 규칙 우회)
    const reverseDoc = await db
      .collection('users')
      .doc(targetUid)
      .collection('swipes')
      .doc(uid)
      .get();

    if (!reverseDoc.exists || !isPositiveSwipe(reverseDoc.data()?.action)) {
      return null;
    }

    // matchId는 정렬된 순서로 — 두 유저 어느 쪽이 먼저 like해도 같은 ID
    const participants = [uid, targetUid].sort();
    const matchId = participants.join('_');
    const matchRef = db.collection('matches').doc(matchId);

    // 이미 매칭됐으면 다시 만들지 않는다 (멱등 처리)
    const existing = await matchRef.get();
    if (existing.exists) return null;

    await matchRef.set({
      participants,
      uid1: participants[0],
      uid2: participants[1],
      matchedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    return null;
  },
);

/** like와 superlike는 모두 매칭을 만들 수 있는 긍정 반응이다. */
function isPositiveSwipe(action) {
  return action === 'like' || action === 'superlike';
}

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

    const narrative = await callOpenAiForNarrative({
      systemPrompt: fortuneSystemPrompt(),
      userPayload: { 속성: attrs },
    });

    if (!isValidNarrative(narrative)) {
      throw new HttpsError('internal', 'GPT 응답 형식이 올바르지 않습니다.');
    }
    narrative.relationshipStory = null; // 개인 서사는 항상 null로 고정

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

    const narrative = await callOpenAiForNarrative({
      systemPrompt: matchSystemPrompt(),
      userPayload: { 속성A: userA, 속성B: userB },
    });

    if (!isValidNarrative(narrative) || typeof narrative.relationshipStory !== 'string') {
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

    const fortune = await callOpenAiForNarrative({
      systemPrompt: dailyFortuneSystemPrompt(),
      userPayload: { 날짜: date, 속성: attrs },
    });

    if (!isValidDailyFortune(fortune)) {
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

const IDEAL_IMAGE_OPTIONS = {
  mood: {
    pure: { ko: '청순한', en: 'soft and innocent mood' },
    chic: { ko: '시크한', en: 'chic and composed mood' },
    playful: { ko: '발랄한', en: 'bright and playful mood' },
    intellectual: { ko: '지적인', en: 'intellectual and thoughtful mood' },
    gentle: { ko: '부드러운', en: 'gentle and warm mood' },
  },
  style: {
    casual: { ko: '캐주얼', en: 'casual everyday outfit' },
    formal: { ko: '포멀', en: 'clean formal outfit' },
    street: { ko: '스트릿', en: 'modern street style outfit' },
    minimal: { ko: '미니멀', en: 'minimal and neat outfit' },
  },
  hair: {
    long_straight: { ko: '긴 생머리', en: 'long straight hair' },
    bob: { ko: '단발', en: 'bob haircut' },
    wavy: { ko: '웨이브', en: 'soft wavy hair' },
    short: { ko: '숏컷', en: 'short haircut' },
    two_block: { ko: '투블럭', en: 'neat two-block haircut' },
    dandy: { ko: '댄디컷', en: 'clean dandy haircut' },
    medium: { ko: '미디엄 헤어', en: 'medium-length natural hair' },
  },
  impression: {
    bright_smile: { ko: '밝은 미소', en: 'bright friendly smile' },
    calm: { ko: '무심한', en: 'calm and understated expression' },
    warm: { ko: '따뜻한', en: 'warm and approachable expression' },
  },
  background: {
    cafe: { ko: '카페', en: 'cozy cafe background' },
    outdoor: { ko: '야외', en: 'natural outdoor background' },
    studio: { ko: '스튜디오', en: 'simple studio background' },
    indoor: { ko: '실내', en: 'comfortable indoor background' },
  },
};

const IDEAL_HAIR_BY_GENDER = {
  male: ['short', 'two_block', 'dandy', 'medium'],
  female: ['long_straight', 'bob', 'wavy', 'short'],
  all: ['long_straight', 'bob', 'wavy', 'short', 'two_block', 'dandy', 'medium'],
};

// OpenAI 계정/조직 권한에 따라 사용 가능한 이미지 모델은 달라질 수 있다.
// 배포 후 "model does not exist"가 계속되면 OpenAI 대시보드에서 접근 가능한 모델명을 확인한다.
const IDEAL_IMAGE_MODEL = 'gpt-image-1';

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
  return {
    gender,
    idealTags,
    mood: optionValue('mood', data?.mood, 'gentle'),
    style: optionValue('style', data?.style, 'casual'),
    hair: optionValue('hair', hairKey, fallbackHair),
    impression: optionValue('impression', data?.impression, 'warm'),
    background: optionValue('background', data?.background, 'studio'),
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

function idealImageHash(input) {
  return crypto
    .createHash('sha256')
    .update(
      JSON.stringify({
        gender: input.gender,
        idealTags: input.idealTags,
        mood: input.mood.key,
        style: input.style.key,
        hair: input.hair.key,
        impression: input.impression.key,
        background: input.background.key,
      }),
    )
    .digest('hex');
}

function buildIdealImagePrompt(input) {
  const tagText = tagLabels(input.idealTags)
    .filter((label) => !['예쁘고 잘생긴'].includes(label))
    .join(', ');
  const tagClause = tagText
    ? `Preference cues interpreted as personality and styling mood only: ${tagText}.`
    : 'Preference cues should remain broad and non-specific.';
  return [
    `A gentle stylized portrait illustration of one ${idealGenderPrompt(input.gender)} as an original fictional character.`,
    'The character is not a real individual, not a celebrity, not an app user, and not based on any identifiable person.',
    `${input.mood.en}, ${input.style.en}, ${input.hair.en}, ${input.impression.en}, ${input.background.en}.`,
    tagClause,
    'Soft editorial illustration, tasteful, non-sexual, adult, single character, simple natural lighting.',
    'Avoid realistic identity details, biometric specificity, logos, names, usernames, or identifying marks.',
  ].join(' ');
}

async function fetchImageBytes(imageUrl) {
  const response = await fetch(imageUrl);
  if (!response.ok) {
    throw new Error(`이미지 URL 다운로드 실패 status=${response.status}`);
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
 * AI 이상형 이미지 생성 (callable).
 *
 * 입력: { gender, idealTags, mood, style, hair, impression, background }
 * 캐싱: users/{uid}.idealTypeImage.inputHash가 같으면 Storage URL을 재사용한다.
 */
exports.generateIdealTypeImage = onCall(
  { secrets: [OPENAI_API_KEY], timeoutSeconds: 120, memory: '1GiB' },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError('unauthenticated', '로그인이 필요합니다.');
    }

    const input = normalizeIdealImageInput(request.data || {});
    const inputHash = idealImageHash(input);
    const userRef = db.collection('users').doc(request.auth.uid);
    const userSnap = await userRef.get();
    if (!userSnap.exists) {
      throw new HttpsError('not-found', '프로필을 찾을 수 없습니다.');
    }

    const cached = userSnap.data()?.idealTypeImage;
    if (
      cached &&
      cached.inputHash === inputHash &&
      typeof cached.imageUrl === 'string' &&
      cached.imageUrl
    ) {
      return cached;
    }

    const client = new OpenAI({ apiKey: OPENAI_API_KEY.value() });
    const prompt = buildIdealImagePrompt(input);
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
        imageBuffer = await fetchImageBytes(imageData.url);
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

    const uploaded = await uploadIdealImage({
      uid: request.auth.uid,
      inputHash,
      imageBuffer,
    });
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
      revisedPrompt: imageData?.revised_prompt || null,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    };

    await userRef.set({ idealTypeImage: result }, { merge: true });
    return {
      ...result,
      createdAt: null,
    };
  },
);

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
