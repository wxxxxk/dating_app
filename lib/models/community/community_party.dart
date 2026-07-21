/// Party·Square 모델(Phase 4-4).
///
/// 하나의 파티 문서를 Square 탐색과 "내 파티" 관리가 함께 쓴다.
///
/// **정확한 만남 장소·위경도·참가비 필드는 이 모델에 존재하지 않는다.** 지역은
/// 광역 단위 key 하나뿐이고, 상세 장소는 Phase 4-5 그룹 채팅에서 참여가 확정된
/// 뒤에 공유하는 것이 정책이다.
library;

import 'package:cloud_firestore/cloud_firestore.dart';

import 'community_author_snapshot.dart';

/// 파티 모집 상태.
enum CommunityPartyStatus { open, full, cancelled }

String communityPartyStatusToString(CommunityPartyStatus status) => status.name;

/// **알 수 없는 값을 open으로 오인하지 않는다.** 모르면 null을 돌려주고,
/// 호출부는 표시하지 않는 쪽(fail-closed)으로 처리한다.
CommunityPartyStatus? communityPartyStatusFromString(Object? value) {
  switch (value) {
    case 'open':
      return CommunityPartyStatus.open;
    case 'full':
      return CommunityPartyStatus.full;
    case 'cancelled':
      return CommunityPartyStatus.cancelled;
    default:
      return null;
  }
}

/// 파티 안에서의 역할.
enum CommunityPartyRole { host, member }

CommunityPartyRole? communityPartyRoleFromString(Object? value) {
  switch (value) {
    case 'host':
      return CommunityPartyRole.host;
    case 'member':
      return CommunityPartyRole.member;
    default:
      return null;
  }
}

/// 내 파티 목록에서 쓰는 상태(mirror 문서의 state).
enum CommunityPartyMembershipState { active, pending }

CommunityPartyMembershipState? communityPartyMembershipStateFromString(
  Object? value,
) {
  switch (value) {
    case 'active':
      return CommunityPartyMembershipState.active;
    case 'pending':
      return CommunityPartyMembershipState.pending;
    default:
      return null;
  }
}

/// 참여 요청 상태.
enum CommunityPartyJoinStatus { pending, approved, rejected, withdrawn }

CommunityPartyJoinStatus? communityPartyJoinStatusFromString(Object? value) {
  switch (value) {
    case 'pending':
      return CommunityPartyJoinStatus.pending;
    case 'approved':
      return CommunityPartyJoinStatus.approved;
    case 'rejected':
      return CommunityPartyJoinStatus.rejected;
    case 'withdrawn':
      return CommunityPartyJoinStatus.withdrawn;
    default:
      return null;
  }
}

/// 서버 allowlist와 1:1로 대응하는 카테고리/지역 목록.
///
/// 클라이언트는 key만 서버에 보낸다 — 한국어 label은 표시 전용이고, 서버가
/// 최종 권한을 갖는다(임의 문자열을 보낼 수 있는 경로는 없다).
class CommunityPartyOptions {
  const CommunityPartyOptions._();

  static const int titleMaxLength = 60;
  static const int descriptionMaxLength = 500;
  static const int joinMessageMaxLength = 200;

  static const int minParticipants = 3;
  static const int maxParticipants = 8;

  /// 서버와 동일한 모임 시각 범위(최소 2시간 뒤, 최대 30일 이내).
  static const Duration minStartLead = Duration(hours: 2);
  static const Duration maxStartAhead = Duration(days: 30);

  static const Map<String, String> categoryLabels = {
    'coffee': '커피·수다',
    'dining': '맛집·식사',
    'culture': '전시·공연',
    'hobby': '취미',
    'exercise': '운동',
    'walk': '산책',
    'study': '스터디',
    'other': '기타',
  };

  static const Map<String, String> areaLabels = {
    'seoul': '서울',
    'gyeonggi': '경기',
    'incheon': '인천',
    'busan': '부산',
    'daegu': '대구',
    'daejeon': '대전',
    'gwangju': '광주',
    'ulsan': '울산',
    'sejong': '세종',
    'gangwon': '강원',
    'chungbuk': '충북',
    'chungnam': '충남',
    'jeonbuk': '전북',
    'jeonnam': '전남',
    'gyeongbuk': '경북',
    'gyeongnam': '경남',
    'jeju': '제주',
    'online': '온라인',
  };

  static List<String> get categoryKeys => categoryLabels.keys.toList();
  static List<String> get areaKeys => areaLabels.keys.toList();

