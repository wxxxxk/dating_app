import 'package:cloud_firestore/cloud_firestore.dart';

/// 공개 프로필에 서버가 저장하는 AI 키워드 요약.
///
/// `publicProfiles/{uid}.aiKeywordSummary`는 공개 read 전용, client write 금지
/// 필드다. 이 모델은 Firestore 원시 값을 안전하게 읽기만 하며 client write용
/// serializer는 제공하지 않는다.
class AiKeywordSummary {
  static final RegExp _sourceHashPattern = RegExp(r'^[0-9a-f]{64}$');
  static final RegExp _keywordPattern = RegExp(
    r'^[가-힣A-Za-z0-9]+(?: [가-힣A-Za-z0-9]+)*$',
  );
  static final RegExp _phonePattern = RegExp(r'^0\d{1,2} ?\d{3,4} ?\d{4}$');

  static const Set<String> _allowedKeys = {
    'keywords',
    'sourceHash',
    'promptVersion',
    'generator',
    'model',
    'generatedAt',
  };

  static const Set<String> _allowedGenerators = {'ai', 'fallback'};

  final List<String> keywords;
  final String sourceHash;
  final int promptVersion;
  final String generator;
  final String? model;
  final DateTime generatedAt;

  AiKeywordSummary({
    required List<String> keywords,
    required this.sourceHash,
    required this.promptVersion,
    required this.generator,
    required this.model,
    required this.generatedAt,
  }) : keywords = List<String>.unmodifiable(keywords);

  /// Firestore 원시 map을 공개 표시용 요약으로 복원한다.
  ///
  /// 서버 결과가 malformed여도 전체 PublicProfile parsing을 깨지 않도록,
  /// 계약 위반은 예외 대신 null로 처리한다.
  static AiKeywordSummary? tryFromMap(Object? raw) {
    if (raw is! Map) return null;
    if (!raw.keys.every((key) => key is String)) return null;

    final map = Map<String, Object?>.from(raw);
    final keys = map.keys.toSet();
    if (keys.length != _allowedKeys.length || !keys.containsAll(_allowedKeys)) {
      return null;
    }

    final keywords = _parseKeywords(map['keywords']);
    if (keywords == null) return null;

    final sourceHash = map['sourceHash'];
    if (sourceHash is! String || !_sourceHashPattern.hasMatch(sourceHash)) {
      return null;
    }

    final promptVersion = map['promptVersion'];
    if (promptVersion is! int || promptVersion < 1) return null;

    final generator = map['generator'];
    if (generator is! String || !_allowedGenerators.contains(generator)) {
      return null;
    }

    final model = map['model'];
    if (generator == 'ai') {
      if (model is! String || model.trim().isEmpty) return null;
    } else if (model != null) {
      return null;
    }

    final generatedAt = map['generatedAt'];
    if (generatedAt is! Timestamp) return null;

    return AiKeywordSummary(
      keywords: keywords,
      sourceHash: sourceHash,
      promptVersion: promptVersion,
      generator: generator,
      model: model as String?,
      generatedAt: generatedAt.toDate(),
    );
  }

  static List<String>? _parseKeywords(Object? raw) {
    if (raw is! List || raw.length > 5) return null;

    final result = <String>[];
    final canonicalKeys = <String>{};
    for (final value in raw) {
      if (value is! String || !_keywordValid(value)) return null;
      final canonical = value.toLowerCase().replaceAll(' ', '');
      if (!canonicalKeys.add(canonical)) return null;
      result.add(value);
    }
    return result;
  }

  static bool _keywordValid(String value) {
    if (value.isEmpty || value.length > 14) return false;
    if (value.trim() != value) return false;
    if (value.contains('  ')) return false;
    if (!_keywordPattern.hasMatch(value)) return false;

    final lower = value.toLowerCase();
    if (lower.contains('http') || lower.startsWith('www')) return false;
    if (_phonePattern.hasMatch(value)) return false;
    return true;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! AiKeywordSummary) return false;
    if (keywords.length != other.keywords.length) return false;
    for (var i = 0; i < keywords.length; i += 1) {
      if (keywords[i] != other.keywords[i]) return false;
    }
    return sourceHash == other.sourceHash &&
        promptVersion == other.promptVersion &&
        generator == other.generator &&
        model == other.model &&
        generatedAt == other.generatedAt;
  }

  @override
  int get hashCode => Object.hash(
    Object.hashAll(keywords),
    sourceHash,
    promptVersion,
    generator,
    model,
    generatedAt,
  );
}
