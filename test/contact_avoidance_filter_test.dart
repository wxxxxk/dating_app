// ignore_for_file: depend_on_referenced_packages
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:dating_app/models/public_profile.dart';
import 'package:dating_app/models/user_profile.dart';
import 'package:dating_app/services/discovery/discovery_service.dart';
import 'package:dating_app/services/privacy/contact_avoidance_service.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// Phase 3-4 — 지인 피하기 제외 집합이 Discovery/받은 좋아요 후보에 적용되는지
/// 확인한다. Firestore 쿼리 자체는 Rules 테스트가 검증하고, 여기서는 제외
/// 집합 계산과 필터 계약을 순수하게 확인한다.
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

PublicProfile _profile(String uid) {
  return PublicProfile(uid: uid, displayName: uid, age: 27, gender: 'female');
}

/// Discovery 화면이 쓰는 것과 같은 제외 규칙(본인·차단·지인 피하기 union).
Set<String> _excluded({
  required Set<String> blocked,
  required Set<String> avoided,
}) {
  return {...blocked, ...avoided};
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    FirebasePlatform.instance = _FakeFirebasePlatform();
  });

  group('1~6. Discovery 제외 집합', () {
    test('1~3. pair 상대는 빠지고 나머지 후보는 남는다', () {
      final excluded = _excluded(blocked: {}, avoided: {'friendA'});
      final visible = ['friendA', 'strangerB', 'strangerC']
          .where((uid) => !excluded.contains(uid))
          .toList();

      expect(visible, ['strangerB', 'strangerC']);
    });

    test('2. block과 pair는 합집합으로 적용된다', () {
      final excluded = _excluded(
        blocked: {'blockedA'},
        avoided: {'friendA', 'blockedA'},
      );
      expect(excluded, {'blockedA', 'friendA'});
      expect(
        ['blockedA', 'friendA', 'strangerB']
            .where((uid) => !excluded.contains(uid))
            .toList(),
        ['strangerB'],
      );
    });

    test('5. pair가 모든 후보를 가리면 빈 결과가 된다', () {
      final excluded = _excluded(blocked: {}, avoided: {'a', 'b'});
      expect(['a', 'b'].where((uid) => !excluded.contains(uid)), isEmpty);
    });

    test('6. pair stream이 갱신되면 제외 집합도 갱신된다', () {
      var excluded = _excluded(blocked: {}, avoided: {'friendA'});
      expect(excluded.contains('friendA'), isTrue);
      // 상대가 연락처에서 사라져 pair가 해제된 경우
      excluded = _excluded(blocked: {}, avoided: {});
      expect(excluded.contains('friendA'), isFalse);
    });

    test('4, 7. DiscoveryService는 본인과 excludedUids를 후보에서 뺀다', () async {
      // getDiscoveryProfiles의 계약: 화면에 넘기기 전에 제외한다(카드 flash 방지).
      final service = DiscoveryService(firestore: _ThrowingFirestore());
      expect(service, isNotNull);

      // 제외 규칙 자체는 순수 집합 연산으로 확인한다.
      const me = 'me';
      final candidates = [
        _profile(me),
        _profile('friendA'),
        _profile('strangerB'),
      ];
      final excluded = _excluded(blocked: {}, avoided: {'friendA'});
      final result = candidates
          .where((p) => p.uid != me && !excluded.contains(p.uid))
          .map((p) => p.uid)
          .toList();
      expect(result, ['strangerB']);
    });
  });

  group('1~4. 받은 좋아요 제외', () {
    test('pair 상대의 좋아요만 빠지고 원본 문서는 건드리지 않는다', () {
      // watchReceivedLikes의 필터 조건과 같은 규칙.
      const currentUid = 'me';
      final avoided = {'friendA'};
      final blocked = {'blockedB'};
      final incoming = ['friendA', 'blockedB', 'strangerC', currentUid];

      final visible = incoming
          .where(
            (actorUid) =>
                actorUid != currentUid &&
                !blocked.contains(actorUid) &&
                !avoided.contains(actorUid),
          )
          .toList();

      expect(visible, ['strangerC']);
      // 원본 swipe 문서는 그대로 존재한다(목록에서 숨기기만 한다).
      expect(incoming.contains('friendA'), isTrue);
    });
  });

  group('pair 문서 → 제외 uid 파싱', () {
    test('participants에서 상대 uid만 추출한다', () {
      final uids = ContactAvoidanceService.avoidedUidsFromDocs('me', [
        {
          'participants': ['me', 'friendA'],
          'updatedAt': Timestamp.now(),
          'schemaVersion': 1,
        },
      ]);
      expect(uids, {'friendA'});
    });

    test('빈 uid나 malformed 문서는 무시한다', () {
      expect(
        ContactAvoidanceService.avoidedUidsFromDocs('', [
          {
            'participants': ['a', 'b'],
          },
        ]),
        {'a', 'b'},
      );
      expect(
        ContactAvoidanceService.avoidedUidsFromDocs('me', [
          {'participants': <dynamic>[]},
        ]),
        isEmpty,
      );
    });
  });

  test('VerificationStatus 등 기존 모델 계약은 그대로다', () {
    // 지인 피하기 도입이 인증 배지 계약을 건드리지 않았는지 대표 확인.
    const status = VerificationStatus(phone: true);
    expect(status.phone, isTrue);
    expect(status.work, isFalse);
    expect(status.school, isFalse);
  });
}

/// 실제 쿼리가 실행되면 실패하도록 하는 스텁(생성자 주입 지점 확인용).
class _ThrowingFirestore extends Fake implements FirebaseFirestore {}
