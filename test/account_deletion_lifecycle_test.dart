import 'dart:async';
import 'dart:io';

import 'package:dating_app/features/home/account_deletion_screen.dart';
import 'package:dating_app/services/auth/account_deletion_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeDeletionHarness {
  AccountDeletionUserSnapshot? snapshot = const AccountDeletionUserSnapshot(
    uid: 'user-1',
    email: 'user@example.com',
    phoneNumber: '+821012345678',
    providerIds: {'password'},
  );
  int passwordReauthCalls = 0;
  int googleReauthCalls = 0;
  int phoneSendCalls = 0;
  int phoneConfirmCalls = 0;
  int tokenRefreshCalls = 0;
  int deleteCalls = 0;
  int signOutCalls = 0;
  final List<String> calls = [];
  Object? passwordFailure;
  Object? googleFailure;
  Object? phoneFailure;
  Object? tokenFailure;
  Object? deleteFailure;
  Completer<void>? passwordCompleter;
  Map<String, Object?>? lastDeletePayload;

  AccountDeletionService service() => AccountDeletionService(
    snapshotReader: () => snapshot,
    passwordReauthenticator: (password) async {
      passwordReauthCalls += 1;
      calls.add('password');
      await passwordCompleter?.future;
      final failure = passwordFailure;
      if (failure != null) throw failure;
    },
    googleReauthenticator: () async {
      googleReauthCalls += 1;
      calls.add('google');
      final failure = googleFailure;
      if (failure != null) throw failure;
    },
    phoneCodeSender: () async {
      phoneSendCalls += 1;
      return 'verification-id';
    },
    phoneCodeConfirmer: (verificationId, smsCode) async {
      phoneConfirmCalls += 1;
      calls.add('phone');
      final failure = phoneFailure;
      if (failure != null) throw failure;
    },
    tokenRefresher: (expectedUid) async {
      tokenRefreshCalls += 1;
      calls.add('token');
      final failure = tokenFailure;
      if (failure != null) throw failure;
      final current = snapshot;
      if (current == null || current.uid != expectedUid) {
        throw const AccountDeletionFailure('현재 계정으로 다시 인증해주세요.');
      }
    },
    deleteCallable: (payload) async {
      deleteCalls += 1;
      calls.add('delete');
      lastDeletePayload = payload;
      final failure = deleteFailure;
      if (failure != null) throw failure;
      return {'status': 'completed'};
    },
    signOutRunner: () async {
      signOutCalls += 1;
      snapshot = null;
    },
  );
}

Future<void> _pumpDeletionScreen(
  WidgetTester tester,
  _FakeDeletionHarness harness, {
  VoidCallback? onDeleted,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: AccountDeletionScreen(
        service: harness.service(),
        onDeleted: onDeleted,
      ),
    ),
  );
}

Future<void> acceptFirstConfirmation(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('start-account-deletion')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('계속'));
  await tester.pumpAndSettle();
}

