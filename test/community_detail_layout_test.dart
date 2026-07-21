// ignore_for_file: depend_on_referenced_packages
import 'dart:async';
import 'dart:typed_data';

import 'package:dating_app/core/theme/app_theme.dart';
import 'package:dating_app/features/community/community_audience_filter.dart';
import 'package:dating_app/features/community/community_comment_widgets.dart';
import 'package:dating_app/features/community/feed/feed_widgets.dart';
import 'package:dating_app/models/community/community_author_snapshot.dart';
import 'package:dating_app/models/community/community_comment.dart';
import 'package:dating_app/models/community/community_enums.dart';
import 'package:dating_app/services/community/community_media_service.dart';
import 'package:dating_app/services/database/firestore_service.dart';
import 'package:dating_app/services/privacy/contact_avoidance_service.dart';
import 'package:dating_app/services/safety/safety_service.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

// Phase 4-3A — 라운지·피드 상세가 실기기에서 깨진 원인의 재현 테스트.
//
// 실기기 stack trace: "BoxConstraints forces an infinite width" @
// FilledButton-[<'lounge-comment-submit'>].
//
// 기존 테스트가 이걸 놓친 이유는 plain MaterialApp의 **기본 theme**으로만
// pump했기 때문이다. 앱 실제 theme(AppTheme.light)은 Filled/Outlined/Elevated
// 버튼에 minimumSize: Size.fromHeight(48) — 즉 폭이 double.infinity인 값을
// 준다. Row의 non-flex 자식은 unbounded width 제약을 받으므로 이 무한 폭이
// 그대로 전달돼 layout assertion이 난다.
//
// 따라서 이 파일의 모든 테스트는 반드시 AppTheme.light로 감싼다.

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

class _FakeSafetyService extends SafetyService {
  _FakeSafetyService() : super(firestoreService: FirestoreService());

  @override
  Future<Set<String>> getBlockedRelationshipUids(String currentUid) async =>
      const <String>{};
}

class _FakeContactAvoidanceService extends ContactAvoidanceService {
  final _controller = StreamController<Set<String>>.broadcast();

  @override
  Stream<Set<String>> watchAvoidedUids(String uid) async* {
    yield const <String>{};
    yield* _controller.stream;
  }

  Future<void> dispose() => _controller.close();
}

CommunityComment _comment(String id) => CommunityComment(
  id: id,
  postId: 'p1',
  authorUid: kOther,
  author: const CommunityAuthorSnapshot(
    uid: kOther,
    displayName: '이웃',
    photoUrl: '',
    photoVerified: false,
    workVerified: false,
    schoolVerified: false,
  ),
  text: '반가워요',
  status: CommunityContentStatus.active,
  createdAt: DateTime(2026, 7, 20, 12),
  updatedAt: null,
  schemaVersion: 1,
);

