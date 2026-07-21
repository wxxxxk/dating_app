// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

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
  ///
  /// swipe 스냅샷과 지인 피하기 pair 스냅샷 **둘 중 하나만 바뀌어도** 새 목록을
  /// 방출한다(Phase 3-4A). pair가 추가되면 해당 좋아요가 즉시 사라지고, pair가
  /// 풀리면 swipe 변경 없이도 다시 나타난다. 원본 swipe 문서는 건드리지 않는다.
  Stream<List<ReceivedLike>> watchReceivedLikes({required String currentUid}) {
    final swipes = _db
        .collectionGroup('swipes')
        .where('targetUid', isEqualTo: currentUid)
        .where('action', whereIn: ['like', 'superlike'])
        .orderBy('timestamp', descending: true)
        .snapshots();
    final avoided = _contactAvoidanceService
        .watchAvoidedUids(currentUid)
        // pair 조회 실패가 좋아요 목록 전체를 막지 않게 한다.
        .handleError((Object _) {})
        .cast<Set<String>>();

    late final StreamController<List<ReceivedLike>> controller;
    StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? swipeSub;
    StreamSubscription<Set<String>>? avoidedSub;

    QuerySnapshot<Map<String, dynamic>>? latestSwipes;
    var avoidedUids = <String>{};
    var hasAvoided = false;
    // 늦게 끝난 오래된 계산이 최신 결과를 덮지 않도록 요청 순번을 센다.
    var requestId = 0;

    Future<void> recompute() async {
      final snap = latestSwipes;
      // pair 스냅샷이 아직 오지 않았어도 좋아요 목록을 막지 않는다.
      if (snap == null) return;
      final myRequest = ++requestId;
      try {
        final results = await _buildReceivedLikes(
          currentUid: currentUid,
          snap: snap,
          avoidedUids: hasAvoided ? avoidedUids : const <String>{},
        );
        if (myRequest != requestId || controller.isClosed) return;
        controller.add(results);
      } catch (e, st) {
        if (myRequest != requestId || controller.isClosed) return;
        // 개별 계산 실패로 stream을 영구 종료시키지 않는다.
        controller.addError(e, st);
      }
    }

    controller = StreamController<List<ReceivedLike>>.broadcast(
      onListen: () {
        swipeSub = swipes.listen(
          (snap) {
            latestSwipes = snap;
            recompute();
          },
          onError: controller.addError,
        );
        avoidedSub = avoided.listen((uids) {
          // 같은 집합이면 다시 계산하지 않는다(불필요한 중복 emit 방지).
          if (hasAvoided && setEquals(avoidedUids, uids)) return;
          avoidedUids = uids;
          hasAvoided = true;
          recompute();
        });
      },
      onCancel: () async {
        await swipeSub?.cancel();
        await avoidedSub?.cancel();
        swipeSub = null;
        avoidedSub = null;
      },
    );

    return controller.stream;
  }

  /// swipe 스냅샷 + 제외 집합으로 표시할 좋아요 목록을 만든다.
  Future<List<ReceivedLike>> _buildReceivedLikes({
    required String currentUid,
    required QuerySnapshot<Map<String, dynamic>> snap,
    required Set<String> avoidedUids,
  }) async {
    final respondedUids = await _loadRespondedUids(currentUid);
    final matchedUids = await _loadMatchedUids(currentUid);
    final blockedUids = await _safetyService.getBlockedRelationshipUids(
      currentUid,
    );
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
          // 지인 피하기 상대의 좋아요는 목록에서만 숨긴다(문서는 유지).
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
