import 'package:dating_app/core/constants/value_questions.dart';
import 'package:dating_app/features/profile/value_answers_edit_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// ValueAnswersEditScreen은 순수 UI 화면이라 Firebase 없이 그대로 테스트한다.
/// 문자열보다 지정된 ValueKey를 중심으로 검증한다.

Widget _host({required Map<String, String> initial}) {
  return MaterialApp(home: ValueAnswersEditScreen(initialAnswers: initial));
}

/// 화면을 열고, 완료를 눌렀을 때 반환되는 map을 캡처하기 위한 호스트.
/// 버튼 탭 → push → pop 흐름으로 결과를 받는다.
Widget _pushHost(
  Map<String, String> initial,
  void Function(Map<String, String>?) onResult,
) {
  return MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: ElevatedButton(
            key: const ValueKey('open'),
            onPressed: () async {
              final result = await Navigator.push<Map<String, String>>(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      ValueAnswersEditScreen(initialAnswers: initial),
                ),
              );
              onResult(result);
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
}

Finder _progress() => find.byKey(const ValueKey('value-answers-progress'));
Finder _option(String q, String a) =>
    find.byKey(ValueKey('value-option-$q-$a'));
Finder _question(String q) => find.byKey(ValueKey('value-question-$q'));

void main() {
  testWidgets('6개 질문과 각 선택지가 catalog 기준으로 렌더링된다', (tester) async {
    await tester.pumpWidget(_host(initial: const {}));
    await tester.pumpAndSettle();

    // 6개 질문 카드 모두 존재
    expect(ValueQuestions.all.length, 6);
    for (final q in ValueQuestions.all) {
      await tester.scrollUntilVisible(_question(q.key), 200);
      expect(_question(q.key), findsOneWidget);
      for (final opt in q.options) {
        expect(_option(q.key, opt.key), findsOneWidget);
      }
    }
  });

  testWidgets('빈 map이면 진행 상태가 0 / 6 답변', (tester) async {
    await tester.pumpWidget(_host(initial: const {}));
    await tester.pumpAndSettle();
    expect(_progress(), findsOneWidget);
    expect(find.text('0 / 6 답변'), findsOneWidget);
  });

  testWidgets('option 선택 시 진행 상태가 증가하고, 같은 option 재탭 시 해제', (tester) async {
    await tester.pumpWidget(_host(initial: const {}));
    await tester.pumpAndSettle();

    await tester.tap(_option('contact_frequency', 'few_times'));
    await tester.pumpAndSettle();
    expect(find.text('1 / 6 답변'), findsOneWidget);

    // 같은 option 재탭 → 해제
    await tester.tap(_option('contact_frequency', 'few_times'));
    await tester.pumpAndSettle();
    expect(find.text('0 / 6 답변'), findsOneWidget);
  });

  testWidgets('같은 질문의 다른 option을 누르면 이전 선택이 교체된다(카운트 1 유지)', (tester) async {
    await tester.pumpWidget(_host(initial: const {}));
    await tester.pumpAndSettle();

    await tester.tap(_option('contact_frequency', 'few_times'));
    await tester.pumpAndSettle();
    expect(find.text('1 / 6 답변'), findsOneWidget);

    await tester.tap(_option('contact_frequency', 'once_a_day'));
    await tester.pumpAndSettle();
    // 교체이므로 여전히 1개
    expect(find.text('1 / 6 답변'), findsOneWidget);
  });

  testWidgets('완료 시 선택 map이 Navigator 결과로 반환된다(부분 응답 허용)', (tester) async {
    Map<String, String>? captured;
    var called = false;
    await tester.pumpWidget(
      _pushHost(const {}, (r) {
        captured = r;
        called = true;
      }),
    );
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();

    await tester.tap(_option('contact_frequency', 'few_times'));
    await tester.pumpAndSettle();
    await tester.tap(_option('conflict_style', 'cool_down'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('value-answers-done')));
    await tester.pumpAndSettle();

    expect(called, isTrue);
    expect(captured, {
      'contact_frequency': 'few_times',
      'conflict_style': 'cool_down',
    });
  });

  testWidgets('뒤로가기 시 결과 없이 종료된다(null 반환)', (tester) async {
    Map<String, String>? captured = {'sentinel': 'x'};
    var called = false;
    await tester.pumpWidget(
      _pushHost(const {}, (r) {
        captured = r;
        called = true;
      }),
    );
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();

    // 선택은 했지만 완료 대신 뒤로가기
    await tester.tap(_option('contact_frequency', 'few_times'));
    await tester.pumpAndSettle();
    // 커스텀 leading(뒤로가기) 아이콘 탭
    await tester.tap(find.byIcon(Icons.arrow_back_ios_new_rounded));
    await tester.pumpAndSettle();

    expect(called, isTrue);
    expect(captured, isNull);
  });

  testWidgets('initialAnswers의 정상 값이 초기 선택/진행 상태에 반영된다', (tester) async {
    await tester.pumpWidget(
      _host(
        initial: const {'contact_frequency': 'few_times', 'date_style': 'cozy'},
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('2 / 6 답변'), findsOneWidget);
  });

  testWidgets('unknown question key는 진행 카운트에서 제외되고 완료 결과에는 보존된다', (
    tester,
  ) async {
    Map<String, String>? captured;
    await tester.pumpWidget(
      _pushHost(const {
        'future_question': 'future_answer',
        'contact_frequency': 'few_times',
      }, (r) => captured = r),
    );
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();

    // unknown key는 카운트에서 제외 → known 1개만
    expect(find.text('1 / 6 답변'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('value-answers-done')));
    await tester.pumpAndSettle();

    // 완료 결과에는 unknown key가 그대로 보존
    expect(captured, {
      'future_question': 'future_answer',
      'contact_frequency': 'few_times',
    });
  });

  testWidgets('known 질문의 invalid answer key는 초기화 시 정규화(제거)된다', (tester) async {
    Map<String, String>? captured;
    await tester.pumpWidget(
      _pushHost(const {
        'contact_frequency': 'invalid_answer',
        'conflict_style': 'cool_down',
      }, (r) => captured = r),
    );
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();

    // invalid answer는 선택 안 된 상태 → known 유효 1개만 카운트
    expect(find.text('1 / 6 답변'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('value-answers-done')));
    await tester.pumpAndSettle();

    // 완료 결과에서 invalid answer가 제거됨(unknown이 아니라 known invalid)
    expect(captured, {'conflict_style': 'cool_down'});
  });

  testWidgets('unknown key와 known invalid가 섞여도 unknown만 보존된다', (tester) async {
    Map<String, String>? captured;
    await tester.pumpWidget(
      _pushHost(const {
        'future_question': 'future_answer', // 보존
        'contact_frequency': 'invalid_answer', // 제거
      }, (r) => captured = r),
    );
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();

    expect(find.text('0 / 6 답변'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('value-answers-done')));
    await tester.pumpAndSettle();

    expect(captured, {'future_question': 'future_answer'});
  });

  testWidgets('작은 화면에서도 완료 버튼 접근 및 스크롤에 overflow가 없다', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_host(initial: const {}));
    await tester.pumpAndSettle();

    // 완료 버튼은 하단 고정이라 항상 접근 가능
    expect(find.byKey(const ValueKey('value-answers-done')), findsOneWidget);

    // 마지막 질문까지 스크롤해도 overflow 예외 없음
    await tester.scrollUntilVisible(_question('life_rhythm'), 200);
    expect(_question('life_rhythm'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
