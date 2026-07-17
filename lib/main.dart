import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';

import 'app.dart';
import 'core/firebase/app_check_bootstrap.dart';
// 연결 필요: 이 파일은 `flutterfire configure` 명령으로 생성된다.
//   - 지금 저장소에는 자리표시자(placeholder)만 들어 있어 실제 실행은 되지 않는다.
//   - 본인이 직접 `flutterfire configure`를 실행하면 이 파일이 실제 값으로 덮어쓰인다.
//   - 보안상 firebase_options.dart는 .gitignore에 추가하는 것을 권장한다(파일 내 주석 참고).
import 'firebase_options.dart';

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
}

/// 앱 진입점.
///
/// 순서가 중요하다:
/// 1) ensureInitialized(): runApp 전에 Firebase 같은 네이티브 연동을 쓰려면
///    Flutter 엔진 바인딩을 먼저 초기화해야 한다.
/// 2) Firebase.initializeApp(): 모든 Firebase 기능(Auth/Firestore 등)의 전제.
/// 3) FirebaseAppCheck.activate(): Firebase 서비스 최초 사용 전에 App Check 설정.
/// 4) runApp(): 그 다음에야 위젯 트리를 띄운다.
Future<void> main() async {
  // runApp 이전에 비동기 초기화를 하려면 반드시 호출해야 한다.
  WidgetsFlutterBinding.ensureInitialized();

  await initializeFirebaseForApp();

  runApp(const MyApp());
}

Future<AppCheckActivationResult> initializeFirebaseForApp({
  Future<void> Function()? initializeFirebase,
  Future<AppCheckActivationResult> Function()? activateAppCheck,
  void Function(Future<void> Function(RemoteMessage))?
  registerBackgroundHandler,
}) async {
  // 플랫폼별 설정(DefaultFirebaseOptions.currentPlatform)으로 Firebase 초기화.
  await (initializeFirebase ??
      () => Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      ))();

  final appCheckResult = await (activateAppCheck ?? activateFirebaseAppCheck)();

  (registerBackgroundHandler ?? FirebaseMessaging.onBackgroundMessage)(
    firebaseMessagingBackgroundHandler,
  );
  return appCheckResult;
}
