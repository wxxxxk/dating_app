import 'package:cloud_firestore/cloud_firestore.dart';

/// matches/{matchId}/presence/{uid} 문서 모델 — 채팅방 단위 접속/입력 상태.
///
/// 전역 앱 온라인 상태가 아니라 "이 채팅방을 foreground에서 열고 있는가"만
/// 나타낸다. uid 외의 프로필 정보·위치·기기정보는 담지 않는다.
///
/// 앱 강제 종료·네트워크 단절로 offline write가 누락될 수 있으므로, 화면에서는
/// [isOnline]만 믿지 않고 [isFresh]로 heartbeat 만료를 함께 판정한다.
class ChatPresence {
  /// heartbeat(30초) 대비 여유를 둔 stale 판정 기준.
  static const Duration freshnessTimeout = Duration(seconds: 90);

  final String uid;
  final bool isOnline;
  final bool isTyping;
  final DateTime? lastActiveAt;

  const ChatPresence({
    required this.uid,
    required this.isOnline,
    required this.isTyping,
    required this.lastActiveAt,
  });

  /// 마지막 heartbeat가 [timeout] 이내인지. 클라이언트/서버 시각 오차로
  /// lastActiveAt이 now보다 약간 앞설 수 있어 절댓값으로 비교한다.
  bool isFresh({
    required DateTime now,
    Duration timeout = freshnessTimeout,
  }) {
    final last = lastActiveAt;
    if (last == null) return false;
    return now.difference(last).abs() <= timeout;
  }

  /// 실제 online 판정 — 저장된 isOnline과 heartbeat 유효성을 함께 본다.
  bool isActuallyOnline({
    required DateTime now,
    Duration timeout = freshnessTimeout,
  }) {
    return isOnline && isFresh(now: now, timeout: timeout);
  }

  /// 입력 중 표시 여부 — online일 때만 노출한다(stale이면 무조건 false).
  bool isActuallyTyping({
    required DateTime now,
    Duration timeout = freshnessTimeout,
  }) {
    return isTyping && isActuallyOnline(now: now, timeout: timeout);
  }

  /// malformed 문서는 crash 대신 안전한 offline 값으로 보정한다. uid가
  /// 비어 있으면(문서 id 없이 파싱 불가) null을 반환한다. unknown field는 무시.
  static ChatPresence? fromMap(String uid, Map<String, dynamic>? data) {
    if (uid.isEmpty) return null;
    if (data == null) return null;

    final lastActiveAt = data['lastActiveAt'];
    return ChatPresence(
      uid: uid,
      isOnline: data['isOnline'] == true,
      isTyping: data['isTyping'] == true,
      // serverTimestamp 반영 전 pending write 등 Timestamp가 아닌 값은 null로 본다.
      lastActiveAt: lastActiveAt is Timestamp ? lastActiveAt.toDate() : null,
    );
  }

  static ChatPresence? fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    return fromMap(doc.id, doc.data());
  }
}

/// 채팅 상단 상태 바에 표시할 문구(순수 함수).
///
/// online/typing은 heartbeat가 유효할 때만 인정하고, 그 외에는 마지막 접속
/// 시각 기준의 offline 문구로 내려간다. presence 문서가 없거나 lastActiveAt이
/// 없으면 시각을 추정하지 않고 '최근 접속'으로 둔다.
String chatPresenceLabel({
  required ChatPresence? presence,
  required DateTime now,
  Duration timeout = ChatPresence.freshnessTimeout,
}) {
  if (presence == null) return '최근 접속';

  if (presence.isActuallyOnline(now: now, timeout: timeout)) {
    return presence.isTyping ? '입력 중...' : '온라인';
  }

  final last = presence.lastActiveAt;
  if (last == null) return '최근 접속';

  // 클라이언트 시각이 뒤처져 lastActiveAt이 미래로 보이는 경우도 '방금 전'으로 본다.
  final elapsed = now.difference(last);
  if (elapsed.inMinutes < 1) return '방금 전 접속';
  if (elapsed.inMinutes < 60) return '${elapsed.inMinutes}분 전 접속';
  if (last.year == now.year && last.month == now.month && last.day == now.day) {
    return '오늘 접속';
  }
  return '최근 접속';
}
