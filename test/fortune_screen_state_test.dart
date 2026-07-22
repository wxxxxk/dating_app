// 오늘의 운세 / 최근 기록 화면의 상태 렌더링 계약.
//
// FortuneHubScreen은 concrete 서비스(AuthService/FirestoreService/MatchesService/
// FortuneService)를 요구하고 그 생성자가 Firebase 인스턴스를 건드린다. 기존
// 위젯 테스트(chat_safety_screen_test 등)와 같은 방식으로 firebase_core 플랫폼만
// fake로 바꿔 인스턴스 생성을 가능하게 한 뒤, 필요한 메서드만 오버라이드한다.
// FortuneHistoryScreen은 controller만 받으므로 Firebase가 전혀 필요 없다.
// ignore_for_file: depend_on_referenced_packages
import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'package:dating_app/features/fortune/fortune_history_screen.dart';
import 'package:dating_app/features/fortune/fortune_hub_controller.dart';
import 'package:dating_app/features/fortune/fortune_hub_screen.dart';
import 'package:dating_app/models/fortune/birth_profile.dart';
import 'package:dating_app/models/fortune_model.dart';
import 'package:dating_app/models/match_model.dart';
import 'package:dating_app/models/user_profile.dart';
import 'package:dating_app/services/auth/auth_service.dart';
import 'package:dating_app/services/database/firestore_service.dart';
import 'package:dating_app/services/fortune/fortune_service.dart';
import 'package:dating_app/services/matches/matches_service.dart';
import 'package:dating_app/services/safety/safety_service.dart';

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

class _FakeUser extends Fake implements User {
  _FakeUser(this.uid);
  @override
  final String uid;
}

class _FakeAuthService extends AuthService {
  _FakeAuthService(String? uid) : _user = uid == null ? null : _FakeUser(uid);

  User? _user;

  void setUid(String? uid) => _user = uid == null ? null : _FakeUser(uid);

  @override
  User? get currentUser => _user;
}

class _FakeFirestoreService extends FirestoreService {
  _FakeFirestoreService(this.profiles);

  final Map<String, UserProfile> profiles;

  @override
  Future<UserProfile?> getUserProfile(String uid) async => profiles[uid];
}

class _FakeMatchesService extends MatchesService {
  _FakeMatchesService(FirestoreService firestoreService)
    : super(
        firestoreService: firestoreService,
        safetyService: SafetyService(firestoreService: firestoreService),
      );

  @override
  Stream<List<MatchWithProfile>> watchMatches({required String currentUid}) {
    // 화면 재빌드마다 StreamBuilder가 다시 구독할 수 있어야 한다.
    return Stream<List<MatchWithProfile>>.multi((controller) {
      controller.add(const []);
    });
  }
}

class _FakeFortuneService extends FortuneService implements FortuneDataSource {
  DailyFortune daily = const DailyFortune(
    loveScore: 4,
    mood: '설렘 가득',
    message: '오늘의 메시지',
    advice: '오늘의 조언',
  );
  Object? dailyError;
  Object? historyError;
  int dailyCallCount = 0;
  int historyCallCount = 0;
  Completer<DailyFortune>? nextDailyCompleter;

  @override
  Future<DailyFortune> getDailyFortune({
    required String uid,
    DateTime? now,
  }) async {
    dailyCallCount += 1;
    final completer = nextDailyCompleter;
    if (completer != null) {
      nextDailyCompleter = null;
      return completer.future;
    }
    if (dailyError != null) throw dailyError!;
    return daily;
  }

  @override
  Future<List<FortuneHistoryEntry>> getFortuneHistory({
    required String uid,
    int days = 7,
    DateTime? now,
  }) async {
    historyCallCount += 1;
    if (historyError != null) throw historyError!;
    return _historyFor(now ?? DateTime.now(), days, uid: uid);
  }
}

