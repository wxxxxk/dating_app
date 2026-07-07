# AGENTS.md / CLAUDE.md

이 문서는 다음 AI 세션(Codex / Claude Code)이 프로젝트 전체 상태를 바로 이해하도록 만든 실제 코드 기준 스냅샷이다. `CLAUDE.md`는 `AGENTS.md` 심볼릭 링크이므로 원본은 이 파일 하나다. 코드가 바뀌면 이 문서도 같이 갱신한다.

최종 코드 기준 확인일: 2026-07-07

## 1. 프로젝트 개요

- **이름**: `dating_app`
- **목적**: AI 사주 기반 데이팅 앱. 발표/시연 준비 단계이며 핵심 매칭 루프, AI 확장 기능, FCM, Rewind 목업까지 코드에 들어와 있다.
- **Firebase 프로젝트**: `cvr-dating-app` (`.firebaserc`, `firebase.json`)
- **저장소**: GitHub `github.com/wxxxxk/dating_app` private, 기본 브랜치 `main`
- **앱 스택**: Flutter/Dart, Firebase Auth, Cloud Firestore, Firebase Storage, Cloud Functions, Firebase Messaging, Google Sign-In
- **AI 스택**: Cloud Functions에서만 OpenAI 호출. 앱에는 `OPENAI_API_KEY`가 없다.
- **주요 Flutter 패키지**: `cloud_firestore`, `firebase_auth`, `firebase_storage`, `cloud_functions`, `firebase_messaging`, `google_sign_in`, `image_picker`, `saju`, `timezone`, `share_plus`, `geolocator`, `in_app_purchase`, `crypto`
- **Functions 런타임/의존성**: Node.js 20, `firebase-functions` `^6.0.0`, `firebase-admin` `^12.0.0`, `openai` `^6.45.0`
- **Firebase 옵션 파일**: `lib/firebase_options.dart`는 저장소 주석상 placeholder 성격이다. 실제 실행 환경에서는 `flutterfire configure`로 생성한 값이 필요하다.

## 2. 현재 Git/배포 상태

- 최근 확인한 `git log --oneline -20` 기준 최근 커밋:
  1. `c7a49cd feat: add AI conversation coach for stalled chats`
  2. `146e543 feat: add FCM match and message notifications`
  3. `155bf78 feat: add AI profile insight card`
  4. `2292261 feat: add match list message time and unread badge`
  5. `f0ab034 docs: refresh project context and add AI working rules for agents`
- 현재 워킹트리에는 Rewind 관련 코드 변경과 이 AGENTS 갱신이 커밋되지 않은 상태다.
- 이 세션에서 `firebase deploy`는 실행하지 않았다. `functions/index.js` 변경 사항은 Firebase에 별도 배포가 필요하다.
- 배포 필요 항목: `generateProfileInsight`, `onMessageCreated`, `generateConversationTips`, `onSwipeCreated` Rewind race 방어 보강. Rewind 클라이언트 코드는 앱 재빌드/배포도 필요하다.
- `CLAUDE.md`는 `CLAUDE.md -> AGENTS.md` 심볼릭 링크 상태로 확인됐다.

## 3. 구현 완료 기능

### 인증 / 프로필

- ✅ 이메일 회원가입/로그인, 이메일 인증 메일 발송/확인
- ✅ Google 로그인
- ✅ 전화번호 인증: `phone_login_screen.dart`, `otp_verification_screen.dart`, `AuthService.signInWithPhone()`
- ✅ 인증 배지: `users/{uid}.verifications.{email,phone,photo}` 기반. 이메일/전화 UI 연결 완료, 사진 인증은 자리만 있음
- ✅ 온보딩: 기본 정보, 상세 정보, 태그, 관계 목표, 사진 업로드
- ✅ 프로필 편집/조회, 상대 프로필 상세 화면
- ✅ 다중 사진: `photoUrls`, 카드/상세 화면에서 좌우 탭 및 PageView 전환
- ✅ AI Profile Insight 카드: 상대 프로필 상세 화면 하단에서 로딩/실패/재시도 처리

### Discovery / Match

