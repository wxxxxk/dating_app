// 이 테스트는 concrete FirestoreService/SafetyService 인스턴스 생성을 위해
// firebase_core 플랫폼 인터페이스를 fake로 바꾼다. 두 플랫폼 인터페이스 패키지는
// pubspec 직접 의존성은 아니지만(transitive), 테스트 인프라에서만 쓰므로
// depend_on_referenced_packages 린트를 파일 단위로 무시한다(pubspec 미변경).
// 이 파일에는 UserProfileScreen 전용 widget 테스트 helper가 아직 없어,
// profile_edit_value_answers_test.dart와 동일한 최소 플랫폼 fake만 재사용한다.
// ignore_for_file: depend_on_referenced_packages
import 'dart:async';

import 'package:dating_app/features/profile/user_profile_screen.dart';
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

/// getPublicProfile 결과만 제어하는 test double.
///
/// [completer]가 있으면 그 future를 반환해 refresh 타이밍을 테스트가 통제한다.
/// UserProfileScreen이 실수로 비공개 users 문서를 조회하지 않는지 검증하기 위해
/// getUserProfile은 호출되면 곧바로 실패시킨다.
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
  Map<String, String> valueAnswers = const {},
  List<String> photoUrls = const [],
}) {
  return PublicProfile(
    uid: uid,
    displayName: '지민',
    age: 27,
    gender: 'female',
    photoUrls: photoUrls,
    valueAnswers: valueAnswers,
  );
}

