// ignore_for_file: depend_on_referenced_packages

import 'dart:async';
import 'dart:io';

import 'package:dating_app/features/onboarding/onboarding_screen.dart';
import 'package:dating_app/models/user_profile.dart';
import 'package:dating_app/services/auth/auth_service.dart';
import 'package:dating_app/services/database/firestore_service.dart';
import 'package:dating_app/services/storage/profile_photo_processor.dart';
import 'package:dating_app/services/storage/storage_service.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

// 온보딩 첫 단계(사진 등록)의 dead-end 제거 회귀 테스트.
//
// 재현 배경: 프로필 조회가 실패하면 기존 유저가 이 화면으로 떨어졌는데,
// step 0에는 뒤로가기도 로그아웃도 없어서 로그인 화면으로 돌아갈 수단이
// 전혀 없었다.

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

class _FakeAuthService extends AuthService {
  _FakeAuthService()
    : super(authBadgeSyncCaller: () async => <String, Object?>{});

  @override
  Future<void> reloadUser() async {}

  @override
  bool get hasAnyAuthVerificationSignal => false;
}

class _FakeStorageService extends StorageService {
  @override
  Future<List<String>> uploadMultipleProfilePhotos({
    required String uid,
    required ProcessedProfilePhoto mainPhoto,
    List<ProcessedProfilePhoto> subPhotos = const [],
    void Function(double progress)? onProgress,
  }) async => const ['https://example.com/main.jpg'];
}

class _FakeFirestoreService extends FirestoreService {
  int createCalls = 0;

  @override
  Future<void> createUserProfile(UserProfile profile) async {
    createCalls += 1;
  }
}

Widget _host({
  required AuthService authService,
  required FirestoreService firestoreService,
  required StorageService storageService,
  Future<void> Function()? onSignOut,
  String? Function()? currentAuthUid,
  VoidCallback? onCompleted,
}) {
  return MaterialApp(
    home: OnboardingScreen(
      uid: 'me',
      authService: authService,
      firestoreService: firestoreService,
      storageService: storageService,
      onSignOut: onSignOut,
      currentAuthUid: currentAuthUid,
      onCompleted: onCompleted ?? () {},
    ),
  );
}

void main() {
  setUpAll(() {
    FirebasePlatform.instance = _FakeFirebasePlatform();
  });

  testWidgets('16. step 0에 로그아웃 버튼이 보인다', (tester) async {
    await tester.pumpWidget(
      _host(
        authService: _FakeAuthService(),
        firestoreService: _FakeFirestoreService(),
        storageService: _FakeStorageService(),
        onSignOut: () async {},
      ),
    );

    expect(find.byKey(const Key('onboarding-sign-out-button')), findsOneWidget);
    // step 0에는 뒤로가기가 없다 — 그래서 로그아웃이 유일한 출구여야 한다.
    expect(find.byIcon(Icons.arrow_back_ios_new_rounded), findsNothing);
  });

  testWidgets('17. 로그아웃 버튼이 확인 후 signOut 경로를 부른다', (tester) async {
    var signOuts = 0;
    await tester.pumpWidget(
      _host(
        authService: _FakeAuthService(),
        firestoreService: _FakeFirestoreService(),
        storageService: _FakeStorageService(),
        onSignOut: () async => signOuts += 1,
      ),
    );

    await tester.tap(find.byKey(const Key('onboarding-sign-out-button')));
    await tester.pumpAndSettle();
    expect(find.text('로그아웃할까요?'), findsOneWidget);

    await tester.tap(find.text('로그아웃').last);
    await tester.pumpAndSettle();
    expect(signOuts, 1);
  });

  testWidgets('17b. 확인 dialog에서 취소하면 로그아웃하지 않는다', (tester) async {
    var signOuts = 0;
    await tester.pumpWidget(
      _host(
        authService: _FakeAuthService(),
        firestoreService: _FakeFirestoreService(),
        storageService: _FakeStorageService(),
        onSignOut: () async => signOuts += 1,
      ),
    );

    await tester.tap(find.byKey(const Key('onboarding-sign-out-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    expect(signOuts, 0);
  });

  testWidgets('18. 로그아웃 진행 중 중복 실행되지 않는다', (tester) async {
    var signOuts = 0;
    final gate = Completer<void>();
    await tester.pumpWidget(
      _host(
        authService: _FakeAuthService(),
        firestoreService: _FakeFirestoreService(),
        storageService: _FakeStorageService(),
        onSignOut: () async {
          signOuts += 1;
          await gate.future;
        },
      ),
    );

    await tester.tap(find.byKey(const Key('onboarding-sign-out-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('로그아웃').last);
    await tester.pump();

    // 진행 중에는 버튼이 비활성화되어 다시 눌러도 반응하지 않는다.
    await tester.tap(
      find.byKey(const Key('onboarding-sign-out-button')),
      warnIfMissed: false,
    );
    await tester.pump();
    expect(signOuts, 1);

    gate.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('19. onSignOut이 없으면 로그아웃 버튼을 노출하지 않는다', (tester) async {
    await tester.pumpWidget(
      _host(
        authService: _FakeAuthService(),
        firestoreService: _FakeFirestoreService(),
        storageService: _FakeStorageService(),
      ),
    );

    expect(find.byKey(const Key('onboarding-sign-out-button')), findsNothing);
  });

  test('20. Auth 사용자가 사라지거나 바뀌면 제출을 중단한다', () {
    // 로그아웃된 상태
    expect(
      shouldAbortSubmitForAuthChange(
        readAuthUid: () => null,
        onboardingUid: 'me',
      ),
      isTrue,
    );
    // 다른 계정으로 전환된 상태
    expect(
      shouldAbortSubmitForAuthChange(
        readAuthUid: () => 'someone-else',
        onboardingUid: 'me',
      ),
      isTrue,
    );
    // 같은 사용자면 정상 진행
    expect(
      shouldAbortSubmitForAuthChange(
        readAuthUid: () => 'me',
        onboardingUid: 'me',
      ),
      isFalse,
    );
    // 훅이 없으면 검사하지 않는다
    expect(
      shouldAbortSubmitForAuthChange(readAuthUid: null, onboardingUid: 'me'),
      isFalse,
    );
  });

  test('21. OnboardingScreen은 회원가입 API를 참조하지 않는다', () {
    // 기존 Auth 계정으로 온보딩을 재개할 때 createUserWithEmailAndPassword가
    // 다시 호출되면 "이미 사용 중인 이메일"로 막힌다. 소스에 호출 자체가 없어야 한다.
    final source = File(
      'lib/features/onboarding/onboarding_screen.dart',
    ).readAsStringSync();
    expect(source.contains('signUpWithEmail'), isFalse);
    expect(source.contains('createUserWithEmailAndPassword'), isFalse);
    expect(source.contains('signInWithEmail'), isFalse);
    // 프로필 생성만 수행한다.
    expect(source.contains('createUserProfile'), isTrue);
  });
}
