// ignore_for_file: depend_on_referenced_packages

import 'dart:async';

import 'package:dating_app/features/profile/profile_edit_screen.dart';
import 'package:dating_app/models/user_profile.dart';
import 'package:dating_app/services/database/firestore_service.dart';
import 'package:dating_app/services/profile/profile_keyword_summary_service.dart';
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

class _FakeFirestoreService extends FirestoreService {
  _FakeFirestoreService({this.updateCompleter, this.throwOnUpdate = false});

  final Completer<void>? updateCompleter;
  final bool throwOnUpdate;
  int updateCalls = 0;
  UserProfile? captured;
  final events = <String>[];

  @override
  Future<void> updateEditableUserProfile(UserProfile profile) async {
    updateCalls += 1;
    captured = profile;
    events.add('update-start');
    if (throwOnUpdate) {
      events.add('update-error');
      throw StateError('update failed');
    }
    final completer = updateCompleter;
    if (completer != null) {
      await completer.future;
    }
    events.add('update-end');
  }
}

UserProfile _profile() {
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
    relationshipGoal: 'serious_relationship',
  );
}

Widget _host({
  required FirestoreService firestoreService,
  required ProfileKeywordSummaryService keywordService,
  void Function(UserProfile?)? onPopped,
}) {
  return MaterialApp(
    home: Builder(
      builder: (context) => ElevatedButton(
        key: const ValueKey('open-edit'),
        onPressed: () async {
          final result = await Navigator.push<UserProfile>(
            context,
            MaterialPageRoute(
              builder: (_) => ProfileEditScreen(
                profile: _profile(),
                firestoreService: firestoreService,
                storageService: StorageService(),
                profileKeywordSummaryService: keywordService,
              ),
            ),
          );
          onPopped?.call(result);
        },
        child: const Text('open'),
      ),
    ),
  );
}

Future<void> _openAndScrollToSave(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('open-edit')));
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(
    find.text('저장'),
    350,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FirebasePlatform.instance = _FakeFirebasePlatform();

  testWidgets(
    'profile save schedules keyword generation after update and pops before AI completes',
    (tester) async {
      final updateCompleter = Completer<void>();
      final keywordCompleter = Completer<Object?>();
      final firestore = _FakeFirestoreService(updateCompleter: updateCompleter);
      final events = firestore.events;
      var keywordCalls = 0;
      UserProfile? popped;
      late Map<String, Object?> keywordPayload;
      final keywordService = ProfileKeywordSummaryService.withInvoker((
        payload,
      ) {
        keywordCalls += 1;
        keywordPayload = Map<String, Object?>.from(payload);
        events.add('keyword-start');
        return keywordCompleter.future;
      });

      await tester.pumpWidget(
        _host(
          firestoreService: firestore,
          keywordService: keywordService,
          onPopped: (profile) => popped = profile,
        ),
      );
      await _openAndScrollToSave(tester);

      await tester.tap(find.text('저장'));
      await tester.pump();
      expect(keywordCalls, 0);
      expect(popped, isNull);

      updateCompleter.complete();
      await tester.pump();

      expect(firestore.updateCalls, 1);
      expect(keywordCalls, 1);
      expect(keywordPayload, isEmpty);
      expect(events, ['update-start', 'update-end', 'keyword-start']);
      expect(popped, isNotNull);
      expect(popped!.uid, 'me');
      expect(keywordCompleter.isCompleted, isFalse);

      keywordCompleter.complete({
        'keywords': ['차분한 대화', '주말 산책', '진지한 관계'],
        'generator': 'ai',
        'cacheHit': false,
      });
      await tester.pump();
    },
  );

  testWidgets('keyword failure is isolated after successful profile save', (
    tester,
  ) async {
    final keywordCompleter = Completer<Object?>();
    final firestore = _FakeFirestoreService();
    var keywordCalls = 0;
    UserProfile? popped;
    final keywordService = ProfileKeywordSummaryService.withInvoker((payload) {
      keywordCalls += 1;
      return keywordCompleter.future;
    });

    await tester.pumpWidget(
      _host(
        firestoreService: firestore,
        keywordService: keywordService,
        onPopped: (profile) => popped = profile,
      ),
    );
    await _openAndScrollToSave(tester);

    await tester.tap(find.text('저장'));
    await tester.pump();

    expect(firestore.updateCalls, 1);
    expect(keywordCalls, 1);
    expect(popped, isNotNull);
    expect(find.textContaining('프로필 저장에 실패했어요'), findsNothing);

    keywordCompleter.completeError(StateError('callable failed'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'profile save failure does not call keyword service or pop route',
    (tester) async {
      final firestore = _FakeFirestoreService(throwOnUpdate: true);
      var keywordCalls = 0;
      UserProfile? popped;
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

      await tester.pumpWidget(
        _host(
          firestoreService: firestore,
          keywordService: keywordService,
          onPopped: (profile) => popped = profile,
        ),
      );
      await _openAndScrollToSave(tester);

      await tester.tap(find.text('저장'));
      await tester.pump();

      expect(firestore.updateCalls, 1);
      expect(keywordCalls, 0);
      expect(popped, isNull);
      expect(find.textContaining('프로필 저장에 실패했어요'), findsOneWidget);
    },
  );
}
