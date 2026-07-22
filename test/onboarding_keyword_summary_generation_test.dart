// ignore_for_file: depend_on_referenced_packages

import 'dart:async';
import 'dart:io';

import 'package:dating_app/features/onboarding/onboarding_screen.dart';
import 'package:dating_app/models/user_profile.dart';
import 'package:dating_app/services/auth/auth_service.dart';
import 'package:dating_app/services/database/firestore_service.dart';
import 'package:dating_app/services/profile/profile_keyword_summary_service.dart';
import 'package:dating_app/services/storage/profile_photo_processor.dart';
import 'package:dating_app/services/storage/storage_service.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

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

/// 결정론적 사진 선택기.
///
/// 예전에는 native ImagePickerPlatform을 fake로 갈아끼웠는데, 그러면 이
/// 위젯 테스트가 image_picker 구현 세부사항(옵션 전달·플랫폼 설치 시점)에
/// 묶인다. 실제 bytes 판정과 metadata 제거는 profile_photo_processor_test가
/// 따로 검증하므로, 여기서는 "처리된 사진이 돌아왔을 때 온보딩이 어떻게
/// 동작하는가"만 본다.
class _FakePhotoPicker implements ProfilePhotoPicker {
  _FakePhotoPicker(this.photo);

  final ProcessedProfilePhoto photo;
  int calls = 0;

  @override
  Future<ProcessedProfilePhoto?> pickFromGallery() async {
    calls += 1;
    return photo;
  }
}

class _FakeAuthService extends AuthService {
  _FakeAuthService()
    : super(authBadgeSyncCaller: () async => <String, Object?>{});

  final events = <String>[];
  int reloadCalls = 0;
  int syncCalls = 0;

  @override
  Future<void> reloadUser() async {
    reloadCalls += 1;
    events.add('reload');
  }

  @override
  bool get hasAnyAuthVerificationSignal => true;

  @override
  Future<VerificationStatus> syncAuthVerificationBadges() async {
    syncCalls += 1;
    events.add('sync');
    return const VerificationStatus(email: true);
  }
}

class _FakeStorageService extends StorageService {
  _FakeStorageService({this.throwOnUpload = false});

  final bool throwOnUpload;
  int uploadCalls = 0;
  final events = <String>[];

  @override
  Future<List<String>> uploadMultipleProfilePhotos({
    required String uid,
    required ProcessedProfilePhoto mainPhoto,
    List<ProcessedProfilePhoto> subPhotos = const [],
    void Function(double progress)? onProgress,
  }) async {
    uploadCalls += 1;
    events.add('upload');
    if (throwOnUpload) {
      throw StateError('upload failed');
    }
    return const ['https://example.com/main.jpg'];
  }
}

class _FakeFirestoreService extends FirestoreService {
  _FakeFirestoreService({this.createCompleter, this.throwOnCreate = false});

  final Completer<void>? createCompleter;
  final bool throwOnCreate;
  int createCalls = 0;
  UserProfile? captured;
  final events = <String>[];

  @override
  Future<void> createUserProfile(UserProfile profile) async {
    createCalls += 1;
    captured = profile;
    events.add('create-start');
    if (throwOnCreate) {
      events.add('create-error');
      throw StateError('create failed');
    }
    final completer = createCompleter;
    if (completer != null) {
      await completer.future;
    }
    events.add('create-end');
  }
}

Widget _host({
  required AuthService authService,
  required FirestoreService firestoreService,
  required StorageService storageService,
  required ProfileKeywordSummaryService keywordService,
  required VoidCallback onCompleted,
  required ProfilePhotoPicker photoPicker,
}) {
  return MaterialApp(
    home: OnboardingScreen(
      photoPicker: photoPicker,
      uid: 'me',
      authService: authService,
      firestoreService: firestoreService,
      storageService: storageService,
      profileKeywordSummaryService: keywordService,
      onCompleted: onCompleted,
    ),
  );
}

