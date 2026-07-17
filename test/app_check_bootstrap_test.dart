import 'package:dating_app/core/firebase/app_check_bootstrap.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dating_app/main.dart' as app_main;

void main() {
  group('App Check provider policy', () {
    test('debug Android provider 선택 = debug', () {
      final policy = appCheckProviderPolicyFor(AppCheckBuildMode.debug);

      expect(policy.androidProviderName, 'debug');
      expect(policy.androidProvider, isA<AndroidDebugProvider>());
    });

    test('release/profile Android provider 선택 = playIntegrity', () {
      final profile = appCheckProviderPolicyFor(AppCheckBuildMode.profile);
      final release = appCheckProviderPolicyFor(AppCheckBuildMode.release);

      expect(profile.androidProviderName, 'playIntegrity');
      expect(profile.androidProvider, isA<AndroidPlayIntegrityProvider>());
      expect(release.androidProviderName, 'playIntegrity');
      expect(release.androidProvider, isA<AndroidPlayIntegrityProvider>());
    });

    test('debug Apple provider 선택 = debug', () {
      final policy = appCheckProviderPolicyFor(AppCheckBuildMode.debug);

      expect(policy.appleProviderName, 'debug');
      expect(policy.appleProvider, isA<AppleDebugProvider>());
    });

    test('release Apple provider는 debug가 아님', () {
      final policy = appCheckProviderPolicyFor(AppCheckBuildMode.release);

      expect(policy.appleProviderName, 'appAttestWithDeviceCheckFallback');
      expect(
        policy.appleProvider,
        isA<AppleAppAttestWithDeviceCheckFallbackProvider>(),
      );
      expect(policy.appleProvider, isNot(isA<AppleDebugProvider>()));
    });

    test('컴파일 모드 선택은 debug/profile/release 순서로 결정된다', () {
      expect(
        currentAppCheckBuildMode(
          isDebug: true,
          isProfile: false,
          isRelease: false,
        ),
        AppCheckBuildMode.debug,
      );
      expect(
        currentAppCheckBuildMode(
          isDebug: false,
          isProfile: true,
          isRelease: false,
        ),
        AppCheckBuildMode.profile,
      );
      expect(
        currentAppCheckBuildMode(
          isDebug: false,
          isProfile: false,
          isRelease: true,
        ),
        AppCheckBuildMode.release,
      );
    });
  });

  group('App Check activation', () {
    test('Firebase 초기화 뒤 App Check 활성화, 그 뒤 앱 실행 준비', () async {
      final events = <String>[];

      await app_main.initializeFirebaseForApp(
        initializeFirebase: () async => events.add('firebase'),
        activateAppCheck: () async {
          events.add('app_check');
          return AppCheckActivationResult(
            status: AppCheckActivationStatus.activated,
            policy: appCheckProviderPolicyFor(AppCheckBuildMode.debug),
          );
        },
        registerBackgroundHandler:
            (Future<void> Function(RemoteMessage message) handler) {
              events.add('messaging');
            },
      );
      events.add('run_app');

      expect(events, ['firebase', 'app_check', 'messaging', 'run_app']);
    });

    test('App Check 활성화 뒤 앱 실행 가능 상태를 반환한다', () async {
      final result = await activateFirebaseAppCheck(
        buildMode: AppCheckBuildMode.debug,
        activate: ({required providerAndroid, required providerApple}) async {},
        log: (_) {},
      );

      expect(result.isActivated, isTrue);
      expect(result.policy.androidProviderName, 'debug');
    });

    test('activate 실패 시 앱 시작 가능하고 안전 로그만 남긴다', () async {
      final logs = <String>[];

      final result = await activateFirebaseAppCheck(
        buildMode: AppCheckBuildMode.release,
        platform: TargetPlatform.android,
        activate: ({required providerAndroid, required providerApple}) async {
          throw StateError('raw-token-or-secret-message');
        },
        log: logs.add,
      );

      expect(result.isActivated, isFalse);
      expect(logs, hasLength(1));
      expect(logs.single, contains('component=app_check'));
      expect(logs.single, contains('category=activation_failed'));
      expect(logs.single, contains('platform=android'));
      expect(logs.single, contains('buildMode=release'));
      expect(logs.single, isNot(contains('raw-token-or-secret-message')));
      expect(logs.single, isNot(contains('StateError')));
      expect(logs.single, isNot(contains('token')));
      expect(logs.single, isNot(contains('stack')));
    });
  });
}
