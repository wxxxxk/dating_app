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

/// 메시지 신고 사유 key와 사용자 표시 라벨.
///
/// 사용자 전체 신고([reportReasonLabels])와 목적이 달라 별도로 둔다 — 사유
/// key 집합이 서로 다르고, firestore.rules도 두 경로를 따로 검증한다.
const messageReportReasonLabels = {
  'abusive_language': '욕설·모욕',
  'sexual_harassment': '성적 불쾌감',
  'hate_threat': '혐오·협박',
  'spam_scam': '사기·스팸',
  'personal_info': '개인정보 요구·노출',
  'other': '기타',
};

/// 신고 상세 내용 최대 길이(사용자 신고/메시지 신고 공통, rules와 동일 값).
const int reportDetailMaxLength = 500;

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

  /// 특정 메시지를 신고한다(Phase 2-4).
  ///
  /// **메시지 원문(text)은 저장하지 않는다.** 운영 검토는 matchId/messageId로
  /// 원본 메시지를 참조한다(메시지는 update/delete가 금지돼 있어 보존된다).
  /// 전화번호·계좌번호 같은 민감한 원문이 reports에 중복 적재되지 않게 하려는
  /// 의도적인 설계다.
  ///
  /// 아래 검증은 오입력을 빨리 막기 위한 클라이언트 1차 방어이고, 최종 방어는
  /// firestore.rules가 담당한다(실제 match participants·message.senderId 확인).
  Future<void> reportMessage({
    required String reporterUid,
    required String reportedUid,
    required String matchId,
    required String messageId,
    required String reason,
    String? detail,
  }) async {
    await _db.collection('reports').add(
      buildMessageReportDoc(
        reporterUid: reporterUid,
        reportedUid: reportedUid,
        matchId: matchId,
        messageId: messageId,
        reason: reason,
        detail: detail,
        createdAt: FieldValue.serverTimestamp(),
      ),
    );
  }

  /// 메시지 신고 문서 payload(순수 함수). 입력 검증도 여기서 수행하므로 잘못된
  /// 값은 Firestore write 전에 [ArgumentError]로 거부된다. [createdAt]은
  /// 프로덕션에서 FieldValue.serverTimestamp(), 테스트에서는 고정 값을 넣는다.
  ///
  /// **메시지 원문(text)은 어떤 경우에도 포함하지 않는다.**
  static Map<String, dynamic> buildMessageReportDoc({
    required String reporterUid,
    required String reportedUid,
    required String matchId,
    required String messageId,
    required String reason,
    required Object createdAt,
    String? detail,
  }) {
    if (reporterUid.isEmpty) {
      throw ArgumentError.value(reporterUid, 'reporterUid', '신고자 uid가 비어 있습니다.');
    }
    if (reportedUid.isEmpty) {
      throw ArgumentError.value(reportedUid, 'reportedUid', '대상 uid가 비어 있습니다.');
    }
    if (reporterUid == reportedUid) {
      throw ArgumentError.value(reportedUid, 'reportedUid', '자기 메시지는 신고할 수 없습니다.');
    }
    if (matchId.isEmpty) {
      throw ArgumentError.value(matchId, 'matchId', 'matchId가 비어 있습니다.');
    }
    if (messageId.isEmpty) {
      throw ArgumentError.value(messageId, 'messageId', 'messageId가 비어 있습니다.');
    }
    if (!messageReportReasonLabels.containsKey(reason)) {
      throw ArgumentError.value(reason, 'reason', '허용되지 않는 신고 사유입니다.');
    }
    final trimmedDetail = detail?.trim() ?? '';
    if (trimmedDetail.length > reportDetailMaxLength) {
      throw ArgumentError.value(
        trimmedDetail.length,
        'detail',
        '상세 내용은 $reportDetailMaxLength자까지 입력할 수 있습니다.',
      );
    }

    return {
      'reportType': 'message',
      'reporterUid': reporterUid,
      'reportedUid': reportedUid,
      'matchId': matchId,
      'messageId': messageId,
      'reason': reason,
      if (trimmedDetail.isNotEmpty) 'detail': trimmedDetail,
      'createdAt': createdAt,
    };
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
