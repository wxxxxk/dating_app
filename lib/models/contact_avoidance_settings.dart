import 'package:cloud_firestore/cloud_firestore.dart';

/// users/{uid}/contactAvoidanceSettings/current 문서 모델(Phase 3-4).
///
/// 전화번호 해시나 숨김 대상 UID 목록은 담지 않는다 — 요약 수치만 담는다.
class ContactAvoidanceSettings {
  final bool enabled;
  final int contactCount;
  final int hiddenCount;
  final DateTime? syncedAt;

  const ContactAvoidanceSettings({
    this.enabled = false,
    this.contactCount = 0,
    this.hiddenCount = 0,
    this.syncedAt,
  });

  /// 아직 한 번도 동기화하지 않은 기본 상태.
  static const ContactAvoidanceSettings disabled = ContactAvoidanceSettings();

  /// malformed 문서는 crash 없이 비활성 상태로 읽는다. unknown field는 무시.
  static ContactAvoidanceSettings fromMap(Map<String, dynamic>? data) {
    if (data == null) return disabled;
    final syncedAt = data['syncedAt'];
    return ContactAvoidanceSettings(
      enabled: data['enabled'] == true,
      contactCount: data['contactCount'] is int
          ? data['contactCount'] as int
          : 0,
      hiddenCount: data['hiddenCount'] is int ? data['hiddenCount'] as int : 0,
      syncedAt: syncedAt is Timestamp ? syncedAt.toDate() : null,
    );
  }

  static ContactAvoidanceSettings fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    if (!doc.exists) return disabled;
    return fromMap(doc.data());
  }
}

/// syncAvoidContacts callable 응답. UID·digest·pairId는 담기지 않는다.
class ContactAvoidanceSyncResult {
  final bool enabled;
  final int contactCount;
  final int hiddenCount;

  const ContactAvoidanceSyncResult({
    required this.enabled,
    required this.contactCount,
    required this.hiddenCount,
  });

  /// 서버 응답 파싱. 알 수 없는 필드는 무시하고 누락은 안전한 기본값으로 둔다.
  static ContactAvoidanceSyncResult fromMap(Map<Object?, Object?>? data) {
    return ContactAvoidanceSyncResult(
      enabled: data?['enabled'] == true,
      contactCount: data?['contactCount'] is int
          ? data!['contactCount'] as int
          : 0,
      hiddenCount: data?['hiddenCount'] is int
          ? data!['hiddenCount'] as int
          : 0,
    );
  }
}
