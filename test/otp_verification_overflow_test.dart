import 'package:dating_app/features/auth/otp_verification_screen.dart';
import 'package:dating_app/services/auth/auth_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// OTP 입력 화면 키보드 Bottom Overflow 회귀 테스트 (Phase 0-D-8).
///
/// 배경: 실기기(SM F700N)에서 OTP 입력칸을 눌러 소프트 키보드가 올라오면
/// body 높이가 줄어 RenderFlex bottom overflow가 발생했다. 화면을
/// SingleChildScrollView로 감싸고 viewInsets.bottom 만큼 하단 패딩을 주어
/// 방어한다.
///
/// 실제 SMS/인증 로직은 호출하지 않는다. AuthService는 FirebaseAuth.instance를
/// 건드리지 않도록 authBadgeSyncCaller를 주입해 구성한다(confirmSmsCode 등은
/// 이 테스트에서 트리거하지 않는다).
void main() {
  AuthService buildAuthService() => AuthService(
    authBadgeSyncCaller: () async => {
      'verifications': {'email': false, 'phone': false, 'photo': false},
    },
  );

  Widget buildSubject() => MaterialApp(
    home: OtpVerificationScreen(
      phoneNumber: '+821012345678',
      verificationId: 'test-verification-id',
      authService: buildAuthService(),
    ),
  );

  // 작은 화면을 가정(360 x 640 논리 픽셀). 키보드 없이도 콘텐츠가 세로로 꽉 찬다.
  void setSmallScreen(WidgetTester tester) {
    tester.view.devicePixelRatio = 3.0;
    tester.view.physicalSize = const Size(1080, 1920);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.reset);
  }

  // 쿨다운(Timer.periodic)이 테스트 종료 시점에 pending으로 남지 않도록
  // 60초를 흘려보내 스스로 취소되게 한다.
  Future<void> drainCooldown(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 61));
  }

  testWidgets('키보드가 올라와 viewInsets가 커도 overflow가 없다', (tester) async {
    setSmallScreen(tester);
    // 소프트 키보드 표시를 시뮬레이션(하단 인셋 = 물리 900px → 논리 300).
    tester.view.viewInsets = const FakeViewPadding(bottom: 900);

    await tester.pumpWidget(buildSubject());
    await tester.pump();

    expect(tester.takeException(), isNull);
    // 입력칸과 확인 버튼이 트리에 존재한다(스크롤로 접근 가능).
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('확인'), findsOneWidget);

    await drainCooldown(tester);
  });

  testWidgets('키보드가 없는 일반 상태도 overflow 없이 렌더링된다', (tester) async {
    setSmallScreen(tester);
    tester.view.viewInsets = const FakeViewPadding();

    await tester.pumpWidget(buildSubject());
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('확인'), findsOneWidget);

    await drainCooldown(tester);
  });

  testWidgets('입력칸에 포커스해 키보드가 뜬 뒤에도 확인 버튼에 스크롤로 접근 가능', (tester) async {
    setSmallScreen(tester);
    tester.view.viewInsets = const FakeViewPadding(bottom: 900);

    await tester.pumpWidget(buildSubject());
    await tester.pump();

    // 입력칸 탭 → 포커스. Scrollable 안이므로 화면 밖으로 밀려도 스크롤로 노출된다.
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(tester.takeException(), isNull);

    await tester.ensureVisible(find.text('확인'));
    expect(tester.takeException(), isNull);

    await drainCooldown(tester);
  });
}
