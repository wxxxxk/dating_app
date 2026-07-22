import '../../models/public_profile.dart';

/// "오늘의 인연" 추천 결과와 그 선정 규칙.
///
/// 이 모듈이 생긴 이유(1-B 감사 결과):
/// - 후보를 거리순 정렬 목록의 `.first`로 골라서 항상 같은 사람이 나왔다.
/// - 점수가 `match ? 88 : 82` + `4` 상수라 실제 근거가 전혀 없었다.
/// - 날짜 개념이 없어서 "오늘의" 추천이 아니었다.
///
/// 그래서 선정을 **사용자 + KST 날짜 + 후보 ID**에만 의존하는 결정론적 함수로
/// 바꾸고, 결과를 한 객체로 묶어 후보·문구가 서로 다른 대상에서 오지 않게 한다.

/// 추천 알고리즘 버전. 선정 규칙이 바뀌면 올린다 → 기존 캐시가 자연히 무효화된다.
const int kTodayMatchAlgorithmVersion = 2;

/// 추천 후보가 어디서 왔는지.
enum TodayMatchSource { match, discovery }

/// 화면이 그릴 수 있는 상태. empty와 error를 구분한다.
enum TodayMatchState { loading, ready, empty, error }

/// 한 번의 추천 결과. 후보·문구·날짜가 항상 같이 움직인다.
///
/// **점수 필드는 없다.** 앱에는 궁합 점수 소스가 존재하지 않는다
/// (사주 evidence engine은 점수·퍼센트·순위를 만들지 않는다). 근거 없는
/// "추천 82%"를 만들어내지 않기 위해 숫자 자체를 두지 않는다.
class TodayMatchResult {
  final PublicProfile profile;
  final String candidateId;
  final String reason;
  final String dateKey;
  final TodayMatchSource source;
  final int algorithmVersion;

  /// 문구가 이 후보에게서 나온 것인지 판별하는 지문.
  /// 후보가 바뀌면 값이 달라져 이전 문구를 재사용할 수 없다.
  final String reasonFingerprint;

  const TodayMatchResult({
    required this.profile,
    required this.candidateId,
    required this.reason,
    required this.dateKey,
    required this.source,
    required this.reasonFingerprint,
    this.algorithmVersion = kTodayMatchAlgorithmVersion,
  });

  /// 캐시된 결과를 그대로 재사용해도 되는지.
  ///
  /// 같은 사용자·같은 날짜·같은 알고리즘이면서, 후보가 **지금도** 자격이 있을 때만
  /// 재사용한다. Firestore 조회가 실패했다고 이전 결과를 계속 보여주지 않는다.
  bool isReusableFor({
    required String dateKey,
    required Set<String> eligibleCandidateIds,
  }) {
    if (this.dateKey != dateKey) return false;
    if (algorithmVersion != kTodayMatchAlgorithmVersion) return false;
    if (!eligibleCandidateIds.contains(candidateId)) return false;
    return reasonFingerprint == buildReasonFingerprint(candidateId, reason);
  }
}

/// 후보 하나와 그 후보에게 붙은 문구.
class TodayMatchCandidate {
  final PublicProfile profile;
  final TodayMatchSource source;

  /// 이 후보 전용 문구. 다른 후보의 문구를 넣지 않는다.
  final String? candidateReason;

  const TodayMatchCandidate({
    required this.profile,
    required this.source,
    this.candidateReason,
  });

  String get id => profile.uid;
}

/// KST(Asia/Seoul) 기준 날짜 key. `YYYY-MM-DD`.
///
/// 한국은 1988년 이후 서머타임이 없어 항상 UTC+9다. 과거 날짜를 다루는
/// 사주 계산과 달리 "오늘"만 필요하므로 고정 오프셋으로 충분하다.
String kstDateKey(DateTime instant) {
  final kst = instant.toUtc().add(const Duration(hours: 9));
  final month = kst.month.toString().padLeft(2, '0');
  final day = kst.day.toString().padLeft(2, '0');
  return '${kst.year}-$month-$day';
}