/// 실제 앱 theme + 지정한 화면 크기/키보드 상태로 댓글 입력줄을 그린다.
Future<void> _pumpCommentInput(
  WidgetTester tester, {
  required String keyPrefix,
  required bool submitting,
  required String text,
  Size viewport = const Size(360, 720),
  double keyboardInset = 0,
}) async {
  tester.view.physicalSize = viewport;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final controller = TextEditingController(text: text);
  addTearDown(controller.dispose);

  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(
        body: MediaQuery(
          data: MediaQueryData(
            size: viewport,
            viewInsets: EdgeInsets.only(bottom: keyboardInset),
          ),
          child: Column(
            children: [
              const Expanded(child: SizedBox.shrink()),
              CommunityCommentInput(
                keyPrefix: keyPrefix,
                controller: controller,
                submitting: submitting,
                onSubmit: () {},
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// 공감 bar + 댓글 목록 + 입력줄을 상세 화면과 같은 배치로 그린다.
Future<void> _pumpDetailBody(
  WidgetTester tester, {
  required String keyPrefix,
  Size viewport = const Size(360, 720),
}) async {
  tester.view.physicalSize = viewport;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final controller = TextEditingController();
  addTearDown(controller.dispose);
  final avoid = _FakeContactAvoidanceService();
  addTearDown(avoid.dispose);
  final audience = CommunityAudienceFilter(
    safetyService: _FakeSafetyService(),
    contactAvoidanceService: avoid,
  );
  addTearDown(audience.dispose);

  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(
        body: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                children: [
                  CommunityReactionBar(
                    keyPrefix: keyPrefix,
                    reactionStream: Stream<bool>.value(false),
                    overrideReacted: null,
                    reactionCount: 12,
                    commentCount: 3,
                    onToggle: () {},
                  ),
                  const SizedBox(height: 16),
                  CommunityCommentList(
                    keyPrefix: keyPrefix,
                    stream: Stream<List<CommunityComment>>.value([
                      _comment('c1'),
                    ]),
                    selfUid: kMe,
                    audience: audience,
                    onDelete: (_) {},
                    onReport: (_) {},
                  ),
                ],
              ),
            ),
            CommunityCommentInput(
              keyPrefix: keyPrefix,
              controller: controller,
              submitting: false,
              onSubmit: () {},
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

class _RecordingMediaService extends Fake implements CommunityMediaService {
  int calls = 0;

  /// 호출 순서대로 돌려줄 결과. Exception이면 throw한다.
  final List<Object?> results;

  _RecordingMediaService(this.results);

  @override
  Future<Uint8List?> loadFeedImageBytes({
    required String storagePath,
    int maxBytes = CommunityMediaService.maxImageBytes,
  }) async {
    calls++;
    final result = results.isEmpty
        ? null
        : results[calls - 1 < results.length ? calls - 1 : results.length - 1];
    if (result is Exception) throw result;
    return result as Uint8List?;
  }
}

/// [mountId]가 다르면 State가 재사용되지 않아 화면 재진입과 같아진다.
Future<void> _pumpFeedImage(
  WidgetTester tester,
  CommunityMediaService media,
  String path, {
  int mountId = 0,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(
        body: FeedStorageImage(
          key: ValueKey('mount-$mountId'),
          mediaService: media,
          storagePath: path,
          height: 200,
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    FirebasePlatform.instance = _FakeFirebasePlatform();
  });

  group('A-1. 댓글 등록 버튼 제약 (실제 앱 theme)', () {
    for (final keyPrefix in ['lounge', 'feed']) {
      for (final submitting in [false, true]) {
        testWidgets(
          '$keyPrefix / submitting=$submitting 에서 layout exception이 없다',
          (tester) async {
            await _pumpCommentInput(
              tester,
              keyPrefix: keyPrefix,
              submitting: submitting,
              text: '안녕하세요',
            );
            expect(tester.takeException(), isNull);
            expect(
              find.byKey(ValueKey('$keyPrefix-comment-submit')),
              findsOneWidget,
            );
          },
        );
      }
    }

    testWidgets('버튼 폭은 64~80, 높이는 48이고 Row 폭을 넘지 않는다', (tester) async {
      await _pumpCommentInput(
        tester,
        keyPrefix: 'lounge',
        submitting: false,
        text: '안녕하세요',
      );
      expect(tester.takeException(), isNull);

      final size = tester.getSize(
        find.byKey(const ValueKey('lounge-comment-submit')),
      );
      expect(size.width, greaterThanOrEqualTo(64));
      expect(size.width, lessThanOrEqualTo(80));
      expect(size.height, 48);

      // 입력창 + 버튼이 360px 안에 들어간다.
      final field = tester.getRect(
        find.byKey(const ValueKey('lounge-comment-input')),
      );
      final button = tester.getRect(
        find.byKey(const ValueKey('lounge-comment-submit')),
      );
      expect(field.left, greaterThanOrEqualTo(0));
      expect(button.right, lessThanOrEqualTo(360));
    });

    testWidgets('"등록" 텍스트가 잘리지 않는다', (tester) async {
      await _pumpCommentInput(
        tester,
        keyPrefix: 'feed',
        submitting: false,
        text: '안녕하세요',
      );
      expect(tester.takeException(), isNull);
      expect(find.text('등록'), findsOneWidget);
    });

    testWidgets('submitting이면 spinner를 보여주고 비활성화된다', (tester) async {
      await _pumpCommentInput(
        tester,
        keyPrefix: 'feed',
        submitting: true,
        text: '안녕하세요',
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      final button = tester.widget<FilledButton>(
        find.byKey(const ValueKey('feed-comment-submit')),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('입력이 비어 있으면 등록 버튼이 비활성화된다', (tester) async {
      await _pumpCommentInput(
        tester,
        keyPrefix: 'lounge',
        submitting: false,
        text: '   ',
      );
      expect(tester.takeException(), isNull);
      final button = tester.widget<FilledButton>(
        find.byKey(const ValueKey('lounge-comment-submit')),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('작은 세로 화면 + 키보드가 올라와도 exception이 없다', (tester) async {
      await _pumpCommentInput(
        tester,
        keyPrefix: 'lounge',
        submitting: false,
        text: '안녕하세요',
        viewport: const Size(360, 560),
        keyboardInset: 280,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('A-5. 상세 본문 구성 (실제 앱 theme)', () {
    for (final keyPrefix in ['lounge', 'feed']) {
      testWidgets('$keyPrefix 공감 bar·댓글·입력줄이 모두 그려진다', (tester) async {
        await _pumpDetailBody(tester, keyPrefix: keyPrefix);
        expect(tester.takeException(), isNull);
        expect(
          find.byKey(ValueKey('$keyPrefix-reaction-button')),
          findsOneWidget,
        );
        expect(find.byKey(ValueKey('$keyPrefix-comment-list')), findsOneWidget);
        expect(find.byKey(ValueKey('$keyPrefix-comment-input')), findsOneWidget);
        expect(
          find.byKey(ValueKey('$keyPrefix-comment-submit')),
          findsOneWidget,
        );
        expect(find.text('공감 12'), findsOneWidget);
        expect(find.text('댓글 3'), findsOneWidget);
      });
    }
  });

  group('A-3. Feed 이미지 실패 캐시', () {
    setUp(clearFeedImageCacheForTest);
    tearDown(clearFeedImageCacheForTest);

    testWidgets('실패한 결과는 캐시에 남지 않아 다음 요청이 다시 시도된다', (tester) async {
      final bytes = Uint8List.fromList(kTransparentImage);
      final media = _RecordingMediaService([null, bytes]);

      await _pumpFeedImage(tester, media, 'p/1.jpg');
      expect(media.calls, 1);
      expect(
        find.byKey(const ValueKey('feed-image-unavailable')),
        findsOneWidget,
      );

      // 같은 경로를 새로 요청하면 캐시된 실패가 아니라 새 getData가 나간다.
      await _pumpFeedImage(tester, media, 'p/1.jpg', mountId: 1);
      expect(media.calls, 2);
    });

    testWidgets('예외로 실패해도 캐시에 남지 않는다', (tester) async {
      final bytes = Uint8List.fromList(kTransparentImage);
      final media = _RecordingMediaService([Exception('boom'), bytes]);

      await _pumpFeedImage(tester, media, 'p/2.jpg');
      expect(media.calls, 1);
      expect(
        find.byKey(const ValueKey('feed-image-unavailable')),
        findsOneWidget,
      );

      await _pumpFeedImage(tester, media, 'p/2.jpg', mountId: 1);
      expect(media.calls, 2);
    });

    testWidgets('성공한 bytes는 캐시돼 재요청하지 않는다', (tester) async {
      final bytes = Uint8List.fromList(kTransparentImage);
      final media = _RecordingMediaService([bytes]);

      await _pumpFeedImage(tester, media, 'p/3.jpg');
      expect(media.calls, 1);

      await _pumpFeedImage(tester, media, 'p/3.jpg', mountId: 1);
      expect(media.calls, 1);
    });

    testWidgets('"다시 시도"를 누르면 새 요청이 나가고 성공하면 이미지가 뜬다', (tester) async {
      final bytes = Uint8List.fromList(kTransparentImage);
      final media = _RecordingMediaService([null, bytes]);

      await _pumpFeedImage(tester, media, 'p/4.jpg');
      expect(media.calls, 1);

      await tester.tap(find.byKey(const ValueKey('feed-image-retry')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(media.calls, 2);
      expect(find.byKey(const ValueKey('feed-image-loaded')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('삭제 시 evict하면 다음 요청이 다시 나간다', (tester) async {
      final bytes = Uint8List.fromList(kTransparentImage);
      final media = _RecordingMediaService([bytes]);

      await _pumpFeedImage(tester, media, 'p/5.jpg');
      expect(media.calls, 1);

      evictFeedImageCache(['p/5.jpg']);
      await _pumpFeedImage(tester, media, 'p/5.jpg', mountId: 1);
      expect(media.calls, 2);
    });
  });
}

/// 1x1 투명 PNG. Image.memory가 실제로 디코드할 수 있는 최소 bytes.
const List<int> kTransparentImage = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
];
