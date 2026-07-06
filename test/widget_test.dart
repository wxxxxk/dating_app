// 기본 카운터 위젯 테스트는 이 프로젝트와 맞지 않아 제거하고,
// Firebase 없이도 돌아가는 순수 로직(Validators) 테스트로 대체했다.
//
// 왜 위젯 테스트 대신 이걸 두나:
// - 메인 화면들은 Firebase 초기화가 전제라 단위 테스트가 무겁다.
// - 검증 로직 같은 순수 함수부터 테스트 습관을 들이는 게 학습에 좋다.

import 'package:dating_app/core/utils/validators.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Validators.email', () {
    test('올바른 이메일은 null을 반환한다', () {
      expect(Validators.email('test@example.com'), isNull);
    });

    test('형식이 틀리면 에러 메시지를 반환한다', () {
      expect(Validators.email('not-an-email'), isNotNull);
    });

    test('빈 값이면 에러 메시지를 반환한다', () {
      expect(Validators.email(''), isNotNull);
    });
  });

  group('Validators.phone', () {
    test('하이픈이 있어도 통과한다', () {
      expect(Validators.phone('010-1234-5678'), isNull);
    });

    test('자릿수가 모자라면 에러를 반환한다', () {
      expect(Validators.phone('010123'), isNotNull);
    });
  });
}
