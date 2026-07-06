/// 입력값 검증 유틸.
///
/// 왜 따로 빼나:
/// - 이메일/전화번호 검증 로직을 화면마다 복사하면 규칙이 제각각이 된다.
/// - 순수 함수로 모아두면 테스트하기 쉽고 재사용된다.
///
/// TextFormField의 validator는 "에러 메시지(String) 또는 null"을 반환하는 규약이라
/// 아래 함수들도 통과 시 null, 실패 시 한국어 에러 메시지를 돌려준다.
class Validators {
  Validators._();

  /// 이메일 형식 검증.
  static String? email(String? value) {
    if (value == null || value.trim().isEmpty) {
      return '이메일을 입력해주세요.';
    }
    // 완벽한 RFC 규격은 아니지만 일반적인 케이스를 거르는 실용적 정규식.
    final regex = RegExp(r'^[\w.+-]+@[\w-]+\.[\w.-]+$');
    if (!regex.hasMatch(value.trim())) {
      return '올바른 이메일 형식이 아닙니다.';
    }
    return null;
  }

  /// 한국 휴대폰 번호 검증(하이픈 유무 모두 허용).
  ///
  /// 전화 로그인 흐름에서 입력을 거르는 용도. 실제 인증코드 발송 전에 한 번 검증한다.
  static String? phone(String? value) {
    if (value == null || value.trim().isEmpty) {
      return '전화번호를 입력해주세요.';
    }
    // 숫자만 남겨 길이/접두를 검사한다.
    final digits = value.replaceAll(RegExp(r'\D'), '');
    final regex = RegExp(r'^01[016789]\d{7,8}$');
    if (!regex.hasMatch(digits)) {
      return '올바른 휴대폰 번호가 아닙니다.';
    }
    return null;
  }

  /// 비밀번호 검증: 최소 6자(Firebase 기본 정책).
  static String? password(String? value) {
    if (value == null || value.isEmpty) {
      return '비밀번호를 입력해주세요.';
    }
    if (value.length < 6) {
      return '비밀번호는 6자 이상이어야 합니다.';
    }
    return null;
  }

  /// 빈 값 검사용 범용 검증기.
  static String? required(String? value, {String fieldName = '값'}) {
    if (value == null || value.trim().isEmpty) {
      return '$fieldName을(를) 입력해주세요.';
    }
    return null;
  }

  /// 이름 검증: 2자 이상, 공백만으로 이루어지면 안 됨.
  static String? name(String? value) {
    if (value == null || value.trim().isEmpty) {
      return '이름을 입력해주세요.';
    }
    if (value.trim().length < 2) {
      return '이름은 2자 이상이어야 합니다.';
    }
    return null;
  }
}
