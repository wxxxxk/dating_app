import 'package:cloud_firestore/cloud_firestore.dart';

/// 만남 후 상태. 사용자 본인만 보는 개인 기록이며 상대에게 공개되지 않는다.
enum AppointmentPostSafetyStatus { safe, needsSupport, cancelled }

/// Firestore 저장 문자열 ↔ enum 변환.
/// - safe / needs_support / cancelled
String appointmentPostSafetyStatusToString(AppointmentPostSafetyStatus status) {
  switch (status) {
    case AppointmentPostSafetyStatus.safe:
      return 'safe';
    case AppointmentPostSafetyStatus.needsSupport:
      return 'needs_support';
    case AppointmentPostSafetyStatus.cancelled:
      return 'cancelled';
  }
}

/// 알 수 없는 값은 null로 본다(임의의 상태로 추측하지 않는다).
AppointmentPostSafetyStatus? appointmentPostSafetyStatusFromString(
  Object? value,
) {
  switch (value) {
    case 'safe':
      return AppointmentPostSafetyStatus.safe;
    case 'needs_support':
      return AppointmentPostSafetyStatus.needsSupport;
    case 'cancelled':
      return AppointmentPostSafetyStatus.cancelled;
    default:
      return null;
  }
}

/// matches/{matchId}/appointments/{appointmentId}/safetyCheckins/{uid} 문서 모델.
///
/// **사용자 본인만 읽을 수 있는 개인 상태다**(rules에서 owner-only read).
/// 체크리스트 개별 답변·위치·귀가 경로·보호자 연락처는 저장하지 않고, 만남 전
/// 확인을 완료한 시각과 만남 후 상태만 담는다.
class AppointmentSafetyCheckin {
  final String uid;
  final DateTime? preCheckCompletedAt;
  final AppointmentPostSafetyStatus? postStatus;
  final DateTime? postCheckedAt;
  final DateTime? updatedAt;

  const AppointmentSafetyCheckin({
    required this.uid,
    required this.preCheckCompletedAt,
    required this.postStatus,
    required this.postCheckedAt,
    required this.updatedAt,
  });

  bool get hasCompletedPreCheck => preCheckCompletedAt != null;
  bool get hasCompletedPostCheck => postStatus != null;
  bool get needsSupport => postStatus == AppointmentPostSafetyStatus.needsSupport;

  /// malformed 문서는 crash 없이 안전한 기본값으로 보정한다. Timestamp가 아닌
  /// 시각 필드는 null, 알 수 없는 postStatus도 null로 둔다. unknown field는 무시.
  static AppointmentSafetyCheckin? fromMap(
    String uid,
    Map<String, dynamic>? data,
  ) {
    if (uid.isEmpty) return null;
    if (data == null) return null;

    final preCheckCompletedAt = data['preCheckCompletedAt'];
    final postCheckedAt = data['postCheckedAt'];
    final updatedAt = data['updatedAt'];
    final postStatus = appointmentPostSafetyStatusFromString(data['postStatus']);

    return AppointmentSafetyCheckin(
      uid: uid,
      preCheckCompletedAt: preCheckCompletedAt is Timestamp
          ? preCheckCompletedAt.toDate()
          : null,
      postStatus: postStatus,
      // 상태가 없으면 기록 시각도 의미가 없으므로 함께 비운다.
      postCheckedAt: postStatus != null && postCheckedAt is Timestamp
          ? postCheckedAt.toDate()
          : null,
      updatedAt: updatedAt is Timestamp ? updatedAt.toDate() : null,
    );
  }

  static AppointmentSafetyCheckin? fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    return fromMap(doc.id, doc.data());
  }
}

/// 약속 안전 확인 단계.
enum AppointmentSafetyPhase { preDate, postDate }

/// 약속 시각 기준 단계 판정(순수 함수).
///
/// 유예시간이나 별도 timezone 변환을 새로 만들지 않고, appointment의
/// scheduledAt DateTime 계약을 그대로 쓴다.
AppointmentSafetyPhase appointmentSafetyPhase({
  required DateTime scheduledAt,
  required DateTime now,
}) {
  return now.isBefore(scheduledAt)
      ? AppointmentSafetyPhase.preDate
      : AppointmentSafetyPhase.postDate;
}
