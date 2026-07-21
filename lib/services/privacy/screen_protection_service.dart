import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 화면 캡처 관련 네이티브 이벤트 종류(Phase 3-5).
enum ScreenProtectionEventType {
  /// iOS에서 스크린샷이 **촬영된 뒤** 전달된다(사전 차단이 아니다).
  screenshotTaken,

  /// 화면 녹화·미러링이 시작됐다.
  captureStarted,

  /// 화면 녹화·미러링이 끝났다.
  captureStopped,
}

/// 네이티브에서 올라온 화면 보호 이벤트.
///
/// **화면 내용·현재 route·보고 있던 UID 같은 정보는 담지 않는다.**
class ScreenProtectionEvent {
  final ScreenProtectionEventType type;

  const ScreenProtectionEvent(this.type);
}

/// 로그인 사용자의 화면을 OS 공개 API 범위에서 보호한다.
///
/// - Android: `FLAG_SECURE`로 스크린샷·화면 녹화를 차단한다.
/// - iOS: 녹화/미러링 중 privacy overlay를 덮고, 스크린샷은 촬영 후 감지해
///   안내만 한다(단일 스크린샷 자체는 공개 API로 막을 수 없다).
abstract interface class ScreenProtectionService {
  Stream<ScreenProtectionEvent> get events;

  Future<void> setEnabled(bool enabled);

  Future<bool> get isCaptureActive;
}

/// MethodChannel 기반 프로덕션 구현.
///
/// 네이티브 호출 실패는 삼켜서 로그인·앱 시작을 막지 않는다. 지원하지 않는
/// 플랫폼(web/desktop)에서는 안전한 no-op으로 동작한다.
class MethodChannelScreenProtectionService implements ScreenProtectionService {
  MethodChannelScreenProtectionService({
    MethodChannel? channel,
    TargetPlatform? platformOverride,
    bool? isSupportedOverride,
  }) : _channel = channel ?? const MethodChannel(channelName),
       _isSupported =
           isSupportedOverride ??
           _defaultIsSupported(platformOverride ?? defaultTargetPlatform) {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  static const String channelName = 'com.cvrlab.dating_app/screen_protection';

  static const String methodSetEnabled = 'setEnabled';
  static const String methodGetCaptureState = 'getCaptureState';
  static const String callbackScreenshotTaken = 'onScreenshotTaken';
  static const String callbackCaptureChanged = 'onCaptureChanged';

  final MethodChannel _channel;
  final bool _isSupported;
  final _controller = StreamController<ScreenProtectionEvent>.broadcast();

  /// 마지막으로 네이티브에 보낸 값. 같은 값이면 다시 호출하지 않는다.
  bool? _lastEnabled;

  static bool _defaultIsSupported(TargetPlatform platform) {
    if (kIsWeb) return false;
    return platform == TargetPlatform.android || platform == TargetPlatform.iOS;
  }

  @override
  Stream<ScreenProtectionEvent> get events => _controller.stream;

  @override
  Future<void> setEnabled(bool enabled) async {
    if (!_isSupported) return;
    if (_lastEnabled == enabled) return;
    // 실패해도 다음 시도가 가능하도록 성공했을 때만 상태를 기록한다.
    try {
      await _channel.invokeMethod<void>(methodSetEnabled, {'enabled': enabled});
      _lastEnabled = enabled;
    } catch (e) {
      // 화면 이름·내용은 남기지 않고 실패 사실만 남긴다.
      _debugLog('[ScreenProtection] setEnabled 실패 code=${e.runtimeType}');
    }
  }

  @override
  Future<bool> get isCaptureActive async {
    if (!_isSupported) return false;
    try {
      final result = await _channel.invokeMethod<bool>(methodGetCaptureState);
      return result == true;
    } catch (e) {
      _debugLog('[ScreenProtection] getCaptureState 실패 code=${e.runtimeType}');
      return false;
    }
  }

  /// 네이티브 → Flutter 콜백. 알 수 없는 method/인자는 조용히 무시한다.
  Future<void> _handleNativeCall(MethodCall call) async {
    final event = parseNativeCall(call.method, call.arguments);
    if (event == null) return;
    if (_controller.isClosed) return;
    _controller.add(event);
  }

  /// 네이티브 콜백 → 이벤트 변환(순수 함수). malformed 입력은 null.
  static ScreenProtectionEvent? parseNativeCall(
    String method,
    Object? arguments,
  ) {
    switch (method) {
      case callbackScreenshotTaken:
        return const ScreenProtectionEvent(
          ScreenProtectionEventType.screenshotTaken,
        );
      case callbackCaptureChanged:
        final captured = arguments is bool
            ? arguments
            : (arguments is Map && arguments['captured'] is bool
                  ? arguments['captured'] as bool
                  : null);
        if (captured == null) return null;
        return ScreenProtectionEvent(
          captured
              ? ScreenProtectionEventType.captureStarted
              : ScreenProtectionEventType.captureStopped,
        );
      default:
        return null;
    }
  }

  /// 앱 종료·테스트 정리용. handler와 stream을 함께 해제한다.
  Future<void> dispose() async {
    _channel.setMethodCallHandler(null);
    await _controller.close();
  }

  void _debugLog(String message) {
    if (kDebugMode) debugPrint(message);
  }
}
