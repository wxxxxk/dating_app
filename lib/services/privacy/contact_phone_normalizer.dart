/// 지인 피하기(Phase 3-4)용 전화번호 정규화·해시 유틸.
///
/// **연락처 이름·사진·이메일은 다루지 않는다.** 전화번호를 E.164 형태로
/// 정규화한 뒤 SHA-256 digest만 만들고, 원문은 반환값 어디에도 남기지 않는다.
/// 서버는 이 digest를 다시 secret으로 HMAC해 저장한다(digest 자체는 미저장).
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

const int _minE164Digits = 8;
const int _maxE164Digits = 15;

/// 전화번호를 `+국가번호숫자` 형태로 정규화한다(순수 함수).
///
/// 한국 번호 중심 MVP다. 정규화할 수 없는 값(내선·문자 포함·자릿수 이상)은
/// null을 반환해 동기화 대상에서 제외한다.
String? normalizeContactPhoneNumber(
  String raw, {
  String defaultCountryCode = '82',
}) {
  // 1. 공백·하이픈·괄호·점 등 표기 문자를 제거한다.
  var value = raw.replaceAll(RegExp(r'[\s\-().]'), '');
  if (value.isEmpty) return null;

  // 2. '+'는 맨 앞 하나만 허용한다(내선 표기 '1234,56' 등은 아래에서 걸러진다).
  final hasPlus = value.startsWith('+');
  if (hasPlus) value = value.substring(1);

  // 숫자 외 문자가 남아 있으면(내선 안내, 한글 메모 등) 정규화하지 않는다.
  if (!RegExp(r'^[0-9]+$').hasMatch(value)) return null;

  final String digits;
  if (hasPlus) {
    // 3. +82... 같은 국제 표기는 그대로 사용한다.
    digits = value;
  } else if (value.startsWith(defaultCountryCode) &&
      value.length > defaultCountryCode.length + 1 &&
      !value.startsWith('0')) {
    // 4. 82... → +82...
    digits = value;
  } else if (value.startsWith('0')) {
    // 5. 국내 표기 0XX... → 앞의 0을 떼고 국가번호를 붙인다.
    final national = value.substring(1);
    if (national.isEmpty) return null;
    digits = '$defaultCountryCode$national';
  } else {
    // 국가번호도 0도 없는 짧은 번호(114, 1234 등)는 대상이 아니다.
    return null;
  }

  // 6. 국가번호 포함 8~15자리만 허용한다.
  if (digits.length < _minE164Digits || digits.length > _maxE164Digits) {
    return null;
  }
  return '+$digits';
}

/// 정규화된 전화번호의 SHA-256 digest(lowercase hex 64자).
String contactPhoneDigest(String normalizedPhone) {
  return sha256.convert(utf8.encode(normalizedPhone)).toString();
}

/// 원문 전화번호 목록 → 중복 제거된 digest 목록(순수 함수).
///
/// 반환값에는 원문이나 연락처 이름이 포함되지 않는다. 입력 순서를 유지해
/// 결과가 결정적이도록 LinkedHashSet 의미를 사용한다.
Set<String> contactPhoneDigests(Iterable<String> rawNumbers) {
  final digests = <String>{};
  for (final raw in rawNumbers) {
    final normalized = normalizeContactPhoneNumber(raw);
    if (normalized == null) continue;
    digests.add(contactPhoneDigest(normalized));
  }
  return digests;
}

/// digest 형식 검증(서버 rules/callable과 동일한 계약).
bool isValidContactDigest(String value) {
  return RegExp(r'^[0-9a-f]{64}$').hasMatch(value);
}
