import 'package:dating_app/core/constants/value_questions.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ValueQuestions 카탈로그', () {
    test('질문은 정확히 6개다', () {
      expect(ValueQuestions.all.length, 6);
    });

    test('question key가 모두 고유하다', () {
      final keys = ValueQuestions.all.map((q) => q.key).toList();
      expect(keys.toSet().length, keys.length);
    });

    test('각 질문의 answer key는 질문 내부에서 모두 고유하다', () {
      for (final question in ValueQuestions.all) {
        final answerKeys = question.options.map((o) => o.key).toList();
        expect(
          answerKeys.toSet().length,
          answerKeys.length,
          reason: '${question.key}에 중복 answer key가 있다',
        );
      }
    });

    test('각 질문은 3~5개의 선택지를 가진다', () {
      for (final question in ValueQuestions.all) {
        expect(
          question.options.length,
          inInclusiveRange(3, 5),
          reason: '${question.key}의 선택지 개수가 범위를 벗어난다',
        );
      }
    });

    test('byKey()가 존재하는 질문을 정상 조회한다', () {
      final question = ValueQuestions.byKey('contact_frequency');
      expect(question, isNotNull);
      expect(question!.profileLabel, '연락 빈도');
    });

    test('byKey()는 알 수 없는 question key에 null을 반환한다', () {
      expect(ValueQuestions.byKey('unknown_question'), isNull);
    });

    test('optionByKey()가 존재하는 선택지를 정상 조회한다', () {
      final option = ValueQuestions.optionByKey('date_style', 'foodie');
      expect(option, isNotNull);
      expect(option!.label, '맛집 탐방');
    });

    test('optionByKey()는 알 수 없는 answer key에 null을 반환한다', () {
      expect(ValueQuestions.optionByKey('date_style', 'unknown'), isNull);
      expect(ValueQuestions.optionByKey('unknown', 'foodie'), isNull);
    });

    test('answerLabel()이 올바른 한글 라벨을 반환한다', () {
      expect(
        ValueQuestions.answerLabel('affection_expression', 'words'),
        '말로 표현하기',
      );
      expect(ValueQuestions.answerLabel('life_rhythm', 'morning'), '아침형');
    });

    test('answerLabel()은 알 수 없는 조합에 null을 반환한다', () {
      expect(ValueQuestions.answerLabel('life_rhythm', 'unknown'), isNull);
      expect(ValueQuestions.answerLabel('unknown', 'morning'), isNull);
    });

    test('isValidAnswer()가 정상·비정상 조합을 구분한다', () {
      expect(
        ValueQuestions.isValidAnswer('conflict_style', 'talk_now'),
        isTrue,
      );
      expect(
        ValueQuestions.isValidAnswer('conflict_style', 'not_real'),
        isFalse,
      );
      expect(
        ValueQuestions.isValidAnswer('not_a_question', 'talk_now'),
        isFalse,
      );
    });
  });
}