- ✅ Tinder 스타일 스와이프 카드
- ✅ pass / like / superlike 액션
- ✅ superlike는 `JellyCosts.superlike = 5` 소모 후 swipe 기록
- ✅ Rewind: 세션 내 직전 `pass`/`like` 1개만 `JellyCosts.rewind = 3` 소모로 되돌림. `superlike`는 제외
- ✅ Rewind 트랜잭션: `JellyService.rewindSwipe()`가 젤리 차감, `jellyTransactions` 기록(`reason: 'rewind'`), `users/{uid}/swipes/{targetUid}` 삭제를 단일 Firestore transaction으로 처리
- ✅ Rewind 정합성 방어: `onSwipeCreated`가 매칭 생성 직전 현재 swipe 문서와 역방향 swipe 문서를 transaction 안에서 재확인. Rewind로 삭제된 like가 뒤늦게 매칭되는 race를 방지
- ✅ 위치 권한/현재 위치 저장, Haversine 거리 계산, 카드 거리 표시
- ✅ 나이/거리/성별 필터 저장: `users/{uid}.discoveryFilter`
- ✅ 부스트: `users/{uid}.boostUntil`, 디스커버리 정렬에서 우선 노출
- ✅ 카드 소진 시 pass 유저 재노출 정책
- ✅ 상세 프로필 진입, 신고/차단 메뉴 연결
- ✅ 서버 매칭 판정: `onSwipeCreated`가 상호 like/superlike일 때 `matches/{matchId}` 멱등 생성
- ✅ 매칭 성사 FCM: `onSwipeCreated`가 양쪽에게 "새로운 매칭!" 푸시 전송
- ✅ 받은 좋아요 목록: `collectionGroup('swipes')`, superlike 강조, 젤리 게이트 해제

### Chat

- ✅ 실시간 채팅: `matches/{matchId}/messages`
- ✅ `createdAt` 오름차순 정렬, 최신 메시지가 아래로 표시
- ✅ 채팅 날짜 Divider: 오늘/어제/월일 구분선
- ✅ 같은 분 연속 메시지는 마지막 말풍선에만 시간 표시
- ✅ Bubble Group: single/top/middle/bottom radius 처리
- ✅ Typing Indicator 컴포넌트 구조: 현재는 `_isOtherTyping` mock bool, 실제 서버 이벤트는 미연결
- ✅ AppBar 아래 온라인 상태 mock 표시
- ✅ 새 메시지 Fade + Slide 애니메이션
- ✅ 빈 채팅방 아이스브레이커 카드: `generateIcebreakers`
- ✅ AI 대화 코치: 메시지가 1개 이상인 채팅방에서 입력창 위 `대화 이어가기` 버튼으로 `generateConversationTips` 호출
- ✅ AI 대화 코치 UX: 제안 탭 시 `_fillInput()`으로 입력창에만 채움, 바로 전송하지 않음. 로딩/실패/재시도 처리
- ✅ 매칭 목록 마지막 메시지 시간/안읽음 뱃지: `matches/{matchId}.lastMessage`, `lastReadAtByUid.{uid}` 기반
- ✅ 채팅 진입 및 새 메시지 수신 시 `ChatService.markMatchRead()`로 `lastReadAtByUid.{uid}` 갱신
- ✅ 새 메시지 FCM: `onMessageCreated`가 수신자에게 "새 메시지" 푸시 전송

### FCM / Notifications

- ✅ `firebase_messaging` 의존성 포함
- ✅ 앱 시작 후 `NotificationService.initialize()`가 foreground/opened/initial message 처리
- ✅ 로그인 유저에 대해 FCM 토큰을 `users/{uid}.fcmTokens` 배열에 저장, 갱신 시 arrayUnion
- ✅ invalid token은 Functions에서 `arrayRemove`
- ✅ foreground 메시지는 SnackBar로 표시하고 "열기" 액션 제공
- ✅ 알림 탭 이동: `type: 'match'`는 매칭 탭, `type: 'chat'`는 해당 채팅방으로 이동
- ✅ Android 우선 구현. iOS 실기기 푸시는 APNs Auth Key 등록 필요 주석이 코드에 있음
- ✅ Background handler: `main.dart` top-level `@pragma('vm:entry-point') firebaseMessagingBackgroundHandler`

### Fortune / AI 사주

