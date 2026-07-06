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
      expect(filter.hasActiveFilters, isFalse);
    });

    test('Firestore map으로 저장하고 복원할 수 있다', () {
      const original = DiscoveryFilter(
        ageMin: 24,
        ageMax: 35,
        maxDistanceKm: 20,
        gender: 'female',
      );

      final restored = DiscoveryFilter.fromMap(original.toFirestore());

      expect(restored.ageMin, 24);
      expect(restored.ageMax, 35);
      expect(restored.maxDistanceKm, 20);
      expect(restored.gender, 'female');
      expect(restored.hasActiveFilters, isTrue);
    });

    test('잘못된 성별 값은 all로 보정한다', () {
      final filter = DiscoveryFilter.fromMap({'gender': 'unknown'});

      expect(filter.gender, 'all');
    });
  });
}
