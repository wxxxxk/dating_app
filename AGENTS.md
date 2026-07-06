# AGENTS.md / CLAUDE.md

이 문서는 다음 AI 세션(Codex / Claude Code)이 프로젝트 전체 맥락을 바로 이해하도록 만든 현재 상태 스냅샷이다. `CLAUDE.md`는 `AGENTS.md` 심볼릭 링크이므로 실제 원본은 이 파일 하나다. 코드가 바뀌면 이 문서도 같이 갱신한다.

최종 코드 기준 확인일: 2026-07-06

## 1. 프로젝트 개요

- **이름**: `dating_app`
- **목적**: AI 사주 기반 데이팅 앱. 현재는 발표/시연 준비 단계이며, 핵심 매칭 루프와 AI 확장 기능이 대부분 구현돼 있다.
- **Firebase 프로젝트**: `cvr-dating-app` (`.firebaserc`, `firebase.json`)
- **앱 스택**: Flutter/Dart, Firebase Auth, Cloud Firestore, Firebase Storage, Cloud Functions, Firebase Messaging 의존성, Google Sign-In
- **AI 스택**: Cloud Functions에서 OpenAI 호출. 앱에는 `OPENAI_API_KEY`가 없다.
- **주요 패키지**: `cloud_firestore`, `firebase_auth`, `firebase_storage`, `cloud_functions`, `google_sign_in`, `image_picker`, `saju`, `timezone`, `share_plus`, `geolocator`, `in_app_purchase`
- **Functions 런타임**: Node.js 20, `firebase-functions` v6, `firebase-admin` v12, `openai` v6
- **저장소**: GitHub `github.com/wxxxxk/dating_app` private, 기본 브랜치 `main`

## 2. 현재 구현 완료 기능

### 인증 / 프로필

- ✅ 이메일 회원가입/로그인, 이메일 인증 메일 발송/확인
- ✅ Google 로그인
- ✅ 전화번호 인증: `phone_login_screen.dart`, `otp_verification_screen.dart`, `AuthService.signInWithPhone()`
- ✅ 인증 배지: `users/{uid}.verifications.{email,phone,photo}` 기반 표시. 이메일/전화는 현재 UI 연결, 사진 인증은 자리만 있음.
- ✅ 온보딩: 기본 정보, 상세 정보, 태그, 관계 목표, 사진 업로드
- ✅ 프로필 편집/조회, 상대 프로필 상세 화면
- ✅ 다중 사진: `photoUrls`, 카드/상세 화면에서 좌우 탭 및 PageView 전환

### Discovery / Match

- ✅ Tinder 스타일 스와이프 카드
- ✅ pass / like / superlike 액션
- ✅ superlike는 젤리 소모와 매칭 판정에 연결
- ✅ 위치 권한/현재 위치 저장, Haversine 거리 계산, 카드 거리 표시
- ✅ 나이/거리/성별 필터 저장: `users/{uid}.discoveryFilter`
- ✅ 부스트: `users/{uid}.boostUntil`, 디스커버리 정렬에서 우선 노출
- ✅ 카드 소진 시 pass 유저 재노출 정책
- ✅ 상세 프로필 진입, 신고/차단 메뉴 연결
- ✅ 서버 매칭 판정: `onSwipeCreated`가 상호 like/superlike일 때 `matches/{matchId}` 생성
- ✅ 받은 좋아요 목록: `collectionGroup('swipes')`, superlike 강조, 젤리 게이트 해제

### Chat

