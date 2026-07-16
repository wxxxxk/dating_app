import 'package:cloud_firestore/cloud_firestore.dart';

import 'public_profile.dart';

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

  /// 매칭 축하(MatchCelebrationOverlay)를 이미 본 uid 목록.
  ///
  /// null이면 "이 필드를 아직 아무도 쓴 적 없는 매치"(이 기능 도입 이전 매치 포함)라는
  /// 뜻이라 자동 축하 표시 대상에서 제외한다. 빈 배열이 아닌 null과 빈 배열을
  /// 구분하는 것이 기존 매치를 한꺼번에 재축하하지 않기 위한 핵심이다.
  final List<String>? celebratedBy;

  /// 이 매칭을 더 이상 원하지 않는다고 표시한 uid 목록.
  ///
  /// celebratedBy와 달리 null/빈 배열을 구분할 필요가 없다 — "아무도 해제
  /// 안 함"과 "필드가 아예 없음"은 의미가 같다(둘 다 활성 매칭). 한 명이라도
  /// 포함되면 양쪽 모두에게 목록/채팅에서 숨긴다([isUnmatched]).
  final List<String> unmatchedBy;

  const MatchModel({
    required this.matchId,
    required this.participants,
    required this.uid1,
    required this.uid2,
    required this.matchedAt,
    this.lastMessage,
    this.lastReadAtByUid = const {},
    this.celebratedBy,
    this.unmatchedBy = const [],
  });

  /// 현재 유저의 UID를 받아 상대방 UID를 반환한다.
  String otherUid(String currentUid) => uid1 == currentUid ? uid2 : uid1;

  DateTime? lastReadAtFor(String uid) => lastReadAtByUid[uid];

  /// uid가 이 매치의 축하를 이미 봤는지. celebratedBy가 없는 매치는 항상 false.
  bool hasCelebrated(String uid) => celebratedBy?.contains(uid) ?? false;

  /// 이 매치가 "누군가는 봤지만 uid는 아직 못 본" 축하 대기 상태인지.
  bool isPendingCelebrationFor(String uid) =>
      celebratedBy != null && !celebratedBy!.contains(uid);

  /// 둘 중 누구라도 매칭을 해제했는지. true면 양쪽 목록/채팅에서 숨겨야 한다.
  bool get isUnmatched => unmatchedBy.isNotEmpty;

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
      celebratedBy: _parseCelebratedBy(d['celebratedBy']),
      unmatchedBy: _parseStringList(d['unmatchedBy']),
    );
  }

  static List<String>? _parseCelebratedBy(Object? value) {
    if (value is! List) return null;
    return value.map((e) => e.toString()).toList();
  }

  static List<String> _parseStringList(Object? value) {
    if (value is! List) return const [];
    return value.map((e) => e.toString()).toList();
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

/// MatchModel + 상대방 PublicProfile을 묶은 뷰 모델.
///
/// MatchesScreen 리스트 렌더링과 축하 오버레이에서 모두 사용한다.
class MatchWithProfile {
  final MatchModel match;
  final PublicProfile otherProfile;

  const MatchWithProfile({required this.match, required this.otherProfile});
}
