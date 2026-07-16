# AGENTS.md / CLAUDE.md

이 문서는 다음 AI 세션(Codex / Claude Code)이 프로젝트 전체 상태를 바로 이해하도록 만든 실제 코드 기준 스냅샷이다. `CLAUDE.md`는 `AGENTS.md` 심볼릭 링크이므로 원본은 이 파일 하나다. 코드가 바뀌면 이 문서도 같이 갱신한다.

최종 코드 기준 확인일: 2026-07-09

## 1. 프로젝트 개요

- **이름**: `dating_app`
- **목적**: AI 사주 기반 데이팅 앱. 발표/시연 준비 단계이며 핵심 매칭 루프, AI 확장 기능(사주/궁합/AI 이상형), FCM, Rewind/Unmatch, 젤리 수익화 목업까지 코드에 들어와 있다.
- **Firebase 프로젝트**: `cvr-dating-app` (`.firebaserc`, `firebase.json`)
- **Cloud Functions 리전**: `asia-northeast3` (`functions/index.js`의 `setGlobalOptions({ region: 'asia-northeast3' })`으로 전역 고정됨)
- **저장소**: GitHub `github.com/wxxxxk/dating_app` private, 기본 브랜치 `main`
- **Android 식별자**: `applicationId` / `namespace` 모두 `com.cvrlab.dating_app` (`android/app/build.gradle.kts`)
- **앱 스택**: Flutter/Dart, Firebase Auth, Cloud Firestore, Firebase Storage, Cloud Functions, Firebase Messaging, Google Sign-In
- **AI 스택**: Cloud Functions에서만 외부 AI API 호출(OpenAI GPT + fal.ai FLUX). 앱에는 `OPENAI_API_KEY`/`FAL_KEY` 등 실제 키가 없다.
- **주요 Flutter 패키지**: `cloud_firestore`, `firebase_auth`, `firebase_storage`, `cloud_functions`, `firebase_messaging`, `google_sign_in`, `image_picker`, `saju`, `timezone`, `share_plus`, `geolocator`, `in_app_purchase`, `crypto`
- **Functions 런타임/의존성**: Node.js 20, `firebase-functions` `^6.0.0`, `firebase-admin` `^12.0.0`, `openai` `^6.45.0`
- **Firebase 옵션 파일**: `lib/firebase_options.dart`는 저장소 주석상 placeholder 성격이다. 실제 실행 환경에서는 `flutterfire configure`로 생성한 값이 필요하다.
- **실기기 테스트 배포 방식**:
  - 1번 폰: USB 디버깅 가능, `adb install -r build/app/outputs/flutter-apk/app-release.apk`로 직접 재설치.
  - 2번 폰: 학교 관리 기기라 USB 디버깅이 막혀 있음. `build/app/outputs/flutter-apk/` 디렉터리에서 `python3 -m http.server 8765`로 로컬 서버를 띄우고, 같은 네트워크에서 `http://10.50.11.14:8765/app-release.apk` URL로 다운로드해 수동 설치. 이 IP는 로컬 개발망 한정이며 인증 없는 정적 파일 서버이므로 작업이 끝나면 서버 프로세스를 계속 켜둘 필요는 없다.
  - 두 경우 모두 실제 API 키/시크릿 값은 앱에 포함되지 않으므로 APK 자체의 민감정보 위험은 없다.

## 2. 현재 체크포인트 상태 (커밋 없이 대규모 누적)

- 마지막 커밋: `66ca736 fix: align callable functions region and harden FCM registration`
- 이 커밋 이후 **커밋 없이** 약 51개 파일(수정 47 + 신규 4)이 누적되어 있다. 규모는 약 5,740 insertions / 1,416 deletions.
- 신규(untracked) 파일: `lib/features/jelly/jelly_history_screen.dart`, `lib/shared/widgets/premium_components.dart`, `test/ideal_type_model_test.dart`, `test/match_model_test.dart`
- 누적된 주요 변경(커밋되지 않은 상태, 시간순이 아니라 기능 단위):
  1. Share image 캡처 안정화 (`ShareImageService`, release 빌드 `LateInitializationError` 제거)
  2. Fortune GPT 응답 sanitize (`sanitizeNarrative`/`sanitizeDailyFortune`, 스키마 불일치 시 안전한 기본값 보정)
  3. AI 이상형 provider abstraction (OpenAI ↔ fal.ai 추상화 계층)
  4. fal.ai FLUX를 기본 provider로 전환 (`ACTIVE_IDEAL_IMAGE_PROVIDER = fal_flux`)
  5. AI 이상형 성별별 옵션 taxonomy (mood/style/hair/impression을 남성/여성/상관없음별로 분리)
  6. `refinementText` 자유 입력 필드 추가 (최대 100자, 서버 sanitize)
  7. provider-aware 캐시 + `promptVersion` 해시 반영
  8. `generateIdealTypeImageProviderPreview` 개발자용 비교 callable 추가
  9. unmatch / `celebratedBy` / 안읽음 배지(`watchUnreadMatchCount`) 등 매칭 생명주기 기능
  10. Rewind 후속 안정화 (`_RewindCandidate.action`, `rewindEntryToken` 재진입 방지)
  11. Discovery `relationshipGoal` 필터 추가
  12. Discovery 카드 사진 로딩 skeleton/fallback 안정화
  13. Jelly 거래 내역 화면(`jelly_history_screen.dart`) / 혜택 요약 카드
  14. 프로필 편집 화면 사진 관리 기능(대표 설정/교체/삭제)
  15. Design Overhaul Phase 1~4 (토큰/공통 컴포넌트/화면별 적용, 아직 완성형 아님 — 10장 참고)
  16. 온보딩 raw exception 노출 제거
  17. 온보딩/프로필 상세 디자인 개선 (Design Phase 4)
  18. **Design Overhaul Phase 5** — 비비드 민트 시그니처 + 하이브리드 다크 히어로 (10장 "Phase 5 적용 완료" 참고). `AppColors.primary`가 seal red → mintDeep으로 repoint됨. 토큰/테마/핵심 화면 광범위 수정
  19. `VerificationBadges` 오버플로우 수정 — 매칭 목록 좁은 subtitle에서 배지 Row가 14px 오버플로우로 깨지던 실기기 버그를 `FittedBox(fit: scaleDown)`로 방어 (`verification_badge.dart`)
- **다음 기능 작업 전에 이 누적분을 기능 단위로 커밋 분리하는 checkpoint 작업이 필요하다.** 커밋 분리 시 주의할 혼합 변경 파일: `functions/index.js`(fortune sanitize와 fal.ai 작업이 줄 범위상 분리 가능), `lib/features/profile/profile_edit_screen.dart`(사진 관리 신규 기능 + PremiumSectionCard 리팩터가 같은 파일에 뒤섞임, 가장 위험), `lib/features/discovery/widgets/profile_card_content.dart`(사진 skeleton + relationshipGoal 칩), `lib/features/matches/matches_screen.dart` / `lib/features/main_shell.dart` / `lib/features/discovery/discovery_screen.dart`(매칭 생명주기 로직과 디자인 색상 변경이 같은 hunk 근처에 인접, `git add -p` 필요).
- 이 세션에서 `firebase deploy`는 실행하지 않았다. 위 변경 중 `firestore.rules`, `functions/index.js`는 커밋 후 별도 배포가 필요하다.

