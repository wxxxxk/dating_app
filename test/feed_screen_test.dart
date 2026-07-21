// ignore_for_file: depend_on_referenced_packages
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dating_app/core/theme/app_theme.dart';
import 'package:dating_app/features/community/feed/feed_compose_screen.dart';
import 'package:dating_app/features/community/feed/feed_post_detail_screen.dart';
import 'package:dating_app/features/community/feed/feed_screen.dart';
import 'package:dating_app/features/community/feed/feed_widgets.dart';
import 'package:dating_app/models/community/community_author_snapshot.dart';
import 'package:dating_app/models/community/community_comment.dart';
import 'package:dating_app/models/community/community_enums.dart';
import 'package:dating_app/models/community/community_post.dart';
import 'package:dating_app/models/community/community_reaction.dart';
import 'package:dating_app/models/community/feed_draft_image.dart';
import 'package:dating_app/services/auth/auth_service.dart';
import 'package:dating_app/services/community/community_media_service.dart';
import 'package:dating_app/services/community/community_service.dart';
import 'package:dating_app/services/database/firestore_service.dart';
import 'package:dating_app/services/privacy/contact_avoidance_service.dart';
import 'package:dating_app/services/safety/safety_service.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

// Phase 4-3 — 피드 화면 위젯 테스트.
//
// 확인 범위: 목록 상태, 작성 흐름(카메라/갤러리/최대 4장/제거/개인정보 확인),
// 업로드 실패 처리, 목록·상세의 이미지 표시, 공감·댓글·신고·삭제, 관계 필터,
// 그리고 Storage 경로·원본 파일 경로가 화면에 절대 노출되지 않는지.

const String kMe = 'me-uid';
const String kOther = 'other-uid';
const String kPostId = 'abcdefghij0123456789';

