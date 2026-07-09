import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../../models/user_profile.dart';
import '../location/location_service.dart';

/// 디스커버리(스와이프) 관련 Firestore 접근을 담당한다.
///
/// 스와이프 데이터 경로: users/{uid}/swipes/{targetUid}
/// - action: 'like' | 'pass' | 'superlike'
/// - timestamp: 서버 타임스탬프
///
/// 이 구조가 M4 매칭 판정의 토대다.
/// A가 B를 like하고 B도 A를 like하면 → 매칭.
class DiscoveryService {
  DiscoveryService({FirebaseFirestore? firestore})
    : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  /// 현재 유저에게 보여줄 프로필 목록을 가져온다.
  ///
  /// 제외 조건:
  /// - 본인 (uid == currentUid)
  /// - 이미 스와이프한 유저 (users/{currentUid}/swipes 문서 목록)
  ///
  /// 현재는 전체 유저를 클라이언트에서 필터링한다.
  /// 유저가 많아지면 서버사이드 페이지네이션 + cursor 방식으로 전환 필요.
  Future<List<UserProfile>> getDiscoveryProfiles({
    required String currentUid,
    UserLocation? currentLocation,
    DiscoveryFilter filter = const DiscoveryFilter(),
    Set<String> excludedUids = const {},
  }) async {
    // 이미 스와이프한 uid 집합 조회.
    // 프로토타입 재노출 정책: 미응답자가 없으면 pass한 사람만 다시 순환 노출한다.
    // 실서비스에서는 재노출 주기/쿨다운/유료 되돌리기 정책으로 조정한다.
    final swipesSnap = await _db
        .collection('users')
        .doc(currentUid)
        .collection('swipes')
        .get();
    final positiveSwipeUids = <String>{};
    final passSwipeUids = <String>{};
    for (final doc in swipesSnap.docs) {
      final action = doc.data()['action'] as String?;
      if (action == 'pass') {
        passSwipeUids.add(doc.id);
      } else {
        positiveSwipeUids.add(doc.id);
      }
    }

    // 전체 유저 조회
    final usersSnap = await _db
        .collection('users')
        .withConverter<UserProfile>(
          fromFirestore: (snap, _) => UserProfile.fromFirestore(snap),
          toFirestore: (p, _) => p.toFirestore(),
        )
        .get();

    final candidates = usersSnap.docs
        .map((d) => d.data())
        .where(
          (p) =>
              p.uid != currentUid &&
              !positiveSwipeUids.contains(p.uid) &&
              !excludedUids.contains(p.uid),
        )
        .where((p) => _matchesFilter(p, filter, currentLocation))
        .toList();

    final freshProfiles = candidates
        .where((p) => !passSwipeUids.contains(p.uid))
        .toList();
    final profiles = freshProfiles.isNotEmpty
        ? freshProfiles
        : candidates.where((p) => passSwipeUids.contains(p.uid)).toList();

    return _rankProfiles(profiles, currentLocation: currentLocation);
  }

  bool _matchesFilter(
    UserProfile profile,
    DiscoveryFilter filter,
    UserLocation? currentLocation,
  ) {
    final age = profile.age;
    if (age < filter.ageMin || age > filter.ageMax) return false;

    if (filter.gender != 'all' && profile.gender != filter.gender) {
      return false;
    }

    if (filter.relationshipGoal != null &&
        profile.relationshipGoal != filter.relationshipGoal) {
      return false;
    }

    final maxDistance = filter.maxDistanceKm;
    if (maxDistance != null && currentLocation != null) {
      final distance = LocationService.distanceBetween(
        currentLocation,
        profile.location,
      );
      if (distance == null || distance > maxDistance) return false;
    }

    return true;
  }

  /// 스와이프 결과를 Firestore에 기록한다.
  ///
  /// [action]: 'like'(오른쪽), 'pass'(왼쪽), 'superlike'(강한 호감).
  /// 문서 ID를 targetUid로 쓰면 동일 대상에 대한 중복 기록이 자동으로 덮어써진다.
  Future<void> recordSwipe({
    required String currentUid,
    required String targetUid,
    required String action,
  }) async {
    if (kDebugMode) {
      debugPrint('[Discovery] 스와이프 기록: $currentUid → $targetUid ($action)');
    }
    await _db
        .collection('users')
        .doc(currentUid)
        .collection('swipes')
        .doc(targetUid)
        .set({
          'action': action,
          'targetUid': targetUid,
          'actorUid': currentUid,
          'timestamp': FieldValue.serverTimestamp(),
        });
  }

  /// 프로필 목록 정렬·랭킹.
  ///
  /// 부스트 활성 유저를 먼저 보여준 뒤, 내 위치가 있으면 가까운 순으로 보여준다.
  /// 위치 없는 유저는 뒤로 보내고, 내 위치가 없으면 부스트 그룹 안/밖에서 셔플한다.
  List<UserProfile> _rankProfiles(
    List<UserProfile> profiles, {
    required UserLocation? currentLocation,
  }) {
    final result = List<UserProfile>.from(profiles);
    if (currentLocation == null) {
      final boosted = result.where(_isBoostActive).toList()..shuffle();
      final normal = result.where((p) => !_isBoostActive(p)).toList()
        ..shuffle();
      return [...boosted, ...normal];
    }

    result.sort((a, b) {
      final aBoosted = _isBoostActive(a);
      final bBoosted = _isBoostActive(b);
      if (aBoosted != bBoosted) return aBoosted ? -1 : 1;

      final aDistance = LocationService.distanceBetween(
        currentLocation,
        a.location,
      );
      final bDistance = LocationService.distanceBetween(
        currentLocation,
        b.location,
      );
      if (aDistance == null && bDistance == null) return 0;
      if (aDistance == null) return 1;
      if (bDistance == null) return -1;
      return aDistance.compareTo(bDistance);
    });
    return result;
  }

  bool _isBoostActive(UserProfile profile) {
    final boostUntil = profile.boostUntil;
    return boostUntil != null && boostUntil.isAfter(DateTime.now());
  }
}