- ✅ 사주/별자리 계산: `fortune_calculator.dart`
- ✅ 오행 레이더 차트: 시각적 floor 적용, 실제 퍼센트 라벨은 원본값 유지
- ✅ 내 사주 서사: `generateFortuneNarrative`, `users/{uid}.fortuneNarrative` 캐시
- ✅ 궁합 서사: `generateMatchNarrative`, `matches/{matchId}.fortuneMatch` 캐시
- ✅ AI 추천 이유: `MatchFortuneScreen`에서 궁합 narrative reasons를 bullet/chip 형태로 표시
- ✅ 오늘의 운세: `generateDailyFortune`, `users/{uid}/dailyFortune/{yyyy-MM-dd}` 캐시
- ✅ 운세 히스토리/그래프, debug 전용 최근 7일 채우기
- ✅ 사주 기반 채팅 아이스브레이커: `generateIcebreakers`, `matches/{matchId}.icebreakers` 캐시
- ✅ 오늘의 인연 Hero: HomeScreen 상단에서 기존 매치 캐시/규칙 기반 궁합/Discovery 후보를 새 GPT 호출 없이 표시
- ✅ 사주/궁합 결과 공유 카드: `ShareImageService`, `share_plus`, 오프스크린 렌더링

### AI 확장

- ✅ Match Narrative: `generateMatchNarrative`
- ✅ Ice Breaker: `generateIcebreakers`
- ✅ Conversation Coach: `generateConversationTips`, `matches/{matchId}.conversationTips.lastMessageId` 짧은 캐시
- ✅ AI Profile Insight: `generateProfileInsight`, GPT `gpt-4o` Vision, `users/{targetUid}.profileInsight.inputHash` 캐시
- ✅ Profile Insight 외모 평가 금지: 프롬프트에 외모 점수/등급/신체 평가 금지, 사진은 표정/분위기/상황 맥락만 사용
- ✅ Charm Report: `generateCharmReport`, `users/{uid}.charmReport` 캐시
- ✅ Ideal Type Image: `generateIdealTypeImage`, 이미지 모델 `gpt-image-1`, Storage `users/{uid}/idealType/...png`, `users/{uid}.idealTypeImage.inputHash` 캐시
- ✅ Ideal Type 안전장치: 가상 인물 프롬프트, 실제 앱 사용자가 아님 명시, raw exception UI 노출 방지
- ✅ Daily Fortune: `generateDailyFortune`
- ✅ Fortune Cache 우선 읽기: 앱 서비스 계층에서 Firestore 캐시 확인 후 callable 호출

### Jelly / 수익화 목업

- ✅ 젤리 잔액: `users/{uid}.jelly`
- ✅ 거래 내역: `users/{uid}/jellyTransactions/{txId}`
- ✅ 목업 충전: `kJellyMockPurchases == true`일 때 클라이언트 트랜잭션 충전
- ✅ 실제 IAP 연결 자리: `in_app_purchase`, `JellyPurchaseService`
- ✅ `verifyJellyPurchase` Cloud Function 스켈레톤
- ✅ 소모처: superlike, rewind, boost, 받은 좋아요 전체보기 해제
- ✅ 비용 상수: `superlike = 5`, `rewind = 3`, `boost = 30`, `unlockReceivedLikes = 20`, `boostDuration = 30분`

### 안전 / 운영 대응

- ✅ 신고: `reports/{reportId}` 생성, 클라이언트 read 차단
- ✅ 차단: `users/{uid}/blocks/{blockedUid}`, 양방향 숨김에 collectionGroup blocks 사용
- ✅ 차단 적용: 디스커버리, 매칭, 받은 좋아요, 채팅 진입 확인
- ✅ 사용자 화면 raw exception/stack trace 노출 방지 작업이 주요 화면에 반영됨. 새 작업 시 계속 확인 필요

## 4. 현재 미구현 / 목업

