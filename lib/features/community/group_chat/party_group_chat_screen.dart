import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../models/community/community_party.dart';
import '../../../services/auth/auth_service.dart';
import '../../../services/community/community_service.dart';
import '../../../services/community/party_service.dart';
import '../../../services/privacy/contact_avoidance_service.dart';
import '../../../services/safety/safety_service.dart';
import '../community_audience_filter.dart';
import '../community_report_sheet.dart';
import '../lounge/lounge_widgets.dart';
import '../party/party_widgets.dart';

/// 파티 그룹 채팅(Phase 4-5).
///
/// 승인된 active 멤버만 들어올 수 있다. 자격 판정의 source of truth는 서버와
/// Rules이고, 이 화면은 그 결과를 표시만 한다 — 파티가 취소되거나 멤버에서
/// 빠지면 스트림이 끊기며 즉시 볼 수 없는 상태로 바뀐다.
///
/// **UID·전화번호·기관명·정확 위치·membership 내부 정보는 표시하지 않는다.**
class PartyGroupChatScreen extends StatefulWidget {
  final String partyId;
  final AuthService authService;
  final PartyService partyService;
  final SafetyService safetyService;
  final ContactAvoidanceService contactAvoidanceService;

  const PartyGroupChatScreen({
    super.key,
    required this.partyId,
    required this.authService,
    required this.partyService,
    required this.safetyService,
    required this.contactAvoidanceService,
  });

  @override
  State<PartyGroupChatScreen> createState() => _PartyGroupChatScreenState();
}

class _PartyGroupChatScreenState extends State<PartyGroupChatScreen> {
  /// build 안에서 만들면 rebuild마다 재구독된다.
  late final Stream<CommunityParty?> _partyStream = widget.partyService
      .watchParty(widget.partyId);
  late final Stream<List<PartyGroupMessage>> _messagesStream = widget
      .partyService
      .watchGroupMessages(partyId: widget.partyId);

  late final CommunityAudienceFilter _audience = CommunityAudienceFilter(
    safetyService: widget.safetyService,
    contactAvoidanceService: widget.contactAvoidanceService,
  );

