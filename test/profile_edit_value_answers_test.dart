// 이 테스트는 concrete FirestoreService/StorageService 인스턴스 생성을 위해
// firebase_core 플랫폼 인터페이스를 fake로 바꾼다. 두 플랫폼 인터페이스 패키지는
// pubspec 직접 의존성은 아니지만(transitive), 테스트 인프라에서만 쓰므로
// depend_on_referenced_packages 린트를 파일 단위로 무시한다(pubspec 미변경).
// ignore_for_file: depend_on_referenced_packages
import 'package:dating_app/features/profile/profile_edit_screen.dart';
import 'package:dating_app/models/user_profile.dart';
import 'package:dating_app/services/database/firestore_service.dart';
import 'package:dating_app/services/storage/storage_service.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// ProfileEditScreen은 concrete FirestoreService/StorageService를 요구한다.
/// 이들 생성자는 FirebaseFirestore/FirebaseStorage.instance를 건드리므로,
/// firebase_core 플랫폼을 fake로 바꿔 인스턴스 생성만 가능하게 한 뒤,
/// updateEditableUserProfile을 오버라이드해 실제 write 없이 payload를 캡처한다.
/// (새 mocking 의존성 없이 flutter_test의 Fake + plugin_platform_interface만 사용)

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

/// 실제 Firestore write 대신 넘어온 프로필을 캡처하는 test double.
class _CaptureFirestoreService extends FirestoreService {
  UserProfile? captured;
  int updateCalls = 0;

  @override
  Future<void> updateEditableUserProfile(UserProfile profile) async {
    updateCalls += 1;
    captured = profile;
  }
}

/// 네트워크 사진 로딩이 테스트를 불안정하게 만들지 않도록, 프로필 사진 없이
/// 저장 검증을 하되 _save()의 "사진 최소 1장" 게이트는 통과해야 한다.
/// 사진 URL 대신 data URI를 쓰면 Image.network 대신 즉시 디코드되진 않지만,
/// _PhotoSlot은 errorBuilder를 가지고 있어 실패해도 예외를 던지지 않는다.
UserProfile _profile({Map<String, String> valueAnswers = const {}}) {
  return UserProfile(
    uid: 'me',
    displayName: '지수',
    birthDate: DateTime(1996, 5, 20),
    gender: 'female',
    bio: '안녕하세요',
    photoUrls: const ['https://example.com/a.jpg'],
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
    interests: const ['music'],
    valueAnswers: valueAnswers,
  );
}

Widget _host(
  UserProfile profile,
  FirestoreService fs,
  StorageService ss, {
  void Function(UserProfile?)? onPopped,
}) {
  return MaterialApp(
    home: Builder(
      builder: (context) => Center(
        child: ElevatedButton(
          key: const ValueKey('open-edit'),
          onPressed: () async {
            final result = await Navigator.push<UserProfile>(
              context,
              MaterialPageRoute(
                builder: (_) => ProfileEditScreen(
                  profile: profile,
                  firestoreService: fs,
                  storageService: ss,
                ),
              ),
            );
            onPopped?.call(result);
          },
          child: const Text('open'),
        ),
      ),
    ),
  );
}

