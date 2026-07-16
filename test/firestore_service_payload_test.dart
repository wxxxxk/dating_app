import 'package:dating_app/models/public_profile.dart';
import 'package:dating_app/models/user_profile.dart';
import 'package:dating_app/services/database/firestore_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// 레거시 편집 payload(`users/{uid}` 부분 갱신)에 절대 없어야 하는 필드.
const _forbiddenLegacyEditKeys = <String>{
  'birthDate',
  'createdAt',
  'personaVector',
  'location',
  'verifications',
  'discoveryFilter',
  'jelly',
  'boostUntil',
  'likesUnlocked',
  'fcmTokens',
  'fcmTokenUpdatedAt',
  'fortuneNarrative',
  'charmReport',
  'charmReportUpdatedAt',
  'profileInsight',
  'idealTypeImage',
  'idealTypeImageProviderPreview',
};

/// 공개 owner payload에 절대 없어야 하는 비공개/server-managed 필드.
const _forbiddenPublicOwnerKeys = <String>{
  'birthDate',
  'birthYear',
  'location',
  'label',
  'discoveryFilter',
  'personaVector',
  'jelly',
  'boostUntil',
  'likesUnlocked',
  'fcmTokens',
  'fcmTokenUpdatedAt',
  'fortuneNarrative',
  'charmReport',
  'profileInsight',
  'idealTypeImage',
  'idealTypeImageProviderPreview',
  // server-managed
  'verifications',
  'rankingBoostUntil',
  'profileUpdatedAt',
  'schemaVersion',
};

UserProfile buildUserProfile({
  int? height,
  String? religion,
  UserLocation? location,
  DateTime? boostUntil,
  List<String>? interests,
}) {
  return UserProfile(
    uid: 'user-1',
    displayName: '지민',
    birthDate: DateTime(1995, 6, 15),
    gender: 'female',
    bio: '안녕하세요',
    photoUrls: const ['https://example.com/a.jpg'],
    createdAt: DateTime(2024, 1, 1),
    updatedAt: DateTime(2026, 7, 1),
    height: height,
    religion: religion,
    smoking: 'non_smoker',
    drinking: 'socially',
    jobCategory: 'design',
    jobTitle: 'UX 디자이너',
    education: 'university',
    mbti: 'ENFP',
    interests: interests ?? const ['coffee', 'travel'],
    personalityTags: const ['warm'],
    idealTags: const ['kind'],
    relationshipGoal: 'serious_relationship',
    location: location,
    verifications: const VerificationStatus(email: true, phone: true),
    jelly: 999,
    boostUntil: boostUntil,
    likesUnlocked: true,
  );
}