  final _messageController = TextEditingController();
  final _scrollController = ScrollController();

  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _audience.start(
      uid: _currentUid,
      onChanged: () {
        if (mounted) setState(() {});
      },
    );
    _messageController.addListener(_onMessageChanged);
  }

  @override
  void dispose() {
    _messageController.removeListener(_onMessageChanged);
    _messageController.dispose();
    _scrollController.dispose();
    _audience.dispose();
    super.dispose();
  }

  void _onMessageChanged() => setState(() {});

  String? get _currentUid => widget.authService.currentUser?.uid;

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // ── 전송 ────────────────────────────────────────────────────────────────

  Future<void> _send() async {
    if (_sending) return;
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    setState(() => _sending = true);
    try {
      await _sendOnce(text, acknowledged: false);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// 서버가 연락처 공유 확인을 요구하면 경고를 보여주고 한 번만 재시도한다.
  Future<void> _sendOnce(String text, {required bool acknowledged}) async {
    try {
      await widget.partyService.sendGroupMessage(
        partyId: widget.partyId,
        text: text,
        safetyAcknowledged: acknowledged,
      );
      if (!mounted) return;
      _messageController.clear();
      _scrollToBottom();
    } on PartyContactAckRequired catch (e) {
      if (acknowledged || !mounted) {
        // 확인 후에도 같은 응답이면 더 재시도하지 않는다.
        _showMessage(CommunityService.genericErrorMessage);
        return;
      }
      final proceed = await _confirmContactShare(e.message);
      if (proceed != true || !mounted) return;
      await _sendOnce(text, acknowledged: true);
    } on CommunityActionError catch (e) {
      _showMessage(e.message);
    } catch (_) {
      _showMessage(CommunityService.genericErrorMessage);
    }
  }

  Future<bool?> _confirmContactShare(String message) {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('party-chat-contact-warning'),
        title: const Text('보내기 전에 확인해주세요'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('다시 쓸게요'),
          ),
          TextButton(
            key: const ValueKey('party-chat-contact-continue'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('그대로 보내기'),
          ),
        ],
      ),
    );
  }

  void _scrollToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
  }

  // ── 삭제·신고 ───────────────────────────────────────────────────────────

  Future<void> _deleteMessage(PartyGroupMessage message) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('메시지를 삭제할까요?'),
        content: const Text('삭제하면 다른 참여자에게 더 이상 보이지 않아요.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('삭제하기'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await widget.partyService.deleteGroupMessage(
        partyId: widget.partyId,
        messageId: message.id,
      );
      _showMessage('메시지를 삭제했어요.');
    } on CommunityActionError catch (e) {
      _showMessage(e.message);
    } catch (_) {
      _showMessage(CommunityService.genericErrorMessage);
    }
  }

  Future<void> _reportMessage(PartyGroupMessage message) async {
    final uid = _currentUid;
    if (uid == null) return;
    final outcome = await showPartyMessageReportSheet(
      context,
      partyService: widget.partyService,
      safetyService: widget.safetyService,
      currentUid: uid,
      partyId: widget.partyId,
      messageId: message.id,
      reportedUid: message.senderUid,
    );
    if (outcome == null || !mounted) return;
    if (outcome.blocked) {
      // 차단 즉시 해당 작성자의 메시지를 숨긴다.
      await _audience.refreshBlocked(
        uid: uid,
        onChanged: () {
          if (mounted) setState(() {});
        },
      );
    }
    _showMessage(outcome.blocked ? '신고하고 차단했어요.' : '신고를 접수했어요.');
  }

  // ── build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const ValueKey('party-group-chat-screen'),
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: StreamBuilder<CommunityParty?>(
          stream: _partyStream,
          builder: (context, partySnap) {
            final party = partySnap.hasError ? null : partySnap.data;
            final loading =
                partySnap.connectionState == ConnectionState.waiting &&
                !partySnap.hasData;

            return Column(
              children: [
                _ChatAppBar(title: party?.title ?? '파티 대화'),
                if (loading)
                  const Expanded(
                    child: Center(
                      key: ValueKey('party-chat-loading'),
                      child: CircularProgressIndicator(),
                    ),
                  )
                else if (party == null)
                  // 파티가 취소·삭제되면 대화도 즉시 닫힌다.
                  const Expanded(
                    child: Padding(
                      padding: EdgeInsets.all(20),
                      child: PartyNotice(
                        key: ValueKey('party-chat-unavailable'),
                        message: '이 파티 대화는 더 이상 볼 수 없어요.',
                      ),
                    ),
                  )
                else ...[
                  Expanded(child: _buildMessages()),
                  _MessageInput(
                    controller: _messageController,
                    sending: _sending,
                    onSubmit: _send,
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildMessages() {
    final uid = _currentUid;
    return StreamBuilder<List<PartyGroupMessage>>(
      stream: _messagesStream,
      builder: (context, snap) {
        if (snap.hasError) {
          // 멤버가 아니거나 파티가 닫히면 Rules가 스트림을 끊는다.
          return const Padding(
            padding: EdgeInsets.all(20),
            child: PartyNotice(
              key: ValueKey('party-chat-error'),
              message: '대화를 불러오지 못했어요.',
            ),
          );
        }
        if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
          return const Center(
            key: ValueKey('party-chat-messages-loading'),
            child: CircularProgressIndicator(),
          );
        }

        // 차단·지인 피하기 작성자의 메시지는 표시만 건너뛴다. 본인 것은 유지.
        final messages = (snap.data ?? const <PartyGroupMessage>[])
            .where(
              (message) => !_audience.isExcluded(
                authorUid: message.senderUid,
                selfUid: uid,
              ),
            )
            .toList();

        if (messages.isEmpty) {
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
            children: const [
              PartySafetyNotice(),
              SizedBox(height: 12),
              PartyNotice(
                key: ValueKey('party-chat-empty'),
                message: '아직 대화가 없어요. 첫 인사를 건네보세요.',
              ),
            ],
          );
        }

        return ListView.separated(
          key: const ValueKey('party-chat-message-list'),
          controller: _scrollController,
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
          itemCount: messages.length + 1,
          separatorBuilder: (_, _) => const SizedBox(height: 10),
          itemBuilder: (context, index) {
            if (index == 0) return const PartySafetyNotice();
            final message = messages[index - 1];
            return _MessageTile(
              message: message,
              isMine: uid != null && message.senderUid == uid,
              onDelete: () => _deleteMessage(message),
              onReport: () => _reportMessage(message),
            );
          },
        );
      },
    );
  }
}

class _ChatAppBar extends StatelessWidget {
  final String title;

  const _ChatAppBar({required this.title});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(4, 6, 16, 6),
      color: AppColors.background,
      child: Row(
        children: [
          IconButton(
            key: const ValueKey('party-chat-back'),
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.arrow_back_rounded),
          ),
          Expanded(
            child: Text(
              title,
              key: const ValueKey('party-chat-title'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: AppColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MessageTile extends StatelessWidget {
  final PartyGroupMessage message;
  final bool isMine;
  final VoidCallback onDelete;
  final VoidCallback onReport;

  const _MessageTile({
    required this.message,
    required this.isMine,
    required this.onDelete,
    required this.onReport,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      key: ValueKey('party-chat-message-${message.id}'),
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isMine ? AppColors.mintSoft : AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.button),
        border: Border.all(
          color: isMine ? AppColors.mintSoft : AppColors.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CommunityAuthorHeader(
            author: message.sender,
            createdAt: message.createdAt,
            avatarRadius: 13,
            trailing: SizedBox(
              width: 32,
              height: 32,
              child: PopupMenuButton<String>(
                key: ValueKey('party-chat-menu-${message.id}'),
                padding: EdgeInsets.zero,
                icon: const Icon(
                  Icons.more_horiz_rounded,
                  size: 16,
                  color: AppColors.textSecondary,
                ),
                onSelected: (value) {
                  if (value == 'delete') {
                    onDelete();
                  } else if (value == 'report') {
                    onReport();
                  }
                },
                itemBuilder: (_) => [
                  if (isMine)
                    const PopupMenuItem(value: 'delete', child: Text('삭제하기'))
                  else
                    const PopupMenuItem(value: 'report', child: Text('신고하기')),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            message.text,
            style: const TextStyle(
              fontSize: 13.5,
              height: 1.5,
              color: AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

/// 전송 버튼의 고정 크기.
///
/// 전역 filledButtonTheme의 minimumSize가 Size.fromHeight(48) — 즉 폭이
/// double.infinity다. Row의 non-flex 자식은 unbounded width 제약을 받으므로
/// 그대로 두면 "BoxConstraints forces an infinite width" assertion이 난다
/// (Phase 4-3A에서 라운지·피드 상세가 이 문제로 깨졌다).
const double _sendButtonWidth = 72;
const double _sendButtonHeight = 48;

class _MessageInput extends StatelessWidget {
  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSubmit;

  const _MessageInput({
    required this.controller,
    required this.sending,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    final canSubmit = controller.text.trim().isNotEmpty && !sending;
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 8,
        bottom: 8 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              key: const ValueKey('party-chat-input'),
              controller: controller,
              maxLength: PartyGroupMessage.textMaxLength,
              minLines: 1,
              maxLines: 4,
              enabled: !sending,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) {
                if (canSubmit) onSubmit();
              },
              decoration: const InputDecoration(
                hintText: '메시지를 입력하세요',
                counterText: '',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: _sendButtonWidth,
            height: _sendButtonHeight,
            child: FilledButton(
              key: const ValueKey('party-chat-send'),
              style: FilledButton.styleFrom(
                minimumSize: Size.zero,
                fixedSize: const Size(_sendButtonWidth, _sendButtonHeight),
                maximumSize: const Size(_sendButtonWidth, _sendButtonHeight),
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
              onPressed: canSubmit ? onSubmit : null,
              child: sending
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text('전송'),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
