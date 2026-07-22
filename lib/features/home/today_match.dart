import '../../core/utils/kst_date.dart' as core_kst;
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
///
/// v3: 차단 fail-closed + candidate/viewer fingerprint 기반 캐시 무효화.
const int kTodayMatchAlgorithmVersion = 3;

/// 차단 관계를 확인하지 못했을 때 던진다.
///
/// 이걸 삼키고 빈 집합으로 진행하면 차단한 상대가 추천에 나올 수 있다.
/// 확인이 안 되면 추천 자체를 하지 않는다(fail-closed).
class BlockLookupFailure implements Exception {
  const BlockLookupFailure();
  @override
  String toString() => 'BlockLookupFailure';
}

/// 후보 목록을 가져오지 못했을 때 던진다. empty와 구분하기 위한 타입.
class CandidateLookupFailure implements Exception {
  const CandidateLookupFailure();
  @override
  String toString() => 'CandidateLookupFailure';
}

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

  /// 후보의 **공개 프로필** 지문. 사진·소개·관심사 등이 바뀌면 값이 달라진다.
  /// ID만 비교하면 같은 사람이 프로필을 고쳐도 옛 카드가 계속 남는다.
  final String candidateProfileFingerprint;

  /// 보는 사람의 추천 조건 지문(필터·목표 등). 조건이 바뀌면 재계산해야 한다.
  final String viewerEligibilityFingerprint;

  const TodayMatchResult({
    required this.profile,
    required this.candidateId,
    required this.reason,
    required this.dateKey,
    required this.source,
    required this.reasonFingerprint,
    required this.candidateProfileFingerprint,
    required this.viewerEligibilityFingerprint,
    this.algorithmVersion = kTodayMatchAlgorithmVersion,
  });

  /// 캐시된 결과를 그대로 재사용해도 되는지.
  ///
  /// 같은 사용자·같은 날짜·같은 알고리즘이면서, 후보가 **지금도** 자격이 있고
  /// 공개 프로필과 내 추천 조건이 그대로일 때만 재사용한다. 조회가 실패했다고
  /// 이전 결과를 계속 보여주지 않는다.
  ///
  /// [eligibleCandidateFingerprints]는 ID → 최신 공개 프로필 지문이다.
  /// ID Set만 받으면 프로필 변경을 감지할 수 없어 map으로 받는다.
  bool isReusableFor({
    required String dateKey,
    required Map<String, String> eligibleCandidateFingerprints,
    required Set<String> blockedUids,
    required String viewerEligibilityFingerprint,
  }) {
    if (this.dateKey != dateKey) return false;
    if (algorithmVersion != kTodayMatchAlgorithmVersion) return false;
    // 차단된 후보는 캐시에 있어도 절대 재사용하지 않는다.
    if (blockedUids.contains(candidateId)) return false;
    if (this.viewerEligibilityFingerprint != viewerEligibilityFingerprint) {
      return false;
    }
    final latest = eligibleCandidateFingerprints[candidateId];
    if (latest == null) return false;
    if (latest != candidateProfileFingerprint) return false;
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
/// 9시간 계산은 core/utils/kst_date.dart 한 곳에만 둔다.
String kstDateKey(DateTime instant) => core_kst.kstDateKey(instant);

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

/// 후보 공개 프로필의 지문.
///
/// 서버가 관리하는 `profileUpdatedAt`/`schemaVersion`을 먼저 쓰되, 그 값이
/// 모든 편집에서 갱신된다는 보장이 없으므로 **카드와 문구가 실제로 쓰는 공개
/// 필드**를 함께 정규화해 넣는다.
///
/// 공개 프로필 필드만 쓴다 — 생년월일·출생시간·정확한 좌표 같은 비공개
/// 데이터는 들어가지 않는다(`age`는 이미 공개 필드다).
/// 이 값은 캐시 무효화 전용이며 UI·로그·Firestore에 노출하지 않는다.
String buildCandidateProfileFingerprint(PublicProfile profile) {
  final parts = <String>[
    profile.uid,
    profile.displayName,
    '${profile.age}',
    profile.bio,
    // 사진은 순서까지 의미가 있다(대표 사진 = 첫 장).
    profile.photoUrls.join(','),
    (profile.interests.toList()..sort()).join(','),
    profile.relationshipGoal ?? '',
    '${profile.schemaVersion}',
    profile.profileUpdatedAt?.toUtc().toIso8601String() ?? '',
  ];
  return '${_fnv1a(parts.join(''))}';
}

/// 보는 사람의 추천 조건 지문.
///
/// 좌표 원문은 넣지 않고 "거리 필터를 쓸 수 있는 상태인지"만 bool로 넣는다.
/// 이 값도 캐시 무효화 전용이며 어디에도 출력하지 않는다.
String buildViewerEligibilityFingerprint({
  required String viewerUid,
  required int ageMin,
  required int ageMax,
  required double? maxDistanceKm,
  required String gender,
  required String? relationshipGoal,
  required bool hasLocation,
}) {
  final parts = <String>[
    viewerUid,
    '$ageMin',
    '$ageMax',
    maxDistanceKm?.toStringAsFixed(1) ?? '',
    gender,
    relationshipGoal ?? '',
    hasLocation ? 'loc' : 'noloc',
  ];
  return '${_fnv1a(parts.join(''))}';
}

/// 후보 목록 → ID별 최신 공개 프로필 지문.
Map<String, String> candidateFingerprints(
  Iterable<TodayMatchCandidate> candidates,
) {
  final result = <String, String>{};
  for (final candidate in candidates) {
    result[candidate.id] = buildCandidateProfileFingerprint(candidate.profile);
  }
  return result;
}

/// 오늘의 인연 후보를 모은다. **차단 확인 실패 시 fail-closed.**
///
/// 순서가 계약이다:
/// 1. 차단 관계를 **먼저** 확인한다. 실패하면 [BlockLookupFailure]를 던지고
///    추천을 중단한다 — 빈 집합으로 대체해 계속 진행하지 않는다.
/// 2. match 후보를 모으고 차단 집합으로 거른다(매치 스트림에 남아 있어도 제외).
/// 3. discovery 조회에 차단 집합을 넘기고, 결과도 방어적으로 다시 거른다.
///
/// match 조회 실패는 치명적이지 않다(차단 집합은 이미 확보했으므로 discovery
/// 만으로 진행 가능). discovery 조회 실패는 [CandidateLookupFailure]다 —
/// "후보 0명"으로 오해하면 안 되기 때문이다.
Future<List<TodayMatchCandidate>> collectTodayMatchCandidates({
  required String viewerUid,
  required Future<Set<String>> Function(String viewerUid) loadBlockedUids,
  required Future<List<TodayMatchCandidate>> Function(Set<String> blockedUids)
  loadMatchCandidates,
  required Future<List<PublicProfile>> Function(Set<String> blockedUids)
  loadDiscoveryProfiles,
  void Function(String event)? onLog,
}) async {
  Set<String> blockedUids;
  try {
    blockedUids = await loadBlockedUids(viewerUid);
  } catch (_) {
    onLog?.call('block_relationship_lookup_failed');
    throw const BlockLookupFailure();
  }

  final candidates = <TodayMatchCandidate>[];

  try {
    final matchCandidates = await loadMatchCandidates(blockedUids);
    candidates.addAll(
      matchCandidates.where((c) => !blockedUids.contains(c.id)),
    );
  } catch (_) {
    // 후보 0명과 구분되도록 남긴다. discovery만으로 계속 진행한다.
    onLog?.call('match_list_failed');
  }

  List<PublicProfile> discoveryProfiles;
  try {
    discoveryProfiles = await loadDiscoveryProfiles(blockedUids);
  } catch (_) {
    onLog?.call('discovery_lookup_failed');
    throw const CandidateLookupFailure();
  }

  candidates.addAll(
    discoveryProfiles
        .where((profile) => !blockedUids.contains(profile.uid))
        .map(
          (profile) => TodayMatchCandidate(
            profile: profile,
            source: TodayMatchSource.discovery,
          ),
        ),
  );

  return candidates;
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
  required String viewerEligibilityFingerprint,
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
    candidateProfileFingerprint: buildCandidateProfileFingerprint(
      candidate.profile,
    ),
    viewerEligibilityFingerprint: viewerEligibilityFingerprint,
  );
}
