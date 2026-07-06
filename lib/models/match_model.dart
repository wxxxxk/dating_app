import 'package:cloud_firestore/cloud_firestore.dart';

import 'user_profile.dart';

/// matches/{matchId}.lastMessage 필드 (채팅 미리보기용).
///
/// 메시지를 보낼 때마다 ChatService가 matches 문서에 함께 기록한다.
class LastMessage {
  final String text;
  final String senderId;
  final DateTime createdAt;

  const LastMessage({
    required this.text,
    required this.senderId,
    required this.createdAt,
  });

  /// Firestore에서 lastMessage는 null(아직 대화 없음)일 수 있고,
  /// serverTimestamp가 아직 확정되지 않은 과도기 문서일 수도 있어 방어적으로 파싱한다.
  static LastMessage? fromMap(Map<String, dynamic>? map) {
    if (map == null) return null;
    final ts = map['createdAt'] as Timestamp?;
    if (ts == null) return null;
    return LastMessage(
      text: map['text'] as String? ?? '',
      senderId: map['senderId'] as String? ?? '',
      createdAt: ts.toDate(),
    );
  }
}

/// Firestore matches/{matchId} 문서 모델.
///
/// matchId = [uid1, uid2].sort().join('_') — 멱등 생성 보장.
/// participants 배열 필드로 arrayContains 쿼리를 사용한다.
class MatchModel {
  final String matchId;
  final List<String> participants;
  final String uid1;
  final String uid2;
  final DateTime matchedAt;
  final LastMessage? lastMessage;
  final Map<String, DateTime> lastReadAtByUid;

  const MatchModel({
    required this.matchId,
    required this.participants,
    required this.uid1,
    required this.uid2,
    required this.matchedAt,
    this.lastMessage,
    this.lastReadAtByUid = const {},
  });

  /// 현재 유저의 UID를 받아 상대방 UID를 반환한다.
  String otherUid(String currentUid) => uid1 == currentUid ? uid2 : uid1;

  DateTime? lastReadAtFor(String uid) => lastReadAtByUid[uid];

  factory MatchModel.fromFirestore(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? {};
    return MatchModel(
      matchId: doc.id,
      participants: (d['participants'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
      uid1: d['uid1'] as String? ?? '',
      uid2: d['uid2'] as String? ?? '',
      matchedAt: (d['matchedAt'] as Timestamp?)?.toDate() ?? DateTime(1970),
      lastMessage: LastMessage.fromMap(
        d['lastMessage'] as Map<String, dynamic>?,
      ),
      lastReadAtByUid: _parseLastReadAtByUid(d['lastReadAtByUid']),
    );
  }

  static Map<String, DateTime> _parseLastReadAtByUid(Object? value) {
    final map = value as Map<String, dynamic>?;
    if (map == null) return const {};

    final parsed = <String, DateTime>{};
    for (final entry in map.entries) {
      final timestamp = entry.value;
      if (timestamp is Timestamp) {
        parsed[entry.key] = timestamp.toDate();
      }
    }
    return parsed;
  }
}

/// MatchModel + 상대방 UserProfile을 묶은 뷰 모델.
///
/// MatchesScreen 리스트 렌더링과 축하 오버레이에서 모두 사용한다.
class MatchWithProfile {
  final MatchModel match;
  final UserProfile otherProfile;

  const MatchWithProfile({required this.match, required this.otherProfile});
}
