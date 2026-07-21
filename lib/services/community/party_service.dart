import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../../core/constants/app_constants.dart';
import '../../models/community/community_party.dart';
import 'community_service.dart';

/// Party·Square 서비스 — Phase 4-4.
///
/// 읽기는 Firestore 구독, **쓰기는 전부 Cloud Functions callable**이다.
/// 클라이언트는 snapshot·status·participantCount·timestamp를 만들지 않고,
/// 차단·지인 피하기 판정도 서버가 최종적으로 다시 한다(목록 필터는 표시용).
///
/// 오류는 [CommunityActionError]로 통일해 라운지·피드와 같은 처리 경로를 쓴다.
class PartyService {
  PartyService({FirebaseFirestore? firestore, FirebaseFunctions? functions})
    : _db = firestore ?? FirebaseFirestore.instance,
      _functions =
          functions ??
          FirebaseFunctions.instanceFor(region: AppConstants.functionsRegion);

  final FirebaseFirestore _db;
  final FirebaseFunctions _functions;

  static const String collectionPath = 'communityParties';
  static const String membersSubcollection = 'members';
  static const String joinRequestsSubcollection = 'joinRequests';
  static const String membershipsSubcollection = 'partyMemberships';
  static const String usersCollection = 'users';

  static const int defaultSquareLimit = 30;
  static const int defaultMembershipLimit = 50;
  static const int defaultRequestLimit = 50;

  static const String createPartyCallable = 'createCommunityParty';
  static const String requestJoinCallable = 'requestPartyJoin';
  static const String reviewJoinCallable = 'reviewPartyJoinRequest';
  static const String withdrawJoinCallable = 'withdrawPartyJoinRequest';
  static const String leavePartyCallable = 'leaveCommunityParty';
  static const String cancelPartyCallable = 'cancelCommunityParty';
  static const String reportPartyCallable = 'reportCommunityParty';

  // Phase 4-5: 그룹 채팅.
  static const String groupMessagesSubcollection = 'groupMessages';
  static const int defaultMessageLimit = 100;

  static const String sendMessageCallable = 'sendPartyGroupMessage';
  static const String deleteMessageCallable = 'deletePartyGroupMessage';
  static const String reportMessageCallable = 'reportPartyGroupMessage';

  /// 서버가 "연락처 공유 확인이 필요하다"고 알릴 때 details에 담는 고정 code.
  static const String ackRequiredErrorCode = 'party_chat/ack_required';

  DocumentReference<Map<String, dynamic>> _partyRef(String partyId) =>
      _db.collection(collectionPath).doc(partyId);

  // ── 읽기 ────────────────────────────────────────────────────────────────

  /// Square 탐색 목록. 아직 시작하지 않은 공개 파티를 가까운 순으로 구독한다.
  ///
  /// 쿼리 조건(visibility/status)은 firestore.rules의 list 조건과 일치해야
  /// 한다 — 전체를 읽어와 클라이언트에서 거르지 않는다.
  Stream<List<CommunityParty>> watchSquareParties({
    int limit = defaultSquareLimit,
    DateTime? now,
  }) {
    final from = now ?? DateTime.now();
    return _db
        .collection(collectionPath)
        .where('visibility', isEqualTo: 'authenticated')
        .where('status', whereIn: const ['open', 'full'])
        .where('startAt', isGreaterThanOrEqualTo: Timestamp.fromDate(from))
        .orderBy('startAt')
        .limit(limit)
        .snapshots()
        .map(parseParties);
  }

  /// 파티 한 건을 실시간 구독한다. 취소·삭제되면 null을 흘려 상세 화면이
  /// "볼 수 없는 파티" 상태로 바뀔 수 있게 한다.
  Stream<CommunityParty?> watchParty(String partyId) {
    if (partyId.isEmpty) return Stream.value(null);
    return _partyRef(partyId).snapshots().map((snap) {
      if (!snap.exists) return null;
      final party = CommunityParty.fromMap(snap.id, snap.data());
      if (party == null || !party.isVisible) return null;
      return party;
    });
  }

