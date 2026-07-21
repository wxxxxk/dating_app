import 'package:dating_app/services/privacy/screen_protection_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Phase 3-5 — 화면 캡처 보호 서비스 테스트.
///
/// MethodChannel을 mock으로 가로채 네이티브 호출 계약과 콜백 파싱을 확인한다.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(
    MethodChannelScreenProtectionService.channelName,
  );
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> calls;
  late MethodChannelScreenProtectionService service;

  void mockHandler({bool captureState = false, bool throwError = false}) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (throwError) {
        throw PlatformException(code: 'native_failure', message: 'raw detail');
      }
      switch (call.method) {
        case MethodChannelScreenProtectionService.methodSetEnabled:
          return {'enabled': (call.arguments as Map)['enabled']};
        case MethodChannelScreenProtectionService.methodGetCaptureState:
          return captureState;
        default:
          return null;
      }
    });
  }

  setUp(() {
    calls = [];
    service = MethodChannelScreenProtectionService(
      platformOverride: TargetPlatform.android,
    );
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    await service.dispose();
  });

  group('1~3. setEnabled', () {
    test('1~2. true/false를 네이티브에 전달한다', () async {
      mockHandler();

      await service.setEnabled(true);
      await service.setEnabled(false);

      expect(calls.map((c) => c.method), [
        MethodChannelScreenProtectionService.methodSetEnabled,
        MethodChannelScreenProtectionService.methodSetEnabled,
      ]);
      expect(calls.first.arguments, {'enabled': true});
      expect(calls.last.arguments, {'enabled': false});
    });

    test('3. 같은 값을 반복하면 네이티브를 다시 호출하지 않는다', () async {
      mockHandler();

      await service.setEnabled(true);
      await service.setEnabled(true);
      await service.setEnabled(true);
      expect(calls, hasLength(1));

      await service.setEnabled(false);
      expect(calls, hasLength(2));
      await service.setEnabled(false);
      expect(calls, hasLength(2));
    });

    test('9. 네이티브 오류가 예외로 새어나가지 않는다', () async {
      mockHandler(throwError: true);

      await expectLater(service.setEnabled(true), completes);
      // 실패했으므로 상태를 기억하지 않고 다음 호출에서 다시 시도한다.
      await service.setEnabled(true);
      expect(calls, hasLength(2));
    });
  });

  group('8. getCaptureState', () {
    test('네이티브 값을 그대로 돌려준다', () async {
      mockHandler(captureState: true);
      expect(await service.isCaptureActive, isTrue);

      calls.clear();
      mockHandler();
      expect(await service.isCaptureActive, isFalse);
      expect(
        calls.single.method,
        MethodChannelScreenProtectionService.methodGetCaptureState,
      );
    });

    test('오류 시 false로 폴백한다', () async {
      mockHandler(throwError: true);
      expect(await service.isCaptureActive, isFalse);
    });
  });

  group('4~7. 네이티브 콜백 파싱', () {
    test('5. screenshot 이벤트', () {
      final event = MethodChannelScreenProtectionService.parseNativeCall(
        MethodChannelScreenProtectionService.callbackScreenshotTaken,
        null,
      );
      expect(event?.type, ScreenProtectionEventType.screenshotTaken);
    });

    test('6~7. capture 시작/종료 이벤트', () {
      expect(
        MethodChannelScreenProtectionService.parseNativeCall(
          MethodChannelScreenProtectionService.callbackCaptureChanged,
          true,
        )?.type,
        ScreenProtectionEventType.captureStarted,
      );
      expect(
        MethodChannelScreenProtectionService.parseNativeCall(
          MethodChannelScreenProtectionService.callbackCaptureChanged,
          false,
        )?.type,
        ScreenProtectionEventType.captureStopped,
      );
      // map 형태 인자도 허용한다.
      expect(
        MethodChannelScreenProtectionService.parseNativeCall(
          MethodChannelScreenProtectionService.callbackCaptureChanged,
          {'captured': true},
        )?.type,
        ScreenProtectionEventType.captureStarted,
      );
    });

    test('4. malformed 이벤트는 무시한다', () {
      for (final args in <Object?>[null, 'yes', 1, <String, Object?>{}]) {
        expect(
          MethodChannelScreenProtectionService.parseNativeCall(
            MethodChannelScreenProtectionService.callbackCaptureChanged,
            args,
          ),
          isNull,
          reason: '$args',
        );
      }
      expect(
        MethodChannelScreenProtectionService.parseNativeCall('unknown', null),
        isNull,
      );
    });

    test('네이티브 콜백이 event stream으로 전달된다', () async {
      final received = <ScreenProtectionEventType>[];
      final sub = service.events.listen((e) => received.add(e.type));
      addTearDown(sub.cancel);

      Future<void> send(String method, Object? arguments) {
        return messenger.handlePlatformMessage(
          MethodChannelScreenProtectionService.channelName,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall(method, arguments),
          ),
          (_) {},
        );
      }

      await send(
        MethodChannelScreenProtectionService.callbackScreenshotTaken,
        null,
      );
      await send(
        MethodChannelScreenProtectionService.callbackCaptureChanged,
        true,
      );
      await send(
        MethodChannelScreenProtectionService.callbackCaptureChanged,
        false,
      );
      // malformed는 흘리지 않는다.
      await send(
        MethodChannelScreenProtectionService.callbackCaptureChanged,
        'nope',
      );
      await Future<void>.delayed(Duration.zero);

      expect(received, [
        ScreenProtectionEventType.screenshotTaken,
        ScreenProtectionEventType.captureStarted,
        ScreenProtectionEventType.captureStopped,
      ]);
    });
  });

  group('10. 미지원 플랫폼', () {
    test('네이티브를 호출하지 않고 안전하게 no-op 한다', () async {
      final unsupported = MethodChannelScreenProtectionService(
        platformOverride: TargetPlatform.macOS,
      );
      addTearDown(unsupported.dispose);
      mockHandler();

      await unsupported.setEnabled(true);
      expect(await unsupported.isCaptureActive, isFalse);
      expect(calls, isEmpty);
    });
  });
}
