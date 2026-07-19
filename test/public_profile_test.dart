import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:dating_app/models/profile_story.dart';
import 'package:dating_app/models/public_profile.dart';
import 'package:dating_app/models/user_profile.dart';
import 'package:flutter_test/flutter_test.dart';

/// 공개 문서 어떤 payload에도 절대 나타나면 안 되는 key 목록.
const _forbiddenKeys = <String>{
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
};

/// 테스트용 UserProfile 생성 헬퍼.
UserProfile buildUserProfile({
  DateTime? birthDate,
  UserLocation? location,
  DateTime? boostUntil,
  int jelly = 999,
  bool likesUnlocked = true,
  Map<String, String> valueAnswers = const {},
  List<ProfileStory> profileStories = const [],
}) {
  return UserProfile(
    uid: 'user-1',
    displayName: '지민',
    birthDate: birthDate ?? DateTime(1995, 6, 15),
    gender: 'female',
    bio: '안녕하세요',
    photoUrls: const ['https://example.com/a.jpg', 'https://example.com/b.jpg'],
    createdAt: DateTime(2024, 1, 1),
    updatedAt: DateTime(2026, 7, 1),
    height: 165,
    religion: 'none',
    smoking: 'non_smoker',
    drinking: 'socially',
    jobCategory: 'design',
    jobTitle: 'UX 디자이너',
    education: 'university',
    mbti: 'ENFP',
    interests: const ['coffee', 'travel'],
    personalityTags: const ['warm'],
    idealTags: const ['kind'],
    relationshipGoal: 'serious_relationship',
    location: location,
    verifications: const VerificationStatus(email: true, phone: true),
    jelly: jelly,
    boostUntil: boostUntil,
    likesUnlocked: likesUnlocked,
    valueAnswers: valueAnswers,
    profileStories: profileStories,
  );
}