## 3. 구현 완료 기능

### 인증 / 프로필

- ✅ 이메일 회원가입/로그인, 이메일 인증 메일 발송/확인
- ✅ Google 로그인
- ✅ 전화번호 인증: `phone_login_screen.dart`, `otp_verification_screen.dart`, `AuthService.signInWithPhone()`
- ✅ 인증 배지: `users/{uid}.verifications.{email,phone,photo}` 기반. 이메일/전화 UI 연결 완료, 사진 인증은 자리만 있음. `VerificationBadges` 위젯은 인증 완료 상태를 `matchPrimary`(딥 민트)로 표시. 좁은 공간(매칭 목록 subtitle 등)에서 깨지지 않도록 배지 내부가 `FittedBox(scaleDown)`로 방어되어 있다
- ✅ 온보딩: 사진 업로드 → 기본 정보 → 상세 정보 → 관심사/성향/이상형 태그 → 찾는 관계, 총 7스텝. Design Phase 4에서 dot 인디케이터를 애니메이션 progress bar로 교체, 각 step을 카드 레이아웃으로 재정리
- ✅ 온보딩 저장 실패 시 raw exception 노출 제거: `'프로필 저장에 실패했어요. 잠시 후 다시 시도해주세요.'` 고정 문구만 표시, 상세 원인은 `kDebugMode`에서만 `debugPrint`
- ✅ 프로필 편집/조회, 상대 프로필 상세 화면(`user_profile_screen.dart`, Design Phase 4에서 사진 히어로 라운드 처리, AI Profile Insight/찾는 관계/태그 색상 정리)
- ✅ 프로필 편집 사진 관리: 슬롯 탭 시 대표 사진 설정/다른 사진으로 교체/삭제 바텀시트. 정책은 **최소 1장 유지(마지막 1장은 삭제 불가), 최대 4장**(`kMaxProfilePhotos = 4`). 삭제는 `StorageService.deleteByUrl` 호출과 연결되어 있어 실제 Storage 파일 삭제까지 이어짐 — 실기기 확인이 아직 필요한 항목(9장 참고)
- ✅ 다중 사진: `photoUrls`, 카드/상세 화면에서 좌우 탭 및 PageView 전환
- ✅ AI Profile Insight 카드: 상대 프로필 상세 화면 하단에서 로딩/실패/재시도 처리. 배지·아이콘은 AI 기능이므로 `matchPrimary`(premium) 톤

### Discovery / Match

