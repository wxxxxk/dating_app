class IdealTypeImageOptions {
  final String gender;
  final List<String> idealTags;
  final String mood;
  final String style;
  final String hair;
  final String impression;
  final String background;
  // 사용자가 직접 입력하는 짧은 수정 요청(예: "더 자연스럽게"). 서버가 항상
  // 길이 제한/키워드 차단을 거친 뒤에만 prompt에 반영한다 — 클라이언트는
  // 이 문자열을 그대로 보내기만 하고, 최종 반영 여부는 서버가 결정한다.
  final String refinementText;

  const IdealTypeImageOptions({
    required this.gender,
    required this.idealTags,
    required this.mood,
    required this.style,
    required this.hair,
    required this.impression,
    required this.background,
    this.refinementText = '',
  });

  Map<String, dynamic> toMap() {
    return {
      'gender': gender,
      'idealTags': idealTags,
      'mood': mood,
      'style': style,
      'hair': hair,
      'impression': impression,
      'background': background,
      'refinementText': refinementText,
    };
  }

  IdealTypeImageOptions copyWith({
    String? gender,
    List<String>? idealTags,
    String? mood,
    String? style,
    String? hair,
    String? impression,
    String? background,
    String? refinementText,
  }) {
    return IdealTypeImageOptions(
      gender: gender ?? this.gender,
      idealTags: idealTags ?? this.idealTags,
      mood: mood ?? this.mood,
      style: style ?? this.style,
      hair: hair ?? this.hair,
      impression: impression ?? this.impression,
      background: background ?? this.background,
      refinementText: refinementText ?? this.refinementText,
    );
  }
}

class IdealTypeImageResult {
  final String imageUrl;
  final String storagePath;
  final String summary;
  final String safetyLabel;
  final String inputHash;

  // 아래는 provider abstraction 도입과 함께 추가된 선택적 메타데이터다.
  // 현재는 어떤 화면에도 노출하지 않는다 — 나중에 provider별 결과를 비교하거나
  // 디버깅할 때 쓰기 위한 용도로만 파싱해 둔다. 기존 서버 응답에는 없던
  // 필드라 전부 nullable이고, 없으면 그냥 null이다(에러 아님).
  final String? provider;
  final String? model;
  final String? promptVersion;
  final String? safetyPolicyVersion;
  final int? imageCount;
  final bool? syntheticHuman;

  // 서버가 이 이미지를 생성할 때 실제로 쓴 옵션. 화면이 캐시를 불러올 때
  // 이 값으로 _options를 다시 맞춰서, "선택한 취향" 칩이 화면에 보이는
  // 이미지와 다른 조건을 표시하는 혼동(재진입 시 _options가 기본값으로
  // 초기화되는 문제)을 막는 데 쓴다. 없어도(null) 에러가 아니다.
  final IdealTypeImageOptions? options;

  const IdealTypeImageResult({
    required this.imageUrl,
    required this.storagePath,
    required this.summary,
    required this.safetyLabel,
    required this.inputHash,
    this.provider,
    this.model,
    this.promptVersion,
    this.safetyPolicyVersion,
    this.imageCount,
    this.syntheticHuman,
    this.options,
  });

  static IdealTypeImageOptions? _parseOptions(dynamic raw) {
    if (raw is! Map) return null;
    final gender = raw['gender'];
    final mood = raw['mood'];
    final style = raw['style'];
    final hair = raw['hair'];
    final impression = raw['impression'];
    final background = raw['background'];
    if (gender is! String ||
        mood is! String ||
        style is! String ||
        hair is! String ||
        impression is! String ||
        background is! String) {
      return null;
    }
    final idealTagsRaw = raw['idealTags'];
    final idealTags = idealTagsRaw is List
        ? idealTagsRaw.map((e) => e.toString()).toList()
        : const <String>[];
    return IdealTypeImageOptions(
      gender: gender,
      idealTags: idealTags,
      mood: mood,
      style: style,
      hair: hair,
      impression: impression,
      background: background,
    );
  }