- ❌ 실제 Store 결제 검증: `verifyJellyPurchase`는 현재 항상 성공하는 스켈레톤
- ❌ 젤리/부스트/되돌리기/likesUnlocked 서버 전용 쓰기 규칙
- ❌ 사진 메시지
- ❌ 메시지별 Read Receipt
- ❌ 실제 Typing Event 저장/전파
- ❌ 실제 온라인/최근 접속 상태 저장/전파
- ❌ 사진 인증
- ❌ 운영자 신고 검토 콘솔
- ❌ Daily Recommendation/추천 노출 제한 정책
- ❌ Rewind 서버 전용 callable화. 현재 Rewind는 클라이언트 Firestore transaction 기반 목업 흐름이다

## 5. 프로젝트 구조

```text
lib/
├── app.dart                         # 서비스 생성/주입, AuthGate, 라우트
├── main.dart                        # Firebase init, FCM background handler 등록
├── firebase_options.dart            # FlutterFire 설정 placeholder 성격
├── core/
│   ├── constants/
│   ├── routes/
│   ├── theme/
│   └── utils/
├── dev/                             # 더미 데이터 생성. 출시 전 제거/점검 대상
├── features/
│   ├── auth/
│   ├── charm/
│   ├── chat/
│   ├── discovery/
│   ├── fortune/
│   ├── home/
│   ├── ideal_type/
│   ├── jelly/
│   ├── likes/
│   ├── matches/
│   ├── onboarding/
│   ├── profile/
│   └── safety/
├── models/                          # user_profile, match, message, fortune, charm, ideal_type, profile_insight
├── services/
│   ├── auth/
│   ├── charm/
│   ├── chat/
│   ├── database/
│   ├── discovery/
│   ├── fortune/
│   ├── ideal_type/
│   ├── jelly/
│   ├── likes/
│   ├── location/
│   ├── matches/
│   ├── notifications/               # NotificationService, FCM 토큰/알림 라우팅
│   ├── profile/                     # ProfileInsightService
│   ├── safety/
│   ├── share/
│   └── storage/
└── shared/

functions/
└── index.js                         # Cloud Functions v2 전체

firestore.rules
firestore.indexes.json
storage.rules
test/
```

## 6. Cloud Functions

`functions/index.js` 실제 exports 기준 11개.

| Function | Trigger | GPT/Image 호출 | 캐시 | 역할 |
|---|---|---:|---|---|
| `onSwipeCreated` | Firestore `onDocumentWritten('users/{uid}/swipes/{targetUid}')` | 아니오 | 없음 | like/superlike 상호 관심 확인. transaction 안에서 현재 swipe와 역방향 swipe를 재확인해 Rewind race 방어 후 `matches/{matchId}` 멱등 생성, 양쪽 FCM 매칭 알림 |
| `onMessageCreated` | Firestore `onDocumentCreated('matches/{matchId}/messages/{messageId}')` | 아니오 | 없음 | 새 채팅 메시지 생성 시 수신자 FCM 알림. data: `type=chat`, `matchId`, `senderUid` |
| `generateFortuneNarrative` | callable | GPT `gpt-4o-mini` | `users/{uid}.fortuneNarrative` | 내 사주 캐릭터/서사 |
| `generateMatchNarrative` | callable | GPT `gpt-4o-mini` | `matches/{matchId}.fortuneMatch` | 두 사람 궁합 서사. participants 권한 확인 |
| `generateIcebreakers` | callable | GPT `gpt-4o-mini` | `matches/{matchId}.icebreakers` | 빈 채팅방 첫 대화 주제 3개 |
| `generateConversationTips` | callable | GPT `gpt-4o-mini` | `matches/{matchId}.conversationTips.lastMessageId` | 최근 메시지 8개 기반 대화 재개 문장 2~3개 |
| `generateDailyFortune` | callable | GPT `gpt-4o-mini` | `users/{uid}/dailyFortune/{date}` | 날짜별 오늘의 애정운 |
| `generateCharmReport` | callable | GPT `gpt-4o-mini` | `users/{uid}.charmReport` | 프로필 기반 첫인상/매력 분석 |
| `generateProfileInsight` | callable | GPT `gpt-4o` Vision | `users/{targetUid}.profileInsight.inputHash` | 상대 프로필 사진/소개/태그/MBTI/사주 기반 비외모 인사이트 |
| `generateIdealTypeImage` | callable, `timeoutSeconds: 120`, `memory: 1GiB` | 이미지 `gpt-image-1` | `users/{uid}.idealTypeImage.inputHash` | 이상형 이미지 생성 후 Storage 저장 |
| `verifyJellyPurchase` | callable | 아니오 | `users/{uid}/jellyTransactions/{transactionId}` 멱등 | IAP 영수증 검증 자리. 현재 검증 함수는 항상 valid 반환하는 스켈레톤 |

