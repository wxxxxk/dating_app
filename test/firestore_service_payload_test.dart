import 'package:dating_app/models/profile_story.dart';
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
  'aiKeywordSummary',
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
  'aiKeywordSummary',
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
  Map<String, String> valueAnswers = const {},
  List<ProfileStory> profileStories = const [],
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
    valueAnswers: valueAnswers,
    profileStories: profileStories,
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
      // Phase 3-3에서 work/school이 추가됐다. 어떤 배지도 true로 시작하지
      // 않는다는 계약은 그대로다(rules도 false만 허용).
      expect(payload['verifications'], {
        'email': false,
        'phone': false,
        'photo': false,
        'work': false,
        'school': false,
      });
      final verifications = payload['verifications'] as Map<String, dynamic>;
      expect(verifications.values.every((value) => value == false), isTrue);
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

  group('valueAnswers dual-write payload', () {
    const answers = {
      'contact_frequency': 'few_times',
      'conflict_style': 'cool_down',
    };

    test(
      'clientCreatableUserKeys / legacyEditableUserKeys에 valueAnswers 포함',
      () {
        expect(
          FirestoreService.clientCreatableUserKeys,
          contains('valueAnswers'),
        );
        expect(
          FirestoreService.legacyEditableUserKeys,
          contains('valueAnswers'),
        );
      },
    );

    test('신규 생성 payload가 답변 map을 포함한다', () {
      final payload = FirestoreService.buildClientCreatableUserFields(
        buildUserProfile(valueAnswers: answers),
      );
      expect(payload['valueAnswers'], answers);
    });

    test('레거시 편집 payload가 답변 map을 포함한다', () {
      final payload = FirestoreService.buildLegacyEditableUserFields(
        buildUserProfile(valueAnswers: answers),
      );
      expect(payload['valueAnswers'], answers);
    });

    test('빈 답변이면 두 builder 모두 빈 map을 포함한다', () {
      final create = FirestoreService.buildClientCreatableUserFields(
        buildUserProfile(),
      );
      final edit = FirestoreService.buildLegacyEditableUserFields(
        buildUserProfile(),
      );
      expect(create['valueAnswers'], isEmpty);
      expect(edit['valueAnswers'], isEmpty);
    });

    test('builder는 원본 map 객체를 그대로 노출하지 않는다', () {
      final source = {'contact_frequency': 'few_times'};
      final profile = buildUserProfile(valueAnswers: source);
      final createPayload = FirestoreService.buildClientCreatableUserFields(
        profile,
      );
      final editPayload = FirestoreService.buildLegacyEditableUserFields(
        profile,
      );
      expect(
        identical(createPayload['valueAnswers'], profile.valueAnswers),
        isFalse,
      );
      expect(
        identical(editPayload['valueAnswers'], profile.valueAnswers),
        isFalse,
      );
    });

    test('공개 owner payload에도 valueAnswers가 자동 포함된다', () {
      final payload = PublicProfile.fromUserProfile(
        buildUserProfile(valueAnswers: answers),
      ).toOwnerEditableFirestore();
      expect(payload['valueAnswers'], answers);
    });
  });

  group('profileStories dual-write payload', () {
    const stories = [
      ProfileStory(promptKey: 'happy_moment', answer: '맛있는 걸 먹을 때'),
      ProfileStory(promptKey: 'weekend', answer: '늦잠 자고 산책하기'),
      ProfileStory(promptKey: 'date_idea', answer: '전시 보고 커피 마시기'),
    ];

    List<Map<String, String>> expectedStoryPayload() => const [
      {'promptKey': 'happy_moment', 'answer': '맛있는 걸 먹을 때'},
      {'promptKey': 'weekend', 'answer': '늦잠 자고 산책하기'},
      {'promptKey': 'date_idea', 'answer': '전시 보고 커피 마시기'},
    ];

    test(
      'clientCreatableUserKeys / legacyEditableUserKeys에 profileStories 포함',
      () {
        expect(
          FirestoreService.clientCreatableUserKeys,
          contains('profileStories'),
        );
        expect(
          FirestoreService.legacyEditableUserKeys,
          contains('profileStories'),
        );
      },
    );

    test('users 신규 생성 payload가 profileStories를 포함한다', () {
      final payload = FirestoreService.buildClientCreatableUserFields(
        buildUserProfile(profileStories: stories),
      );

      expect(payload['profileStories'], expectedStoryPayload());
    });

    test('users 편집 payload가 profileStories를 포함한다', () {
      final payload = FirestoreService.buildLegacyEditableUserFields(
        buildUserProfile(profileStories: stories),
      );

      expect(payload['profileStories'], expectedStoryPayload());
    });

    test('publicProfiles owner payload가 profileStories를 포함한다', () {
      final payload = PublicProfile.fromUserProfile(
        buildUserProfile(profileStories: stories),
      ).toOwnerEditableFirestore();

      expect(payload['profileStories'], expectedStoryPayload());
    });

    test('users/publicProfiles payload 내용과 순서가 동일하다', () {
      final profile = buildUserProfile(profileStories: stories);
      final create = FirestoreService.buildClientCreatableUserFields(profile);
      final edit = FirestoreService.buildLegacyEditableUserFields(profile);
      final public = PublicProfile.fromUserProfile(
        profile,
      ).toOwnerEditableFirestore();

      expect(create['profileStories'], edit['profileStories']);
      expect(create['profileStories'], public['profileStories']);
    });

    test('빈 리스트도 세 payload에 명시적으로 포함된다', () {
      final profile = buildUserProfile();
      final create = FirestoreService.buildClientCreatableUserFields(profile);
      final edit = FirestoreService.buildLegacyEditableUserFields(profile);
      final public = PublicProfile.fromUserProfile(
        profile,
      ).toOwnerEditableFirestore();

      expect(create.containsKey('profileStories'), isTrue);
      expect(edit.containsKey('profileStories'), isTrue);
      expect(public.containsKey('profileStories'), isTrue);
      expect(create['profileStories'], isEmpty);
      expect(edit['profileStories'], isEmpty);
      expect(public['profileStories'], isEmpty);
    });

    test('payload list/map은 모델 내부 객체를 공유하지 않는다', () {
      final profile = buildUserProfile(profileStories: stories);
      final create = FirestoreService.buildClientCreatableUserFields(profile);
      final edit = FirestoreService.buildLegacyEditableUserFields(profile);
      final public = PublicProfile.fromUserProfile(
        profile,
      ).toOwnerEditableFirestore();

      for (final payload in [create, edit, public]) {
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
      }
    });

    test('payload 생성 후 원본 collection 변경이 payload에 영향 없다', () {
      final source = [const ProfileStory(promptKey: 'weekend', answer: '산책')];
      final profile = buildUserProfile(profileStories: source);
      final payload = FirestoreService.buildClientCreatableUserFields(profile);

      source.add(const ProfileStory(promptKey: 'date_idea', answer: '전시'));

      expect(payload['profileStories'], [
        {'promptKey': 'weekend', 'answer': '산책'},
      ]);
    });

    test('기존 valueAnswers payload는 유지된다', () {
      final payload = FirestoreService.buildClientCreatableUserFields(
        buildUserProfile(
          valueAnswers: const {'date_style': 'foodie'},
          profileStories: stories,
        ),
      );

      expect(payload['valueAnswers'], {'date_style': 'foodie'});
      expect(payload['profileStories'], isNotEmpty);
    });

    test('server-only 필드는 client payload에 추가되지 않는다', () {
      final create = FirestoreService.buildClientCreatableUserFields(
        buildUserProfile(profileStories: stories),
      );
      final edit = FirestoreService.buildLegacyEditableUserFields(
        buildUserProfile(profileStories: stories),
      );
      final public = PublicProfile.fromUserProfile(
        buildUserProfile(profileStories: stories),
      ).toOwnerEditableFirestore();

      for (final forbidden in _forbiddenLegacyEditKeys) {
        expect(edit.containsKey(forbidden), isFalse, reason: forbidden);
      }
      for (final forbidden in _forbiddenPublicOwnerKeys) {
        expect(public.containsKey(forbidden), isFalse, reason: forbidden);
      }
      expect(create.containsKey('rankingBoostUntil'), isFalse);
      expect(create.containsKey('aiKeywordSummary'), isFalse);
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
