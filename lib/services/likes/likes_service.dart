// ignore_for_file: prefer_initializing_formals

import 'package:cloud_firestore/cloud_firestore.dart';

import '../../models/public_profile.dart';
import '../database/firestore_service.dart';
import '../privacy/contact_avoidance_service.dart';
import '../safety/safety_service.dart';

/// 나를 좋아요한 사람 목록용 뷰 모델.
class ReceivedLike {
  final String uid;
  final PublicProfile profile;
  final DateTime? likedAt;
  final String action;

  const ReceivedLike({
    required this.uid,
    required this.profile,
    required this.likedAt,
    required this.action,
  });

  bool get isSuperlike => action == 'superlike';
}

/// 받은 좋아요 조회를 담당한다.
///
/// swipes 문서는 users/{actorUid}/swipes/{targetUid}에 흩어져 있으므로,
/// collectionGroup('swipes') + targetUid 필드로 "나를 향한 좋아요"만 조회한다.
class LikesService {
  LikesService({
    FirebaseFirestore? firestore,
    required FirestoreService firestoreService,
    required SafetyService safetyService,
    ContactAvoidanceService? contactAvoidanceService,
  }) : _db = firestore ?? FirebaseFirestore.instance,
       _firestoreService = firestoreService,
       _safetyService = safetyService,
       _contactAvoidanceService =
           contactAvoidanceService ?? ContactAvoidanceService();

  final FirebaseFirestore _db;
  final FirestoreService _firestoreService;
  final SafetyService _safetyService;
  final ContactAvoidanceService _contactAvoidanceService;

  /// 나를 like/superlike했지만 내가 아직 응답하지 않은 사람들을 실시간으로 구독한다.
  Stream<List<ReceivedLike>> watchReceivedLikes({required String currentUid}) {
    return _db
        .collectionGroup('swipes')
        .where('targetUid', isEqualTo: currentUid)
        .where('action', whereIn: ['like', 'superlike'])
        .orderBy('timestamp', descending: true)
        .snapshots()
        .asyncMap((snap) async {
          final respondedUids = await _loadRespondedUids(currentUid);
          final matchedUids = await _loadMatchedUids(currentUid);
          final blockedUids = await _safetyService.getBlockedRelationshipUids(
            currentUid,
          );
          // 지인 피하기(Phase 3-4) 상대의 좋아요도 목록에서 숨긴다. 원본 swipe
          // 문서는 지우지 않으므로, pair가 사라지면 다시 보일 수 있다.
          final avoidedUids = await _loadAvoidedUids(currentUid);
          final seen = <String>{};

          final futures = snap.docs.map((doc) async {
            final data = doc.data();
            final actorUid =
                data['actorUid'] as String? ?? doc.reference.parent.parent?.id;
            if (actorUid == null ||
                actorUid == currentUid ||
                respondedUids.contains(actorUid) ||
                matchedUids.contains(actorUid) ||
                blockedUids.contains(actorUid) ||
                avoidedUids.contains(actorUid) ||
                !seen.add(actorUid)) {
              return null;
            }

            final profile = await _firestoreService.getPublicProfile(actorUid);
            if (profile == null) return null;
            final ts = data['timestamp'] as Timestamp?;
            final action = data['action'] as String? ?? 'like';
            return ReceivedLike(
              uid: actorUid,
              profile: profile,
              likedAt: ts?.toDate(),
              action: action,
            );
          });

          final results = await Future.wait(futures);
          return results.whereType<ReceivedLike>().toList();
        });
  }

  /// 지인 피하기 pair 상대 목록. 조회 실패는 좋아요 목록을 막지 않는다.
  Future<Set<String>> _loadAvoidedUids(String currentUid) async {
    try {
      return await _contactAvoidanceService
          .watchAvoidedUids(currentUid)
          .first
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      return const <String>{};
    }
  }

  Future<Set<String>> _loadRespondedUids(String currentUid) async {
    final snap = await _db
        .collection('users')
        .doc(currentUid)
        .collection('swipes')
        .get();
    return snap.docs.map((doc) => doc.id).toSet();
  }

  Future<Set<String>> _loadMatchedUids(String currentUid) async {
    final snap = await _db
        .collection('matches')
        .where('participants', arrayContains: currentUid)
        .get();
    final result = <String>{};
    for (final doc in snap.docs) {
      final participants = (doc.data()['participants'] as List<dynamic>? ?? [])
          .map((uid) => uid.toString());
      result.addAll(participants.where((uid) => uid != currentUid));
    }
    return result;
  }
}
