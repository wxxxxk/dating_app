import 'dart:io';

import 'package:dating_app/core/constants/app_constants.dart';
import 'package:dating_app/models/public_profile.dart';
import 'package:dating_app/models/user_profile.dart';
import 'package:dating_app/services/location/location_service.dart';
import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  group('Public Profile read cutover 계약', () {
    test('공개 프로필 snapshot map은 document ID를 uid로 보존한다', () {
      final profile = PublicProfile.fromMap(
        uid: 'public-user-1',
        data: {
          'displayName': '민지',
          'age': 28,
          'photoUrls': ['https://example.com/p.jpg'],
        },
      );

      expect(profile.uid, 'public-user-1');
      expect(profile.displayName, '민지');
      expect(profile.age, 28);
      expect(profile.photoUrls, ['https://example.com/p.jpg']);
    });

    test('공개 프로필 누락/불완전 데이터는 안전한 기본값으로 처리한다', () {
      final profile = PublicProfile.fromMap(uid: 'missing-public', data: {});

      expect(profile.uid, 'missing-public');
      expect(profile.displayName, '');
      expect(profile.age, PublicProfile.unknownAge);
      expect(profile.photoUrls, isEmpty);
      expect(profile.coarseLocation, isNull);
    });

    test('거리 계산은 정확 상대 위치가 아니라 coarseLocation을 사용한다', () {
      final current = UserLocation(
        lat: 37.5665,
        lng: 126.9780,
        updatedAt: DateTime(2026, 7, 1),
      );
      final coarse = CoarseLocation(lat: 37.57, lng: 126.98);

      final distance = LocationService.distanceToCoarse(current, coarse);

      expect(distance, isNotNull);
      expect(distance!, greaterThanOrEqualTo(0));
    });

    test('FirestoreService 공개 조회 API는 publicProfiles 상수를 사용한다', () {
      final source = _read('lib/services/database/firestore_service.dart');

      expect(AppConstants.publicProfilesCollection, 'publicProfiles');
      expect(source, contains('getPublicProfile(String uid)'));
      expect(source, contains('watchPublicProfile(String uid)'));
      expect(
        source,
        contains('collection(AppConstants.publicProfilesCollection)'),
      );
    });

    test('Discovery 후보 조회는 publicProfiles와 PublicProfile을 사용한다', () {
      final source = _read('lib/services/discovery/discovery_service.dart');

      expect(source, contains('Future<List<PublicProfile>>'));
      expect(
        source,
        contains('collection(AppConstants.publicProfilesCollection)'),
      );
      expect(source, contains('distanceToCoarse'));
      expect(source, isNot(contains('withConverter<UserProfile>')));
    });

    test('좋아요/매칭/알림/차단 상대 표시 조회는 PublicProfile API를 사용한다', () {
      for (final path in [
        'lib/services/likes/likes_service.dart',
        'lib/services/matches/matches_service.dart',
        'lib/services/notifications/notification_service.dart',
        'lib/services/safety/safety_service.dart',
      ]) {
        final source = _read(path);
        expect(source, contains('getPublicProfile'), reason: path);
        expect(
          source,
          isNot(contains('getUserProfile(actorUid)')),
          reason: path,
        );
        expect(
          source,
          isNot(contains('getUserProfile(otherUid)')),
          reason: path,
        );
        expect(
          source,
          isNot(contains('getUserProfile(targetUid)')),
          reason: path,
        );
        expect(
          source,
          isNot(contains('getUserProfile(senderUid)')),
          reason: path,
        );
        expect(source, isNot(contains('getUserProfile(doc.id)')), reason: path);
      }
    });

    test('상대 프로필 상세은 publicProfiles만 재조회하고 users fallback이 없다', () {
      final source = _read('lib/features/profile/user_profile_screen.dart');

      expect(source, contains('PublicProfile initialProfile'));
      expect(source, contains('getPublicProfile'));
      expect(source, isNot(contains('getUserProfile')));
      expect(source, isNot(contains('profileInsightService')));
    });

    test('본인 프로필/온보딩 성격의 private read path는 users를 유지한다', () {
      expect(
        _read('lib/features/home/home_screen.dart'),
        contains('getUserProfile(uid)'),
      );
      expect(
        _read('lib/features/discovery/discovery_screen.dart'),
        contains('getUserProfile(uid)'),
      );
      expect(
        _read('lib/features/matches/matches_screen.dart'),
        contains('getUserProfile(uid)'),
      );
    });

    test('공개 표시 경로에 users fallback 조회가 없다', () {
      for (final path in [
        'lib/services/discovery/discovery_service.dart',
        'lib/services/likes/likes_service.dart',
        'lib/services/matches/matches_service.dart',
        'lib/services/notifications/notification_service.dart',
        'lib/features/profile/user_profile_screen.dart',
      ]) {
        final source = _read(path);
        expect(source, isNot(contains('getUserProfile(')), reason: path);
      }
    });
  });
}