주의:
- 모든 OpenAI 호출은 `OPENAI_API_KEY` Firebase Secret 사용. 앱/저장소에 키 리터럴 금지.
- `functions/index.js`에는 현재 전역 region 설정이 없다. 그대로 배포하면 Firebase 기본 리전이 적용된다.
- FCM 전송은 Admin SDK `sendEachForMulticast()` 사용. invalid token은 `users/{uid}.fcmTokens`에서 제거한다.

## 7. Firestore / Storage 구조

### Firestore

- `users/{uid}`
  - 기본 프로필: `displayName`, `birthDate`, `gender`, `bio`, `photoUrls`, `createdAt`, `updatedAt`
  - 상세 프로필: `height`, `religion`, `smoking`, `drinking`, `jobCategory`, `jobTitle`, `education`, `mbti`
  - 태그/목표: `interests`, `personalityTags`, `idealTags`, `relationshipGoal`, `personaVector?`
  - 인증: `verifications: { email, phone, photo }`
  - 위치: `location: { lat, lng, updatedAt, label? }`
  - 필터: `discoveryFilter: { ageMin, ageMax, maxDistanceKm, gender }`
  - 푸시 토큰: `fcmTokens`, `fcmTokenUpdatedAt`
  - AI 캐시: `fortuneNarrative`, `charmReport`, `profileInsight`, `idealTypeImage`
  - 젤리/수익화: `jelly`, `boostUntil`, `likesUnlocked`
- `users/{uid}/swipes/{targetUid}`
  - `action: 'like' | 'pass' | 'superlike'`, `targetUid`, `actorUid`, `timestamp`
  - 받은 좋아요는 `collectionGroup('swipes')` + `targetUid == currentUid` + `action in ['like','superlike']`
  - Rewind는 직전 pass/like에 한해 젤리 3개 차감과 함께 이 문서를 transaction으로 삭제
- `users/{uid}/dailyFortune/{yyyy-MM-dd}`
  - `loveScore`, `mood`, `message`, `advice`
  - write는 rules에서 클라이언트 금지. Cloud Functions admin SDK가 저장
- `users/{uid}/blocks/{blockedUid}`
  - `blockerUid`, `blockedUid`, `createdAt`
  - 양방향 숨김은 `collectionGroup('blocks') where blockedUid == currentUid`
- `users/{uid}/jellyTransactions/{txId}`
  - 공통: `type`, `amount`, `reason`, `createdAt`
  - IAP 경로: `platform`, `productId`, `transactionId`
  - Rewind 경로: `type: 'spend'`, `amount: -3`, `reason: 'rewind'`
- `matches/{matchId}`
  - `participants`, `uid1`, `uid2`, `matchedAt`
  - `lastMessage: { text, senderId, createdAt }`
  - 읽음 상태: `lastReadAtByUid.{uid}`. 매칭 목록 안읽음 뱃지 판정에 사용
  - AI 캐시: `fortuneMatch`, `icebreakers`, `conversationTips`
- `matches/{matchId}/messages/{messageId}`
  - `senderId`, `text`, `createdAt`
  - update/delete는 아직 금지
- `reports/{reportId}`
  - `reporterUid`, `reportedUid`, `reason`, `detail?`, `createdAt`
  - 클라이언트 create만 허용, read/update/delete 금지

### Indexes / Rules

- `matches`: `participants arrayContains + matchedAt desc`
- `swipes` collectionGroup: `targetUid asc + action asc + timestamp desc`
- `blocks` collectionGroup field override: `blockedUid asc`
- `firestore.rules`에 RELEASE-BLOCKER 주석이 남아 있다. 배포 전 반드시 검색할 것.

### Storage

- `users/{uid}/{allPaths=**}`: 인증 유저 read, 본인 write
- 프로필 사진과 AI 이상형 이미지(`users/{uid}/idealType/...png`)가 이 경로를 사용

