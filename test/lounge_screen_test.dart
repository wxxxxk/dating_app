// ignore_for_file: depend_on_referenced_packages
import 'dart:async';

import 'package:dating_app/core/theme/app_theme.dart';
import 'package:dating_app/features/community/lounge/lounge_post_detail_screen.dart';
import 'package:dating_app/features/community/lounge/lounge_screen.dart';
import 'package:dating_app/models/community/community_author_snapshot.dart';
import 'package:dating_app/models/community/community_comment.dart';
import 'package:dating_app/models/community/community_enums.dart';
import 'package:dating_app/models/community/community_post.dart';
import 'package:dating_app/models/community/community_reaction.dart';
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
const String kOther = 'other-uid';

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

class _FakeSafetyService extends SafetyService {
  _FakeSafetyService({this.blocked = const {}})
    : super(firestoreService: FirestoreService());

  Set<String> blocked;
  final List<String> blockCalls = [];

  @override
  Future<Set<String>> getBlockedRelationshipUids(String currentUid) async =>
      blocked;

  @override
  Future<void> blockUser({
    required String currentUid,
    required String blockedUid,
  }) async {
    blockCalls.add(blockedUid);
    blocked = {...blocked, blockedUid};
  }
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

/// 스트림과 callable 호출을 제어하는 CommunityService fake.
class _FakeCommunityService extends Fake implements CommunityService {
  _FakeCommunityService({this.postsError = false});

  final bool postsError;

  final _posts = StreamController<List<CommunityPost>>.broadcast();
  final _post = StreamController<CommunityPost?>.broadcast();
  final _comments = StreamController<List<CommunityComment>>.broadcast();
  final _myReaction = StreamController<bool>.broadcast();

  final List<String> calls = [];
  String? lastPostText;
  String? lastCommentText;

  /// 세팅하면 해당 호출이 완료될 때까지 대기한다(중복 제출 방지 검증용).
  Completer<void>? createPostGate;
  CommunityActionError? failure;
  CommunityReactionResult reactionResult = const CommunityReactionResult(
    reacted: true,
    reactionCount: 1,
  );

  void emitPosts(List<CommunityPost> posts) => _posts.add(posts);
  void emitPost(CommunityPost? post) => _post.add(post);
  void emitPostError() => _post.addError(StateError('firestore raw'));
  void emitComments(List<CommunityComment> comments) => _comments.add(comments);
  void emitMyReaction(bool value) => _myReaction.add(value);

  @override
  Stream<List<CommunityPost>> watchPosts({
    required CommunityPostSurface surface,
    int limit = CommunityService.defaultLimit,
  }) async* {
    if (postsError) {
      yield* Stream<List<CommunityPost>>.error(StateError('firestore raw'));
      return;
    }
    yield* _posts.stream;
  }

  @override
  Stream<CommunityPost?> watchPost(String postId) => _post.stream;

  @override
  Stream<List<CommunityComment>> watchComments({
    required String postId,
    int limit = CommunityService.defaultCommentLimit,
  }) async* {
    yield const <CommunityComment>[];
    yield* _comments.stream;
  }

  @override
  Stream<bool> watchMyReaction({
    required String postId,
    required String uid,
  }) async* {
    yield false;
    yield* _myReaction.stream;
  }

  @override
  Future<String> createLoungePost({required String text}) async {
    calls.add('createPost');
    lastPostText = text;
    await createPostGate?.future;
    final failure = this.failure;
    if (failure != null) throw failure;
    return 'new-post';
  }

  @override
  Future<String> createComment({
    required String postId,
    required String text,
  }) async {
    calls.add('createComment');
    lastCommentText = text;
    final failure = this.failure;
    if (failure != null) throw failure;
    return 'new-comment';
  }

  @override
  Future<CommunityReactionResult> toggleReaction({
    required String postId,
  }) async {
    calls.add('toggleReaction');
    final failure = this.failure;
    if (failure != null) throw failure;
    return reactionResult;
  }

