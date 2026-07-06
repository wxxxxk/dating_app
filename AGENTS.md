# CLAUDE.md

이 파일은 다음 Claude Code 세션이 시작하자마자 프로젝트 맥락을 파악하도록 만든
현재 상태 스냅샷이다. 코드가 바뀌면 이 파일도 같이 갱신할 것.

## 1. 프로젝트 개요

- **이름**: `dating_app` (Flutter)
- **Firebase 프로젝트**: `cvr-dating-app` (`.firebaserc`, `firebase.json`)
- **스택**: Flutter/Dart + Firebase(Auth/Firestore/Storage/Messaging/Functions) + Google Sign-In
- **AI**: Cloud Functions에서 OpenAI(GPT/DALL·E) 호출 — 앱에는 키가 전혀 없음
- **저장소**: GitHub `github.com/wxxxxk/dating_app` (private)

## 2. 폴더 구조

```
lib/
├── core/        # 상수(profile_options, app_constants), 테마, 라우트 이름, validators
├── dev/         # 개발용 더미 데이터 생성 (dummy_data_service.dart) — 출시 전 검토 대상
├── features/    # 화면(UI) 단위: auth·charm·chat·discovery·fortune·home·
│                #   ideal_type·jelly·likes·matches·onboarding·profile·safety
├── models/      # 데이터 모델: charm/fortune/ideal_type/match/message/user_profile
├── services/    # Firestore·Functions 접근 계층. features와 1:1 대응 다수
└── shared/      # 공용 상태(auth_state)·위젯(버튼, 로딩 인디케이터)

functions/       # Cloud Functions 소스 (index.js 1개 파일)
test/            # 단위 테스트
android/, ios/   # 네이티브 프로젝트
```

## 3. 기능 구현 상태

| 기능 | 상태 | 비고 |
|---|---|---|
| 인증(이메일/구글) | ✅ 구현완료 | `services/auth/auth_service.dart` |
| 전화번호 인증 | ❌ 미구현 | `auth_service.dart:216` — `TODO(M2 구현): 실제 전화 인증 흐름` (구현부가 주석 처리된 상태) |
| 온보딩 | ✅ 구현완료 | `features/onboarding/*` |
| 프로필(조회/편집) | ✅ 구현완료 | `features/profile/*` |
| 디스커버리(스와이프) | ✅ 구현완료 | `features/discovery/*` |
| 매칭 | ✅ 구현완료 | `features/matches/*`, functions `onSwipeCreated` |
| 채팅 | ✅ 구현완료 | `features/chat/chat_screen.dart` |
| 사주(운세/궁합/아이스브레이커) | ✅ 구현완료 | `features/fortune/*` — 가장 큰 기능 묶음 |
| 매력 리포트 | ✅ 구현완료 | `features/charm/*`, functions `generateCharmReport` |
| 이상형 이미지 생성 | ✅ 구현완료 (⚠️ 모델명 재확인 필요) | `functions/index.js:1018` — **현재 `model: 'dall-e-3'` 사용 중**. gpt-image 계열로 교체 검토 이력이 있었으나 **아직 교체되지 않은 상태로 확인됨**(2026-07-06 재확인). 다음 세션에서 모델 교체 여부를 다시 결정할 것. |
| 젤리(재화) 결제 | 🟡 목업 단계 | `jelly_shop_screen.dart:92` — `TODO: 출시 시 in_app_purchase 연동 및 서버 영수증 검증으로 교체` |

## 4. Cloud Functions (`functions/index.js`, exports 7개)

| 함수 | 트리거 | 역할 |
|---|---|---|
| `onSwipeCreated` | `onDocumentWritten('users/{uid}/swipes/{targetUid}')` | 스와이프 생성/수정 시 상호 like/superlike 확인 후 `matches/{matchId}` 멱등 생성 |
| `generateFortuneNarrative` | callable | 내 사주 서사 생성, `users/{uid}.fortuneNarrative`에 캐싱 |
| `generateMatchNarrative` | callable | 두 사람 궁합 서사, `matches/{matchId}.fortuneMatch`에 캐싱 (participants 권한 확인) |
| `generateIcebreakers` | callable | 매칭 상대와의 사주 기반 대화 물꼬 생성, `matches/{matchId}.icebreakers`에 캐싱 |
| `generateDailyFortune` | callable | 오늘의 운세(애정 중심), `users/{uid}/dailyFortune/{date}`에 날짜별 캐싱 |
| `generateCharmReport` | callable | 프로필 기반 매력 리포트, `users/{uid}.charmReport`에 캐싱(`refresh` 옵션 시 재생성) |
| `generateIdealTypeImage` | callable(`timeoutSeconds:120, memory:1GiB`) | AI 이상형 이미지 생성(`dall-e-3`), `users/{uid}.idealTypeImage.inputHash` 기준 캐싱 |

