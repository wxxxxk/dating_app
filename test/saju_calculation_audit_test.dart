import 'dart:convert';
import 'dart:io';

import 'package:dating_app/models/fortune/saju_birth_input.dart';
import 'package:dating_app/models/fortune/saju_convention.dart';
import 'package:dating_app/services/fortune/fortune_calculator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saju/saju.dart' as bazi;

// Phase 5-1 — 사주 계산 정확도 기준선.
//
// 한국천문연구원(KASI) 음양력 변환 공식값으로 만든 golden fixture와 현재
// 계산기를 대조한다. 네트워크를 쓰지 않는다 — fixture에 기대값이 고정돼 있다.
//
// fixture 입력은 전부 합성 데이터다. 실패 메시지에는 case id와 어긋난 field만
// 남기고 생년월일 전체를 늘어놓지 않는다.

/// fixture는 공개 저장소에 들어가므로, 실제 사용자 데이터가 섞여 들어오는 것을
/// 구조적으로 막는다.
const Set<String> _allowedInputKeys = {
  'calendarType',
  'year',
  'month',
  'day',
  'birthTime',
  'timeZone',
  'lunarLeapMonth',
};

Map<String, dynamic> _loadFixture() {
  final file = File('test/fixtures/saju_golden_v1.json');
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

/// 60갑자에서 천간(첫 글자)만 뽑는다. 예: '병인' -> '병'
String _stemOf(String ganji) => ganji.substring(0, 1);

/// 율리우스 적일. 앱이 의존하는 `saju` 패키지의 `jdnFromDate`와 **같은 표준
/// 알고리즘**을 테스트 쪽에 독립적으로 둔 것이다(패키지는 이 함수를 public으로
/// export하지 않는다). KASI 공식 SOLC_JD와 대조해 알고리즘 자체를 검증한다.
int _jdnFromDate(int year, int month, int day) {
  var y = year;
  var m = month;
  if (m <= 2) {
    y -= 1;
    m += 12;
  }
  final a = y ~/ 100;
  final b = 2 - a + (a ~/ 4);
  final jd =
      (365.25 * (y + 4716)).floor() +
      (30.6001 * (m + 1)).floor() +
      day +
      b -
      1524.5;
  return jd.round();
}

/// 앱(및 서버)이 쓰는 일주 index 규칙: `(jdn - 11) mod 60`.
int _dayPillarIndex(int jdn) => (((jdn - 11) % 60) + 60) % 60;

void main() {
  final fixture = _loadFixture();
  final cases = (fixture['cases'] as List).cast<Map<String, dynamic>>();

  group('fixture 자체 계약', () {
    test('schema/convention 버전이 고정돼 있다', () {
      expect(fixture['schemaVersion'], 1);
      expect(fixture['conventionVersion'], currentConvention.version);
    });

    test('case id는 고유하고 40건 이상이다', () {
      final ids = cases.map((c) => c['id'] as String).toList();
      expect(ids.length, greaterThanOrEqualTo(40));
      expect(ids.toSet().length, ids.length, reason: '중복 case id가 있다');
    });

    test('입력에 허용된 key만 있다 — 개인정보 유입 방지', () {
      for (final c in cases) {
        final input = (c['input'] as Map).cast<String, dynamic>();
        final unexpected = input.keys.toSet().difference(_allowedInputKeys);
        expect(
          unexpected,
          isEmpty,
          reason: 'case=${c['id']} 허용되지 않은 입력 key=$unexpected',
        );
      }
    });

    test('출처 metadata가 남아 있다', () {
      final source = (fixture['metadata'] as Map)['source'] as Map;
      expect(source['provider'], contains('한국천문연구원'));
      expect(source['retrievedAt'], isNotEmpty);
    });

    test('음력 case는 윤달 플래그를 반드시 갖는다', () {
      for (final c in cases) {
        final input = SajuBirthInput.fromMap(
          (c['input'] as Map).cast<String, dynamic>(),
        );
        if (input.calendarType != SajuCalendarType.lunar) continue;
        expect(
          input.isWellFormed,
          isTrue,
          reason: 'case=${c['id']} 음력인데 lunarLeapMonth가 없다',
        );
      }
    });
  });

  group('율리우스 적일 — KASI 공식값 대조', () {
    test('양력 case의 JDN이 KASI SOLC_JD와 일치한다', () {
      final mismatches = <String>[];
      for (final c in cases) {
        if (c['expected'] == null) continue;
        final expected = (c['expected'] as Map).cast<String, dynamic>();
        final julianDay = expected['julianDay'];
        if (julianDay == null) continue;

        // 어떤 case든 expected.solarDate가 정규화된 양력 날짜다.
        final parts = (expected['solarDate'] as String).split('-');
        final actual = _jdnFromDate(
          int.parse(parts[0]),
          int.parse(parts[1]),
          int.parse(parts[2]),
        );
        if (actual != julianDay) {
          mismatches.add(
            'case=${c['id']} field=julianDay expected=$julianDay actual=$actual',
          );
        }
      }
      expect(mismatches, isEmpty, reason: mismatches.join('\n'));
    });

    test('일주 index 규칙 (jdn-11) mod 60이 KASI 일진과 맞물린다', () {
      // 앱과 Cloud Functions가 각각 같은 상수 11을 쓴다. 이 anchor가 맞는지를
      // 공식 일진으로 직접 확인한다.
      final mismatches = <String>[];
      for (final c in cases) {
        if (c['expected'] == null) continue;
        final expected = (c['expected'] as Map).cast<String, dynamic>();
        final dayGanji = expected['dayGanji'];
        final julianDay = expected['julianDay'];
        if (dayGanji == null || julianDay == null) continue;

        final pillar = bazi.Pillar.fromIndex(_dayPillarIndex(julianDay as int));
        final actual = '${pillar.stem.korean}${pillar.branch.korean}';
        final want = (dayGanji as Map)['korean'] as String;
        if (actual != want) {
          mismatches.add(
            'case=${c['id']} field=dayPillarAnchor expected=$want actual=$actual',
          );
        }
      }
      expect(mismatches, isEmpty, reason: mismatches.join('\n'));
    });
  });

  group('일주(日柱) — KASI 일진 대조', () {
    test('dayPillarFromDate가 KASI 일진과 60갑자까지 일치한다', () {
      final mismatches = <String>[];
      for (final c in cases) {
        if (c['expected'] == null) continue;
        final expected = (c['expected'] as Map).cast<String, dynamic>();
        final dayGanji = expected['dayGanji'];
        if (dayGanji == null) continue;

        final parts = (expected['solarDate'] as String).split('-');
        final pillar = bazi.dayPillarFromDate(
          int.parse(parts[0]),
          int.parse(parts[1]),
          int.parse(parts[2]),
        );
        final actual = '${pillar.stem.korean}${pillar.branch.korean}';
        final want = (dayGanji as Map)['korean'] as String;
        if (actual != want) {
          mismatches.add(
            'case=${c['id']} field=dayPillar expected=$want actual=$actual',
          );
        }
      }
      expect(mismatches, isEmpty, reason: mismatches.join('\n'));
    });

    test('FortuneCalculator.getSaju의 일간이 KASI 일진의 천간과 일치한다', () {
      final mismatches = <String>[];
      for (final c in cases) {
        if (c['expected'] == null) continue;
        final expected = (c['expected'] as Map).cast<String, dynamic>();
        final dayGanji = expected['dayGanji'];
        if (dayGanji == null) continue;

        final parts = (expected['solarDate'] as String).split('-');
        final saju = FortuneCalculator.getSaju(
          DateTime(
            int.parse(parts[0]),
            int.parse(parts[1]),
            int.parse(parts[2]),
          ),
        );
        final want = _stemOf((dayGanji as Map)['korean'] as String);
        if (saju.dayMaster != want) {
          mismatches.add(
            'case=${c['id']} field=dayMaster expected=$want actual=${saju.dayMaster}',
          );
        }
      }
      expect(mismatches, isEmpty, reason: mismatches.join('\n'));
    });
  });

  group('음력 변환 — 현재 미지원 확인', () {
    test('음력 case의 양력 대응일은 fixture에 고정돼 있다', () {
      final lunarCases = cases.where(
        (c) => c['input']['calendarType'] == 'lunar' && c['expected'] != null,
      );
      expect(lunarCases, isNotEmpty);
      for (final c in lunarCases) {
        final expected = (c['expected'] as Map).cast<String, dynamic>();
        expect(
          expected['solarDate'],
          matches(r'^\d{4}-\d{2}-\d{2}$'),
          reason: 'case=${c['id']}',
        );
      }
    });

    test('같은 음력 날짜라도 평달/윤달은 다른 양력 날짜다', () {
      final byBase = <String, Set<String>>{};
      for (final c in cases) {
        if (c['input']['calendarType'] != 'lunar' || c['expected'] == null) {
          continue;
        }
        final input = c['input'] as Map;
        final key = '${input['year']}-${input['month']}-${input['day']}';
        byBase
            .putIfAbsent(key, () => <String>{})
            .add((c['expected'] as Map)['solarDate'] as String);
      }
      final paired = byBase.entries.where((e) => e.value.length > 1);
      expect(
        paired,
        isNotEmpty,
        reason: '평달/윤달 구분을 검증할 짝이 fixture에 없다',
      );
    });

    test('현재 앱은 음력 입력 경로가 없다 — 계산기는 양력만 받는다', () {
      // FortuneCalculator의 공개 API는 DateTime(양력)만 받는다.
      // 음력 입력을 양력으로 변환하는 코드는 앱·서버 어디에도 없다.
      expect(currentConvention.calendarConversion, CalendarConversion.solar);
      expect(currentConvention.lunarLeapMonthRequired, isFalse);
    });

    test('음력 → 양력 → 음력 round trip이 입력과 일치한다', () {
      // KASI /life/lunc(음력→양력)로 얻은 양력일을 다시 /life/solc로 되돌린
      // 결과가 expected.lunarDate다. 입력과 어긋나면 fixture 수집이 틀린 것이다.
      final mismatches = <String>[];
      for (final c in cases) {
        if (c['input']['calendarType'] != 'lunar' || c['expected'] == null) {
          continue;
        }
        final input = (c['input'] as Map).cast<String, dynamic>();
        final back =
            ((c['expected'] as Map)['lunarDate'] as Map).cast<String, dynamic>();
        final want =
            '${input['year']}-${input['month']}-${input['day']}-'
            '${input['lunarLeapMonth']}';
        final actual =
            '${back['year']}-${back['month']}-${back['day']}-'
            '${back['isLeapMonth']}';
        if (want != actual) {
          mismatches.add(
            'case=${c['id']} field=lunarRoundTrip expected=$want actual=$actual',
          );
        }
      }
      expect(mismatches, isEmpty, reason: mismatches.join('\n'));
    });

    test('윤달 플래그가 빠진 음력 입력은 계약 위반이다', () {
      // 윤달 여부를 모르면 음력 날짜가 하루가 아니라 한 달 단위로 어긋난다.
      // Phase 5-2에서 음력 입력을 받게 되면 이 검증이 서버 진입점에 있어야 한다.
      const missingLeapFlag = SajuBirthInput(
        calendarType: SajuCalendarType.lunar,
        year: 1995,
        month: 8,
        day: 15,
        birthTime: null,
        timeZone: 'Asia/Seoul',
        lunarLeapMonth: null,
      );
      expect(missingLeapFlag.isWellFormed, isFalse);
    });
  });

  group('시간대 정책', () {
    test('fixture 입력은 전부 Asia/Seoul이다 — 해외 출생은 현재 미지원', () {
      // 출생지·timezone 입력 필드가 앱에 없다. 테스트만으로 해외 출생을
      // 지원하는 것처럼 꾸미지 않는다.
      for (final c in cases) {
        final input = SajuBirthInput.fromMap(
          (c['input'] as Map).cast<String, dynamic>(),
        );
        expect(input.timeZone, 'Asia/Seoul', reason: 'case=${c['id']}');
      }
      expect(currentConvention.timezonePolicy, TimezonePolicy.asiaSeoul);
      expect(recommendedConvention.timezonePolicy, TimezonePolicy.asiaSeoul);
    });
  });

  group('기대값 출처 계약', () {
    test('연주·월주·시주 기대값은 fixture에 존재하지 않는다', () {
      // KASI 세차(LUNC_PRCN)는 설날 경계, 월건(LUNC_WLGN)은 음력 월 기준이라
      // 입춘·절기 기준인 사주 연주/월주와 다르다. 잘못 끌어다 쓰지 못하도록
      // 아예 필드를 두지 않고, 미확보 사실을 metadata에 남긴다.
      for (final c in cases) {
        final expectedMap = c['expected'];
        if (expectedMap == null) continue;
        final keys = (expectedMap as Map).keys.toSet();
        expect(
          keys.intersection({'yearPillar', 'monthPillar', 'hourPillar'}),
          isEmpty,
          reason: 'case=${c['id']} 근거 없는 기대값이 들어왔다',
        );
      }

      final unavailable =
          (fixture['metadata'] as Map)['unavailableExpectations'] as List;
      expect(unavailable.length, greaterThanOrEqualTo(3));
    });
  });

  group('출생시간 precision', () {
    test('birthTime이 없으면 precision은 dateOnly다', () {
      for (final c in cases) {
        final input = SajuBirthInput.fromMap(
          (c['input'] as Map).cast<String, dynamic>(),
        );
        if (input.birthTime != null) continue;
        expect(
          input.precision,
          SajuInputPrecision.dateOnly,
          reason: 'case=${c['id']}',
        );
      }
    });

    test('현재 계산기는 출생시간을 전혀 반영하지 않는다', () {
      // 같은 날짜면 시각이 달라도 결과가 같다 — 시주가 없다는 뜻이며,
      // 동시에 자시(23:00) 경계를 적용할 수 없다는 뜻이기도 하다.
      final hourCases = cases
          .where((c) => c['conventionSensitive'] == true)
          .toList();
      expect(hourCases, isNotEmpty);

      final results = <String>{};
      for (final c in hourCases) {
        final input = c['input'] as Map;
        final saju = FortuneCalculator.getSaju(
          DateTime(input['year'] as int, input['month'] as int, input['day'] as int),
        );
        results.add(saju.dayMaster);
      }
      expect(
        results.length,
        1,
        reason: '출생시간을 반영하지 않으므로 같은 날짜는 항상 같은 일간이어야 한다',
      );
    });

    test('자정 convention에서는 23시대도 같은 날 일주를 쓴다', () {
      final mismatches = <String>[];
      for (final c in cases.where((c) => c['conventionSensitive'] == true)) {
        final expected = (c['expected'] as Map).cast<String, dynamic>();
        final byConvention =
            (expected['dayGanjiByConvention'] as Map).cast<String, dynamic>();
        final parts = (expected['solarDate'] as String).split('-');
        final pillar = bazi.dayPillarFromDate(
          int.parse(parts[0]),
          int.parse(parts[1]),
          int.parse(parts[2]),
        );
        final actual = '${pillar.stem.korean}${pillar.branch.korean}';
        final want = (byConvention['midnight'] as Map)['korean'] as String;
        if (actual != want) {
          mismatches.add(
            'case=${c['id']} field=dayPillar.midnight expected=$want actual=$actual',
          );
        }
      }
      expect(mismatches, isEmpty, reason: mismatches.join('\n'));
    });

    test('23시 이후 case는 두 convention의 결과가 실제로 갈린다', () {
      final split = cases.where((c) {
        if (c['conventionSensitive'] != true) return false;
        final byConvention =
            ((c['expected'] as Map)['dayGanjiByConvention'] as Map);
        return (byConvention['midnight'] as Map)['korean'] !=
            (byConvention['zi23'] as Map)['korean'];
      });
      expect(
        split.length,
        greaterThanOrEqualTo(2),
        reason: '일주 경계 convention 결정이 실제로 결과를 바꾼다는 근거 case가 필요하다',
      );
    });
  });

  group('실재하지 않는 날짜', () {
    test('invalid_solar case는 그레고리력에 없는 날짜다', () {
      final invalid = cases.where(
        (c) => c['expectedError'] == 'invalid_solar_date',
      );
      expect(invalid, isNotEmpty);
      for (final c in invalid) {
        final input = SajuBirthInput.fromMap(
          (c['input'] as Map).cast<String, dynamic>(),
        );
        expect(
          input.isRealSolarDate,
          isFalse,
          reason: 'case=${c['id']} 실재하는 날짜로 판정됐다',
        );
      }
    });

    test('유효한 양력 case는 모두 실재하는 날짜다', () {
      for (final c in cases) {
        if (c['expectedError'] != null) continue;
        final input = SajuBirthInput.fromMap(
          (c['input'] as Map).cast<String, dynamic>(),
        );
        if (input.calendarType != SajuCalendarType.solar) continue;
        expect(input.isRealSolarDate, isTrue, reason: 'case=${c['id']}');
      }
    });

    test('현재 계산기는 실재하지 않는 날짜를 조용히 넘긴다', () {
      // DateTime(1993, 2, 29)는 1993-03-01로 굴러간다 — 예외가 아니라 다른
      // 날짜의 사주가 나온다. 입력 검증은 Phase 5-2에서 서버가 맡아야 한다.
      final rolled = DateTime(1993, 2, 29);
      expect(rolled.month, 3);
      expect(rolled.day, 1);
      expect(
        () => FortuneCalculator.getSaju(rolled),
        returnsNormally,
        reason: '검증 없이 계산된다는 사실 자체를 기록한다',
      );
    });
  });

  group('convention 계약', () {
    test('현재 convention이 코드 감사 결과와 일치한다', () {
      expect(currentConvention.version, 1);
      expect(currentConvention.timezonePolicy, TimezonePolicy.asiaSeoul);
      expect(currentConvention.yearPillarBoundary, YearPillarBoundary.ipchun);
      expect(
        currentConvention.monthPillarBoundary,
        MonthPillarBoundary.solarTerms,
      );
      expect(currentConvention.dayPillarBoundary, DayPillarBoundary.midnight);
      expect(currentConvention.solarTimeCorrection, SolarTimeCorrection.disabled);
    });

    test('출생시간 미수집인데 고정 시각을 대입하고 있다 — 알려진 결함', () {
      // getOhaengBalance가 정오 12:00을 대입한다. 절기 경계일에는 연/월주가
      // 실제와 달라질 수 있다. Phase 5-2에서 estimateNotAllowed로 옮긴다.
      expect(
        currentConvention.unknownBirthTimePolicy,
        UnknownBirthTimePolicy.substituteFixedTime,
      );
      expect(
        recommendedConvention.unknownBirthTimePolicy,
        UnknownBirthTimePolicy.estimateNotAllowed,
      );
    });

    test('오행 밸런스는 6글자(년·월·일) 기반이라 합이 1이다', () {
      final balance = FortuneCalculator.getOhaengBalance(DateTime(1995, 2, 4));
      final sum = balance.values.fold<double>(0, (a, b) => a + b);
      expect(sum, closeTo(1.0, 1e-9));
      // 시주가 빠져 있으므로 8글자 사주가 아니다.
      expect(balance.length, 5);
    });
  });
}
