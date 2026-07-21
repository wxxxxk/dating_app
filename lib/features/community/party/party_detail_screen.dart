import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../models/community/community_party.dart';
import '../../../services/auth/auth_service.dart';
import '../../../services/community/community_service.dart';
import '../../../services/community/party_service.dart';
import '../../../services/privacy/contact_avoidance_service.dart';
import '../../../services/safety/safety_service.dart';
import '../community_report_sheet.dart';
import '../group_chat/party_group_chat_screen.dart';
import '../community_text_guard.dart';
import '../lounge/lounge_widgets.dart';
import 'party_widgets.dart';

/// 파티 상세 화면(Phase 4-4).
///
/// 일반 사용자는 참여 요청/요청 취소/나가기/신고를, 호스트는 대기 중 요청
/// 승인·거절과 파티 취소를 한다.
///
/// **UID·전화번호·정확 주소·생년월일·기관명은 표시하지 않고, 상대가 나를
/// 차단했는지나 지인 피하기 대상인지도 알려주지 않는다.** 참여할 수 없는
/// 이유는 항상 같은 중립 문구로만 안내한다.
class PartyDetailScreen extends StatefulWidget {
  final String partyId;
  final AuthService authService;
  final PartyService partyService;
  final SafetyService safetyService;
  final ContactAvoidanceService contactAvoidanceService;

  const PartyDetailScreen({
    super.key,
    required this.partyId,
    required this.authService,
    required this.partyService,
    required this.safetyService,
    required this.contactAvoidanceService,
  });

  @override
  State<PartyDetailScreen> createState() => _PartyDetailScreenState();
}

class _PartyDetailScreenState extends State<PartyDetailScreen> {
  /// stream error 재시도를 위해 다시 구독할 수 있어야 하므로 final이 아니다.
  late Stream<CommunityParty?> _partyStream = widget.partyService.watchParty(
    widget.partyId,
  );
  late final Stream<CommunityPartyJoinRequest?> _myRequestStream = widget
      .partyService
      .watchMyJoinRequest(partyId: widget.partyId, uid: _currentUid ?? '');
  late final Stream<bool> _isMemberStream = widget.partyService.watchIsMember(
    partyId: widget.partyId,
    uid: _currentUid ?? '',
  );

  /// build 안에서 만들면 rebuild마다 재구독되어 목록이 초기화된다.
  late final Stream<List<CommunityPartyJoinRequest>> _pendingRequestsStream =
      widget.partyService.watchPendingJoinRequests(partyId: widget.partyId);

  final _messageController = TextEditingController();

  bool _busy = false;

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  String? get _currentUid => widget.authService.currentUser?.uid;

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _retryParty() {
    setState(() {
      _partyStream = widget.partyService.watchParty(widget.partyId);
    });
  }