  /// 모르는 key는 그대로 노출하지 않고 중립 문구로 바꾼다.
  static String categoryLabel(String key) => categoryLabels[key] ?? '기타';
  static String areaLabel(String key) => areaLabels[key] ?? '지역 미정';
}

DateTime? _timestampOf(Object? value) {
  if (value is Timestamp) return value.toDate();
  if (value is DateTime) return value;
  return null;
}

/// communityParties/{partyId} 문서 모델.
class CommunityParty {
  static const int supportedSchemaVersion = 1;

  final String id;
  final String hostUid;
  final CommunityAuthorSnapshot host;
  final String title;
  final String description;
  final String category;
  final String area;
  final DateTime startAt;
  final int maxParticipants;
  final int participantCount;
  final CommunityPartyStatus status;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final int schemaVersion;

  const CommunityParty({
    required this.id,
    required this.hostUid,
    required this.host,
    required this.title,
    required this.description,
    required this.category,
    required this.area,
    required this.startAt,
    required this.maxParticipants,
    required this.participantCount,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    required this.schemaVersion,
  });

  /// 목록·상세에 보여도 되는 상태인지. 취소된 파티는 노출하지 않는다.
  bool get isVisible =>
      status == CommunityPartyStatus.open ||
      status == CommunityPartyStatus.full;

  bool get isFull =>
      status == CommunityPartyStatus.full ||
      participantCount >= maxParticipants;

  bool get isPast => startAt.isBefore(DateTime.now());

  /// 새 참여 요청을 받을 수 있는 상태인지(최종 판정은 서버가 한다).
  bool get acceptsJoinRequests =>
      status == CommunityPartyStatus.open && !isFull && !isPast;

  String get categoryLabel => CommunityPartyOptions.categoryLabel(category);
  String get areaLabel => CommunityPartyOptions.areaLabel(area);

  /// 필수 필드가 malformed면 null을 반환한다(부분 렌더링 방지).
  static CommunityParty? fromMap(String id, Map<String, dynamic>? data) {
    if (id.isEmpty || data == null) return null;

    if (data['visibility'] != 'authenticated') return null;

    final schemaVersion = data['schemaVersion'];
    if (schemaVersion is! int || schemaVersion != supportedSchemaVersion) {
      return null;
    }

    final status = communityPartyStatusFromString(data['status']);
    if (status == null) return null;

    final hostUid = data['hostUid'];
    if (hostUid is! String || hostUid.isEmpty) return null;

    final host = CommunityAuthorSnapshot.fromMap(
      data['hostSnapshot'] is Map
          ? Map<String, dynamic>.from(data['hostSnapshot'] as Map)
          : null,
    );
    if (host == null) return null;

    final title = data['title'];
    if (title is! String || title.isEmpty) return null;
    final description = data['description'];
    if (description is! String || description.isEmpty) return null;

    final category = data['category'];
    if (category is! String || category.isEmpty) return null;
    final area = data['area'];
    if (area is! String || area.isEmpty) return null;

    final startAt = _timestampOf(data['startAt']);
    if (startAt == null) return null;

    final maxParticipants = data['maxParticipants'];
    if (maxParticipants is! int ||
        maxParticipants < CommunityPartyOptions.minParticipants ||
        maxParticipants > CommunityPartyOptions.maxParticipants) {
      return null;
    }

    final rawCount = data['participantCount'];
    if (rawCount is! int || rawCount < 1) return null;
    // 서버가 보정하지만, 표시 단계에서도 정원을 넘지 않게 잘라둔다.
    final participantCount = rawCount > maxParticipants
        ? maxParticipants
        : rawCount;

    return CommunityParty(
      id: id,
      hostUid: hostUid,
      host: host,
      title: title,
      description: description,
      category: category,
      area: area,
      startAt: startAt,
      maxParticipants: maxParticipants,
      participantCount: participantCount,
      status: status,
      createdAt: _timestampOf(data['createdAt']),
      updatedAt: _timestampOf(data['updatedAt']),
      schemaVersion: schemaVersion,
    );
  }
}

/// users/{uid}/partyMemberships/{partyId} mirror 문서.
///
/// "내가 관여한 파티"의 단일 목록이다. 파티별 member/joinRequest 목록을 훑지
/// 않고 이 문서만 읽어 내 파티 화면을 만든다.
class CommunityPartyMembership {
  final String partyId;
  final CommunityPartyRole role;
  final CommunityPartyMembershipState state;
  final DateTime? updatedAt;

