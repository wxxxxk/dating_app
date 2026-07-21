// ContactAvoidanceScreen은 concrete ContactAvoidanceService를 요구하고, 그
// 생성자는 FirebaseFirestore/FirebaseFunctions.instance를 건드린다. 기존
// 테스트와 같은 방식으로 firebase_core 플랫폼만 fake로 바꿔 인스턴스 생성을
// 가능하게 한 뒤, 필요한 메서드만 오버라이드해 화면을 검증한다.
// ignore_for_file: depend_on_referenced_packages
import 'dart:async';

import 'package:dating_app/features/privacy/contact_avoidance_screen.dart';
import 'package:dating_app/models/contact_avoidance_settings.dart';
import 'package:dating_app/services/privacy/contact_avoidance_service.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

const String kUid = 'userA';

const Key kConsent = ValueKey('contact-avoidance-consent');
const Key kSync = ValueKey('contact-avoidance-sync-button');
const Key kResync = ValueKey('contact-avoidance-resync-button');
const Key kDisable = ValueKey('contact-avoidance-disable-button');
const Key kActive = ValueKey('contact-avoidance-active');
const Key kSummary = ValueKey('contact-avoidance-summary');
const Key kPhoneRequired = ValueKey('contact-avoidance-phone-required');
const Key kVerifyPhone = ValueKey('contact-avoidance-verify-phone-button');
const Key kPermissionDenied = ValueKey('contact-avoidance-permission-denied');
const Key kPrivacyGuide = ValueKey('contact-avoidance-privacy-guide');

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

/// 동기화 호출을 캡처하는 test double.
class _FakeService extends ContactAvoidanceService {
  _FakeService({ContactAvoidanceSettings? initial, this.error})
    : _controller = StreamController<ContactAvoidanceSettings?>.broadcast(),
      _latest = initial;

  final StreamController<ContactAvoidanceSettings?> _controller;
  final ContactAvoidanceSettings? _latest;
  final ContactAvoidanceError? error;

  int syncCalls = 0;
  int disableCalls = 0;
  Completer<void>? gate;

  void emit(ContactAvoidanceSettings settings) => _controller.add(settings);

  @override
  Stream<ContactAvoidanceSettings?> watchSettings(String uid) async* {
    yield _latest;
    yield* _controller.stream;
  }

  @override
  Future<ContactAvoidanceSyncResult> syncContacts({required String uid}) async {
    syncCalls += 1;
    if (gate != null) await gate!.future;
    if (error != null) throw error!;
    return const ContactAvoidanceSyncResult(
      enabled: true,
      contactCount: 120,
      hiddenCount: 3,
    );
  }

