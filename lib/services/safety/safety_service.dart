// ignore_for_file: prefer_initializing_formals

import 'package:cloud_firestore/cloud_firestore.dart';

import '../../models/public_profile.dart';
import '../database/firestore_service.dart';

/// 신고 사유 key와 사용자 표시 라벨.
const reportReasonLabels = {
  'inappropriate_photo': '부적절한 사진',
  'abusive_language': '욕설·폭언',
  'spam_scam': '사기·스팸',
  'impersonation': '사칭',
  'other': '기타',
};

/// 차단 목록 화면에서 쓸 차단 사용자 뷰 모델.
class BlockedUser {
  final String uid;
  final PublicProfile? profile;
  final DateTime? createdAt;

  const BlockedUser({
    required this.uid,
    required this.profile,
    required this.createdAt,
  });
}

/// 신고/차단 관련 Firestore 접근을 담당한다.
class SafetyService {
  SafetyService({
    FirebaseFirestore? firestore,
    required FirestoreService firestoreService,
  }) : _db = firestore ?? FirebaseFirestore.instance,
       _firestoreService = firestoreService;

  final FirebaseFirestore _db;
  final FirestoreService _firestoreService;

  /// users/{currentUid}/blocks/{blockedUid}에 차단 기록을 만든다.
  Future<void> blockUser({
    required String currentUid,
    required String blockedUid,
  }) async {
    if (currentUid == blockedUid) return;
    await _db
        .collection('users')
        .doc(currentUid)
        .collection('blocks')
        .doc(blockedUid)
        .set({
          'blockerUid': currentUid,
          'blockedUid': blockedUid,
          'createdAt': FieldValue.serverTimestamp(),
        });
  }

  Future<void> unblockUser({
    required String currentUid,
    required String blockedUid,
  }) async {
    await _db
        .collection('users')
        .doc(currentUid)
        .collection('blocks')
        .doc(blockedUid)
        .delete();
  }

  /// 신고 내용을 reports 컬렉션에 적재한다. 클라이언트 read는 rules에서 막는다.
  Future<void> reportUser({
    required String reporterUid,
    required String reportedUid,
    required String reason,
    String? detail,
  }) async {
    await _db.collection('reports').add({
      'reporterUid': reporterUid,
      'reportedUid': reportedUid,
      'reason': reason,
      if (detail != null && detail.trim().isNotEmpty) 'detail': detail.trim(),
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  /// 내가 차단한 uid와 나를 차단한 uid를 모두 가져온다.
  Future<Set<String>> getBlockedRelationshipUids(String currentUid) async {
    final myBlocks = await _db
        .collection('users')
        .doc(currentUid)
        .collection('blocks')
        .get();
    final blockedByOthers = await _db
        .collectionGroup('blocks')
        .where('blockedUid', isEqualTo: currentUid)
        .get();

    final result = <String>{
      ...myBlocks.docs.map((doc) => doc.id),
      ...blockedByOthers.docs.map(
        (doc) =>
            doc.data()['blockerUid'] as String? ??
            doc.reference.parent.parent?.id ??
            '',
      ),
    }..remove('');
    return result;
  }

  Future<bool> isBlockedBetween({
    required String currentUid,
    required String otherUid,
  }) async {
    final myBlock = await _db
        .collection('users')
        .doc(currentUid)
        .collection('blocks')
        .doc(otherUid)
        .get();
    if (myBlock.exists) return true;

    // 상대의 blocks 하위 문서를 직접 읽으면 소유자 규칙에 막힌다.
    // collectionGroup 규칙은 blockedUid가 본인인 문서만 허용하므로 그 경로로 확인한다.
    final blockedByOther = await _db
        .collectionGroup('blocks')
        .where('blockedUid', isEqualTo: currentUid)
        .get();
    return blockedByOther.docs.any(
      (doc) =>
          doc.data()['blockerUid'] == otherUid ||
          doc.reference.parent.parent?.id == otherUid,
    );
  }

  Stream<List<BlockedUser>> watchBlockedUsers(String currentUid) {
    return _db
        .collection('users')
        .doc(currentUid)
        .collection('blocks')
        .orderBy('createdAt', descending: true)
        .snapshots()
        .asyncMap((snap) async {
          final futures = snap.docs.map((doc) async {
            final data = doc.data();
            final profile = await _firestoreService.getPublicProfile(doc.id);
            final ts = data['createdAt'] as Timestamp?;
            return BlockedUser(
              uid: doc.id,
              profile: profile,
              createdAt: ts?.toDate(),
            );
          });
          return Future.wait(futures);
        });
  }
}
