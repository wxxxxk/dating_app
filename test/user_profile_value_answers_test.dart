import 'package:dating_app/models/user_profile.dart';
import 'package:flutter_test/flutter_test.dart';

// 참고: valueAnswers의 Firestore 파싱(_stringMap)은 UserProfile.fromFirestore가
// DocumentSnapshot을 요구하는데, 이 클래스는 sealed라 별도 mocking 프레임워크
// 없이 깔끔한 fake를 만들 수 없다. 프로젝트에 DocumentSnapshot 테스트 기반이
// 아직 없으므로, 이번 단계에서는 생성자·copyWith 계약만 검증한다. 파싱 경로는
// dual-write/round-trip 테스트가 들어오는 Phase 1-1-C에서 함께 다룬다.

void main() {
  group('UserProfile.valueAnswers 생성자·copyWith', () {
    test('valueAnswers를 전달하지 않은 생성자는 빈 map이다', () {
      expect(baseProfile().valueAnswers, isEmpty);
    });

    test('copyWith(valueAnswers: ...)가 새 답변 map을 반영한다', () {
      final updated = baseProfile().copyWith(
        valueAnswers: const {'date_style': 'foodie'},
      );
      expect(updated.valueAnswers, {'date_style': 'foodie'});
    });

    test('copyWith에서 valueAnswers를 생략하면 기존 값이 유지된다', () {
      final withAnswers = baseProfile().copyWith(
        valueAnswers: const {'life_rhythm': 'morning'},
      );
      final copied = withAnswers.copyWith(displayName: '변경');
      expect(copied.valueAnswers, {'life_rhythm': 'morning'});
    });
  });

  group('UserProfile.toFirestore valueAnswers 방출', () {
    test('toFirestore가 valueAnswers map을 포함한다', () {
      final payload = baseProfile()
          .copyWith(valueAnswers: const {'date_style': 'foodie'})
          .toFirestore();
      expect(payload['valueAnswers'], {'date_style': 'foodie'});
    });

    test('빈 답변이면 빈 map을 포함한다(필드 존재 보장)', () {
      final payload = baseProfile().toFirestore();
      expect(payload.containsKey('valueAnswers'), isTrue);
      expect(payload['valueAnswers'], isEmpty);
    });

    test('원본 map과 payload map은 동일 객체가 아니다', () {
      final source = {'date_style': 'foodie'};
      final profile = baseProfile().copyWith(valueAnswers: source);
      final payload = profile.toFirestore();
      expect(identical(payload['valueAnswers'], profile.valueAnswers), isFalse);
    });
  });

  group('completenessPercent는 valueAnswers와 무관하다', () {
    test('답변 유무가 완성도 계산을 바꾸지 않는다', () {
      final without = baseProfile();
      final with_ = baseProfile().copyWith(
        valueAnswers: const {
          'contact_frequency': 'few_times',
          'date_style': 'culture',
        },
      );
      expect(with_.completenessPercent, without.completenessPercent);
    });
  });
}

UserProfile baseProfile() {
  return UserProfile(
    uid: 'u1',
    displayName: '테스트',
    birthDate: DateTime(2000, 1, 1),
    gender: 'female',
    bio: '',
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
  );
}
