import 'package:dating_app/models/user_profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DiscoveryFilter', () {
    test('문서에 설정이 없으면 기본값을 사용한다', () {
      final filter = DiscoveryFilter.fromMap(null);

      expect(filter.ageMin, 18);
      expect(filter.ageMax, 80);
      expect(filter.maxDistanceKm, isNull);
      expect(filter.gender, 'all');
      expect(filter.relationshipGoal, isNull);
      expect(filter.hasActiveFilters, isFalse);
    });

    test('Firestore map으로 저장하고 복원할 수 있다', () {
      const original = DiscoveryFilter(
        ageMin: 24,
        ageMax: 35,
        maxDistanceKm: 20,
        gender: 'female',
        relationshipGoal: 'serious_relationship',
      );

      final restored = DiscoveryFilter.fromMap(original.toFirestore());

      expect(restored.ageMin, 24);
      expect(restored.ageMax, 35);
      expect(restored.maxDistanceKm, 20);
      expect(restored.gender, 'female');
      expect(restored.relationshipGoal, 'serious_relationship');
      expect(restored.hasActiveFilters, isTrue);
    });

    test('잘못된 성별 값은 all로 보정한다', () {
      final filter = DiscoveryFilter.fromMap({'gender': 'unknown'});

      expect(filter.gender, 'all');
    });

    test('relationshipGoal이 없는 기존 문서도 안전하게 읽는다', () {
      // relationshipGoal 필드 자체가 없는(이 기능 이전에 저장된) 문서를 흉내낸다.
      final filter = DiscoveryFilter.fromMap({
        'ageMin': 20,
        'ageMax': 40,
        'gender': 'male',
      });

      expect(filter.relationshipGoal, isNull);
      expect(filter.hasActiveFilters, isTrue); // gender가 male이라 활성 상태
    });

    test('알 수 없는 relationshipGoal 값은 전체(null)로 보정한다', () {
      final filter = DiscoveryFilter.fromMap({
        'relationshipGoal': 'no_longer_valid_key',
      });

      expect(filter.relationshipGoal, isNull);
    });

    test('copyWith로 relationshipGoal을 설정/해제할 수 있다', () {
      const base = DiscoveryFilter(relationshipGoal: 'light_romance');

      final updated = base.copyWith(relationshipGoal: 'casual_friend');
      expect(updated.relationshipGoal, 'casual_friend');

      final cleared = base.copyWith(clearRelationshipGoal: true);
      expect(cleared.relationshipGoal, isNull);
    });
  });
}
