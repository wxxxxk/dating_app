import 'package:dating_app/services/location/location_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LocationService.distanceKm', () {
    test('같은 좌표는 0km를 반환한다', () {
      final distance = LocationService.distanceKm(
        fromLat: 37.5665,
        fromLng: 126.9780,
        toLat: 37.5665,
        toLng: 126.9780,
      );

      expect(distance, closeTo(0, 1e-9));
    });

    test('서울 시청에서 강남구청까지의 거리를 결정론적으로 계산한다', () {
      final distance = LocationService.distanceKm(
        fromLat: 37.5665,
        fromLng: 126.9780,
        toLat: 37.5172,
        toLng: 127.0473,
      );

      expect(distance, closeTo(8.2, 0.3));
    });
  });

  group('LocationService.formatDistance', () {
    test('1km 미만은 1km 이내로 숨긴다', () {
      expect(LocationService.formatDistance(0.4), '1km 이내');
    });

    test('가까운 거리는 올림한 km 이내로 표시한다', () {
      expect(LocationService.formatDistance(2.1), '3km 이내');
    });

    test('먼 거리는 반올림 km로 표시한다', () {
      expect(LocationService.formatDistance(12.6), '13km');
    });
  });
}
