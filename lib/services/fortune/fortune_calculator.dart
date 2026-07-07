import 'package:saju/saju.dart' as bazi;
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// 오행 5개를 항상 이 순서(목→화→토→금→수)로 다룬다.
///
/// `bazi.Element.values`(wood/fire/earth/metal/water)와 같은 순서로 맞춰뒀다.
/// Map 반복 순서를 이 상수에 고정해두면, 강한/약한 원소가 동점일 때도 항상
/// 같은 원소가 뽑혀 결과가 결정론적으로 유지된다.
const List<String> ohaengOrder = ['목', '화', '토', '금', '수'];

/// 별자리 + 4원소(불/흙/공기/물) 계산 결과.
class ZodiacInfo {
  final String sign; // 한글 별자리 이름, 예: "양자리"
  final String element; // 한글 원소, 예: "불"
  const ZodiacInfo({required this.sign, required this.element});

  /// Cloud Function에 넘길 근거 속성. GPT는 이 값만 근거로 해석해야 한다.
  Map<String, String> toAttrs() => {'sign': sign, 'element': element};
}

/// 사주 일간(日干) + 오행 계산 결과.
class SajuInfo {
  final String dayMaster; // 일간 한글, 예: "갑"
  final String element; // 오행 한글, 예: "목"
  const SajuInfo({required this.dayMaster, required this.element});

  Map<String, String> toAttrs() => {'dayMaster': dayMaster, 'element': element};
}

/// 스와이프 카드에 표시할 가벼운 규칙 기반 궁합 힌트.
///
/// GPT를 호출하지 않고 생년월일에서 계산한 별자리 원소와 사주 일간 오행만으로
/// 즉석 산출한다. 정렬이나 매칭 점수에는 쓰지 않고, 카드의 참고 정보로만 보여준다.
class CompatibilityHint {
  final String level; // 예: 상생, 조화, 보완
  final String emoji;
  final String shortLabel;

  const CompatibilityHint({
    required this.level,
    required this.emoji,
    required this.shortLabel,
  });
}

/// 생년월일 기반 결정론적 규칙 계산.
///
/// 같은 생년월일이면 항상 같은 결과를 반환한다(순수 함수, 외부 상태 없음).
/// GPT는 여기서 뽑은 속성을 "해석"만 할 뿐 스스로 지어내지 않는다 —
/// 이 계산이 서사의 유일한 근거 데이터 출처다.
class FortuneCalculator {
  FortuneCalculator._();

  static bool _tzInitialized = false;

  /// timezone 데이터베이스는 한 번만 초기화하면 된다.
  /// getOhaengBalance가 연/월주 계산에 tz.TZDateTime을 필요로 해서 여기서만 쓴다.
  static void _ensureTimezoneInitialized() {
    if (_tzInitialized) return;
    tzdata.initializeTimeZones();
    _tzInitialized = true;
  }

  /// 각 별자리의 시작 경계일. (월, 일) 오름차순으로 정렬돼 있어야 한다.
  static const _boundaries = <_ZodiacBoundary>[
    _ZodiacBoundary(1, 20, '물병자리', '공기'),
    _ZodiacBoundary(2, 19, '물고기자리', '물'),
    _ZodiacBoundary(3, 21, '양자리', '불'),
    _ZodiacBoundary(4, 20, '황소자리', '흙'),
    _ZodiacBoundary(5, 21, '쌍둥이자리', '공기'),
    _ZodiacBoundary(6, 22, '게자리', '물'),
    _ZodiacBoundary(7, 23, '사자자리', '불'),
    _ZodiacBoundary(8, 23, '처녀자리', '흙'),
    _ZodiacBoundary(9, 23, '천칭자리', '공기'),
    _ZodiacBoundary(10, 23, '전갈자리', '물'),
    _ZodiacBoundary(11, 22, '사수자리', '불'),
    _ZodiacBoundary(12, 22, '염소자리', '흙'),
  ];

