class ProfileInsight {
  final String inputHash;
  final String firstImpression;
  final String conversationStyle;
  final String atmosphere;
  final String goodMatchType;

  const ProfileInsight({
    required this.inputHash,
    required this.firstImpression,
    required this.conversationStyle,
    required this.atmosphere,
    required this.goodMatchType,
  });

  factory ProfileInsight.fromMap(Map<String, dynamic> map) {
    return ProfileInsight(
      inputHash: map['inputHash'] as String? ?? '',
      firstImpression: map['firstImpression'] as String? ?? '',
      conversationStyle: map['conversationStyle'] as String? ?? '',
      atmosphere: map['atmosphere'] as String? ?? '',
      goodMatchType: map['goodMatchType'] as String? ?? '',
    );
  }

  bool get isComplete =>
      inputHash.isNotEmpty &&
      firstImpression.trim().isNotEmpty &&
      conversationStyle.trim().isNotEmpty &&
      atmosphere.trim().isNotEmpty &&
      goodMatchType.trim().isNotEmpty;
}