모든 GPT 호출 함수는 `OPENAI_API_KEY` Firebase Secret을 `defineSecret(...).value()`로만 읽는다 — 코드에 키 리터럴 없음.

## 5. 알려진 이슈 / 배포 전 체크리스트

- [ ] **`firestore.rules`의 `dummy_.*` 예외 규칙 2곳** (라인 16~29, 37~50) —
  `RELEASE-BLOCKER` 마커로 표시돼 있음. 배포 전 이 저장소에서 `"RELEASE-BLOCKER"`를
  검색해 반드시 제거하고 `firebase deploy --only firestore:rules` 재배포할 것.
  - 첫 번째(`users/{uid}` 쓰기 예외) 제거 시: `lib/dev/dummy_data_service.dart`의
    `createUserProfile()` 호출(35번 줄)이 try/catch로 감싸여 있지 않아 더미 생성이
    **즉시 permission-denied로 하드 실패**한다.
  - 두 번째(`swipes` 쓰기 예외) 제거 시: 같은 파일의 역방향 좋아요 쓰기는
    try/catch로 감싸여 있어(51~73번 줄) 앱이 죽지는 않고, "즉시 매칭" 데모
    효과만 조용히 사라진다.
  - 두 규칙 모두 아직 활성 개발 기능이 의존 중이므로 지금 당장 삭제하지 않음 —
    배포 직전 체크리스트로만 남겨둔 상태(2026-07-06 판단).
- [ ] **Cloud Functions 의존성 메이저 업그레이드** — 현재 `firebase-admin@12.7.0`
  (latest 14.x), `firebase-functions@6.6.0`(latest 7.x). Node 20 런타임 지원
  종료가 2026-10-30로 예정돼 있어, 그 전에 Node 22 등 상위 런타임 + 라이브러리
  메이저 업그레이드를 함께 검토해야 한다.
- [ ] **젤리 결제 목업 → 실연동** — `in_app_purchase` 영수증 검증 후 서버(Functions)에서
  충전/차감하는 구조로 교체 필요. 현재는 클라이언트가 직접 Firestore 트랜잭션으로
  잔액을 갱신한다(`services/jelly/jelly_service.dart`).
- [ ] **`auth_service.dart:216`의 전화번호 인증** — 구현부가 주석 처리된 상태로 남아있음.

## 6. 배포 주의사항

- **리전**: 프로젝트 방침은 `asia-northeast3`이지만, **`functions/index.js`에는
  현재 리전 설정이 전혀 없다**(`onCall`/`onDocumentWritten` 어디에도 `region` 옵션
  없음 — grep으로 확인, 2026-07-06). 그대로 배포하면 Firebase 기본 리전(`us-central1`)으로
  나간다. 리전을 맞추려면 각 함수 옵션에 `region: 'asia-northeast3'`를 추가하거나
  `setGlobalOptions({ region: 'asia-northeast3' })`를 도입해야 한다 — **아직 안 된 상태**.
- **OPENAI_API_KEY**: Firebase Secret으로만 관리 (`firebase functions:secrets:set OPENAI_API_KEY`).
  앱/저장소 어디에도 실제 키 리터럴을 넣지 않는다.
- **`.env`**: 실제 값은 절대 커밋하지 않는다. `.env.example`(placeholder만)만 커밋 대상.
- 배포 전 firestore.rules의 RELEASE-BLOCKER 항목(5절 참고) 제거 여부를 항상 재확인할 것.

## 7. 개발 워크플로우

- **역할 분리**: 설계·검증은 사람이 담당하고, 구현은 Claude Code / Codex가 수행한다.
- **버전관리**: git 저장소 — `github.com/wxxxxk/dating_app` (private repo), 기본 브랜치 `main`.
- 커밋은 명시적으로 요청받았을 때만 생성한다(자동 커밋 금지).
