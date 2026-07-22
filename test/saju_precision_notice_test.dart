import 'package:dating_app/core/theme/app_theme.dart';
import 'package:dating_app/features/fortune/widgets/saju_precision_notice.dart';
import 'package:dating_app/models/fortune_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Phase 5-2A — 정밀도·절기 경계 안내.
//
// "정확하지 않다"는 공포성 경고가 아니라, 어떤 근거를 제외했는지를 전달하는지
// 확인한다.

const _precisionKey = Key('saju-precision-notice');
const _boundaryKey = Key('saju-boundary-uncertainty-notice');

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.binding.setSurfaceSize(const Size(600, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(theme: AppTheme.light, home: Scaffold(body: child)),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('내 사주 정밀도 안내', () {
    testWidgets('출생시간을 알면 확정 문구만 보이고 경계 안내는 없다', (tester) async {
      await _pump(
        tester,
        const SajuPrecisionNotice(hasKnownTime: true, boundaryUncertain: false),
      );
      expect(find.byKey(_precisionKey), findsOneWidget);
      expect(find.byKey(_boundaryKey), findsNothing);
      expect(find.text('생년월일과 태어난 시간을 기준으로 해석했어요.'), findsOneWidget);
      expect(find.text('태어난 시간 추가하기'), findsNothing);
    });

    testWidgets('시간 미상 + 경계 없음이면 기본 문구를 쓴다', (tester) async {
      await _pump(
        tester,
        const SajuPrecisionNotice(hasKnownTime: false, boundaryUncertain: false),
      );
      expect(find.byKey(_precisionKey), findsOneWidget);
      expect(find.byKey(_boundaryKey), findsNothing);
      expect(find.text('태어난 시간 없이 기본 사주를 해석했어요.'), findsOneWidget);
    });

    testWidgets('시간 미상 + 절기 경계면 제외한 근거를 알려준다', (tester) async {
      await _pump(
        tester,
        const SajuPrecisionNotice(hasKnownTime: false, boundaryUncertain: true),
      );
      expect(find.byKey(_boundaryKey), findsOneWidget);
      expect(
        find.text('태어난 시간이 없어 절기 경계에 걸린 일부 항목은 제외하고 해석했어요.'),
        findsOneWidget,
      );
      expect(find.text('시간을 추가하면 더 세밀한 내용을 볼 수 있어요.'), findsOneWidget);
    });

    testWidgets('시간을 알면 경계 안내가 나오지 않는다', (tester) async {
      // 알려진 시각은 절입 전후가 확정되므로 이 조합 자체가 생기지 않아야 한다.
      await _pump(
        tester,
        const SajuPrecisionNotice(hasKnownTime: true, boundaryUncertain: true),
      );
      expect(find.byKey(_boundaryKey), findsNothing);
      expect(find.text('생년월일과 태어난 시간을 기준으로 해석했어요.'), findsOneWidget);
    });

    testWidgets('추가하기 콜백이 있으면 버튼이 보이고 눌린다', (tester) async {
      var taps = 0;
      await _pump(
        tester,
        SajuPrecisionNotice(
          hasKnownTime: false,
          boundaryUncertain: true,
          onAddBirthTime: () => taps += 1,
        ),
      );
      await tester.tap(find.byKey(const Key('saju-add-birth-time')));
      await tester.pumpAndSettle();
      expect(taps, 1);
    });
  });

  group('궁합 정밀도 안내', () {
    testWidgets('둘 다 확정이면 아무것도 표시하지 않는다', (tester) async {
      await _pump(
        tester,
        const MatchPrecisionNotice(
          missingBirthTime: false,
          boundaryUncertain: false,
        ),
      );
      expect(find.byKey(const Key('match-precision-notice')), findsNothing);
    });

    testWidgets('시간만 없으면 기본 궁합 문구를 쓴다', (tester) async {
      await _pump(
        tester,
        const MatchPrecisionNotice(missingBirthTime: true),
      );
      expect(
        find.text('두 사람 중 일부의 출생시간이 없어 기본 궁합으로 해석했어요.'),
        findsOneWidget,
      );
    });

    testWidgets('절기 경계까지 걸리면 확정 가능한 항목만 썼다고 알린다', (tester) async {
      await _pump(
        tester,
        const MatchPrecisionNotice(
          missingBirthTime: true,
          boundaryUncertain: true,
        ),
      );
      expect(
        find.text('두 사람 중 일부의 출생시간이 없어 확정 가능한 항목만으로 궁합을 해석했어요.'),
        findsOneWidget,
      );
    });
  });

  group('FortuneNarrative 경계 metadata 파싱', () {
    test('서버가 보낸 boundaryUncertain을 읽는다', () {
      final narrative = FortuneNarrative.fromMap({
        'characterType': '테스트형',
        'summary': '요약',
        'reasons': <dynamic>[],
        'precision': 'dateOnly',
        'missingBirthTime': true,
        'boundaryUncertain': true,
      });
      expect(narrative.precision, 'dateOnly');
      expect(narrative.missingBirthTime, isTrue);
      expect(narrative.boundaryUncertain, isTrue);
    });

    test('구버전 캐시에는 필드가 없어 false로 안전 처리된다', () {
      final narrative = FortuneNarrative.fromMap({
        'characterType': '테스트형',
        'summary': '요약',
        'reasons': <dynamic>[],
      });
      expect(narrative.precision, isNull);
      expect(narrative.missingBirthTime, isFalse);
      expect(narrative.boundaryUncertain, isFalse);
    });
  });
}
