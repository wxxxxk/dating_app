// FortuneCalculator는 Firebase 없이 도는 순수 함수라 단위 테스트로 검증하기 좋다.
// 핵심 요구사항: 같은 생년월일이면 항상 같은 결과(결정론적)를 반환해야 한다.

import 'package:dating_app/services/fortune/fortune_calculator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FortuneCalculator.getZodiacSign', () {
    test('같은 날짜는 항상 같은 별자리를 반환한다', () {
      final d = DateTime(1990, 5, 15);
      final a = FortuneCalculator.getZodiacSign(d);
      final b = FortuneCalculator.getZodiacSign(d);
      expect(a.sign, b.sign);
      expect(a.element, b.element);
    });

    test('경계일 앞뒤로 다른 별자리를 반환한다 (황소자리 시작일)', () {
      final before = FortuneCalculator.getZodiacSign(DateTime(1990, 4, 19));
      final onStart = FortuneCalculator.getZodiacSign(DateTime(1990, 4, 20));
      expect(before.sign, '양자리');
      expect(onStart.sign, '황소자리');
    });

    test('1월 1일~19일은 전년도부터 이어지는 염소자리다', () {
      final result = FortuneCalculator.getZodiacSign(DateTime(2000, 1, 1));
      expect(result.sign, '염소자리');
      expect(result.element, '흙');
    });

    test('연말 12월 25일은 염소자리다', () {
      final result = FortuneCalculator.getZodiacSign(DateTime(1995, 12, 25));
      expect(result.sign, '염소자리');
    });
  });

  group('FortuneCalculator.getSaju', () {
    test('같은 날짜는 항상 같은 일간/오행을 반환한다', () {
      final d = DateTime(1990, 5, 15);
      final a = FortuneCalculator.getSaju(d);
      final b = FortuneCalculator.getSaju(d);
      expect(a.dayMaster, b.dayMaster);
      expect(a.element, b.element);
    });

    test('일간은 오행 값 중 하나로 매핑된다', () {
      final result = FortuneCalculator.getSaju(DateTime(1990, 5, 15));
      expect(['목', '화', '토', '금', '수'], contains(result.element));
    });
  });

  group('FortuneCalculator.getOhaengBalance', () {
    test('같은 날짜는 항상 같은 밸런스를 반환한다', () {
      final d = DateTime(1990, 5, 15);
      final a = FortuneCalculator.getOhaengBalance(d);
      final b = FortuneCalculator.getOhaengBalance(d);
      expect(a, b);
    });

    test('다섯 원소 값의 합은 1이다(6글자를 정규화했으므로)', () {
      final balance = FortuneCalculator.getOhaengBalance(DateTime(1990, 5, 15));
      expect(balance.keys.toSet(), ohaengOrder.toSet());
      final sum = balance.values.fold<double>(0, (a, b) => a + b);
      expect(sum, closeTo(1.0, 1e-9));
    });

    test('모든 값은 0~1 사이다', () {
      final balance = FortuneCalculator.getOhaengBalance(DateTime(2000, 1, 1));
      for (final v in balance.values) {
        expect(v, inInclusiveRange(0.0, 1.0));
      }
    });

    test('1996-03-15 신금 일간의 6글자 대표 오행 카운트를 그대로 반영한다', () {
      final saju = FortuneCalculator.getSaju(DateTime(1996, 3, 15));
      final balance = FortuneCalculator.getOhaengBalance(DateTime(1996, 3, 15));

      expect(saju.dayMaster, '신');
      expect(saju.element, '금');
      expect(balance['목'], closeTo(1 / 6, 1e-9));
      expect(balance['화'], closeTo(1 / 6, 1e-9));
      expect(balance['토'], 0);
      expect(balance['금'], closeTo(2 / 6, 1e-9));
      expect(balance['수'], closeTo(2 / 6, 1e-9));
    });
  });

  group('FortuneCalculator.strongestElement / weakestElement', () {
    test('가장 큰 값과 가장 작은 값을 정확히 찾는다', () {
      const balance = {'목': 0.1, '화': 0.5, '토': 0.2, '금': 0.0, '수': 0.2};
      expect(FortuneCalculator.strongestElement(balance).key, '화');
      expect(FortuneCalculator.weakestElement(balance).key, '금');
    });

    test('동점이면 ohaengOrder 순서상 앞선 원소를 결정론적으로 택한다', () {
      const balance = {'목': 0.3, '화': 0.3, '토': 0.2, '금': 0.1, '수': 0.1};
      expect(FortuneCalculator.strongestElement(balance).key, '목');
      expect(FortuneCalculator.weakestElement(balance).key, '금');
    });
  });

  group('FortuneCalculator.nourishingElement', () {
    test('상생 순환(목→화→토→금→수→목)에 따라 생(生)해주는 원소를 반환한다', () {
      expect(FortuneCalculator.nourishingElement('화'), '목');
      expect(FortuneCalculator.nourishingElement('토'), '화');
      expect(FortuneCalculator.nourishingElement('금'), '토');
      expect(FortuneCalculator.nourishingElement('수'), '금');
      expect(FortuneCalculator.nourishingElement('목'), '수');
    });
  });

  group('FortuneCalculator.getCompatibilityHint', () {
    test('같은 생년월일은 편안한 조화 힌트를 반환한다', () {
      final hint = FortuneCalculator.getCompatibilityHint(
        DateTime(1996, 3, 15),
        DateTime(1996, 3, 15),
      );

      expect(hint.level, '조화');
      expect(hint.shortLabel, '편안한 조화');
    });

    test('한쪽 오행이 다른 쪽을 생하면 상생 힌트를 반환한다', () {
      final hint = FortuneCalculator.getCompatibilityHint(
        DateTime(1996, 3, 15), // 신금
        DateTime(2000, 3, 15), // 임수
      );

      expect(hint.level, '상생');
      expect(hint.shortLabel, '상생 흐름');
    });

    test('오행 상극 관계는 보완 힌트를 반환한다', () {
      final hint = FortuneCalculator.getCompatibilityHint(
        DateTime(1996, 3, 15), // 신금
        DateTime(1995, 3, 15), // 을목
      );

      expect(hint.level, '보완');
      expect(hint.shortLabel, '서로 보완');
    });
  });
}
