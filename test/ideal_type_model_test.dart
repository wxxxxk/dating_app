import 'package:dating_app/models/ideal_type_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('IdealTypeOptionSets 성별별 taxonomy', () {
    test('여성/남성/상관없음의 mood 목록이 서로 다르게 분리된다', () {
      final female = IdealTypeOptionSets.moodsForGender('female');
      final male = IdealTypeOptionSets.moodsForGender('male');
      final neutral = IdealTypeOptionSets.moodsForGender('all');

      expect(female, isNot(equals(male)));
      expect(female.map((o) => o.key), contains('lovely'));
      expect(male.map((o) => o.key), contains('dandy_mood'));
      expect(neutral, equals(IdealTypeOptionSets.moods));
    });

    test('여성/남성 style/impression 목록도 분리된다', () {
      final femaleStyles = IdealTypeOptionSets.stylesForGender('female');
      final maleStyles = IdealTypeOptionSets.stylesForGender('male');
      expect(femaleStyles.map((o) => o.key), contains('feminine'));
      expect(maleStyles.map((o) => o.key), contains('dandy_casual'));

      final femaleImpressions = IdealTypeOptionSets.impressionsForGender(
        'female',
      );
      final maleImpressions = IdealTypeOptionSets.impressionsForGender(
        'male',
      );
      expect(femaleImpressions.map((o) => o.key), contains('luxury_vibe'));
      expect(maleImpressions.map((o) => o.key), contains('confident'));
    });

    test('알 수 없는 gender 값은 상관없음(neutral) 목록으로 대체된다', () {
      final unknown = IdealTypeOptionSets.moodsForGender('unknown');
      expect(unknown, equals(IdealTypeOptionSets.moods));
    });

    test('gender별 기본값은 항상 그 gender의 유효한 목록에 속한다', () {
      for (final gender in ['female', 'male', 'all']) {
        expect(
          IdealTypeOptionSets.isMoodValidForGender(
            gender,
            IdealTypeOptionSets.defaultMoodForGender(gender),
          ),
          isTrue,
          reason: 'gender=$gender',
        );
        expect(
          IdealTypeOptionSets.isStyleValidForGender(
            gender,
            IdealTypeOptionSets.defaultStyleForGender(gender),
          ),
          isTrue,
          reason: 'gender=$gender',
        );
        expect(
          IdealTypeOptionSets.isImpressionValidForGender(
            gender,
            IdealTypeOptionSets.defaultImpressionForGender(gender),
          ),
          isTrue,
          reason: 'gender=$gender',
        );
        expect(
          IdealTypeOptionSets.isHairValidForGender(
            gender,
            IdealTypeOptionSets.defaultHairForGender(gender),
          ),
          isTrue,
          reason: 'gender=$gender',
        );
      }
    });

    test('한쪽 성별에만 있는 키는 다른 성별에서는 무효로 판정된다', () {
      // 'lovely'는 female mood 전용 — male 목록에는 없어야 한다.
      expect(IdealTypeOptionSets.isMoodValidForGender('male', 'lovely'), isFalse);
      // 'dandy_mood'는 male mood 전용 — female 목록에는 없어야 한다.
      expect(
        IdealTypeOptionSets.isMoodValidForGender('female', 'dandy_mood'),
        isFalse,
      );
      // hair도 기존 패턴 그대로 유지되는지 확인(회귀 방지).
      expect(IdealTypeOptionSets.isHairValidForGender('male', 'long_straight'), isFalse);
      expect(IdealTypeOptionSets.isHairValidForGender('female', 'two_block'), isFalse);
    });
  });

  group('기존 key backward compatibility', () {
    test('상관없음(all)에서 기존 중립 mood/style/impression key가 여전히 유효하다', () {
      for (final key in ['pure', 'chic', 'playful', 'intellectual', 'gentle']) {
        expect(IdealTypeOptionSets.isMoodValidForGender('all', key), isTrue);
      }
      for (final key in ['casual', 'formal', 'street', 'minimal']) {
        expect(IdealTypeOptionSets.isStyleValidForGender('all', key), isTrue);
      }
      for (final key in ['bright_smile', 'calm', 'warm']) {
        expect(
          IdealTypeOptionSets.isImpressionValidForGender('all', key),
          isTrue,
        );
      }
    });

    test('기존 hair key(성별별)는 여전히 유효하다', () {
      for (final key in ['long_straight', 'bob', 'wavy', 'short']) {
        expect(IdealTypeOptionSets.isHairValidForGender('female', key), isTrue);
      }
      for (final key in ['short', 'two_block', 'dandy', 'medium']) {
        expect(IdealTypeOptionSets.isHairValidForGender('male', key), isTrue);
      }
    });
  });

  group('IdealTypeImageOptions.refinementText', () {
    IdealTypeImageOptions buildOptions({String refinementText = ''}) {
      return IdealTypeImageOptions(
        gender: 'all',
        idealTags: const [],
        mood: 'gentle',
        style: 'casual',
        hair: 'wavy',
        impression: 'warm',
        background: 'studio',
        refinementText: refinementText,
      );
    }

    test('기본값은 빈 문자열이다', () {
      const options = IdealTypeImageOptions(
        gender: 'all',
        idealTags: [],
        mood: 'gentle',
        style: 'casual',
        hair: 'wavy',
        impression: 'warm',
        background: 'studio',
      );
      expect(options.refinementText, isEmpty);
    });

    test('toMap()에 refinementText가 포함된다', () {
      final options = buildOptions(refinementText: '더 자연스럽게');
      final map = options.toMap();
      expect(map['refinementText'], '더 자연스럽게');
    });

    test('copyWith로 refinementText를 갱신할 수 있고, 넘기지 않으면 기존 값을 유지한다', () {
      final options = buildOptions(refinementText: '웃는 느낌으로');
      final updated = options.copyWith(refinementText: '배경은 더 깔끔하게');
      expect(updated.refinementText, '배경은 더 깔끔하게');

      final unchanged = options.copyWith(mood: 'chic');
      expect(unchanged.refinementText, '웃는 느낌으로');
      expect(unchanged.mood, 'chic');
    });
  });

  group('IdealTypeImageResult.fromMap 안전 파싱(회귀 방지)', () {
    test('신규 metadata 필드가 없어도 크래시 없이 null로 채운다', () {
      final result = IdealTypeImageResult.fromMap({
        'imageUrl': 'https://example.com/a.png',
        'storagePath': 'users/x/idealType/a.png',
        'summary': '부드러운 · 캐주얼',
        'inputHash': 'abc123',
      });
      expect(result.provider, isNull);
      expect(result.model, isNull);
      expect(result.imageUrl, 'https://example.com/a.png');
      expect(result.options, isNull);
    });

    test('options 필드가 있으면 IdealTypeImageOptions로 파싱된다', () {
      final result = IdealTypeImageResult.fromMap({
        'imageUrl': 'https://example.com/a.png',
        'storagePath': 'users/x/idealType/a.png',
        'summary': '러블리한 · 페미닌',
        'inputHash': 'abc123',
        'options': {
          'gender': 'female',
          'idealTags': ['kind', 'funny'],
          'mood': 'lovely',
          'style': 'feminine',
          'hair': 'long_straight',
          'impression': 'warm',
          'background': 'outdoor',
        },
      });
      expect(result.options, isNotNull);
      expect(result.options!.gender, 'female');
      expect(result.options!.mood, 'lovely');
      expect(result.options!.idealTags, ['kind', 'funny']);
    });

    test('options 필드 일부가 누락되면 안전하게 null로 처리한다(크래시 없음)', () {
      final result = IdealTypeImageResult.fromMap({
        'imageUrl': 'https://example.com/a.png',
        'storagePath': 'p',
        'summary': 's',
        'inputHash': 'h',
        'options': {'gender': 'female'},
      });
      expect(result.options, isNull);
    });
  });
}
