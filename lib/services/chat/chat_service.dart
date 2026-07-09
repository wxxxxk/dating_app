import 'package:cloud_firestore/cloud_firestore.dart';

import '../../models/message_model.dart';

/// matches/{matchId}/messages 서브컬렉션 기반 1:1 채팅 서비스.
///
/// Firestore 구조:
///   matches/{matchId}/messages/{messageId}
///     senderId: string, text: string, createdAt: Timestamp
///   matches/{matchId}.lastMessage
///     { text, senderId, createdAt } — 매칭 목록 미리보기/정렬용
///   matches/{matchId}.lastReadAtByUid.{uid}
///     Timestamp — 매칭 목록 안읽음 표시용
class ChatService {
  ChatService({FirebaseFirestore? firestore})
    : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  DocumentReference<Map<String, dynamic>> _matchRef(String matchId) =>
      _db.collection('matches').doc(matchId);

  /// 메시지 목록을 오래된 순(작성 시각 오름차순)으로 실시간 구독한다.
  Stream<List<MessageModel>> watchMessages(String matchId) {
    return _matchRef(matchId)
        .collection('messages')
        .orderBy('createdAt', descending: false)
        .snapshots()
        .map((snap) => snap.docs.map(MessageModel.fromFirestore).toList());
  }

  /// 메시지를 전송하고, matches 문서의 lastMessage를 함께 갱신한다.
  ///
  /// 두 쓰기를 batch로 묶어 "메시지는 저장됐는데 미리보기는 안 바뀜" 같은
  /// 부분 실패 상태를 막는다. 빈 메시지(trim 후 공백)는 전송하지 않는다.
  Future<void> sendMessage({
    required String matchId,
    required String senderId,
    required String text,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    final matchRef = _matchRef(matchId);
    final messageRef = matchRef.collection('messages').doc();
    final serverNow = FieldValue.serverTimestamp();

    final batch = _db.batch();
    batch.set(messageRef, {
      'senderId': senderId,
      'text': trimmed,
      'createdAt': serverNow,
    });
    batch.update(matchRef, {
      'lastMessage': {
        'text': trimmed,
        'senderId': senderId,
        'createdAt': serverNow,
      },
    });
    await batch.commit();
  }

  /// 현재 유저가 이 매치의 메시지를 확인한 시각을 기록한다.
  Future<void> markMatchRead({
    required String matchId,
    required String currentUid,
  }) async {
    await _matchRef(matchId).update({
      FieldPath(['lastReadAtByUid', currentUid]): FieldValue.serverTimestamp(),
    });
  }

  /// 이 매치가 (나든 상대든) 해제됐는지 실시간으로 구독한다.
  ///
  /// 채팅방 접근 제한(입력 비활성화/안내 배너)용. 채팅방을 이미 열어둔 채로
  /// 상대가 해제해도 바로 반영되도록 스트림으로 둔다. 메시지 create 자체는
  /// firestore.rules가 서버 단에서도 막으므로, 이 스트림은 UX(안내/비활성화)
  /// 목적이지 유일한 방어선이 아니다.
  Stream<bool> watchIsUnmatched(String matchId) {
    return _matchRef(matchId).snapshots().map((snap) {
      final unmatchedBy = snap.data()?['unmatchedBy'] as List<dynamic>?;
      return unmatchedBy != null && unmatchedBy.isNotEmpty;
    });
  }
}
