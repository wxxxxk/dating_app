import 'package:cloud_firestore/cloud_firestore.dart';

import '../../models/chat_appointment.dart';
import '../../models/message_model.dart';

/// 약속 입력값 검증 실패. 사용자에게는 [message]만 노출하고 raw 오류는 감춘다.
class AppointmentValidationError implements Exception {
  final String message;
  const AppointmentValidationError(this.message);

  @override
  String toString() => 'AppointmentValidationError: $message';
}

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

  // ── 채팅 약속 ──────────────────────────────────────────────────────────
  //
  // matches/{matchId}/appointments/{appointmentId} 서브컬렉션에 약속을 저장하고,
  // 같은 batch로 약속 메시지(messages)와 lastMessage 미리보기를 함께 갱신한다.
  // UI 검증만 믿지 않고 firestore.rules가 서버 단에서도 권한/필드를 제한한다.

  static const int appointmentPlaceMaxLength = 80;
  static const int appointmentNoteMaxLength = 200;
  static const int appointmentMaxDaysAhead = 180;

  static const String appointmentProposalText = '약속을 제안했어요.';
  static const String appointmentAcceptedText = '약속을 수락했어요.';
  static const String appointmentDeclinedText = '이번 약속은 어려워요.';

  /// 약속 입력값을 trim/검증한다(순수 함수). 실패 시 [AppointmentValidationError].
  /// [now]를 주입할 수 있어 테스트에서 시간 의존성을 제거한다.
  static ({String place, String note}) normalizeAppointmentInput({
    required DateTime scheduledAt,
    required String place,
    required String note,
    DateTime? now,
  }) {
    final current = now ?? DateTime.now();
    if (!scheduledAt.isAfter(current)) {
      throw const AppointmentValidationError('현재 이후 시간으로 약속을 잡아 주세요.');
    }
    final trimmedPlace = place.trim();
    if (trimmedPlace.isEmpty) {
      throw const AppointmentValidationError('장소를 입력해 주세요.');
    }
    if (trimmedPlace.length > appointmentPlaceMaxLength) {
      throw const AppointmentValidationError('장소는 80자까지 입력할 수 있어요.');
    }
    final trimmedNote = note.trim();
    if (trimmedNote.length > appointmentNoteMaxLength) {
      throw const AppointmentValidationError('메모는 200자까지 입력할 수 있어요.');
    }
    return (place: trimmedPlace, note: trimmedNote);
  }

  /// appointment 문서 payload(순수 함수). [createdAt]은 프로덕션에서
  /// FieldValue.serverTimestamp(), 테스트에서는 고정 값을 주입한다.
  static Map<String, dynamic> buildAppointmentDoc({
    required String proposerUid,
    required String recipientUid,
    required DateTime scheduledAt,
    required String place,
    required String note,
    required Object createdAt,
  }) {
    return {
      'proposerUid': proposerUid,
      'recipientUid': recipientUid,
      'scheduledAt': Timestamp.fromDate(scheduledAt),
      'place': place,
      'note': note,
      'status': chatAppointmentStatusToString(ChatAppointmentStatus.pending),
      'createdAt': createdAt,
      'respondedAt': null,
      'respondedBy': null,
    };
  }

  /// 약속 제안 메시지 payload(순수 함수).
  static Map<String, dynamic> buildAppointmentMessageDoc({
    required String senderId,
    required String appointmentId,
    required Object createdAt,
  }) {
    return {
      'senderId': senderId,
      'text': appointmentProposalText,
      'type': 'appointment',
      'appointmentId': appointmentId,
      'createdAt': createdAt,
    };
  }

  /// 약속 수락/거절 결과 메시지 payload(순수 함수).
  static Map<String, dynamic> buildAppointmentResponseMessageDoc({
    required String senderId,
    required String appointmentId,
    required ChatAppointmentStatus status,
    required Object createdAt,
  }) {
    final accepted = status == ChatAppointmentStatus.accepted;
    return {
      'senderId': senderId,
      'text': accepted ? appointmentAcceptedText : appointmentDeclinedText,
      'type': 'appointment_response',
      'appointmentId': appointmentId,
      'appointmentStatus': chatAppointmentStatusToString(status),
      'createdAt': createdAt,
    };
  }

  /// 단일 약속 문서를 실시간 구독한다. malformed/삭제 문서는 null을 흘린다.
  Stream<ChatAppointment?> watchAppointment({
    required String matchId,
    required String appointmentId,
  }) {
    return _matchRef(matchId)
        .collection('appointments')
        .doc(appointmentId)
        .snapshots()
        .map((snap) => ChatAppointment.fromMap(snap.id, snap.data()));
  }

  /// 약속을 제안한다. appointment 문서 생성 + 약속 메시지 생성 + lastMessage
  /// 갱신을 단일 batch로 처리하고, 생성된 appointmentId를 반환한다.
  Future<String> proposeAppointment({
    required String matchId,
    required String proposerUid,
    required String recipientUid,
    required DateTime scheduledAt,
    required String place,
    String note = '',
  }) async {
    final normalized = normalizeAppointmentInput(
      scheduledAt: scheduledAt,
      place: place,
      note: note,
    );

    final matchRef = _matchRef(matchId);
    final appointmentRef = matchRef.collection('appointments').doc();
    final messageRef = matchRef.collection('messages').doc();
    final serverNow = FieldValue.serverTimestamp();

    final batch = _db.batch();
    batch.set(
      appointmentRef,
      buildAppointmentDoc(
        proposerUid: proposerUid,
        recipientUid: recipientUid,
        scheduledAt: scheduledAt,
        place: normalized.place,
        note: normalized.note,
        createdAt: serverNow,
      ),
    );
    batch.set(
      messageRef,
      buildAppointmentMessageDoc(
        senderId: proposerUid,
        appointmentId: appointmentRef.id,
        createdAt: serverNow,
      ),
    );
    batch.update(matchRef, {
      'lastMessage': {
        'text': appointmentProposalText,
        'senderId': proposerUid,
        'createdAt': serverNow,
      },
    });
    await batch.commit();
    return appointmentRef.id;
  }

  /// 약속을 수락/거절한다. appointment 상태 갱신 + 결과 메시지 생성 +
  /// lastMessage 갱신을 단일 batch로 처리한다. accepted/declined만 허용한다.
  Future<void> respondToAppointment({
    required String matchId,
    required String appointmentId,
    required String responderUid,
    required ChatAppointmentStatus status,
  }) async {
    if (status != ChatAppointmentStatus.accepted &&
        status != ChatAppointmentStatus.declined) {
      throw ArgumentError('약속 응답은 수락 또는 거절만 가능합니다.');
    }

    final matchRef = _matchRef(matchId);
    final appointmentRef = matchRef
        .collection('appointments')
        .doc(appointmentId);
    final messageRef = matchRef.collection('messages').doc();
    final serverNow = FieldValue.serverTimestamp();
    final text = status == ChatAppointmentStatus.accepted
        ? appointmentAcceptedText
        : appointmentDeclinedText;

    final batch = _db.batch();
    batch.update(appointmentRef, {
      'status': chatAppointmentStatusToString(status),
      'respondedAt': serverNow,
      'respondedBy': responderUid,
    });
    batch.set(
      messageRef,
      buildAppointmentResponseMessageDoc(
        senderId: responderUid,
        appointmentId: appointmentId,
        status: status,
        createdAt: serverNow,
      ),
    );
    batch.update(matchRef, {
      'lastMessage': {
        'text': text,
        'senderId': responderUid,
        'createdAt': serverNow,
      },
    });
    await batch.commit();
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