  const CommunityPartyMembership({
    required this.partyId,
    required this.role,
    required this.state,
    required this.updatedAt,
  });

  bool get isHost => role == CommunityPartyRole.host;
  bool get isPending => state == CommunityPartyMembershipState.pending;

  static CommunityPartyMembership? fromMap(
    String id,
    Map<String, dynamic>? data,
  ) {
    if (id.isEmpty || data == null) return null;
    final role = communityPartyRoleFromString(data['role']);
    if (role == null) return null;
    final state = communityPartyMembershipStateFromString(data['state']);
    if (state == null) return null;

    final partyId = data['partyId'];
    // 문서 id가 곧 partyId다. 어긋나면 신뢰하지 않는다.
    if (partyId is! String || partyId != id) return null;

    return CommunityPartyMembership(
      partyId: id,
      role: role,
      state: state,
      updatedAt: _timestampOf(data['updatedAt']),
    );
  }
}

/// communityParties/{partyId}/joinRequests/{uid} 문서.
///
/// 호스트에게 보여줄 때도 공개 snapshot과 요청 메시지만 쓴다 — UID는 화면에
/// 표시하지 않는다.
class CommunityPartyJoinRequest {
  final String requesterUid;
  final CommunityAuthorSnapshot requester;
  final String message;
  final CommunityPartyJoinStatus status;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const CommunityPartyJoinRequest({
    required this.requesterUid,
    required this.requester,
    required this.message,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
  });

  bool get isPending => status == CommunityPartyJoinStatus.pending;

  static CommunityPartyJoinRequest? fromMap(
    String id,
    Map<String, dynamic>? data,
  ) {
    if (id.isEmpty || data == null) return null;
    final status = communityPartyJoinStatusFromString(data['status']);
    if (status == null) return null;

    final requesterUid = data['requesterUid'];
    if (requesterUid is! String || requesterUid.isEmpty) return null;

    final requester = CommunityAuthorSnapshot.fromMap(
      data['requesterSnapshot'] is Map
          ? Map<String, dynamic>.from(data['requesterSnapshot'] as Map)
          : null,
    );
    if (requester == null) return null;

    final message = data['message'];

    return CommunityPartyJoinRequest(
      requesterUid: requesterUid,
      requester: requester,
      message: message is String ? message : '',
      status: status,
      createdAt: _timestampOf(data['createdAt']),
      updatedAt: _timestampOf(data['updatedAt']),
    );
  }
}

/// communityParties/{partyId}/groupMessages/{messageId} 문서 모델(Phase 4-5).
///
/// 표시에 쓰는 값은 저장된 공개 snapshot과 본문·시각뿐이다 — UID·전화번호·
/// 기관명·정확 위치·membership 내부 정보는 담지 않는다.
class PartyGroupMessage {
  static const int textMaxLength = 1000;
  static const int supportedSchemaVersion = 1;

  final String id;
  final String senderUid;
  final CommunityAuthorSnapshot sender;
  final String text;
  final DateTime? createdAt;

  const PartyGroupMessage({
    required this.id,
    required this.senderUid,
    required this.sender,
    required this.text,
    required this.createdAt,
  });

  /// 필수 필드가 malformed거나 removed면 null을 반환한다(부분 렌더링 방지).
  ///
  /// **알 수 없는 status를 active로 오인하지 않는다** — 모르면 표시하지 않는
  /// 쪽(fail-closed)으로 처리한다.
  static PartyGroupMessage? fromMap(String id, Map<String, dynamic>? data) {
    if (id.isEmpty || data == null) return null;

    if (data['status'] != 'active') return null;

    final schemaVersion = data['schemaVersion'];
    if (schemaVersion is! int || schemaVersion != supportedSchemaVersion) {
      return null;
    }

    final senderUid = data['senderUid'];
    if (senderUid is! String || senderUid.isEmpty) return null;

    final sender = CommunityAuthorSnapshot.fromMap(
      data['senderSnapshot'] is Map
          ? Map<String, dynamic>.from(data['senderSnapshot'] as Map)
          : null,
    );
    if (sender == null) return null;

    final text = data['text'];
    if (text is! String || text.isEmpty || text.length > textMaxLength) {
      return null;
    }

    return PartyGroupMessage(
      id: id,
      senderUid: senderUid,
      sender: sender,
      text: text,
      createdAt: _timestampOf(data['createdAt']),
    );
  }
}
