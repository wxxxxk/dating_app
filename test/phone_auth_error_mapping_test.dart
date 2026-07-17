import 'dart:io';

import 'package:dating_app/services/auth/auth_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Phone Auth 오류 매핑 회귀 테스트 (Phase 0-D-7A).
///
/// 배경: 실기기 전화 인증에서 operation-not-allowed(status 17006, SMS 허용
/// 지역 미설정)가 발생했으나, 공용 매핑이 이를 항상 "이메일/비밀번호 로그인이
/// 활성화되지 않았습니다"로 변환해 잘못된 안내가 나갔다.
///
/// 원문 Firebase message 문자열은 사용하지 않고 code만으로 문맥을 구분한다.
void main() {
  group('operation-not-allowed 문맥 구분', () {
    test('email/password 문맥은 기존 이메일 안내를 유지한다', () {
      final message = authFailureMessageForCode('operation-not-allowed');

      expect(message, contains('이메일/비밀번호 로그인이 활성화되지 않았습니다'));
      expect(message, contains('Sign-in method'));
    });

    test('phone 문맥은 출시용 재시도 안내로 바뀌고 콘솔 설정을 노출하지 않는다', () {
      final message = authFailureMessageForCode(
        'operation-not-allowed',
        phone: true,
      );

      expect(message, contains('현재 전화 인증을 사용할 수 없습니다'));
      expect(message, contains('잠시 후 다시 시도'));
      // 전화 문맥에서 이메일/비밀번호를 언급하면 안 된다.
      expect(message.contains('이메일'), isFalse);
      expect(message.contains('비밀번호'), isFalse);
      // 일반 사용자가 바꿀 수 없는 콘솔/설정 지시를 노출하지 않는다.
      expect(message.contains('SMS'), isFalse);
      expect(message.contains('제공업체'), isFalse);
      expect(message.contains('설정'), isFalse);
    });
  });

  group('invalid-credential 문맥 구분', () {
    test('email 문맥은 기존 이메일/비밀번호 안내를 유지한다', () {
      final message = authFailureMessageForCode('invalid-credential');

      expect(message, '이메일 또는 비밀번호가 올바르지 않습니다.');
    });

    test('phone 문맥은 이메일/비밀번호를 언급하지 않는다', () {
      final message = authFailureMessageForCode(
        'invalid-credential',
        phone: true,
      );

      expect(message, contains('인증 정보가 유효하지 않습니다'));
      expect(message, contains('인증코드를 다시'));
      expect(message.contains('이메일'), isFalse);
      expect(message.contains('비밀번호'), isFalse);
    });
  });

  group('phone 문맥 주요 코드', () {
    test('invalid-phone-number', () {
      final message = authFailureMessageForCode(
        'invalid-phone-number',
        phone: true,
      );
      expect(message, contains('전화번호 형식'));
    });

    test('invalid-verification-code', () {
      final message = authFailureMessageForCode(
        'invalid-verification-code',
        phone: true,
      );
      expect(message, contains('인증번호'));
    });

    test('too-many-requests는 전화 문맥에서 인증 요청 안내로 보강된다', () {
      final message = authFailureMessageForCode(
        'too-many-requests',
        phone: true,
      );
      expect(message, contains('인증 요청이 너무 많습니다'));
      // 이메일 로그인 문구가 아니어야 한다.
      expect(message.contains('로그인 시도'), isFalse);
    });

    test('network-request-failed', () {
      final message = authFailureMessageForCode(
        'network-request-failed',
        phone: true,
      );
      expect(message, contains('네트워크'));
    });

    test('quota-exceeded', () {
      final message = authFailureMessageForCode('quota-exceeded', phone: true);
      expect(message, contains('SMS 발송 한도'));
    });

    test('session-expired는 인증코드 재요청 안내로 보강된다', () {
      final message = authFailureMessageForCode('session-expired', phone: true);
      expect(message, contains('인증코드를 다시'));
    });

    test('invalid-app-credential / app-not-authorized 안내가 존재한다', () {
      expect(
        authFailureMessageForCode('invalid-app-credential', phone: true),
        contains('앱 인증'),
      );
      expect(
        authFailureMessageForCode('app-not-authorized', phone: true),
        contains('권한'),
      );
    });
  });

  group('안전성', () {
    test('알 수 없는 코드는 문맥과 무관하게 안전한 기본 문구로 폴백한다', () {
      const unknown = 'some-internal-error-xyz';
      expect(authFailureMessageForCode(unknown), '인증에 실패했습니다. 잠시 후 다시 시도해주세요.');
      expect(
        authFailureMessageForCode(unknown, phone: true),
        '인증에 실패했습니다. 잠시 후 다시 시도해주세요.',
      );
    });

    test('매핑 결과에 raw Firebase code나 PII 형태가 노출되지 않는다', () {
      // 대표 코드들에 대해 원본 code 문자열이나 status 숫자가 그대로 노출되지
      // 않는지 확인한다(사용자 문구는 항상 한국어 안내여야 한다).
      const codes = [
        'operation-not-allowed',
        'invalid-phone-number',
        'invalid-verification-code',
        'too-many-requests',
        'quota-exceeded',
        'network-request-failed',
        'invalid-app-credential',
        'app-not-authorized',
        'session-expired',
      ];
      for (final code in codes) {
        final message = authFailureMessageForCode(code, phone: true);
        expect(message.contains(code), isFalse, reason: 'code 노출: $code');
        expect(message.contains('17006'), isFalse);
      }
    });
  });

  group('소스 레벨 가드', () {
    final source = File(
      'lib/services/auth/auth_service.dart',
    ).readAsStringSync();

    test('debug 로그에 e.message 문자열 보간이 존재하지 않는다', () {
      // Firebase 원문 message(전화번호/이메일 등 포함 가능)를 로그로 남기면
      // 안 된다. debugPrint는 문자열 보간을 사용하므로, 어떤 로그에서도
      // `${e.message}` 보간이 나타나지 않아야 한다.
      // (라인 273의 onFailed(e.message)는 AuthFailure의 사용자 문구를 콜백에
      //  전달하는 것으로, 로그 노출이 아니라 검사 대상이 아니다.)
      expect(source.contains(r'${e.message}'), isFalse);
      // 어떤 로그 문자열에도 message 보간 종료 토큰이 남지 않아야 한다.
      // (사용자 문구 전달인 라인 273의 `e.message)`는 `.message}`가 아니므로
      //  이 검사에 걸리지 않는다.)
      expect(source.contains('.message}'), isFalse);
    });

    test('phone 실패 흐름이 local phone 배지를 true로 설정하는 경로를 만들지 않는다', () {
      // 배지의 phone 값은 서버 sync가 판정한다. 클라이언트가 임의로 true로
      // 바꾸는 경로(copyWith/verifications map write)가 있으면 안 된다.
      // (오류 문맥 플래그 `_firebaseAuthMessage(e, phone: true)`는 배지 쓰기가
      //  아니므로 여기서 검사 대상이 아니다.)
      expect(source.contains('copyWith(phone: true'), isFalse);
      expect(source.contains("'phone': true"), isFalse);
    });
  });
}