  @override
  Future<ContactAvoidanceSyncResult> disable({required String uid}) async {
    disableCalls += 1;
    if (error != null) throw error!;
    return const ContactAvoidanceSyncResult(
      enabled: false,
      contactCount: 0,
      hiddenCount: 0,
    );
  }
}

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
  bool phoneVerified = true,
  VoidCallback? onVerifyPhone,
  bool tallViewport = true,
}) async {
  if (tallViewport) {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }
  final s = service ?? _FakeService();
  await tester.pumpWidget(
    MaterialApp(
      home: ContactAvoidanceScreen(
        uid: kUid,
        service: s,
        phoneVerified: phoneVerified,
        onVerifyPhone: onVerifyPhone,
      ),
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

  testWidgets('2. 전화 미인증이면 선행 안내와 인증 버튼만 보여준다', (tester) async {
    var verifyTaps = 0;
    final service = await _pump(
      tester,
      phoneVerified: false,
      onVerifyPhone: () => verifyTaps += 1,
    );

    expect(find.byKey(kPhoneRequired), findsOneWidget);
    expect(find.text('지인 피하기를 사용하려면 먼저 전화 인증이 필요해요.'), findsOneWidget);
    expect(find.byKey(kSync), findsNothing);
    expect(find.byKey(kConsent), findsNothing);

    await _tapVisible(tester, find.byKey(kVerifyPhone));
    expect(verifyTaps, 1);
    expect(service.syncCalls, 0);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('3. 동의 전에는 동기화 버튼이 비활성이다', (tester) async {
    final service = await _pump(tester);

    expect(find.byKey(kPrivacyGuide), findsOneWidget);
    expect(
      find.textContaining('연락처 이름과 전화번호 원문은 서버에 저장되지 않아요'),
      findsOneWidget,
    );
    expect(find.text('연락처 동기화하고 지인 숨기기'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(kSync)).onPressed, isNull);
    expect(service.syncCalls, 0);

    await _tapVisible(tester, find.byKey(kConsent));
    expect(tester.widget<FilledButton>(find.byKey(kSync)).onPressed, isNotNull);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('4. 연락처 권한 거부는 안내로 처리하고 crash하지 않는다', (tester) async {
    final service = _FakeService(error: const ContactPermissionDeniedError());
    await _pump(tester, service: service);

    await _tapVisible(tester, find.byKey(kConsent));
    await _tapVisible(tester, find.byKey(kSync));

    expect(service.syncCalls, 1);
    expect(find.byKey(kPermissionDenied), findsOneWidget);
    expect(find.text('기기 설정에서 연락처 접근을 허용한 뒤 다시 시도해주세요.'), findsOneWidget);
    // 재시도 경로가 남아 있어야 한다.
    expect(find.text('다시 시도'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('5. 동기화 중에는 중복 실행되지 않는다', (tester) async {
    final service = _FakeService()..gate = Completer<void>();
    await _pump(tester, service: service);

    await _tapVisible(tester, find.byKey(kConsent));
    await _tapVisible(tester, find.byKey(kSync));
    expect(service.syncCalls, 1);
    expect(tester.widget<FilledButton>(find.byKey(kSync)).onPressed, isNull);

    await tester.tap(find.byKey(kSync), warnIfMissed: false);
    await tester.pump();
    expect(service.syncCalls, 1);

    service.gate!.complete();
    await tester.pump();
    await tester.pump();
    expect(find.text('연락처 120개를 동기화했어요.'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('6~8, 11~12. 활성 상태는 요약과 안내 문구를 보여준다', (tester) async {
    await _pump(
      tester,
      service: _FakeService(
        initial: ContactAvoidanceSettings(
          enabled: true,
          contactCount: 342,
          hiddenCount: 5,
          syncedAt: DateTime(2026, 7, 21, 14, 5),
        ),
      ),
    );

    expect(find.byKey(kActive), findsOneWidget);
    expect(find.text('지인 피하기 사용 중'), findsOneWidget);
    expect(find.byKey(kSummary), findsOneWidget);
    // 7~8. 개수 표시
    expect(find.text('342개'), findsOneWidget);
    expect(find.text('5명'), findsOneWidget);
    expect(find.text('2026.07.21 14:05'), findsOneWidget);
    // 11~12. 기존 매치 유지 / 상대 소유 pair 유지 안내
    expect(find.textContaining('기존 매칭과 대화는 계속 유지돼요.'), findsOneWidget);
    expect(
      find.textContaining('상대방이 나를 연락처에 저장해 지인 피하기를 사용 중이면'),
      findsOneWidget,
    );
    // 활성 상태에서는 최초 동의 UI가 아니라 재동기화/끄기가 보인다.
    expect(find.byKey(kResync), findsOneWidget);
    expect(find.byKey(kDisable), findsOneWidget);
    expect(find.byKey(kConsent), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('9. 재동기화는 연락처를 다시 읽어 동기화한다', (tester) async {
    final service = _FakeService(
      initial: const ContactAvoidanceSettings(
        enabled: true,
        contactCount: 10,
        hiddenCount: 1,
      ),
    );
    await _pump(tester, service: service);

    await _tapVisible(tester, find.byKey(kResync));
    expect(service.syncCalls, 1);
    expect(find.text('연락처 120개를 동기화했어요.'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('10. 끄기는 확인 후에만 실행된다', (tester) async {
    final service = _FakeService(
      initial: const ContactAvoidanceSettings(
        enabled: true,
        contactCount: 10,
        hiddenCount: 1,
      ),
    );
    await _pump(tester, service: service);

    await _tapVisible(tester, find.byKey(kDisable));
    expect(find.text('지인 피하기를 끌까요?'), findsOneWidget);
    expect(find.textContaining('기존 매칭과 대화는 그대로 유지됩니다.'), findsOneWidget);

    // 취소하면 아무 일도 없다.
    await _tapVisible(tester, find.text('취소'));
    expect(service.disableCalls, 0);

    await _tapVisible(tester, find.byKey(kDisable));
    await _tapVisible(tester, find.text('끄기'));
    expect(service.disableCalls, 1);
    expect(find.text('지인 피하기를 껐어요.'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('13. 작은 화면에서도 overflow가 없다', (tester) async {
    tester.view.physicalSize = const Size(720, 1280);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    await _pump(tester, tallViewport: false);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());

    await _pump(
      tester,
      tallViewport: false,
      service: _FakeService(
        initial: ContactAvoidanceSettings(
          enabled: true,
          contactCount: 1999,
          hiddenCount: 42,
          syncedAt: DateTime(2026, 7, 21, 14, 5),
        ),
      ),
    );
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('서버 오류는 고정 문구로만 안내한다', (tester) async {
    final service = _FakeService(
      error: const ContactAvoidanceError('잠시 후 다시 동기화해주세요.'),
    );
    await _pump(tester, service: service);

    await _tapVisible(tester, find.byKey(kConsent));
    await _tapVisible(tester, find.byKey(kSync));

    expect(find.text('잠시 후 다시 동기화해주세요.'), findsOneWidget);
    expect(find.textContaining('Exception'), findsNothing);
    expect(find.textContaining('firebase'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });
}