void main() {
  group('신규 생성 payload (users/{uid})', () {
    test('key 집합이 clientCreatableUserKeys와 정확히 같다', () {
      final payload = FirestoreService.buildClientCreatableUserFields(
        buildUserProfile(
          location: UserLocation(
            lat: 37.56647,
            lng: 126.97796,
            updatedAt: DateTime(2026, 6, 1),
            label: '서울',
          ),
        ),
      );
      expect(payload.keys.toSet(), FirestoreService.clientCreatableUserKeys);
    });

    test('재화·토큰·AI 캐시·권한성 필드가 없다', () {
      final payload = FirestoreService.buildClientCreatableUserFields(
        buildUserProfile(boostUntil: DateTime(2030, 1, 1)),
      );
      for (final forbidden in const {
        'jelly',
        'boostUntil',
        'likesUnlocked',
        'fcmTokens',
        'fcmTokenUpdatedAt',
        'fortuneNarrative',
        'charmReport',
        'profileInsight',
        'idealTypeImage',
        'idealTypeImageProviderPreview',
        'admin',
        'role',
        'moderationStatus',
      }) {
        expect(
          payload.containsKey(forbidden),
          isFalse,
          reason: '$forbidden 이(가) 신규 생성 payload에 포함됨',
        );
      }
    });

    test('인증 완료 true를 신규 생성 payload에 싣지 않는다', () {
      final payload = FirestoreService.buildClientCreatableUserFields(
        buildUserProfile(),
      );
      expect(payload['verifications'], {
        'email': false,
        'phone': false,
        'photo': false,
      });
    });
  });

  group('레거시 편집 payload (users/{uid} 부분 갱신)', () {
    test('key 집합이 legacyEditableUserKeys와 정확히 같다', () {
      final payload = FirestoreService.buildLegacyEditableUserFields(
        buildUserProfile(),
      );
      expect(payload.keys.toSet(), FirestoreService.legacyEditableUserKeys);
    });

    test('nullable 필드가 null로 명시적으로 포함된다', () {
      final payload = FirestoreService.buildLegacyEditableUserFields(
        buildUserProfile(height: null, religion: null),
      );
      expect(payload.containsKey('height'), isTrue);
      expect(payload['height'], isNull);
      expect(payload.containsKey('religion'), isTrue);
      expect(payload['religion'], isNull);
    });

    test('재화·토큰·위치·인증·AI 캐시·불변 필드가 없다', () {
      final payload = FirestoreService.buildLegacyEditableUserFields(
        buildUserProfile(),
      );
      for (final forbidden in _forbiddenLegacyEditKeys) {
        expect(
          payload.containsKey(forbidden),
          isFalse,
          reason: '$forbidden 이(가) 레거시 편집 payload에 포함됨',
        );
      }
    });
  });

  group('공개 owner payload (publicProfiles/{uid})', () {
    UserProfile profile() => buildUserProfile(
      location: UserLocation(
        lat: 37.56647,
        lng: 126.97796,
        updatedAt: DateTime(2026, 6, 1),
        label: '서울 어딘가',
      ),
      boostUntil: DateTime(2030, 1, 1),
    );

    Map<String, dynamic> ownerPayload() =>
        PublicProfile.fromUserProfile(profile()).toOwnerEditableFirestore();

    test('key 집합이 ownerEditableKeys와 정확히 같다', () {
      expect(ownerPayload().keys.toSet(), PublicProfile.ownerEditableKeys);
    });

    test('server-managed 필드가 없다', () {
      final payload = ownerPayload();
      for (final serverKey in PublicProfile.serverManagedKeys) {
        expect(payload.containsKey(serverKey), isFalse, reason: serverKey);
      }
    });

    test('모든 비공개/금지 필드가 없다', () {
      final payload = ownerPayload();
      for (final forbidden in _forbiddenPublicOwnerKeys) {
        expect(
          payload.containsKey(forbidden),
          isFalse,
          reason: '$forbidden 이(가) 공개 owner payload에 포함됨',
        );
      }
    });

    test('정확 위치와 coarseLocation 값이 다르고 label이 없다', () {
      final coarse = ownerPayload()['coarseLocation'] as Map<String, dynamic>;
      expect(coarse.keys.toSet(), {'lat', 'lng', 'updatedAt'});
      expect(coarse.containsKey('label'), isFalse);
      // 양자화로 원본 정밀 좌표와 값이 달라진다.
      expect(coarse['lat'], 37.57);
      expect(coarse['lat'], isNot(37.56647));
      expect(coarse['lng'], 126.98);
      expect(coarse['lng'], isNot(126.97796));
    });

    test('미래 boostUntil이 공개 owner payload와 rankingBoostUntil로 흐르지 않는다', () {
      final public = PublicProfile.fromUserProfile(profile());
      expect(public.rankingBoostUntil, isNull);
      final payload = public.toOwnerEditableFirestore();
      expect(payload.containsKey('rankingBoostUntil'), isFalse);
      expect(payload.containsKey('boostUntil'), isFalse);
    });
  });

  group('불변성 방어', () {
    test('입력 배열을 변경해도 payload key와 모델 내부 값이 변하지 않는다', () {
      final interests = ['coffee', 'travel'];
      final profile = buildUserProfile(interests: interests);
      final public = PublicProfile.fromUserProfile(profile);
      final payloadBefore = public.toOwnerEditableFirestore();

      interests.add('hacked');

      // 모델 내부 값(방어 복사)은 그대로.
      expect(public.interests, ['coffee', 'travel']);
      // payload key 집합도 그대로.
      expect(
        public.toOwnerEditableFirestore().keys.toSet(),
        payloadBefore.keys.toSet(),
      );
      expect(public.toOwnerEditableFirestore()['interests'], [
        'coffee',
        'travel',
      ]);
    });
  });
}
