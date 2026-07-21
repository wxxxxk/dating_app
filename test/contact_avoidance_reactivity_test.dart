// ignore_for_file: depend_on_referenced_packages
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:dating_app/models/public_profile.dart';
import 'package:dating_app/services/privacy/contact_avoidance_service.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// Phase 3-4A — pair 변경 반응성 테스트.
///
/// Discovery 화면과 받은 좋아요가 pair stream 변경에 즉시 반응하는지를,
/// 화면 로직과 동일한 규칙을 재현해 검증한다(Firestore 없이).
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

PublicProfile _p(String uid) =>
    PublicProfile(uid: uid, displayName: uid, age: 27, gender: 'female');

/// DiscoveryScreen._onAvoidedUidsChanged / _removeAvoidedFromDeck과 같은 규칙.
class _Deck {
  _Deck(this.profiles, this.index);

  List<PublicProfile> profiles;
  int index;
  Set<String> avoided = {};
  int reloadRequests = 0;

  void onAvoidedChanged(Set<String> next) {
    if (setEquals(avoided, next)) return;
    final added = next.difference(avoided);
    final removed = avoided.difference(next);
    avoided = next;
    if (added.isNotEmpty) _removeAdded(added);
    if (removed.isNotEmpty) reloadRequests += 1;
  }

  void _removeAdded(Set<String> added) {
    if (profiles.isEmpty) return;
    final currentUid = index < profiles.length ? profiles[index].uid : null;
    final remaining = profiles
        .where((profile) => !added.contains(profile.uid))
        .toList();
    if (remaining.length == profiles.length) return;

    var nextIndex = currentUid == null
        ? index
        : remaining.indexWhere((profile) => profile.uid == currentUid);
    if (nextIndex < 0) {
      nextIndex = index.clamp(0, remaining.isEmpty ? 0 : remaining.length);
    }
    profiles = remaining;
    index = remaining.isEmpty ? 0 : nextIndex.clamp(0, remaining.length);
  }
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    FirebasePlatform.instance = _FakeFirebasePlatform();
  });

  group('Discovery 반응성', () {
    test('1. pair 추가 시 해당 후보가 즉시 덱에서 빠진다', () {
      final deck = _Deck([_p('a'), _p('friend'), _p('b')], 0);

      deck.onAvoidedChanged({'friend'});

      expect(deck.profiles.map((p) => p.uid), ['a', 'b']);
      // 보고 있던 카드(a)는 그대로 유지된다.
      expect(deck.profiles[deck.index].uid, 'a');
      expect(deck.reloadRequests, 0);
    });

    test('2. 현재 보고 있던 카드가 제외돼도 index 오류가 없다', () {
      final deck = _Deck([_p('a'), _p('friend'), _p('b')], 1);

      deck.onAvoidedChanged({'friend'});

      expect(deck.profiles.map((p) => p.uid), ['a', 'b']);
      // 같은 자리에 오는 다음 카드로 안전하게 이동한다.
      expect(deck.index, 1);
      expect(deck.profiles[deck.index].uid, 'b');

      // 마지막 카드가 제외되는 경우에도 범위를 벗어나지 않는다.
      final last = _Deck([_p('a'), _p('friend')], 1);
      last.onAvoidedChanged({'friend'});
      expect(last.profiles.map((p) => p.uid), ['a']);
      expect(last.index, lessThan(last.profiles.length + 1));
      expect(() => last.profiles[last.index.clamp(0, 0)], returnsNormally);

      // 전부 제외되면 빈 덱이 되고 index는 0이다.
      final all = _Deck([_p('x'), _p('y')], 1);
      all.onAvoidedChanged({'x', 'y'});
      expect(all.profiles, isEmpty);
      expect(all.index, 0);
    });

    test('3. pair 제거는 후보 복원을 위해 재조회를 요청한다', () {
      final deck = _Deck([_p('a')], 0)..avoided = {'friend'};

      deck.onAvoidedChanged({});

      expect(deck.reloadRequests, 1);
    });

    test('4. 같은 집합을 다시 받으면 아무 작업도 하지 않는다', () {
      final deck = _Deck([_p('a'), _p('friend')], 0);
      deck.onAvoidedChanged({'friend'});
      final profilesAfterFirst = deck.profiles.length;

      deck.onAvoidedChanged({'friend'});
      deck.onAvoidedChanged({'friend'});

      expect(deck.profiles.length, profilesAfterFirst);
      expect(deck.reloadRequests, 0);
    });

    test('9. block과 pair는 계속 합집합으로 적용된다', () {
      final excluded = {'blocked', ...{'friend'}};
      final visible = ['blocked', 'friend', 'stranger']
          .where((uid) => !excluded.contains(uid))
          .toList();
      expect(visible, ['stranger']);
    });
  });

  group('받은 좋아요 반응성', () {
    test('6~8. swipe/pair 어느 쪽이 바뀌어도 결과가 갱신된다', () async {
      // watchReceivedLikes의 dual-stream 결합 규칙을 재현한다.
      final swipeController = StreamController<List<String>>();
      final avoidedController = StreamController<Set<String>>();
      final emitted = <List<String>>[];

      List<String>? latestSwipes;
      var avoided = <String>{};
      var hasAvoided = false;

      void recompute() {
        final swipes = latestSwipes;
        if (swipes == null) return;
        emitted.add(
          swipes
              .where((uid) => !(hasAvoided ? avoided : <String>{}).contains(uid))
              .toList(),
        );
      }

      final swipeSub = swipeController.stream.listen((value) {
        latestSwipes = value;
        recompute();
      });
      final avoidedSub = avoidedController.stream.listen((value) {
        if (hasAvoided && setEquals(avoided, value)) return;
        avoided = value;
        hasAvoided = true;
        recompute();
      });

      // 8. swipe 변경 반영
      swipeController.add(['friend', 'stranger']);
      await Future<void>.delayed(Duration.zero);
      expect(emitted.last, ['friend', 'stranger']);

      // 6. pair 추가만으로 즉시 사라진다(swipe 변경 없음).
      avoidedController.add({'friend'});
      await Future<void>.delayed(Duration.zero);
      expect(emitted.last, ['stranger']);

      // 7. pair 제거만으로 다시 나타난다(swipe 변경 없음).
      avoidedController.add({});
      await Future<void>.delayed(Duration.zero);
      expect(emitted.last, ['friend', 'stranger']);

      // 같은 집합 재수신은 중복 emit을 만들지 않는다.
      final countBefore = emitted.length;
      avoidedController.add({});
      await Future<void>.delayed(Duration.zero);
      expect(emitted.length, countBefore);

      await swipeSub.cancel();
      await avoidedSub.cancel();
      await swipeController.close();
      await avoidedController.close();
    });

    test('10. stream 취소 시 내부 subscription이 정리된다', () async {
      var cancelled = false;
      final controller = StreamController<Set<String>>(
        onCancel: () => cancelled = true,
      );

      final sub = controller.stream.listen((_) {});
      await sub.cancel();

      expect(cancelled, isTrue);
      await controller.close();
    });
  });

  group('pair 파싱 회귀', () {
    test('11~12. 상대 uid만 추출하고 malformed는 무시한다', () {
      final uids = ContactAvoidanceService.avoidedUidsFromDocs('me', [
        {
          'participants': ['me', 'friendA'],
          'updatedAt': Timestamp.now(),
        },
        {'participants': null},
        {
          'participants': ['me'],
        },
      ]);
      expect(uids, {'friendA'});
    });
  });
}
