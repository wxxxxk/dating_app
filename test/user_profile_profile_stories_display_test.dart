// 이 테스트는 concrete FirestoreService/SafetyService 인스턴스 생성을 위해
// firebase_core 플랫폼 인터페이스를 fake로 바꾼다. 두 플랫폼 인터페이스 패키지는
// pubspec 직접 의존성은 아니지만(transitive), 테스트 인프라에서만 쓰므로
// depend_on_referenced_packages 린트를 파일 단위로 무시한다(pubspec 미변경).
// ignore_for_file: depend_on_referenced_packages
import 'dart:async';

import 'package:dating_app/core/theme/app_colors.dart';
import 'package:dating_app/features/profile/user_profile_screen.dart';
import 'package:dating_app/models/profile_story.dart';
import 'package:dating_app/models/public_profile.dart';
import 'package:dating_app/models/user_profile.dart';
import 'package:dating_app/services/database/firestore_service.dart';
import 'package:dating_app/services/safety/safety_service.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _FakeApp extends Fake
    with MockPlatformInterfaceMixin
    implements FirebaseAppPlatform {
  @override
  String get name => defaultFirebaseAppName;

  @override
  FirebaseOptions get options => const FirebaseOptions(
    apiKey: 'k',
    appId: 'a',
    messagingSenderId: 's',
    projectId: 'p',
    storageBucket: 'b.appspot.com',
  );
}

class _FakeFirebasePlatform extends FirebasePlatform {
  @override
  FirebaseAppPlatform app([String name = defaultFirebaseAppName]) => _FakeApp();

  @override
  Future<FirebaseAppPlatform> initializeApp({
    String? name,
    FirebaseOptions? options,
  }) async => _FakeApp();

  @override
  List<FirebaseAppPlatform> get apps => [_FakeApp()];
}

class _FakeFirestoreService extends FirestoreService {
  _FakeFirestoreService(this.result);

  PublicProfile? result;
  Completer<PublicProfile?>? completer;
  int getPublicCalls = 0;

  @override
  Future<PublicProfile?> getPublicProfile(String uid) async {
    getPublicCalls++;
    if (completer != null) return completer!.future;
    return result;
  }

  @override
  Future<UserProfile?> getUserProfile(String uid) async {
    fail('UserProfileScreen은 비공개 users/{uid}를 조회하면 안 된다 (uid=$uid)');
  }
}

PublicProfile _profile({
  String uid = 'target-1',
  String bio = '',
  List<ProfileStory> profileStories = const [],
  Map<String, String> valueAnswers = const {},
  List<String> photoUrls = const [],
  int? height,
  List<String> interests = const [],
  List<String> personalityTags = const [],
  List<String> idealTags = const [],
  String? relationshipGoal,
}) {
  return PublicProfile(
    uid: uid,
    displayName: '지민',
    age: 27,
    gender: 'female',
    bio: bio,
    photoUrls: photoUrls,
    height: height,
    interests: interests,
    personalityTags: personalityTags,
    idealTags: idealTags,
    relationshipGoal: relationshipGoal,
    valueAnswers: valueAnswers,
    profileStories: profileStories,
  );
}

Future<void> _pump(
  WidgetTester tester,
  PublicProfile initial,
  _FakeFirestoreService fs,
) async {
  final safety = SafetyService(firestoreService: fs);
  await tester.pumpWidget(
    MaterialApp(
      home: UserProfileScreen(
        currentUid: 'me',
        initialProfile: initial,
        currentLocation: null,
        firestoreService: fs,
        safetyService: safety,
      ),
    ),
  );
}

Finder _section() => find.byKey(const ValueKey('profile-stories-section'));
Finder _card(String key) => find.byKey(ValueKey('profile-story-display-$key'));
Finder _promptLabel(String key) =>
    find.byKey(ValueKey('profile-story-prompt-label-$key'));
Finder _answerLabel(String key) =>
    find.byKey(ValueKey('profile-story-answer-label-$key'));

