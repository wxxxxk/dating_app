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
}
