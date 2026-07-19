import 'package:dating_app/models/profile_story.dart';
import 'package:dating_app/models/user_profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('UserProfile.profileStories 생성자·copyWith', () {
    test('기본값은 빈 리스트다', () {
      expect(baseProfile().profileStories, isEmpty);
    });

    test('정상 1개/3개 story를 보존하고 순서를 유지한다', () {
      final one = baseProfile(
        profileStories: const [
          ProfileStory(promptKey: 'happy_moment', answer: '맛있는 걸 먹을 때'),
        ],
      );
      expect(one.profileStories.single.promptKey, 'happy_moment');

      final three = baseProfile(
        profileStories: const [
          ProfileStory(promptKey: 'happy_moment', answer: '1'),
          ProfileStory(promptKey: 'weekend', answer: '2'),
          ProfileStory(promptKey: 'date_idea', answer: '3'),
        ],
      );
      expect(three.profileStories.map((story) => story.promptKey), [
        'happy_moment',
        'weekend',
        'date_idea',
      ]);
    });

    test('copyWith(profileStories: ...)가 새 리스트를 반영한다', () {
      final updated = baseProfile().copyWith(
        profileStories: const [
          ProfileStory(promptKey: 'weekend', answer: '늦잠과 산책'),
        ],
      );

      expect(updated.profileStories, [
        const ProfileStory(promptKey: 'weekend', answer: '늦잠과 산책'),
      ]);
    });

    test('copyWith에서 생략하면 기존 profileStories가 유지된다', () {
      final withStories = baseProfile(
        profileStories: const [
          ProfileStory(promptKey: 'travel_style', answer: '가볍게 걷는 여행'),
        ],
      );
      final copied = withStories.copyWith(displayName: '변경');

      expect(copied.profileStories, withStories.profileStories);
    });

    test('unknown promptKey도 모델에서는 보존한다', () {
      final profile = baseProfile(
        profileStories: const [
          ProfileStory(promptKey: 'future_prompt', answer: '미래 답변'),
        ],
      );

      expect(profile.profileStories.single.promptKey, 'future_prompt');
    });
  });

  group('UserProfile.toFirestore profileStories 방출', () {
    test('toFirestore가 profileStories list를 포함한다', () {
      final payload = baseProfile(
        profileStories: const [
          ProfileStory(promptKey: 'date_idea', answer: '전시 보고 커피 마시기'),
        ],
      ).toFirestore();

      expect(payload['profileStories'], [
        {'promptKey': 'date_idea', 'answer': '전시 보고 커피 마시기'},
      ]);
    });

    test('빈 story면 빈 list를 포함한다', () {
      final payload = baseProfile().toFirestore();

      expect(payload.containsKey('profileStories'), isTrue);
      expect(payload['profileStories'], isEmpty);
    });

    test('payload list/map은 모델 내부 리스트와 동일 객체가 아니다', () {
      final profile = baseProfile(
        profileStories: const [
          ProfileStory(promptKey: 'weekend', answer: '산책'),
        ],
      );
      final payload = profile.toFirestore();

      expect(
        identical(payload['profileStories'], profile.profileStories),
        isFalse,
      );
      expect(
        identical(
          (payload['profileStories'] as List).first,
          profile.profileStories.first,
        ),
        isFalse,
      );
    });

    test('기존 valueAnswers 및 다른 필드가 유지된다', () {
      final payload = baseProfile(
        valueAnswers: const {'date_style': 'foodie'},
        profileStories: const [
          ProfileStory(promptKey: 'comfort_food', answer: '떡볶이'),
        ],
      ).toFirestore();

      expect(payload['valueAnswers'], {'date_style': 'foodie'});
      expect(payload['displayName'], '테스트');
      expect(payload['gender'], 'female');
    });
  });

  group('UserProfile.profileStories 불변성 방어', () {
    test('외부 list 변경이 모델 내부 상태를 바꾸지 않는다', () {
      final source = [const ProfileStory(promptKey: 'weekend', answer: '산책')];
      final profile = baseProfile(profileStories: source);

      source.add(const ProfileStory(promptKey: 'date_idea', answer: '전시'));

      expect(profile.profileStories, [
        const ProfileStory(promptKey: 'weekend', answer: '산책'),
      ]);
    });

    test('노출 리스트는 수정 불가다', () {
      final profile = baseProfile(
        profileStories: const [
          ProfileStory(promptKey: 'weekend', answer: '산책'),
        ],
      );

      expect(
        () => profile.profileStories.add(
          const ProfileStory(promptKey: 'date_idea', answer: '전시'),
        ),
        throwsUnsupportedError,
      );
    });
  });
}

UserProfile baseProfile({
  List<ProfileStory> profileStories = const [],
  Map<String, String> valueAnswers = const {},
}) {
  return UserProfile(
    uid: 'u1',
    displayName: '테스트',
    birthDate: DateTime(2000, 1, 1),
    gender: 'female',
    bio: '',
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
    valueAnswers: valueAnswers,
    profileStories: profileStories,
  );
}
