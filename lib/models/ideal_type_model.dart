class IdealTypeImageOptions {
  final String gender;
  final List<String> idealTags;
  final String mood;
  final String style;
  final String hair;
  final String impression;
  final String background;

  const IdealTypeImageOptions({
    required this.gender,
    required this.idealTags,
    required this.mood,
    required this.style,
    required this.hair,
    required this.impression,
    required this.background,
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
  }) {
    return IdealTypeImageOptions(
      gender: gender ?? this.gender,
      idealTags: idealTags ?? this.idealTags,
      mood: mood ?? this.mood,
      style: style ?? this.style,
      hair: hair ?? this.hair,
      impression: impression ?? this.impression,
      background: background ?? this.background,
    );
  }
}

class IdealTypeImageResult {
  final String imageUrl;
  final String storagePath;
  final String summary;
  final String safetyLabel;
  final String inputHash;

  const IdealTypeImageResult({
    required this.imageUrl,
    required this.storagePath,
    required this.summary,
    required this.safetyLabel,
    required this.inputHash,
  });

  factory IdealTypeImageResult.fromMap(Map<String, dynamic> map) {
    return IdealTypeImageResult(
      imageUrl: map['imageUrl'] as String? ?? '',
      storagePath: map['storagePath'] as String? ?? '',
      summary: map['summary'] as String? ?? '',
      safetyLabel:
          map['safetyLabel'] as String? ??
          'AI가 생성한 가상의 이미지입니다. 실제 앱 사용자가 아닙니다.',
      inputHash: map['inputHash'] as String? ?? '',
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

  static const moods = [
    IdealTypeOption(key: 'pure', label: '청순한'),
    IdealTypeOption(key: 'chic', label: '시크한'),
    IdealTypeOption(key: 'playful', label: '발랄한'),
    IdealTypeOption(key: 'intellectual', label: '지적인'),
    IdealTypeOption(key: 'gentle', label: '부드러운'),
  ];

  static const styles = [
    IdealTypeOption(key: 'casual', label: '캐주얼'),
    IdealTypeOption(key: 'formal', label: '포멀'),
    IdealTypeOption(key: 'street', label: '스트릿'),
    IdealTypeOption(key: 'minimal', label: '미니멀'),
  ];

  static const femaleHairs = [
    IdealTypeOption(key: 'long_straight', label: '긴 생머리'),
    IdealTypeOption(key: 'bob', label: '단발'),
    IdealTypeOption(key: 'wavy', label: '웨이브'),
    IdealTypeOption(key: 'short', label: '숏컷'),
  ];

  static const maleHairs = [
    IdealTypeOption(key: 'short', label: '숏컷'),
    IdealTypeOption(key: 'two_block', label: '투블럭'),
    IdealTypeOption(key: 'dandy', label: '댄디컷'),
    IdealTypeOption(key: 'medium', label: '미디엄 헤어'),
  ];

  static const allHairs = [
    IdealTypeOption(key: 'long_straight', label: '긴 생머리'),
    IdealTypeOption(key: 'bob', label: '단발'),
    IdealTypeOption(key: 'wavy', label: '웨이브'),
    IdealTypeOption(key: 'short', label: '숏컷'),
    IdealTypeOption(key: 'two_block', label: '투블럭'),
    IdealTypeOption(key: 'dandy', label: '댄디컷'),
    IdealTypeOption(key: 'medium', label: '미디엄 헤어'),
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

  static const backgrounds = [
    IdealTypeOption(key: 'cafe', label: '카페'),
    IdealTypeOption(key: 'outdoor', label: '야외'),
    IdealTypeOption(key: 'studio', label: '스튜디오'),
    IdealTypeOption(key: 'indoor', label: '실내'),
  ];
}
