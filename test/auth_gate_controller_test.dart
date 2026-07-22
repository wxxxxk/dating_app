import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dating_app/features/auth/auth_gate_controller.dart';
import 'package:dating_app/models/user_profile.dart';

/// 인증 상태를 직접 조작할 수 있는 가짜. FirebaseAuth를 쓰지 않는다.
class FakeGateAuth extends ChangeNotifier implements AuthGateAuth {
  FakeGateAuth({bool initializing = true, String? uid})
    : _initializing = initializing,
      _uid = uid;

  // ignore_for_file: prefer_initializing_formals
  bool _initializing;
  String? _uid;

  @override
  bool get initializing => _initializing;

  @override
  String? get currentUid => _uid;

  void emit({required bool initializing, String? uid}) {
    _initializing = initializing;
    _uid = uid;
    notifyListeners();
  }

  void signIn(String uid) => emit(initializing: false, uid: uid);
  void signOut() => emit(initializing: false, uid: null);
}

UserProfile profileFor(String uid) => UserProfile(
  uid: uid,
  displayName: '테스터',
  birthDate: DateTime(1994, 5, 12),
  gender: 'female',
  bio: '소개',
  createdAt: DateTime(2026, 1, 1),
  updatedAt: DateTime(2026, 1, 1),
);