- ✅ 실시간 채팅: `matches/{matchId}/messages`
- ✅ `createdAt` 오름차순 정렬, 최신 메시지가 아래로 표시
- ✅ 날짜 Divider: 오늘/어제/월일 구분선
- ✅ 같은 분 연속 메시지는 마지막 말풍선에만 시간 표시
- ✅ Bubble Group: single/top/middle/bottom radius 처리
- ✅ Typing Indicator 컴포넌트 구조: 현재는 `_isOtherTyping` mock bool, 실제 서버 이벤트는 미연결
- ✅ AppBar 아래 온라인 상태 mock 표시
- ✅ 새 메시지 Fade + Slide 애니메이션
- ✅ 빈 채팅방 아이스브레이커 카드
- ✅ 매칭 목록 마지막 메시지 시간/안읽음 뱃지: `matches/{matchId}.lastMessage`, `lastReadAtByUid.{uid}` 기반

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
- ✅ Charm Report: `generateCharmReport`, `users/{uid}.charmReport` 캐시
- ✅ Ideal Type Image: `generateIdealTypeImage`, `gpt-image-1`, Storage `users/{uid}/idealType/...png`, `users/{uid}.idealTypeImage` 캐시
- ✅ Ideal Type 안전장치: 가상 인물 프롬프트, 안전 라벨, 실제 앱 사용자가 아님 명시, raw exception UI 노출 방지
- ✅ Daily Fortune: `generateDailyFortune`
- ✅ Fortune Cache 우선 읽기: 앱 서비스 계층에서 Firestore 캐시 확인 후 callable 호출

### Jelly / 수익화 목업

- ✅ 젤리 잔액: `users/{uid}.jelly`
- ✅ 거래 내역: `users/{uid}/jellyTransactions/{txId}`
- ✅ 목업 충전: `kJellyMockPurchases == true`일 때 클라이언트 트랜잭션 충전
- ✅ 실제 IAP 연결 자리: `in_app_purchase`, `JellyPurchaseService`
- ✅ `verifyJellyPurchase` Cloud Function 스켈레톤
- ✅ 소모처: superlike, boost, 받은 좋아요 전체보기 해제

### 안전 / 운영 대응

- ✅ 신고: `reports/{reportId}` 생성, 클라이언트 read 차단
- ✅ 차단: `users/{uid}/blocks/{blockedUid}`, 양방향 숨김에 collectionGroup blocks 사용
- ✅ 차단 적용: 디스커버리, 매칭, 받은 좋아요, 채팅 진입 확인

## 3. 현재 미구현 / 목업

- ❌ 실제 Store 결제 검증: `verifyJellyPurchase`는 현재 항상 성공하는 스켈레톤
- ❌ 젤리/부스트/likesUnlocked 서버 전용 쓰기 규칙
- ❌ AI Profile Insight
- ❌ AI Conversation Coach
- ❌ Rewind
- ❌ Push Notification
- ❌ 사진 메시지
- ❌ 메시지별 Read Receipt
- ❌ 실제 Typing Event 저장/전파
- ❌ 실제 온라인/최근 접속 상태 저장/전파
- ❌ 사진 인증
- ❌ 운영자 신고 검토 콘솔

## 4. 프로젝트 구조