## 8. RELEASE-BLOCKER / 배포 전 필수 처리

`rg "RELEASE-BLOCKER|verifyWith|dummy_|firebase-admin|firebase-functions" firestore.rules functions/index.js functions/package.json` 기준 실제 확인 사항이다.

1. **dummy rule 제거**
   - `firestore.rules`에 `uid.matches('dummy_.*')` write 예외 2곳:
     - `users/{uid}` 문서 write
     - `users/{uid}/swipes/{targetUid}` write
   - 출시 전 반드시 제거하고 `firebase deploy --only firestore:rules`.
   - 제거하면 더미 생성/역방향 스와이프 데모는 실패하거나 즉시 매칭 데모 효과가 사라질 수 있음.

2. **users/{uid} 전체 write 허용**
   - 현재 `allow write: if request.auth != null && request.auth.uid == uid;`가 `users/{uid}` 전체 필드를 열어둔다.
   - 이 상태에서는 클라이언트가 `jelly`, `boostUntil`, `likesUnlocked`, `fcmTokens` 등도 직접 조작 가능하다.
   - 실서비스 전에는 프로필 편집 허용 필드만 좁히고, 재화/수익화 필드는 서버 전용으로 분리해야 한다.
   - rules hardening 때 `fcmTokens`, `fcmTokenUpdatedAt`은 본인 기기 토큰 등록을 위해 허용 필드에 포함해야 한다.
   - `matches/{matchId}.lastReadAtByUid.{uid}`는 현재 별도 map diff 규칙으로 본인 uid 키만 갱신 가능하다. rules hardening 때 이 허용 범위를 유지해야 매칭 목록 안읽음 처리가 깨지지 않는다.

3. **젤리 client write 위험**
   - `users/{uid}.jelly`, `boostUntil`, `likesUnlocked`가 users 전체 write 허용에 포함된다.
   - `users/{uid}/jellyTransactions/{txId}`도 현재 본인 read/write 허용이다.
   - Rewind도 현재 클라이언트 transaction으로 `jelly`와 `jellyTransactions`를 쓴다.
   - 실서비스 전에는 superlike/boost/rewind/unlock 관련 쓰기를 Cloud Functions admin SDK로만 제한해야 한다.

4. **`verifyJellyPurchase` 실제 검증**
   - `functions/index.js`의 `verifyWithAppStore()` / `verifyWithGooglePlay()`는 현재 항상 `{ valid: true }`를 반환한다.
   - App Store Server API / Google Play Developer API 검증으로 교체 전 프로덕션 금지.

5. **Functions 런타임/의존성 업그레이드**
   - `functions/package.json`은 Node 20, `firebase-admin` `^12.0.0`, `firebase-functions` `^6.0.0`.
   - Node 20 런타임 종료 일정 전에 Node 22+ 검토 필요.
   - Firebase Functions/Admin SDK는 메이저 업그레이드 검토 필요: `firebase-admin` 12 → 14, `firebase-functions` 6 → 7.

6. **Cloud Functions region**
   - `functions/index.js`에 `setGlobalOptions({ region: ... })` 또는 함수별 region 없음.
   - 리전 요구가 있으면 배포 전 명시해야 한다.

7. **미배포 상태**
   - 이 세션에서 `firebase deploy`는 실행하지 않았다.
   - Firebase Functions 배포 필요: `generateProfileInsight`, `onMessageCreated`, `generateConversationTips`, `onSwipeCreated` Rewind race 방어 보강.
   - Firestore rules는 이번 Rewind 작업에서 수정하지 않았지만, 기존 RELEASE-BLOCKER가 남아 있다.

8. **개발용 코드**
   - `lib/dev/dummy_data_service.dart`
   - Discovery의 더미 생성 버튼
   - Fortune History의 `kDebugMode` 최근 7일 채우기
   - 출시 전 노출 여부 점검 필요

## 9. 개발 원칙

