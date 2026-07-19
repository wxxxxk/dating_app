import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

import '../../core/constants/app_constants.dart';

typedef ProfileKeywordSummaryInvoker =
    Future<Object?> Function(Map<String, Object?> payload);

class ProfileKeywordSummaryFailure implements Exception {
  final String code;

  const ProfileKeywordSummaryFailure(this.code);

  @override
  String toString() => 'ProfileKeywordSummaryFailure($code)';
}

class ProfileKeywordSummaryGenerationResult {
  final List<String> keywords;
  final String generator;
  final bool cacheHit;

  ProfileKeywordSummaryGenerationResult({
    required List<String> keywords,
    required this.generator,
    required this.cacheHit,
  }) : keywords = List<String>.unmodifiable(keywords);

  static ProfileKeywordSummaryGenerationResult parse(Object? raw) {
    if (raw is! Map) {
      throw const ProfileKeywordSummaryFailure('malformed-response');
    }

    const expectedKeys = {'keywords', 'generator', 'cacheHit'};
    if (raw.length != expectedKeys.length ||
        raw.keys.any((key) => key is! String || !expectedKeys.contains(key))) {
      throw const ProfileKeywordSummaryFailure('malformed-response');
    }

    final rawKeywords = raw['keywords'];
    final generator = raw['generator'];
    final cacheHit = raw['cacheHit'];
    if (rawKeywords is! List ||
        generator is! String ||
        (generator != 'ai' && generator != 'fallback') ||
        cacheHit is! bool) {
      throw const ProfileKeywordSummaryFailure('malformed-response');
    }

    final keywords = _parseKeywords(rawKeywords);
    return ProfileKeywordSummaryGenerationResult(
      keywords: keywords,
      generator: generator,
      cacheHit: cacheHit,
    );
  }
}

class ProfileKeywordSummaryService {
  ProfileKeywordSummaryService({FirebaseFunctions? functions})
    : _invoke = _firebaseInvoker(
        functions ??
            FirebaseFunctions.instanceFor(region: AppConstants.functionsRegion),
      );

  @visibleForTesting
  ProfileKeywordSummaryService.withInvoker(ProfileKeywordSummaryInvoker invoker)
    : _invoke = invoker;

  final ProfileKeywordSummaryInvoker _invoke;

  static ProfileKeywordSummaryInvoker _firebaseInvoker(
    FirebaseFunctions functions,
  ) {
    return (payload) async {
      final callable = functions.httpsCallable('generateProfileKeywordSummary');
      final result = await callable.call<Map<String, dynamic>>(payload);
      return result.data;
    };
  }

  Future<ProfileKeywordSummaryGenerationResult> generate({
    bool refresh = false,
  }) async {
    final payload = <String, Object?>{};
    if (refresh) {
      payload['refresh'] = true;
    }

    try {
      final raw = await _invoke(payload);
      return ProfileKeywordSummaryGenerationResult.parse(raw);
    } on ProfileKeywordSummaryFailure {
      rethrow;
    } on FirebaseFunctionsException catch (e) {
      throw ProfileKeywordSummaryFailure(_normalizeFailureCode(e.code));
    } catch (_) {
      throw const ProfileKeywordSummaryFailure('unknown');
    }
  }
}

const _allowedFailureCodes = {
  'unauthenticated',
  'invalid-argument',
  'not-found',
  'resource-exhausted',
  'failed-precondition',
  'internal',
  'unavailable',
  'deadline-exceeded',
  'malformed-response',
  'unknown',
};

final _keywordPattern = RegExp(r'^[가-힣A-Za-z0-9]+(?: [가-힣A-Za-z0-9]+)*$');
final _urlPattern = RegExp(
  r'(?:https?:\/\/|www\.|[A-Za-z0-9-]+\.(?:com|net|org|kr|co|io)\b)',
  caseSensitive: false,
);

List<String> _parseKeywords(List<Object?> rawKeywords) {
  if (rawKeywords.length > 5) {
    throw const ProfileKeywordSummaryFailure('malformed-response');
  }

  final keywords = <String>[];
  final seen = <String>{};
  for (final rawKeyword in rawKeywords) {
    if (rawKeyword is! String || !_isValidKeyword(rawKeyword)) {
      throw const ProfileKeywordSummaryFailure('malformed-response');
    }
    final canonical = rawKeyword.toLowerCase().replaceAll(RegExp(r'\s+'), '');
    if (!seen.add(canonical)) {
      throw const ProfileKeywordSummaryFailure('malformed-response');
    }
    keywords.add(rawKeyword);
  }
  return keywords;
}

bool _isValidKeyword(String value) {
  if (value.isEmpty ||
      value.length > 14 ||
      value.trim() != value ||
      value.contains(RegExp(r'\s{2,}')) ||
      value.contains('#') ||
      value.contains('@') ||
      _urlPattern.hasMatch(value) ||
      _looksLikePhoneNumber(value)) {
    return false;
  }
  return _keywordPattern.hasMatch(value);
}

bool _looksLikePhoneNumber(String value) {
  final compact = value.replaceAll(RegExp(r'\s+'), '');
  final digits = compact.replaceAll(RegExp(r'\D'), '');
  if (digits.length < 7) {
    return false;
  }
  return RegExp(r'^(?:\+?82|0?10|0[2-9])').hasMatch(compact) ||
      RegExp(r'^[+\d\s().-]+$').hasMatch(value);
}

String _normalizeFailureCode(String code) {
  return _allowedFailureCodes.contains(code) ? code : 'unknown';
}