```text
lib/
├── app.dart                         # 서비스 생성/주입, AuthGate, 라우트
├── firebase_options.dart            # FlutterFire 설정
├── core/
│   ├── constants/                   # 앱/프로필 옵션 상수
│   ├── routes/                      # named route 상수
│   ├── theme/                       # AppColors, AppTheme
│   └── utils/                       # validators 등 유틸
├── dev/                             # 더미 데이터 생성. 출시 전 제거/점검 대상
├── features/
│   ├── auth/                        # 이메일/Google/전화 인증 화면
│   ├── charm/                       # 매력 리포트
│   ├── chat/                        # 채팅방 UX
│   ├── discovery/                   # 스와이프, 필터, 부스트, 더미 생성
│   ├── fortune/                     # 사주 허브, 내 사주, 궁합, 운세 기록
│   ├── home/                        # 내 프로필 탭, 오늘의 인연 Hero
│   ├── ideal_type/                  # AI 이상형 이미지
│   ├── jelly/                       # 젤리 상점
│   ├── likes/                       # 받은 좋아요
│   ├── matches/                     # 매칭 목록/축하/채팅 진입
│   ├── onboarding/                  # 초기 프로필 생성
│   ├── profile/                     # 프로필 편집/상대 상세/인증 배지
│   └── safety/                      # 신고/차단 UI
├── models/                          # user_profile, match, message, fortune, charm, ideal_type
├── services/
│   ├── auth/                        # AuthService
│   ├── charm/                       # CharmService
│   ├── chat/                        # ChatService
│   ├── database/                    # FirestoreService
│   ├── discovery/                   # DiscoveryService
│   ├── fortune/                     # FortuneService, FortuneCalculator
│   ├── ideal_type/                  # IdealTypeService
│   ├── jelly/                       # JellyService, JellyPurchaseService
│   ├── likes/                       # LikesService
│   ├── location/                    # LocationService
│   ├── matches/                     # MatchesService
│   ├── safety/                      # SafetyService
│   ├── share/                       # ShareImageService
│   └── storage/                     # StorageService
└── shared/
    ├── state/                       # AuthState
    └── widgets/                     # 공용 버튼/로딩 등

functions/
└── index.js                         # Cloud Functions v2 전체

firestore.rules
firestore.indexes.json
storage.rules
test/
```

## 5. Cloud Functions

`functions/index.js` 기준 exports 8개.

| Function | Trigger | GPT/Image 호출 | 캐시 | 역할 |
|---|---|---:|---|---|
| `onSwipeCreated` | Firestore `onDocumentWritten('users/{uid}/swipes/{targetUid}')` | 아니오 | 해당 없음 | like/superlike 상호 관심 확인 후 `matches/{matchId}` 멱등 생성 |
| `generateFortuneNarrative` | callable | GPT `gpt-4o-mini` | `users/{uid}.fortuneNarrative` | 내 사주 캐릭터/서사 |
| `generateMatchNarrative` | callable | GPT `gpt-4o-mini` | `matches/{matchId}.fortuneMatch` | 두 사람 궁합 서사. participants 권한 확인 |
| `generateIcebreakers` | callable | GPT `gpt-4o-mini` | `matches/{matchId}.icebreakers` | 빈 채팅방 첫 대화 주제 3개 |
| `generateDailyFortune` | callable | GPT `gpt-4o-mini` | `users/{uid}/dailyFortune/{date}` | 날짜별 오늘의 애정운 |
| `generateCharmReport` | callable | GPT `gpt-4o-mini` | `users/{uid}.charmReport` | 프로필 기반 첫인상/매력 분석 |
| `generateIdealTypeImage` | callable, `timeoutSeconds: 120`, `memory: 1GiB` | 이미지 `gpt-image-1` | `users/{uid}.idealTypeImage.inputHash` | 이상형 이미지 생성 후 Storage 저장 |
| `verifyJellyPurchase` | callable | 아니오 | `users/{uid}/jellyTransactions/{transactionId}` 멱등 | IAP 영수증 검증 자리. 현재 검증 함수는 스켈레톤 |

주의:
- 모든 OpenAI 호출은 `OPENAI_API_KEY` Firebase Secret 사용. 앱/저장소에 키 리터럴 금지.
- `functions/index.js`에는 현재 전역 region 설정이 없다. 그대로 배포하면 Firebase 기본 리전이 적용된다.

## 6. Firestore / Storage 구조

### Firestore

- `users/{uid}`
  - 기본 프로필: `displayName`, `birthDate`, `gender`, `bio`, `photoUrls`, 상세정보, 태그, `relationshipGoal`
  - 인증: `verifications: { email, phone, photo }`
  - 위치: `location: { lat, lng, updatedAt, label? }`
  - 필터: `discoveryFilter: { ageMin, ageMax, maxDistanceKm, gender }`
  - AI 캐시: `fortuneNarrative`, `charmReport`, `idealTypeImage`
  - 젤리/수익화: `jelly`, `boostUntil`, `likesUnlocked`