- 기존 구조와 서비스 계층을 우선 재사용한다.
- 새 GPT 호출은 최소화한다. 이미 있는 narrative/cache/규칙 계산으로 해결 가능한지 먼저 본다.
- Firestore 캐시 우선, callable은 캐시 miss일 때만 호출한다.
- 새 Firestore 구조는 최소화한다. 기존 문서/필드로 해결 가능한지 먼저 판단한다.
- UI보다 안정성을 우선한다. 실패해도 화면 전체가 깨지지 않아야 한다.
- 사용자 화면에 raw exception, FirebaseFunctionsException 전체 문자열, stack trace를 노출하지 않는다.
- 상세 에러 로그는 `kDebugMode`에서만 `debugPrint`로 남긴다.
- OpenAI API 키, 스토어 키, 서비스 계정 키는 절대 앱/저장소에 넣지 않는다.
- 디자인은 `AppColors`, 기존 버튼/카드 스타일 등 프로젝트 토큰을 재사용한다.
- `flutter analyze`는 `No issues found!` 상태를 유지한다.
- 변경 후 가능한 경우 `flutter test` 전체 통과를 확인한다.
- 커밋은 사용자가 명시적으로 요청할 때만 한다.

## 10. 최근 변경 이력

최근 커밋 및 현재 워킹트리 기준 시간순:

1. `513d5dc feat: implement phone auth flow (SMS OTP with 60s resend cooldown)`
2. `8eaad2f fix: update ideal image generation model and hide raw errors`
3. `dcc9b72 fix: add chat date dividers and clarify message ordering`
4. `45e9f30 fix: add visual floor to ohaeng radar chart`
5. `2e2087e fix: connect phone verification to profile badges`
6. `de729ac fix: tidy discovery app bar actions`
7. `32a2bc9 feat: add multi-photo navigation to profile cards`
8. `a34600b fix: harden ideal type image error handling`
9. `a614fba feat: show AI recommendation reasons on match fortune`
10. `62368af feat: add daily match hero to home screen`
11. `c70d05c feat: polish chat room messaging UX`
12. `f0ab034 docs: refresh project context and add AI working rules for agents`
13. `2292261 feat: add match list message time and unread badge`
14. `155bf78 feat: add AI profile insight card`
15. `146e543 feat: add FCM match and message notifications`
16. `c7a49cd feat: add AI conversation coach for stalled chats`
17. 현재 워킹트리: Rewind 되돌리기 구현 및 `onSwipeCreated` race 방어 보강. 아직 커밋되지 않음

## 11. 다음 개발 우선순위

실제 코드에 아직 없는 항목만 남긴다.

1. 실제 Store 결제 검증
2. 젤리/수익화 서버 전용 write hardening
3. Photo Message
4. 메시지별 Read Receipt
5. Daily Recommendation/추천 노출 제한 정책
6. 실제 Typing Event
7. 실제 온라인/최근 접속 상태
8. 사진 인증
9. 운영자 신고 검토 콘솔

## 12. 자주 실행하는 검증 명령

```bash
flutter analyze
flutter test
node --check functions/index.js
firebase deploy --only functions
firebase deploy --only firestore:rules
firebase deploy --only firestore:indexes
```

서버 배포가 필요한 변경:
- `functions/index.js` 수정 → `firebase deploy --only functions`
- `firestore.rules` 수정 → `firebase deploy --only firestore:rules`
- `firestore.indexes.json` 수정 → `firebase deploy --only firestore:indexes`
- `storage.rules` 수정 → Firebase CLI에 storage target이 있으면 `firebase deploy --only storage`

## AI Working Rules

이 프로젝트에서 작업하는 모든 AI 에이전트(Claude Code, Codex)는 아래 원칙을 반드시 따른다.

1. 구현 전 기존 구조를 먼저 분석한다.
2. 동일 기능이 이미 존재하는지 먼저 확인한다 (중복 구현 금지).
3. 새 Cloud Function보다 기존 Function 재사용을 우선한다.
4. 새 Firestore Collection 생성은 최후의 수단으로 한다.
5. 새 GPT 호출 추가 전 반드시 기존 캐시 구조를 먼저 확인한다.
6. 사용자에게 raw exception, stack trace를 절대 노출하지 않는다.
7. debugPrint는 반드시 kDebugMode에서만 사용한다.
8. flutter analyze와 flutter test가 통과하지 않으면 작업 완료로 간주하지 않는다.
9. 디자인은 기존 Design Token을 재사용한다.
10. 커밋은 항상 사용자 승인 후에만 수행한다.
