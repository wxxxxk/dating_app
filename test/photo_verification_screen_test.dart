// PhotoVerificationScreen은 concrete PhotoVerificationService를 요구하고,
// 그 생성자는 FirebaseFirestore/FirebaseStorage.instance를 건드린다. 기존
// 테스트와 같은 방식으로 firebase_core 플랫폼만 fake로 바꿔 인스턴스 생성을
// 가능하게 한 뒤, 필요한 메서드만 오버라이드해 네트워크 없이 화면을 검증한다.
// ignore_for_file: depend_on_referenced_packages
import 'dart:async';
import 'dart:io';

import 'package:dating_app/features/verification/photo_verification_screen.dart';
import 'package:dating_app/models/photo_verification_request.dart';
import 'package:dating_app/services/verification/photo_verification_service.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

const String kUid = 'userA';

const Key kCapture = ValueKey('photo-verification-capture-button');
const Key kRetake = ValueKey('photo-verification-retake-button');
const Key kSubmit = ValueKey('photo-verification-submit-button');
const Key kConsent = ValueKey('photo-verification-consent');
const Key kPreview = ValueKey('photo-verification-preview');
const Key kGuide = ValueKey('photo-verification-guide');
const Key kPending = ValueKey('photo-verification-pending');
const Key kApproved = ValueKey('photo-verification-approved');
const Key kRejected = ValueKey('photo-verification-rejected');

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

/// 촬영/제출 호출을 캡처하는 test double.
class _FakeService extends PhotoVerificationService {
  _FakeService({PhotoVerificationRequest? initial, this.failMessage})
    : _controller = StreamController<PhotoVerificationRequest?>.broadcast(),
      _latest = initial;

  final StreamController<PhotoVerificationRequest?> _controller;
  final PhotoVerificationRequest? _latest;
  final String? failMessage;

  XFile? nextCapture;
  int captureCalls = 0;
  int submitCalls = 0;
  Completer<void>? gate;

  void emit(PhotoVerificationRequest? request) => _controller.add(request);

  @override
  Stream<PhotoVerificationRequest?> watchRequest(String uid) async* {
    yield _latest;
    yield* _controller.stream;
  }

  @override
  Future<XFile?> captureVerificationPhoto() async {
    captureCalls += 1;
    return nextCapture;
  }

  @override
  Future<void> submitVerificationPhoto({
    required String uid,
    required XFile photo,
  }) async {
    submitCalls += 1;
    if (gate != null) await gate!.future;
    if (failMessage != null) throw PhotoVerificationError(failMessage!);
  }
}

/// 실제 이미지 파일 없이 preview 위젯 경로만 태우기 위한 임시 파일.
XFile _tempPhoto() {
  final file = File(
    '${Directory.systemTemp.path}/photo_verification_test.jpg',
  )..writeAsBytesSync(const [0, 1, 2, 3]);
  return XFile(file.path);
}

PhotoVerificationRequest _request(
  PhotoVerificationStatus status, {
  String? rejectionReason,
}) {
  return PhotoVerificationRequest(
    uid: kUid,
    status: status,
    storagePath: 'photoVerification/$kUid/upload1.jpg',
    submittedAt: DateTime(2026, 7, 21, 12),
    updatedAt: DateTime(2026, 7, 21, 12),
    reviewedAt: status == PhotoVerificationStatus.pending
        ? null
        : DateTime(2026, 7, 21, 13),
    rejectionReason: rejectionReason,
  );
}

/// 스크롤 화면 안의 위젯을 보이게 만든 뒤 탭한다(preview가 길어 하단 요소가
/// 화면 밖에 있을 수 있다).
Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pump();
  await tester.pump();
}

