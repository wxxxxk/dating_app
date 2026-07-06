class CharmPoint {
  final String title;
  final String description;

  const CharmPoint({required this.title, required this.description});

  factory CharmPoint.fromMap(Map<String, dynamic> map) {
    return CharmPoint(
      title: map['title'] as String? ?? '',
      description: map['description'] as String? ?? '',
    );
  }
}

class CharmReport {
  final String firstImpression;
  final List<CharmPoint> charmPoints;
  final String appealTip;

  const CharmReport({
    required this.firstImpression,
    required this.charmPoints,
    required this.appealTip,
  });

  factory CharmReport.fromMap(Map<String, dynamic> map) {
    final rawPoints = map['charmPoints'] as List<dynamic>? ?? [];
    return CharmReport(
      firstImpression: map['firstImpression'] as String? ?? '',
      charmPoints: rawPoints
          .map(
            (item) =>
                CharmPoint.fromMap(Map<String, dynamic>.from(item as Map)),
          )
          .where(
            (point) =>
                point.title.trim().isNotEmpty &&
                point.description.trim().isNotEmpty,
          )
          .toList(),
      appealTip: map['appealTip'] as String? ?? '',
    );
  }
}

class CharmInterestSummary {
  final int likeCount;
  final int superlikeCount;

  const CharmInterestSummary({
    required this.likeCount,
    required this.superlikeCount,
  });

  int get totalPositive => likeCount + superlikeCount;

  String get badgeLabel {
    if (superlikeCount > 0) return '특별한 관심을 받는 중';
    if (totalPositive >= 5) return '호감 신호가 쌓이는 중';
    if (totalPositive > 0) return '매력 상승 중';
    return '프로필 첫인상 준비 중';
  }

  String get description {
    if (superlikeCount > 0) {
      return '강한 호감 신호가 있어요. 숫자보다 프로필이 주는 인상에 집중해볼게요.';
    }
    if (totalPositive > 0) {
      return '받은 관심이 조금씩 쌓이고 있어요. 지금 프로필의 강점을 함께 볼게요.';
    }
    return '아직 데이터가 적어 정성 분석 중심으로 리포트를 보여드려요.';
  }
}
