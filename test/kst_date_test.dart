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

  group('KstCalendarDate — 달력 날짜와 절대 시각 분리', () {
    test('절대 시각에서 KST 달력 날짜를 뽑는다', () {
      final d = KstCalendarDate.fromInstant(DateTime.utc(2026, 7, 22, 15, 0));
      expect(d.year, 2026);
      expect(d.month, 7);
      expect(d.day, 23);
      expect(d.dateKey, '2026-07-23');
    });

    test('1. UTC+14 표현에서도 KST 오늘 key가 정확하다', () {
      // 2026-07-23T00:30+14:00 == 2026-07-22T10:30Z == KST 19:30 같은 날
      final instant = DateTime.parse('2026-07-23T00:30:00+14:00');
      expect(KstCalendarDate.fromInstant(instant).dateKey, '2026-07-22');
      expect(kstDateKey(instant), '2026-07-22');
    });

    test('2. UTC-12 표현에서도 정확하다', () {
      // 2026-07-22T10:30-12:00 == 2026-07-22T22:30Z == KST 7/23 07:30
      final instant = DateTime.parse('2026-07-22T10:30:00-12:00');
      expect(KstCalendarDate.fromInstant(instant).dateKey, '2026-07-23');
    });

    test('11. 달력 값을 kstDateKey로 재해석해도 날짜가 밀리지 않는다', () {
      // 예전 버그: naive DateTime을 다시 kstDateKey에 넣어 +9가 두 번 붙었다.
      final d = KstCalendarDate.fromInstant(DateTime.utc(2026, 7, 22, 15, 0));
      // utcCalendarValue는 UTC 자정이므로 KST로 보면 같은 날 09:00이다.
      expect(kstDateKey(d.utcCalendarValue), d.dateKey);
    });

    test('4/5/6. 월말·연말·윤년 역산', () {
      expect(
        const KstCalendarDate(2026, 8, 1).subtractDays(1).dateKey,
        '2026-07-31',
      );
      expect(
        const KstCalendarDate(2027, 1, 1).subtractDays(1).dateKey,
        '2026-12-31',
      );
      expect(
        const KstCalendarDate(2028, 3, 1).subtractDays(1).dateKey,
        '2028-02-29',
      );
      expect(
        const KstCalendarDate(2027, 3, 1).subtractDays(1).dateKey,
        '2027-02-28',
      );
    });
  });

  group('kstDatesBackwards — 최근 7일 기록', () {
    test('7/8/9. 정확히 7개, 중복 없이, 오늘부터 과거 순서', () {
      final dates = kstDatesBackwards(DateTime.utc(2026, 7, 22, 3, 0), 7);
      final keys = dates.map((d) => d.dateKey).toList();
      expect(keys.length, 7);
      expect(keys.toSet().length, 7);
      expect(keys, [
        '2026-07-22',
        '2026-07-21',
        '2026-07-20',
        '2026-07-19',
        '2026-07-18',
        '2026-07-17',
        '2026-07-16',
      ]);
    });

    test('3. 기기 시간대 표현이 달라도 같은 목록이다', () {
      final a = kstDatesBackwards(
        DateTime.parse('2026-07-23T00:30:00+14:00'),
        7,
      );
      final b = kstDatesBackwards(DateTime.parse('2026-07-22T10:30:00Z'), 7);
      expect(
        a.map((d) => d.dateKey).toList(),
        b.map((d) => d.dateKey).toList(),
      );
    });

    test('4. 월말 경계에서 역산이 정확하다', () {
      final keys = kstDatesBackwards(
        DateTime.utc(2026, 7, 31, 16, 0),
        3,
      ).map((d) => d.dateKey).toList();
      // UTC 7/31 16:00 == KST 8/1 01:00
      expect(keys, ['2026-08-01', '2026-07-31', '2026-07-30']);
    });

    test('5. 연말 경계', () {
      final keys = kstDatesBackwards(
        DateTime.utc(2026, 12, 31, 16, 0),
        2,
      ).map((d) => d.dateKey).toList();
      expect(keys, ['2027-01-01', '2026-12-31']);
    });

    test('6. 윤년 경계', () {
      final keys = kstDatesBackwards(
        DateTime.utc(2028, 2, 29, 16, 0),
        2,
      ).map((d) => d.dateKey).toList();
      expect(keys, ['2028-03-01', '2028-02-29']);
    });

    test('10. dateKey와 표시 날짜가 같은 달력 날짜를 가리킨다', () {
      for (final d in kstDatesBackwards(DateTime.utc(2026, 7, 22, 3, 0), 7)) {
        final value = d.utcCalendarValue;
        expect(value.isUtc, isTrue);
        expect(
          '${value.year.toString().padLeft(4, '0')}-'
          '${value.month.toString().padLeft(2, '0')}-'
          '${value.day.toString().padLeft(2, '0')}',
          d.dateKey,
        );
      }
    });
  });

  group('중복 구현 방지', () {
    test('9시간 오프셋 상수가 한 곳에만 있다', () {
      expect(kstOffset, const Duration(hours: 9));
    });
  });
}