  @override
  Future<void> deletePost({required String postId}) async {
    calls.add('deletePost:$postId');
  }

  @override
  Future<void> deleteComment({
    required String postId,
    required String commentId,
  }) async {
    calls.add('deleteComment:$commentId');
  }

  @override
  Future<void> reportContent({
    required String targetType,
    required String postId,
    String commentId = '',
    required String reason,
    String? detail,
  }) async {
    calls.add('report:$targetType:$postId:$commentId:$reason');
  }

  Future<void> dispose() async {
    await _posts.close();
    await _post.close();
    await _comments.close();
    await _myReaction.close();
  }
}

CommunityAuthorSnapshot _author(String uid, {String name = '작성자'}) {
  return CommunityAuthorSnapshot(
    uid: uid,
    displayName: name,
    photoUrl: '',
    photoVerified: true,
    workVerified: false,
    schoolVerified: false,
  );
}

CommunityPost _post({
  String id = 'p1',
  String authorUid = kOther,
  String text = '라운지 이야기',
  int reactionCount = 0,
  int commentCount = 0,
}) {
  return CommunityPost(
    id: id,
    surface: CommunityPostSurface.lounge,
    authorUid: authorUid,
    author: _author(authorUid),
    text: text,
    imageUrls: const [],
    status: CommunityContentStatus.active,
    visibility: CommunityVisibility.authenticated,
    reactionCount: reactionCount,
    commentCount: commentCount,
    createdAt: DateTime(2026, 7, 20, 12),
    updatedAt: DateTime(2026, 7, 20, 12),
    schemaVersion: 1,
  );
}

CommunityComment _comment({
  String id = 'c1',
  String authorUid = kOther,
  String text = '반가워요',
}) {
  return CommunityComment(
    id: id,
    postId: 'p1',
    authorUid: authorUid,
    author: _author(authorUid, name: authorUid == kMe ? '나' : '댓글 작성자'),
    text: text,
    status: CommunityContentStatus.active,
    createdAt: DateTime(2026, 7, 20, 13),
    updatedAt: DateTime(2026, 7, 20, 13),
    schemaVersion: 1,
  );
}

Future<
  ({
    _FakeCommunityService community,
    _FakeContactAvoidanceService avoid,
    _FakeSafetyService safety,
  })
>
_pumpLounge(
  WidgetTester tester, {
  _FakeCommunityService? community,
  Set<String> blocked = const {},
  Size viewport = const Size(800, 1600),
}) async {
  tester.view.physicalSize = viewport;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final c = community ?? _FakeCommunityService();
  final a = _FakeContactAvoidanceService();
  final s = _FakeSafetyService(blocked: blocked);
  addTearDown(c.dispose);
  addTearDown(a.dispose);

  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      home: LoungeScreen(
        authService: _FakeAuthService(),
        communityService: c,
        safetyService: s,
        contactAvoidanceService: a,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return (community: c, avoid: a, safety: s);
}

Future<
  ({
    _FakeCommunityService community,
    _FakeContactAvoidanceService avoid,
    _FakeSafetyService safety,
  })
>
_pumpDetail(
  WidgetTester tester, {
  _FakeCommunityService? community,
  Set<String> blocked = const {},
}) async {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final c = community ?? _FakeCommunityService();
  final a = _FakeContactAvoidanceService();
  final s = _FakeSafetyService(blocked: blocked);
  addTearDown(c.dispose);
  addTearDown(a.dispose);

  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      home: LoungePostDetailScreen(
        postId: 'p1',
        authService: _FakeAuthService(),
        communityService: c,
        safetyService: s,
        contactAvoidanceService: a,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return (community: c, avoid: a, safety: s);
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    FirebasePlatform.instance = _FakeFirebasePlatform();
  });

  group('3~6. 라운지 목록', () {
    testWidgets('3. 로딩 상태를 보여준다', (tester) async {
      await _pumpLounge(tester);
      expect(find.byKey(const ValueKey('lounge-screen')), findsOneWidget);
      expect(find.byKey(const ValueKey('lounge-loading')), findsOneWidget);
    });

    testWidgets('4. 게시물이 없으면 빈 상태와 글쓰기 버튼을 보여준다', (tester) async {
      final ctx = await _pumpLounge(tester);
      ctx.community.emitPosts(const []);
      await tester.pump();

      expect(find.byKey(const ValueKey('lounge-empty')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('lounge-create-post-button')),
        findsOneWidget,
      );
    });

    testWidgets('5. 오류 시 고정 문구와 다시 시도를 보여준다', (tester) async {
      await _pumpLounge(
        tester,
        community: _FakeCommunityService(postsError: true),
      );

      expect(find.text('라운지 이야기를 불러오지 못했어요.'), findsOneWidget);
      expect(find.textContaining('firestore raw'), findsNothing);
      expect(find.textContaining('StateError'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('lounge-retry')));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('6. 게시물 카드는 공개 정보만 보여준다', (tester) async {
      final ctx = await _pumpLounge(tester);
      ctx.community.emitPosts([_post(reactionCount: 2, commentCount: 1)]);
      await tester.pump();

      expect(find.byKey(const ValueKey('lounge-post-p1')), findsOneWidget);
      expect(find.text('라운지 이야기'), findsOneWidget);
      expect(find.text('사진 인증'), findsOneWidget);

      for (final element in find.byType(Text).evaluate()) {
        final data = (element.widget as Text).data ?? '';
        expect(data.contains(kOther), isFalse);
        expect(data.contains(kMe), isFalse);
        expect(data.contains('010-'), isFalse);
      }
    });
  });

  group('7~11. 글쓰기', () {
    testWidgets('7~8. 빈 글은 막고 정상 글은 제출한다', (tester) async {
      final ctx = await _pumpLounge(tester);
      ctx.community.emitPosts(const []);
      await tester.pump();

      await tester.tap(
        find.byKey(const ValueKey('lounge-create-post-button')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('lounge-compose-sheet')), findsOneWidget);

      // 공백만 입력하면 제출 버튼이 비활성이다.
      await tester.enterText(
        find.byKey(const ValueKey('lounge-compose-input')),
        '   ',
      );
      await tester.pump();
      final button = tester.widget<FilledButton>(
        find.byKey(const ValueKey('lounge-compose-submit')),
      );
      expect(button.onPressed, isNull);
      expect(ctx.community.calls, isEmpty);

      await tester.enterText(
        find.byKey(const ValueKey('lounge-compose-input')),
        '  오늘 날씨가 좋네요  ',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('lounge-compose-submit')));
      await tester.pumpAndSettle();

      expect(ctx.community.calls, ['createPost']);
      expect(ctx.community.lastPostText, '오늘 날씨가 좋네요');
      expect(find.byKey(const ValueKey('lounge-compose-sheet')), findsNothing);
    });

    testWidgets('9. 제출 중 중복 요청을 막는다', (tester) async {
      final ctx = await _pumpLounge(tester);
      ctx.community.emitPosts(const []);
      ctx.community.createPostGate = Completer<void>();
      await tester.pump();

      await tester.tap(
        find.byKey(const ValueKey('lounge-create-post-button')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('lounge-compose-input')),
        '중복 방지 확인',
      );
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('lounge-compose-submit')));
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('lounge-compose-submit')),
        warnIfMissed: false,
      );
      await tester.pump();

      expect(ctx.community.calls, ['createPost']);
      ctx.community.createPostGate!.complete();
      await tester.pumpAndSettle();
    });

