import 'package:cloud_firestore/cloud_firestore.dart';

/// matches/{matchId}/messages/{messageId} 문서 모델.
class MessageModel {
  final String id;
  final String senderId;
  final String text;

  /// 서버 타임스탬프. 방금 보낸 메시지가 로컬 캐시에서 먼저 렌더링될 때는
  /// 서버 확정 전이라 null일 수 있다(추후 서버 값으로 갱신되어 스냅샷이 다시 온다).
  final DateTime? createdAt;

  const MessageModel({
    required this.id,
    required this.senderId,
    required this.text,
    required this.createdAt,
  });

  factory MessageModel.fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final d = doc.data() ?? {};
    return MessageModel(
      id: doc.id,
      senderId: d['senderId'] as String? ?? '',
      text: d['text'] as String? ?? '',
      createdAt: (d['createdAt'] as Timestamp?)?.toDate(),
    );
  }
}
