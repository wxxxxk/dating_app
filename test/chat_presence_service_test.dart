// 마지막 테스트는 FirebaseFirestore 주입 지점을 실제로 확인하기 위해
// firebase_core 플랫폼을 fake로 바꾼다(기존 테스트와 동일한 방식, pubspec 미변경).
// ignore_for_file: depend_on_referenced_packages
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:dating_app/services/chat/chat_presence_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Phase 2-2 — presence 문서 경로/payload 계약 테스트.
///
/// 실제 write 경로는 Firestore Emulator rules 테스트가 검증하고, 여기서는
/// firestore.rules와 맞춰야 하는 경로·필드 계약만 순수 함수로 확인한다.
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

void main() {
  test('presence 문서 경로는 matches/{matchId}/presence/{uid}다', () {
    expect(
      ChatPresenceService.presencePath(matchId: 'match1', uid: 'userA'),
      'matches/match1/presence/userA',
    );
  });

  test('payload는 rules allowlist와 정확히 같은 5개 필드만 담는다', () {
    final doc = ChatPresenceService.buildPresenceDoc(
      uid: 'userA',
      isOnline: true,
      isTyping: true,
      timestamp: FieldValue.serverTimestamp(),
    );

    expect(doc.keys.toSet(), {
      'uid',
      'isOnline',
      'isTyping',
      'lastActiveAt',
      'updatedAt',
    });
    expect(doc['uid'], 'userA');
    expect(doc['isOnline'], isTrue);
    expect(doc['isTyping'], isTrue);
    // 시각은 항상 serverTimestamp — rules가 request.time만 허용한다.
    expect(doc['lastActiveAt'], isA<FieldValue>());
    expect(doc['updatedAt'], same(doc['lastActiveAt']));
  });

  test('offline이면 typing 요청이 와도 false로 내려간다', () {
    final doc = ChatPresenceService.buildPresenceDoc(
      uid: 'userA',
      isOnline: false,
      isTyping: true,
      timestamp: 'ts',
    );
    expect(doc['isOnline'], isFalse);
    expect(doc['isTyping'], isFalse);
  });

  test('FirebaseFirestore를 주입할 수 있다(dependency injection)', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    FirebasePlatform.instance = _FakeFirebasePlatform();

    final injected = ChatPresenceService(firestore: FirebaseFirestore.instance);
    expect(injected, isNotNull);
    // 주입하지 않으면 FirebaseFirestore.instance로 폴백한다.
    expect(ChatPresenceService(), isNotNull);
  });
}