  /// 생년월일(월/일)로 서양 별자리 + 4원소를 계산한다. 연도는 사용하지 않는다.
  static ZodiacInfo getZodiacSign(DateTime birthDate) {
    final m = birthDate.month;
    final d = birthDate.day;

    // 경계일을 최신(12월)부터 역순으로 훑어, (m,d)가 그 경계일 이후(또는 같은 날)인
    // 첫 항목을 찾는다. 1/1~1/19처럼 어떤 경계에도 안 걸리면 전년도 12/22에
    // 시작한 염소자리가 그대로 이어지는 경우이므로 아래 fallback으로 처리한다.
    for (final b in _boundaries.reversed) {
      final afterBoundary = m > b.month || (m == b.month && d >= b.day);
      if (afterBoundary) {
        return ZodiacInfo(sign: b.sign, element: b.element);
      }
    }
    return const ZodiacInfo(sign: '염소자리', element: '흙');
  }

  /// 사주 일간(日干)과 오행을 계산한다.
  ///
  /// 일주(日柱)는 태어난 날짜만으로 정해지는 60갑자의 연속 순환이라
  /// 태어난 시각이 없어도 정확히 계산할 수 있다(연/월주와 달리 절기 경계에
  /// 영향받지 않는다). 출생 시각을 수집하지 않으므로 시주(時柱)는 계산하지 않는다.
  static SajuInfo getSaju(DateTime birthDate) {
    final pillar = bazi.dayPillarFromDate(
      birthDate.year,
      birthDate.month,
      birthDate.day,
    );
    return SajuInfo(
      dayMaster: pillar.stem.korean,
      element: pillar.stem.element.korean,
    );
  }

  /// 오행(목화토금수) 밸런스를 0~1로 정규화해 반환한다.
  ///
  /// 계산 방식:
  /// - 년주·월주·일주(각 천간+지지, 총 6글자)에 등장하는 대표 오행을 세어
  ///   전체 글자 수(6)로 나눈 비율을 사용한다. 지지는 주 오행만 반영하고,
  ///   지장간(藏干)의 세부 가중치는 반영하지 않는 가벼운 근사치다.
  /// - 시주(時柱)는 출생 시각을 수집하지 않아 포함하지 않는다 — 따라서 이 결과는
  ///   "완전한 사주팔자(8글자)"가 아니라 년/월/일 6글자 기반의 근사치다.
  ///   시주나 지장간까지 포함하면 오행 비율이 달라질 수 있다는 한계가 있다.
  /// - 년주/월주는 절기(태양 황경) 기준으로 정해지므로 실제 계산에는 시각이 필요하다.
  ///   출생 시각이 없어 정오(12:00, Asia/Seoul)를 임의로 대입한다 — 자정 근처를
  ///   피해 날짜 경계(하루가 바뀌는 시점) 판정이 흔들리지 않게 하기 위함이다.
  ///   연/월 경계일(절기 당일)에 태어난 경우 실제와 다르게 나올 수 있다.
  /// - 위 근사를 적용해도 같은 생년월일이면 항상 같은 6글자 조합이 나오므로
  ///   결과는 결정론적이다.
  static Map<String, double> getOhaengBalance(DateTime birthDate) {
    _ensureTimezoneInitialized();
    final seoul = tz.getLocation('Asia/Seoul');
    final noon = tz.TZDateTime(
      seoul,
      birthDate.year,
      birthDate.month,
      birthDate.day,
      12,
    );
    final pillars = bazi.getFourPillars(noon).pillars;

    final letters = <bazi.Element>[
      pillars.year.stem.element,
      pillars.year.branch.element,
      pillars.month.stem.element,
      pillars.month.branch.element,
      pillars.day.stem.element,
      pillars.day.branch.element,
    ];

    final counts = {for (final key in ohaengOrder) key: 0};
    for (final element in letters) {
      counts[element.korean] = (counts[element.korean] ?? 0) + 1;
    }

    return {for (final key in ohaengOrder) key: counts[key]! / letters.length};
  }

  /// balance에서 가장 강한 원소의 (이름, 값)을 반환한다.
  /// 동점이면 [ohaengOrder] 순서상 앞선 원소를 택해 결과가 항상 같게 한다.
  static MapEntry<String, double> strongestElement(
    Map<String, double> balance,
  ) {
    return ohaengOrder
        .map((key) => MapEntry(key, balance[key] ?? 0))
        .reduce((a, b) => b.value > a.value ? b : a);
  }

  /// balance에서 가장 부족한 원소의 (이름, 값)을 반환한다.
  /// 동점이면 [ohaengOrder] 순서상 앞선 원소를 택해 결과가 항상 같게 한다.
  static MapEntry<String, double> weakestElement(Map<String, double> balance) {
    return ohaengOrder
        .map((key) => MapEntry(key, balance[key] ?? 0))
        .reduce((a, b) => b.value < a.value ? b : a);
  }

