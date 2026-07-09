// ignore_for_file: prefer_initializing_formals

import 'package:cloud_firestore/cloud_firestore.dart';

import '../../models/match_model.dart';
import '../database/firestore_service.dart';
import '../safety/safety_service.dart';

/// matches 컬렉션을 구독하고 개별 매치 조회를 담당하는 서비스.
///
/// Firestore 구조:
///   matches/{matchId}
///     participants: [uid1, uid2]  ← arrayContains 쿼리용
///     uid1, uid2: string
///     matchedAt: Timestamp
///
/// 쿼리 주의:
///   .where('participants', arrayContains:) + .orderBy('matchedAt') 조합은
///   Firestore 복합 인덱스가 필요하다.
///   쿼리 실패 시 콘솔에 인덱스 생성 URL이 출력된다 — 해당 URL을 열어 인덱스를 만들 것.
class MatchesService {
  MatchesService({
    FirebaseFirestore? firestore,
    required FirestoreService firestoreService,
    required SafetyService safetyService,
  }) : _db = firestore ?? FirebaseFirestore.instance,
       _firestoreService = firestoreService,
       _safetyService = safetyService;

  final FirebaseFirestore _db;
  final FirestoreService _firestoreService;
  final SafetyService _safetyService;

  /// 현재 유저의 모든 매치를 실시간으로 구독한다 (최신순).
  ///
  /// 각 Match에 대해 상대방 프로필을 asyncMap으로 추가 조회한다.
  /// N명 매치 → N+1 쿼리. MVP에서는 허용; 추후 denormalize 예정.
  Stream<List<MatchWithProfile>> watchMatches({required String currentUid}) {
    return _db
        .collection('matches')
        .where('participants', arrayContains: currentUid)
        .orderBy('matchedAt', descending: true)
        .snapshots()
        .asyncMap((snap) async {
          final blockedUids = await _safetyService.getBlockedRelationshipUids(
            currentUid,
          );
          final futures = snap.docs.map((doc) async {
            final match = MatchModel.fromFirestore(doc);
            // 둘 중 누구든 매칭을 해제했으면 양쪽 모두의 목록에서 숨긴다.
            // 이 스트림 하나만 필터링하면 watchUnreadMatchCount와 매칭 탭의
            // "아직 못 본 축하" 체크도 자동으로 같은 제외를 상속받는다(둘 다
            // 이 watchMatches를 그대로 재사용하기 때문).
            if (match.isUnmatched) return null;
            final otherUid = match.otherUid(currentUid);
            if (blockedUids.contains(otherUid)) return null;
            final profile = await _firestoreService.getUserProfile(otherUid);
            if (profile == null) return null;
            return MatchWithProfile(match: match, otherProfile: profile);
          });
          final results = await Future.wait(futures);
          return results.whereType<MatchWithProfile>().toList();
        });
  }

  /// 특정 두 유저 사이의 매치 문서를 일회성으로 조회한다.
  ///
  /// like 스와이프 직후 Cloud Function이 matches 문서를 생성했는지
  /// 확인할 때 사용한다.
  Future<MatchWithProfile?> checkForMatch({
    required String currentUid,
    required String targetUid,
  }) async {
    final matchId = ([currentUid, targetUid]..sort()).join('_');
    final doc = await _db.collection('matches').doc(matchId).get();
    if (!doc.exists) return null;
    final match = MatchModel.fromFirestore(doc);
    final profile = await _firestoreService.getUserProfile(targetUid);
    if (profile == null) return null;
    final isBlocked = await _safetyService.isBlockedBetween(
      currentUid: currentUid,
      otherUid: targetUid,
    );
    if (isBlocked) return null;
    return MatchWithProfile(match: match, otherProfile: profile);
  }

  /// currentUid 기준으로 안읽은 메시지가 있는 매치 개수를 실시간으로 센다.
  ///
  /// 하단 내비게이션 "매칭" 탭 배지용. matches_screen.dart의 _hasUnread와
  /// 같은 판정 기준(내가 보낸 마지막 메시지가 아니고, lastReadAt 이후에
  /// 온 메시지)을 재사용한다.
  Stream<int> watchUnreadMatchCount({required String currentUid}) {
    return watchMatches(currentUid: currentUid).map((matches) {
      return matches.where((mwp) {
        final last = mwp.match.lastMessage;
        if (last == null || last.senderId == currentUid) return false;
        final lastReadAt = mwp.match.lastReadAtFor(currentUid);
        if (lastReadAt == null) return true;
        return last.createdAt.isAfter(lastReadAt);
      }).length;
    });
  }

  /// uid가 이 매치의 축하(MatchCelebrationOverlay)를 봤다고 기록한다.
  ///
  /// celebratedBy 배열에 본인 uid만 arrayUnion으로 추가한다 — firestore.rules가
  /// 이 필드만 바뀌고 추가되는 값이 호출자 본인 uid인지 서버에서도 검증한다.
  /// 필드가 아예 없던 매치에도 안전하게(merge) 적용된다.
  Future<void> markCelebrated({
    required String matchId,
    required String uid,
  }) async {
    await _db.collection('matches').doc(matchId).set({
      'celebratedBy': FieldValue.arrayUnion([uid]),
    }, SetOptions(merge: true));
  }

  /// 이 매칭을 더 이상 원하지 않는다고 표시한다.
  ///
  /// unmatchedBy 배열에 본인 uid만 arrayUnion으로 추가한다 — 채팅 기록/매치
  /// 문서 자체는 지우지 않는다(신고/감사 가능성 보존). firestore.rules가
  /// 이 필드만 바뀌고 추가되는 값이 호출자 본인 uid인지 서버에서도 검증하며,
  /// 이후 이 매치의 새 메시지 생성도 rules 단에서 함께 막는다.
  Future<void> unmatch({required String matchId, required String uid}) async {
    await _db.collection('matches').doc(matchId).set({
      'unmatchedBy': FieldValue.arrayUnion([uid]),
    }, SetOptions(merge: true));
  }
}