    testWidgets('10. 개인정보·인증번호·송금 요청은 제출 전에 막는다', (tester) async {
      final ctx = await _pumpLounge(tester);
      ctx.community.emitPosts(const []);
      await tester.pump();

      await tester.tap(
        find.byKey(const ValueKey('lounge-create-post-button')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('lounge-compose-input')),
        '연락처는 010-1234-5678 이에요',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('lounge-compose-submit')));
      await tester.pumpAndSettle();

      expect(ctx.community.calls, isEmpty);
      expect(find.text('개인정보·인증번호·송금 요청은 공개 글에 올릴 수 없어요.'), findsOneWidget);
      // 입력 내용은 유지된다.
      expect(find.text('연락처는 010-1234-5678 이에요'), findsOneWidget);
    });

    testWidgets('11. 외부 연락처는 확인 후 계속 게시할 수 있다', (tester) async {
      final ctx = await _pumpLounge(tester);
      ctx.community.emitPosts(const []);
      await tester.pump();

      await tester.tap(
        find.byKey(const ValueKey('lounge-create-post-button')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('lounge-compose-input')),
        '카카오톡으로 같이 얘기해요',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('lounge-compose-submit')));
      await tester.pumpAndSettle();

      expect(find.text('외부 연락처를 공개하시겠어요?'), findsOneWidget);
      expect(ctx.community.calls, isEmpty);

      await tester.tap(
        find.byKey(const ValueKey('community-external-contact-continue')),
      );
      await tester.pumpAndSettle();
      expect(ctx.community.calls, ['createPost']);
    });
  });

  group('12, 21~23. 상세 진입과 관계 필터', () {
    testWidgets('12. 카드를 누르면 상세 화면으로 이동한다', (tester) async {
      final ctx = await _pumpLounge(tester);
      ctx.community.emitPosts([_post()]);
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('lounge-post-p1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.byKey(const ValueKey('lounge-post-detail-screen')),
        findsOneWidget,
      );
    });

    testWidgets('21, 23. 차단한 작성자 글은 숨기고 본인 글은 유지한다', (tester) async {
      final ctx = await _pumpLounge(tester, blocked: {'blockedAuthor'});
      ctx.community.emitPosts([
        _post(id: 'p1', authorUid: 'blockedAuthor', text: '차단된 사람 글'),
        _post(id: 'p2', authorUid: kMe, text: '내 글'),
        _post(id: 'p3', authorUid: kOther, text: '보여야 하는 글'),
      ]);
      await tester.pump();
      await tester.pump();

      expect(find.text('차단된 사람 글'), findsNothing);
      expect(find.text('내 글'), findsOneWidget);
      expect(find.text('보여야 하는 글'), findsOneWidget);
    });

    testWidgets('22. 지인 피하기 상대는 숨기고 해제되면 다시 보인다', (tester) async {
      final ctx = await _pumpLounge(tester);
      ctx.community.emitPosts([
        _post(id: 'p1', authorUid: 'friendA', text: '지인 글'),
        _post(id: 'p2', authorUid: kOther, text: '일반 글'),
      ]);
      await tester.pump();
      expect(find.text('지인 글'), findsOneWidget);

      ctx.avoid.emit({'friendA'});
      await tester.pump();
      await tester.pump();
      expect(find.text('지인 글'), findsNothing);
      expect(find.text('일반 글'), findsOneWidget);

      ctx.avoid.emit(const <String>{});
      await tester.pump();
      await tester.pump();
      expect(find.text('지인 글'), findsOneWidget);
    });
  });

  group('13~19, 24. 상세 화면', () {

    testWidgets('A-2. AppBar 제목이 "라운지 게시물"이다', (tester) async {
      final ctx = await _pumpDetail(tester);
      ctx.community.emitPost(_post());
      await tester.pump();

      expect(find.text('라운지 게시물'), findsOneWidget);
      expect(find.text('게시물'), findsNothing);
    });

    testWidgets('A-5. 본문·공감 bar·댓글·입력줄이 모두 그려진다', (tester) async {
      final ctx = await _pumpDetail(tester);
      ctx.community.emitPost(_post(reactionCount: 4, commentCount: 1));
      await tester.pump();
      ctx.community.emitComments([_comment(text: '첫 댓글')]);
      await tester.pump();

      expect(find.byKey(const ValueKey('lounge-detail-post')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('lounge-reaction-button')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('lounge-comment-list')), findsOneWidget);
      expect(find.byKey(const ValueKey('lounge-comment-input')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('lounge-comment-submit')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('A-4. stream 오류는 다시 시도할 수 있는 상태로 구분한다', (tester) async {
      final ctx = await _pumpDetail(tester);
      ctx.community.emitPostError();
      await tester.pump();

      expect(find.text('게시물을 불러오지 못했어요.'), findsOneWidget);
      expect(find.byKey(const ValueKey('lounge-detail-retry')), findsOneWidget);
      // raw Firebase 오류는 노출하지 않는다.
      expect(find.textContaining('firestore raw'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('lounge-detail-retry')));
      await tester.pump();
      expect(find.text('이 게시물은 더 이상 볼 수 없어요.'), findsNothing);
    });

    testWidgets('A-4. 문서 없음은 되돌릴 수 없는 상태로 안내한다', (tester) async {
      final ctx = await _pumpDetail(tester);
      ctx.community.emitPost(null);
      await tester.pump();

      expect(find.text('이 게시물은 더 이상 볼 수 없어요.'), findsOneWidget);
      expect(find.byKey(const ValueKey('lounge-detail-retry')), findsNothing);
    });
    testWidgets('13. 공감을 추가하고 취소한다', (tester) async {
      final ctx = await _pumpDetail(tester);
      ctx.community.emitPost(_post(reactionCount: 0));
      await tester.pump();

      expect(find.text('공감 0'), findsOneWidget);

      ctx.community.reactionResult = const CommunityReactionResult(
        reacted: true,
        reactionCount: 1,
      );
      await tester.tap(find.byKey(const ValueKey('lounge-reaction-button')));
      await tester.pumpAndSettle();
      expect(find.text('공감 1'), findsOneWidget);
      expect(find.byIcon(Icons.favorite_rounded), findsOneWidget);

      ctx.community.reactionResult = const CommunityReactionResult(
        reacted: false,
        reactionCount: 0,
      );
      await tester.tap(find.byKey(const ValueKey('lounge-reaction-button')));
      await tester.pumpAndSettle();
      expect(find.text('공감 0'), findsOneWidget);
      expect(find.byIcon(Icons.favorite_border_rounded), findsOneWidget);
      expect(ctx.community.calls, ['toggleReaction', 'toggleReaction']);
    });

    testWidgets('14~15. 댓글 목록을 보여주고 댓글을 작성한다', (tester) async {
      final ctx = await _pumpDetail(tester);
      ctx.community.emitPost(_post());
      await tester.pump();
      ctx.community.emitComments([_comment(text: '첫 댓글')]);
      await tester.pump();

      expect(find.byKey(const ValueKey('lounge-comment-c1')), findsOneWidget);
      expect(find.text('첫 댓글'), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('lounge-comment-input')),
        '  좋은 글이에요  ',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('lounge-comment-submit')));
      await tester.pumpAndSettle();

      expect(ctx.community.calls, ['createComment']);
      expect(ctx.community.lastCommentText, '좋은 글이에요');
      // 성공하면 입력창을 비운다.
      expect(find.text('좋은 글이에요'), findsNothing);
    });

    testWidgets('댓글도 개인정보가 있으면 제출 전에 막는다', (tester) async {
      final ctx = await _pumpDetail(tester);
      ctx.community.emitPost(_post());
      await tester.pump();

      await tester.enterText(
        find.byKey(const ValueKey('lounge-comment-input')),
        '인증번호 알려주세요',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('lounge-comment-submit')));
      await tester.pumpAndSettle();

      expect(ctx.community.calls, isEmpty);
      expect(find.text('개인정보·인증번호·송금 요청은 공개 글에 올릴 수 없어요.'), findsOneWidget);
    });

    testWidgets('16, 18. 본인 게시물·댓글은 삭제할 수 있다', (tester) async {
      final ctx = await _pumpDetail(tester);
      ctx.community.emitPost(_post(authorUid: kMe));
      await tester.pump();
      ctx.community.emitComments([_comment(authorUid: kMe)]);
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('lounge-comment-menu-c1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('삭제하기').last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '삭제하기'));
      await tester.pumpAndSettle();
      expect(ctx.community.calls, ['deleteComment:c1']);

      await tester.tap(find.byKey(const ValueKey('lounge-detail-post-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('삭제하기').last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '삭제하기'));
      await tester.pumpAndSettle();
      expect(ctx.community.calls, ['deleteComment:c1', 'deletePost:p1']);
    });

    testWidgets('17, 19~20. 타인 게시물·댓글 신고와 신고 후 차단', (tester) async {
      final ctx = await _pumpDetail(tester);
      ctx.community.emitPost(_post(authorUid: kOther));
      await tester.pump();
      ctx.community.emitComments([_comment(authorUid: kOther)]);
      await tester.pump();

      // 타인 콘텐츠에는 삭제가 아니라 신고가 뜬다.
      await tester.tap(find.byKey(const ValueKey('lounge-comment-menu-c1')));
      await tester.pumpAndSettle();
      expect(find.text('삭제하기'), findsNothing);
      await tester.tap(find.text('신고하기').last);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('community-report-sheet')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey('community-report-reason-spam_scam')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('community-report-block')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('community-report-submit')));
      await tester.pumpAndSettle();

      expect(ctx.community.calls, ['report:comment:p1:c1:spam_scam']);
      expect(ctx.safety.blockCalls, [kOther]);
    });

    testWidgets('24. 삭제된 게시물은 볼 수 없는 상태로 바뀐다', (tester) async {
      final ctx = await _pumpDetail(tester);
      ctx.community.emitPost(_post());
      await tester.pump();
      expect(find.byKey(const ValueKey('lounge-detail-post')), findsOneWidget);

      ctx.community.emitPost(null);
      await tester.pump();

      expect(find.text('이 게시물은 더 이상 볼 수 없어요.'), findsOneWidget);
      expect(find.byKey(const ValueKey('lounge-comment-input')), findsNothing);
      expect(
        find.byKey(const ValueKey('lounge-reaction-button')),
        findsNothing,
      );
    });

    testWidgets('차단한 작성자의 댓글은 상세에서도 숨긴다', (tester) async {
      final ctx = await _pumpDetail(tester, blocked: {'blockedAuthor'});
      ctx.community.emitPost(_post());
      await tester.pump();
      ctx.community.emitComments([
        _comment(id: 'c1', authorUid: 'blockedAuthor', text: '차단된 댓글'),
        _comment(id: 'c2', authorUid: kMe, text: '내 댓글'),
      ]);
      await tester.pump();
      await tester.pump();

      expect(find.text('차단된 댓글'), findsNothing);
      expect(find.text('내 댓글'), findsOneWidget);
    });
  });

  group('25. 레이아웃', () {
    testWidgets('작은 화면·키보드에서도 overflow가 없다', (tester) async {
      final ctx = await _pumpLounge(
        tester,
        viewport: const Size(720, 1280),
      );
      ctx.community.emitPosts([
        _post(id: 'p1', text: '가' * 400),
        _post(id: 'p2', text: '나' * 200),
      ]);
      await tester.pump();
      expect(tester.takeException(), isNull);

      await tester.tap(
        find.byKey(const ValueKey('lounge-create-post-button')),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.enterText(
        find.byKey(const ValueKey('lounge-compose-input')),
        '가' * 300,
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });
}