  /// 내가 관여한 파티 mirror 목록(host/참여 중/승인 대기).
  ///
  /// state 필터 없이 한 번에 읽고 화면에서 분류한다 — 상태별로 나눠 구독하면
  /// 같은 문서를 여러 번 읽게 되고 composite index만 늘어난다.
  Stream<List<CommunityPartyMembership>> watchMyMemberships({
    required String uid,
    int limit = defaultMembershipLimit,
  }) {
    if (uid.isEmpty) {
      return Stream.value(const <CommunityPartyMembership>[]);
    }
    return _db
        .collection(usersCollection)
        .doc(uid)
        .collection(membershipsSubcollection)
        .orderBy('updatedAt', descending: true)
        .limit(limit)
        .snapshots()
        .map(parseMemberships);
  }

  /// 호스트가 보는 대기 중 참여 요청 목록. 호스트가 아니면 rules가 막는다.
  Stream<List<CommunityPartyJoinRequest>> watchPendingJoinRequests({
    required String partyId,
    int limit = defaultRequestLimit,
  }) {
    if (partyId.isEmpty) {
      return Stream.value(const <CommunityPartyJoinRequest>[]);
    }
    return _partyRef(partyId)
        .collection(joinRequestsSubcollection)
        .where('status', isEqualTo: 'pending')
        .orderBy('createdAt')
        .limit(limit)
        .snapshots()
        .map(parseJoinRequests);
  }

  /// 이 파티에 대한 내 참여 요청 상태(없으면 null).
  Stream<CommunityPartyJoinRequest?> watchMyJoinRequest({
    required String partyId,
    required String uid,
  }) {
    if (partyId.isEmpty || uid.isEmpty) return Stream.value(null);
    return _partyRef(partyId)
        .collection(joinRequestsSubcollection)
        .doc(uid)
        .snapshots()
        .map((snap) {
          if (!snap.exists) return null;
          return CommunityPartyJoinRequest.fromMap(snap.id, snap.data());
        });
  }

  /// 내가 이 파티의 확정 멤버인지.
  Stream<bool> watchIsMember({
    required String partyId,
    required String uid,
  }) {
    if (partyId.isEmpty || uid.isEmpty) return Stream.value(false);
    return _partyRef(partyId)
        .collection(membersSubcollection)
        .doc(uid)
        .snapshots()
        .map((snap) => snap.exists);
  }

  /// 파티 그룹 채팅 메시지를 오래된 순으로 구독한다.
  ///
  /// 쿼리 조건(status)은 firestore.rules의 list 조건과 일치해야 한다 —
  /// 전체를 읽어와 클라이언트에서 거르지 않는다.
  Stream<List<PartyGroupMessage>> watchGroupMessages({
    required String partyId,
    int limit = defaultMessageLimit,
  }) {
    if (partyId.isEmpty) return Stream.value(const <PartyGroupMessage>[]);
    return _partyRef(partyId)
        .collection(groupMessagesSubcollection)
        .where('status', isEqualTo: 'active')
        .orderBy('createdAt')
        .limit(limit)
        .snapshots()
        .map(parseGroupMessages);
  }

  // ── 쓰기(전부 서버 callable) ─────────────────────────────────────────────

  /// 파티를 만들고 새 partyId를 돌려준다.
  Future<String> createParty({
    required String title,
    required String description,
    required String category,
    required String area,
    required DateTime startAt,
    required int maxParticipants,
  }) async {
    final data = await _call(createPartyCallable, {
      'title': title,
      'description': description,
      'category': category,
      'area': area,
      'startAtMillis': startAt.millisecondsSinceEpoch,
      'maxParticipants': maxParticipants,
    });
    final partyId = data['partyId'];
    if (partyId is! String || partyId.isEmpty) {
      throw const CommunityActionError(CommunityService.genericErrorMessage);
    }
    return partyId;
  }

  /// 참여 요청. 같은 pending 요청을 다시 보내도 서버가 멱등 처리한다.
  Future<void> requestJoin({
    required String partyId,
    String message = '',
  }) async {
    await _call(requestJoinCallable, {
      'partyId': partyId,
      'message': message.trim(),
    });
  }

  /// 호스트의 승인/거절. 서버가 보정한 인원·상태를 함께 돌려준다.
  Future<PartyReviewResult> reviewJoinRequest({
    required String partyId,
    required String requesterUid,
    required bool approve,
  }) async {
    final data = await _call(reviewJoinCallable, {
      'partyId': partyId,
      'requesterUid': requesterUid,
      'decision': approve ? 'approve' : 'reject',
    });
    final result = PartyReviewResult.fromMap(data);
    if (result == null) {
      throw const CommunityActionError(CommunityService.genericErrorMessage);
    }
    return result;
  }

