import 'package:cloud_firestore/cloud_firestore.dart';

/// 채팅 약속 상태.
enum ChatAppointmentStatus { pending, accepted, declined }

/// Firestore 저장용 문자열 ↔ enum 변환. enum name이 그대로 저장 문자열이다
/// (pending/accepted/declined). 알 수 없는 값은 안전하게 pending으로 본다.
String chatAppointmentStatusToString(ChatAppointmentStatus status) =>
    status.name;

ChatAppointmentStatus chatAppointmentStatusFromString(Object? value) {
  switch (value) {
    case 'accepted':
      return ChatAppointmentStatus.accepted;
    case 'declined':
      return ChatAppointmentStatus.declined;
    default:
      return ChatAppointmentStatus.pending;
  }
}

/// matches/{matchId}/appointments/{appointmentId} 문서 모델.
///
/// 지도 좌표·전화번호·SNS 등 민감 정보는 담지 않는다. 약속은 날짜/시간/장소/
/// 선택 메모만 구조화한다. malformed 문서는 [fromMap]이 null을 반환해 화면이
/// 안전한 대체 표시로 넘어가도록 하고, 앱 crash로 이어지지 않는다.
class ChatAppointment {
  final String id;
  final String proposerUid;
  final String recipientUid;
  final DateTime scheduledAt;
  final String place;
  final String note;
  final ChatAppointmentStatus status;
  final DateTime? createdAt;
  final DateTime? respondedAt;
  final String? respondedBy;

  const ChatAppointment({
    required this.id,
    required this.proposerUid,
    required this.recipientUid,
    required this.scheduledAt,
    required this.place,
    required this.note,
    required this.status,
    required this.createdAt,
    required this.respondedAt,
    required this.respondedBy,
  });

  bool get isPending => status == ChatAppointmentStatus.pending;
  bool get isAccepted => status == ChatAppointmentStatus.accepted;
  bool get isDeclined => status == ChatAppointmentStatus.declined;

  bool isProposer(String uid) => proposerUid == uid;
  bool isRecipient(String uid) => recipientUid == uid;

  /// 필수 필드(proposerUid/recipientUid/scheduledAt)가 유효하지 않으면 null을
  /// 반환한다. 나머지 필드는 방어적으로 기본값을 채운다.
  static ChatAppointment? fromMap(String id, Map<String, dynamic>? data) {
    if (data == null) return null;
    final proposerUid = data['proposerUid'];
    final recipientUid = data['recipientUid'];
    final scheduledAt = data['scheduledAt'];
    if (proposerUid is! String || proposerUid.isEmpty) return null;
    if (recipientUid is! String || recipientUid.isEmpty) return null;
    if (scheduledAt is! Timestamp) return null;

    return ChatAppointment(
      id: id,
      proposerUid: proposerUid,
      recipientUid: recipientUid,
      scheduledAt: scheduledAt.toDate(),
      place: data['place'] is String ? data['place'] as String : '',
      note: data['note'] is String ? data['note'] as String : '',
      status: chatAppointmentStatusFromString(data['status']),
      createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
      respondedAt: (data['respondedAt'] as Timestamp?)?.toDate(),
      respondedBy: data['respondedBy'] is String
          ? data['respondedBy'] as String
          : null,
    );
  }

  static ChatAppointment? fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    return fromMap(doc.id, doc.data());
  }
}