  /// [element](한글, 예: "수")를 생(生)해주는 원소의 한글 이름을 반환한다.
  ///
  /// 상생 순환: 목→화→토→금→수→목. 즉 "무엇이 water를 생하는가"의 답은 금(金)이다.
  /// `Element.generatedBy`(saju 패키지)를 그대로 활용한다 — 상생 표를 다시
  /// 구현하지 않고 이미 검증된 로직을 재사용한다.
  static String nourishingElement(String element) {
    final e = bazi.Element.values.firstWhere((v) => v.korean == element);
    return e.generatedBy.korean;
  }

  /// 두 생년월일의 별자리 원소 + 사주 일간 오행으로 카드용 궁합 힌트를 만든다.
  ///
  /// 계산 규칙:
  /// - 별자리 4원소: 같은 원소 또는 불×공기, 흙×물 조합은 편안한 흐름으로 본다.
  /// - 사주 오행: 같은 오행은 조화, 한쪽이 다른 쪽을 생(生)하면 상생,
  ///   한쪽이 다른 쪽을 극(剋)하면 보완으로 본다.
  /// - 최종 문구는 가벼운 힌트일 뿐이며, 디스커버리 정렬에는 전혀 관여하지 않는다.
  static CompatibilityHint getCompatibilityHint(
    DateTime myBirthDate,
    DateTime otherBirthDate,
  ) {
    final myZodiac = getZodiacSign(myBirthDate);
    final otherZodiac = getZodiacSign(otherBirthDate);
    final mySaju = getSaju(myBirthDate);
    final otherSaju = getSaju(otherBirthDate);

    final zodiacScore = _zodiacCompatibilityScore(
      myZodiac.element,
      otherZodiac.element,
    );
    final ohaengRelation = _ohaengRelation(mySaju.element, otherSaju.element);
    final total = zodiacScore + ohaengRelation.score;

    if (ohaengRelation.kind == _OhaengRelationKind.generating && total >= 4) {
      return const CompatibilityHint(
        level: '상생',
        emoji: '',
        shortLabel: '상생 흐름',
      );
    }
    if (total >= 4) {
      return const CompatibilityHint(
        level: '조화',
        emoji: '',
        shortLabel: '편안한 조화',
      );
    }
    if (ohaengRelation.kind == _OhaengRelationKind.controlling || total <= 2) {
      return const CompatibilityHint(
        level: '보완',
        emoji: '',
        shortLabel: '서로 보완',
      );
    }
    return const CompatibilityHint(
      level: '균형',
      emoji: '',
      shortLabel: '균형 있는 흐름',
    );
  }

  static int _zodiacCompatibilityScore(String a, String b) {
    if (a == b) return 2;
    final pair = {a, b};
    if (pair.contains('불') && pair.contains('공기')) return 2;
    if (pair.contains('흙') && pair.contains('물')) return 2;
    if (pair.contains('불') && pair.contains('물')) return 0;
    if (pair.contains('흙') && pair.contains('공기')) return 0;
    return 1;
  }

  static _OhaengRelation _ohaengRelation(String a, String b) {
    if (a == b) {
      return const _OhaengRelation(_OhaengRelationKind.same, 2);
    }
    if (_generates[a] == b || _generates[b] == a) {
      return const _OhaengRelation(_OhaengRelationKind.generating, 3);
    }
    if (_controls[a] == b || _controls[b] == a) {
      return const _OhaengRelation(_OhaengRelationKind.controlling, 1);
    }
    return const _OhaengRelation(_OhaengRelationKind.neutral, 1);
  }

  static const Map<String, String> _generates = {
    '목': '화',
    '화': '토',
    '토': '금',
    '금': '수',
    '수': '목',
  };

  static const Map<String, String> _controls = {
    '목': '토',
    '토': '수',
    '수': '화',
    '화': '금',
    '금': '목',
  };
}

enum _OhaengRelationKind { same, generating, controlling, neutral }

class _OhaengRelation {
  final _OhaengRelationKind kind;
  final int score;

  const _OhaengRelation(this.kind, this.score);
}

class _ZodiacBoundary {
  final int month;
  final int day;
  final String sign;
  final String element;
  const _ZodiacBoundary(this.month, this.day, this.sign, this.element);
}