  Future<void> withdrawJoinRequest({required String partyId}) async {
    await _call(withdrawJoinCallable, {'partyId': partyId});
  }

  Future<void> leaveParty({required String partyId}) async {
    await _call(leavePartyCallable, {'partyId': partyId});
  }

  Future<void> cancelParty({required String partyId}) async {
    await _call(cancelPartyCallable, {'partyId': partyId});
  }

  Future<void> reportParty({
    required String partyId,
    required String reason,
    String? detail,
  }) async {
    final trimmed = detail?.trim() ?? '';
    await _call(reportPartyCallable, {
      'partyId': partyId,
      'reason': reason,
      'detail': trimmed,
    });
  }

  /// 그룹 채팅 메시지를 보내고 새 messageId를 돌려준다.
  ///
  /// [safetyAcknowledged]는 클라이언트가 연락처 공유 경고를 보여주고 사용자가
  /// 계속하기를 고른 경우에만 true다. 서버가 최종 판정한다.
  Future<String> sendGroupMessage({
    required String partyId,
    required String text,
    bool safetyAcknowledged = false,
  }) async {
    final data = await _call(sendMessageCallable, {
      'partyId': partyId,
      'text': text,
      'safetyAcknowledged': safetyAcknowledged,
    });
    final messageId = data['messageId'];
    if (messageId is! String || messageId.isEmpty) {
      throw const CommunityActionError(CommunityService.genericErrorMessage);
    }
    return messageId;
  }

  Future<void> deleteGroupMessage({
    required String partyId,
    required String messageId,
  }) async {
    await _call(deleteMessageCallable, {
      'partyId': partyId,
      'messageId': messageId,
    });
  }

  Future<void> reportGroupMessage({
    required String partyId,
    required String messageId,
    required String reason,
    String? detail,
  }) async {
    await _call(reportMessageCallable, {
      'partyId': partyId,
      'messageId': messageId,
      'reason': reason,
      'detail': detail?.trim() ?? '',
    });
  }

  /// callable 호출 공통 처리. raw Firebase 오류는 밖으로 내보내지 않고,
  /// 입력 text/uid도 로그로 남기지 않는다.
  Future<Map<Object?, Object?>> _call(
    String name,
    Map<String, dynamic> payload,
  ) async {
    try {
      final result = await _functions.httpsCallable(name).call(payload);
      final data = result.data;
      if (data is Map) return data;
      throw const CommunityActionError(CommunityService.genericErrorMessage);
    } on CommunityActionError {
      rethrow;
    } on FirebaseFunctionsException catch (e) {
      throw mapPartyException(e);
    } catch (_) {
      throw const CommunityActionError(CommunityService.genericErrorMessage);
    }
  }

  /// 서버 code → 고정 안내 문구.
  ///
  /// 라운지·피드 매핑을 재사용하되, 파티에서 뜻이 다른 code만 덮어쓴다.
  /// `permission-denied`는 차단·지인 피하기 거부에도 쓰이므로 "권한이 없어요"
  /// 대신 이유를 알 수 없는 중립 문구를 쓴다(관계 노출 방지).
  static CommunityActionError mapPartyException(
    FirebaseFunctionsException e,
  ) {
    final details = e.details;
    if (details is Map && details['code'] == ackRequiredErrorCode) {
      // 연락처 공유 확인이 필요한 경우다 — 화면이 경고를 띄우고 다시 보낸다.
      return PartyContactAckRequired(
        e.message?.trim().isNotEmpty == true
            ? e.message!.trim()
            : PartyContactAckRequired.defaultMessage,
      );
    }
    switch (e.code) {
      case 'permission-denied':
        return const CommunityActionError('지금은 이 파티에 참여할 수 없어요.');
      case 'not-found':
        return const CommunityActionError('이미 종료됐거나 볼 수 없는 파티예요.');
      case 'failed-precondition':
        // 서버가 보낸 고정 문구가 상황별로 다르다(정원·시작 시각·중복 등).
        // 관계나 상대 정보는 담기지 않으므로 그대로 보여줄 수 있다.
        final message = e.message?.trim() ?? '';
        if (message.isNotEmpty) return CommunityActionError(message);
        return const CommunityActionError('지금은 이 파티에 참여할 수 없어요.');
      default:
        return CommunityService.mapFunctionsException(e);
    }
  }