/// FNV-1a 32bit. 외부 의존성 없이 안정적인 분산을 얻기 위해 쓴다.
int _fnv1a(String input) {
  var hash = 0x811c9dc5;
  for (final unit in input.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash;
}

/// 사용자·날짜·후보에만 의존하는 결정론적 순위값.
///
/// 같은 날 같은 사용자에게는 항상 같은 순서가 나오고, 날짜가 바뀌면 순서가
/// 달라진다. Firestore 반환 순서나 `Random()`에 의존하지 않는다.
int dailyRankFor({
  required String viewerUid,
  required String dateKey,
  required String candidateId,
}) {
  return _fnv1a(
    '$viewerUid|$dateKey|$candidateId|v$kTodayMatchAlgorithmVersion',
  );
}

/// 문구가 이 후보에게서 나왔음을 나타내는 지문.
String buildReasonFingerprint(String candidateId, String reason) {
  return '${_fnv1a('$candidateId|$reason')}';
}

/// 후보 목록에서 오늘의 한 명을 고른다.
///
/// 규칙:
/// 1. 이미 이어진 인연(match)을 새 후보(discovery)보다 우선한다 — 기존 제품 동작.
/// 2. 같은 source 안에서는 daily rank 오름차순.
/// 3. rank가 같으면 candidateId 사전순으로 tie-break(완전 결정론).
///
/// `.first`나 Firestore 정렬 순서에 의존하지 않는다.
TodayMatchCandidate? selectTodayCandidate({
  required String viewerUid,
  required String dateKey,
  required List<TodayMatchCandidate> candidates,
}) {
  if (candidates.isEmpty) return null;

  // 같은 후보가 match/discovery 양쪽에 들어오면 match 쪽만 남긴다.
  final byId = <String, TodayMatchCandidate>{};
  for (final candidate in candidates) {
    final existing = byId[candidate.id];
    if (existing == null || existing.source == TodayMatchSource.discovery) {
      byId[candidate.id] = candidate;
    }
  }

  final sorted = byId.values.toList()
    ..sort((a, b) {
      if (a.source != b.source) {
        return a.source == TodayMatchSource.match ? -1 : 1;
      }
      final rankA = dailyRankFor(
        viewerUid: viewerUid,
        dateKey: dateKey,
        candidateId: a.id,
      );
      final rankB = dailyRankFor(
        viewerUid: viewerUid,
        dateKey: dateKey,
        candidateId: b.id,
      );
      if (rankA != rankB) return rankA.compareTo(rankB);
      return a.id.compareTo(b.id);
    });

  return sorted.first;
}

/// 후보 자신의 정보만으로 만드는 안전 문구.
///
/// AI 문구를 불러오지 못했을 때 쓰지만, **다른 후보나 demo 사용자의 문구를
/// 재사용하지 않는다.** 항상 이 후보의 프로필에서만 만든다.
String buildDeterministicReason(TodayMatchCandidate candidate) {
  final profile = candidate.profile;
  final prefix = candidate.source == TodayMatchSource.match
      ? '이미 이어진 인연이라'
      : '오늘 먼저 대화해보기 좋은';

  if (profile.interests.isNotEmpty) {
    final interest = (profile.interests.toList()..sort()).first;
    return '$prefix 상대예요. 관심사에 «$interest»가 있어 첫 대화를 열기 쉬워요.';
  }
  if (profile.relationshipGoal != null) {
    return '$prefix 상대예요. 찾는 관계가 프로필에 분명히 적혀 있어요.';
  }
  return '$prefix 상대예요. 프로필이 안정적으로 채워져 있어요.';
}

/// 후보와 문구를 묶어 최종 결과를 만든다.
///
/// 문구는 반드시 이 후보에게서 나온 것만 받는다.
TodayMatchResult buildTodayMatchResult({
  required TodayMatchCandidate candidate,
  required String dateKey,
}) {
  final reason = (candidate.candidateReason?.trim().isNotEmpty ?? false)
      ? candidate.candidateReason!.trim()
      : buildDeterministicReason(candidate);
  return TodayMatchResult(
    profile: candidate.profile,
    candidateId: candidate.id,
    reason: reason,
    dateKey: dateKey,
    source: candidate.source,
    reasonFingerprint: buildReasonFingerprint(candidate.id, reason),
  );
}
