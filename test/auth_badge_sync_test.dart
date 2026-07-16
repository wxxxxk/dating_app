import 'dart:io';

import 'package:dating_app/models/user_profile.dart';
import 'package:dating_app/services/auth/auth_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AuthService.syncAuthVerificationBadges', () {
    test('서버 응답을 VerificationStatus로 파싱한다', () async {
      var calls = 0;
      final service = AuthService(
        authBadgeSyncCaller: () async {
          calls += 1;
          return {
            'verifications': {'email': true, 'phone': false, 'photo': false},
            'changed': true,
          };
        },
      );

      final result = await service.syncAuthVerificationBadges();

      expect(calls, 1);
      expect(result, isA<VerificationStatus>());
      expect(result.email, isTrue);
      expect(result.phone, isFalse);
      expect(result.photo, isFalse);
    });

    test('malformed response는 AuthFailure로 안전 처리한다', () async {
      final service = AuthService(
        authBadgeSyncCaller: () async {
          return {
            'verifications': {'email': true, 'phone': 'yes', 'photo': false},
          };
        },
      );

      expect(service.syncAuthVerificationBadges(), throwsA(isA<AuthFailure>()));
    });

    test('wrapper는 uid나 verification 값을 인자로 받지 않는다', () async {
      final service = AuthService(
        authBadgeSyncCaller: () async {
          return {
            'verifications': {'email': false, 'phone': false, 'photo': false},
          };
        },
      );

      final result = await service.syncAuthVerificationBadges();

      expect(result.hasAny, isFalse);
    });
  });

  group('client badge write boundary', () {
    test('직접 verification Firestore write API가 제거되어 있다', () {
      final source = File(
        'lib/services/database/firestore_service.dart',
      ).readAsStringSync();

      expect(source.contains('updateUserVerifications'), isFalse);
      expect(
        source.contains("'verifications': verifications.toFirestore()"),
        isFalse,
      );
    });

    test('전화 인증 완료 경로는 서버 sync 결과를 기다린다', () {
      final source = File(
        'lib/features/home/home_screen.dart',
      ).readAsStringSync();

      expect(source.contains('syncAuthVerificationBadges'), isTrue);
      expect(source.contains('copyWith(phone: true)'), isFalse);
      expect(source.contains('updateUserVerifications'), isFalse);
    });
  });
}
