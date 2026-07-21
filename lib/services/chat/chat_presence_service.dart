import 'package:cloud_firestore/cloud_firestore.dart';

import '../../models/chat_presence.dart';

/// matches/{matchId}/presence/{uid} 기반 채팅방 접속/입력 상태 서비스.
///
/// Firestore 구조:
///   matches/{matchId}/presence/{uid}
///     uid: string, isOnline: bool, isTyping: bool,
///     lastActiveAt: Timestamp, updatedAt: Timestamp
///
/// 문서는 삭제하지 않고 상태만 갱신한다(rules에서도 delete 금지). 모든 write는
/// best-effort — 실패해도 메시지 전송 등 채팅 핵심 기능을 막지 않는다.
class ChatPresenceService {
  ChatPresenceService({FirebaseFirestore? firestore})
    : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  /// presence 문서 경로(순수 함수). rules의 matches/{matchId}/presence/{uid}와
  /// 1:1 대응한다.
  static String presencePath({required String matchId, required String uid}) {
    return 'matches/$matchId/presence/$uid';
  }

  /// presence 문서 payload(순수 함수). [timestamp]는 프로덕션에서
  /// FieldValue.serverTimestamp(), 테스트에서는 고정 값을 주입한다.
  ///
  /// offline이면 typing은 항상 false로 내린다 — rules도 같은 조합만 허용한다.
  static Map<String, dynamic> buildPresenceDoc({
    required String uid,
    required bool isOnline,
    required bool isTyping,
    required Object timestamp,
  }) {
    return {
      'uid': uid,
      'isOnline': isOnline,
      'isTyping': isOnline && isTyping,
      'lastActiveAt': timestamp,
      'updatedAt': timestamp,
    };
  }

  DocumentReference<Map<String, dynamic>> _presenceRef({
    required String matchId,
    required String uid,
  }) {
    return _db.doc(presencePath(matchId: matchId, uid: uid));
  }

  /// 상대의 presence를 실시간 구독한다. 문서가 없거나 malformed면 null을 흘린다.
  Stream<ChatPresence?> watchPresence({
    required String matchId,
    required String uid,
  }) {
    return _presenceRef(matchId: matchId, uid: uid).snapshots().map((snap) {
      if (!snap.exists) return null;
      return ChatPresence.fromMap(snap.id, snap.data());
    });
  }

  /// 본인 presence를 merge write한다. lastActiveAt/updatedAt은 항상
  /// serverTimestamp — rules가 `== request.time`을 요구하므로 클라이언트 시각을
  /// 쓰지 않는다. offline이면 typing은 항상 false로 내린다(rules와 동일 계약).
  Future<void> setPresence({
    required String matchId,
    required String uid,
    required bool isOnline,
    required bool isTyping,
  }) async {
    await _presenceRef(matchId: matchId, uid: uid).set(
      buildPresenceDoc(
        uid: uid,
        isOnline: isOnline,
        isTyping: isTyping,
        timestamp: FieldValue.serverTimestamp(),
      ),
      SetOptions(merge: true),
    );
  }

  /// 채팅방 진입/heartbeat — online 상태를 갱신한다. typing은 현재 상태를 유지
  /// 전달해 heartbeat가 입력 중 표시를 되돌리지 않게 한다.
  Future<void> enterChat({
    required String matchId,
    required String uid,
    bool isTyping = false,
  }) {
    return setPresence(
      matchId: matchId,
      uid: uid,
      isOnline: true,
      isTyping: isTyping,
    );
  }

  /// 채팅방 이탈/백그라운드 전환 — offline + typing false.
  Future<void> leaveChat({required String matchId, required String uid}) {
    return setPresence(
      matchId: matchId,
      uid: uid,
      isOnline: false,
      isTyping: false,
    );
  }

  /// 입력 중 상태만 바꾼다(online 유지).
  Future<void> setTyping({
    required String matchId,
    required String uid,
    required bool isTyping,
  }) {
    return setPresence(
      matchId: matchId,
      uid: uid,
      isOnline: true,
      isTyping: isTyping,
    );
  }
}