List<FortuneHistoryEntry> _historyFor(
  DateTime now,
  int days, {
  String uid = 'user-a',
}) {
  final kst = now.toUtc().add(const Duration(hours: 9));
  final today = DateTime.utc(kst.year, kst.month, kst.day);
  return List.generate(days, (index) {
    final date = today.subtract(Duration(days: index));
    final key =
        '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
    return FortuneHistoryEntry(
      dateKey: key,
      date: date,
      fortune: DailyFortune(
        loveScore: 3,
        mood: '$uid 기록 $index',
        message: 'm',
        advice: 'a',
      ),
    );
  });
}

UserProfile _profileFor(String uid, {BirthProfile? birthProfile}) =>
    UserProfile(
      uid: uid,
      displayName: '테스터',
      birthDate: DateTime(1994, 5, 12),
      gender: 'female',
      bio: '소개',
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
      birthProfile: birthProfile ?? const BirthProfile.unknownTime(),
    );

/// history 화면 전용 — Firebase 없이 controller만 넣는다.
class _HistoryOnlyDataSource implements FortuneDataSource {
  _HistoryOnlyDataSource({this.historyError});

  final Object? historyError;
  int historyCallCount = 0;
  Completer<List<FortuneHistoryEntry>>? nextHistoryCompleter;

  @override
  Future<DailyFortune> getDailyFortune({
    required String uid,
    DateTime? now,
  }) async => const DailyFortune(
    loveScore: 3,
    mood: 'm',
    message: 'm',
    advice: 'a',
  );

  @override
  Future<List<FortuneHistoryEntry>> getFortuneHistory({
    required String uid,
    int days = 7,
    DateTime? now,
  }) async {
    historyCallCount += 1;
    final completer = nextHistoryCompleter;
    if (completer != null) {
      nextHistoryCompleter = null;
      return completer.future;
    }
    if (historyError != null) throw historyError!;
    return _historyFor(now ?? DateTime.now(), days, uid: uid);
  }
}

