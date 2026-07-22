import 'package:dating_app/core/theme/app_theme.dart';
import 'package:dating_app/features/fortune/birth_time_completion_screen.dart';
import 'package:dating_app/features/onboarding/basic_info_step.dart';
import 'package:dating_app/models/fortune/birth_profile.dart';
import 'package:dating_app/services/profile/birth_profile_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Phase 5-2 — 출생시간 입력 UX.
//
// 실제 사용자 데이터를 쓰지 않는다. 모든 날짜는 합성 값이다.

const _knownKey = Key('birth-time-known-option');
const _unknownKey = Key('birth-time-unknown-option');
const _pickerKey = Key('birth-time-picker');
const _saveKey = Key('birth-time-save');

Future<void> _setSurface(WidgetTester tester, Size size) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

/// 온보딩 기본정보 스텝을 띄우고, onNext로 넘어온 값을 잡아둔다.
Future<List<BirthProfile>> _pumpBasicInfo(
  WidgetTester tester, {
  Size size = const Size(800, 1400),
}) async {
  final captured = <BirthProfile>[];
  await _setSurface(tester, size);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(
        body: BasicInfoStep(
          onNext:
              ({
                required name,
                required birthDate,
                required birthProfile,
                required gender,
                required bio,
              }) {
                captured.add(birthProfile);
              },
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return captured;
}

/// 이름·생년월일·성별·소개까지 채운다. 출생시간은 채우지 않는다.
Future<void> _fillExceptBirthTime(WidgetTester tester) async {
  await tester.enterText(find.byType(TextFormField).at(0), '지수');
  await tester.tap(find.byType(TextFormField).at(1));
  await tester.pumpAndSettle();
  await tester.tap(find.text('확인'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('여성'));
  await tester.enterText(find.byType(TextFormField).at(2), '천천히 대화해요');
  await tester.pumpAndSettle();
}

Future<void> _tapNext(WidgetTester tester) async {
  await tester.ensureVisible(find.text('다음'));
  await tester.tap(find.text('다음'));
  await tester.pumpAndSettle();
}

void main() {
  group('회원가입 출생시간 입력', () {
    testWidgets('두 선택지가 모두 보이고 기본 선택은 없다', (tester) async {
      await _pumpBasicInfo(tester);
      expect(find.text('태어난 시간'), findsOneWidget);
      expect(find.byKey(_knownKey), findsOneWidget);
      expect(find.byKey(_unknownKey), findsOneWidget);
      // 아무것도 고르기 전에는 시간 선택 필드가 없다.
      expect(find.byKey(_pickerKey), findsNothing);
    });

    testWidgets('출생시간을 고르지 않으면 진행할 수 없다', (tester) async {
      final captured = await _pumpBasicInfo(tester);
      await _fillExceptBirthTime(tester);
      await _tapNext(tester);
      expect(captured, isEmpty);
      expect(find.text('태어난 시간을 아는지 선택해주세요.'), findsOneWidget);
    });

    testWidgets('"알아요"만 고르고 시각을 안 고르면 진행할 수 없다', (tester) async {
      final captured = await _pumpBasicInfo(tester);
      await _fillExceptBirthTime(tester);
      await tester.tap(find.byKey(_knownKey));
      await tester.pumpAndSettle();

      // 시각 선택 전에는 값이 없다는 안내만 있다 — 자동으로 채워지지 않는다.
      expect(find.text('시간을 선택하세요'), findsOneWidget);

      await _tapNext(tester);
      expect(captured, isEmpty);
      expect(find.text('태어난 시각을 선택해주세요.'), findsOneWidget);
    });

    testWidgets('"몰라요"를 고르면 dateOnly로 진행된다', (tester) async {
      final captured = await _pumpBasicInfo(tester);
      await _fillExceptBirthTime(tester);
      await tester.tap(find.byKey(_unknownKey));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('모르셔도 생년월일을 기반으로 기본 해석을 제공해요.'),
        findsOneWidget,
      );

      await _tapNext(tester);
      expect(captured, hasLength(1));
      expect(captured.single.status, BirthProfileStatus.dateOnly);
      expect(captured.single.minutes, isNull);
      expect(captured.single.isValid, isTrue);
    });

    testWidgets('"몰라요"에서 "알아요"로 바꾸면 시간 선택이 다시 필요하다', (tester) async {
      final captured = await _pumpBasicInfo(tester);
      await _fillExceptBirthTime(tester);
      await tester.tap(find.byKey(_unknownKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(_knownKey));
      await tester.pumpAndSettle();

      expect(find.text('시간을 선택하세요'), findsOneWidget);
      await _tapNext(tester);
      expect(captured, isEmpty);
    });

    testWidgets('좁은 화면에서도 overflow 없이 렌더링된다', (tester) async {
      await _pumpBasicInfo(tester, size: const Size(320, 640));
      expect(find.byKey(_knownKey), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(_knownKey));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('기존 사용자 출생시간 보완', () {
    testWidgets('저장 전에는 버튼이 비활성이고, 모름 선택 후 저장된다', (tester) async {
      await _setSurface(tester, const Size(800, 1200));
      final service = _FakeBirthProfileService();
      var completed = 0;

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: BirthTimeCompletionScreen(
              birthDate: DateTime(1995, 2, 4),
              birthProfileService: service,
              onCompleted: () => completed += 1,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('birth-time-completion-screen')), findsOneWidget);
      expect(
        find.textContaining('더 정확한 사주 해석을 위해'),
        findsOneWidget,
      );

      // 아무것도 안 고른 상태에서는 저장이 눌리지 않는다.
      await tester.tap(find.byKey(_saveKey));
      await tester.pumpAndSettle();
      expect(service.calls, isEmpty);
      expect(completed, 0);

      await tester.tap(find.byKey(_unknownKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(_saveKey));
      await tester.pumpAndSettle();

      expect(service.calls, hasLength(1));
      expect(service.calls.single.status, BirthProfileStatus.dateOnly);
      expect(completed, 1);
    });

    testWidgets('저장 실패해도 고른 값이 유지되고 안내 문구만 바뀐다', (tester) async {
      await _setSurface(tester, const Size(800, 1200));
      final service = _FakeBirthProfileService(shouldFail: true);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: BirthTimeCompletionScreen(
              birthDate: DateTime(1995, 2, 4),
              birthProfileService: service,
              onCompleted: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(_unknownKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(_saveKey));
      await tester.pumpAndSettle();

      expect(find.text('저장에 실패했어요. 잠시 후 다시 시도해주세요.'), findsOneWidget);
      // 선택 상태가 남아 있어 바로 다시 저장할 수 있다.
      expect(
        find.textContaining('태어난 시간을 입력하면 더 세밀한 사주 해석을'),
        findsOneWidget,
      );
      expect(find.text('저장하기'), findsOneWidget);
    });

    testWidgets('저장 중 중복 탭해도 한 번만 호출된다', (tester) async {
      await _setSurface(tester, const Size(800, 1200));
      final service = _FakeBirthProfileService(delay: true);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: BirthTimeCompletionScreen(
              birthDate: DateTime(1995, 2, 4),
              birthProfileService: service,
              onCompleted: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(_unknownKey));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(_saveKey));
      await tester.pump();
      await tester.tap(find.byKey(_saveKey), warnIfMissed: false);
      await tester.pump();
      await tester.pumpAndSettle(const Duration(milliseconds: 300));

      expect(service.calls, hasLength(1));
    });
  });
}

class _FakeBirthProfileService implements BirthProfileService {
  final bool shouldFail;
  final bool delay;
  final List<BirthProfile> calls = [];

  _FakeBirthProfileService({this.shouldFail = false, this.delay = false});

  @override
  Future<BirthProfileSaveResult> save({
    required DateTime birthDate,
    required BirthProfile birthProfile,
  }) async {
    if (delay) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (shouldFail) throw const BirthProfileFailure('unavailable');
    calls.add(birthProfile);
    return BirthProfileSaveResult(
      timeKnown: birthProfile.hasKnownTime,
      precision: birthProfile.hasKnownTime ? 'dateAndTime' : 'dateOnly',
    );
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
