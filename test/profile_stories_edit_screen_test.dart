import 'package:dating_app/core/constants/profile_story_prompts.dart';
import 'package:dating_app/features/profile/profile_stories_edit_screen.dart';
import 'package:dating_app/models/profile_story.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host({required List<ProfileStory> initial}) {
  return MaterialApp(home: ProfileStoriesEditScreen(initialStories: initial));
}

Widget _pushHost(
  List<ProfileStory> initial,
  void Function(List<ProfileStory>?) onResult,
) {
  return MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: ElevatedButton(
            key: const ValueKey('open'),
            onPressed: () async {
              final result = await Navigator.push<List<ProfileStory>>(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      ProfileStoriesEditScreen(initialStories: initial),
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

Finder _progress() => find.byKey(const ValueKey('profile-stories-progress'));
Finder _prompt(String key) => find.byKey(ValueKey('profile-story-prompt-$key'));
Finder _card(String key) => find.byKey(ValueKey('profile-story-card-$key'));
Finder _answer(String key) => find.byKey(ValueKey('profile-story-answer-$key'));
Finder _remove(String key) => find.byKey(ValueKey('profile-story-remove-$key'));

Future<void> _openPrompt(WidgetTester tester, String key) async {
  await tester.dragUntilVisible(
    _prompt(key),
    find.byType(ListView),
    const Offset(0, -220),
  );
  // dragUntilVisible는 위젯이 빌드되는 즉시 멈춰 대상이 뷰포트 하단 경계에
  // 걸칠 수 있다. 탭 전에 완전히 보이도록 스크롤한다(레이아웃 높이에 무관).
  await tester.ensureVisible(_prompt(key));
  await tester.pumpAndSettle();
  await tester.tap(_prompt(key));
  await tester.pumpAndSettle();
}

Future<void> _expectProgress(WidgetTester tester, String text) async {
  await tester.dragUntilVisible(
    _progress(),
    find.byType(ListView),
    const Offset(0, 220),
  );
  expect(find.text(text), findsOneWidget);
}

Future<void> _enterAnswer(WidgetTester tester, String key, String value) async {
  await tester.dragUntilVisible(
    _answer(key),
    find.byType(ListView),
    const Offset(0, -220),
  );
  await tester.ensureVisible(_answer(key));
  await tester.pumpAndSettle();
  await tester.enterText(_answer(key), value);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('8개 프롬프트와 초기 진행 상태가 표시된다', (tester) async {
    await tester.pumpWidget(_host(initial: const []));
    await tester.pumpAndSettle();

    expect(ProfileStoryPrompts.all.length, 8);
    expect(find.text('0 / 3 카드'), findsOneWidget);
    expect(_progress(), findsOneWidget);
    for (final prompt in ProfileStoryPrompts.all) {
      await tester.dragUntilVisible(
        _prompt(prompt.key),
        find.byType(ListView),
        const Offset(0, -220),
      );
      expect(_prompt(prompt.key), findsOneWidget);
      expect(find.text(prompt.label), findsWidgets);
    }
  });

  testWidgets('프롬프트 선택 시 편집 카드가 생기고 중복 선택은 불가하다', (tester) async {
    await tester.pumpWidget(_host(initial: const []));
    await tester.pumpAndSettle();

    await _openPrompt(tester, 'happy_moment');

    expect(_card('happy_moment'), findsOneWidget);
    expect(_answer('happy_moment'), findsOneWidget);
    expect(_prompt('happy_moment'), findsNothing);
    await _expectProgress(tester, '1 / 3 카드');
  });

  testWidgets('선택 순서를 유지하고 최대 3개 이후 네 번째 추가는 불가하다', (tester) async {
    await tester.pumpWidget(_host(initial: const []));
    await tester.pumpAndSettle();

    await _openPrompt(tester, 'weekend');
    await _openPrompt(tester, 'date_idea');
    await _openPrompt(tester, 'comfort_food');
    await _openPrompt(tester, 'happy_moment');

    await _expectProgress(tester, '3 / 3 카드');
    expect(_card('weekend'), findsOneWidget);
    expect(_card('date_idea'), findsOneWidget);
    expect(_card('comfort_food'), findsOneWidget);
    expect(_card('happy_moment'), findsNothing);
    expect(find.text('이야기 카드는 최대 3개까지 작성할 수 있어요.'), findsOneWidget);
  });

  testWidgets('삭제 시 슬롯이 열리고 삭제한 프롬프트를 재선택할 수 있다', (tester) async {
    await tester.pumpWidget(_host(initial: const []));
    await tester.pumpAndSettle();

    await _openPrompt(tester, 'weekend');
    await _openPrompt(tester, 'date_idea');
    await _openPrompt(tester, 'comfort_food');

    await tester.dragUntilVisible(
      _remove('comfort_food'),
      find.byType(ListView),
      const Offset(0, -220),
    );
    await tester.ensureVisible(_remove('comfort_food'));
    await tester.pumpAndSettle();
    await tester.tap(_remove('comfort_food'));
    await tester.pumpAndSettle();

    await _expectProgress(tester, '2 / 3 카드');
    expect(_card('comfort_food'), findsNothing);

    await _openPrompt(tester, 'comfort_food');
    expect(_card('comfort_food'), findsOneWidget);
    await _expectProgress(tester, '3 / 3 카드');
  });

  testWidgets('답변 입력 후 완료 결과가 선택 순서로 반환된다', (tester) async {
    List<ProfileStory>? captured;
    await tester.pumpWidget(_pushHost(const [], (r) => captured = r));
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();

    await _openPrompt(tester, 'weekend');
    await _openPrompt(tester, 'date_idea');
    await _enterAnswer(tester, 'weekend', '늦잠 자고 산책하기');
    await _enterAnswer(tester, 'date_idea', '전시 보고 커피 마시기');

    await tester.tap(find.byKey(const ValueKey('profile-stories-done')));
    await tester.pumpAndSettle();

    expect(captured, [
      const ProfileStory(promptKey: 'weekend', answer: '늦잠 자고 산책하기'),
      const ProfileStory(promptKey: 'date_idea', answer: '전시 보고 커피 마시기'),
    ]);
  });

  testWidgets('빈 답변과 공백 답변은 완료 결과에서 제외된다', (tester) async {
    List<ProfileStory>? captured;
    await tester.pumpWidget(_pushHost(const [], (r) => captured = r));
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();

    await _openPrompt(tester, 'weekend');
    await _openPrompt(tester, 'date_idea');
    await _enterAnswer(tester, 'date_idea', '   ');

    await tester.tap(find.byKey(const ValueKey('profile-stories-done')));
    await tester.pumpAndSettle();

    expect(captured, isEmpty);
  });

  testWidgets('완료 시 trim, emoji 제거, 제어문자 제거를 적용한다', (tester) async {
    List<ProfileStory>? captured;
    await tester.pumpWidget(_pushHost(const [], (r) => captured = r));
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();

    await _openPrompt(tester, 'happy_moment');
    await _enterAnswer(tester, 'happy_moment', '  좋아요\u0001🙂  ');

    await tester.tap(find.byKey(const ValueKey('profile-stories-done')));
    await tester.pumpAndSettle();

    expect(captured, [
      const ProfileStory(promptKey: 'happy_moment', answer: '좋아요'),
    ]);
  });

  testWidgets('100자 입력은 허용하고 101자는 100자로 제한한다', (tester) async {
    List<ProfileStory>? captured;
    await tester.pumpWidget(_pushHost(const [], (r) => captured = r));
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();

    await _openPrompt(tester, 'happy_moment');
    await _enterAnswer(tester, 'happy_moment', List.filled(100, 'a').join());
    await tester.tap(find.byKey(const ValueKey('profile-stories-done')));
    await tester.pumpAndSettle();
    expect(captured!.single.answer.length, 100);

    captured = null;
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();
    await _openPrompt(tester, 'happy_moment');
    await _enterAnswer(tester, 'happy_moment', List.filled(101, 'b').join());
    await tester.tap(find.byKey(const ValueKey('profile-stories-done')));
    await tester.pumpAndSettle();
    expect(captured!.single.answer.length, 100);
  });

  testWidgets('initialStories를 표시하고 기존 순서를 유지한다', (tester) async {
    await tester.pumpWidget(
      _host(
        initial: const [
          ProfileStory(promptKey: 'weekend', answer: '주말'),
          ProfileStory(promptKey: 'date_idea', answer: '데이트'),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('2 / 3 카드'), findsOneWidget);
    expect(_card('weekend'), findsOneWidget);
    expect(_card('date_idea'), findsOneWidget);
    expect(find.text('주말'), findsOneWidget);
    expect(find.text('데이트'), findsOneWidget);
  });

  testWidgets('뒤로가기는 null을 반환한다', (tester) async {
    List<ProfileStory>? captured = [
      const ProfileStory(promptKey: 'sentinel', answer: 'x'),
    ];
    var called = false;
    await tester.pumpWidget(
      _pushHost(const [], (r) {
        captured = r;
        called = true;
      }),
    );
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();
    await _openPrompt(tester, 'weekend');

    await tester.tap(find.byIcon(Icons.arrow_back_ios_new_rounded));
    await tester.pumpAndSettle();

    expect(called, isTrue);
    expect(captured, isNull);
  });

  testWidgets('완료 결과는 새 리스트이며 호출자가 수정해도 다음 결과에 영향 없다', (tester) async {
    List<ProfileStory>? first;
    List<ProfileStory>? second;
    await tester.pumpWidget(_pushHost(const [], (r) => first = r));
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();
    await _openPrompt(tester, 'weekend');
    await _enterAnswer(tester, 'weekend', '첫 답변');
    await tester.tap(find.byKey(const ValueKey('profile-stories-done')));
    await tester.pumpAndSettle();

    expect(
      () => first!.add(const ProfileStory(promptKey: 'x', answer: 'y')),
      throwsUnsupportedError,
    );

    await tester.pumpWidget(_pushHost(const [], (r) => second = r));
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('profile-stories-done')));
    await tester.pumpAndSettle();

    expect(second, isEmpty);
  });

  testWidgets('unknown promptKey는 화면에 표시하지 않고 완료 결과에 보존한다', (tester) async {
    List<ProfileStory>? captured;
    await tester.pumpWidget(
      _pushHost(const [
        ProfileStory(promptKey: 'future_prompt', answer: '미래 답변'),
      ], (r) => captured = r),
    );
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();

    expect(find.text('1 / 3 카드'), findsOneWidget);
    expect(find.text('현재 앱에서 편집할 수 없는 이야기 카드가 유지되고 있어요.'), findsOneWidget);
    expect(find.text('future_prompt'), findsNothing);
    expect(find.text('미래 답변'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('profile-stories-done')));
    await tester.pumpAndSettle();

    expect(captured, [
      const ProfileStory(promptKey: 'future_prompt', answer: '미래 답변'),
    ]);
  });

  testWidgets('unknown story도 최대 슬롯 수에 포함된다', (tester) async {
    await tester.pumpWidget(
      _host(
        initial: const [
          ProfileStory(promptKey: 'future_a', answer: 'A'),
          ProfileStory(promptKey: 'future_b', answer: 'B'),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('2 / 3 카드'), findsOneWidget);
    await _openPrompt(tester, 'weekend');
    await _openPrompt(tester, 'date_idea');

    await _expectProgress(tester, '3 / 3 카드');
    expect(_card('weekend'), findsOneWidget);
    expect(_card('date_idea'), findsNothing);
  });

  testWidgets('작은 화면과 키보드 상태에서도 overflow 없이 완료 버튼 접근 가능', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() => tester.view.viewInsets = const FakeViewPadding());

    await tester.pumpWidget(_host(initial: const []));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('profile-stories-done')), findsOneWidget);
    await _openPrompt(tester, 'happy_moment');
    await _enterAnswer(tester, 'happy_moment', '작은 화면 테스트');
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('profile-stories-done')), findsOneWidget);
  });
}