void main() {
  // KST 2026-07-22 12:00
  final day1 = DateTime.utc(2026, 7, 22, 3);
  // KST 2026-07-23 00:30
  final day2 = DateTime.utc(2026, 7, 22, 15, 30);

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    FirebasePlatform.instance = _FakeFirebasePlatform();
  });

  group('FortuneHubScreen 상태 렌더링', () {
    late _FakeAuthService auth;
    late _FakeFortuneService fortune;
    late _FakeFirestoreService firestore;
    late DateTime now;

    Widget hub() => MaterialApp(
      home: FortuneHubScreen(
        authService: auth,
        firestoreService: firestore,
        matchesService: _FakeMatchesService(firestore),
        fortuneService: fortune,
        onExploreTap: () {},
        nowProvider: () => now,
      ),
    );

    setUp(() {
      now = day1;
      auth = _FakeAuthService('user-a');
      fortune = _FakeFortuneService();
      firestore = _FakeFirestoreService({'user-a': _profileFor('user-a')});
    });

    testWidgets('32/33. loading → ready 키가 순서대로 나타난다', (tester) async {
      final pending = Completer<DailyFortune>();
      fortune.nextDailyCompleter = pending;
      await tester.pumpWidget(hub());
      await tester.pump();

      expect(find.byKey(const Key('daily-fortune-loading')), findsOneWidget);
      expect(find.byKey(const Key('daily-fortune-ready')), findsNothing);

      pending.complete(fortune.daily);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('daily-fortune-ready')), findsOneWidget);
      expect(find.text('설렘 가득'), findsOneWidget);
      // KST 날짜로 라벨을 만든다 — 기기 로컬 날짜가 아니다.
      expect(find.textContaining('7월 22일'), findsOneWidget);
    });

    testWidgets('34. resource-exhausted면 rate-limit 문구를 보여준다', (tester) async {
      fortune.dailyError = const FortuneFailure('resource-exhausted');
      await tester.pumpWidget(hub());
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('daily-fortune-rate-limited')),
        findsOneWidget,
      );
      expect(find.text('요청이 많아요. 잠시 후 다시 시도해 주세요.'), findsOneWidget);
    });

    testWidgets('35. unavailable이면 네트워크 안내를 보여준다', (tester) async {
      fortune.dailyError = const FortuneFailure('unavailable');
      await tester.pumpWidget(hub());
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('daily-fortune-unavailable')),
        findsOneWidget,
      );
      expect(
        find.text('오늘의 운세를 불러오지 못했어요.\n네트워크를 확인하고 다시 시도해 주세요.'),
        findsOneWidget,
      );
    });

    testWidgets('36. 출생정보 미완성이면 보완 화면을 보여주고 callable을 부르지 않는다', (
      tester,
    ) async {
      firestore = _FakeFirestoreService({
        'user-a': _profileFor(
          'user-a',
          birthProfile: const BirthProfile.legacyMissing(),
        ),
      });
      await tester.pumpWidget(hub());
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('daily-fortune-needs-birth-profile')),
        findsOneWidget,
      );
      expect(fortune.dailyCallCount, 0);
    });

    testWidgets('37. internal 오류면 error 상태와 retry 버튼을 보여준다', (tester) async {
      fortune.dailyError = const FortuneFailure('internal');
      await tester.pumpWidget(hub());
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('daily-fortune-error')), findsOneWidget);
      expect(find.byKey(const Key('daily-fortune-retry')), findsOneWidget);
      expect(find.text('오늘의 운세를 불러오지 못했어요.'), findsOneWidget);

      fortune.dailyError = null;
      await tester.tap(find.byKey(const Key('daily-fortune-retry')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('daily-fortune-ready')), findsOneWidget);
    });

    testWidgets('37-b. 사용자 화면에 raw 예외 문자열이 노출되지 않는다', (tester) async {
      fortune.dailyError = StateError('permission-denied at users/uid-1234');
      await tester.pumpWidget(hub());
      await tester.pumpAndSettle();

      expect(find.textContaining('permission-denied'), findsNothing);
      expect(find.textContaining('uid-1234'), findsNothing);
      expect(find.textContaining('StateError'), findsNothing);
    });

    testWidgets('43/44. resume 시 날짜가 바뀌면 어제 ready 위젯이 사라진다', (tester) async {
      await tester.pumpWidget(hub());
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('daily-fortune-ready')), findsOneWidget);
      expect(fortune.dailyCallCount, 1);

      // 같은 날짜 resume — 추가 호출 없음, 화면 유지.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(fortune.dailyCallCount, 1);
      expect(find.byKey(const Key('daily-fortune-ready')), findsOneWidget);

      // KST 날짜가 넘어간 뒤 resume — 어제 결과가 즉시 사라진다.
      now = day2;
      final pending = Completer<DailyFortune>();
      fortune.nextDailyCompleter = pending;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(find.byKey(const Key('daily-fortune-ready')), findsNothing);
      expect(find.byKey(const Key('daily-fortune-loading')), findsOneWidget);

      pending.complete(
        const DailyFortune(
          loveScore: 2,
          mood: '오늘 분위기',
          message: 'm',
          advice: 'a',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('오늘 분위기'), findsOneWidget);
      expect(find.textContaining('7월 23일'), findsOneWidget);
      expect(fortune.dailyCallCount, 2);
    });

    testWidgets('42. 계정이 바뀌면 이전 사용자 결과 위젯이 표시되지 않는다', (tester) async {
      await tester.pumpWidget(hub());
      await tester.pumpAndSettle();
      expect(find.text('설렘 가득'), findsOneWidget);

      firestore.profiles['user-b'] = _profileFor('user-b');
      auth.setUid('user-b');
      final pending = Completer<DailyFortune>();
      fortune.nextDailyCompleter = pending;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();

      expect(find.text('설렘 가득'), findsNothing, reason: 'A 결과가 B 화면에 남으면 안 된다');
      expect(find.byKey(const Key('daily-fortune-loading')), findsOneWidget);

      pending.complete(
        const DailyFortune(
          loveScore: 5,
          mood: 'B의 분위기',
          message: 'm',
          advice: 'a',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('B의 분위기'), findsOneWidget);
    });
  });

  group('FortuneHistoryScreen 상태 렌더링', () {
    FortuneHubController controllerWith(
      FortuneDataSource source, {
      DateTime? at,
    }) => FortuneHubController(
      fortuneService: source,
      loadProfile: (uid) async => _profileFor(uid),
      initialUid: 'user-a',
      nowProvider: () => at ?? day1,
    );

    testWidgets('38/39. loading → ready 키와 7일 항목', (tester) async {
      final source = _HistoryOnlyDataSource()
        ..nextHistoryCompleter = Completer<List<FortuneHistoryEntry>>();
      final controller = controllerWith(source);
      await tester.pumpWidget(
        MaterialApp(home: FortuneHistoryScreen(controller: controller)),
      );
      await tester.pump();
      expect(find.byKey(const Key('fortune-history-loading')), findsOneWidget);

      source.nextHistoryCompleter = null;
      controller.retryHistory();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('fortune-history-ready')), findsOneWidget);
      expect(find.byKey(const Key('fortune-history-day-0')), findsOneWidget);
      expect(controller.history.length, 7);
      // ListView는 화면 밖 항목을 만들지 않는다. 마지막 날짜까지 스크롤해 확인한다.
      await tester.scrollUntilVisible(
        find.byKey(const Key('fortune-history-day-6')),
        300,
      );
      expect(find.byKey(const Key('fortune-history-day-6')), findsOneWidget);
      expect(find.byKey(const Key('fortune-history-day-7')), findsNothing);
      controller.dispose();
    });

    testWidgets('40. 오류면 error 키와 retry 버튼, raw 문자열은 없다', (tester) async {
      final source = _HistoryOnlyDataSource(
        historyError: StateError('permission-denied at users/uid-1234'),
      );
      final controller = controllerWith(source);
      await tester.pumpWidget(
        MaterialApp(home: FortuneHistoryScreen(controller: controller)),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('fortune-history-error')), findsOneWidget);
      expect(find.byKey(const Key('fortune-history-retry')), findsOneWidget);
      expect(find.text('최근 운세 기록을 불러오지 못했어요.'), findsOneWidget);
      expect(find.textContaining('permission-denied'), findsNothing);
      expect(find.textContaining('uid-1234'), findsNothing);
      controller.dispose();
    });

    testWidgets('41. 문구가 과거 기록을 뜻한다 (미래 예보 표현 없음)', (tester) async {
      final controller = controllerWith(_HistoryOnlyDataSource());
      await tester.pumpWidget(
        MaterialApp(home: FortuneHistoryScreen(controller: controller)),
      );
      await tester.pumpAndSettle();

      expect(find.text('최근 7일 애정운 흐름'), findsOneWidget);
      expect(find.text('지난 7일 기록'), findsOneWidget);
      for (final forbidden in const [
        '앞으로의 7일',
        '7일 예보',
        '다음 주 흐름',
        '향후 일주일',
        '이번 주 애정운 흐름',
      ]) {
        expect(find.textContaining(forbidden), findsNothing);
      }
      controller.dispose();
    });

    testWidgets('44-b. 허브가 이미 읽어둔 날짜면 진입 시 추가 요청이 없다', (tester) async {
      final source = _HistoryOnlyDataSource();
      final controller = controllerWith(source);
      await controller.loadInitial();
      await tester.pump();
      final callsBefore = source.historyCallCount;

      await tester.pumpWidget(
        MaterialApp(home: FortuneHistoryScreen(controller: controller)),
      );
      await tester.pumpAndSettle();

      expect(source.historyCallCount, callsBefore);
      expect(find.byKey(const Key('fortune-history-ready')), findsOneWidget);
      controller.dispose();
    });
  });
}
