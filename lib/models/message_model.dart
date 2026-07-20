import 'package:cloud_firestore/cloud_firestore.dart';

import 'chat_appointment.dart';

/// 채팅 메시지 종류. 기존 문서(필드 없음)와 알 수 없는 값은 모두 [text]로 본다.
enum ChatMessageType { text, appointment, appointmentResponse }

/// Firestore `type` 문자열 ↔ enum 변환.
/// - text: 필드 없음 또는 'text'
/// - appointment: 'appointment'
/// - appointmentResponse: 'appointment_response'
ChatMessageType chatMessageTypeFromString(Object? value) {
  switch (value) {
    case 'appointment':
      return ChatMessageType.appointment;
    case 'appointment_response':
      return ChatMessageType.appointmentResponse;
    default:
      return ChatMessageType.text;
  }
}

/// matches/{matchId}/messages/{messageId} 문서 모델.
class MessageModel {
  final String id;
  final String senderId;
  final String text;

  /// 서버 타임스탬프. 방금 보낸 메시지가 로컬 캐시에서 먼저 렌더링될 때는
  /// 서버 확정 전이라 null일 수 있다(추후 서버 값으로 갱신되어 스냅샷이 다시 온다).
  final DateTime? createdAt;

  /// 메시지 종류. 약속 제안/응답 메시지를 일반 텍스트와 구분한다. 기존 메시지는
  /// 필드가 없어 [ChatMessageType.text]로 파싱되므로 하위 호환이 유지된다.
  final ChatMessageType type;

  /// 약속 제안/응답 메시지가 가리키는 appointment 문서 id.
  final String? appointmentId;

  /// 약속 응답 메시지가 담은 수락/거절 상태. 제안 메시지에서는 null이다.
  final ChatAppointmentStatus? appointmentStatus;

  const MessageModel({
    required this.id,
    required this.senderId,
    required this.text,
    required this.createdAt,
    this.type = ChatMessageType.text,
    this.appointmentId,
    this.appointmentStatus,
  });

  /// 약속 카드/시스템 행이 아니라 일반 텍스트 말풍선으로 렌더링해야 하는가.
  /// appointmentId가 비어 있는 약속 메시지도 안전하게 텍스트로 폴백한다.
  bool get isPlainText =>
      type == ChatMessageType.text ||
      (appointmentId == null || appointmentId!.isEmpty);

  bool get isAppointment =>
      type == ChatMessageType.appointment &&
      appointmentId != null &&
      appointmentId!.isNotEmpty;

  bool get isAppointmentResponse =>
      type == ChatMessageType.appointmentResponse;

  factory MessageModel.fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    return MessageModel.fromMap(doc.id, doc.data());
  }

  factory MessageModel.fromMap(String id, Map<String, dynamic>? data) {
    final d = data ?? {};
    final appointmentId = d['appointmentId'];
    final appointmentStatus = d['appointmentStatus'];
    return MessageModel(
      id: id,
      senderId: d['senderId'] as String? ?? '',
      text: d['text'] as String? ?? '',
      createdAt: (d['createdAt'] as Timestamp?)?.toDate(),
      type: chatMessageTypeFromString(d['type']),
      appointmentId: appointmentId is String && appointmentId.isNotEmpty
          ? appointmentId
          : null,
      appointmentStatus: appointmentStatus is String
          ? chatAppointmentStatusFromString(appointmentStatus)
          : null,
    );
  }
}
