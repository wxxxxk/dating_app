import 'package:dating_app/models/profile_story.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ProfileStory', () {
    test('toMap()이 Firestore 필드명으로 직렬화한다', () {
      const story = ProfileStory(
        promptKey: 'happy_moment',
        answer: '좋아하는 사람과 맛있는 것을 먹을 때예요.',
      );

      expect(story.toMap(), {
        'promptKey': 'happy_moment',
        'answer': '좋아하는 사람과 맛있는 것을 먹을 때예요.',
      });
    });

    test('정상 map을 파싱한다', () {
      final story = ProfileStory.tryFromMap({
        'promptKey': 'weekend',
        'answer': '늦잠을 자고 산책해요.',
      });

      expect(story, isNotNull);
      expect(story!.promptKey, 'weekend');
      expect(story.answer, '늦잠을 자고 산책해요.');
    });

    test('unknown promptKey도 구조가 정상이면 보존한다', () {
      final story = ProfileStory.tryFromMap({
        'promptKey': 'future_prompt',
        'answer': '나중에 추가된 답변',
      });

      expect(
        story,
        const ProfileStory(promptKey: 'future_prompt', answer: '나중에 추가된 답변'),
      );
    });

    test('비-map은 null', () {
      expect(ProfileStory.tryFromMap('not_a_map'), isNull);
      expect(ProfileStory.tryFromMap(null), isNull);
    });

    test('필드 누락은 null', () {
      expect(ProfileStory.tryFromMap({'answer': '답변'}), isNull);
      expect(ProfileStory.tryFromMap({'promptKey': 'weekend'}), isNull);
    });

    test('타입 오류는 null', () {
      expect(ProfileStory.tryFromMap({'promptKey': 1, 'answer': '답변'}), isNull);
      expect(
        ProfileStory.tryFromMap({'promptKey': 'weekend', 'answer': false}),
        isNull,
      );
    });

    test('빈 promptKey/answer는 null', () {
      expect(
        ProfileStory.tryFromMap({'promptKey': '', 'answer': '답변'}),
        isNull,
      );
      expect(
        ProfileStory.tryFromMap({'promptKey': 'weekend', 'answer': ''}),
        isNull,
      );
    });
  });

  group('normalizeProfileStories', () {
    test('null/비-list는 빈 리스트', () {
      expect(normalizeProfileStories(null), isEmpty);
      expect(normalizeProfileStories({'promptKey': 'weekend'}), isEmpty);
    });

    test('malformed entry를 개별 제외하고 순서를 유지한다', () {
      final stories = normalizeProfileStories([
        {'promptKey': 'happy_moment', 'answer': '첫 번째'},
        {'promptKey': 'broken'},
        'not_a_map',
        {'promptKey': 'weekend', 'answer': '두 번째'},
      ]);

      expect(stories.map((story) => story.promptKey), [
        'happy_moment',
        'weekend',
      ]);
    });

    test('duplicate promptKey는 first-wins로 처리한다', () {
      final stories = normalizeProfileStories([
        {'promptKey': 'weekend', 'answer': '첫 답변'},
        {'promptKey': 'weekend', 'answer': '두 번째 답변'},
      ]);

      expect(stories, [
        const ProfileStory(promptKey: 'weekend', answer: '첫 답변'),
      ]);
    });

    test('최대 3개까지만 유지한다', () {
      final stories = normalizeProfileStories([
        {'promptKey': 'happy_moment', 'answer': '1'},
        {'promptKey': 'weekend', 'answer': '2'},
        {'promptKey': 'get_closer', 'answer': '3'},
        {'promptKey': 'into_lately', 'answer': '4'},
      ]);

      expect(stories.map((story) => story.promptKey), [
        'happy_moment',
        'weekend',
        'get_closer',
      ]);
    });

    test('반환 리스트는 수정 불가다', () {
      final stories = normalizeProfileStories([
        {'promptKey': 'weekend', 'answer': '답변'},
      ]);

      expect(
        () => stories.add(
          const ProfileStory(promptKey: 'date_idea', answer: '새 답변'),
        ),
        throwsUnsupportedError,
      );
    });

    test('원본 collection 변경이 결과에 영향을 주지 않는다', () {
      final rawEntry = {'promptKey': 'weekend', 'answer': '원본 답변'};
      final raw = [rawEntry];
      final stories = normalizeProfileStories(raw);

      rawEntry['answer'] = '변조';
      raw.add({'promptKey': 'date_idea', 'answer': '추가'});

      expect(stories, [
        const ProfileStory(promptKey: 'weekend', answer: '원본 답변'),
      ]);
    });
  });
}
