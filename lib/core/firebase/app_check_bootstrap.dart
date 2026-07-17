import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:flutter/foundation.dart';

enum AppCheckBuildMode { debug, profile, release }

enum AppCheckActivationStatus { activated, failed }

class AppCheckProviderPolicy {
  const AppCheckProviderPolicy({
    required this.buildMode,
    required this.androidProviderName,
    required this.appleProviderName,
    required this.androidProvider,
    required this.appleProvider,
  });

  final AppCheckBuildMode buildMode;
  final String androidProviderName;
  final String appleProviderName;
  final AndroidAppCheckProvider androidProvider;
  final AppleAppCheckProvider appleProvider;
}

class AppCheckActivationResult {
  const AppCheckActivationResult({required this.status, required this.policy});

  final AppCheckActivationStatus status;
  final AppCheckProviderPolicy policy;

  bool get isActivated => status == AppCheckActivationStatus.activated;
}

typedef AppCheckActivateCall =
    Future<void> Function({
      required AndroidAppCheckProvider providerAndroid,
      required AppleAppCheckProvider providerApple,
    });

typedef AppCheckLogSink = void Function(String message);

AppCheckBuildMode currentAppCheckBuildMode({
  bool isDebug = kDebugMode,
  bool isProfile = kProfileMode,
  bool isRelease = kReleaseMode,
}) {
  if (isDebug) return AppCheckBuildMode.debug;
  if (isProfile) return AppCheckBuildMode.profile;
  if (isRelease) return AppCheckBuildMode.release;
  return AppCheckBuildMode.release;
}

AppCheckProviderPolicy appCheckProviderPolicyFor(AppCheckBuildMode buildMode) {
  switch (buildMode) {
    case AppCheckBuildMode.debug:
      return const AppCheckProviderPolicy(
        buildMode: AppCheckBuildMode.debug,
        androidProviderName: 'debug',
        appleProviderName: 'debug',
        androidProvider: AndroidDebugProvider(),
        appleProvider: AppleDebugProvider(),
      );
    case AppCheckBuildMode.profile:
      return const AppCheckProviderPolicy(
        buildMode: AppCheckBuildMode.profile,
        androidProviderName: 'playIntegrity',
        appleProviderName: 'appAttestWithDeviceCheckFallback',
        androidProvider: AndroidPlayIntegrityProvider(),
        appleProvider: AppleAppAttestWithDeviceCheckFallbackProvider(),
      );
    case AppCheckBuildMode.release:
      return const AppCheckProviderPolicy(
        buildMode: AppCheckBuildMode.release,
        androidProviderName: 'playIntegrity',
        appleProviderName: 'appAttestWithDeviceCheckFallback',
        androidProvider: AndroidPlayIntegrityProvider(),
        appleProvider: AppleAppAttestWithDeviceCheckFallbackProvider(),
      );
  }
}

Future<AppCheckActivationResult> activateFirebaseAppCheck({
  AppCheckBuildMode? buildMode,
  AppCheckActivateCall? activate,
  AppCheckLogSink? log,
  TargetPlatform? platform,
}) async {
  final policy = appCheckProviderPolicyFor(
    buildMode ?? currentAppCheckBuildMode(),
  );
  final activateCall =
      activate ??
      ({
        required AndroidAppCheckProvider providerAndroid,
        required AppleAppCheckProvider providerApple,
      }) {
        return FirebaseAppCheck.instance.activate(
          providerAndroid: providerAndroid,
          providerApple: providerApple,
        );
      };

  try {
    await activateCall(
      providerAndroid: policy.androidProvider,
      providerApple: policy.appleProvider,
    );
    return AppCheckActivationResult(
      status: AppCheckActivationStatus.activated,
      policy: policy,
    );
  } catch (_) {
    (log ?? debugPrint)(
      'component=app_check category=activation_failed '
      'platform=${_platformLabel(platform)} '
      'buildMode=${policy.buildMode.name}',
    );
    return AppCheckActivationResult(
      status: AppCheckActivationStatus.failed,
      policy: policy,
    );
  }
}

String _platformLabel(TargetPlatform? platform) {
  if (kIsWeb) return 'web';
  return (platform ?? defaultTargetPlatform).name;
}
