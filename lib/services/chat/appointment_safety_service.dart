import 'package:cloud_firestore/cloud_firestore.dart';

import '../../models/appointment_safety_checkin.dart';

/// 안전 확인 입력값 검증 실패. 사용자에게는 [message]만 노출하고 raw 오류는 감춘다.
class AppointmentSafetyValidationError implements Exception {
  final String message;
  const AppointmentSafetyValidationError(this.message);

  @override
  String toString() => 'AppointmentSafetyValidationError: $message';
}

/// matches/{matchId}/appointments/{appointmentId}/safetyCheckins/{uid} 기반
/// 약속 전·후 안전 확인 서비스(Phase 2-5).
///
/// 저장하는 값은 "만남 전 확인을 마친 시각"과 "만남 후 상태"뿐이다. 체크리스트
/// 개별 답변·위치·귀가 경로·보호자 연락처·신고 내용은 저장하지 않는다.
/// 문서는 본인만 읽을 수 있고(rules), 상대에게 알림도 보내지 않는다.
class AppointmentSafetyService {
  AppointmentSafetyService({FirebaseFirestore? firestore})
    : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  /// checkin 문서 경로(순수 함수). rules의 경로와 1:1 대응한다.
  static String checkinPath({
    required String matchId,
    required String appointmentId,
    required String uid,
  }) {
    return 'matches/$matchId/appointments/$appointmentId/safetyCheckins/$uid';
  }

  /// 아직 문서가 없을 때 쓰는 초기 payload(순수 함수). 다섯 필드를 모두 포함해야
  /// rules의 exact field allowlist를 통과한다.
  static Map<String, dynamic> buildInitialCheckinDoc({
    required String uid,
    required Object timestamp,
    Object? preCheckCompletedAt,
    AppointmentPostSafetyStatus? postStatus,
  }) {
    return {
      'uid': uid,
      'preCheckCompletedAt': preCheckCompletedAt,
      'postStatus': postStatus == null
          ? null
          : appointmentPostSafetyStatusToString(postStatus),
      'postCheckedAt': postStatus == null ? null : timestamp,
      'updatedAt': timestamp,
    };
  }

  DocumentReference<Map<String, dynamic>> _checkinRef({
    required String matchId,
    required String appointmentId,
    required String uid,
  }) {
    return _db.doc(
      checkinPath(matchId: matchId, appointmentId: appointmentId, uid: uid),
    );
  }

  /// 본인 checkin을 실시간 구독한다. 문서가 없거나 malformed면 null을 흘린다.
  Stream<AppointmentSafetyCheckin?> watchCheckin({
    required String matchId,
    required String appointmentId,
    required String uid,
  }) {
    return _checkinRef(
      matchId: matchId,
      appointmentId: appointmentId,
      uid: uid,
    ).snapshots().map((snap) {
      if (!snap.exists) return null;
      return AppointmentSafetyCheckin.fromMap(snap.id, snap.data());
    });
  }

  /// 만남 전 안전 확인 완료를 기록한다.
  ///
  /// 이미 기록돼 있으면 아무것도 하지 않는다(idempotent). 기존 post 상태는
  /// 그대로 보존한다. 트랜잭션으로 처리해 동시 탭에서도 중복 기록되지 않는다.
  Future<void> completePreCheck({
    required String matchId,
    required String appointmentId,
    required String uid,
  }) async {
    if (uid.isEmpty) {
      throw ArgumentError.value(uid, 'uid', 'uid가 비어 있습니다.');
    }

    final ref = _checkinRef(
      matchId: matchId,
      appointmentId: appointmentId,
      uid: uid,
    );

    await _db.runTransaction((tx) async {
      final snap = await tx.get(ref);
      final serverNow = FieldValue.serverTimestamp();

      if (!snap.exists) {
        tx.set(
          ref,
          buildInitialCheckinDoc(
            uid: uid,
            timestamp: serverNow,
            preCheckCompletedAt: serverNow,
          ),
        );
        return;
      }

      final existing = AppointmentSafetyCheckin.fromMap(snap.id, snap.data());
      // 이미 완료했으면 다시 쓰지 않는다 — 기록 시각이 덮이지 않게 한다.
      if (existing?.hasCompletedPreCheck ?? false) return;

      tx.update(ref, {
        'preCheckCompletedAt': serverNow,
        'updatedAt': serverNow,
      });
    });
  }

  /// 만남 후 상태를 기록한다.
  ///
  /// 한 번 기록한 상태는 다른 값으로 바꿀 수 없다(같은 값 재호출은 no-op).
  /// 약속 시각 전에는 기록할 수 없다. 만남 전 확인을 건너뛰었어도 호출 가능하다.
  Future<void> completePostCheck({
    required String matchId,
    required String appointmentId,
    required String uid,
    required DateTime scheduledAt,
    required AppointmentPostSafetyStatus status,
    DateTime? now,
  }) async {
    if (uid.isEmpty) {
      throw ArgumentError.value(uid, 'uid', 'uid가 비어 있습니다.');
    }
    final current = now ?? DateTime.now();
    if (appointmentSafetyPhase(scheduledAt: scheduledAt, now: current) !=
        AppointmentSafetyPhase.postDate) {
      throw const AppointmentSafetyValidationError('약속 시간이 지난 뒤에 확인할 수 있어요.');
    }

    final ref = _checkinRef(
      matchId: matchId,
      appointmentId: appointmentId,
      uid: uid,
    );

    await _db.runTransaction((tx) async {
      final snap = await tx.get(ref);
      final serverNow = FieldValue.serverTimestamp();

      if (!snap.exists) {
        tx.set(
          ref,
          buildInitialCheckinDoc(
            uid: uid,
            timestamp: serverNow,
            postStatus: status,
          ),
        );
        return;
      }

      final existing = AppointmentSafetyCheckin.fromMap(snap.id, snap.data());
      final recorded = existing?.postStatus;
      if (recorded != null) {
        // 같은 상태 재호출은 no-op, 다른 상태로의 변경은 거부한다.
        if (recorded == status) return;
        throw const AppointmentSafetyValidationError('이미 기록한 상태는 바꿀 수 없어요.');
      }

      tx.update(ref, {
        'postStatus': appointmentPostSafetyStatusToString(status),
        'postCheckedAt': serverNow,
        'updatedAt': serverNow,
      });
    });
  }
}
