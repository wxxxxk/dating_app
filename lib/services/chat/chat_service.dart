import 'package:cloud_firestore/cloud_firestore.dart';

import '../../models/message_model.dart';

/// matches/{matchId}/messages 서브컬렉션 기반 1:1 채팅 서비스.
///
/// Firestore 구조:
///   matches/{matchId}/messages/{messageId}
///     senderId: string, text: string, createdAt: Timestamp
///   matches/{matchId}.lastMessage
///     { text, senderId, createdAt } — 매칭 목록 미리보기/정렬용
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
}