  /// 파티 액션 공통 처리. 실패해도 raw 오류는 노출하지 않는다.
  Future<void> _run(Future<void> Function() action, String successMessage) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      _showMessage(successMessage);
    } on CommunityActionError catch (e) {
      _showMessage(e.message);
    } catch (_) {
      _showMessage(CommunityService.genericErrorMessage);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── 참여자 액션 ─────────────────────────────────────────────────────────

  Future<void> _requestJoin() async {
    final message = _messageController.text.trim();
    if (message.isNotEmpty) {
      final allowed = await confirmCommunityTextBeforeSubmit(context, message);
      if (!allowed || !mounted) return;
    }
    await _run(
      () => widget.partyService.requestJoin(
        partyId: widget.partyId,
        message: message,
      ),
      '참여 요청을 보냈어요.',
    );
    if (mounted) _messageController.clear();
  }

  Future<void> _withdraw() async {
    final confirmed = await _confirm(
      title: '참여 요청을 취소할까요?',
      message: '취소한 뒤에도 다시 요청할 수 있어요.',
      confirmLabel: '요청 취소',
    );
    if (confirmed != true) return;
    await _run(
      () => widget.partyService.withdrawJoinRequest(partyId: widget.partyId),
      '참여 요청을 취소했어요.',
    );
  }

  Future<void> _leave() async {
    final confirmed = await _confirm(
      title: '파티에서 나갈까요?',
      message: '나가면 자리가 다시 열려요.',
      confirmLabel: '나가기',
    );
    if (confirmed != true) return;
    await _run(
      () => widget.partyService.leaveParty(partyId: widget.partyId),
      '파티에서 나왔어요.',
    );
  }

  // ── 호스트 액션 ─────────────────────────────────────────────────────────

  Future<void> _review(String requesterUid, {required bool approve}) async {
    await _run(
      () => widget.partyService.reviewJoinRequest(
        partyId: widget.partyId,
        requesterUid: requesterUid,
        approve: approve,
      ),
      approve ? '참여를 승인했어요.' : '참여 요청을 거절했어요.',
    );
  }

  Future<void> _cancelParty() async {
    final confirmed = await _confirm(
      title: '파티를 취소할까요?',
      message: '취소하면 참여자에게 더 이상 보이지 않고 되돌릴 수 없어요.',
      confirmLabel: '파티 취소',
    );
    if (confirmed != true) return;
    await _run(
      () => widget.partyService.cancelParty(partyId: widget.partyId),
      '파티를 취소했어요.',
    );
    if (mounted) Navigator.of(context).pop();
  }

  /// 그룹 채팅으로 이동한다. 최종 자격 판정은 서버·Rules가 한다.
  void _openGroupChat() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PartyGroupChatScreen(
          partyId: widget.partyId,
          authService: widget.authService,
          partyService: widget.partyService,
          safetyService: widget.safetyService,
          contactAvoidanceService: widget.contactAvoidanceService,
        ),
      ),
    );
  }

  // ── 신고 ────────────────────────────────────────────────────────────────

  Future<void> _report(CommunityParty party) async {
    final uid = _currentUid;
    if (uid == null || _busy) return;
    _busy = true;
    try {
      final outcome = await showPartyReportSheet(
        context,
        partyService: widget.partyService,
        safetyService: widget.safetyService,
        currentUid: uid,
        partyId: party.id,
        reportedUid: party.hostUid,
      );
      if (outcome == null || !mounted) return;
      _showMessage(outcome.blocked ? '신고하고 차단했어요.' : '신고를 접수했어요.');
    } finally {
      _busy = false;
    }
  }

  Future<bool?> _confirm({
    required String title,
    required String message,
    required String confirmLabel,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
  }

  // ── build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final uid = _currentUid;
    return Scaffold(
      key: const ValueKey('party-detail-screen'),
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: const Text('파티'),
      ),
      body: SafeArea(
        child: StreamBuilder<CommunityParty?>(
          stream: _partyStream,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting &&
                !snap.hasData) {
              return const Center(
                key: ValueKey('party-detail-loading'),
                child: CircularProgressIndicator(),
              );
            }
            if (snap.hasError) {
              return Padding(
                padding: const EdgeInsets.all(20),
                child: PartyNotice(
                  message: '파티를 불러오지 못했어요.',
                  retryKey: const ValueKey('party-detail-retry'),
                  onRetry: _retryParty,
                ),
              );
            }

            final party = snap.data;
            if (party == null) {
              return const Padding(
                padding: EdgeInsets.all(20),
                child: PartyNotice(
                  key: ValueKey('party-detail-unavailable'),
                  message: '이 파티는 더 이상 볼 수 없어요.',
                ),
              );
            }

            final isHost = uid != null && party.hostUid == uid;
            return ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
              children: [
                _PartyHeader(party: party),
                const SizedBox(height: 14),
                const PartySafetyNotice(),
                const SizedBox(height: 16),
                if (isHost)
                  _HostActions(
                    party: party,
                    pendingRequestsStream: _pendingRequestsStream,
                    busy: _busy,
                    onReview: _review,
                    onCancel: _cancelParty,
                    onOpenGroupChat: _openGroupChat,
                  )
                else
                  _ParticipantActions(
                    party: party,
                    busy: _busy,
                    messageController: _messageController,
                    myRequestStream: _myRequestStream,
                    isMemberStream: _isMemberStream,
                    onRequest: _requestJoin,
                    onWithdraw: _withdraw,
                    onLeave: _leave,
                    onReport: () => _report(party),
                    onOpenGroupChat: _openGroupChat,
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _PartyHeader extends StatelessWidget {
  final CommunityParty party;

  const _PartyHeader({required this.party});

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('party-detail-body'),
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CommunityAuthorHeader(
            author: party.host,
            createdAt: party.createdAt,
            trailing: PartyStatusBadge(party: party),
          ),
          const SizedBox(height: 12),
          Text(
            party.title,
            key: const ValueKey('party-detail-title'),
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.bold,
              height: 1.35,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              PartyMetaChip(
                icon: Icons.schedule_rounded,
                label: formatPartyStartAt(party.startAt),
                emphasized: true,
              ),
              PartyMetaChip(
                icon: Icons.place_outlined,
                label: party.areaLabel,
              ),
              PartyMetaChip(
                icon: Icons.local_activity_outlined,
                label: party.categoryLabel,
              ),
              PartyMetaChip(
                icon: Icons.group_outlined,
                label: formatPartyParticipants(party),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            party.description,
            key: const ValueKey('party-detail-description'),
            style: const TextStyle(
              fontSize: 14.5,
              height: 1.6,
              color: AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

/// 호스트 전용 영역 — 대기 중 요청 승인·거절, 파티 취소.
class _HostActions extends StatelessWidget {
  final CommunityParty party;
  final Stream<List<CommunityPartyJoinRequest>> pendingRequestsStream;
  final bool busy;
  final Future<void> Function(String requesterUid, {required bool approve})
  onReview;
  final VoidCallback onCancel;
  final VoidCallback onOpenGroupChat;

  const _HostActions({
    required this.party,
    required this.pendingRequestsStream,
    required this.busy,
    required this.onReview,
    required this.onCancel,
    required this.onOpenGroupChat,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 호스트는 members/{hostUid} 문서를 갖고 있으므로 항상 입장할 수 있다.
        FilledButton.icon(
          key: const ValueKey('party-open-group-chat'),
          onPressed: busy ? null : onOpenGroupChat,
          icon: const Icon(Icons.groups_outlined, size: 18),
          label: const Text('그룹 채팅 들어가기'),
        ),
        const SizedBox(height: 16),
        const Text(
          '참여 요청',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 8),
        StreamBuilder<List<CommunityPartyJoinRequest>>(
          stream: pendingRequestsStream,
          builder: (context, snap) {
            if (snap.hasError) {
              return const PartyNotice(
                key: ValueKey('party-requests-error'),
                message: '참여 요청을 불러오지 못했어요.',
              );
            }
            final requests =
                snap.data ?? const <CommunityPartyJoinRequest>[];
            if (requests.isEmpty) {
              return const PartyNotice(
                key: ValueKey('party-requests-empty'),
                message: '아직 참여 요청이 없어요.',
              );
            }
            return Column(
              key: const ValueKey('party-requests-list'),
              children: [
                for (final request in requests) ...[
                  _JoinRequestTile(
                    request: request,
                    busy: busy,
                    onApprove: () =>
                        onReview(request.requesterUid, approve: true),
                    onReject: () =>
                        onReview(request.requesterUid, approve: false),
                  ),
                  const SizedBox(height: 8),
                ],
              ],
            );
          },
        ),
        const SizedBox(height: 12),
        OutlinedButton(
          key: const ValueKey('party-cancel-button'),
          style: OutlinedButton.styleFrom(foregroundColor: AppColors.error),
          onPressed: busy ? null : onCancel,
          child: const Text('파티 취소하기'),
        ),
      ],
    );
  }
}

class _JoinRequestTile extends StatelessWidget {
  final CommunityPartyJoinRequest request;
  final bool busy;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  const _JoinRequestTile({
    required this.request,
    required this.busy,
    required this.onApprove,
    required this.onReject,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      // 요청자 UID는 key에도 화면에도 넣지 않는다(공개 이름만 표시).
      key: ValueKey('party-request-${request.requester.displayName}'),
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.button),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CommunityAuthorHeader(
            author: request.requester,
            createdAt: request.createdAt,
            avatarRadius: 13,
          ),
          if (request.message.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              request.message,
              style: const TextStyle(
                fontSize: 13.5,
                height: 1.5,
                color: AppColors.textPrimary,
              ),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: busy ? null : onReject,
                  child: const Text('거절'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  onPressed: busy ? null : onApprove,
                  child: const Text('승인'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 일반 사용자 영역 — 참여 요청/취소, 나가기, 신고.
class _ParticipantActions extends StatelessWidget {
  final CommunityParty party;
  final bool busy;
  final TextEditingController messageController;
  final Stream<CommunityPartyJoinRequest?> myRequestStream;
  final Stream<bool> isMemberStream;
  final VoidCallback onRequest;
  final VoidCallback onWithdraw;
  final VoidCallback onLeave;
  final VoidCallback onReport;
  final VoidCallback onOpenGroupChat;

  const _ParticipantActions({
    required this.party,
    required this.busy,
    required this.messageController,
    required this.myRequestStream,
    required this.isMemberStream,
    required this.onRequest,
    required this.onWithdraw,
    required this.onLeave,
    required this.onReport,
    required this.onOpenGroupChat,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<bool>(
      stream: isMemberStream,
      builder: (context, memberSnap) {
        final isMember = memberSnap.data ?? false;
        return StreamBuilder<CommunityPartyJoinRequest?>(
          stream: myRequestStream,
          builder: (context, requestSnap) {
            final pending = requestSnap.data?.isPending ?? false;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (isMember) ...[
                  _StateBanner(
                    stateKey: 'party-state-joined',
                    label: '참여 중',
                    description: '호스트가 승인한 파티예요.',
                  ),
                  FilledButton.icon(
                    key: const ValueKey('party-open-group-chat'),
                    onPressed: busy ? null : onOpenGroupChat,
                    icon: const Icon(Icons.groups_outlined, size: 18),
                    label: const Text('그룹 채팅 들어가기'),
                  ),
                  const SizedBox(height: 4),
                ] else if (pending)
                  // 승인 전에는 대화에 들어갈 수 없다는 것을 분명히 알린다.
                  _StateBanner(
                    stateKey: 'party-state-pending',
                    label: '승인 대기',
                    description: '참여 승인 후 그룹 채팅을 이용할 수 있어요.',
                  ),
                if (!isMember && !pending) ...[
                  if (party.acceptsJoinRequests) ...[
                    TextField(
                      key: const ValueKey('party-join-message'),
                      controller: messageController,
                      maxLength: CommunityPartyOptions.joinMessageMaxLength,
                      minLines: 2,
                      maxLines: 4,
                      enabled: !busy,
                      decoration: const InputDecoration(
                        hintText: '간단한 인사를 남겨보세요. (선택)',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 4),
                    FilledButton(
                      key: const ValueKey('party-join-button'),
                      onPressed: busy ? null : onRequest,
                      child: const Text('참여 요청 보내기'),
                    ),
                  ] else
                    const PartyNotice(
                      key: ValueKey('party-join-closed'),
                      message: '지금은 이 파티에 참여 요청을 보낼 수 없어요.',
                    ),
                ],
                if (pending) ...[
                  const SizedBox(height: 10),
                  OutlinedButton(
                    key: const ValueKey('party-withdraw-button'),
                    onPressed: busy ? null : onWithdraw,
                    child: const Text('참여 요청 취소'),
                  ),
                ],
                if (isMember) ...[
                  const SizedBox(height: 10),
                  OutlinedButton(
                    key: const ValueKey('party-leave-button'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.error,
                    ),
                    onPressed: busy ? null : onLeave,
                    child: const Text('파티 나가기'),
                  ),
                ],
                const SizedBox(height: 10),
                TextButton(
                  key: const ValueKey('party-report-button'),
                  onPressed: busy ? null : onReport,
                  child: const Text('이 파티 신고하기'),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _StateBanner extends StatelessWidget {
  final String stateKey;
  final String label;
  final String description;

  const _StateBanner({
    required this.stateKey,
    required this.label,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      key: ValueKey(stateKey),
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.mintSoft,
        borderRadius: BorderRadius.circular(AppRadius.button),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
              color: AppColors.mintDeep,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            description,
            style: const TextStyle(
              fontSize: 12.5,
              height: 1.4,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}