void main() {
  group('UserProfile.ageAt', () {
    final profile = buildUserProfile(birthDate: DateTime(1995, 6, 15));

    test('생일 당일에는 만 나이가 올라간다', () {
      expect(profile.ageAt(DateTime(2026, 6, 15)), 31);
    });

    test('생일 전날에는 아직 이전 나이다', () {
      expect(profile.ageAt(DateTime(2026, 6, 14)), 30);
    });

    test('생일 다음 날에는 새 나이가 유지된다', () {
      expect(profile.ageAt(DateTime(2026, 6, 16)), 31);
    });

    test('연말 기준 나이', () {
      expect(profile.ageAt(DateTime(2026, 12, 31)), 31);
    });

    test('연초 기준 나이(생일 전이라 1을 뺀다)', () {
      expect(profile.ageAt(DateTime(2026, 1, 1)), 30);
    });

    test('윤년 2월 29일 생일도 예외 없이 처리된다', () {
      final leap = buildUserProfile(birthDate: DateTime(2000, 2, 29));
      // 비윤년 2/28: 아직 생일 전으로 본다.
      expect(leap.ageAt(DateTime(2026, 2, 28)), 25);
      // 비윤년 3/1: 생일이 지난 것으로 본다.
      expect(leap.ageAt(DateTime(2026, 3, 1)), 26);
      // 윤년 2/29 당일.
      expect(leap.ageAt(DateTime(2024, 2, 29)), 24);
    });

    test('age getter는 ageAt(now)와 일관된다', () {
      final now = DateTime.now();
      expect(profile.age, profile.ageAt(now));
    });
  });

  group('CoarseLocation 양자화', () {
    test('정확 좌표가 소수점 둘째 자리로 양자화된다', () {
      final coarse = CoarseLocation.fromUserLocation(
        UserLocation(lat: 37.56647, lng: 126.97796, updatedAt: DateTime(2026)),
      );
      expect(coarse.lat, 37.57);
      expect(coarse.lng, 126.98);
    });

    test('quantize는 반올림을 사용한다', () {
      expect(CoarseLocation.quantize(37.564), 37.56);
      expect(CoarseLocation.quantize(37.565), 37.57);
      expect(CoarseLocation.quantize(-126.978), -126.98);
    });

    test('lat/lng 누락 또는 비정상 숫자는 null로 처리된다', () {
      expect(CoarseLocation.fromMap(null), isNull);
      expect(CoarseLocation.fromMap({'lng': 126.98}), isNull);
      expect(CoarseLocation.fromMap({'lat': 'x', 'lng': 1.0}), isNull);
      expect(CoarseLocation.fromMap({'lat': double.nan, 'lng': 1.0}), isNull);
    });

    test('toMap에는 label이 없고 lat/lng만 노출된다', () {
      final coarse = CoarseLocation.fromUserLocation(
        UserLocation(lat: 37.5, lng: 127.0, updatedAt: DateTime(2026)),
      );
      final map = coarse.toMap();
      expect(map.keys.toSet(), {'lat', 'lng', 'updatedAt'});
      expect(map.containsKey('label'), isFalse);
    });
  });

  group('PublicProfile.fromUserProfile 경계', () {
    final profile = buildUserProfile(
      birthDate: DateTime(1995, 6, 15),
      location: UserLocation(
        lat: 37.56647,
        lng: 126.97796,
        updatedAt: DateTime(2026, 6, 1),
        label: '서울 어딘가',
      ),
      boostUntil: DateTime(2026, 8, 1),
    );

    test('정확 나이가 계산되고 birthDate는 노출되지 않는다', () {
      final public = PublicProfile.fromUserProfile(
        profile,
        referenceDate: DateTime(2026, 7, 1),
      );
      expect(public.age, 31);
      expect(public.toBackfillFirestore().containsKey('birthDate'), isFalse);
      expect(public.toBackfillFirestore().containsKey('birthYear'), isFalse);
    });

    test('정확 위치와 label이 공개 변환에 포함되지 않는다', () {
      final public = PublicProfile.fromUserProfile(profile);
      expect(public.coarseLocation, isNotNull);
      expect(public.coarseLocation!.lat, 37.57);
      expect(public.coarseLocation!.lng, 126.98);

      final coarseMap =
          public.toOwnerEditableFirestore()['coarseLocation']
              as Map<String, dynamic>;
      expect(coarseMap.containsKey('label'), isFalse);
      // 원본 정밀 좌표가 그대로 새어나가지 않는다.
      expect(coarseMap['lat'], isNot(37.56647));
    });

    test('boostUntil이 미래여도 rankingBoostUntil은 복사되지 않고 null이다', () {
      // profile.boostUntil = DateTime(2026, 8, 1) (미래)
      final public = PublicProfile.fromUserProfile(profile);
      expect(public.rankingBoostUntil, isNull);
    });

    test('owner-editable payload에는 rankingBoostUntil/boostUntil이 없다', () {
      final public = PublicProfile.fromUserProfile(profile);
      final owner = public.toOwnerEditableFirestore();
      expect(owner.containsKey('rankingBoostUntil'), isFalse);
      expect(owner.containsKey('boostUntil'), isFalse);
    });

    test('server-managed 계약에는 rankingBoostUntil key가 존재하되 값은 null', () {
      final public = PublicProfile.fromUserProfile(profile);
      final server = public.toServerManagedFirestore();
      expect(server.containsKey('rankingBoostUntil'), isTrue);
      expect(server['rankingBoostUntil'], isNull);
    });

    test('backfill 계약에는 rankingBoostUntil key가 존재하되 값은 null', () {
      final public = PublicProfile.fromUserProfile(profile);
      final backfill = public.toBackfillFirestore();
      expect(backfill.containsKey('rankingBoostUntil'), isTrue);
      expect(backfill['rankingBoostUntil'], isNull);
    });
  });

  group('payload별 key 집합', () {
    final public = PublicProfile.fromUserProfile(
      buildUserProfile(
        location: UserLocation(
          lat: 37.5,
          lng: 127.0,
          updatedAt: DateTime(2026),
        ),
        boostUntil: DateTime(2026, 8, 1),
      ),
    );

    test('owner-editable payload에 서버 관리 필드가 없다', () {
      final keys = public.toOwnerEditableFirestore().keys.toSet();
      expect(keys, PublicProfile.ownerEditableKeys);
      for (final serverKey in PublicProfile.serverManagedKeys) {
        expect(keys.contains(serverKey), isFalse, reason: serverKey);
      }
    });

    test('server-managed payload에 사용자 프로필 필드가 없다', () {
      final keys = public.toServerManagedFirestore().keys.toSet();
      expect(keys, PublicProfile.serverManagedKeys);
      // 대표적인 owner-editable 필드가 섞이지 않는다.
      for (final ownerKey in const ['displayName', 'age', 'coarseLocation']) {
        expect(keys.contains(ownerKey), isFalse, reason: ownerKey);
      }
    });

    test('backfill payload에 공개 필드 전체가 존재한다', () {
      final keys = public.toBackfillFirestore().keys.toSet();
      expect(keys, PublicProfile.backfillKeys);
      expect(keys, containsAll(PublicProfile.ownerEditableKeys));
      expect(keys, containsAll(PublicProfile.serverManagedKeys));
    });

    test('세 payload 어디에도 비공개/금지 key가 없다', () {
      final payloads = <Map<String, dynamic>>[
        public.toOwnerEditableFirestore(),
        public.toServerManagedFirestore(),
        public.toBackfillFirestore(),
      ];
      for (final payload in payloads) {
        for (final forbidden in _forbiddenKeys) {
          expect(
            payload.containsKey(forbidden),
            isFalse,
            reason: '$forbidden 이(가) payload에 포함됨',
          );
        }
      }
    });
  });

  group('PublicProfile.fromMap 안전 파싱', () {
    test('빈 Map(구형 문서)도 예외 없이 기본값으로 파싱된다', () {
      final public = PublicProfile.fromMap(uid: 'u', data: const {});
      expect(public.uid, 'u');
      expect(public.displayName, '');
      expect(public.gender, 'other');
      expect(public.photoUrls, isEmpty);
      expect(public.coarseLocation, isNull);
      expect(public.schemaVersion, PublicProfile.currentSchemaVersion);
    });

    test('age 누락/범위 밖이면 unknownAge로 두고 위조하지 않는다', () {
      expect(
        PublicProfile.fromMap(uid: 'u', data: const {}).age,
        PublicProfile.unknownAge,
      );
      expect(
        PublicProfile.fromMap(uid: 'u', data: const {'age': 999}).age,
        PublicProfile.unknownAge,
      );
      final valid = PublicProfile.fromMap(uid: 'u', data: const {'age': 27});
      expect(valid.age, 27);
      expect(valid.hasValidAge, isTrue);
      expect(
        PublicProfile.fromMap(uid: 'u', data: const {}).hasValidAge,
        isFalse,
      );
    });

    test('Timestamp 서버 필드가 DateTime으로 복원된다', () {
      final public = PublicProfile.fromMap(
        uid: 'u',
        data: {
          'age': 30,
          'rankingBoostUntil': Timestamp.fromDate(DateTime(2026, 8, 1)),
          'profileUpdatedAt': Timestamp.fromDate(DateTime(2026, 7, 1)),
          'coarseLocation': {'lat': 37.57, 'lng': 126.98},
        },
      );
      expect(public.rankingBoostUntil, DateTime(2026, 8, 1));
      expect(public.profileUpdatedAt, DateTime(2026, 7, 1));
      expect(public.coarseLocation!.lat, 37.57);
    });

    test('잘못된 optional/server-managed 타입도 예외 없이 기본값으로 처리한다', () {
      final public = PublicProfile.fromMap(
        uid: 'u',
        data: const {
          'displayName': 123,
          'height': '170',
          'rankingBoostUntil': '2030-01-01',
          'profileUpdatedAt': 123,
          'schemaVersion': '1',
        },
      );

      expect(public.displayName, '');
      expect(public.height, isNull);
      expect(public.rankingBoostUntil, isNull);
      expect(public.profileUpdatedAt, isNull);
      expect(public.schemaVersion, PublicProfile.currentSchemaVersion);
    });
  });

  group('불변성 방어', () {
    test('입력 배열을 외부에서 변경해도 모델 내부 값이 바뀌지 않는다', () {
      final photos = ['a', 'b'];
      final interests = ['coffee'];
      final public = PublicProfile(
        uid: 'u',
        photoUrls: photos,
        interests: interests,
      );

      photos.add('c');
      interests.clear();

      expect(public.photoUrls, ['a', 'b']);
      expect(public.interests, ['coffee']);
    });

    test('노출된 리스트는 수정 불가(unmodifiable)다', () {
      final public = PublicProfile(uid: 'u', photoUrls: ['a']);
      expect(() => public.photoUrls.add('b'), throwsUnsupportedError);
    });
  });

  group('valueAnswers 공개 계약', () {
    const answers = {'contact_frequency': 'few_times', 'date_style': 'culture'};

    test('기본값은 빈 map이다', () {
      expect(PublicProfile(uid: 'u').valueAnswers, isEmpty);
    });

    test('fromUserProfile이 답변을 복사한다', () {
      final public = PublicProfile.fromUserProfile(
        buildUserProfile(valueAnswers: answers),
      );
      expect(public.valueAnswers, answers);
    });

    test('toOwnerEditableFirestore가 valueAnswers map을 포함한다', () {
      final public = PublicProfile.fromUserProfile(
        buildUserProfile(valueAnswers: answers),
      );
      expect(public.toOwnerEditableFirestore()['valueAnswers'], answers);
    });

    test('ownerEditableKeys에는 포함, serverManagedKeys에는 미포함', () {
      expect(PublicProfile.ownerEditableKeys, contains('valueAnswers'));
      expect(PublicProfile.serverManagedKeys, isNot(contains('valueAnswers')));
    });

    test('backfillKeys에는 포함된다', () {
      expect(PublicProfile.backfillKeys, contains('valueAnswers'));
    });

    test('fromMap: 필드 부재 시 빈 map', () {
      final public = PublicProfile.fromMap(uid: 'u', data: const {});
      expect(public.valueAnswers, isEmpty);
    });

    test('fromMap: 문자열 key-value만 보존하고 비문자열 값은 무시한다', () {
      final public = PublicProfile.fromMap(
        uid: 'u',
        data: const {
          'valueAnswers': {
            'contact_frequency': 'few_times', // 보존
            'noise_num': 3, // 무시
            'noise_bool': true, // 무시
            'noise_list': ['a'], // 무시
            'noise_map': {'k': 'v'}, // 무시
          },
        },
      );
      expect(public.valueAnswers, {'contact_frequency': 'few_times'});
    });

    test('fromMap: map이 아니면 빈 map', () {
      final public = PublicProfile.fromMap(
        uid: 'u',
        data: const {'valueAnswers': 'not_a_map'},
      );
      expect(public.valueAnswers, isEmpty);
    });

    test('외부 map 변경이 내부 상태를 바꾸지 않고, 노출 map은 수정 불가다', () {
      final source = {'contact_frequency': 'few_times'};
      final public = PublicProfile(uid: 'u', valueAnswers: source);
      source['date_style'] = 'culture';

      expect(public.valueAnswers, {'contact_frequency': 'few_times'});
      expect(() => public.valueAnswers['x'] = 'y', throwsUnsupportedError);
    });

    test('valueAnswers가 있어도 비공개/금지 key는 payload에 추가되지 않는다', () {
      final payload = PublicProfile.fromUserProfile(
        buildUserProfile(valueAnswers: answers),
      ).toOwnerEditableFirestore();
      for (final forbidden in _forbiddenKeys) {
        expect(
          payload.containsKey(forbidden),
          isFalse,
          reason: '$forbidden 이(가) owner payload에 노출됨',
        );
      }
    });

    test('currentSchemaVersion은 1을 유지한다', () {
      expect(PublicProfile.currentSchemaVersion, 1);
    });
  });

  group('profileStories 공개 계약', () {
    const stories = [
      ProfileStory(promptKey: 'happy_moment', answer: '맛있는 걸 먹을 때'),
      ProfileStory(promptKey: 'weekend', answer: '늦잠 자고 산책하기'),
      ProfileStory(promptKey: 'date_idea', answer: '전시 보고 커피 마시기'),
    ];

    test('기본값은 빈 리스트다', () {
      expect(PublicProfile(uid: 'u').profileStories, isEmpty);
    });

    test('fromUserProfile이 story를 순서대로 복사한다', () {
      final public = PublicProfile.fromUserProfile(
        buildUserProfile(profileStories: stories),
      );

      expect(public.profileStories, stories);
      expect(public.profileStories.map((story) => story.promptKey), [
        'happy_moment',
        'weekend',
        'date_idea',
      ]);
    });

    test('fromMap이 정상 story를 파싱하고 malformed entry는 제외한다', () {
      final public = PublicProfile.fromMap(
        uid: 'u',
        data: const {
          'profileStories': [
            {'promptKey': 'happy_moment', 'answer': '첫 답변'},
            {'promptKey': 'broken'},
            {'promptKey': 'weekend', 'answer': '두 번째 답변'},
          ],
        },
      );

      expect(public.profileStories, [
        const ProfileStory(promptKey: 'happy_moment', answer: '첫 답변'),
        const ProfileStory(promptKey: 'weekend', answer: '두 번째 답변'),
      ]);
    });

    test('fromMap은 unknown promptKey를 구조적으로 보존한다', () {
      final public = PublicProfile.fromMap(
        uid: 'u',
        data: const {
          'profileStories': [
            {'promptKey': 'future_prompt', 'answer': '미래 답변'},
          ],
        },
      );

      expect(public.profileStories.single.promptKey, 'future_prompt');
    });

    test('toOwnerEditableFirestore가 story payload를 포함한다', () {
      final payload = PublicProfile.fromUserProfile(
        buildUserProfile(profileStories: stories),
      ).toOwnerEditableFirestore();

      expect(payload['profileStories'], [
        {'promptKey': 'happy_moment', 'answer': '맛있는 걸 먹을 때'},
        {'promptKey': 'weekend', 'answer': '늦잠 자고 산책하기'},
        {'promptKey': 'date_idea', 'answer': '전시 보고 커피 마시기'},
      ]);
    });

    test('ownerEditableKeys/backfillKeys에는 포함, serverManagedKeys에는 미포함', () {
      expect(PublicProfile.ownerEditableKeys, contains('profileStories'));
      expect(PublicProfile.backfillKeys, contains('profileStories'));
      expect(
        PublicProfile.serverManagedKeys,
        isNot(contains('profileStories')),
      );
    });

    test('외부 list 변경과 payload 변경이 모델 내부 상태를 바꾸지 않는다', () {
      final source = [const ProfileStory(promptKey: 'weekend', answer: '산책')];
      final public = PublicProfile(uid: 'u', profileStories: source);
      final payload = public.toOwnerEditableFirestore();

      source.add(const ProfileStory(promptKey: 'date_idea', answer: '전시'));
      (payload['profileStories'] as List).add({
        'promptKey': 'happy_moment',
        'answer': '변조',
      });

      expect(public.profileStories, [
        const ProfileStory(promptKey: 'weekend', answer: '산책'),
      ]);
      expect(() => public.profileStories.clear(), throwsUnsupportedError);
    });

    test('profileStories가 있어도 비공개/금지 key는 payload에 추가되지 않는다', () {
      final payload = PublicProfile.fromUserProfile(
        buildUserProfile(profileStories: stories),
      ).toOwnerEditableFirestore();
      for (final forbidden in _forbiddenKeys) {
        expect(
          payload.containsKey(forbidden),
          isFalse,
          reason: '$forbidden 이(가) owner payload에 노출됨',
        );
      }
    });

    test('schemaVersion은 1을 유지한다', () {
      final public = PublicProfile.fromUserProfile(
        buildUserProfile(profileStories: stories),
      );

      expect(public.schemaVersion, 1);
    });

    test('기존 valueAnswers 계약은 유지된다', () {
      final payload = PublicProfile.fromUserProfile(
        buildUserProfile(
          valueAnswers: const {'date_style': 'foodie'},
          profileStories: stories,
        ),
      ).toOwnerEditableFirestore();

      expect(payload['valueAnswers'], {'date_style': 'foodie'});
      expect(payload['profileStories'], isNotEmpty);
    });
  });
}
