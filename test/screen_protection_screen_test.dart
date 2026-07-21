import 'dart:async';

import 'package:dating_app/features/privacy/screen_protection_widgets.dart';
import 'package:dating_app/services/privacy/screen_protection_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Phase 3-5 — coordinator·안내 UI 테스트.
class _FakeService implements ScreenProtectionService {
  _FakeService({this.failSetEnabled = false});

  final bool failSetEnabled;
  final _controller = StreamController<ScreenProtectionEvent>.broadcast();
  final List<bool> setEnabledCalls = [];
  bool captureState = false;

  void emit(ScreenProtectionEventType type) =>
      _controller.add(ScreenProtectionEvent(type));

  @override
  Stream<ScreenProtectionEvent> get events => _controller.stream;

  @override
  Future<void> setEnabled(bool enabled) async {
    setEnabledCalls.add(enabled);
    if (failSetEnabled) throw StateError('native failure');
  }

  @override
  Future<bool> get isCaptureActive async => captureState;

  Future<void> dispose() => _controller.close();
}

Future<void> _pumpCoordinator(
  WidgetTester tester, {
  required _FakeService service,
  required bool loggedIn,
  Widget? child,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: ScreenProtectionCoordinator(
        service: service,
        loggedIn: loggedIn,
        child: child ?? const Scaffold(body: Text('앱 화면')),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('Auth coordinator', () {
    testWidgets('1~2. 로그인 상태에 따라 보호를 켜고 끈다', (tester) async {
      final service = _FakeService();
      addTearDown(service.dispose);

      await _pumpCoordinator(tester, service: service, loggedIn: true);
      expect(service.setEnabledCalls, [true]);

      // 로그아웃으로 바뀌면 해제한다.
      await tester.pumpWidget(
        MaterialApp(
          home: ScreenProtectionCoordinator(
            service: service,
            loggedIn: false,
            child: const Scaffold(body: Text('앱 화면')),
          ),
        ),
      );
      await tester.pump();
      expect(service.setEnabledCalls, [true, false]);
    });

    testWidgets('3. 같은 auth 상태가 반복돼도 중복 호출하지 않는다', (tester) async {
      final service = _FakeService();
      addTearDown(service.dispose);

      await _pumpCoordinator(tester, service: service, loggedIn: true);
      for (var i = 0; i < 3; i++) {
        await _pumpCoordinator(tester, service: service, loggedIn: true);
      }

      expect(service.setEnabledCalls, [true]);
    });

    testWidgets('4. dispose 후 이벤트는 무시된다', (tester) async {
      final service = _FakeService();
      addTearDown(service.dispose);

      await _pumpCoordinator(tester, service: service, loggedIn: true);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();

      service.emit(ScreenProtectionEventType.screenshotTaken);
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.textContaining('스크린샷'), findsNothing);
    });

    testWidgets('5. setEnabled 실패해도 화면은 정상 표시된다', (tester) async {
      final service = _FakeService(failSetEnabled: true);
      addTearDown(service.dispose);

      await _pumpCoordinator(tester, service: service, loggedIn: true);
      await tester.pump();

      expect(find.text('앱 화면'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('6~7. 스크린샷 안내는 로그인 상태에서만, 2초 내 중복 없이 표시된다', (
      tester,
    ) async {
      final service = _FakeService();
      addTearDown(service.dispose);

      // 6. 로그인 전에는 표시하지 않는다.
      await _pumpCoordinator(tester, service: service, loggedIn: false);
      service.emit(ScreenProtectionEventType.screenshotTaken);
      await tester.pump();
      await tester.pump();
      expect(find.byType(SnackBar), findsNothing);

      // 로그인 상태에서는 표시한다.
      await _pumpCoordinator(tester, service: service, loggedIn: true);
      service.emit(ScreenProtectionEventType.screenshotTaken);
      await tester.pump();
      await tester.pump();
      expect(
        find.text('스크린샷이 감지됐어요. 상대방의 개인정보를 공유하지 말아주세요.'),
        findsOneWidget,
      );

      // 7. 2초 안에 다시 오면 중복 표시하지 않는다.
      service.emit(ScreenProtectionEventType.screenshotTaken);
      await tester.pump();
      await tester.pump();
      expect(find.byType(SnackBar), findsOneWidget);

      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('8. capture 이벤트는 보조 상태만 바꾸고 UI를 바꾸지 않는다', (tester) async {
      final service = _FakeService();
      addTearDown(service.dispose);

      await _pumpCoordinator(tester, service: service, loggedIn: true);
      final state = tester.state(find.byType(ScreenProtectionCoordinator));

      service.emit(ScreenProtectionEventType.captureStarted);
      await tester.pump();
      expect((state as dynamic).captureActive, isTrue);
      // 안내 dialog/SnackBar를 반복 표시하지 않는다.
      expect(find.byType(SnackBar), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('앱 화면'), findsOneWidget);

      service.emit(ScreenProtectionEventType.captureStopped);
      await tester.pump();
      expect((state as dynamic).captureActive, isFalse);
      // 보호 상태 변경 외의 네이티브 호출은 없다.
      expect(service.setEnabledCalls, [true]);
    });
  });

  group('안내 UI', () {
    Future<void> pumpRow(
      WidgetTester tester, {
      TargetPlatform platform = TargetPlatform.android,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ScreenProtectionInfoRow(
                onTap: () => showScreenProtectionInfoSheet(
                  context,
                  platformOverride: platform,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('1. 화면 캡처 보호 행이 표시된다', (tester) async {
      await pumpRow(tester);

      expect(
        find.byKey(const ValueKey('screen-protection-info-row')),
        findsOneWidget,
      );
      expect(find.text('화면 캡처 보호'), findsOneWidget);
      expect(find.text('사용 중'), findsOneWidget);
      expect(find.text('민감한 프로필과 대화 화면을 보호해요'), findsOneWidget);
      // 토글은 제공하지 않는다.
      expect(find.byType(Switch), findsNothing);
    });

    testWidgets('2~3. Android 안내 시트', (tester) async {
      await pumpRow(tester, platform: TargetPlatform.android);
      await tester.tap(find.byKey(const ValueKey('screen-protection-info-row')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('screen-protection-info-sheet')),
        findsOneWidget,
      );
      expect(
        find.text('프로필 사진과 대화 내용에는 다른 사람의 개인정보가 포함될 수 있어요.\n앱 밖으로 저장하거나 공유하지 말아주세요.'),
        findsOneWidget,
      );
      expect(find.textContaining('스크린샷과 화면 녹화를 차단해요'), findsOneWidget);

      await tester.tap(find.text('확인했어요'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('screen-protection-info-sheet')),
        findsNothing,
      );
    });

    testWidgets('4~5. iOS 안내는 완전 차단이라고 말하지 않는다', (tester) async {
      await pumpRow(tester, platform: TargetPlatform.iOS);
      await tester.tap(find.byKey(const ValueKey('screen-protection-info-row')));
      await tester.pumpAndSettle();

      expect(find.textContaining('화면 녹화·미러링 중 앱 내용을 가리고'), findsOneWidget);
      expect(
        find.textContaining('단일 스크린샷 촬영 자체를 완전히 막을 수 없어요'),
        findsOneWidget,
      );
      // 과장 표현이 없어야 한다.
      expect(find.textContaining('스크린샷을 차단'), findsNothing);
      expect(find.textContaining('완전히 차단'), findsNothing);
    });

    testWidgets('기타 플랫폼 안내', (tester) async {
      await pumpRow(tester, platform: TargetPlatform.macOS);
      await tester.tap(find.byKey(const ValueKey('screen-protection-info-row')));
      await tester.pumpAndSettle();

      expect(
        find.text('현재 기기에서는 운영체제가 지원하는 범위 안에서 화면을 보호해요.'),
        findsOneWidget,
      );
    });

    testWidgets('9. 작은 화면에서도 overflow가 없다', (tester) async {
      tester.view.physicalSize = const Size(720, 1280);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);

      await pumpRow(tester, platform: TargetPlatform.iOS);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const ValueKey('screen-protection-info-row')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