  // ── 파싱(순수 함수) ──────────────────────────────────────────────────────

  /// 스냅샷 → 표시 가능한 파티 목록(순수 함수).
  /// malformed 문서와 취소된 파티는 조용히 건너뛴다.
  static List<CommunityParty> parseParties(
    QuerySnapshot<Map<String, dynamic>> snapshot,
  ) {
    final parties = <CommunityParty>[];
    final seen = <String>{};
    for (final doc in snapshot.docs) {
      final party = CommunityParty.fromMap(doc.id, doc.data());
      if (party == null || !party.isVisible) continue;
      if (!seen.add(party.id)) continue;
      parties.add(party);
    }
    return List<CommunityParty>.unmodifiable(parties);
  }

  static List<CommunityPartyMembership> parseMemberships(
    QuerySnapshot<Map<String, dynamic>> snapshot,
  ) {
    final memberships = <CommunityPartyMembership>[];
    final seen = <String>{};
    for (final doc in snapshot.docs) {
      final membership = CommunityPartyMembership.fromMap(doc.id, doc.data());
      if (membership == null) continue;
      if (!seen.add(membership.partyId)) continue;
      memberships.add(membership);
    }
    return List<CommunityPartyMembership>.unmodifiable(memberships);
  }

  /// 스냅샷 → 표시 가능한 메시지 목록(순수 함수).
  /// malformed 문서와 removed 메시지는 조용히 건너뛴다.
  static List<PartyGroupMessage> parseGroupMessages(
    QuerySnapshot<Map<String, dynamic>> snapshot,
  ) {
    final messages = <PartyGroupMessage>[];
    final seen = <String>{};
    for (final doc in snapshot.docs) {
      final message = PartyGroupMessage.fromMap(doc.id, doc.data());
      if (message == null) continue;
      if (!seen.add(message.id)) continue;
      messages.add(message);
    }
    return List<PartyGroupMessage>.unmodifiable(messages);
  }

  static List<CommunityPartyJoinRequest> parseJoinRequests(
    QuerySnapshot<Map<String, dynamic>> snapshot,
  ) {
    final requests = <CommunityPartyJoinRequest>[];
    final seen = <String>{};
    for (final doc in snapshot.docs) {
      final request = CommunityPartyJoinRequest.fromMap(doc.id, doc.data());
      if (request == null || !request.isPending) continue;
      if (!seen.add(request.requesterUid)) continue;
      requests.add(request);
    }
    return List<CommunityPartyJoinRequest>.unmodifiable(requests);
  }
}

/// 승인/거절 결과. 서버가 보정한 인원·상태만 담는다(대상 UID 없음).
class PartyReviewResult {
  final bool approved;
  final int participantCount;
  final CommunityPartyStatus status;

  const PartyReviewResult({
    required this.approved,
    required this.participantCount,
    required this.status,
  });

  static PartyReviewResult? fromMap(Map<Object?, Object?> data) {
    final decision = data['decision'];
    if (decision is! String) return null;
    if (decision != 'approve' && decision != 'reject') return null;

    final count = data['participantCount'];
    if (count is! int || count < 1) return null;

    final status = communityPartyStatusFromString(data['status']);
    if (status == null) return null;

    return PartyReviewResult(
      approved: decision == 'approve',
      participantCount: count,
      status: status,
    );
  }
}

/// 연락처·외부 메신저 언급이 있어 사용자 확인이 필요한 상태(Phase 4-5).
///
/// 실패가 아니라 "한 번 더 확인하고 다시 보내라"는 신호다. 화면이 경고를
/// 보여주고 사용자가 계속하기를 고르면 safetyAcknowledged: true로 재전송한다.
class PartyContactAckRequired extends CommunityActionError {
  static const String defaultMessage =
      '연락처를 공유하면 원하지 않는 연락을 받을 수 있어요.\n'
      '파티 참여자에게만 보내는 내용인지 다시 확인해주세요.';

  const PartyContactAckRequired(super.message);
}
