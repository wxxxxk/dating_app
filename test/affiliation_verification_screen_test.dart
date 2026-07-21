// AffiliationVerificationScreen은 concrete AffiliationVerificationService를
// 요구하고, 그 생성자는 FirebaseFirestore/FirebaseStorage.instance를 건드린다.
// 기존 테스트와 같은 방식으로 firebase_core 플랫폼만 fake로 바꿔 인스턴스
// 생성을 가능하게 한 뒤, 필요한 메서드만 오버라이드해 화면을 검증한다.
// ignore_for_file: depend_on_referenced_packages
import 'dart:async';
import 'dart:io';

import 'package:dating_app/features/profile/widgets/verification_badge.dart';
import 'package:dating_app/features/verification/affiliation_verification_screen.dart';
import 'package:dating_app/models/affiliation_verification_request.dart';
import 'package:dating_app/models/user_profile.dart';
import 'package:dating_app/services/verification/affiliation_verification_service.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

const String kUid = 'userA';

const Key kInstitution = ValueKey('affiliation-institution-field');
const Key kDetail = ValueKey('affiliation-detail-field');
const Key kCamera = ValueKey('affiliation-camera-button');
const Key kGallery = ValueKey('affiliation-gallery-button');
const Key kConsent = ValueKey('affiliation-consent');
const Key kSubmit = ValueKey('affiliation-submit-button');
const Key kPreview = ValueKey('affiliation-proof-preview');
const Key kPrivacyGuide = ValueKey('affiliation-privacy-guide');
const Key kPending = ValueKey('affiliation-verification-pending');
const Key kApproved = ValueKey('affiliation-verification-approved');
const Key kRejected = ValueKey('affiliation-verification-rejected');

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

/// 제출/선택 호출을 캡처하는 test double.
class _FakeService extends AffiliationVerificationService {
  _FakeService({AffiliationVerificationRequest? initial}) : _latest = initial;

  final AffiliationVerificationRequest? _latest;

  XFile? nextPick;
  int cameraCalls = 0;
  int galleryCalls = 0;
  final List<Map<String, Object?>> submissions = [];
  Completer<void>? gate;

  @override
  Stream<AffiliationVerificationRequest?> watchRequest({
    required String uid,
    required AffiliationVerificationType type,
  }) async* {
    yield _latest;
  }

  @override
  Future<XFile?> pickProofFromCamera() async {
    cameraCalls += 1;
    return nextPick;
  }

  @override
  Future<XFile?> pickProofFromGallery() async {
    galleryCalls += 1;
    return nextPick;
  }

  @override
  Future<void> submitVerification({
    required String uid,
    required AffiliationVerificationType type,
    required String institutionName,
    required String affiliationDetail,
    required String proofType,
    required XFile proof,
  }) async {
    submissions.add({
      'uid': uid,
      'type': affiliationVerificationTypeToString(type),
      'institutionName': institutionName,
      'affiliationDetail': affiliationDetail,
      'proofType': proofType,
    });
    if (gate != null) await gate!.future;
  }
}

XFile _tempProof() {
  final file = File('${Directory.systemTemp.path}/affiliation_proof_test.jpg')
    ..writeAsBytesSync(const [0, 1, 2, 3]);
  return XFile(file.path);
}

AffiliationVerificationRequest _request(
  AffiliationVerificationType type,
  AffiliationVerificationStatus status, {
  String? rejectionReason,
}) {
  return AffiliationVerificationRequest(
    uid: kUid,
    type: type,
    institutionName: 'CVR Lab',
    affiliationDetail: '개발팀',
    proofType: 'employee_id',
    status: status,
    storagePath:
        'affiliationVerification/$kUid/${affiliationVerificationTypeToString(type)}/up1.jpg',
    submittedAt: DateTime(2026, 7, 21, 12),
    updatedAt: DateTime(2026, 7, 21, 12),
    reviewedAt: status == AffiliationVerificationStatus.pending
        ? null
        : DateTime(2026, 7, 21, 13),
    rejectionReason: rejectionReason,
  );
}

/// 스크롤 화면 안의 위젯을 보이게 만든 뒤 탭한다.
Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pump();
  await tester.pump();
}