- `users/{uid}/swipes/{targetUid}`
  - `action: 'like' | 'pass' | 'superlike'`, `targetUid`, `actorUid`, `timestamp`
  - 받은 좋아요는 `collectionGroup('swipes')` + `targetUid == currentUid` + `action in ['like','superlike']`
- `users/{uid}/dailyFortune/{yyyy-MM-dd}`
  - `loveScore`, `mood`, `message`, `advice`
  - write는 rules에서 클라이언트 금지. Cloud Functions admin SDK가 저장
- `users/{uid}/blocks/{blockedUid}`
  - `blockerUid`, `blockedUid`, `createdAt`
  - 양방향 숨김은 `collectionGroup('blocks') where blockedUid == currentUid`
- `users/{uid}/jellyTransactions/{txId}`
  - `type`, `amount`, `reason`, `createdAt`, IAP 경로에서는 `platform`, `productId`, `transactionId`
- `matches/{matchId}`
  - `participants`, `uid1`, `uid2`, `matchedAt`, `lastMessage`
  - 읽음 상태: `lastReadAtByUid.{uid}`. 매칭 목록 안읽음 뱃지 판정에 사용
  - AI 캐시: `fortuneMatch`, `icebreakers`
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

## 7. RELEASE-BLOCKER / 배포 전 필수 처리

1. **dummy rule 제거**
   - `firestore.rules`의 `uid.matches('dummy_.*')` write 예외 2곳
   - 출시 전 반드시 제거하고 `firebase deploy --only firestore:rules`
   - 제거하면 더미 생성/역방향 스와이프 데모는 실패할 수 있음

2. **젤리 client write 위험**
   - 현재 `users/{uid}` 본인 write가 `jelly`, `boostUntil`, `likesUnlocked`까지 열어둔다.
   - `users/{uid}/jellyTransactions`도 본인 write 허용 상태다.
   - 실서비스 전에는 젤리/부스트/해제 관련 쓰기를 Cloud Functions admin SDK로만 제한해야 한다.

3. **`verifyJellyPurchase` 실제 검증**
   - 현재 `verifyWithAppStore()` / `verifyWithGooglePlay()`는 항상 성공 반환.
   - App Store Server API / Google Play Developer API 검증으로 교체 전 프로덕션 금지.

4. **Node 20 Runtime**
   - `functions/package.json`은 Node 20.
   - Node 20 지원 종료 일정 전에 Node 22+ 및 Functions/Admin SDK 메이저 업그레이드 검토 필요.

5. **Cloud Functions region**
   - `functions/index.js`에 `setGlobalOptions({ region: ... })` 또는 함수별 region 없음.
   - 리전 요구가 있으면 배포 전 명시해야 한다.

6. **개발용 코드**
   - `lib/dev/dummy_data_service.dart`
   - Discovery의 더미 생성 버튼
   - Fortune History의 `kDebugMode` 최근 7일 채우기
   - 출시 전 노출 여부 점검 필요

## 8. 개발 원칙

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

## 9. 최근 큰 변경 이력

최근 커밋 기준:

1. `feat: implement phone auth flow (SMS OTP with 60s resend cooldown)`
2. `fix: update ideal image generation model and hide raw errors`
3. `fix: add chat date dividers and clarify message ordering`
4. `fix: add visual floor to ohaeng radar chart`
5. `fix: connect phone verification to profile badges`
6. `fix: tidy discovery app bar actions`
7. `feat: add multi-photo navigation to profile cards`
8. `fix: harden ideal type image error handling`
9. `feat: show AI recommendation reasons on match fortune`
10. `feat: add daily match hero to home screen`
11. `feat: polish chat room messaging UX`

## 10. 다음 개발 우선순위

1. AI Profile Insight
2. Conversation Coach
3. Read Receipt
4. Push Notification
5. Photo Message
6. Rewind
7. Real Store Verification

## 11. 자주 실행하는 검증 명령

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
