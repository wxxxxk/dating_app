// ignore_for_file: invalid_use_of_protected_member

import 'package:cloud_functions/cloud_functions.dart';
import 'package:dating_app/services/profile/profile_keyword_summary_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'generate sends empty payload by default and omits refresh false',
    () async {
      late Map<String, Object?> capturedPayload;
      final service = ProfileKeywordSummaryService.withInvoker((payload) async {
        capturedPayload = Map<String, Object?>.from(payload);
        return {
          'keywords': ['차분한 대화', '주말 산책', '진지한 관계'],
          'generator': 'ai',
          'cacheHit': false,
        };
      });

      final result = await service.generate();

      expect(capturedPayload, isEmpty);
      expect(result.generator, 'ai');
      expect(result.cacheHit, isFalse);
    },
  );

  test('generate sends refresh true only when requested', () async {
    late Map<String, Object?> capturedPayload;
    final service = ProfileKeywordSummaryService.withInvoker((payload) async {
      capturedPayload = Map<String, Object?>.from(payload);
      return {
        'keywords': <String>[],
        'generator': 'fallback',
        'cacheHit': true,
      };
    });

    final result = await service.generate(refresh: true);

    expect(capturedPayload, {'refresh': true});
    expect(result.keywords, isEmpty);
    expect(result.generator, 'fallback');
  });

  test('parse accepts valid AI and fallback responses', () {
    final ai = ProfileKeywordSummaryGenerationResult.parse({
      'keywords': ['차분한 대화', '주말 산책', '진지한 관계'],
      'generator': 'ai',
      'cacheHit': false,
    });
    final fallback = ProfileKeywordSummaryGenerationResult.parse({
      'keywords': ['산책'],
      'generator': 'fallback',
      'cacheHit': true,
    });

    expect(ai.keywords, ['차분한 대화', '주말 산책', '진지한 관계']);
    expect(fallback.keywords, ['산책']);
  });

  test(
    'parse accepts zero and five keywords, and keywords are unmodifiable',
    () {
      final empty = ProfileKeywordSummaryGenerationResult.parse({
        'keywords': <String>[],
        'generator': 'fallback',
        'cacheHit': false,
      });
      final five = ProfileKeywordSummaryGenerationResult.parse({
        'keywords': ['차분한', '산책', '영화', '맛집 탐방', '진지한 관계'],
        'generator': 'ai',
        'cacheHit': false,
      });

      expect(empty.keywords, isEmpty);
      expect(five.keywords, hasLength(5));
      expect(() => five.keywords.add('추가'), throwsUnsupportedError);
    },
  );

  test('parse rejects malformed response shape', () {
    final invalidResponses = <Object?>[
      null,
      'bad',
      {
        'keywords': <String>[],
        'generator': 'fallback',
        'cacheHit': false,
        'extra': true,
      },
      {'keywords': '차분한', 'generator': 'ai', 'cacheHit': false},
      {
        'keywords': ['차분한'],
        'generator': 'unknown',
        'cacheHit': false,
      },
      {'keywords': <String>[], 'generator': 'ai', 'cacheHit': 'false'},
    ];

    for (final raw in invalidResponses) {
      expect(
        () => ProfileKeywordSummaryGenerationResult.parse(raw),
        throwsA(
          isA<ProfileKeywordSummaryFailure>().having(
            (e) => e.code,
            'code',
            'malformed-response',
          ),
        ),
      );
    }
  });

  test('parse rejects malformed keywords', () {
    final invalidKeywordLists = <List<Object?>>[
      ['차분한 대화', 1, '주말 산책'],
      ['차분한 대화', '주말 산책', '진지한 관계', '영화', '맛집', '산책'],
      [''],
      ['abcdefghijklmnx'],
      [' 차분한 대화'],
      ['차분한  대화'],
      ['차분한😀'],
      ['#차분한'],
      ['@id'],
      ['https://example.com'],
      ['010 1234 5678'],
      ['Calm Talk', 'calmtalk'],
    ];

    for (final keywords in invalidKeywordLists) {
      expect(
        () => ProfileKeywordSummaryGenerationResult.parse({
          'keywords': keywords,
          'generator': 'ai',
          'cacheHit': false,
        }),
        throwsA(isA<ProfileKeywordSummaryFailure>()),
      );
    }
  });

  test(
    'generate converts generic invoker errors to typed unknown failure',
    () async {
      final service = ProfileKeywordSummaryService.withInvoker((payload) async {
        throw StateError('boom');
      });

      await expectLater(
        service.generate(),
        throwsA(
          isA<ProfileKeywordSummaryFailure>().having(
            (e) => e.code,
            'code',
            'unknown',
          ),
        ),
      );
    },
  );

  test('generate preserves FirebaseFunctionsException code only', () async {
    final service = ProfileKeywordSummaryService.withInvoker((payload) async {
      throw FirebaseFunctionsException(
        code: 'resource-exhausted',
        message: 'raw server message',
      );
    });

    await expectLater(
      service.generate(),
      throwsA(
        isA<ProfileKeywordSummaryFailure>().having(
          (e) => e.code,
          'code',
          'resource-exhausted',
        ),
      ),
    );
  });

  test(
    'generate maps unknown FirebaseFunctionsException code to unknown',
    () async {
      final service = ProfileKeywordSummaryService.withInvoker((payload) async {
        throw FirebaseFunctionsException(
          code: 'custom-code',
          message: 'raw server message',
        );
      });

      await expectLater(
        service.generate(),
        throwsA(
          isA<ProfileKeywordSummaryFailure>().having(
            (e) => e.code,
            'code',
            'unknown',
          ),
        ),
      );
    },
  );
}