void main() {
  test('회원 탈퇴 진입점과 payload 계약은 targetUid를 보내지 않는다', () async {
    final homeSource = File(
      'lib/features/home/home_screen.dart',
    ).readAsStringSync();
    final serviceSource = File(
      'lib/services/auth/account_deletion_service.dart',
    ).readAsStringSync();
    final harness = _FakeDeletionHarness();

    await harness.service().deleteMyAccount();

    expect(homeSource, contains("Key('open-account-deletion')"));
    expect(homeSource, contains('회원 탈퇴'));
    expect(harness.lastDeletePayload, {
      'confirmation': deleteMyAccountConfirmation,
    });
    expect(harness.lastDeletePayload!.containsKey('targetUid'), isFalse);
    expect(serviceSource, isNot(contains('debugPrint')));
    expect(serviceSource, isNot(contains('print(')));
  });

  testWidgets('첫 confirmation 취소는 재인증과 callable을 실행하지 않는다', (tester) async {
    final harness = _FakeDeletionHarness();
    await _pumpDeletionScreen(tester, harness);

    await tester.tap(find.byKey(const Key('start-account-deletion')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();

    expect(harness.passwordReauthCalls, 0);
    expect(harness.deleteCalls, 0);
  });

  testWidgets('최종 confirmation 취소는 callable을 실행하지 않는다', (tester) async {
    final harness = _FakeDeletionHarness();
    await _pumpDeletionScreen(tester, harness);
    await acceptFirstConfirmation(tester);
    await tester.enterText(
      find.byKey(const Key('account-deletion-password')),
      'secret',
    );

    await tester.tap(find.byKey(const Key('confirm-account-deletion')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();

    expect(harness.passwordReauthCalls, 1);
    expect(harness.tokenRefreshCalls, 1);
    expect(harness.deleteCalls, 0);
  });

  testWidgets('password 재인증 성공 후 token refresh 다음 callable 1회와 로그아웃을 수행한다', (
    tester,
  ) async {
    final harness = _FakeDeletionHarness();
    var deleted = false;
    await _pumpDeletionScreen(tester, harness, onDeleted: () => deleted = true);
    await acceptFirstConfirmation(tester);
    await tester.enterText(
      find.byKey(const Key('account-deletion-password')),
      'secret',
    );

    await tester.tap(find.byKey(const Key('confirm-account-deletion')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '회원 탈퇴'));
    await tester.pumpAndSettle();

    expect(harness.passwordReauthCalls, 1);
    expect(harness.tokenRefreshCalls, 1);
    expect(harness.deleteCalls, 1);
    expect(harness.calls, ['password', 'token', 'delete']);
    expect(harness.signOutCalls, 1);
    expect(deleted, isTrue);
  });

  testWidgets('password 재인증 실패는 callable을 실행하지 않는다', (tester) async {
    final harness = _FakeDeletionHarness()
      ..passwordFailure = const AccountDeletionFailure('재인증에 실패했습니다.');
    await _pumpDeletionScreen(tester, harness);
    await acceptFirstConfirmation(tester);
    await tester.enterText(
      find.byKey(const Key('account-deletion-password')),
      'wrong',
    );

    await tester.tap(find.byKey(const Key('confirm-account-deletion')));
    await tester.pumpAndSettle();

    expect(harness.passwordReauthCalls, 1);
    expect(harness.tokenRefreshCalls, 0);
    expect(harness.deleteCalls, 0);
  });

  testWidgets('Google 재인증 성공은 token refresh 후 호출하고 다른 계정은 차단한다', (
    tester,
  ) async {
    final harness = _FakeDeletionHarness()
      ..snapshot = const AccountDeletionUserSnapshot(
        uid: 'user-1',
        providerIds: {'google.com'},
      );
    await _pumpDeletionScreen(tester, harness);
    await acceptFirstConfirmation(tester);

    await tester.tap(find.byKey(const Key('confirm-account-deletion')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '회원 탈퇴'));
    await tester.pumpAndSettle();

    expect(harness.googleReauthCalls, 1);
    expect(harness.tokenRefreshCalls, 1);
    expect(harness.deleteCalls, 1);
    expect(harness.calls, ['google', 'token', 'delete']);

    final blocked = _FakeDeletionHarness()
      ..snapshot = const AccountDeletionUserSnapshot(
        uid: 'user-1',
        providerIds: {'google.com'},
      )
      ..googleFailure = const AccountDeletionFailure('현재 계정으로 다시 인증해주세요.');
    await _pumpDeletionScreen(tester, blocked);
    await acceptFirstConfirmation(tester);
    await tester.tap(find.byKey(const Key('confirm-account-deletion')));
    await tester.pumpAndSettle();

    expect(blocked.googleReauthCalls, 1);
    expect(blocked.tokenRefreshCalls, 0);
    expect(blocked.deleteCalls, 0);
  });

  testWidgets('phone OTP 성공은 token refresh 후 호출하고 실패는 callable 0이다', (
    tester,
  ) async {
    final harness = _FakeDeletionHarness()
      ..snapshot = const AccountDeletionUserSnapshot(
        uid: 'user-1',
        phoneNumber: '+821012345678',
        providerIds: {'phone'},
      );
    await _pumpDeletionScreen(tester, harness);
    await acceptFirstConfirmation(tester);

    await tester.tap(find.byKey(const Key('send-account-deletion-phone-code')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('account-deletion-sms-code')),
      '123456',
    );
    await tester.tap(find.byKey(const Key('confirm-account-deletion')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '회원 탈퇴'));
    await tester.pumpAndSettle();

    expect(harness.phoneSendCalls, 1);
    expect(harness.phoneConfirmCalls, 1);
    expect(harness.tokenRefreshCalls, 1);
    expect(harness.deleteCalls, 1);
    expect(harness.calls, ['phone', 'token', 'delete']);

    final failed = _FakeDeletionHarness()
      ..snapshot = const AccountDeletionUserSnapshot(
        uid: 'user-1',
        phoneNumber: '+821012345678',
        providerIds: {'phone'},
      )
      ..phoneFailure = const AccountDeletionFailure('재인증에 실패했습니다.');
    await _pumpDeletionScreen(tester, failed);
    await acceptFirstConfirmation(tester);
    await tester.tap(find.byKey(const Key('send-account-deletion-phone-code')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('account-deletion-sms-code')),
      '000000',
    );
    await tester.tap(find.byKey(const Key('confirm-account-deletion')));
    await tester.pumpAndSettle();

    expect(failed.phoneConfirmCalls, 1);
    expect(failed.tokenRefreshCalls, 0);
    expect(failed.deleteCalls, 0);
  });

  testWidgets('token refresh 실패는 callable을 실행하지 않는다', (tester) async {
    final harness = _FakeDeletionHarness()
      ..tokenFailure = const AccountDeletionFailure('재인증 상태를 확인하지 못했습니다.');
    await _pumpDeletionScreen(tester, harness);
    await acceptFirstConfirmation(tester);
    await tester.enterText(
      find.byKey(const Key('account-deletion-password')),
      'secret',
    );

    await tester.tap(find.byKey(const Key('confirm-account-deletion')));
    await tester.pumpAndSettle();

    expect(harness.passwordReauthCalls, 1);
    expect(harness.tokenRefreshCalls, 1);
    expect(harness.deleteCalls, 0);
    expect(harness.calls, ['password', 'token']);
  });

  testWidgets('재인증 후 current user UID가 바뀌면 callable을 실행하지 않는다', (tester) async {
    final harness = _FakeDeletionHarness()
      ..passwordCompleter = Completer<void>();
    await _pumpDeletionScreen(tester, harness);
    await acceptFirstConfirmation(tester);
    await tester.enterText(
      find.byKey(const Key('account-deletion-password')),
      'secret',
    );

    await tester.tap(find.byKey(const Key('confirm-account-deletion')));
    await tester.pump();
    harness.snapshot = const AccountDeletionUserSnapshot(
      uid: 'other-user',
      providerIds: {'password'},
    );
    harness.passwordCompleter!.complete();
    await tester.pumpAndSettle();

    expect(harness.passwordReauthCalls, 1);
    expect(harness.tokenRefreshCalls, 1);
    expect(harness.deleteCalls, 0);
  });

  testWidgets('unsupported provider만 있으면 탈퇴 실행을 차단한다', (tester) async {
    final harness = _FakeDeletionHarness()
      ..snapshot = const AccountDeletionUserSnapshot(
        uid: 'user-1',
        providerIds: {'anonymous'},
      );
    await _pumpDeletionScreen(tester, harness);

    expect(find.textContaining('지원되는 재인증 수단을 찾을 수 없어'), findsOneWidget);
    await tester.tap(find.byKey(const Key('start-account-deletion')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('계속'));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('confirm-account-deletion')),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('로딩 중 중복 탭은 재인증과 callable을 중복 실행하지 않는다', (tester) async {
    final harness = _FakeDeletionHarness()
      ..passwordCompleter = Completer<void>();
    await _pumpDeletionScreen(tester, harness);
    await acceptFirstConfirmation(tester);
    await tester.enterText(
      find.byKey(const Key('account-deletion-password')),
      'secret',
    );

    await tester.tap(find.byKey(const Key('confirm-account-deletion')));
    await tester.tap(find.byKey(const Key('confirm-account-deletion')));
    await tester.pump();
    expect(harness.passwordReauthCalls, 1);
    expect(harness.tokenRefreshCalls, 0);
    expect(harness.deleteCalls, 0);

    harness.passwordCompleter!.complete();
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '회원 탈퇴'));
    await tester.pumpAndSettle();
    expect(harness.tokenRefreshCalls, 1);
    expect(harness.deleteCalls, 1);
  });

  testWidgets('timeout 계열 실패를 삭제 성공으로 임의 처리하지 않는다', (tester) async {
    final harness = _FakeDeletionHarness()
      ..deleteFailure = const AccountDeletionFailure(
        '계정 삭제를 완료하지 못했습니다. 잠시 후 다시 시도해주세요.',
      );
    await _pumpDeletionScreen(tester, harness);
    await acceptFirstConfirmation(tester);
    await tester.enterText(
      find.byKey(const Key('account-deletion-password')),
      'secret',
    );

    await tester.tap(find.byKey(const Key('confirm-account-deletion')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '회원 탈퇴'));
    await tester.pumpAndSettle();

    expect(harness.deleteCalls, 1);
    expect(harness.tokenRefreshCalls, 1);
    expect(harness.signOutCalls, 0);
  });

  testWidgets('서버가 이미 Auth를 삭제해 current user가 사라진 경우 로컬 정리 성공', (tester) async {
    final harness = _FakeDeletionHarness()
      ..deleteFailure = const AccountDeletionFailure(
        '계정 삭제를 완료하지 못했습니다. 잠시 후 다시 시도해주세요.',
      );
    var deleted = false;
    await _pumpDeletionScreen(tester, harness, onDeleted: () => deleted = true);
    await acceptFirstConfirmation(tester);
    await tester.enterText(
      find.byKey(const Key('account-deletion-password')),
      'secret',
    );

    await tester.tap(find.byKey(const Key('confirm-account-deletion')));
    await tester.pumpAndSettle();
    harness.snapshot = null;
    await tester.tap(find.widgetWithText(FilledButton, '회원 탈퇴'));
    await tester.pumpAndSettle();

    expect(harness.signOutCalls, 1);
    expect(harness.tokenRefreshCalls, 1);
    expect(deleted, isTrue);
  });
}
