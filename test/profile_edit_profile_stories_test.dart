// 이 테스트는 concrete FirestoreService/StorageService 인스턴스 생성을 위해
// firebase_core 플랫폼 인터페이스를 fake로 바꾼다. 두 플랫폼 인터페이스 패키지는
// pubspec 직접 의존성은 아니지만(transitive), 테스트 인프라에서만 쓰므로
// depend_on_referenced_packages 린트를 파일 단위로 무시한다(pubspec 미변경).
// ignore_for_file: depend_on_referenced_packages
import 'package:dating_app/features/profile/profile_edit_screen.dart';
import 'package:dating_app/models/profile_story.dart';
import 'package:dating_app/models/user_profile.dart';
import 'package:dating_app/services/database/firestore_service.dart';
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

class _CaptureFirestoreService extends FirestoreService {
  UserProfile? captured;
  int updateCalls = 0;

  @override
  Future<void> updateEditableUserProfile(UserProfile profile) async {
    updateCalls += 1;
    captured = profile;
  }
}

UserProfile _profile({
  List<ProfileStory> profileStories = const [],
  Map<String, String> valueAnswers = const {'date_style': 'cozy'},
}) {
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
    personalityTags: const ['warm'],
    idealTags: const ['kind'],
    relationshipGoal: 'serious_relationship',
    valueAnswers: valueAnswers,
    profileStories: profileStories,
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

Finder _entry() => find.byKey(const ValueKey('profile-stories-edit-entry'));
Finder _prompt(String key) => find.byKey(ValueKey('profile-story-prompt-$key'));
Finder _answer(String key) => find.byKey(ValueKey('profile-story-answer-$key'));

Future<void> _scrollToEntry(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    _entry(),
    250,
    scrollable: find.byType(Scrollable).first,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FirebasePlatform.instance = _FakeFirebasePlatform();

  testWidgets('기존 profileStories 초기 요약이 표시된다', (tester) async {
    final fs = _CaptureFirestoreService();
    await tester.pumpWidget(
      MaterialApp(
        home: ProfileEditScreen(
          profile: _profile(
            profileStories: const [
              ProfileStory(promptKey: 'weekend', answer: '산책하는 주말'),
            ],
          ),
          firestoreService: fs,
          storageService: StorageService(),
        ),
      ),
    );
    await tester.pump();

    await _scrollToEntry(tester);
    expect(find.text('1 / 3개 작성'), findsOneWidget);
    expect(find.text('완벽한 주말을 보낸다면?'), findsOneWidget);
    expect(find.text('산책하는 주말'), findsOneWidget);
    expect(
      find.descendant(of: _entry(), matching: find.text('수정하기')),
      findsOneWidget,
    );
  });

  testWidgets('빈 상태 문구와 진입 key가 존재한다', (tester) async {
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

    await _scrollToEntry(tester);
    expect(_entry(), findsOneWidget);
    expect(find.text('아직 작성한 이야기가 없어요'), findsOneWidget);
    expect(find.text('작성하기'), findsOneWidget);
  });

  testWidgets('전용 화면 완료 후 부모 요약은 갱신되지만 service write는 0회', (tester) async {
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

    await _scrollToEntry(tester);
    await tester.tap(_entry());
    await tester.pumpAndSettle();

    await tester.tap(_prompt('weekend'));
    await tester.pumpAndSettle();
    await tester.enterText(_answer('weekend'), '늦잠 자고 산책하기');
    await tester.pumpAndSettle();

    expect(fs.updateCalls, 0);
    await tester.tap(find.byKey(const ValueKey('profile-stories-done')));
    await tester.pumpAndSettle();

    await _scrollToEntry(tester);
    expect(find.text('1 / 3개 작성'), findsOneWidget);
    expect(find.text('늦잠 자고 산책하기'), findsOneWidget);
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

    await _scrollToEntry(tester);
    await tester.tap(_entry());
    await tester.pumpAndSettle();
    await tester.tap(_prompt('weekend'));
    await tester.pumpAndSettle();
    await tester.enterText(_answer('weekend'), '임시 답변');
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.arrow_back_ios_new_rounded));
    await tester.pumpAndSettle();

    await _scrollToEntry(tester);
    expect(find.text('아직 작성한 이야기가 없어요'), findsOneWidget);
    expect(find.text('임시 답변'), findsNothing);
    expect(fs.updateCalls, 0);
  });

  testWidgets('최종 저장 시 captured/popped profileStories와 기존 필드가 유지된다', (
    tester,
  ) async {
    final fs = _CaptureFirestoreService();
    UserProfile? popped;
    await tester.pumpWidget(
      _host(_profile(), fs, StorageService(), onPopped: (p) => popped = p),
    );
    await tester.tap(find.byKey(const ValueKey('open-edit')));
    await tester.pumpAndSettle();

    await _scrollToEntry(tester);
    await tester.tap(_entry());
    await tester.pumpAndSettle();
    await tester.tap(_prompt('weekend'));
    await tester.pumpAndSettle();
    await tester.enterText(_answer('weekend'), '늦잠 자고 산책하기');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('profile-stories-done')));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('저장'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();

    expect(fs.updateCalls, 1);
    expect(fs.captured, isNotNull);
    expect(fs.captured!.profileStories, [
      const ProfileStory(promptKey: 'weekend', answer: '늦잠 자고 산책하기'),
    ]);
    expect(fs.captured!.displayName, '지수');
    expect(fs.captured!.bio, '안녕하세요');
    expect(fs.captured!.photoUrls, const ['https://example.com/a.jpg']);
    expect(fs.captured!.interests, const ['music']);
    expect(fs.captured!.personalityTags, const ['warm']);
    expect(fs.captured!.idealTags, const ['kind']);
    expect(fs.captured!.valueAnswers, {'date_style': 'cozy'});

    expect(popped, isNotNull);
    expect(popped!.profileStories, fs.captured!.profileStories);
  });

  testWidgets('story 순서와 unknown story가 저장까지 보존된다', (tester) async {
    final fs = _CaptureFirestoreService();
    await tester.pumpWidget(
      MaterialApp(
        home: ProfileEditScreen(
          profile: _profile(
            profileStories: const [
              ProfileStory(promptKey: 'future_prompt', answer: '미래 답변'),
              ProfileStory(promptKey: 'weekend', answer: '기존 주말'),
            ],
          ),
          firestoreService: fs,
          storageService: StorageService(),
        ),
      ),
    );
    await tester.pump();

    await _scrollToEntry(tester);
    expect(find.text('1 / 3개 작성'), findsOneWidget);
    expect(find.text('future_prompt'), findsNothing);

    await tester.scrollUntilVisible(
      find.text('저장'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();

    expect(fs.updateCalls, 1);
    expect(fs.captured!.profileStories, [
      const ProfileStory(promptKey: 'future_prompt', answer: '미래 답변'),
      const ProfileStory(promptKey: 'weekend', answer: '기존 주말'),
    ]);
  });
}