Future<_FakeService> _pump(
  WidgetTester tester, {
  AffiliationVerificationType type = AffiliationVerificationType.work,
  _FakeService? service,
  bool tallViewport = true,
}) async {
  // 입력 폼이 기본 테스트 뷰포트(600px)보다 길어 스크롤 위치에 따라 탭이
  // 빗나갈 수 있다. 동작 검증에는 폼이 다 보이는 화면을 쓰고, 작은 화면
  // overflow는 별도 테스트에서 확인한다.
  if (tallViewport) {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }
  final s = service ?? _FakeService();
  await tester.pumpWidget(
    MaterialApp(
      home: AffiliationVerificationScreen(uid: kUid, type: type, service: s),
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

  testWidgets('3, 9. 직장 화면은 직장용 증빙 옵션만 보여준다', (tester) async {
    await _pump(tester);

    expect(find.text('직장 인증'), findsWidgets);
    expect(
      find.text('소속을 확인할 수 있는 증빙을 운영자가 직접 확인해요.\n증빙 이미지는 공개되지 않으며 검토 후 삭제됩니다.'),
      findsOneWidget,
    );
    expect(find.byKey(kInstitution), findsOneWidget);
    expect(find.byKey(kDetail), findsOneWidget);
    // 9~10. 직장에는 사원증/재직 증명만, 학생증 옵션은 없다.
    expect(find.text('사원증'), findsOneWidget);
    expect(find.text('재직 증명 자료'), findsOneWidget);
    expect(find.text('학생증'), findsNothing);
    expect(find.text('재학 증명 자료'), findsNothing);

    // 5. 민감정보 가림 안내
    expect(find.byKey(kPrivacyGuide), findsOneWidget);
    expect(
      find.textContaining('주민등록번호, 학생·사원번호, 집 주소, 전화번호, QR 코드와 바코드는 가린 뒤'),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('4, 10. 학교 화면은 학교용 증빙 옵션만 보여준다', (tester) async {
    await _pump(tester, type: AffiliationVerificationType.school);

    expect(find.text('학교 인증'), findsWidgets);
    expect(find.text('학생증'), findsOneWidget);
    expect(find.text('재학 증명 자료'), findsOneWidget);
    expect(find.text('사원증'), findsNothing);
    expect(find.text('재직 증명 자료'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('5~8, 11. 카메라·갤러리·취소·preview·동의 전 제출 비활성', (tester) async {
    final service = await _pump(tester);

    // 7. 취소하면 preview가 생기지 않는다.
    service.nextPick = null;
    await _tapVisible(tester, find.byKey(kCamera));
    expect(service.cameraCalls, 1);
    expect(find.byKey(kPreview), findsNothing);

    // 5. 카메라 선택
    service.nextPick = _tempProof();
    await _tapVisible(tester, find.byKey(kCamera));
    expect(service.cameraCalls, 2);
    expect(find.byKey(kPreview), findsOneWidget);

    // 6. 갤러리 선택
    await _tapVisible(tester, find.byKey(kGallery));
    expect(service.galleryCalls, 1);
    expect(find.byKey(kPreview), findsOneWidget);

    // 11. 기관명·동의 전에는 제출 비활성
    expect(tester.widget<FilledButton>(find.byKey(kSubmit)).onPressed, isNull);
    await tester.enterText(find.byKey(kInstitution), 'CVR Lab');
    await tester.pump();
    expect(
      tester.widget<FilledButton>(find.byKey(kSubmit)).onPressed,
      isNull,
      reason: '동의 전에는 여전히 비활성',
    );
    await _tapVisible(tester, find.byKey(kConsent));
    expect(
      tester.widget<FilledButton>(find.byKey(kSubmit)).onPressed,
      isNotNull,
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('제출은 입력값을 그대로 서비스에 넘기고 중복 제출을 막는다', (tester) async {
    final service = _FakeService()..gate = Completer<void>();
    await _pump(tester, service: service);
    service.nextPick = _tempProof();

    await _tapVisible(tester, find.byKey(kGallery));
    await tester.enterText(find.byKey(kInstitution), '  CVR Lab  ');
    await tester.pump();
    await tester.enterText(find.byKey(kDetail), '개발팀');
    await tester.pump();
    await _tapVisible(tester, find.text('재직 증명 자료'));
    await _tapVisible(tester, find.byKey(kConsent));
    await _tapVisible(tester, find.byKey(kSubmit));

    expect(service.submissions, hasLength(1));
    expect(service.submissions.single['type'], 'work');
    expect(service.submissions.single['institutionName'], '  CVR Lab  ');
    expect(service.submissions.single['proofType'], 'employment_certificate');

    // 제출 중에는 버튼이 비활성이라 다시 눌러도 호출되지 않는다.
    expect(tester.widget<FilledButton>(find.byKey(kSubmit)).onPressed, isNull);
    await tester.tap(find.byKey(kSubmit), warnIfMissed: false);
    await tester.pump();
    expect(service.submissions, hasLength(1));

    service.gate!.complete();
    await tester.pump();
    await tester.pump();
    expect(find.text('인증 요청을 제출했어요. 검토 결과를 기다려주세요.'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('12. pending 상태에는 입력·제출 UI가 없다', (tester) async {
    await _pump(
      tester,
      service: _FakeService(
        initial: _request(
          AffiliationVerificationType.work,
          AffiliationVerificationStatus.pending,
        ),
      ),
    );

    expect(find.byKey(kPending), findsOneWidget);
    expect(find.text('직장 인증 검토 중'), findsOneWidget);
    expect(find.text('검토가 끝나면 인증 상태가 자동으로 반영돼요.'), findsOneWidget);
    expect(find.byKey(kSubmit), findsNothing);
    expect(find.byKey(kCamera), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('13. approved 상태에는 새 요청 UI가 없다', (tester) async {
    await _pump(
      tester,
      type: AffiliationVerificationType.school,
      service: _FakeService(
        initial: _request(
          AffiliationVerificationType.school,
          AffiliationVerificationStatus.approved,
        ),
      ),
    );

    expect(find.byKey(kApproved), findsOneWidget);
    expect(find.text('학교 인증 완료'), findsOneWidget);
    expect(find.text('프로필에 인증 배지가 표시돼요.'), findsOneWidget);
    expect(find.byKey(kSubmit), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('14~15. rejected 상태는 사유 label과 재제출 폼을 보여준다', (tester) async {
    await _pump(
      tester,
      service: _FakeService(
        initial: _request(
          AffiliationVerificationType.work,
          AffiliationVerificationStatus.rejected,
          rejectionReason: 'sensitive_info_visible',
        ),
      ),
    );

    expect(find.byKey(kRejected), findsOneWidget);
    expect(find.text('인증 자료를 다시 확인해주세요'), findsOneWidget);
    expect(find.text('민감한 번호나 QR 코드를 가린 뒤 다시 제출해주세요.'), findsOneWidget);
    expect(find.text('다시 제출하기'), findsOneWidget);
    expect(find.byKey(kCamera), findsOneWidget);
    // 관리자 원문 key를 그대로 노출하지 않는다.
    expect(find.textContaining('sensitive_info_visible'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('화면에 storagePath/공개 URL이 노출되지 않는다', (tester) async {
    await _pump(
      tester,
      service: _FakeService(
        initial: _request(
          AffiliationVerificationType.work,
          AffiliationVerificationStatus.pending,
        ),
      ),
    );

    for (final element in find.byType(Text).evaluate()) {
      final data = (element.widget as Text).data ?? '';
      expect(data.contains('affiliationVerification/'), isFalse);
      expect(data.contains('https://'), isFalse);
      expect(data.contains(kUid), isFalse);
    }

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('20. 작은 화면에서도 overflow가 없다', (tester) async {
    tester.view.physicalSize = const Size(720, 1280);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    final service = await _pump(tester, tallViewport: false);
    expect(tester.takeException(), isNull);

    service.nextPick = _tempProof();
    await _tapVisible(tester, find.byKey(kCamera));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
  });

  // ── 공개 프로필 배지(16~19) ──────────────────────────────────────────────
  Future<void> pumpBadges(
    WidgetTester tester,
    VerificationStatus verifications,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VerificationBadges(verifications: verifications),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('16~17. 승인된 work/school만 공개 배지로 표시된다', (tester) async {
    await pumpBadges(
      tester,
      const VerificationStatus(email: true, work: true),
    );
    expect(find.text('직장 인증'), findsOneWidget);
    expect(find.text('학교 인증'), findsNothing);

    await pumpBadges(tester, const VerificationStatus(school: true));
    expect(find.text('학교 인증'), findsOneWidget);
    expect(find.text('직장 인증'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('18~19. 미인증 배지는 표시되지 않고 기존 배지는 그대로다', (tester) async {
    // request가 pending이어도 verifications가 false면 공개 배지는 없다.
    await pumpBadges(tester, const VerificationStatus());
    expect(find.text('직장 인증'), findsNothing);
    expect(find.text('학교 인증'), findsNothing);
    expect(find.text('이메일 인증'), findsNothing);

    // 19. 기존 이메일·전화·사진 배지 회귀 없음
    await pumpBadges(
      tester,
      const VerificationStatus(email: true, phone: true, photo: true),
    );
    expect(find.text('이메일 인증'), findsOneWidget);
    expect(find.text('전화 인증'), findsOneWidget);
    expect(find.text('사진 인증'), findsOneWidget);
    expect(find.text('직장 인증'), findsNothing);
    expect(find.text('학교 인증'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });
}