Future<String> _writeTinyImage() async {
  // 유효한 최소 PNG(IHDR + IDAT + IEND). ProfilePhotoProcessor가 실제 bytes로
  // 포맷을 판정하므로 signature만 있는 조각으로는 통과하지 못한다.
  int crc32(List<int> data) {
    var crc = 0xFFFFFFFF;
    for (final byte in data) {
      crc ^= byte;
      for (var i = 0; i < 8; i += 1) {
        crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
      }
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }

  final out = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  void chunk(String type, List<int> data) {
    final length = data.length;
    out.addAll([
      (length >> 24) & 0xFF,
      (length >> 16) & 0xFF,
      (length >> 8) & 0xFF,
      length & 0xFF,
    ]);
    final typed = [...type.codeUnits, ...data];
    out.addAll(typed);
    final crc = crc32(typed);
    out.addAll([
      (crc >> 24) & 0xFF,
      (crc >> 16) & 0xFF,
      (crc >> 8) & 0xFF,
      crc & 0xFF,
    ]);
  }

  chunk('IHDR', [0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0]);
  chunk('IDAT', [0x78, 0x9C, 0x63, 0x00, 0x00, 0x00, 0x02, 0x00, 0x01]);
  chunk('IEND', const []);

  final file = File('${Directory.systemTemp.path}/cvr_onboarding_test.png');
  await file.writeAsBytes(out);
  return file.path;
}

Future<void> _advanceToSubmit(WidgetTester tester) async {
  await tester.tap(find.text('메인 사진 선택 (필수)'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('다음'));
  await tester.pumpAndSettle();

  await tester.enterText(find.byType(TextFormField).at(0), '지수');
  await tester.tap(find.byType(TextFormField).at(1));
  await tester.pumpAndSettle();
  await tester.tap(find.text('확인'));
  await tester.pumpAndSettle();
  // Phase 5-2: 출생시간 선택은 필수다. 여기서는 "몰라요"로 진행한다.
  await tester.tap(find.byKey(const Key('birth-time-unknown-option')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('여성'));
  await tester.enterText(find.byType(TextFormField).at(2), '천천히 대화해요');
  await tester.tap(find.text('다음'));
  await tester.pumpAndSettle();

  for (var i = 0; i < 4; i += 1) {
    await tester.tap(find.text('다음'));
    await tester.pumpAndSettle();
  }
}

Future<void> _setLargeSurface(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(800, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FirebasePlatform.instance = _FakeFirebasePlatform();
  late ProcessedProfilePhoto fixturePhoto;

  setUpAll(() async {
    fixturePhoto = await ProfilePhotoProcessor().processFile(
      File(await _writeTinyImage()),
    );
  });

  testWidgets(
    'onboarding schedules keyword generation after create and completes before AI finishes',
    (tester) async {
      final createCompleter = Completer<void>();
      final keywordCompleter = Completer<Object?>();
      final auth = _FakeAuthService();
      final storage = _FakeStorageService();
      final firestore = _FakeFirestoreService(createCompleter: createCompleter);
      final events = <String>[];
      var keywordCalls = 0;
      var completedCalls = 0;
      late Map<String, Object?> keywordPayload;
      final keywordService = ProfileKeywordSummaryService.withInvoker((
        payload,
      ) {
        keywordCalls += 1;
        keywordPayload = Map<String, Object?>.from(payload);
        events.add('keyword-start');
        return keywordCompleter.future;
      });

      await _setLargeSurface(tester);
      await tester.pumpWidget(
        _host(
          authService: auth,
          firestoreService: firestore,
          storageService: storage,
          keywordService: keywordService,
          photoPicker: _FakePhotoPicker(fixturePhoto),
          onCompleted: () {
            completedCalls += 1;
            events.add('completed');
          },
        ),
      );
      await _advanceToSubmit(tester);

      await tester.tap(find.text('완료'));
      await tester.pump();

      expect(storage.uploadCalls, 1);
      expect(firestore.createCalls, 1);
      expect(keywordCalls, 0);
      expect(completedCalls, 0);

      createCompleter.complete();
      await tester.pump();

      expect(firestore.captured?.uid, 'me');
      expect(auth.syncCalls, 1);
      expect(keywordCalls, 1);
      expect(keywordPayload, isEmpty);
      expect(completedCalls, 1);
      expect(keywordCompleter.isCompleted, isFalse);
      expect(firestore.events, ['create-start', 'create-end']);
      expect(events, ['keyword-start', 'completed']);

      keywordCompleter.complete({
        'keywords': ['차분한 대화', '주말 산책', '진지한 관계'],
        'generator': 'ai',
        'cacheHit': false,
      });
      await tester.pump();
    },
  );

  testWidgets('onboarding keyword failure does not block completion', (
    tester,
  ) async {
    final auth = _FakeAuthService();
    final storage = _FakeStorageService();
    final firestore = _FakeFirestoreService();
    final keywordCompleter = Completer<Object?>();
    var completedCalls = 0;
    final keywordService = ProfileKeywordSummaryService.withInvoker((payload) {
      return keywordCompleter.future;
    });

    await _setLargeSurface(tester);
    await tester.pumpWidget(
      _host(
        authService: auth,
        firestoreService: firestore,
        storageService: storage,
        keywordService: keywordService,
        photoPicker: _FakePhotoPicker(fixturePhoto),
        onCompleted: () => completedCalls += 1,
      ),
    );
    await _advanceToSubmit(tester);

    await tester.tap(find.text('완료'));
    await tester.pump();

    expect(completedCalls, 1);
    expect(find.textContaining('프로필 저장에 실패'), findsNothing);

    keywordCompleter.completeError(StateError('callable failed'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'createUserProfile failure does not schedule keyword generation or complete',
    (tester) async {
      final auth = _FakeAuthService();
      final storage = _FakeStorageService();
      final firestore = _FakeFirestoreService(throwOnCreate: true);
      var keywordCalls = 0;
      var completedCalls = 0;
      final keywordService = ProfileKeywordSummaryService.withInvoker((
        payload,
      ) async {
        keywordCalls += 1;
        return {
          'keywords': <String>[],
          'generator': 'fallback',
          'cacheHit': false,
        };
      });

      await _setLargeSurface(tester);
      await tester.pumpWidget(
        _host(
          authService: auth,
          firestoreService: firestore,
          storageService: storage,
          keywordService: keywordService,
          photoPicker: _FakePhotoPicker(fixturePhoto),
          onCompleted: () => completedCalls += 1,
        ),
      );
      await _advanceToSubmit(tester);

      await tester.tap(find.text('완료'));
      await tester.pump();

      expect(firestore.createCalls, 1);
      expect(keywordCalls, 0);
      expect(completedCalls, 0);
      expect(find.textContaining('프로필 저장에 실패했어요'), findsOneWidget);
    },
  );

  testWidgets('photo upload failure does not schedule keyword generation', (
    tester,
  ) async {
    final auth = _FakeAuthService();
    final storage = _FakeStorageService(throwOnUpload: true);
    final firestore = _FakeFirestoreService();
    var keywordCalls = 0;
    var completedCalls = 0;
    final keywordService = ProfileKeywordSummaryService.withInvoker((
      payload,
    ) async {
      keywordCalls += 1;
      return {
        'keywords': <String>[],
        'generator': 'fallback',
        'cacheHit': false,
      };
    });

    await _setLargeSurface(tester);
    await tester.pumpWidget(
      _host(
        authService: auth,
        firestoreService: firestore,
        storageService: storage,
        keywordService: keywordService,
        photoPicker: _FakePhotoPicker(fixturePhoto),
        onCompleted: () => completedCalls += 1,
      ),
    );
    await _advanceToSubmit(tester);

    await tester.tap(find.text('완료'));
    await tester.pump();

    expect(storage.uploadCalls, 1);
    expect(firestore.createCalls, 0);
    expect(keywordCalls, 0);
    expect(completedCalls, 0);
    expect(find.textContaining('프로필 저장에 실패했어요'), findsOneWidget);
  });
}