  factory IdealTypeImageResult.fromMap(Map<String, dynamic> map) {
    return IdealTypeImageResult(
      imageUrl: map['imageUrl'] as String? ?? '',
      storagePath: map['storagePath'] as String? ?? '',
      summary: map['summary'] as String? ?? '',
      safetyLabel:
          map['safetyLabel'] as String? ??
          'AI가 생성한 가상의 이미지입니다. 실제 앱 사용자가 아닙니다.',
      inputHash: map['inputHash'] as String? ?? '',
      provider: map['provider'] as String?,
      model: map['model'] as String?,
      promptVersion: map['promptVersion'] as String?,
      safetyPolicyVersion: map['safetyPolicyVersion'] as String?,
      imageCount: map['imageCount'] as int?,
      syntheticHuman: map['syntheticHuman'] as bool?,
      options: _parseOptions(map['options']),
    );
  }
}

class IdealTypeOption {
  final String key;
  final String label;

  const IdealTypeOption({required this.key, required this.label});
}

class IdealTypeOptionSets {
  static const genders = [
    IdealTypeOption(key: 'all', label: '상관없음'),
    IdealTypeOption(key: 'female', label: '여성'),
    IdealTypeOption(key: 'male', label: '남성'),
  ];

  // '상관없음'(gender == 'all')일 때 쓰는 중립 옵션. 기존 앱 버전/캐시가 이
  // key들을 그대로 쓰고 있으므로 이름도 값도 바꾸지 않는다.
  static const moods = [
    IdealTypeOption(key: 'pure', label: '청순한'),
    IdealTypeOption(key: 'chic', label: '시크한'),
    IdealTypeOption(key: 'playful', label: '발랄한'),
    IdealTypeOption(key: 'intellectual', label: '지적인'),
    IdealTypeOption(key: 'gentle', label: '부드러운'),
  ];

  static const femaleMoods = [
    IdealTypeOption(key: 'pure', label: '청순한'),
    IdealTypeOption(key: 'refined', label: '세련된'),
    IdealTypeOption(key: 'lovely', label: '러블리한'),
    IdealTypeOption(key: 'calm', label: '차분한'),
    IdealTypeOption(key: 'luxury', label: '고급스러운'),
    IdealTypeOption(key: 'mysterious', label: '신비로운'),
  ];

  static const maleMoods = [
    IdealTypeOption(key: 'dandy_mood', label: '댄디한'),
    IdealTypeOption(key: 'intellectual', label: '지적인'),
    IdealTypeOption(key: 'warm_hearted', label: '훈훈한'),
    IdealTypeOption(key: 'chic', label: '시크한'),
    IdealTypeOption(key: 'mature', label: '성숙한'),
    IdealTypeOption(key: 'sporty', label: '스포티한'),
  ];

  static List<IdealTypeOption> moodsForGender(String gender) {
    if (gender == 'male') return maleMoods;
    if (gender == 'female') return femaleMoods;
    return moods;
  }

  static String defaultMoodForGender(String gender) =>
      moodsForGender(gender).first.key;

  static bool isMoodValidForGender(String gender, String mood) {
    return moodsForGender(gender).any((option) => option.key == mood);
  }

  static const styles = [
    IdealTypeOption(key: 'casual', label: '캐주얼'),
    IdealTypeOption(key: 'formal', label: '포멀'),
    IdealTypeOption(key: 'street', label: '스트릿'),
    IdealTypeOption(key: 'minimal', label: '미니멀'),
  ];

  static const femaleStyles = [
    IdealTypeOption(key: 'minimal', label: '미니멀'),
    IdealTypeOption(key: 'natural', label: '내추럴'),
    IdealTypeOption(key: 'feminine', label: '페미닌'),
    IdealTypeOption(key: 'modern_casual', label: '모던 캐주얼'),
    IdealTypeOption(key: 'formal', label: '포멀'),
    IdealTypeOption(key: 'sensitive', label: '감성적인'),
  ];

  static const maleStyles = [
    IdealTypeOption(key: 'minimal', label: '미니멀'),
    IdealTypeOption(key: 'dandy_casual', label: '댄디 캐주얼'),
    IdealTypeOption(key: 'formal', label: '포멀'),
    IdealTypeOption(key: 'street', label: '스트릿 캐주얼'),
    IdealTypeOption(key: 'natural', label: '내추럴'),
    IdealTypeOption(key: 'clean_shirt', label: '깔끔한 셔츠 스타일'),
  ];

  static List<IdealTypeOption> stylesForGender(String gender) {
    if (gender == 'male') return maleStyles;
    if (gender == 'female') return femaleStyles;
    return styles;
  }