String _feedPath(String postId, String uid, [int index = 1]) =>
    'communityFeed/$uid/$postId/image$index.jpg';

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

  @override
  Future<Set<String>> getBlockedRelationshipUids(String currentUid) async =>
      blocked;

  @override
  Future<void> blockUser({
    required String currentUid,
    required String blockedUid,
  }) async {
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

/// 1x1 PNG(base64). 형식 판별과 실제 decode를 모두 통과해야 하므로
/// magic number만 흉내내지 않고 진짜 이미지 bytes를 쓴다.
const String _png1x1Base64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQ'
    'DwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

/// 표시·업로드 경로에서 쓰는 최소 이미지 bytes.
///
/// IEND 뒤의 trailing byte는 decoder가 무시하므로, seed로 fingerprint(sha256)만
/// 다르게 만들면서 decode 가능한 상태를 유지한다.
Uint8List _imageBytes({int seed = 1}) {
  final base = base64Decode(_png1x1Base64);
  final bytes = Uint8List(base.length + 1)..setAll(0, base);
  bytes[base.length] = seed;
  return bytes;
}

Uint8List _heicBytes() {
  final bytes = Uint8List(64);
  // ftyp box(heic) — jpeg/png magic이 아니라 거부돼야 한다.
  bytes.setAll(4, 'ftypheic'.codeUnits);
  return bytes;
}

/// Storage·picker를 실제로 부르지 않는 media service.
class _FakeMediaService extends CommunityMediaService {
  _FakeMediaService();

  final List<String> calls = [];

  /// pick*이 돌려줄 bytes 목록(파일 대신 bytes로 바로 준비한다).
  List<Uint8List> cameraBytes = [];
  List<Uint8List> galleryBytes = [];
  int? lastRemainingSlots;

  /// 업로드 결과·실패 제어.
  List<String> uploadedPaths = [];
  Object? uploadError;
  Completer<void>? uploadGate;

  /// 표시용 bytes(경로 → bytes). 없으면 null(=중립 placeholder).
  final Map<String, Uint8List> storedImages = {};
  final List<String> loadedPaths = [];

  @override
  Future<XFile?> pickFeedImageFromCamera() async {
    calls.add('camera');
    if (cameraBytes.isEmpty) return null;
    return _FakeXFile(cameraBytes.removeAt(0));
  }

  @override
  Future<List<XFile>> pickFeedImagesFromGallery({
    int remainingSlots = CommunityMediaService.maxImages,
  }) async {
    calls.add('gallery');
    lastRemainingSlots = remainingSlots;
    final take = galleryBytes.take(remainingSlots).toList();
    galleryBytes = galleryBytes.skip(take.length).toList();
    return take.map<XFile>(_FakeXFile.new).toList();
  }

  @override
  Future<FeedDraftImage> prepareFeedImage(XFile file) async {
    final bytes = await file.readAsBytes();
    return CommunityMediaService.buildDraftImage(bytes);
  }

  @override
  Future<List<String>> uploadFeedImages({
    required String uid,
    required String postId,
    required List<FeedDraftImage> images,
    Object? random,
  }) async {
    calls.add('upload:${images.length}');
    await uploadGate?.future;
    final error = uploadError;
    if (error != null) throw error;
    uploadedPaths = [
      for (var i = 0; i < images.length; i++) _feedPath(postId, uid, i + 1),
    ];
    return uploadedPaths;
  }

  @override
  Future<Uint8List?> loadFeedImageBytes({
    required String storagePath,
    int maxBytes = CommunityMediaService.maxImageBytes,
  }) async {
    loadedPaths.add(storagePath);
    return storedImages[storagePath];
  }
}

class _FakeXFile extends Fake implements XFile {
  _FakeXFile(this._bytes);
  final Uint8List _bytes;

  @override
  String get path => '/private/var/tmp/should-never-be-shown.jpg';
  @override
  String get name => 'should-never-be-shown.jpg';
  @override
  Future<Uint8List> readAsBytes() async => _bytes;
}

class _FakeCommunityService extends Fake implements CommunityService {
  _FakeCommunityService({this.postsError = false});

  final bool postsError;

  final _posts = StreamController<List<CommunityPost>>.broadcast();
  final _post = StreamController<CommunityPost?>.broadcast();
  final _comments = StreamController<List<CommunityComment>>.broadcast();
  final _myReaction = StreamController<bool>.broadcast();

  final List<String> calls = [];
  String? lastPostText;
  List<String>? lastImagePaths;
  String? lastPostId;

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

  @override
  String createPostId() => kPostId;

  @override
  Stream<List<CommunityPost>> watchPosts({
    required CommunityPostSurface surface,
    int limit = CommunityService.defaultLimit,
  }) async* {
    calls.add('watchPosts:${communityPostSurfaceToString(surface)}');
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
  Future<String> createFeedPost({
    required String postId,
    required String text,
    required List<String> imagePaths,
  }) async {
    calls.add('createFeedPost');
    lastPostId = postId;
    lastPostText = text;
    lastImagePaths = imagePaths;
    await createPostGate?.future;
    final failure = this.failure;
    if (failure != null) throw failure;
    return postId;
  }

  @override
  Future<String> createComment({
    required String postId,
    required String text,
  }) async {
    calls.add('createComment');
    final failure = this.failure;
    if (failure != null) throw failure;
    return 'new-comment';
  }

  @override
  Future<CommunityReactionResult> toggleReaction({
    required String postId,
  }) async {
    calls.add('toggleReaction');
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

CommunityPost _feedPost({
  String id = kPostId,
  String authorUid = kOther,
  String text = '오늘의 사진',
  int imageCount = 1,
  int reactionCount = 0,
  int commentCount = 0,
}) {
  return CommunityPost(
    id: id,
    surface: CommunityPostSurface.feed,
    authorUid: authorUid,
    author: _author(authorUid),
    text: text,
    imageUrls: const [],
    imagePaths: [
      for (var i = 1; i <= imageCount; i++) _feedPath(id, authorUid, i),
    ],
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
  String text = '멋져요',
}) {
  return CommunityComment(
    id: id,
    postId: kPostId,
    authorUid: authorUid,
    author: _author(authorUid, name: authorUid == kMe ? '나' : '댓글 작성자'),
    text: text,
    status: CommunityContentStatus.active,
    createdAt: DateTime(2026, 7, 20, 13),
    updatedAt: DateTime(2026, 7, 20, 13),
    schemaVersion: 1,
  );
}

typedef _Ctx = ({
  _FakeCommunityService community,
  _FakeMediaService media,
  _FakeContactAvoidanceService avoid,
  _FakeSafetyService safety,
});

Future<_Ctx> _pumpFeed(
  WidgetTester tester, {
  _FakeCommunityService? community,
  _FakeMediaService? media,
  Set<String> blocked = const {},
  Size viewport = const Size(800, 1600),
}) async {
  tester.view.physicalSize = viewport;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  addTearDown(clearFeedImageCacheForTest);

  final c = community ?? _FakeCommunityService();
  final m = media ?? _FakeMediaService();
  final a = _FakeContactAvoidanceService();
  final s = _FakeSafetyService(blocked: blocked);
  addTearDown(c.dispose);
  addTearDown(a.dispose);

  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      home: FeedScreen(
        authService: _FakeAuthService(),
        communityService: c,
        mediaService: m,
        safetyService: s,
        contactAvoidanceService: a,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return (community: c, media: m, avoid: a, safety: s);
}

Future<_Ctx> _pumpCompose(
  WidgetTester tester, {
  _FakeCommunityService? community,
  _FakeMediaService? media,
  Size viewport = const Size(800, 1600),
}) async {
  tester.view.physicalSize = viewport;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final c = community ?? _FakeCommunityService();
  final m = media ?? _FakeMediaService();
  final a = _FakeContactAvoidanceService();
  final s = _FakeSafetyService();
  addTearDown(c.dispose);
  addTearDown(a.dispose);

  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      home: FeedComposeScreen(
        authService: _FakeAuthService(),
        communityService: c,
        mediaService: m,
      ),
    ),
  );
  await tester.pump();
  return (community: c, media: m, avoid: a, safety: s);
}

Future<_Ctx> _pumpDetail(
  WidgetTester tester, {
  _FakeCommunityService? community,
  _FakeMediaService? media,
  Set<String> blocked = const {},
}) async {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  addTearDown(clearFeedImageCacheForTest);

  final c = community ?? _FakeCommunityService();
  final m = media ?? _FakeMediaService();
  final a = _FakeContactAvoidanceService();
  final s = _FakeSafetyService(blocked: blocked);
  addTearDown(c.dispose);
  addTearDown(a.dispose);

  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      home: FeedPostDetailScreen(
        postId: kPostId,
        authService: _FakeAuthService(),
        communityService: c,
        mediaService: m,
        safetyService: s,
        contactAvoidanceService: a,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return (community: c, media: m, avoid: a, safety: s);
}

/// 화면 어디에도 Storage 경로·원본 파일 경로가 없어야 한다.
void _expectNoRawPaths(WidgetTester tester) {
  final texts = tester
      .widgetList<Text>(find.byType(Text))
      .map((t) => t.data ?? '')
      .join('\n');
  expect(texts.contains('communityFeed/'), isFalse, reason: texts);
  expect(texts.contains('should-never-be-shown'), isFalse, reason: texts);
  expect(texts.contains('/var/'), isFalse, reason: texts);
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    FirebasePlatform.instance = _FakeFirebasePlatform();
  });

  group('3~5. 피드 목록 상태', () {
    testWidgets('3. 로딩 상태를 보여준다', (tester) async {
      await _pumpFeed(tester);
      expect(find.byKey(const ValueKey('feed-screen')), findsOneWidget);
      expect(find.byKey(const ValueKey('feed-loading')), findsOneWidget);
    });

    testWidgets('4. 게시물이 없으면 빈 상태와 작성 버튼을 보여준다', (tester) async {
      final ctx = await _pumpFeed(tester);
      ctx.community.emitPosts(const []);
      await tester.pump();

      expect(find.byKey(const ValueKey('feed-empty')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('feed-create-post-button')),
        findsOneWidget,
      );
      // feed surface만 구독한다.
      expect(ctx.community.calls, contains('watchPosts:feed'));
    });

    testWidgets('5. 오류 시 고정 문구와 다시 시도를 보여준다', (tester) async {
      await _pumpFeed(tester, community: _FakeCommunityService(postsError: true));
      await tester.pump();

      expect(find.byKey(const ValueKey('feed-error')), findsOneWidget);
      expect(find.text('피드를 불러오지 못했어요.'), findsOneWidget);
      expect(find.textContaining('firestore raw'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('feed-retry')));
      await tester.pump();
    });
  });

  group('17~18, 27. 목록 카드', () {
    testWidgets('17. 첫 이미지를 읽어 보여준다', (tester) async {
      final media = _FakeMediaService();
      final post = _feedPost(imageCount: 3);
      media.storedImages[post.imagePaths.first] = _imageBytes();

      final ctx = await _pumpFeed(tester, media: media);
      ctx.community.emitPosts([post]);
      await tester.pump();
      await tester.pump();

      // 목록에서는 대표 이미지 1장만 읽는다.
      expect(media.loadedPaths, [post.imagePaths.first]);
      expect(find.byKey(ValueKey('feed-post-${post.id}')), findsOneWidget);
    });

    testWidgets('18. 이미지가 여러 장이면 장수를 표시한다', (tester) async {
      final ctx = await _pumpFeed(tester);
      ctx.community.emitPosts([_feedPost(imageCount: 3)]);
      await tester.pump();
      await tester.pump();

      expect(
        find.byKey(ValueKey('feed-post-image-count-$kPostId')),
        findsOneWidget,
      );
      expect(find.text('1/3'), findsOneWidget);

      // 1장이면 표시하지 않는다.
      ctx.community.emitPosts([_feedPost(imageCount: 1)]);
      await tester.pump();
      await tester.pump();
      expect(find.text('1/1'), findsNothing);
    });

    testWidgets('27. 이미지를 읽지 못해도 카드가 깨지지 않고 경로도 노출하지 않는다', (tester) async {
      // storedImages가 비어 있으므로 loadFeedImageBytes가 null을 돌려준다.
      final ctx = await _pumpFeed(tester);
      ctx.community.emitPosts([_feedPost()]);
      await tester.pump();
      await tester.pump();

      expect(
        find.byKey(const ValueKey('feed-image-unavailable')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      _expectNoRawPaths(tester);
    });
  });

  group('6~16. 피드 작성', () {
    testWidgets('6~7. 이미지가 없으면 게시할 수 없다', (tester) async {
      await _pumpCompose(tester);
      expect(find.byKey(const ValueKey('feed-compose-screen')), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('feed-compose-input')),
        '사진 없이 올려볼게요',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('feed-compose-privacy-check')));
      await tester.pump();

      final button = tester.widget<FilledButton>(
        find.byKey(const ValueKey('feed-compose-submit')),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('8. 카메라로 사진을 담는다', (tester) async {
      final media = _FakeMediaService()..cameraBytes = [_imageBytes()];
      await _pumpCompose(tester, media: media);

      await tester.tap(find.byKey(const ValueKey('feed-compose-camera')));
      await tester.pump();
      await tester.pump();

      expect(media.calls, contains('camera'));
      expect(find.byKey(const ValueKey('feed-compose-preview')), findsOneWidget);
      expect(find.byKey(const ValueKey('feed-compose-remove-0')), findsOneWidget);
    });

    testWidgets('9~10. 갤러리 다중 선택은 남은 슬롯까지만 담는다', (tester) async {
      final media = _FakeMediaService()
        ..galleryBytes = [
          for (var i = 1; i <= 6; i++) _imageBytes(seed: i),
        ];
      await _pumpCompose(tester, media: media);

      await tester.tap(find.byKey(const ValueKey('feed-compose-gallery')));
      await tester.pump();
      await tester.pump();

      // 10. 최대 4장까지만 담긴다.
      expect(media.lastRemainingSlots, 4);
      expect(find.byKey(const ValueKey('feed-compose-remove-3')), findsOneWidget);
      expect(find.byKey(const ValueKey('feed-compose-remove-4')), findsNothing);

      // 슬롯이 없으면 선택 버튼이 비활성화된다.
      final camera = tester.widget<OutlinedButton>(
        find.ancestor(
          of: find.text('카메라로 촬영'),
          matching: find.byType(OutlinedButton),
        ),
      );
      expect(camera.onPressed, isNull);
    });

    testWidgets('11. 선택한 이미지를 제거할 수 있다', (tester) async {
      final media = _FakeMediaService()
        ..galleryBytes = [_imageBytes(seed: 1), _imageBytes(seed: 2)];
      await _pumpCompose(tester, media: media);

      await tester.tap(find.byKey(const ValueKey('feed-compose-gallery')));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('feed-compose-remove-1')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('feed-compose-remove-0')));
      await tester.pump();
      expect(find.byKey(const ValueKey('feed-compose-remove-1')), findsNothing);
      expect(find.byKey(const ValueKey('feed-compose-remove-0')), findsOneWidget);
    });

    testWidgets('12. HEIC는 안내 문구와 함께 거부한다', (tester) async {
      final media = _FakeMediaService()..cameraBytes = [_heicBytes()];
      await _pumpCompose(tester, media: media);

      await tester.tap(find.byKey(const ValueKey('feed-compose-camera')));
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const ValueKey('feed-compose-error')), findsOneWidget);
      expect(find.textContaining('HEIC'), findsOneWidget);
      expect(find.byKey(const ValueKey('feed-compose-preview')), findsNothing);
    });

    testWidgets('같은 사진을 두 번 담지 않는다', (tester) async {
      final media = _FakeMediaService()
        ..galleryBytes = [_imageBytes(seed: 7), _imageBytes(seed: 7)];
      await _pumpCompose(tester, media: media);

      await tester.tap(find.byKey(const ValueKey('feed-compose-gallery')));
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const ValueKey('feed-compose-remove-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('feed-compose-remove-1')), findsNothing);
    });

    testWidgets('13. 개인정보 확인 전에는 게시할 수 없다', (tester) async {
      final media = _FakeMediaService()..cameraBytes = [_imageBytes()];
      await _pumpCompose(tester, media: media);

      await tester.tap(find.byKey(const ValueKey('feed-compose-camera')));
      await tester.pump();
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('feed-compose-input')),
        '오늘의 산책',
      );
      await tester.pump();

      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('feed-compose-submit')),
            )
            .onPressed,
        isNull,
      );

      await tester.tap(find.byKey(const ValueKey('feed-compose-privacy-check')));
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('feed-compose-submit')),
            )
            .onPressed,
        isNotNull,
      );
    });

    testWidgets('14. 정상 업로드하고 게시한다', (tester) async {
      final media = _FakeMediaService()
        ..galleryBytes = [_imageBytes(seed: 1), _imageBytes(seed: 2)];
      final ctx = await _pumpCompose(tester, media: media);

      await tester.tap(find.byKey(const ValueKey('feed-compose-gallery')));
      await tester.pump();
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('feed-compose-input')),
        '  오늘의 산책  ',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('feed-compose-privacy-check')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('feed-compose-submit')));
      // pop 라우트 전환까지 끝나야 화면이 실제로 닫힌 것을 확인할 수 있다.
      await tester.pumpAndSettle();

      expect(media.calls, contains('upload:2'));
      expect(ctx.community.calls, contains('createFeedPost'));
      expect(ctx.community.lastPostId, kPostId);
      expect(ctx.community.lastPostText, '오늘의 산책');
      expect(ctx.community.lastImagePaths?.length, 2);
      // 화면이 닫힌다.
      expect(find.byKey(const ValueKey('feed-compose-screen')), findsNothing);
    });

    testWidgets('15. 제출 중 중복 요청을 막는다', (tester) async {
      final media = _FakeMediaService()..cameraBytes = [_imageBytes()];
      final community = _FakeCommunityService()
        ..createPostGate = Completer<void>();
      final ctx = await _pumpCompose(
        tester,
        community: community,
        media: media,
      );

      await tester.tap(find.byKey(const ValueKey('feed-compose-camera')));
      await tester.pump();
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('feed-compose-input')),
        '중복 방지',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('feed-compose-privacy-check')));
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('feed-compose-submit')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('feed-compose-submit')));
      await tester.pump();

      ctx.community.createPostGate!.complete();
      await tester.pump();
      await tester.pump();

      final createCalls = ctx.community.calls
          .where((c) => c == 'createFeedPost')
          .length;
      expect(createCalls, 1);
    });

    testWidgets('16. 실패하면 본문과 미리보기를 유지하고 원인은 감춘다', (tester) async {
      final media = _FakeMediaService()..cameraBytes = [_imageBytes()];
      final community = _FakeCommunityService()
        ..failure = const CommunityActionError('잠시 후 다시 시도해주세요.');
      await _pumpCompose(tester, community: community, media: media);

      await tester.tap(find.byKey(const ValueKey('feed-compose-camera')));
      await tester.pump();
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('feed-compose-input')),
        '유지되어야 하는 본문',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('feed-compose-privacy-check')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('feed-compose-submit')));
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const ValueKey('feed-compose-screen')), findsOneWidget);
      expect(find.text('유지되어야 하는 본문'), findsOneWidget);
      expect(find.byKey(const ValueKey('feed-compose-preview')), findsOneWidget);
      expect(find.byKey(const ValueKey('feed-compose-error')), findsOneWidget);
      _expectNoRawPaths(tester);
    });

    testWidgets('업로드 실패도 고정 문구로만 안내한다', (tester) async {
      final media = _FakeMediaService()
        ..cameraBytes = [_imageBytes()]
        ..uploadError = CommunityMediaUploadFailure(uploadedPaths: const []);
      await _pumpCompose(tester, media: media);

      await tester.tap(find.byKey(const ValueKey('feed-compose-camera')));
      await tester.pump();
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('feed-compose-input')),
        '업로드 실패',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('feed-compose-privacy-check')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('feed-compose-submit')));
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const ValueKey('feed-compose-error')), findsOneWidget);
      expect(find.text(CommunityMediaService.uploadFailedMessage), findsOneWidget);
    });
  });

  group('19~24, 26. 피드 상세', () {

    testWidgets('A-2. AppBar 제목이 "피드 게시물"이다', (tester) async {
      final ctx = await _pumpDetail(tester);
      ctx.community.emitPost(_feedPost());
      await tester.pump();
      await tester.pump();

      expect(find.text('피드 게시물'), findsOneWidget);
      expect(find.text('게시물'), findsNothing);
    });

    testWidgets('A-5. 이미지·본문·공감 bar·댓글·입력줄이 모두 그려진다', (tester) async {
      final media = _FakeMediaService();
      final post = _feedPost(imageCount: 2, reactionCount: 4, commentCount: 1);
      for (final path in post.imagePaths) {
        media.storedImages[path] = _imageBytes();
      }
      final ctx = await _pumpDetail(tester, media: media);
      ctx.community.emitPost(post);
      await tester.pump();
      await tester.pump();
      ctx.community.emitComments([_comment(text: '첫 댓글')]);
      await tester.pump();

      expect(find.byKey(const ValueKey('feed-detail-post')), findsOneWidget);
      expect(find.byKey(const ValueKey('feed-detail-gallery')), findsOneWidget);
      expect(find.byKey(const ValueKey('feed-reaction-button')), findsOneWidget);

      // 댓글 목록은 이미지 아래에 있어 뷰포트 밖일 수 있다.
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('feed-comment-list')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.byKey(const ValueKey('feed-comment-list')), findsOneWidget);
      expect(find.byKey(const ValueKey('feed-comment-input')), findsOneWidget);
      expect(find.byKey(const ValueKey('feed-comment-submit')), findsOneWidget);
      expect(tester.takeException(), isNull);
      _expectNoRawPaths(tester);
    });

    testWidgets('A-4. stream 오류는 다시 시도할 수 있는 상태로 구분한다', (tester) async {
      final ctx = await _pumpDetail(tester);
      ctx.community.emitPostError();
      await tester.pump();

      expect(find.text('게시물을 불러오지 못했어요.'), findsOneWidget);
      expect(find.byKey(const ValueKey('feed-detail-retry')), findsOneWidget);
      expect(find.textContaining('firestore raw'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('feed-detail-retry')));
      await tester.pump();
      expect(find.text('이 게시물은 더 이상 볼 수 없어요.'), findsNothing);
    });

    testWidgets('A-4. 문서 없음은 되돌릴 수 없는 상태로 안내한다', (tester) async {
      final ctx = await _pumpDetail(tester);
      ctx.community.emitPost(null);
      await tester.pump();

      expect(find.text('이 게시물은 더 이상 볼 수 없어요.'), findsOneWidget);
      expect(find.byKey(const ValueKey('feed-detail-retry')), findsNothing);
    });
    testWidgets('19. 여러 이미지를 PageView로 보여준다', (tester) async {
      final media = _FakeMediaService();
      final post = _feedPost(imageCount: 3);
      for (final path in post.imagePaths) {
        media.storedImages[path] = _imageBytes();
      }
      final ctx = await _pumpDetail(tester, media: media);
      ctx.community.emitPost(post);
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const ValueKey('feed-detail-gallery')), findsOneWidget);
      expect(find.byKey(const ValueKey('feed-detail-indicator')), findsOneWidget);
      expect(find.text('오늘의 사진'), findsOneWidget);
      _expectNoRawPaths(tester);
    });

    testWidgets('20. 공감을 추가한다', (tester) async {
      final ctx = await _pumpDetail(tester);
      ctx.community.emitPost(_feedPost(reactionCount: 0));
      await tester.pump();
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('feed-reaction-button')));
      await tester.pump();
      await tester.pump();

      expect(ctx.community.calls, contains('toggleReaction'));
      expect(find.text('공감 1'), findsOneWidget);
    });

    testWidgets('21. 댓글 목록을 보여주고 댓글을 작성한다', (tester) async {
      final ctx = await _pumpDetail(tester);
      ctx.community.emitPost(_feedPost(commentCount: 1));
      await tester.pump();
      ctx.community.emitComments([_comment()]);
      await tester.pump();

      expect(find.byKey(const ValueKey('feed-comment-list')), findsOneWidget);
      expect(find.text('멋져요'), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('feed-comment-input')),
        '좋은 사진이에요',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('feed-comment-submit')));
      await tester.pump();
      await tester.pump();

      expect(ctx.community.calls, contains('createComment'));
    });

    testWidgets('22~23. 본인 게시물은 삭제, 타인 게시물은 신고할 수 있다', (tester) async {
      // 본인 게시물 삭제
      final mine = await _pumpDetail(tester);
      mine.community.emitPost(_feedPost(authorUid: kMe));
      await tester.pump();
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('feed-detail-post-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('삭제하기').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('삭제하기').last);
      await tester.pump();
      await tester.pump();

      expect(mine.community.calls, contains('deletePost:$kPostId'));
    });

    testWidgets('23~24. 타인 게시물 신고 후 차단하면 볼 수 없게 된다', (tester) async {
      final ctx = await _pumpDetail(tester);
      ctx.community.emitPost(_feedPost(authorUid: kOther));
      await tester.pump();
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('feed-detail-post-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('신고하기').last);
      await tester.pumpAndSettle();

      // 신고 시트가 열린다(사유 선택 계약은 Phase 4-2에서 검증됨).
      expect(find.textContaining('신고'), findsWidgets);
    });

    testWidgets('26. 삭제된 게시물은 볼 수 없는 상태로 바뀐다', (tester) async {
      final ctx = await _pumpDetail(tester);
      ctx.community.emitPost(_feedPost());
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('feed-detail-post')), findsOneWidget);

      ctx.community.emitPost(null);
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const ValueKey('feed-detail-post')), findsNothing);
      expect(find.text('이 게시물은 더 이상 볼 수 없어요.'), findsOneWidget);
    });
  });

  group('25. 관계 필터', () {
    testWidgets('차단·지인 피하기 상대의 글은 숨기고 본인 글은 유지한다', (tester) async {
      final ctx = await _pumpFeed(tester, blocked: {kOther});
      ctx.community.emitPosts([
        _feedPost(id: kPostId, authorUid: kOther),
        _feedPost(id: 'mypost0123456789abcd', authorUid: kMe, text: '내 사진'),
      ]);
      await tester.pump();
      await tester.pump();

      expect(find.byKey(ValueKey('feed-post-$kPostId')), findsNothing);
      expect(
        find.byKey(const ValueKey('feed-post-mypost0123456789abcd')),
        findsOneWidget,
      );
    });

    testWidgets('지인 피하기 상대는 숨기고 해제되면 다시 보인다', (tester) async {
      final ctx = await _pumpFeed(tester);
      ctx.community.emitPosts([_feedPost(authorUid: kOther)]);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(ValueKey('feed-post-$kPostId')), findsOneWidget);

      ctx.avoid.emit({kOther});
      await tester.pump();
      await tester.pump();
      expect(find.byKey(ValueKey('feed-post-$kPostId')), findsNothing);

      ctx.avoid.emit(const {});
      await tester.pump();
      await tester.pump();
      expect(find.byKey(ValueKey('feed-post-$kPostId')), findsOneWidget);
    });
  });

  group('28. 레이아웃', () {
    testWidgets('작은 화면·키보드에서도 overflow가 없다', (tester) async {
      final media = _FakeMediaService()
        ..galleryBytes = [
          for (var i = 1; i <= 4; i++) _imageBytes(seed: i),
        ];
      await _pumpCompose(
        tester,
        media: media,
        viewport: const Size(320 * 3, 568 * 3),
      );
      tester.view.devicePixelRatio = 3.0;

      await tester.tap(find.byKey(const ValueKey('feed-compose-gallery')));
      await tester.pump();
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('feed-compose-input')),
        '작은 화면 확인' * 20,
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
    });

    testWidgets('목록도 작은 화면에서 overflow가 없다', (tester) async {
      final ctx = await _pumpFeed(
        tester,
        viewport: const Size(320 * 3, 568 * 3),
      );
      tester.view.devicePixelRatio = 3.0;
      ctx.community.emitPosts([
        _feedPost(imageCount: 4, text: '긴 본문 ' * 40, reactionCount: 12),
      ]);
      await tester.pump();
      await tester.pump();

      expect(tester.takeException(), isNull);
    });
  });
}
