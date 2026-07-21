// ignore_for_file: depend_on_referenced_packages
import 'dart:async';

import 'package:dating_app/core/navigation/main_tab_index.dart';
import 'package:dating_app/features/community/community_hub_screen.dart';
import 'package:dating_app/models/community/community_enums.dart';
import 'package:dating_app/models/community/community_post.dart';
import 'package:dating_app/services/auth/auth_service.dart';
import 'package:dating_app/services/community/community_service.dart';
import 'package:dating_app/services/database/firestore_service.dart';
import 'package:dating_app/services/privacy/contact_avoidance_service.dart';
import 'package:dating_app/services/safety/safety_service.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

const String kMe = 'me-uid';

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
  @override
  String get uid => kMe;
}

class _FakeAuthService extends Fake implements AuthService {
  @override
  User? get currentUser => _FakeUser();
}

class _FakeCommunityService extends Fake implements CommunityService {
  _FakeCommunityService();

  static const bool error = false;
  final _controller = StreamController<List<CommunityPost>>.broadcast();
  int watchCalls = 0;

  void emit(List<CommunityPost> posts) => _controller.add(posts);

  @override
  Stream<List<CommunityPost>> watchPosts({
    required CommunityPostSurface surface,
    int limit = CommunityService.defaultLimit,
  }) async* {
    watchCalls += 1;
    if (error) {
      yield* Stream<List<CommunityPost>>.error(StateError('firestore raw'));
      return;
    }
    yield* _controller.stream;
  }

  Future<void> dispose() => _controller.close();
}

class _FakeSafetyService extends SafetyService {
  _FakeSafetyService({this.blocked = const {}})
    : super(firestoreService: FirestoreService());

  final Set<String> blocked;

  @override
  Future<Set<String>> getBlockedRelationshipUids(String currentUid) async =>
      blocked;
}

class _FakeContactAvoidanceService extends ContactAvoidanceService {
  final _controller = StreamController<Set<String>>.broadcast();

  void emit(Set<String> uids) => _controller.add(uids);

  @override
  Stream<Set<String>> watchAvoidedUids(String uid) async* {
    yield const <String>{};
    yield* _controller.stream;
  }

  Future<void> dispose() => _controller.close();
}

Future<({_FakeCommunityService community, _FakeContactAvoidanceService avoid})>
_pump(
  WidgetTester tester, {
  _FakeCommunityService? community,
  Set<String> blocked = const {},
  _FakeContactAvoidanceService? avoid,
  bool tallViewport = true,
}) async {
  if (tallViewport) {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }
  final c = community ?? _FakeCommunityService();
  final a = avoid ?? _FakeContactAvoidanceService();
  addTearDown(c.dispose);
  addTearDown(a.dispose);

  await tester.pumpWidget(
    MaterialApp(
      home: CommunityHubScreen(
        authService: _FakeAuthService(),
        communityService: c,
        safetyService: _FakeSafetyService(blocked: blocked),
        contactAvoidanceService: a,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return (community: c, avoid: a);
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    FirebasePlatform.instance = _FakeFirebasePlatform();
  });

  group('탭 index 상수', () {
    test('3~5. 커뮤니티 3 / 프로필 4, 범위 검증', () {
      expect(MainTabIndex.discovery, 0);
      expect(MainTabIndex.matches, 1);
      expect(MainTabIndex.fortune, 2);
      expect(MainTabIndex.community, 3);
      expect(MainTabIndex.profile, 4);

      for (final valid in [0, 1, 2, 3, 4]) {
        expect(MainTabIndex.isValid(valid), isTrue);
      }
      for (final invalid in [-1, 5, 99]) {
        expect(MainTabIndex.isValid(invalid), isFalse);
      }
    });
  });

  group('7~13. 커뮤니티 화면', () {
    testWidgets('7~8, 10. 진입 시 네 목적지와 준비 중 안내를 보여준다', (tester) async {
      await _pump(tester);

      expect(find.byKey(const ValueKey('community-hub-screen')), findsOneWidget);
      expect(find.text('취향과 일상을 나누며 새로운 사람들과 가볍게 연결해보세요.'), findsOneWidget);
      expect(
        find.text('개인정보·연락처·인증번호·금전 정보는 공개 글에 올리지 마세요.'),
        findsOneWidget,
      );

      for (final key in [
        'community-destination-lounge',
        'community-destination-feed',
        'community-destination-party-square',
        'community-destination-group-chat',
      ]) {
        expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
      }
      // Phase 4-2: 라운지는 이용 가능, 나머지는 준비 중 유지.
      expect(find.text('이용 가능'), findsOneWidget);
      expect(find.text('준비 중'), findsNWidgets(3));

      // 10. 준비 중 목적지는 안내만 한다.
      await tester.tap(find.byKey(const ValueKey('community-destination-feed')));
      await tester.pump();
      await tester.pump();
      expect(find.text('피드는 다음 단계에서 열릴 예정이에요.'), findsOneWidget);
    });

    testWidgets('9. 허브는 라운지 게시물을 직접 구독하지 않는다', (tester) async {
      final ctx = await _pump(tester);

      expect(ctx.community.watchCalls, 0);
      expect(find.byKey(const ValueKey('community-lounge-list')), findsNothing);
      expect(find.text('아직 올라온 이야기가 없어요.'), findsNothing);
    });

    testWidgets('11~13. 라운지 카드는 별도 화면을 연다', (tester) async {
      final ctx = await _pump(tester);

      await tester.tap(
        find.byKey(const ValueKey('community-destination-lounge')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byKey(const ValueKey('lounge-screen')), findsOneWidget);
      expect(find.text('라운지'), findsWidgets);
      // 라운지 화면에서만 게시물 stream을 구독한다.
      expect(ctx.community.watchCalls, 1);
    });
  });

  group('19. 레이아웃', () {
    testWidgets('작은 화면에서도 overflow가 없다', (tester) async {
      tester.view.physicalSize = const Size(720, 1280);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);

      await _pump(tester, tallViewport: false);
      expect(tester.takeException(), isNull);
    });
  });
}