Future<void> _scrollToStories(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    _section(),
    250,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FirebasePlatform.instance = _FakeFirebasePlatform();

  group('이야기 카드 기본 표시', () {
    testWidgets('유효 story 1개면 섹션·질문·답변 key를 표시하고 raw key는 숨긴다', (tester) async {
      final profile = _profile(
        profileStories: const [
          ProfileStory(promptKey: 'happy_moment', answer: '맛있는 것을 먹을 때예요.'),
        ],
      );
      final fs = _FakeFirestoreService(profile);
      await _pump(tester, profile, fs);
      await tester.pumpAndSettle();
      await _scrollToStories(tester);

      expect(_section(), findsOneWidget);
      expect(find.text('이 사람의 이야기'), findsOneWidget);
      expect(_card('happy_moment'), findsOneWidget);
      expect(_promptLabel('happy_moment'), findsOneWidget);
      expect(_answerLabel('happy_moment'), findsOneWidget);
      expect(find.text('요즘 가장 행복한 순간은?'), findsOneWidget);
      expect(find.text('맛있는 것을 먹을 때예요.'), findsOneWidget);
      expect(find.text('happy_moment'), findsNothing);
    });

    testWidgets('이야기 카드는 밝은 배경용 semantic color를 사용한다', (tester) async {
      final profile = _profile(
        profileStories: const [
          ProfileStory(promptKey: 'happy_moment', answer: '맛있는 것을 먹을 때예요.'),
        ],
      );
      final fs = _FakeFirestoreService(profile);
      await _pump(tester, profile, fs);
      await tester.pumpAndSettle();
      await _scrollToStories(tester);

      // Phase 4-B: 어두운 독립 카드 → 밝은 interview surface 항목으로 전환.
      final card = tester.widget<Container>(_card('happy_moment'));
      final decoration = card.decoration as BoxDecoration;
      expect(decoration.color, AppColors.surfacePrimary);

      final question = tester.widget<Text>(_promptLabel('happy_moment'));
      expect(question.style?.color, AppColors.expressiveAccent);
      expect(question.style?.color, isNot(AppColors.textOnDark));

      final answer = tester.widget<Text>(_answerLabel('happy_moment'));
      expect(answer.style?.color, AppColors.textStrong);
      expect(answer.style?.color, isNot(AppColors.textOnDark));

      final sectionTitle = tester.widget<Text>(find.text('이 사람의 이야기'));
      expect(sectionTitle.style?.color, AppColors.textPrimary);
    });

    testWidgets('story 3개를 저장된 순서대로 표시하고 catalog 순서로 재배열하지 않는다', (
      tester,
    ) async {
      final profile = _profile(
        profileStories: const [
          ProfileStory(promptKey: 'weekend', answer: '늦잠 후 산책'),
          ProfileStory(promptKey: 'date_idea', answer: '새로운 동네 걷기'),
          ProfileStory(promptKey: 'happy_moment', answer: '좋아하는 사람과 식사'),
        ],
      );
      final fs = _FakeFirestoreService(profile);
      await _pump(tester, profile, fs);
      await tester.pumpAndSettle();
      await _scrollToStories(tester);

      expect(_card('weekend'), findsOneWidget);
      expect(_card('date_idea'), findsOneWidget);
      expect(_card('happy_moment'), findsOneWidget);

      final weekendDy = tester.getTopLeft(_card('weekend')).dy;
      final dateDy = tester.getTopLeft(_card('date_idea')).dy;
      final happyDy = tester.getTopLeft(_card('happy_moment')).dy;
      expect(weekendDy, lessThan(dateDy));
      expect(dateDy, lessThan(happyDy));
    });

    testWidgets('긴 100자 답변과 여러 줄 답변을 ellipsis 없이 렌더링한다', (tester) async {
      final longAnswer = 'a' * 100;
      const multiline = '첫 번째 줄\n두 번째 줄';
      final profile = _profile(
        profileStories: [
          ProfileStory(promptKey: 'happy_moment', answer: longAnswer),
          const ProfileStory(promptKey: 'weekend', answer: multiline),
        ],
      );
      final fs = _FakeFirestoreService(profile);
      await _pump(tester, profile, fs);
      await tester.pumpAndSettle();
      await _scrollToStories(tester);

      expect(find.text(longAnswer), findsOneWidget);
      expect(find.text(multiline), findsOneWidget);

      final text = tester.widget<Text>(_answerLabel('happy_moment'));
      expect(text.maxLines, isNull);
      expect(text.overflow, isNull);
    });
  });

  group('위치와 기존 섹션 공존', () {
    testWidgets('bio 다음, 상세 정보 이전에 표시되고 가치관과 별도로 공존한다', (tester) async {
      final profile = _profile(
        bio: '서로 잘 맞는 산책 친구를 찾고 있어요.',
        height: 168,
        valueAnswers: const {'contact_frequency': 'few_times'},
        profileStories: const [
          ProfileStory(promptKey: 'weekend', answer: '공원 산책을 해요.'),
        ],
      );
      final fs = _FakeFirestoreService(profile);
      await _pump(tester, profile, fs);
      await tester.pumpAndSettle();
      await _scrollToStories(tester);

      final bioDy = tester.getTopLeft(find.text('서로 잘 맞는 산책 친구를 찾고 있어요.')).dy;
      final storyDy = tester.getTopLeft(_section()).dy;
      final detailDy = tester.getTopLeft(find.text('상세 정보')).dy;
      expect(bioDy, lessThan(storyDy));
      expect(storyDy, lessThan(detailDy));

      expect(find.text('가치관'), findsOneWidget);
      expect(find.text('연락 빈도'), findsOneWidget);
      expect(find.text('하루에 몇 번'), findsOneWidget);
    });

    testWidgets('기존 이름·나이·태그·찾는 관계·신고/차단·pull-to-refresh를 유지한다', (
      tester,
    ) async {
      final profile = _profile(
        interests: const ['movie'],
        personalityTags: const ['calm'],
        idealTags: const ['same_hobby'],
        relationshipGoal: 'serious_relationship',
        profileStories: const [
          ProfileStory(promptKey: 'date_idea', answer: '작은 전시를 보고 싶어요.'),
        ],
      );
      final fs = _FakeFirestoreService(profile);
      await _pump(tester, profile, fs);
      await tester.pumpAndSettle();

      expect(find.text('지민, 27'), findsOneWidget);
      expect(find.byType(PopupMenuButton<String>), findsOneWidget);
      expect(find.byType(RefreshIndicator), findsOneWidget);
      expect(find.text('영화'), findsOneWidget);
      expect(find.text('차분한'), findsOneWidget);
      expect(find.text('취미가 같은'), findsOneWidget);
      expect(find.text('진지한 연애를 시작하고 싶어요'), findsOneWidget);
    });
  });

  group('빈 값과 unknown 처리', () {
    testWidgets('빈 list면 섹션을 표시하지 않는다', (tester) async {
      final profile = _profile();
      final fs = _FakeFirestoreService(profile);
      await _pump(tester, profile, fs);
      await tester.pumpAndSettle();

      expect(_section(), findsNothing);
      expect(find.text('아직 작성한 이야기가 없어요'), findsNothing);
    });

    testWidgets('unknown promptKey만 있으면 섹션을 숨기고 raw key를 노출하지 않는다', (
      tester,
    ) async {
      final profile = _profile(
        profileStories: const [
          ProfileStory(promptKey: 'unknown_future', answer: '보존되는 답변'),
        ],
      );
      final fs = _FakeFirestoreService(profile);
      await _pump(tester, profile, fs);
      await tester.pumpAndSettle();

      expect(_section(), findsNothing);
      expect(find.text('unknown_future'), findsNothing);
      expect(find.text('보존되는 답변'), findsNothing);
    });

    testWidgets('valid와 unknown이 섞이면 valid만 표시하되 known 상대 순서를 유지한다', (
      tester,
    ) async {
      final profile = _profile(
        profileStories: const [
          ProfileStory(promptKey: 'weekend', answer: '늦잠'),
          ProfileStory(promptKey: 'unknown_future', answer: '숨김'),
          ProfileStory(promptKey: 'happy_moment', answer: '식사'),
        ],
      );
      final fs = _FakeFirestoreService(profile);
      await _pump(tester, profile, fs);
      await tester.pumpAndSettle();
      await _scrollToStories(tester);

      expect(_card('weekend'), findsOneWidget);
      expect(_card('happy_moment'), findsOneWidget);
      expect(find.text('unknown_future'), findsNothing);
      expect(find.text('숨김'), findsNothing);

      final weekendDy = tester.getTopLeft(_card('weekend')).dy;
      final happyDy = tester.getTopLeft(_card('happy_moment')).dy;
      expect(weekendDy, lessThan(happyDy));
    });

    testWidgets('공백 answer와 emoji/제어문자 제거 후 빈 answer는 숨긴다', (tester) async {
      final profile = _profile(
        profileStories: const [
          ProfileStory(promptKey: 'happy_moment', answer: '   '),
          ProfileStory(promptKey: 'weekend', answer: '💖\u0001'),
        ],
      );
      final fs = _FakeFirestoreService(profile);
      await _pump(tester, profile, fs);
      await tester.pumpAndSettle();

      expect(_section(), findsNothing);
    });

    testWidgets('표시 answer에서 emoji와 제어문자를 제거한다', (tester) async {
      final profile = _profile(
        profileStories: const [
          ProfileStory(promptKey: 'happy_moment', answer: '  산책💖\u0001 좋아요  '),
        ],
      );
      final fs = _FakeFirestoreService(profile);
      await _pump(tester, profile, fs);
      await tester.pumpAndSettle();
      await _scrollToStories(tester);

      expect(find.text('산책 좋아요'), findsOneWidget);
      expect(find.textContaining('💖'), findsNothing);
    });
  });

  group('새로고침', () {
    testWidgets('refresh 완료 전에는 initialProfile의 story를 즉시 표시한다', (
      tester,
    ) async {
      final initial = _profile(
        profileStories: const [
          ProfileStory(promptKey: 'weekend', answer: '처음 답변'),
        ],
      );
      final fs = _FakeFirestoreService(null)..completer = Completer();
      await _pump(tester, initial, fs);
      await tester.pump();
      await _scrollToStories(tester);

      expect(_card('weekend'), findsOneWidget);
      expect(find.text('처음 답변'), findsOneWidget);

      fs.completer!.complete(initial);
      await tester.pumpAndSettle();
    });

    testWidgets('refresh 결과의 새 story와 순서 변경을 반영한다', (tester) async {
      final initial = _profile(
        profileStories: const [
          ProfileStory(promptKey: 'happy_moment', answer: '처음 답변'),
        ],
      );
      final refreshed = _profile(
        profileStories: const [
          ProfileStory(promptKey: 'date_idea', answer: '전시 보기'),
          ProfileStory(promptKey: 'weekend', answer: '산책하기'),
        ],
      );
      final fs = _FakeFirestoreService(refreshed);
      await _pump(tester, initial, fs);
      await tester.pumpAndSettle();
      await _scrollToStories(tester);

      expect(_card('happy_moment'), findsNothing);
      expect(_card('date_idea'), findsOneWidget);
      expect(_card('weekend'), findsOneWidget);
      expect(
        tester.getTopLeft(_card('date_idea')).dy,
        lessThan(tester.getTopLeft(_card('weekend')).dy),
      );
    });

    testWidgets('refresh 결과가 빈 list면 섹션을 제거한다', (tester) async {
      final initial = _profile(
        profileStories: const [
          ProfileStory(promptKey: 'happy_moment', answer: '처음 답변'),
        ],
      );
      final refreshed = _profile();
      final fs = _FakeFirestoreService(refreshed);
      await _pump(tester, initial, fs);
      await tester.pumpAndSettle();

      expect(_section(), findsNothing);
    });

    testWidgets('refresh 결과가 unknown-only면 섹션을 제거한다', (tester) async {
      final initial = _profile(
        profileStories: const [
          ProfileStory(promptKey: 'happy_moment', answer: '처음 답변'),
        ],
      );
      final refreshed = _profile(
        profileStories: const [
          ProfileStory(promptKey: 'unknown_future', answer: '숨김'),
        ],
      );
      final fs = _FakeFirestoreService(refreshed);
      await _pump(tester, initial, fs);
      await tester.pumpAndSettle();

      expect(_section(), findsNothing);
      expect(find.text('unknown_future'), findsNothing);
    });
  });

  group('데이터 경계와 작은 화면', () {
    testWidgets('PublicProfile.profileStories만 사용하고 추가 private read 없이 표시한다', (
      tester,
    ) async {
      final profile = _profile(
        profileStories: const [
          ProfileStory(promptKey: 'comfort_food', answer: '따뜻한 국물 요리'),
        ],
      );
      final fs = _FakeFirestoreService(profile);
      await _pump(tester, profile, fs);
      await tester.pumpAndSettle();
      await _scrollToStories(tester);

      expect(find.text('기분 좋아지는 음식은?'), findsOneWidget);
      expect(find.text('따뜻한 국물 요리'), findsOneWidget);
      expect(fs.getPublicCalls, 1);
    });

    testWidgets('작은 화면에서 3개 긴 답변도 overflow 없이 스크롤 가능하다', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final longAnswer = '차분하게 대화하면서 서로의 하루를 나누고 싶은 마음이 있어요. ' * 2;
      final profile = _profile(
        profileStories: [
          ProfileStory(promptKey: 'happy_moment', answer: longAnswer),
          ProfileStory(promptKey: 'weekend', answer: longAnswer),
          ProfileStory(promptKey: 'date_idea', answer: longAnswer),
        ],
      );
      final fs = _FakeFirestoreService(profile);
      await _pump(tester, profile, fs);
      await tester.pumpAndSettle();
      await _scrollToStories(tester);
      await tester.scrollUntilVisible(
        _card('date_idea'),
        250,
        scrollable: find.byType(Scrollable).first,
      );

      expect(_card('date_idea'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
