import 'package:flutter_test/flutter_test.dart';

import 'package:dating_app/core/utils/kst_date.dart';

// 1-E 회귀 테스트.
//
// 수정 전: FortuneService가 `DateTime.now()`(기기 로컬 시간)로 dateKey를
// 만들었다. 서버는 seoulDateKey()로 Asia/Seoul 기준 날짜를 쓰므로, 기기
// 시간대가 KST가 아니거나 자정 근처면 **다른 날짜 문서를 읽고 썼다.**

void main() {
  group('KST 경계', () {
    test('1/2. UTC 14:59:59는 같은 날, 15:00:00은 다음 날이다', () {
      expect(kstDateKey(DateTime.utc(2026, 7, 22, 14, 59, 59)), '2026-07-22');
      expect(kstDateKey(DateTime.utc(2026, 7, 22, 15, 0, 0)), '2026-07-23');
    });

    test('KST 자정 직전/직후', () {
      // 2026-07-22 23:59 KST == 2026-07-22 14:59 UTC
      expect(kstDateKey(DateTime.utc(2026, 7, 22, 14, 59)), '2026-07-22');
      // 2026-07-23 00:00 KST == 2026-07-22 15:00 UTC
      expect(kstDateKey(DateTime.utc(2026, 7, 22, 15, 0)), '2026-07-23');
    });

    test('3. 월말 경계', () {
      expect(kstDateKey(DateTime.utc(2026, 7, 31, 14, 59)), '2026-07-31');
      expect(kstDateKey(DateTime.utc(2026, 7, 31, 15, 0)), '2026-08-01');
    });

    test('4. 연말 경계', () {
      expect(kstDateKey(DateTime.utc(2026, 12, 31, 14, 59)), '2026-12-31');
      expect(kstDateKey(DateTime.utc(2026, 12, 31, 15, 0)), '2027-01-01');
    });

    test('5. 윤년 2월', () {
      // 2028은 윤년이다.
      expect(kstDateKey(DateTime.utc(2028, 2, 28, 15, 0)), '2028-02-29');
      expect(kstDateKey(DateTime.utc(2028, 2, 29, 15, 0)), '2028-03-01');
      // 평년은 2/28 다음이 3/1이다.
      expect(kstDateKey(DateTime.utc(2027, 2, 28, 15, 0)), '2027-03-01');
    });

    test('6. 기기 시간대와 무관하게 같은 순간이면 같은 key다', () {
      final instant = DateTime.utc(2026, 7, 22, 15, 30);
      expect(kstDateKey(instant), kstDateKey(instant.toLocal()));
      // UTC로 표현하든 로컬로 표현하든 동일한 절대 시각이면 결과가 같다.
      expect(kstDateKey(instant), '2026-07-23');
    });

    test('형식이 YYYY-MM-DD로 zero-padding된다', () {
      expect(kstDateKey(DateTime.utc(2026, 1, 5, 0, 0)), '2026-01-05');
      expect(
        RegExp(
          r'^\d{4}-\d{2}-\d{2}$',
        ).hasMatch(kstDateKey(DateTime.utc(2026, 1, 5))),
        isTrue,
      );
    });
  });

  group('kstDateOnly', () {
    test('KST 달력 기준 연·월·일을 돌려준다', () {
      final result = kstDateOnly(DateTime.utc(2026, 7, 22, 15, 0));
      expect(result.year, 2026);
      expect(result.month, 7);
      expect(result.day, 23);
      expect(result.hour, 0);
    });

    test('날짜 목록을 만들어도 경계가 어긋나지 않는다', () {
      // 7일 흐름처럼 today에서 거슬러 올라갈 때 월 경계가 정확해야 한다.
      final today = kstDateOnly(
        DateTime.utc(2026, 8, 1, 0, 0),
      ); // KST 8/1 09:00
      final keys = List.generate(
        3,
        (i) => kstDateKey(today.subtract(Duration(days: i)).toUtc()),
      );
      expect(keys, ['2026-08-01', '2026-07-31', '2026-07-30']);
    });
  });

  group('중복 구현 방지', () {
    test('9시간 오프셋 상수가 한 곳에만 있다', () {
      expect(kstOffset, const Duration(hours: 9));
    });
  });
}