Finder _entry() => find.byKey(const ValueKey('value-answers-edit-entry'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FirebasePlatform.instance = _FakeFirebasePlatform();

  testWidgets('기존 valueAnswers가 가치관 카드 응답 수에 반영된다', (tester) async {
    final fs = _CaptureFirestoreService();
    final ss = StorageService();
    await tester.pumpWidget(
      MaterialApp(
        home: ProfileEditScreen(
          profile: _profile(
            valueAnswers: const {
              'contact_frequency': 'few_times',
              'conflict_style': 'cool_down',
            },
          ),
          firestoreService: fs,
          storageService: ss,
        ),
      ),
    );
    await tester.pump();

    await tester.scrollUntilVisible(
      _entry(),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('2 / 6 답변'), findsOneWidget);
    expect(find.text('수정하기'), findsOneWidget);
  });

  testWidgets('미응답이면 안내 문구와 답변하기가 표시된다', (tester) async {
    final fs = _CaptureFirestoreService();
    await tester.pumpWidget(
      MaterialApp(
        home: ProfileEditScreen(
          profile: _profile(),
          firestoreService: fs,
          storageService: StorageService(),
        ),
      ),
    );
    await tester.pump();

    await tester.scrollUntilVisible(
      _entry(),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('아직 답변한 가치관 질문이 없어요'), findsOneWidget);
    expect(find.text('답변하기'), findsOneWidget);
  });

  testWidgets('진입 → 전용 화면 편집 → 완료 시 부모 요약이 갱신되고, 그 동안 서비스 write는 0회', (
    tester,
  ) async {
    final fs = _CaptureFirestoreService();
    await tester.pumpWidget(
      MaterialApp(
        home: ProfileEditScreen(
          profile: _profile(),
          firestoreService: fs,
          storageService: StorageService(),
        ),
      ),
    );
    await tester.pump();

    await tester.scrollUntilVisible(
      _entry(),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(_entry());
    await tester.pumpAndSettle();

    // 전용 화면에서 두 문항 선택
    await tester.tap(
      find.byKey(const ValueKey('value-option-contact_frequency-few_times')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('value-option-conflict_style-cool_down')),
    );
    await tester.pumpAndSettle();

    // 선택하는 동안 서비스 write 없음
    expect(fs.updateCalls, 0);

    await tester.tap(find.byKey(const ValueKey('value-answers-done')));
    await tester.pumpAndSettle();

    // 부모 요약 갱신
    await tester.scrollUntilVisible(
      _entry(),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('2 / 6 답변'), findsOneWidget);
    // 완료만으로는 저장 안 됨
    expect(fs.updateCalls, 0);
  });

  testWidgets('전용 화면에서 뒤로가면 부모 상태가 바뀌지 않는다', (tester) async {
    final fs = _CaptureFirestoreService();
    await tester.pumpWidget(
      MaterialApp(
        home: ProfileEditScreen(
          profile: _profile(),
          firestoreService: fs,
          storageService: StorageService(),
        ),
      ),
    );
    await tester.pump();

    await tester.scrollUntilVisible(
      _entry(),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(_entry());
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('value-option-contact_frequency-few_times')),
    );
    await tester.pumpAndSettle();
    // 완료 대신 뒤로가기
    await tester.tap(find.byIcon(Icons.arrow_back_ios_new_rounded));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      _entry(),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('아직 답변한 가치관 질문이 없어요'), findsOneWidget);
  });

  testWidgets(
    '최종 저장 시 captured UserProfile.valueAnswers에 변경값이 포함되고, updateEditableUserProfile은 정확히 1회',
    (tester) async {
      final fs = _CaptureFirestoreService();
      UserProfile? popped;
      await tester.pumpWidget(
        _host(_profile(), fs, StorageService(), onPopped: (p) => popped = p),
      );
      await tester.tap(find.byKey(const ValueKey('open-edit')));
      await tester.pumpAndSettle();

      // 가치관 입력
      await tester.scrollUntilVisible(
        _entry(),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(_entry());
      await tester.pumpAndSettle();
      // 옵션이 화면 아래에 있으면 탭이 하단 완료 버튼에 잘못 적중할 수 있으므로
      // 먼저 보이도록 스크롤한다.
      await tester.ensureVisible(
        find.byKey(const ValueKey('value-option-date_style-cozy')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('value-option-date_style-cozy')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('value-answers-done')));
      await tester.pumpAndSettle();

      // 최종 저장
      await tester.scrollUntilVisible(
        find.text('저장'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('저장'));
      await tester.pumpAndSettle();

      expect(fs.updateCalls, 1);
      expect(fs.captured, isNotNull);
      expect(fs.captured!.valueAnswers, {'date_style': 'cozy'});
      // 기존 필드 회귀: 이름·소개·사진·태그 보존
      expect(fs.captured!.displayName, '지수');
      expect(fs.captured!.bio, '안녕하세요');
      expect(fs.captured!.photoUrls, const ['https://example.com/a.jpg']);
      expect(fs.captured!.interests, const ['music']);

      // 저장 후 pop된 updatedProfile에도 valueAnswers 포함
      expect(popped, isNotNull);
      expect(popped!.valueAnswers, {'date_style': 'cozy'});
    },
  );
}