Future<_FakeService> _pump(
  WidgetTester tester, {
  _FakeService? service,
}) async {
  final s = service ?? _FakeService();
  await tester.pumpWidget(
    MaterialApp(
      home: PhotoVerificationScreen(uid: kUid, service: s),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return s;
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    FirebasePlatform.instance = _FakeFirebasePlatform();
  });

  testWidgets('1~2. 요청이 없으면 안내와 촬영 버튼을 보여준다', (tester) async {
    await _pump(tester);

    expect(find.byKey(kGuide), findsOneWidget);
    expect(find.byKey(kCapture), findsOneWidget);
    expect(find.text('인증 사진 촬영하기'), findsOneWidget);
    expect(
      find.text('프로필 사진이 본인의 사진인지 운영자가 확인해요.\n인증용 사진은 공개되지 않으며 검토 후 삭제돼요.'),
      findsOneWidget,
    );
    expect(find.text('밝은 장소에서 촬영해주세요.'), findsOneWidget);
    expect(find.text('마스크·선글라스 등 얼굴을 가리는 물건은 벗어주세요.'), findsOneWidget);
    // 생체/AI 인증으로 오인될 문구가 없어야 한다.
    expect(find.textContaining('생체'), findsNothing);
    expect(find.textContaining('AI'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('3. 촬영을 취소하면 preview 없이 그대로 유지된다', (tester) async {
    final service = await _pump(tester);
    service.nextCapture = null;

    await tester.tap(find.byKey(kCapture));
    await tester.pump();
    await tester.pump();

    expect(service.captureCalls, 1);
    expect(find.byKey(kPreview), findsNothing);
    expect(find.byKey(kSubmit), findsNothing);
    expect(find.byKey(kGuide), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('4~6. preview·동의 전 제출 비활성·다시 촬영', (tester) async {
    final service = await _pump(tester);
    service.nextCapture = _tempPhoto();

    await tester.tap(find.byKey(kCapture));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(kPreview), findsOneWidget);
    expect(find.byKey(kConsent), findsOneWidget);
    expect(
      find.text('인증 사진이 운영 검토에 사용되고 검토 후 삭제되는 것에 동의해요.'),
      findsOneWidget,
    );

    // 5. 동의 전에는 제출 비활성
    expect(
      tester.widget<FilledButton>(find.byKey(kSubmit)).onPressed,
      isNull,
    );
    await _tapVisible(tester, find.byKey(kConsent));
    expect(
      tester.widget<FilledButton>(find.byKey(kSubmit)).onPressed,
      isNotNull,
    );

    // 6. 다시 촬영하면 동의가 초기화된다.
    await _tapVisible(tester, find.byKey(kRetake));
    expect(service.captureCalls, 2);
    expect(
      tester.widget<FilledButton>(find.byKey(kSubmit)).onPressed,
      isNull,
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('7. 제출 중에는 중복 제출되지 않는다', (tester) async {
    final service = _FakeService()..gate = Completer<void>();
    await _pump(tester, service: service);
    service.nextCapture = _tempPhoto();

    await tester.tap(find.byKey(kCapture));
    await tester.pump();
    await tester.pump();
    await _tapVisible(tester, find.byKey(kConsent));

    await _tapVisible(tester, find.byKey(kSubmit));
    expect(service.submitCalls, 1);
    // 제출 진행 중에는 버튼이 비활성이라 다시 눌러도 호출되지 않는다.
    expect(
      tester.widget<FilledButton>(find.byKey(kSubmit)).onPressed,
      isNull,
    );
    await tester.tap(find.byKey(kSubmit), warnIfMissed: false);
    await tester.pump();
    expect(service.submitCalls, 1);

    service.gate!.complete();
    await tester.pump();
    await tester.pump();
    expect(find.text('사진 인증을 요청했어요. 검토 결과를 기다려주세요.'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('8. pending 상태에는 재제출 버튼이 없다', (tester) async {
    await _pump(
      tester,
      service: _FakeService(initial: _request(PhotoVerificationStatus.pending)),
    );

    expect(find.byKey(kPending), findsOneWidget);
    expect(find.text('사진 인증 검토 중'), findsOneWidget);
    expect(find.text('검토가 끝나면 인증 상태가 자동으로 반영돼요.'), findsOneWidget);
    expect(find.byKey(kCapture), findsNothing);
    expect(find.byKey(kSubmit), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('9. approved 상태에는 새 요청 버튼이 없다', (tester) async {
    await _pump(
      tester,
      service: _FakeService(initial: _request(PhotoVerificationStatus.approved)),
    );

    expect(find.byKey(kApproved), findsOneWidget);
    expect(find.text('사진 인증 완료'), findsOneWidget);
    expect(find.text('프로필에 사진 인증 배지가 표시돼요.'), findsOneWidget);
    expect(find.byKey(kCapture), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('10~11. rejected 상태는 사유 label과 재촬영 버튼을 보여준다', (tester) async {
    await _pump(
      tester,
      service: _FakeService(
        initial: _request(
          PhotoVerificationStatus.rejected,
          rejectionReason: 'image_quality',
        ),
      ),
    );

    expect(find.byKey(kRejected), findsOneWidget);
    expect(find.text('사진을 다시 확인해주세요'), findsOneWidget);
    expect(find.text('사진이 흐리거나 너무 어두워요.'), findsOneWidget);
    expect(find.byKey(kCapture), findsOneWidget);
    expect(find.text('다시 촬영하기'), findsOneWidget);
    // 관리자 원문 key를 그대로 노출하지 않는다.
    expect(find.textContaining('image_quality'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('12. 화면 어디에도 storagePath/공개 URL이 표시되지 않는다', (tester) async {
    await _pump(
      tester,
      service: _FakeService(initial: _request(PhotoVerificationStatus.pending)),
    );

    for (final element in find.byType(Text).evaluate()) {
      final data = (element.widget as Text).data ?? '';
      expect(data.contains('photoVerification/'), isFalse);
      expect(data.contains('https://'), isFalse);
      expect(data.contains(kUid), isFalse);
    }

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('13. 작은 화면에서도 overflow가 없다', (tester) async {
    tester.view.physicalSize = const Size(720, 1280);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    final service = await _pump(tester);
    expect(tester.takeException(), isNull);

    service.nextCapture = _tempPhoto();
    await tester.tap(find.byKey(kCapture));
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('제출 실패 시 안전한 고정 문구만 보여준다', (tester) async {
    final service = _FakeService(failMessage: '이미 검토 중인 요청이 있어요.');
    await _pump(tester, service: service);
    service.nextCapture = _tempPhoto();

    await tester.tap(find.byKey(kCapture));
    await tester.pump();
    await tester.pump();
    await _tapVisible(tester, find.byKey(kConsent));
    await _tapVisible(tester, find.byKey(kSubmit));

    expect(find.text('이미 검토 중인 요청이 있어요.'), findsOneWidget);
    expect(find.textContaining('Exception'), findsNothing);
    expect(find.textContaining('photoVerification/'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });
}
