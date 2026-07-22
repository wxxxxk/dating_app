import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:dating_app/models/fortune/birth_profile.dart';
import 'package:dating_app/models/fortune/saju_birth_input.dart';
import 'package:dating_app/models/public_profile.dart';
import 'package:dating_app/models/user_profile.dart';
import 'package:dating_app/services/database/firestore_service.dart';
import 'package:flutter_test/flutter_test.dart';

// Phase 5-2 — 출생정보 모델 계약과 개인정보 경계.

UserProfile _profile({BirthProfile? birthProfile}) {
  return UserProfile(
    uid: 'u1',
    displayName: '지수',
    birthDate: DateTime(1995, 2, 4),
    birthProfile: birthProfile ?? const BirthProfile.unknownTime(),
    gender: 'female',
    bio: '안녕하세요',
    photoUrls: const ['https://example.com/a.jpg'],
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
  );
}

void main() {
  group('BirthProfile 상태', () {
    test('필드가 없는 기존 문서는 legacyMissing이다 — unknown과 구분된다', () {
      final legacy = BirthProfile.fromMap({'displayName': '지수'});
      expect(legacy.status, BirthProfileStatus.legacyMissing);
      expect(legacy.needsCompletion, isTrue);
      expect(legacy.hasKnownTime, isFalse);

      const unknown = BirthProfile.unknownTime();
      expect(unknown.status, BirthProfileStatus.dateOnly);
      expect(unknown.needsCompletion, isFalse);
    });

    test('시각을 알면 dateAndTime이고 분이 보존된다', () {
      final known = BirthProfile.fromMap({
        'birthTimeKnown': true,
        'birthTimeMinutes': 455,
      });
      expect(known.status, BirthProfileStatus.dateAndTime);
      expect(known.hasKnownTime, isTrue);
      expect(known.minutes, 455);
    });

    test('모름인데 분이 남아 있으면 무시한다', () {
      final unknown = BirthProfile.fromMap({
        'birthTimeKnown': false,
        'birthTimeMinutes': 720,
      });
      expect(unknown.minutes, isNull);
      expect(unknown.isValid, isTrue);
    });
  });

  group('BirthProfile 계약 검증', () {
    test('known/minutes invariant를 서버와 같은 규칙으로 판정한다', () {
      expect(const BirthProfile.knownTime(0).isValid, isTrue);
      expect(const BirthProfile.knownTime(1439).isValid, isTrue);
      expect(const BirthProfile.unknownTime().isValid, isTrue);
      expect(
        const BirthProfile(timeKnown: true, minutes: null).isValid,
        isFalse,
      );
      expect(
        const BirthProfile(timeKnown: true, minutes: -1).isValid,
        isFalse,
      );
      expect(
        const BirthProfile(timeKnown: true, minutes: 1440).isValid,
        isFalse,
      );
      expect(
        const BirthProfile(timeKnown: false, minutes: 0).isValid,
        isFalse,
      );
    });

    test('양력·Asia/Seoul 외 값은 계약 위반이다', () {
      expect(
        const BirthProfile(
          timeKnown: false,
          minutes: null,
          calendarType: 'lunar',
        ).isValid,
        isFalse,
      );
      expect(
        const BirthProfile(
          timeKnown: false,
          minutes: null,
          timeZone: 'UTC',
        ).isValid,
        isFalse,
      );
    });
  });

  group('시간 표기', () {
    test('한국어 오전/오후 표기', () {
      expect(BirthProfile.formatKorean(0), '오전 12:00');
      expect(BirthProfile.formatKorean(455), '오전 7:35');
      expect(BirthProfile.formatKorean(720), '오후 12:00');
      expect(BirthProfile.formatKorean(1390), '오후 11:10');
      expect(BirthProfile.formatKorean(1439), '오후 11:59');
    });

    test('24시간 정규화 표기', () {
      expect(BirthProfile.formatClock(0), '00:00');
      expect(BirthProfile.formatClock(455), '07:35');
      expect(BirthProfile.formatClock(1439), '23:59');
    });
  });

  group('Phase 5-1 계산 입력 계약 연결', () {
    test('시각을 모르면 dateOnly precision으로 변환된다', () {
      final input = const BirthProfile.unknownTime().toSajuInput(
        DateTime(1995, 2, 4),
      );
      expect(input.precision, SajuInputPrecision.dateOnly);
      expect(input.birthTime, isNull);
      expect(input.calendarType, SajuCalendarType.solar);
    });

    test('시각을 알면 dateAndTime precision으로 변환된다', () {
      final input = const BirthProfile.knownTime(455).toSajuInput(
        DateTime(1995, 2, 4),
      );
      expect(input.precision, SajuInputPrecision.dateAndTime);
      expect(input.birthTime, '07:35');
      expect(input.isWellFormed, isTrue);
    });
  });

  group('Firestore 저장 payload', () {
    test('신규 생성 payload에 출생정보가 정규화돼 포함된다', () {
      final fields = const BirthProfile.knownTime(455).toFirestoreFields();
      expect(fields['birthCalendarType'], 'solar');
      expect(fields['birthTimeKnown'], isTrue);
      expect(fields['birthTimeMinutes'], 455);
      expect(fields['birthTimeZone'], 'Asia/Seoul');
      expect(fields['sajuInputVersion'], 2);
      expect(fields['birthProfileUpdatedAt'], isA<FieldValue>());
    });

    test('모름 payload는 minutes를 null로 저장한다', () {
      final fields = const BirthProfile.unknownTime().toFirestoreFields();
      expect(fields['birthTimeKnown'], isFalse);
      expect(fields['birthTimeMinutes'], isNull);
    });

    test('클라이언트 생성 허용 key에 출생정보가 포함되고 payload와 일치한다', () {
      final payload = FirestoreService.buildClientCreatableUserFields(
        _profile(birthProfile: const BirthProfile.knownTime(455)),
      );
      // location처럼 값이 있을 때만 방출되는 key가 있어 부분집합으로 확인한다.
      expect(
        payload.keys.toSet().difference(
          FirestoreService.clientCreatableUserKeys,
        ),
        isEmpty,
        reason: 'whitelist에 없는 key가 create payload에 있다',
      );
      for (final key in const [
        'birthCalendarType',
        'birthTimeKnown',
        'birthTimeMinutes',
        'birthTimeZone',
        'sajuInputVersion',
        'birthProfileUpdatedAt',
      ]) {
        expect(payload.containsKey(key), isTrue, reason: 'key=$key');
        expect(
          FirestoreService.clientCreatableUserKeys.contains(key),
          isTrue,
          reason: 'key=$key',
        );
      }
      expect(payload['birthTimeKnown'], isTrue);
      expect(payload['birthTimeMinutes'], 455);
    });

    test('프로필 편집 경로로는 출생정보를 바꿀 수 없다 — 서버 callable 전용', () {
      final editable = FirestoreService.buildLegacyEditableUserFields(
        _profile(birthProfile: const BirthProfile.knownTime(455)),
      );
      for (final key in const [
        'birthDate',
        'birthTimeKnown',
        'birthTimeMinutes',
        'birthCalendarType',
        'birthTimeZone',
        'sajuInputVersion',
      ]) {
        expect(editable.containsKey(key), isFalse, reason: 'key=$key');
        expect(
          FirestoreService.legacyEditableUserKeys.contains(key),
          isFalse,
          reason: 'key=$key',
        );
      }
    });
  });

  group('개인정보 경계', () {
    test('공개 프로필에 출생정보가 어떤 형태로도 담기지 않는다', () {
      final profile = _profile(
        birthProfile: const BirthProfile.knownTime(455),
      );
      final public = PublicProfile.fromUserProfile(profile);
      final payload = public.toOwnerEditableFirestore();
      final serialized = payload.toString();

      for (final key in const [
        'birthDate',
        'birthTimeKnown',
        'birthTimeMinutes',
        'birthCalendarType',
        'birthTimeZone',
        'sajuInputVersion',
        'birthProfileUpdatedAt',
      ]) {
        expect(payload.containsKey(key), isFalse, reason: 'key=$key');
      }
      // 정확한 생년월일·시각이 문자열로도 새어나가지 않는다.
      expect(serialized.contains('455'), isFalse);
      expect(serialized.contains('1995-02-04'), isFalse);
      // 나이는 공개된다 — 이것이 유일하게 허용된 파생값이다.
      expect(public.age, greaterThan(0));
    });

    test('UserProfile은 기존 문서를 legacyMissing으로 안전하게 읽는다', () {
      final profile = _profile();
      expect(profile.birthProfile.isValid, isTrue);
      final legacy = profile.copyWith(
        birthProfile: const BirthProfile.legacyMissing(),
      );
      expect(legacy.birthProfile.needsCompletion, isTrue);
    });
  });
}
