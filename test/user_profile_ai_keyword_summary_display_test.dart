// 이 테스트는 concrete FirestoreService/SafetyService 인스턴스 생성을 위해
// firebase_core 플랫폼 인터페이스를 fake로 바꾼다. 두 플랫폼 인터페이스 패키지는
// pubspec 직접 의존성은 아니지만(transitive), 테스트 인프라에서만 쓰므로
// depend_on_referenced_packages 린트를 파일 단위로 무시한다(pubspec 미변경).
// ignore_for_file: depend_on_referenced_packages
import 'package:dating_app/features/profile/user_profile_screen.dart';
import 'package:dating_app/models/ai_keyword_summary.dart';
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
  int getPublicCalls = 0;
  int getPrivateCalls = 0;

  @override
  Future<PublicProfile?> getPublicProfile(String uid) async {
    getPublicCalls++;
    return result;
  }

  @override
  Future<UserProfile?> getUserProfile(String uid) async {
    getPrivateCalls++;
    fail('UserProfileScreen은 비공개 users/{uid}를 조회하면 안 된다 (uid=$uid)');
  }
}

AiKeywordSummary _summary({
  List<String> keywords = const ['차분한 대화', '주말 산책', '진지한 관계'],
  String generator = 'ai',
  String? model = 'gpt-4o-mini',
}) {
  return AiKeywordSummary(
    keywords: keywords,
    sourceHash:
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    promptVersion: 7,
    generator: generator,
    model: model,
    generatedAt: DateTime(2026, 7, 19, 12),
  );
}