void main() {
  group('AuthGateController', () {
    test('1. 인증 초기화 중에는 loading이다', () {
      final auth = FakeGateAuth();
      final controller = AuthGateController(
        auth: auth,
        loadProfile: (_) async => fail('초기화 중에는 조회하지 않아야 한다'),
        runSideEffects: (_, _) async {},
      )..start();

      expect(controller.status, AuthGateStatus.loading);
      controller.dispose();
    });

    test('2. 로그아웃 상태면 unauthenticated다', () {
      final auth = FakeGateAuth(initializing: false);
      final controller = AuthGateController(
        auth: auth,
        loadProfile: (_) async => fail('비로그인 상태에서는 조회하지 않아야 한다'),
        runSideEffects: (_, _) async {},
      )..start();

      expect(controller.status, AuthGateStatus.unauthenticated);
      controller.dispose();
    });

    test('3. 프로필이 있으면 authenticated다', () async {
      final auth = FakeGateAuth(initializing: false, uid: 'u1');
      final controller = AuthGateController(
        auth: auth,
        loadProfile: (uid) async => profileFor(uid),
        runSideEffects: (_, _) async {},
      )..start();

      await pumpEventQueue();
      expect(controller.status, AuthGateStatus.authenticated);
      expect(controller.errorCategory, isNull);
      controller.dispose();
    });

    test('4. 프로필이 없으면 onboarding이다', () async {
      final auth = FakeGateAuth(initializing: false, uid: 'u1');
      final controller = AuthGateController(
        auth: auth,
        loadProfile: (_) async => null,
        runSideEffects: (_, _) async {},
      )..start();

      await pumpEventQueue();
      expect(controller.status, AuthGateStatus.onboarding);
      controller.dispose();
    });

    test('5. network 오류는 recoverableError다', () async {
      final auth = FakeGateAuth(initializing: false, uid: 'u1');
      final controller = AuthGateController(
        auth: auth,
        loadProfile: (_) async => throw const SocketException('offline'),
        runSideEffects: (_, _) async {},
      )..start();

      await pumpEventQueue();
      expect(controller.status, AuthGateStatus.recoverableError);
      expect(controller.errorCategory, ProfileErrorCategory.network);
      controller.dispose();
    });

    test('6. permission-denied는 recoverableError다', () async {
      final auth = FakeGateAuth(initializing: false, uid: 'u1');
      final controller = AuthGateController(
        auth: auth,
        loadProfile: (_) async =>
            throw FirebaseException(plugin: 'cloud_firestore', code: 'permission-denied'),
        runSideEffects: (_, _) async {},
      )..start();

      await pumpEventQueue();
      expect(controller.status, AuthGateStatus.recoverableError);
      expect(controller.errorCategory, ProfileErrorCategory.permissionDenied);
      controller.dispose();
    });

    test('7. 조회 실패는 절대 onboarding이 되지 않는다', () async {
      for (final error in <Object>[
        const SocketException('offline'),
        FirebaseException(plugin: 'cloud_firestore', code: 'permission-denied'),
        FirebaseException(plugin: 'cloud_firestore', code: 'unavailable'),
        StateError('unexpected'),
      ]) {
        final auth = FakeGateAuth(initializing: false, uid: 'u1');
        final controller = AuthGateController(
          auth: auth,
          loadProfile: (_) async => throw error,
          runSideEffects: (_, _) async {},
        )..start();

        await pumpEventQueue();
        expect(controller.status, isNot(AuthGateStatus.onboarding),
            reason: '$error');
        expect(controller.status, AuthGateStatus.recoverableError);
        controller.dispose();
      }
    });

    test('8. retry가 성공하면 authenticated로 회복한다', () async {
      final auth = FakeGateAuth(initializing: false, uid: 'u1');
      var attempt = 0;
      final controller = AuthGateController(
        auth: auth,
        loadProfile: (uid) async {
          attempt += 1;
          if (attempt == 1) throw const SocketException('offline');
          return profileFor(uid);
        },
        runSideEffects: (_, _) async {},
      )..start();

      await pumpEventQueue();
      expect(controller.status, AuthGateStatus.recoverableError);

      await controller.retry();
      await pumpEventQueue();
      expect(controller.status, AuthGateStatus.authenticated);
      expect(controller.errorCategory, isNull);
      controller.dispose();
    });

    test('9. retry 결과가 프로필 없음이면 onboarding이다', () async {
      final auth = FakeGateAuth(initializing: false, uid: 'u1');
      var attempt = 0;
      final controller = AuthGateController(
        auth: auth,
        loadProfile: (_) async {
          attempt += 1;
          if (attempt == 1) throw const SocketException('offline');
          return null;
        },
        runSideEffects: (_, _) async {},
      )..start();

      await pumpEventQueue();
      expect(controller.status, AuthGateStatus.recoverableError);

      await controller.retry();
      await pumpEventQueue();
      expect(controller.status, AuthGateStatus.onboarding);
      controller.dispose();
    });

    test('10~12. 부가 작업이 실패해도 authenticated를 유지한다', () async {
      final auth = FakeGateAuth(initializing: false, uid: 'u1');
      var sideEffectRan = false;
      final controller = AuthGateController(
        auth: auth,
        loadProfile: (uid) async => profileFor(uid),
        runSideEffects: (_, _) async {
          sideEffectRan = true;
          // reloadUser·배지 동기화·알림 등록 중 무엇이 터지든 같은 경로다.
          throw Exception('reloadUser/badge/notification failed');
        },
      )..start();

      await pumpEventQueue();
      expect(sideEffectRan, isTrue);
      expect(controller.status, AuthGateStatus.authenticated);
      expect(controller.errorCategory, isNull);
      controller.dispose();
    });

    test('13. 이전 uid의 늦은 응답이 새 사용자 상태를 덮어쓰지 않는다', () async {
      final auth = FakeGateAuth(initializing: false, uid: 'old');
      final gate = Completer<void>();
      final controller = AuthGateController(
        auth: auth,
        loadProfile: (uid) async {
          if (uid == 'old') {
            await gate.future;
            return profileFor(uid); // old에는 프로필이 있다
          }
          return null; // new 사용자는 온보딩 대상
        },
        runSideEffects: (_, _) async {},
      )..start();

      // old 조회가 진행 중인 상태에서 계정이 바뀐다.
      auth.signIn('new');
      await pumpEventQueue();
      expect(controller.status, AuthGateStatus.onboarding);

      // 이제서야 old 응답이 도착한다. 무시되어야 한다.
      gate.complete();
      await pumpEventQueue();
      expect(controller.status, AuthGateStatus.onboarding);
      controller.dispose();
    });

    test('14. 로그아웃 후 도착한 응답은 무시된다', () async {
      final auth = FakeGateAuth(initializing: false, uid: 'u1');
      final gate = Completer<void>();
      final controller = AuthGateController(
        auth: auth,
        loadProfile: (uid) async {
          await gate.future;
          return profileFor(uid);
        },
        runSideEffects: (_, _) async {},
      )..start();

      auth.signOut();
      await pumpEventQueue();
      expect(controller.status, AuthGateStatus.unauthenticated);

      gate.complete();
      await pumpEventQueue();
      expect(controller.status, AuthGateStatus.unauthenticated);
      controller.dispose();
    });

    test('15. 같은 uid로 중복 조회하지 않는다', () async {
      final auth = FakeGateAuth(initializing: false, uid: 'u1');
      var calls = 0;
      final gate = Completer<void>();
      final controller = AuthGateController(
        auth: auth,
        loadProfile: (uid) async {
          calls += 1;
          await gate.future;
          return profileFor(uid);
        },
        runSideEffects: (_, _) async {},
      )..start();

      // 조회 진행 중에 같은 uid로 알림이 반복돼도 재요청하지 않는다.
      auth.signIn('u1');
      auth.signIn('u1');
      await controller.retry();
      expect(calls, 1);

      gate.complete();
      await pumpEventQueue();
      expect(controller.status, AuthGateStatus.authenticated);

      // 확정된 뒤 같은 uid 알림이 와도 다시 조회하지 않는다.
      auth.signIn('u1');
      await pumpEventQueue();
      expect(calls, 1);
      controller.dispose();
    });

    test('온보딩 완료를 알리면 재조회 없이 authenticated가 된다', () async {
      final auth = FakeGateAuth(initializing: false, uid: 'u1');
      var calls = 0;
      final controller = AuthGateController(
        auth: auth,
        loadProfile: (_) async {
          calls += 1;
          return null;
        },
        runSideEffects: (_, _) async {},
      )..start();

      await pumpEventQueue();
      expect(controller.status, AuthGateStatus.onboarding);

      controller.markProfileCreated('u1');
      await pumpEventQueue();
      expect(controller.status, AuthGateStatus.authenticated);
      expect(calls, 1);
      controller.dispose();
    });

    test('오류 분류가 raw 코드를 노출하지 않고 축약된다', () {
      expect(
        categorizeProfileError(
          FirebaseException(plugin: 'cloud_firestore', code: 'unavailable'),
        ),
        ProfileErrorCategory.unavailable,
      );
      expect(
        categorizeProfileError(
          FirebaseException(plugin: 'cloud_firestore', code: 'deadline-exceeded'),
        ),
        ProfileErrorCategory.network,
      );
      expect(categorizeProfileError(StateError('x')), ProfileErrorCategory.unknown);
    });
  });
}
