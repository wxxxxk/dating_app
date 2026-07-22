import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dating_app/features/auth/auth_gate_error_view.dart';

void main() {
  group('AuthGateErrorView', () {
    testWidgets('안내 문구와 두 개의 출구를 보여준다', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: AuthGateErrorView(onRetry: () {}, onSignOut: () {}),
        ),
      );

      expect(find.byKey(const Key('auth-gate-error')), findsOneWidget);
      expect(find.text('프로필을 불러오지 못했어요.'), findsOneWidget);
      expect(find.text('인터넷 연결을 확인하고 다시 시도해 주세요.'), findsOneWidget);
      expect(find.byKey(const Key('auth-gate-retry-button')), findsOneWidget);
      expect(find.byKey(const Key('auth-gate-sign-out-button')), findsOneWidget);
    });

    testWidgets('재시도와 로그아웃 콜백이 호출된다', (tester) async {
      var retries = 0;
      var signOuts = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: AuthGateErrorView(
            onRetry: () => retries += 1,
            onSignOut: () => signOuts += 1,
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('auth-gate-retry-button')));
      await tester.pump();
      expect(retries, 1);

      await tester.tap(find.byKey(const Key('auth-gate-sign-out-button')));
      await tester.pump();
      expect(signOuts, 1);
    });

    testWidgets('busy 상태에서는 두 버튼이 모두 비활성화된다', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: AuthGateErrorView(
            busy: true,
            onRetry: () => taps += 1,
            onSignOut: () => taps += 1,
          ),
        ),
      );

      await tester.tap(
        find.byKey(const Key('auth-gate-retry-button')),
        warnIfMissed: false,
      );
      await tester.tap(
        find.byKey(const Key('auth-gate-sign-out-button')),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(taps, 0);
    });

    testWidgets('화면에 raw 오류·UID·Firestore 경로를 노출하지 않는다', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: AuthGateErrorView(onRetry: () {}, onSignOut: () {}),
        ),
      );

      final texts = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? '')
          .join(' ');
      for (final forbidden in [
        'permission-denied',
        'FirebaseException',
        'users/',
        'uid',
        '@',
      ]) {
        expect(texts.contains(forbidden), isFalse, reason: forbidden);
      }
    });
  });
}