- ✅ Tinder 스타일 스와이프 카드, 카드 사진은 로딩 중 skeleton → 완료 시 크로스페이드, 실패 시 고정 fallback으로 깜빡임 방지(`_CardPhotoImage`)
- ✅ pass / like / superlike 액션
- ✅ superlike는 `JellyCosts.superlike = 5` 소모 후 swipe 기록
- ✅ Rewind: 세션 내 직전 `pass`/`like` 1개만 `JellyCosts.rewind = 3` 소모로 되돌림. `superlike`는 제외. `_RewindCandidate`에 `action` 필드 추가, `rewindEntryToken`으로 화면 재진입 시 되돌리기 애니메이션이 중복 재생되지 않도록 방지
- ✅ Rewind 트랜잭션: `JellyService.rewindSwipe()`가 젤리 차감, `jellyTransactions` 기록(`reason: 'rewind'`), `users/{uid}/swipes/{targetUid}` 삭제를 단일 Firestore transaction으로 처리
- ✅ Rewind 정합성 방어: `onSwipeCreated`가 매칭 생성 직전 현재 swipe 문서와 역방향 swipe 문서를 transaction 안에서 재확인. Rewind로 삭제된 like가 뒤늦게 매칭되는 race를 방지
- ✅ 위치 권한/현재 위치 저장, Haversine 거리 계산, 카드 거리 표시
- ✅ 나이/거리/성별/**찾는 관계(relationshipGoal)** 필터 저장: `users/{uid}.discoveryFilter`. 필터 시트에 프리미엄 필터 예고 카드(`_PremiumFilterTeaser`, `PremiumNoticeCard` 재사용) 포함
- ✅ 부스트: `users/{uid}.boostUntil`, 디스커버리 정렬에서 우선 노출
- ✅ 카드 소진 시 pass 유저 재노출 정책
- ✅ 상세 프로필 진입, 신고/차단 메뉴 연결
- ✅ 서버 매칭 판정: `onSwipeCreated`가 상호 like/superlike일 때 `matches/{matchId}` 멱등 생성
- ✅ 매칭 성사 FCM: `onSwipeCreated`가 양쪽에게 "새로운 매칭!" 푸시 전송
- ✅ 받은 좋아요 목록: `collectionGroup('swipes')`, superlike 강조, 젤리 게이트 해제
- ✅ **Unmatch(매칭 해제)**: 매칭 목록/채팅방에서 해제 확인 다이얼로그 → `matches/{matchId}.unmatchedBy`에 본인 uid를 arrayUnion. 되돌리기(재매칭) 기능은 없음 — 배열은 늘어나기만 한다. 해제 후 양쪽 매칭 목록/채팅에서 숨김 처리(`MatchModel.isUnmatched`)
- ✅ Unmatch 서버측 방어: `firestore.rules`가 `unmatchedBy`가 비어있지 않은 매치에는 새 메시지 `create`와 `lastMessage` update를 모두 차단. 클라이언트 UI를 우회해도 서버 단에서 막힌다. 기존 채팅 기록(`read`)은 계속 조회 가능(신고/감사 목적 보존)
- ✅ **매칭 축하(celebration) 1회성 표시**: `matches/{matchId}.celebratedBy` 배열에 이미 본 uid를 기록. 매칭 목록/받은 좋아요/디스커버리 어디서 매칭이 성사되든 `markCelebrated()`로 기록하고, 매칭 탭 재진입 시 아직 못 본 축하가 있으면 도장(印章) 스탬프 애니메이션(`MatchCelebrationOverlay`)을 자동으로 다시 보여준다. `celebratedBy`가 아예 없는 매치(이 기능 이전 매치)는 대상에서 제외해 기존 매치가 한꺼번에 재축하되지 않도록 함
- ✅ **매칭 탭 안읽음 배지**: `MatchesService.watchUnreadMatchCount()` — 마지막 메시지가 본인이 보낸 게 아니고 `lastReadAt` 이후 도착했으면 카운트. 하단 내비게이션 매칭 탭에 `Badge`로 표시

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
- ✅ AI 대화 코치: 메시지가 1개 이상인 채팅방에서 입력창 위 `대화 이어가기` 버튼으로 `generateConversationTips` 호출. 버튼은 AI 기능이므로 `AppColors.premium` 톤
- ✅ AI 대화 코치 UX: 제안 탭 시 `_fillInput()`으로 입력창에만 채움, 바로 전송하지 않음. 로딩/실패/재시도 처리
- ✅ 매칭 목록 마지막 메시지 시간/안읽음 뱃지: `matches/{matchId}.lastMessage`, `lastReadAtByUid.{uid}` 기반
- ✅ 채팅 진입 및 새 메시지 수신 시 `ChatService.markMatchRead()`로 `lastReadAtByUid.{uid}` 갱신
- ✅ 새 메시지 FCM: `onMessageCreated`가 수신자에게 "새 메시지" 푸시 전송
- ✅ **채팅방 unmatch 처리**: 상단 메뉴에서 매칭 해제 가능. `ChatService.watchIsUnmatched()`로 실시간 구독 — 채팅방을 이미 열어둔 채로 상대가 해제해도 즉시 입력창이 비활성화되고 안내 배너(`_UnmatchedInputBar`)로 전환

### FCM / Notifications

- ✅ `firebase_messaging` 의존성 포함
- ✅ 앱 시작 후 `NotificationService.initialize()`가 foreground/opened/initial message 처리
- ✅ 로그인 유저에 대해 FCM 토큰을 `users/{uid}.fcmTokens` 배열에 저장, 갱신 시 arrayUnion
- ✅ invalid token은 Functions에서 `arrayRemove`
- ✅ foreground 메시지는 SnackBar로 표시하고 "열기" 액션 제공
- ✅ 알림 탭 이동: `type: 'match'`는 매칭 탭, `type: 'chat'`는 해당 채팅방으로 이동(채팅 화면 생성 시 `MatchesService`도 함께 주입 — unmatch 기능 사용을 위해)
- ✅ Android 우선 구현. iOS 실기기 푸시는 APNs Auth Key 등록 필요 주석이 코드에 있음
- ✅ Background handler: `main.dart` top-level `@pragma('vm:entry-point') firebaseMessagingBackgroundHandler`

### Fortune / AI 사주

- ✅ 사주/별자리 계산: `fortune_calculator.dart`
- ✅ 오행 레이더 차트: 시각적 floor 적용 + 축별 순차 애니메이션(`_axisProgress`), 실제 퍼센트 라벨은 원본값 유지
- ✅ 내 사주 서사: `generateFortuneNarrative`, `users/{uid}.fortuneNarrative` 캐시
- ✅ 궁합 서사: `generateMatchNarrative`, `matches/{matchId}.fortuneMatch` 캐시
- ✅ **GPT 응답 sanitize**: `sanitizeNarrative()`/`sanitizeDailyFortune()`가 GPT 응답이 스키마와 안 맞아도 예외 대신 안전한 기본값으로 보정하고 실패 케이스는 `console.error`로 원본/보정값을 함께 로그. `generateFortuneNarrative`/`generateMatchNarrative`/`generateDailyFortune` 3곳에 모두 적용되어 있어 "GPT 응답 형식이 올바르지 않습니다" 실패가 크게 줄어듦
- ✅ AI 추천 이유: `MatchFortuneScreen`에서 궁합 narrative reasons를 bullet/chip 형태로 표시
- ✅ 오늘의 운세: `generateDailyFortune`, `users/{uid}/dailyFortune/{yyyy-MM-dd}` 캐시
- ✅ 운세 히스토리/그래프, debug 전용 최근 7일 채우기
- ✅ 사주 기반 채팅 아이스브레이커: `generateIcebreakers`, `matches/{matchId}.icebreakers` 캐시
- ✅ 오늘의 인연 Hero: HomeScreen 상단에서 기존 매치 캐시/규칙 기반 궁합/Discovery 후보를 새 GPT 호출 없이 표시
- ✅ 사주/궁합 결과 공유 카드: `ShareImageService`, `share_plus`, 오프스크린 렌더링. release 빌드에서 `RenderRepaintBoundary.debugNeedsPaint`(디버그 전용 getter, release에서 접근 시 `LateInitializationError`)를 참조하던 버그를 제거하고 프레임 대기를 강화해 실기기 공유 실패 문제를 해결

### AI 확장 / AI 이상형 (fal.ai)

- ✅ Match Narrative: `generateMatchNarrative`
- ✅ Ice Breaker: `generateIcebreakers`
- ✅ Conversation Coach: `generateConversationTips`, `matches/{matchId}.conversationTips.lastMessageId` 짧은 캐시
- ✅ AI Profile Insight: `generateProfileInsight`, GPT `gpt-4o` Vision, `users/{targetUid}.profileInsight.inputHash` 캐시
- ✅ Profile Insight 외모 평가 금지: 프롬프트에 외모 점수/등급/신체 평가 금지, 사진은 표정/분위기/상황 맥락만 사용
- ✅ Charm Report: `generateCharmReport`, `users/{uid}.charmReport` 캐시
- ✅ Daily Fortune: `generateDailyFortune`
- ✅ Fortune Cache 우선 읽기: 앱 서비스 계층에서 Firestore 캐시 확인 후 callable 호출
- ✅ **AI 이상형 이미지 — provider 추상화 완료**. `generateIdealTypeImage`가 provider 추상화 계층을 거친다. 자세한 현재 상태는 7장 참고.

### Jelly / 수익화 목업

- ✅ 젤리 잔액: `users/{uid}.jelly`
- ✅ 거래 내역: `users/{uid}/jellyTransactions/{txId}`. `JellyService.watchTransactions()` + `JellyTransaction` 모델로 실시간 구독
- ✅ **젤리 사용 내역 화면**(`jelly_history_screen.dart` 신규): 충전/사용 내역을 시간순으로 표시, reason key를 한글 라벨로 변환(`JellyTransaction.label`)
- ✅ 젤리샵에 **혜택 요약 카드**(`_JellyBenefitsCard`) + 내역 화면 진입점 추가
- ✅ 목업 충전: `kJellyMockPurchases == true`일 때 클라이언트 트랜잭션 충전
- ✅ 실제 IAP 연결 자리: `in_app_purchase`, `JellyPurchaseService`
- ✅ `verifyJellyPurchase` Cloud Function 스켈레톤
- ✅ 소모처: superlike, rewind, boost, 받은 좋아요 전체보기 해제
- ✅ 비용 상수(`JellyCosts`): `superlike = 5`, `rewind = 3`, `boost = 30`, `unlockReceivedLikes = 20`, `boostDuration = 30분`

### 안전 / 운영 대응

- ✅ 신고: `reports/{reportId}` 생성, 클라이언트 read 차단
- ✅ 차단: `users/{uid}/blocks/{blockedUid}`, 양방향 숨김에 collectionGroup blocks 사용
- ✅ 차단 적용: 디스커버리, 매칭, 받은 좋아요, 채팅 진입 확인
- ✅ 사용자 화면 raw exception/stack trace 노출 방지 작업이 주요 화면에 반영됨(온보딩 포함). 새 작업 시 계속 확인 필요

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
- ❌ 온보딩 draft/resume(중간 이탈 후 이어하기)
- ❌ AI 이상형 여러 후보 생성/저장/공유, 생성 결과와 실제 인연 추천 연결

## 5. 프로젝트 구조

```text
lib/
├── app.dart                         # 서비스 생성/주입, AuthGate, 라우트
├── main.dart                        # Firebase init, FCM background handler 등록
├── firebase_options.dart            # FlutterFire 설정 placeholder 성격
├── core/
│   ├── constants/
│   ├── routes/
│   ├── theme/                       # app_tokens.dart: AppColors/AppSpacing/AppRadius/AppDurations/AppCurves
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
│   ├── jelly/                       # jelly_shop_screen.dart, jelly_history_screen.dart(신규)
│   ├── likes/
│   ├── matches/                     # matches_screen.dart, widgets/match_celebration_overlay.dart
│   ├── onboarding/
│   ├── profile/
│   └── safety/
├── models/                          # user_profile(DiscoveryFilter 포함), match(celebratedBy/unmatchedBy), message, fortune, charm, ideal_type, profile_insight
├── services/
│   ├── auth/
│   ├── charm/
│   ├── chat/                        # watchIsUnmatched() 포함
│   ├── database/
│   ├── discovery/
│   ├── fortune/
│   ├── ideal_type/
│   ├── jelly/                       # JellyTransaction, watchTransactions()
│   ├── likes/
│   ├── location/
│   ├── matches/                     # unmatch(), markCelebrated(), watchUnreadMatchCount()
│   ├── notifications/               # NotificationService, FCM 토큰/알림 라우팅
│   ├── profile/                     # ProfileInsightService
│   ├── safety/
│   ├── share/                       # ShareImageService (release 캡처 안정화)
│   └── storage/
└── shared/
    └── widgets/                     # primary_button.dart, premium_components.dart(신규: PremiumSectionCard/PremiumBadge/PremiumNoticeCard)

functions/
└── index.js                         # Cloud Functions v2 전체, 12 exports

firestore.rules
firestore.indexes.json
storage.rules
test/
```

## 6. Cloud Functions

`functions/index.js` 실제 exports 기준 **12개**. 전역 리전은 `asia-northeast3`로 고정(`setGlobalOptions`).

| Function | Trigger | GPT/Image 호출 | 캐시 | 역할 |
|---|---|---:|---|---|
| `onSwipeCreated` | Firestore `onDocumentWritten('users/{uid}/swipes/{targetUid}')` | 아니오 | 없음 | like/superlike 상호 관심 확인. transaction 안에서 현재 swipe와 역방향 swipe를 재확인해 Rewind race 방어 후 `matches/{matchId}` 멱등 생성, 양쪽 FCM 매칭 알림 |
| `onMessageCreated` | Firestore `onDocumentCreated('matches/{matchId}/messages/{messageId}')` | 아니오 | 없음 | 새 채팅 메시지 생성 시 수신자 FCM 알림. data: `type=chat`, `matchId`, `senderUid` |
| `generateFortuneNarrative` | callable | GPT `gpt-4o-mini` | `users/{uid}.fortuneNarrative` | 내 사주 캐릭터/서사. `sanitizeNarrative()`로 응답 보정 |
| `generateMatchNarrative` | callable | GPT `gpt-4o-mini` | `matches/{matchId}.fortuneMatch` | 두 사람 궁합 서사. participants 권한 확인, `sanitizeNarrative()`로 응답 보정 |
| `generateIcebreakers` | callable | GPT `gpt-4o-mini` | `matches/{matchId}.icebreakers` | 빈 채팅방 첫 대화 주제 3개 |
| `generateConversationTips` | callable | GPT `gpt-4o-mini` | `matches/{matchId}.conversationTips.lastMessageId` | 최근 메시지 8개 기반 대화 재개 문장 2~3개 |
| `generateDailyFortune` | callable | GPT `gpt-4o-mini` | `users/{uid}/dailyFortune/{date}` | 날짜별 오늘의 애정운. `sanitizeDailyFortune()`로 응답 보정 |
| `generateCharmReport` | callable | GPT `gpt-4o-mini` | `users/{uid}.charmReport` | 프로필 기반 첫인상/매력 분석 |
| `generateProfileInsight` | callable | GPT `gpt-4o` Vision | `users/{targetUid}.profileInsight.inputHash` | 상대 프로필 사진/소개/태그/MBTI/사주 기반 비외모 인사이트 |
| `generateIdealTypeImage` | callable, `timeoutSeconds: 120`, `memory: 1GiB` | 이미지, **기본 provider fal.ai FLUX** (`fal-ai/flux/schnell`) | `users/{uid}.idealTypeImage.inputHash`(provider/promptVersion/refinementText 포함 해시) | 이상형 이미지 생성 후 Storage 저장. 자세한 내용은 7장 |
| `generateIdealTypeImageProviderPreview` | callable | 이미지, `request.data.provider`로 openai/fal_flux 선택 | 없음(비교용, 캐시 저장 안 함) | 개발자/운영자 전용 provider 비교 callable. custom claim(`admin`/`developer`/`idealImageProviderPreview`) 필요 |
| `verifyJellyPurchase` | callable | 아니오 | `users/{uid}/jellyTransactions/{transactionId}` 멱등 | IAP 영수증 검증 자리. 현재 검증 함수는 항상 valid 반환하는 스켈레톤 |

주의:
- OpenAI 호출은 `OPENAI_API_KEY`, fal.ai 호출은 `FAL_KEY` Firebase Secret 사용. **앱/저장소/이 문서 어디에도 실제 키 값 리터럴을 넣지 않는다.**
- FCM 전송은 Admin SDK `sendEachForMulticast()` 사용. invalid token은 `users/{uid}.fcmTokens`에서 제거한다.

## 7. AI 이상형 (fal.ai) 현재 상태

- **기본 provider는 OpenAI가 아니라 fal.ai FLUX다.** `ACTIVE_IDEAL_IMAGE_PROVIDER = IDEAL_IMAGE_PROVIDERS.FAL_FLUX` (2026-07-08 전환, PoC 결과 fal.ai가 더 현실적인 이상형 이미지를 생성해 기본값으로 채택).
- 모델: `fal-ai/flux/schnell` (`FAL_FLUX_MODEL`), sync 엔드포인트 `https://fal.run/{model}` 호출.
- OpenAI 경로(`generateIdealTypeImageWithOpenAI`, 모델 `gpt-image-1`)는 삭제하지 않고 그대로 보존 — `ACTIVE_IDEAL_IMAGE_PROVIDER` 값만 되돌리면 즉시 롤백 가능한 구조.
- `FAL_KEY`는 다른 API 키와 동일하게 Firebase Secret으로만 관리한다. 코드/문서/로그 어디에도 리터럴 값을 남기지 않는다.
- `generateIdealTypeImage`(일반 사용자용 callable)는 항상 `ACTIVE_IDEAL_IMAGE_PROVIDER` 경로(현재 fal_flux)로 생성한다. **실제 앱 UI에는 provider 선택권을 열지 않는다** — 사용자는 어떤 provider가 쓰이는지 알 수도, 고를 수도 없다.
- `generateIdealTypeImageProviderPreview`는 openai/fal_flux를 골라 호출할 수 있는 **개발자/운영자 전용 비교 callable**이다. `request.auth.token`에 `admin === true` 또는 `developer === true` 또는 `idealImageProviderPreview === true` 커스텀 클레임 중 하나가 없으면 `permission-denied`로 거부된다(`requireIdealImagePreviewAccess()`).
- 안전 정책(코드/프롬프트에 이미 반영됨, 문서로도 남김):
  - 생성된 이미지는 AI가 만든 가상의 인물이며 **실제 앱 사용자가 아님을 화면에 표시**해야 한다.
  - 특정 실존 인물/연예인을 닮게 해달라는 요청은 금지 프롬프트로 차단한다.
  - 미성년으로 해석될 수 있는 요청, 과한 노출/선정적 요청은 `sanitizeIdealImageRefinementText()`의 키워드 블록리스트로 차단한다.

## 8. AI 이상형 옵션 구조

- 성별(대상)별로 mood/style/hair/impression 옵션 세트가 분리되어 있다(`IdealTypeOptionSets.moodsForGender()` 등, 서버 `IDEAL_IMAGE_OPTIONS` 맵과 대응). 남성/여성/상관없음 각각 5~7개 수준.
- **label과 promptText 개념이 분리되어 있다.** 클라이언트는 옵션의 `key`만 서버에 보낸다. key → 실제 영어 프롬프트 문장으로의 변환은 서버(`functions/index.js`의 `IDEAL_IMAGE_OPTIONS` 맵)가 최종 권한을 가진다. 클라이언트가 임의의 프롬프트 텍스트를 직접 보낼 수 있는 경로는 없다.
- `refinementText`: 사용자가 자유 텍스트로 추가 요청을 적을 수 있는 필드. 최대 100자, 서버에서 `sanitizeIdealImageRefinementText()`로 sanitize/키워드 검증 후 프롬프트에 삽입한다(안전 트레일링 문구보다 앞에 삽입해, 안전 제약이 항상 마지막 발언권을 갖도록 함).
- 캐시 해시(`idealImageHash(input, provider, promptVersion)`)에 `refinementText`, `provider`, `promptVersion`이 모두 포함되어 있어, 옵션/문구/provider가 하나라도 다르면 캐시를 재사용하지 않는다.
- 기존 OpenAI 시절에 저장된 캐시(`legacyIdealImageHash()`)와의 하위 호환도 유지한다 — provider 필드가 없는 과거 캐시는 provider를 추론해 재사용 가능 여부를 판단한다(`isReusableIdealImageCache()`).
- 클라이언트 화면(`ideal_type_screen.dart`)은 Firestore에 저장된 마지막 생성 결과를 불러올 때 `IdealTypeImageResult.options`를 파싱해 로컬 `_options` 상태를 그 값으로 동기화한다 — 화면을 재진입했을 때 "선택한 취향" 표시와 실제 생성된 이미지의 옵션이 어긋나는 문제를 방지하기 위함이다(`refinementText`는 세션마다 새로 입력해야 하므로 이 동기화에서 제외).

## 9. Firestore / Storage 구조

### Firestore

- `users/{uid}`
  - 기본 프로필: `displayName`, `birthDate`, `gender`, `bio`, `photoUrls`, `createdAt`, `updatedAt`
  - 상세 프로필: `height`, `religion`, `smoking`, `drinking`, `jobCategory`, `jobTitle`, `education`, `mbti`
  - 태그/목표: `interests`, `personalityTags`, `idealTags`, `relationshipGoal`, `personaVector?`
  - 인증: `verifications: { email, phone, photo }`
  - 위치: `location: { lat, lng, updatedAt, label? }`
  - 필터: `discoveryFilter: { ageMin, ageMax, maxDistanceKm, gender, relationshipGoal? }` — `relationshipGoal`이 null이면 상관없음/전체
  - 푸시 토큰: `fcmTokens`, `fcmTokenUpdatedAt`
  - AI 캐시: `fortuneNarrative`, `charmReport`, `profileInsight`, `idealTypeImage`(provider/promptVersion/refinementText 포함 해시로 캐시 유효성 판단)
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
  - 젤리 내역 화면(`jelly_history_screen.dart`)이 `JellyService.watchTransactions()`로 최근 거래를 실시간 구독
- `matches/{matchId}`
  - `participants`, `uid1`, `uid2`, `matchedAt`
  - `lastMessage: { text, senderId, createdAt }` — **`unmatchedBy`가 비어있을 때만** update 허용
  - 읽음 상태: `lastReadAtByUid.{uid}`. 매칭 목록 안읽음 뱃지 판정에 사용
  - `celebratedBy: string[]?` — 매칭 축하 오버레이를 이미 본 uid 목록. 필드가 아예 없는 매치(도입 이전)와 빈 배열은 의미가 다르게 취급됨(전자는 축하 대상에서 제외)
  - `unmatchedBy: string[]` — 매칭 해제한 uid 목록. 하나라도 있으면 `MatchModel.isUnmatched == true`, 양쪽 목록/채팅에서 숨김. 되돌리기 없음
  - AI 캐시: `fortuneMatch`, `icebreakers`, `conversationTips`
- `matches/{matchId}/messages/{messageId}`
  - `senderId`, `text`, `createdAt`
  - create는 이 매치가 아직 unmatch되지 않았을 때만 허용(rules). update/delete는 여전히 금지

### Indexes / Rules

- `matches`: `participants arrayContains + matchedAt desc`
- `swipes` collectionGroup: `targetUid asc + action asc + timestamp desc`
- `blocks` collectionGroup field override: `blockedUid asc`
- `matches/{matchId}` update 규칙: `lastMessage`(unmatch 안 된 경우만) / 본인 `lastReadAtByUid` 키 / 본인 uid를 끝에 추가하는 `celebratedBy` / 본인 uid를 끝에 추가하는 `unmatchedBy` — 이 4가지 외 필드는 여전히 Cloud Functions 전용
- `firestore.rules`에 RELEASE-BLOCKER 주석이 남아 있다. 배포 전 반드시 검색할 것.

### Storage

- `users/{uid}/{allPaths=**}`: 인증 유저 read, 본인 write
- 프로필 사진과 AI 이상형 이미지(`users/{uid}/idealType/...png`)가 이 경로를 사용
- 프로필 편집 화면의 사진 삭제 기능이 `StorageService.deleteByUrl()`을 호출해 실제 파일을 지운다 — 삭제 실패 시 UI 롤백 여부는 아직 실기기로 확인되지 않았다(RELEASE-BLOCKER 아님, 일반 QA 항목)

## 10. Design Overhaul 현재 방향 및 보정 필요 사항

### 목표 방향

- 최종 제품 방향: **Premium Match + Soft Dating + Fortune Insight**
- 레퍼런스: Marry Fit류 국내 프리미엄 매칭앱. black/deep charcoal + mint/neon green 액센트 + bold typography + photo-led card + membership/locked/benefit panel 느낌.
- 화면을 두 가지 디자인 모드로 나눠 적용해야 한다(아직 미착수, 다음 세션 과제):
  1. **Dark Premium Mode** — 로그인/첫인상, Discovery, AI 이상형, Jelly/멤버십/혜택, 프리미엄 필터/혜택 안내, AI Daily Pick. 이 화면들이 앱의 "프리미엄 매칭앱" 첫인상을 결정한다.
  2. **Cream Support Mode** — 프로필 편집, 프로필 상세의 읽기 영역, 사주 리포트 본문, 채팅 일부, 설정/내역. 정보를 편하게 읽는 화면은 기존 크림톤을 유지한다.
- 색상 역할 원칙: `red`(seal)는 core CTA에서 완전히 제거하고 `fortuneAccent` 또는 `error`(destructive)로만 제한한다. `matchPrimary`/`premium`은 매칭/AI/젤리/프리미엄 액션에 사용한다. 사주/궁합은 앱의 메인이 아니라 **romantic insight의 보조 역할**로 위치시킨다.

### Phase 5 적용 완료 (2026-07-09, 이 세션)

위 "보정 필요" 과제 중 색상 정체성 재정의를 실행했다. 사용자 확정 방향:
**하이브리드(라이트 base + 다크 히어로) + 비비드 민트 + 사주 레드는 fortune insight 전용 축소 + 토큰→핵심 화면 순 적용.**

- **토큰 재정의** (`app_tokens.dart`):
  - `mint`(#4BE39B) 비비드 민트 = 시그니처. CTA fill/선택 상태/다크 서피스 강조. **민트 fill 위 텍스트는 반드시 `onMint`(#0C231A). 흰 텍스트 금지.**
  - `mintDeep`(#0E9F6B) = 라이트 배경 위 텍스트/아이콘/링크. `matchPrimary`와 `premium`이 이 값으로 승계됨.
  - **`AppColors.primary`를 seal red → `mintDeep`으로 repoint 완료.** 미리팩터 화면도 자동으로 민트 계열이 된다.
  - 다크 히어로 서피스: `night`/`nightAlt`/`nightBorder`/`onNight`/`onNightSecondary`. 적용 문법: night 그라데이션 + `AppRadius.hero(28)` + `AppShadows.hero`.
  - `fortuneAccent`(=seal) 사주 전용 유지, 다크 위에서는 `fortuneAccentBright`(#F07A6C).
  - `AppShadows.card/hero/mintGlow` 신설 — flat 1px 보더 단독 카드 지양.
- **테마** (`app_theme.dart`): Elevated/FilledButton = mint fill + onMint, TextButton = mintDeep, 칩 selected = mint + onMint, 네비/포커스 = matchPrimary, splash = mint.
- **적용된 핵심 화면**: 홈 '오늘의 인연' 히어로(다크), 젤리샵 잔액 헤더(다크) + 상품 타일 섀도우, 채팅 내 버블(mint+onMint, red 폐기), 프로필 버튼 위계(민트 CTA는 AI 이상형 하나만, 나머지 outlined), 태그/세그먼트 선택 상태(mint+onMint), Discovery 액션(like=matchPrimary, superlike=water, pass=error) 및 LIKE 스탬프, 매칭 축하 CTA(민트; 인장 緣/궁합 연출은 seal 유지), fortune 4개 화면+radar를 `fortuneAccent` 명시로 교체, 공유/CTA 버튼은 민트.
- **주의 규칙**: `FilledButton.styleFrom(backgroundColor: ...)`으로 덮어쓸 때 반드시 `foregroundColor`도 지정할 것 — 테마 기본 fg가 `onMint`(다크)라서 error red 등 어두운 배경과 조합되면 대비가 깨진다. error 배경 버튼들은 `foregroundColor: AppColors.surface` 명시를 완료했다.

### 남은 디자인 과제

- 로그인/온보딩 첫인상 화면의 Dark Premium 버전(현재는 라이트 + 민트 CTA까지만).
- Discovery 카드 오버레이/그라데이션 톤 정밀 보정, 매칭 목록·받은 좋아요 카드 깊이(AppShadows.card) 확산.
- MaruBuri(명조) display 사용 범위 축소 검토 — 사주 콘텐츠 전용으로 남기고 UI 헤드라인은 Pretendard 굵기 대비로.
- 마이크로 인터랙션(카드 진입 stagger, 버튼 press scale)은 AppDurations/AppCurves 기반으로 확산.

## 11. RELEASE-BLOCKER / 배포 전 필수 처리

`rg "RELEASE-BLOCKER|verifyWith|dummy_|firebase-admin|firebase-functions" firestore.rules functions/index.js functions/package.json` 기준 실제 확인 사항이다.

1. **dummy rule 제거** — ✅ 해결됨 (Phase 0-A, 2026-07-16).
   - `firestore.rules`의 `uid.matches('dummy_.*')` write 예외 2곳(`users/{uid}` 문서 write, `users/{uid}/swipes/{targetUid}` write)을 모두 제거했다.
   - 이제 일반 인증 클라이언트는 타인 또는 `dummy_*` 사용자 명의로 사용자 문서·스와이프를 생성/수정할 수 없다. 본인(`request.auth.uid == uid`) 문서·스와이프 쓰기만 허용된다.
   - 신규 더미 생성 기능(`DummyDataService`, Discovery 더미 생성 메뉴)은 제거했다. 별도 seed 인프라(Emulator/Admin SDK)를 새로 만들 계획은 현재 없다.
   - 기존에 생성돼 있는 `dummy_*` 문서는 당분간 삭제하지 않으며, 일반 읽기/표시 경로로는 계속 노출될 수 있다.
   - **배포 필요**: 이 규칙 변경은 커밋 후 `firebase deploy --only firestore:rules` 로 반영해야 실제 적용된다.

2. **users/{uid} 전체 write 허용**
   - 현재 `allow write: if request.auth != null && request.auth.uid == uid;`가 `users/{uid}` 전체 필드를 열어둔다.
   - 이 상태에서는 클라이언트가 `jelly`, `boostUntil`, `likesUnlocked`, `fcmTokens` 등도 직접 조작 가능하다.
   - 실서비스 전에는 프로필 편집 허용 필드만 좁히고, 재화/수익화 필드는 서버 전용으로 분리해야 한다.
   - rules hardening 때 `fcmTokens`, `fcmTokenUpdatedAt`은 본인 기기 토큰 등록을 위해 허용 필드에 포함해야 한다.
   - `matches/{matchId}`의 `lastReadAtByUid.{uid}` / `celebratedBy` / `unmatchedBy`는 각각 별도 map/array diff 규칙으로 이미 본인 uid만 갱신 가능하도록 좁혀져 있다. rules hardening 때 이 3가지 허용 범위를 반드시 유지해야 안읽음 처리·축하 1회성 표시·매칭 해제 기능이 깨지지 않는다.

3. **젤리 client write 위험**
   - `users/{uid}.jelly`, `boostUntil`, `likesUnlocked`가 users 전체 write 허용에 포함된다.
   - `users/{uid}/jellyTransactions/{txId}`도 현재 본인 read/write 허용이다.
   - Rewind도 현재 클라이언트 transaction으로 `jelly`와 `jellyTransactions`를 쓴다.
   - 실서비스 전에는 superlike/boost/rewind/unlock 관련 쓰기를 Cloud Functions admin SDK로만 제한해야 한다.
   - **아직 미해결.** 이 세션에서도 손대지 않았다.

4. **`verifyJellyPurchase` 실제 검증**
   - `functions/index.js`의 `verifyWithAppStore()` / `verifyWithGooglePlay()`는 현재 항상 `{ valid: true }`를 반환한다.
   - App Store Server API / Google Play Developer API 검증으로 교체 전 프로덕션 금지.
   - **아직 스켈레톤 상태.**

5. **Functions 런타임/의존성 업그레이드**
   - `functions/package.json`은 Node 20, `firebase-admin` `^12.0.0`, `firebase-functions` `^6.0.0`.
   - Node 20 런타임 종료 일정 전에 Node 22+ 검토 필요.
   - Firebase Functions/Admin SDK는 메이저 업그레이드 검토 필요: `firebase-admin` 12 → 14, `firebase-functions` 6 → 7.

6. **Cloud Functions region** — ✅ 해결됨. `setGlobalOptions({ region: 'asia-northeast3' })`로 전역 고정되어 있다(과거 버전 문서에는 미설정으로 기록돼 있었으나 현재는 반영됨).

7. **커밋/배포 상태**
   - 2장에 정리된 46개 파일이 아직 커밋되지 않았다. `firebase deploy`도 이 세션에서 실행하지 않았다.
   - `functions/index.js`(fal.ai provider, fortune sanitize), `firestore.rules`(unmatch/celebration 규칙) 모두 커밋 후 각각 `firebase deploy --only functions` / `firebase deploy --only firestore:rules` 별도 배포가 필요하다.

8. **개발용 코드**
   - ~~`lib/dev/dummy_data_service.dart`~~ / ~~Discovery의 더미 생성 버튼~~ — Phase 0-A(2026-07-16)에서 제거 완료.
   - Fortune History의 `kDebugMode` 최근 7일 채우기
   - 출시 전 노출 여부 점검 필요

## 12. 개발 원칙

- 기존 구조와 서비스 계층을 우선 재사용한다.
- 새 GPT 호출은 최소화한다. 이미 있는 narrative/cache/규칙 계산으로 해결 가능한지 먼저 본다.
- Firestore 캐시 우선, callable은 캐시 miss일 때만 호출한다.
- 새 Firestore 구조는 최소화한다. 기존 문서/필드로 해결 가능한지 먼저 판단한다.
- UI보다 안정성을 우선한다. 실패해도 화면 전체가 깨지지 않아야 한다.
- 사용자 화면에 raw exception, FirebaseFunctionsException 전체 문자열, stack trace를 노출하지 않는다.
- 상세 에러 로그는 `kDebugMode`에서만 `debugPrint`로 남긴다. (`share_image_service.dart`에 `kDebugMode` 가드 없는 `debugPrint`가 다수 추가되어 있어 이 원칙과 어긋난다 — 다음 세션에서 점검 필요)
- OpenAI/fal.ai API 키, 스토어 키, 서비스 계정 키는 절대 앱/저장소/문서에 넣지 않는다.
- 디자인은 `AppColors`, 기존 버튼/카드 스타일 등 프로젝트 토큰을 재사용한다. 의미 기반 토큰(`matchPrimary`/`fortuneAccent`)을 화면 성격에 맞게 명시적으로 고른다.
- 커밋은 사용자가 명시적으로 요청할 때만 한다.

## 13. 작업 방식 규칙

- **디자인-only 작업**(색상/레이아웃/타이포/애니메이션처럼 기능·데이터·권한에 영향이 없는 변경)에서는 `flutter analyze` / `flutter test` / `flutter build` / 실기기 검증을 매번 반복 요구하지 않는다. 이런 작업은 코드 diff와 서면 리포트 중심으로 받는다. 테스트/런타임 오류 확인은 사용자가 직접 처리한다.
- 단, 다음 영역을 건드리는 작업은 검증 항목(analyze/test/build, 필요시 실기기)을 다시 포함한다: 인증/매칭/채팅 등 **기능 로직**, **보안/결제/젤리**, **Firestore rules**, **Cloud Functions**, **AI provider(OpenAI/fal.ai) 설정**.
- 실제 AI 이미지 생성 테스트(fal.ai/OpenAI 실호출)는 꼭 필요한 경우로만 최소화한다 — 비용이 발생하고, provider/prompt 변경의 영향이 클 때만 수행한다.

## 14. 커밋 관리 주의사항

- 2장에서 정리한 대로 마지막 커밋(`66ca736`) 이후 46개 파일, 약 5,203 insertions / 1,136 deletions가 커밋 없이 누적돼 있다. **다음 기능 작업을 더 얹기 전에 기능 단위 커밋 분리(checkpoint)가 필요하다.**
- 커밋 분리 시 기능별로 나누는 것을 권장한다(예: share image 안정화 / fortune GPT sanitize / AI 이상형 provider·taxonomy / unmatch·celebration·배지 / discovery filter·photo 안정화 / jelly 내역 / design overhaul / onboarding·profile 디자인).
- 다음 파일들은 서로 다른 관심사가 같은 파일·인접한 hunk에 섞여 있어 `git add -p`로 hunk 단위 스테이징이 필요하거나, 분리 실익보다 위험이 커서 통합 커밋으로 처리하는 편이 나을 수 있다:
  - `functions/index.js` — fortune GPT sanitize와 fal.ai provider abstraction이 줄 범위상 분리는 가능(각각 독립된 구간)하나 같은 파일이라 주의 필요.
  - `lib/features/profile/profile_edit_screen.dart` — 사진 관리 신규 기능과 PremiumSectionCard 디자인 리팩터가 뒤섞여 있음. **가장 위험한 파일.**
  - `lib/features/discovery/widgets/profile_card_content.dart` — 사진 로딩 skeleton/fallback과 relationshipGoal 칩이 혼재.
  - `lib/features/matches/matches_screen.dart`, `lib/features/main_shell.dart`, `lib/features/discovery/discovery_screen.dart` — unmatch/celebration/안읽음 배지/Rewind 후속 로직과 디자인 색상·레이아웃 변경이 같은 위젯 근처에 인접.
  - **Phase 5(민트 시그니처) 변경이 위 파일 대부분에 추가로 얹혀 있다.** `app_tokens.dart`/`app_theme.dart`/`primary_button.dart`는 Phase 5 단독이라 분리 커밋이 쉽지만, 화면 파일들은 기능 변경과 색 변경이 섞여 있으므로 "디자인 Phase 5" 커밋을 마지막에 몰아서 처리하는 편이 안전하다.
- `firestore.rules`/`functions/index.js` 관련 커밋은 배포 전 반드시 실제 규칙/함수 diff를 사람이 재검토한다.

## 15. 최근 변경 이력

커밋된 이력(최근 20개 기준 상위):

1. `66ca736 fix: align callable functions region and harden FCM registration`
2. `a32e9e4 style: apply modern-ink tokens across app screens`
3. `5cee203 feat: add modern-ink design token system and typography`
4. `3697d49 feat: add rewind support for discovery swipes`
5. `c7a49cd feat: add AI conversation coach for stalled chats`
6. `146e543 feat: add FCM match and message notifications`
7. `155bf78 feat: add AI profile insight card`
8. `2292261 feat: add match list message time and unread badge`

`66ca736` 이후 **커밋되지 않은** 누적 작업(자세한 내용은 2장):

- Share image 캡처 안정화
- Fortune GPT 응답 sanitize
- AI 이상형 provider abstraction + fal.ai FLUX 기본 전환 + 성별 taxonomy + refinementText + provider-aware 캐시 + 개발자용 preview callable
- Unmatch / celebratedBy / 안읽음 배지 등 매칭 생명주기
- Rewind 후속 안정화
- Discovery relationshipGoal 필터 + 카드 사진 로딩 안정화
- Jelly 거래 내역 화면 + 혜택 카드
- 프로필 편집 사진 관리 기능
- Design Overhaul Phase 1~4
- 온보딩 raw exception 제거 + 온보딩/프로필 상세 디자인 개선(Design Phase 4)
- **Design Overhaul Phase 5 (2026-07-09)** — 비비드 민트 시그니처(`mint`/`onMint`/`mintDeep`), `AppColors.primary` repoint(seal→mintDeep), 하이브리드 다크 히어로(홈 '오늘의 인연', 젤리샵 잔액 헤더), 채팅 버블 민트 전환, fortune 화면 `fortuneAccent` 명시화, error 버튼 foregroundColor 명시. 상세는 10장
- `VerificationBadges` FittedBox 오버플로우 방어 (실기기에서 매칭 목록 배지 깨짐 수정)

## 16. 다음 개발 우선순위

1. **커밋 checkpoint 정리** (14장) — 다음 기능 작업 전 선행 필요
2. Design Overhaul 다음 단계 — Dark Premium Mode 확장: 로그인/온보딩 첫인상, Discovery, AI 이상형, 젤리샵 전체 화면(10장 "남은 디자인 과제" 참고. 토큰(`night` 계열)과 히어로 문법은 Phase 5에서 이미 준비됨)
3. 실제 Store 결제 검증
4. 젤리/수익화 서버 전용 write hardening
5. Photo Message
6. 메시지별 Read Receipt
7. Daily Recommendation/추천 노출 제한 정책
8. 실제 Typing Event
9. 실제 온라인/최근 접속 상태
10. 사진 인증
11. 운영자 신고 검토 콘솔
12. 온보딩 draft/resume
13. AI 이상형 여러 후보 생성/저장/공유, 실제 인연 추천 연결

## 17. 자주 실행하는 검증 명령

```bash
flutter analyze
flutter test
node --check functions/index.js
firebase deploy --only functions
firebase deploy --only firestore:rules
firebase deploy --only firestore:indexes
```

실기기 배포:
```bash
# 1번 폰 (USB 디버깅 가능)
adb install -r build/app/outputs/flutter-apk/app-release.apk

# 2번 폰 (USB 디버깅 불가 — 로컬 서버로 배포)
cd build/app/outputs/flutter-apk && python3 -m http.server 8765
# 같은 네트워크에서 http://10.50.11.14:8765/app-release.apk 로 다운로드
```

서버 배포가 필요한 변경:
- `functions/index.js` 수정 → `firebase deploy --only functions`
- `firestore.rules` 수정 → `firebase deploy --only firestore:rules`
- `firestore.indexes.json` 수정 → `firebase deploy --only firestore:indexes`
- `storage.rules` 수정 → Firebase CLI에 storage target이 있으면 `firebase deploy --only storage`

13장 기준으로, 디자인-only 작업은 위 명령을 매번 반복하지 않아도 된다. 기능/보안/rules/functions/AI provider 변경은 반드시 포함한다.

## AI Working Rules

이 프로젝트에서 작업하는 모든 AI 에이전트(Claude Code, Codex)는 아래 원칙을 반드시 따른다.

1. 구현 전 기존 구조를 먼저 분석한다.
2. 동일 기능이 이미 존재하는지 먼저 확인한다 (중복 구현 금지).
3. 새 Cloud Function보다 기존 Function 재사용을 우선한다.
4. 새 Firestore Collection 생성은 최후의 수단으로 한다.
5. 새 GPT 호출 추가 전 반드시 기존 캐시 구조를 먼저 확인한다.
6. 사용자에게 raw exception, stack trace를 절대 노출하지 않는다.
7. debugPrint는 반드시 kDebugMode에서만 사용한다.
8. **디자인-only 작업**은 flutter analyze/test/build/실기기 검증을 매번 요구하지 않는다. diff + 서면 리포트로 결과를 전달한다. 사용자가 직접 테스트/런타임 오류를 확인한다.
9. **기능/보안/결제/Firestore rules/Cloud Functions/AI provider 변경**은 8번의 예외이며, flutter analyze와 flutter test가 통과하지 않으면 작업 완료로 간주하지 않는다.
10. 디자인은 기존 Design Token을 재사용한다. 새 화면은 `matchPrimary`/`fortuneAccent` 등 의미 기반 토큰 중 실제 성격에 맞는 것을 명시적으로 고른다.
11. 실제 AI 이미지 생성 테스트(fal.ai/OpenAI 실호출)는 꼭 필요한 경우로만 최소화한다.
12. 커밋은 항상 사용자 승인 후에만 수행한다. 변경량이 크게 누적되면 다음 기능 작업 전에 커밋 분리를 먼저 제안한다.
13. 실제 API 키, secret, uid, 이메일, Storage URL 등 민감정보를 코드/커밋 메시지/문서 어디에도 리터럴로 남기지 않는다.
