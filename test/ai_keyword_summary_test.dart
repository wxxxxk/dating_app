import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:dating_app/models/ai_keyword_summary.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> summaryMap({
  Object? keywords = const ['차분한 대화', '주말 산책', '진지한 관계'],
  Object? sourceHash =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  Object? promptVersion = 1,
  Object? generator = 'ai',
  Object? model = 'test-model',
  Object? generatedAt,
}) {
  return {
    'keywords': keywords,
    'sourceHash': sourceHash,
    'promptVersion': promptVersion,
    'generator': generator,
    'model': model,
    'generatedAt': generatedAt ?? Timestamp.fromDate(DateTime(2026, 7, 19)),
  };
}

void main() {
  group('AiKeywordSummary.tryFromMap', () {
    test('valid AI summary parsing', () {
      final summary = AiKeywordSummary.tryFromMap(summaryMap());

      expect(summary, isNotNull);
      expect(summary!.keywords, ['차분한 대화', '주말 산책', '진지한 관계']);
      expect(
        summary.sourceHash,
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      );
      expect(summary.promptVersion, 1);
      expect(summary.generator, 'ai');
      expect(summary.model, 'test-model');
      expect(summary.generatedAt, DateTime(2026, 7, 19));
    });

    test('valid fallback summary parsing', () {
      final summary = AiKeywordSummary.tryFromMap(
        summaryMap(generator: 'fallback', model: null),
      );

      expect(summary, isNotNull);
      expect(summary!.generator, 'fallback');
      expect(summary.model, isNull);
    });

    test('keywords unmodifiable', () {
      final summary = AiKeywordSummary.tryFromMap(summaryMap())!;

      expect(() => summary.keywords.add('변조'), throwsUnsupportedError);
    });

    test('입력 list/map 변경이 parsed summary를 바꾸지 않는다', () {
      final keywords = ['차분한 대화', '주말 산책'];
      final raw = summaryMap(keywords: keywords);
      final summary = AiKeywordSummary.tryFromMap(raw)!;

      keywords.add('변조');
      raw['sourceHash'] =
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

      expect(summary.keywords, ['차분한 대화', '주말 산책']);
      expect(
        summary.sourceHash,
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      );
    });

    test('empty keywords 허용', () {
      final summary = AiKeywordSummary.tryFromMap(summaryMap(keywords: []));

      expect(summary, isNotNull);
      expect(summary!.keywords, isEmpty);
    });

    test('keywords가 list가 아니거나 keyword가 String이 아니면 거부', () {
      expect(
        AiKeywordSummary.tryFromMap(summaryMap(keywords: '차분한 대화')),
        isNull,
      );
      expect(
        AiKeywordSummary.tryFromMap(summaryMap(keywords: ['산책', 3])),
        isNull,
      );
    });

    test('5개 keywords 허용, 6개 keywords 거부', () {
      expect(
        AiKeywordSummary.tryFromMap(
          summaryMap(keywords: ['하나', '둘', '셋', '넷', '다섯']),
        ),
        isNotNull,
      );
      expect(
        AiKeywordSummary.tryFromMap(
          summaryMap(keywords: ['하나', '둘', '셋', '넷', '다섯', '여섯']),
        ),
        isNull,
      );
    });

    test('keyword 길이와 공백 계약을 검증한다', () {
      expect(AiKeywordSummary.tryFromMap(summaryMap(keywords: [''])), isNull);
      expect(
        AiKeywordSummary.tryFromMap(summaryMap(keywords: ['가나다라마바사아자차카타파하'])),
        isNotNull,
      );
      expect(
        AiKeywordSummary.tryFromMap(summaryMap(keywords: ['가나다라마바사아자차카타파하가'])),
        isNull,
      );
      expect(
        AiKeywordSummary.tryFromMap(summaryMap(keywords: [' 차분한 대화'])),
        isNull,
      );
      expect(
        AiKeywordSummary.tryFromMap(summaryMap(keywords: ['차분한 대화 '])),
        isNull,
      );
      expect(
        AiKeywordSummary.tryFromMap(summaryMap(keywords: ['차분한  대화'])),
        isNull,
      );
    });

    test('keyword 허용 문자와 연락처 재노출 위험을 검증한다', () {
      for (final keyword in [
        '차분한 대화🙂',
        '#차분한대화',
        '@calm',
        'http://a.com',
        'www example',
        '01012345678',
        '010 1234 5678',
      ]) {
        expect(
          AiKeywordSummary.tryFromMap(summaryMap(keywords: [keyword])),
          isNull,
          reason: keyword,
        );
      }
    });

    test('duplicate keyword를 canonical key로 거부한다', () {
      expect(
        AiKeywordSummary.tryFromMap(summaryMap(keywords: ['산책', '산책'])),
        isNull,
      );
      expect(
        AiKeywordSummary.tryFromMap(
          summaryMap(keywords: ['Calm Talk', 'calmtalk']),
        ),
        isNull,
      );
    });

    test('sourceHash 형식을 검증한다', () {
      expect(
        AiKeywordSummary.tryFromMap(
          summaryMap(sourceHash: List.filled(63, 'a').join()),
        ),
        isNull,
      );
      expect(
        AiKeywordSummary.tryFromMap(
          summaryMap(
            sourceHash:
                'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
          ),
        ),
        isNull,
      );
    });

    test('promptVersion과 generator/model 조합을 검증한다', () {
      expect(AiKeywordSummary.tryFromMap(summaryMap(promptVersion: 0)), isNull);
      expect(
        AiKeywordSummary.tryFromMap(summaryMap(generator: 'manual')),
        isNull,
      );
      expect(
        AiKeywordSummary.tryFromMap(summaryMap(generator: 'ai', model: null)),
        isNull,
      );
      expect(
        AiKeywordSummary.tryFromMap(
          summaryMap(generator: 'fallback', model: 'test-model'),
        ),
        isNull,
      );
    });

    test('generatedAt 누락 또는 타입 위반을 거부한다', () {
      final missing = summaryMap()..remove('generatedAt');
      expect(AiKeywordSummary.tryFromMap(missing), isNull);
      expect(
        AiKeywordSummary.tryFromMap(summaryMap(generatedAt: '2026-07-19')),
        isNull,
      );
    });

    test('unknown map field와 non-map 입력을 거부한다', () {
      final unknown = summaryMap()..['extra'] = true;

      expect(AiKeywordSummary.tryFromMap(unknown), isNull);
      expect(AiKeywordSummary.tryFromMap(null), isNull);
      expect(AiKeywordSummary.tryFromMap('not_a_map'), isNull);
    });
  });
}
