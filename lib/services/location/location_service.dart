import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../../models/public_profile.dart';
import '../../models/user_profile.dart';
import '../database/firestore_service.dart';

/// 위치 권한 요청, 현재 위치 저장, 거리 계산을 담당한다.
///
/// 앱은 실시간 추적을 하지 않고 디스커버리 진입 시 1회만 마지막 위치를 갱신한다.
/// 정확 좌표는 Firestore 저장과 거리 계산에만 쓰며 화면에는 거리 라벨만 보여준다.
class LocationService {
  const LocationService();

  static const double _earthRadiusKm = 6371.0088;

  /// Haversine 공식으로 두 좌표 사이의 직선 거리(km)를 계산한다.
  static double distanceKm({
    required double fromLat,
    required double fromLng,
    required double toLat,
    required double toLng,
  }) {
    final dLat = _degreesToRadians(toLat - fromLat);
    final dLng = _degreesToRadians(toLng - fromLng);
    final lat1 = _degreesToRadians(fromLat);
    final lat2 = _degreesToRadians(toLat);

    final a =
        math.pow(math.sin(dLat / 2), 2) +
        math.cos(lat1) * math.cos(lat2) * math.pow(math.sin(dLng / 2), 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return _earthRadiusKm * c;
  }

  static double? distanceBetween(UserLocation? from, UserLocation? to) {
    if (from == null || to == null) return null;
    return distanceKm(
      fromLat: from.lat,
      fromLng: from.lng,
      toLat: to.lat,
      toLng: to.lng,
    );
  }

  static double? distanceToCoarse(UserLocation? from, CoarseLocation? to) {
    if (from == null || to == null) return null;
    return distanceKm(
      fromLat: from.lat,
      fromLng: from.lng,
      toLat: to.lat,
      toLng: to.lng,
    );
  }

  /// 개인정보 보호를 위해 정확 좌표 대신 둥근 거리 라벨만 만든다.
  static String formatDistance(double km) {
    if (km < 1) return '1km 이내';
    if (km < 10) return '${km.ceil()}km 이내';
    return '${km.round()}km';
  }

  /// 권한이 허용되면 현재 위치를 users/{uid}.location에 저장하고 반환한다.
  ///
  /// 권한 거부, 위치 서비스 꺼짐, 플랫폼 오류는 앱 흐름을 막지 않도록 null로 처리한다.
  Future<UserLocation?> updateCurrentUserLocation({
    required String uid,
    required FirestoreService firestoreService,
  }) async {
    try {
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) {
        debugPrint('[Location] 위치 서비스가 꺼져 있어 거리 표시를 생략합니다.');
        return null;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        debugPrint('[Location] 위치 권한 거부: $permission');
        return null;
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.low,
          timeLimit: Duration(seconds: 8),
        ),
      );
      final location = UserLocation(
        lat: position.latitude,
        lng: position.longitude,
        updatedAt: DateTime.now(),
      );
      await firestoreService.updateUserLocation(uid, location);
      debugPrint('[Location] 현재 위치 저장 완료');
      return location;
    } catch (e) {
      debugPrint('[Location] 현재 위치 저장 실패, 거리 표시 생략: $e');
      return null;
    }
  }

  static double _degreesToRadians(double degrees) => degrees * math.pi / 180;
}