PublicProfile _profile({
  AiKeywordSummary? summary,
  String bio = '',
  List<ProfileStory> profileStories = const [],
  Map<String, String> valueAnswers = const {},
  int? height,
  List<String> interests = const [],
  List<String> personalityTags = const [],
  List<String> idealTags = const [],
  String? relationshipGoal,
}) {
  return PublicProfile(
    uid: 'target-1',
    displayName: '지민',
    age: 27,
    gender: 'female',
    bio: bio,
    height: height,
    interests: interests,
    personalityTags: personalityTags,
    idealTags: idealTags,
    relationshipGoal: relationshipGoal,
    valueAnswers: valueAnswers,
    profileStories: profileStories,
    aiKeywordSummary: summary,
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

Finder _section() =>
    find.byKey(const ValueKey('profile-keyword-summary-section'));
Finder _chip(int index) =>
    find.byKey(ValueKey('profile-keyword-summary-chip-$index'));
Finder _label(int index) =>
    find.byKey(ValueKey('profile-keyword-summary-label-$index'));
Finder _storySection() => find.byKey(const ValueKey('profile-stories-section'));

Future<void> _scrollToKeywordSummary(WidgetTester tester) async {
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

  group('AI 키워드 요약 표시', () {
    testWidgets('generator ai는 AI 제목, sparkle icon, 저장 순서의 # 키워드를 표시한다', (
      tester,
    ) async {
      final profile = _profile(
        bio: '서로의 하루를 차분히 나누고 싶어요.',
        summary: _summary(),
        profileStories: const [
          ProfileStory(promptKey: 'weekend', answer: '공원 산책을 해요.'),
        ],
        height: 168,
        interests: const ['movie'],
        personalityTags: const ['calm'],
        idealTags: const ['same_hobby'],
        valueAnswers: const {'contact_frequency': 'few_times'},
        relationshipGoal: 'serious_relationship',
      );
      final fs = _FakeFirestoreService(profile);
      await _pump(tester, profile, fs);
      await tester.pumpAndSettle();
      await _scrollToKeywordSummary(tester);

      expect(_section(), findsOneWidget);
      expect(find.text('AI가 요약한 키워드'), findsOneWidget);
      expect(find.byIcon(Icons.auto_awesome_rounded), findsOneWidget);
      expect(find.text('#차분한 대화'), findsOneWidget);
      expect(find.text('#주말 산책'), findsOneWidget);
      expect(find.text('#진지한 관계'), findsOneWidget);
      expect(find.text('차분한 대화'), findsNothing);

      for (var i = 0; i < 3; i++) {
        expect(_chip(i), findsOneWidget);
        expect(_label(i), findsOneWidget);
      }

      final labels = List<Text>.generate(
        3,
        (index) => tester.widget<Text>(_label(index)),
      );
      expect(labels.map((label) => label.data), [
        '#차분한 대화',
        '#주말 산책',
        '#진지한 관계',
      ]);

      final bioDy = tester.getTopLeft(find.text('서로의 하루를 차분히 나누고 싶어요.')).dy;
      final summaryDy = tester.getTopLeft(_section()).dy;
      await tester.scrollUntilVisible(
        _storySection(),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      final storyDy = tester.getTopLeft(_storySection()).dy;
      final detailDy = tester.getTopLeft(find.text('상세 정보')).dy;
      expect(bioDy, lessThan(summaryDy));
      expect(summaryDy, lessThan(storyDy));
      expect(storyDy, lessThan(detailDy));

      expect(find.text('가치관'), findsOneWidget);
      expect(find.text('연락 빈도'), findsOneWidget);
      expect(find.text('영화'), findsOneWidget);
      expect(find.text('차분한'), findsOneWidget);
      expect(find.text('취미가 같은'), findsOneWidget);
      expect(find.text('진지한 연애를 시작하고 싶어요'), findsOneWidget);
      expect(fs.getPublicCalls, 1);
      expect(fs.getPrivateCalls, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('generator fallback은 프로필 키워드로 표시하고 AI로 오표시하지 않는다', (
      tester,
    ) async {
      final profile = _profile(
        summary: _summary(
          keywords: const ['주말 산책', '진지한 관계'],
          generator: 'fallback',
          model: null,
        ),
      );
      final fs = _FakeFirestoreService(profile);
      await _pump(tester, profile, fs);
      await tester.pumpAndSettle();
      await _scrollToKeywordSummary(tester);

      expect(_section(), findsOneWidget);
      expect(find.text('프로필 키워드'), findsOneWidget);
      expect(find.text('AI가 요약한 키워드'), findsNothing);
      expect(find.byIcon(Icons.auto_awesome_rounded), findsNothing);
      expect(find.text('#주말 산책'), findsOneWidget);
      expect(find.text('#진지한 관계'), findsOneWidget);
    });

    testWidgets('summary null, 0개, 1개 키워드는 빈 상태 없이 섹션을 숨긴다', (tester) async {
      for (final profile in [
        _profile(),
        _profile(summary: _summary(keywords: const [])),
        _profile(summary: _summary(keywords: const ['차분한 대화'])),
      ]) {
        final fs = _FakeFirestoreService(profile);
        await _pump(tester, profile, fs);
        await tester.pumpAndSettle();

        expect(_section(), findsNothing);
        expect(find.text('AI가 요약한 키워드'), findsNothing);
        expect(find.text('프로필 키워드'), findsNothing);
        expect(find.text('아직 분석되지 않았어요'), findsNothing);
        expect(find.text('placeholder'), findsNothing);
      }
    });

    testWidgets('5개 키워드를 모두 Wrap으로 표시하고 작은 화면에서도 overflow가 없다', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final profile = _profile(
        summary: _summary(
          keywords: const ['차분한 대화', '주말 산책', '진지한 관계', '취향 존중', '느린 호흡'],
        ),
      );
      final fs = _FakeFirestoreService(profile);
      await _pump(tester, profile, fs);
      await tester.pumpAndSettle();
      await _scrollToKeywordSummary(tester);

      final wrap = find.descendant(of: _section(), matching: find.byType(Wrap));
      expect(wrap, findsOneWidget);
      for (var i = 0; i < 5; i++) {
        expect(_chip(i), findsOneWidget);
      }
      expect(find.text('#느린 호흡'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('metadata와 기술 문구를 노출하지 않는다', (tester) async {
      final profile = _profile(summary: _summary());
      final fs = _FakeFirestoreService(profile);
      await _pump(tester, profile, fs);
      await tester.pumpAndSettle();
      await _scrollToKeywordSummary(tester);

      expect(
        find.text(
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        ),
        findsNothing,
      );
      expect(find.text('gpt-4o-mini'), findsNothing);
      expect(find.text('ai'), findsNothing);
      expect(find.text('7'), findsNothing);
      expect(find.textContaining('2026'), findsNothing);
      expect(find.textContaining('source hash'), findsNothing);
      expect(find.textContaining('cache'), findsNothing);
      expect(find.textContaining('fallback'), findsNothing);
    });
  });

  group('새로고침', () {
    testWidgets('refresh로 summary가 생기면 섹션이 나타나고 public profile read만 사용한다', (
      tester,
    ) async {
      final initial = _profile();
      final refreshed = _profile(
        summary: _summary(keywords: const ['첫 번째', '두 번째', '세 번째']),
      );
      final fs = _FakeFirestoreService(initial);
      await _pump(tester, initial, fs);
      await tester.pumpAndSettle();

      expect(_section(), findsNothing);

      fs.result = refreshed;
      final refresh = tester
          .state<RefreshIndicatorState>(find.byType(RefreshIndicator))
          .show();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await refresh;
      await tester.pump();
      await _scrollToKeywordSummary(tester);

      expect(_section(), findsOneWidget);
      expect(find.text('#첫 번째'), findsOneWidget);
      expect(find.text('#두 번째'), findsOneWidget);
      expect(find.text('#세 번째'), findsOneWidget);
      expect(fs.getPublicCalls, 2);
      expect(fs.getPrivateCalls, 0);
    });

    testWidgets('refresh 결과에 summary가 없으면 기존 섹션이 사라진다', (tester) async {
      final initial = _profile(summary: _summary());
      final refreshed = _profile();
      final fs = _FakeFirestoreService(initial);
      await _pump(tester, initial, fs);
      await tester.pumpAndSettle();
      await _scrollToKeywordSummary(tester);

      expect(_section(), findsOneWidget);

      fs.result = refreshed;
      final refresh = tester
          .state<RefreshIndicatorState>(find.byType(RefreshIndicator))
          .show();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await refresh;
      await tester.pump();

      expect(_section(), findsNothing);
      expect(find.text('AI가 요약한 키워드'), findsNothing);
      expect(fs.getPublicCalls, 2);
      expect(fs.getPrivateCalls, 0);
    });
  });
}