  static String defaultStyleForGender(String gender) =>
      stylesForGender(gender).first.key;

  static bool isStyleValidForGender(String gender, String style) {
    return stylesForGender(gender).any((option) => option.key == style);
  }

  static const femaleHairs = [
    IdealTypeOption(key: 'long_straight', label: '긴 생머리'),
    IdealTypeOption(key: 'bob', label: '단발'),
    IdealTypeOption(key: 'wavy', label: '웨이브'),
    IdealTypeOption(key: 'short', label: '숏컷'),
    IdealTypeOption(key: 'layered', label: '레이어드 컷'),
  ];

  static const maleHairs = [
    IdealTypeOption(key: 'short', label: '숏컷'),
    IdealTypeOption(key: 'two_block', label: '투블럭'),
    IdealTypeOption(key: 'dandy', label: '댄디컷'),
    IdealTypeOption(key: 'medium', label: '미디엄 헤어'),
    IdealTypeOption(key: 'regent', label: '리젠트'),
  ];

  static const allHairs = [
    IdealTypeOption(key: 'long_straight', label: '긴 생머리'),
    IdealTypeOption(key: 'bob', label: '단발'),
    IdealTypeOption(key: 'wavy', label: '웨이브'),
    IdealTypeOption(key: 'short', label: '숏컷'),
    IdealTypeOption(key: 'two_block', label: '투블럭'),
    IdealTypeOption(key: 'dandy', label: '댄디컷'),
    IdealTypeOption(key: 'medium', label: '미디엄 헤어'),
    IdealTypeOption(key: 'layered', label: '레이어드 컷'),
    IdealTypeOption(key: 'regent', label: '리젠트'),
  ];

  static List<IdealTypeOption> hairsForGender(String gender) {
    if (gender == 'male') return maleHairs;
    if (gender == 'female') return femaleHairs;
    return allHairs;
  }

  static String defaultHairForGender(String gender) {
    if (gender == 'male') return 'short';
    return 'wavy';
  }

  static bool isHairValidForGender(String gender, String hair) {
    return hairsForGender(gender).any((option) => option.key == hair);
  }

  static const impressions = [
    IdealTypeOption(key: 'bright_smile', label: '밝은 미소'),
    IdealTypeOption(key: 'calm', label: '무심한'),
    IdealTypeOption(key: 'warm', label: '따뜻한'),
  ];

  static const femaleImpressions = [
    IdealTypeOption(key: 'bright_clear', label: '맑은 인상'),
    IdealTypeOption(key: 'warm', label: '따뜻한 미소'),
    IdealTypeOption(key: 'clear_features', label: '또렷한 이목구비'),
    IdealTypeOption(key: 'calm_eyes', label: '차분한 눈빛'),
    IdealTypeOption(key: 'luxury_vibe', label: '고급스러운 분위기'),
  ];

  static const maleImpressions = [
    IdealTypeOption(key: 'sharp_eyes', label: '선명한 눈매'),
    IdealTypeOption(key: 'calm_smile', label: '차분한 미소'),
    IdealTypeOption(key: 'mature_impression', label: '성숙한 인상'),
    IdealTypeOption(key: 'soft_impression', label: '부드러운 인상'),
    IdealTypeOption(key: 'confident', label: '자신감 있는 분위기'),
  ];

  static List<IdealTypeOption> impressionsForGender(String gender) {
    if (gender == 'male') return maleImpressions;
    if (gender == 'female') return femaleImpressions;
    return impressions;
  }

  static String defaultImpressionForGender(String gender) =>
      impressionsForGender(gender).first.key;

  static bool isImpressionValidForGender(String gender, String impression) {
    return impressionsForGender(
      gender,
    ).any((option) => option.key == impression);
  }

  // 배경은 성별과 무관하게 공통이다. 배경 인물 이슈 때문에 화면 초기값은
  // studio(스튜디오)를 우선 추천한다(ideal_type_screen.dart의 초기 옵션 참고).
  static const backgrounds = [
    IdealTypeOption(key: 'studio', label: '스튜디오'),
    IdealTypeOption(key: 'cafe', label: '카페'),
    IdealTypeOption(key: 'outdoor', label: '야외'),
    IdealTypeOption(key: 'indoor', label: '실내'),
  ];
}