Future<void> _pump(
  WidgetTester tester,
  PublicProfile initial,
  FirestoreService fs,
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
    find.byKey(const ValueKey('profile-value-answers-section'));
Finder _answerItem(String q) => find.byKey(ValueKey('profile-value-answer-$q'));
Finder _questionLabel(String q) =>
    find.byKey(ValueKey('profile-value-question-$q'));

Future<void> _scrollToSection(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    _section(),
    250,
    scrollable: find.byType(Scrollable).first,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FirebasePlatform.instance = _FakeFirebasePlatform();

  group('가치관 기본 표시', () {
    testWidgets('유효한 valueAnswers가 있으면 가치관 섹션과 라벨을 표시한다', (tester) async {
      final profile = _profile(
        valueAnswers: const {
          'contact_frequency': 'few_times',
          'date_style': 'foodie',
        },
      );
      final fs = _FakeFirestoreService(profile);
      await _pump(tester, profile, fs);
      await tester.pumpAndSettle();
      await _scrollToSection(tester);

      expect(_section(), findsOneWidget);
      // profileLabel + answerLabel(카탈로그 변환값)이 사용자에게 보인다.
      expect(find.text('연락 빈도'), findsOneWidget);
      expect(find.text('하루에 몇 번'), findsOneWidget);
      expect(find.text('데이트 스타일'), findsOneWidget);
      expect(find.text('맛집 탐방'), findsOneWidget);
    });

    testWidgets('질문은 카탈로그(ValueQuestions.all) 순서로 표시된다', (tester) async {
      // 삽입 순서를 카탈로그 순서와 반대로 준다.
      final profile = _profile(
        valueAnswers: const {
          'life_rhythm': 'morning', // 카탈로그 index 5
          'contact_frequency': 'few_times', // 카탈로그 index 0
        },
      );
      final fs = _FakeFirestoreService(profile);
      await _pump(tester, profile, fs);
      await tester.pumpAndSettle();
      await _scrollToSection(tester);

      final contactDy = tester.getTopLeft(_answerItem('contact_frequency')).dy;
      final rhythmDy = tester.getTopLeft(_answerItem('life_rhythm')).dy;
      expect(contactDy, lessThan(rhythmDy));
    });

    testWidgets('6문항 전체가 정상 표시된다', (tester) async {
      final profile = _profile(
        valueAnswers: const {
          'contact_frequency': 'all_day',
          'conflict_style': 'talk_now',
          'date_style': 'active',
          'alone_time': 'some',
          'affection_expression': 'words',
          'life_rhythm': 'night',
        },
      );
      final fs = _FakeFirestoreService(profile);
      await _pump(tester, profile, fs);
      await tester.pumpAndSettle();
      await _scrollToSection(tester);

      for (final q in const [
        'contact_frequency',
        'conflict_style',
        'date_style',
        'alone_time',
        'affection_expression',
        'life_rhythm',
      ]) {
        expect(_answerItem(q), findsOneWidget, reason: q);
      }
    });

    testWidgets('저장 key 원문은 사용자에게 표시되지 않는다', (tester) async {
      final profile = _profile(
        valueAnswers: const {'contact_frequency': 'few_times'},
      );
      final fs = _FakeFirestoreService(profile);
      await _pump(tester, profile, fs);
      await tester.pumpAndSettle();
      await _scrollToSection(tester);

      expect(find.text('contact_frequency'), findsNothing);
      expect(find.text('few_times'), findsNothing);
    });

    testWidgets('작은 화면에서도 6문항이 overflow 없이 표시된다', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final profile = _profile(
        valueAnswers: const {
          'contact_frequency': 'all_day',
          'conflict_style': 'soften',
          'date_style': 'culture',
          'alone_time': 'together',
          'affection_expression': 'actions',
          'life_rhythm': 'flexible',
        },
      );
      final fs = _FakeFirestoreService(profile);
      await _pump(tester, profile, fs);
      await tester.pumpAndSettle();
      await _scrollToSection(tester);

      expect(_section(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('빈 값과 잘못된 값', () {
    testWidgets('빈 map이면 가치관 섹션을 표시하지 않는다', (tester) async {
      final profile = _profile();
      final fs = _FakeFirestoreService(profile);
      await _pump(tester, profile, fs);
      await tester.pumpAndSettle();

      expect(_section(), findsNothing);
    });

    testWidgets('알 수 없는 question key만 있으면 섹션을 표시하지 않는다', (tester) async {
      final profile = _profile(
        valueAnswers: const {'legacy_removed_question': 'whatever'},
      );
      final fs = _FakeFirestoreService(profile);
      await _pump(tester, profile, fs);
      await tester.pumpAndSettle();

      expect(_section(), findsNothing);
    });

    testWidgets('known question + invalid answer이면 해당 항목을 표시하지 않는다', (
      tester,
    ) async {
      final profile = _profile(
        valueAnswers: const {'contact_frequency': 'not_a_real_option'},
      );
      final fs = _FakeFirestoreService(profile);
      await _pump(tester, profile, fs);
      await tester.pumpAndSettle();

      expect(_section(), findsNothing);
    });

    testWidgets('valid와 invalid/unknown이 섞이면 valid 항목만 표시된다', (tester) async {
      final profile = _profile(
        valueAnswers: const {
          'contact_frequency': 'few_times', // valid
          'conflict_style': 'not_a_real_option', // invalid answer
          'legacy_removed_question': 'x', // unknown question
          'date_style': 'cozy', // valid
        },
      );
      final fs = _FakeFirestoreService(profile);
      await _pump(tester, profile, fs);
      await tester.pumpAndSettle();
      await _scrollToSection(tester);

      expect(_answerItem('contact_frequency'), findsOneWidget);
      expect(_answerItem('date_style'), findsOneWidget);
      expect(_answerItem('conflict_style'), findsNothing);
      // unknown key가 valid 항목 렌더링을 방해하지 않는다.
      expect(find.text('편안한 실내 데이트'), findsOneWidget);
    });
  });

  group('데이터 경계', () {
    testWidgets('가치관 표시는 비공개 users 조회 없이 PublicProfile.valueAnswers만 사용한다', (
      tester,
    ) async {
      // _FakeFirestoreService.getUserProfile은 호출 시 fail()이므로,
      // 이 테스트가 통과한다는 것은 users/{uid} 조회가 없었다는 뜻이다.
      final profile = _profile(
        valueAnswers: const {'contact_frequency': 'once_a_day'},
      );
      final fs = _FakeFirestoreService(profile);
      await _pump(tester, profile, fs);
      await tester.pumpAndSettle();
      await _scrollToSection(tester);

      expect(find.text('하루 한 번쯤'), findsOneWidget);
      // 공개 프로필 재조회는 있었지만, 그 외 추가 read 경로는 없다.
      expect(fs.getPublicCalls, 1);
    });
  });

  group('새로고침', () {
    testWidgets('refresh 완료 전에는 initialProfile의 답변을 표시한다', (tester) async {
      final initial = _profile(
        valueAnswers: const {'contact_frequency': 'few_times'},
      );
      final fs = _FakeFirestoreService(null)..completer = Completer();
      await _pump(tester, initial, fs);
      await tester.pump(); // refresh 미완료 상태
      await _scrollToSection(tester);

      expect(_questionLabel('contact_frequency'), findsOneWidget);
      expect(find.text('하루에 몇 번'), findsOneWidget);

      // 열린 future를 닫아 pending timer 경고를 방지한다.
      fs.completer!.complete(initial);
      await tester.pumpAndSettle();
    });

    testWidgets('refresh 응답의 새 답변으로 섹션이 갱신된다', (tester) async {
      final initial = _profile(
        valueAnswers: const {'contact_frequency': 'few_times'},
      );
      final refreshed = _profile(valueAnswers: const {'date_style': 'active'});
      final fs = _FakeFirestoreService(refreshed);
      await _pump(tester, initial, fs);
      await tester.pumpAndSettle();
      await _scrollToSection(tester);

      expect(_answerItem('date_style'), findsOneWidget);
      expect(find.text('활동적인 야외 데이트'), findsOneWidget);
      expect(_answerItem('contact_frequency'), findsNothing);
    });

    testWidgets('refresh 응답의 valueAnswers가 비면 섹션이 사라진다', (tester) async {
      final initial = _profile(
        valueAnswers: const {'contact_frequency': 'few_times'},
      );
      final refreshed = _profile(); // 빈 valueAnswers
      final fs = _FakeFirestoreService(refreshed);
      await _pump(tester, initial, fs);
      await tester.pumpAndSettle();

      expect(_section(), findsNothing);
    });
  });

  group('기존 표시 회귀', () {
    testWidgets('이름·나이·신고/차단 메뉴가 계속 표시된다', (tester) async {
      final profile = _profile(
        valueAnswers: const {'contact_frequency': 'few_times'},
      );
      final fs = _FakeFirestoreService(profile);
      await _pump(tester, profile, fs);
      await tester.pumpAndSettle();

      expect(find.text('지민, 27'), findsOneWidget);
      expect(find.byType(PopupMenuButton<String>), findsOneWidget);
    });
  });
}
