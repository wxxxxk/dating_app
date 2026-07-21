// ignore_for_file: depend_on_referenced_packages
import 'dart:async';

import 'package:dating_app/core/navigation/main_tab_index.dart';
import 'package:dating_app/features/community/community_hub_screen.dart';
import 'package:dating_app/models/community/community_author_snapshot.dart';
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
  _FakeCommunityService({this.error = false});

  final bool error;
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

CommunityPost _post({
  String id = 'post1',
  String authorUid = 'authorA',
  String text = '오늘 라운지에서 만나요',
  String displayName = '작성자',
  bool photoVerified = true,
  int reactionCount = 2,
  int commentCount = 1,
}) {
  return CommunityPost(
    id: id,
    surface: CommunityPostSurface.lounge,
    authorUid: authorUid,
    author: CommunityAuthorSnapshot(
      uid: authorUid,
      displayName: displayName,
      photoUrl: '',
      photoVerified: photoVerified,
      workVerified: false,
      schoolVerified: false,
    ),
    text: text,
    imageUrls: const [],
    status: CommunityContentStatus.active,
    visibility: CommunityVisibility.authenticated,
    reactionCount: reactionCount,
    commentCount: commentCount,
    createdAt: DateTime(2026, 7, 21, 12),
    updatedAt: DateTime(2026, 7, 21, 12),
    schemaVersion: 1,
  );
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
      expect(find.text('게시물 읽기 가능'), findsOneWidget);
      expect(find.text('준비 중'), findsNWidgets(3));

      // 10. 준비 중 목적지는 안내만 한다.
      await tester.tap(find.byKey(const ValueKey('community-destination-feed')));
      await tester.pump();
      await tester.pump();
      expect(find.text('피드는 다음 단계에서 열릴 예정이에요.'), findsOneWidget);
    });

    testWidgets('9, 11. 게시물이 없으면 빈 상태를 보여주고 작성 버튼이 없다', (tester) async {
      final ctx = await _pump(tester);
      ctx.community.emit(const []);
      await tester.pump();

      expect(
        find.text('아직 올라온 이야기가 없어요.\n라운지가 열리면 이곳에서 새로운 대화를 만날 수 있어요.'),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.edit_rounded), findsNothing);
      expect(find.text('글쓰기'), findsNothing);
    });

    testWidgets('12. 오류 시 고정 문구와 다시 시도를 보여준다', (tester) async {
      await _pump(tester, community: _FakeCommunityService(error: true));

      expect(find.text('라운지 이야기를 불러오지 못했어요.'), findsOneWidget);
      expect(find.text('다시 시도'), findsOneWidget);
      // raw Firestore 오류는 노출하지 않는다.
      expect(find.textContaining('firestore raw'), findsNothing);
      expect(find.textContaining('StateError'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('community-lounge-retry')));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('13, 17. 게시물 카드는 공개 정보만 보여준다', (tester) async {
      final ctx = await _pump(tester);
      ctx.community.emit([_post()]);
      await tester.pump();

      expect(find.byKey(const ValueKey('community-lounge-list')), findsOneWidget);
      expect(find.byKey(const ValueKey('community-post-post1')), findsOneWidget);
      expect(find.text('작성자'), findsOneWidget);
      expect(find.text('오늘 라운지에서 만나요'), findsOneWidget);
      expect(find.text('사진 인증'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);

      // 17. UID·기관명·전화번호·나이/성별은 표시하지 않는다.
      for (final element in find.byType(Text).evaluate()) {
        final data = (element.widget as Text).data ?? '';
        expect(data.contains('authorA'), isFalse);
        expect(data.contains(kMe), isFalse);
        expect(data.contains('010-'), isFalse);
      }
      // 읽기 전용: 좋아요·댓글·수정 버튼이 없다.
      expect(find.widgetWithText(TextButton, '댓글'), findsNothing);
      expect(find.byIcon(Icons.favorite_rounded), findsNothing);
    });
  });

  group('14~16. 관계 기반 숨김', () {
    testWidgets('14. 차단한 작성자 게시물은 숨긴다', (tester) async {
      final ctx = await _pump(tester, blocked: {'blockedAuthor'});
      ctx.community.emit([
        _post(id: 'p1', authorUid: 'blockedAuthor', text: '차단된 사람 글'),
        _post(id: 'p2', authorUid: 'okAuthor', text: '보여야 하는 글'),
      ]);
      await tester.pump();
      await tester.pump();

      expect(find.text('차단된 사람 글'), findsNothing);
      expect(find.text('보여야 하는 글'), findsOneWidget);
    });

    testWidgets('15~16. 지인 피하기 상대는 숨기고 해제되면 다시 보인다', (tester) async {
      final ctx = await _pump(tester);
      ctx.community.emit([
        _post(id: 'p1', authorUid: 'friendA', text: '지인 글'),
        _post(id: 'p2', authorUid: 'okAuthor', text: '일반 글'),
      ]);
      await tester.pump();
      expect(find.text('지인 글'), findsOneWidget);

      // 15. pair가 생기면 즉시 사라진다.
      ctx.avoid.emit({'friendA'});
      await tester.pump();
      await tester.pump();
      expect(find.text('지인 글'), findsNothing);
      expect(find.text('일반 글'), findsOneWidget);

      // 16. 관계가 풀리면 다시 보인다(게시물 문서는 지우지 않았다).
      ctx.avoid.emit(const <String>{});
      await tester.pump();
      await tester.pump();
      expect(find.text('지인 글'), findsOneWidget);
    });
  });

  group('19. 레이아웃', () {
    testWidgets('작은 화면에서도 overflow가 없다', (tester) async {
      tester.view.physicalSize = const Size(720, 1280);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);

      final ctx = await _pump(tester, tallViewport: false);
      expect(tester.takeException(), isNull);

      ctx.community.emit([
        _post(id: 'p1', text: '가' * 400, displayName: '아주 긴 이름을 가진 사용자입니다'),
      ]);
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });
}
