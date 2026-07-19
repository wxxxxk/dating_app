import 'package:dating_app/core/constants/profile_story_prompts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ProfileStoryPrompts 카탈로그', () {
    const expectedKeys = [
      'happy_moment',
      'weekend',
      'get_closer',
      'into_lately',
      'comfort_food',
      'travel_style',
      'small_happiness',
      'date_idea',
    ];

    test('프롬프트는 정확히 8개다', () {
      expect(ProfileStoryPrompts.all.length, 8);
    });

    test('확정 key가 순서대로 존재한다', () {
      expect(ProfileStoryPrompts.all.map((prompt) => prompt.key), expectedKeys);
    });

    test('prompt key가 모두 고유하다', () {
      final keys = ProfileStoryPrompts.all.map((prompt) => prompt.key).toList();
      expect(keys.toSet().length, keys.length);
    });

    test('label은 모두 비어 있지 않다', () {
      for (final prompt in ProfileStoryPrompts.all) {
        expect(prompt.label, isNotEmpty, reason: prompt.key);
      }
    });

    test('maxStories는 3이다', () {
      expect(ProfileStoryPrompts.maxStories, 3);
    });

    test('maxAnswerLength는 100이다', () {
      expect(ProfileStoryPrompts.maxAnswerLength, 100);
    });

    test('byKey()가 존재하는 프롬프트를 정상 조회한다', () {
      final prompt = ProfileStoryPrompts.byKey('happy_moment');
      expect(prompt, isNotNull);
      expect(prompt!.label, '요즘 가장 행복한 순간은?');
    });

    test('byKey()는 unknown key에 null을 반환한다', () {
      expect(ProfileStoryPrompts.byKey('unknown_prompt'), isNull);
    });

    test('labelFor()가 표시 질문을 반환한다', () {
      expect(ProfileStoryPrompts.labelFor('weekend'), '완벽한 주말을 보낸다면?');
    });

    test('isValidKey()가 정상·비정상 key를 구분한다', () {
      expect(ProfileStoryPrompts.isValidKey('date_idea'), isTrue);
      expect(ProfileStoryPrompts.isValidKey('unknown_prompt'), isFalse);
    });
  });
}
