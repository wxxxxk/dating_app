import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../models/community/community_author_snapshot.dart';
import '../../../models/community/community_party.dart';
import '../../../services/auth/auth_service.dart';
import '../../../services/community/community_service.dart';
import '../../../services/community/party_service.dart';
import '../../../services/privacy/contact_avoidance_service.dart';
import '../../../services/safety/safety_service.dart';
import '../community_audience_filter.dart';
import '../community_report_sheet.dart';
import '../party/party_widgets.dart'
    show formatPartyStartAt, formatPartyParticipants;

/// 파티 그룹 채팅(Phase 4-5, UX 정리 Phase 4-7).
///
/// 승인된 active 멤버만 들어올 수 있다. 자격 판정의 source of truth는 서버와
/// Rules이고, 이 화면은 그 결과를 표시만 한다 — 파티가 취소되거나 멤버에서
/// 빠지면 스트림이 끊기며 즉시 볼 수 없는 상태로 바뀐다.
///
/// 표시는 매칭 채팅(`features/chat/chat_screen.dart`)과 같은 대화방 문법을
/// 따른다 — 좌우 말풍선, 연속 메시지 그룹화, 날짜 구분선. 여러 명이 말하므로
/// **상대 말풍선에만** 프로필·이름을 붙인다(그룹 첫 메시지 한 번).
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
  bool _safetyNoticeVisible = true;

  /// 자동 스크롤 판단용. 목록이 실제로 바뀌었을 때만 스크롤한다
  /// (rebuild마다 끌어내리면 과거 메시지를 읽을 수 없다).
  int _renderedCount = 0;
  String? _renderedLastId;
  bool _didInitialScroll = false;

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

  // ── 스크롤 ──────────────────────────────────────────────────────────────

  /// 사용자가 하단 근처를 보고 있는지. 아직 레이아웃 전이면 따라가는 쪽으로 본다.
  bool get _isNearBottom {
    if (!_scrollController.hasClients) return true;
    final position = _scrollController.position;
    return position.maxScrollExtent - position.pixels <= 120;
  }

  void _scrollToBottom({bool animated = true}) {
    // 새 프레임이 그려진 뒤(리스트 길이 갱신 후) 스크롤해야 maxScrollExtent가 정확하다.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final target = _scrollController.position.maxScrollExtent;
      if (!animated) {
        _scrollController.jumpTo(target);
        return;
      }
      _scrollController.animateTo(
        target,
        duration: AppDurations.base,
        curve: AppCurves.standard,
      );
    });
  }

  /// 목록이 바뀐 프레임에서만 하단 추적 여부를 정한다.
  ///
  /// - 최초 로드: 최신 메시지 위치로 바로 이동
  /// - 이후: 사용자가 하단 근처일 때만 따라감(과거를 읽는 중이면 두지 않는다)
  void _syncAutoScroll(List<PartyGroupMessage> messages) {
    final lastId = messages.isEmpty ? null : messages.last.id;
    final changed =
        messages.length != _renderedCount || lastId != _renderedLastId;
    if (!changed) return;

    _renderedCount = messages.length;
    _renderedLastId = lastId;
    if (messages.isEmpty) return;

    final isInitial = !_didInitialScroll;
    if (!isInitial && !_isNearBottom) return;

    _didInitialScroll = true;
    _scrollToBottom(animated: !isInitial);
  }

  // ── 삭제·신고 ───────────────────────────────────────────────────────────

  /// 길게 누르면 뜨는 메뉴. 본인 메시지는 삭제, 상대 메시지는 신고만 노출한다
  /// (항상 보이는 점 세 개 버튼은 대화방 느낌을 해쳐서 없앴다).
  Future<void> _openMessageActions(PartyGroupMessage message, bool isMine) {
    return showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          key: ValueKey('party-chat-actions-${message.id}'),
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isMine)
              ListTile(
                leading: const Icon(Icons.delete_outline_rounded),
                title: const Text('삭제하기'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _deleteMessage(message);
                },
              )
            else
              ListTile(
                leading: const Icon(Icons.flag_outlined),
                title: const Text('신고하기'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _reportMessage(message);
                },
              ),
          ],
        ),
      ),
    );
  }

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
      backgroundColor: AppColors.warmCanvas,
      body: SafeArea(
        child: StreamBuilder<CommunityParty?>(
          stream: _partyStream,
          builder: (context, partySnap) {
            final party = partySnap.hasError ? null : partySnap.data;
            final loading =
                partySnap.connectionState == ConnectionState.waiting &&
                !partySnap.hasData;

            return DecoratedBox(
              // 평평한 단색 대신 상단에만 아주 옅은 민트 wash를 깐다.
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    AppColors.surfaceMintSoft,
                    AppColors.warmCanvas,
                    AppColors.warmCanvas,
                  ],
                  stops: [0, 0.28, 1],
                ),
              ),
              child: Column(
                children: [
                  _ChatAppBar(
                    title: party?.title ?? '파티 대화',
                    subtitle: _subtitleOf(party),
                  ),
                  if (loading)
                    const Expanded(
                      child: _ChatMessagesSkeleton(
                        key: ValueKey('party-chat-loading'),
                      ),
                    )
                  else if (party == null)
                    // 파티가 취소·삭제되면 대화도 즉시 닫힌다.
                    const Expanded(
                      child: _ChatNotice(
                        noticeKey: ValueKey('party-chat-unavailable'),
                        message: '이 파티 대화는 더 이상 볼 수 없어요.',
                      ),
                    )
                  else ...[
                    _PartyContextRibbon(party: party),
                    if (_safetyNoticeVisible)
                      _SafetyBanner(
                        onDismiss: () =>
                            setState(() => _safetyNoticeVisible = false),
                      ),
                    Expanded(child: _buildMessages()),
                    _MessageInput(
                      controller: _messageController,
                      sending: _sending,
                      onSubmit: _send,
                    ),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  /// 참여 인원만 보조 문구로 쓴다. 멤버 명단·상태는 노출하지 않는다.
  String _subtitleOf(CommunityParty? party) {
    if (party == null) return '파티 그룹 채팅';
    return '참여자 ${party.participantCount}명';
  }

  Widget _buildMessages() {
    final uid = _currentUid;
    return StreamBuilder<List<PartyGroupMessage>>(
      stream: _messagesStream,
      builder: (context, snap) {
        if (snap.hasError) {
          // 멤버가 아니거나 파티가 닫히면 Rules가 스트림을 끊는다.
          return const _ChatNotice(
            noticeKey: ValueKey('party-chat-error'),
            message: '대화를 불러오지 못했어요.',
            danger: true,
          );
        }
        if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
          return const _ChatMessagesSkeleton(
            key: ValueKey('party-chat-messages-loading'),
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

        _syncAutoScroll(messages);

        if (messages.isEmpty) return const _EmptyConversation();

        return ListView.builder(
          key: const ValueKey('party-chat-message-list'),
          controller: _scrollController,
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
          itemCount: messages.length,
          itemBuilder: (context, index) {
            final message = messages[index];
            final isMine = uid != null && message.senderUid == uid;
            final position = _bubblePosition(messages, index);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_shouldShowDateDivider(messages, index))
                  _DateDivider(date: message.createdAt!),
                _MessageRow(
                  message: message,
                  isMine: isMine,
                  position: position,
                  showTime: _shouldShowTime(messages, index),
                  onLongPress: () => _openMessageActions(message, isMine),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // ── 그룹화 규칙 (매칭 채팅과 동일 계약) ──────────────────────────────────

  bool _shouldShowDateDivider(List<PartyGroupMessage> messages, int index) {
    final current = messages[index].createdAt;
    if (current == null) return false;
    if (index == 0) return true;

    final previous = messages[index - 1].createdAt;
    if (previous == null) return true;
    return !_isSameDate(current, previous);
  }

  bool _isSameDate(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  _BubblePosition _bubblePosition(List<PartyGroupMessage> messages, int index) {
    final joinsPrevious = _isGroupedWith(messages, index - 1, index);
    final joinsNext = _isGroupedWith(messages, index, index + 1);
    if (joinsPrevious && joinsNext) return _BubblePosition.middle;
    if (joinsNext) return _BubblePosition.top;
    if (joinsPrevious) return _BubblePosition.bottom;
    return _BubblePosition.single;
  }

  /// 그룹의 마지막 메시지에만 시간을 붙인다.
  bool _shouldShowTime(List<PartyGroupMessage> messages, int index) {
    if (messages[index].createdAt == null) return true;
    return !_isGroupedWith(messages, index, index + 1);
  }

  /// 같은 사람이 같은 날 5분 이내에 이어 보낸 메시지만 한 그룹으로 본다.
  bool _isGroupedWith(
    List<PartyGroupMessage> messages,
    int firstIndex,
    int secondIndex,
  ) {
    if (firstIndex < 0 || secondIndex >= messages.length) return false;
    final first = messages[firstIndex];
    final second = messages[secondIndex];
    if (first.senderUid != second.senderUid) return false;
    final firstTime = first.createdAt;
    final secondTime = second.createdAt;
    if (firstTime == null || secondTime == null) return false;
    if (!_isSameDate(firstTime, secondTime)) return false;
    return secondTime.difference(firstTime).abs() <= const Duration(minutes: 5);
  }
}

// ── AppBar ────────────────────────────────────────────────────────────────

class _ChatAppBar extends StatelessWidget {
  final String title;
  final String subtitle;

  const _ChatAppBar({required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(4, 6, AppSpacing.lg, 10),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.surfaceMintSoft, AppColors.surfacePrimary],
        ),
        border: Border(bottom: BorderSide(color: AppColors.borderSubtle)),
      ),
      child: Row(
        children: [
          IconButton(
            key: const ValueKey('party-chat-back'),
            onPressed: () => Navigator.of(context).maybePop(),
            color: AppColors.textStrong,
            icon: const Icon(Icons.arrow_back_rounded),
          ),
          const ExcludeSemantics(child: _GroupVisual()),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  key: const ValueKey('party-chat-title'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.cardTitle.copyWith(fontSize: 17),
                ),
                const SizedBox(height: 1),
                Text(
                  subtitle,
                  key: const ValueKey('party-chat-subtitle'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.caption,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 헤더 좌측 그룹 정체성 표식. 실제 참여자 사진을 특정해 노출하지 않고,
/// "여러 사람이 모인 대화"라는 의미만 겹친 원으로 암시한다.
class _GroupVisual extends StatelessWidget {
  const _GroupVisual();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 46,
      height: 34,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            top: 3,
            child: _ring(AppColors.expressiveAccentSoft),
          ),
          Positioned(left: 14, top: 3, child: _ring(AppColors.surfaceMintSoft)),
          Positioned(
            left: 7,
            top: 0,
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: AppColors.brandPrimaryStrong,
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.surfacePrimary, width: 2),
              ),
              child: const Icon(
                Icons.groups_rounded,
                size: 18,
                color: AppColors.onBrandPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _ring(Color color) {
    return Container(
      width: 26,
      height: 26,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: AppColors.surfacePrimary, width: 2),
      ),
    );
  }
}

// ── 파티 컨텍스트 리본 ────────────────────────────────────────────────────

/// AppBar 아래 한 번 표시하는 작은 파티 맥락 띠. 실제 일정·참여 인원만 쓰고,
/// 새 navigation이나 정확 주소는 만들지 않는다.
class _PartyContextRibbon extends StatelessWidget {
  final CommunityParty party;

  const _PartyContextRibbon({required this.party});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.xs,
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: AppColors.surfaceMintSoft,
        borderRadius: BorderRadius.circular(AppRadius.small),
        border: Border.all(
          color: AppColors.brandPrimary.withValues(alpha: 0.18),
        ),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.event_rounded,
            size: 15,
            color: AppColors.brandPrimaryStrong,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              formatPartyStartAt(party.startAt),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.caption.copyWith(
                color: AppColors.brandPrimaryStrong,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          const Icon(
            Icons.group_rounded,
            size: 15,
            color: AppColors.brandPrimaryStrong,
          ),
          const SizedBox(width: 6),
          Text(
            formatPartyParticipants(party),
            style: AppTextStyles.caption.copyWith(
              color: AppColors.brandPrimaryStrong,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

// ── 안전 안내 ─────────────────────────────────────────────────────────────

/// AppBar 아래 얇은 배너. 대화 첫 화면을 아래로 밀지 않도록 한 줄로 줄이고
/// 닫을 수 있게 했다(안전 detector·경고 자체는 서버 쪽 그대로다).
class _SafetyBanner extends StatelessWidget {
  final VoidCallback onDismiss;

  const _SafetyBanner({required this.onDismiss});

  static const String message = '연락처·금전 정보 공유에 주의해주세요.';

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('party-chat-safety-banner'),
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 8, 8, 8),
      decoration: const BoxDecoration(
        color: AppColors.surfaceSecondary,
        border: Border(bottom: BorderSide(color: AppColors.borderSubtle)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.shield_outlined,
            size: 15,
            color: AppColors.textMuted,
          ),
          const SizedBox(width: 8),
          const Expanded(child: Text(message, style: AppTextStyles.caption)),
          SizedBox(
            width: 32,
            height: 32,
            child: IconButton(
              key: const ValueKey('party-chat-safety-dismiss'),
              padding: EdgeInsets.zero,
              iconSize: 16,
              onPressed: onDismiss,
              icon: const Icon(Icons.close_rounded, color: AppColors.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

// ── 빈 대화방 ─────────────────────────────────────────────────────────────

class _EmptyConversation extends StatelessWidget {
  const _EmptyConversation();

  @override
  Widget build(BuildContext context) {
    return Center(
      key: const ValueKey('party-chat-empty'),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ExcludeSemantics(
              child: SizedBox(
                width: 84,
                height: 48,
                child: _ChatBubblesMotif(),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              '아직 대화가 없어요. 첫 인사를 건네보세요.',
              textAlign: TextAlign.center,
              style: AppTextStyles.bodySecondary,
            ),
          ],
        ),
      ),
    );
  }
}

/// 겹쳐 놓인 두 말풍선. 가짜 예시 메시지·사용자를 만들지 않는다.
class _ChatBubblesMotif extends StatelessWidget {
  const _ChatBubblesMotif();

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned(
          left: 0,
          bottom: 0,
          child: _bubble(
            AppColors.surfaceMintSoft,
            AppColors.brandPrimary.withValues(alpha: 0.3),
          ),
        ),
        Positioned(
          right: 0,
          top: 0,
          child: _bubble(
            AppColors.expressiveAccentSoft,
            AppColors.expressiveAccent.withValues(alpha: 0.3),
          ),
        ),
      ],
    );
  }

  Widget _bubble(Color fill, Color border) {
    return Container(
      width: 48,
      height: 30,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(AppRadius.small),
        border: Border.all(color: border),
      ),
    );
  }
}

/// 대화 로딩 skeleton. 좌우 말풍선 자리를 몇 개 두고 작은 스피너 하나만 둔다.
class _ChatMessagesSkeleton extends StatelessWidget {
  const _ChatMessagesSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    // 좌(수신)·우(발신) 폭을 번갈아 배치해 실제 대화 흐름을 암시한다.
    const rows = <(bool, double)>[
      (false, 180),
      (false, 120),
      (true, 150),
      (false, 200),
      (true, 96),
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.md,
      ),
      physics: const NeverScrollableScrollPhysics(),
      children: [
        for (final (mine, width) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Align(
              alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                width: width,
                height: 38,
                decoration: BoxDecoration(
                  color: AppColors.canvasSubtle,
                  borderRadius: BorderRadius.circular(AppRadius.card),
                ),
              ),
            ),
          ),
        const SizedBox(height: AppSpacing.md),
        Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.brandPrimary.withValues(alpha: 0.6),
            ),
          ),
        ),
      ],
    );
  }
}

/// 대화 오류/불가 안내. raw 오류는 노출하지 않고 고정 문구만 보여준다.
/// [danger]일 때만 작은 danger 아이콘을 붙인다(불가 상태는 뉴트럴).
class _ChatNotice extends StatelessWidget {
  final Key? noticeKey;
  final String message;
  final bool danger;

  const _ChatNotice({
    this.noticeKey,
    required this.message,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: noticeKey,
      padding: const EdgeInsets.all(AppSpacing.screenH),
      child: Center(
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(AppSpacing.lg20),
          decoration: BoxDecoration(
            color: AppColors.surfacePrimary,
            borderRadius: BorderRadius.circular(AppRadius.surface),
            border: Border.all(color: AppColors.borderSubtle),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (danger) ...[
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: AppColors.statusDangerSoft,
                    borderRadius: BorderRadius.circular(AppRadius.small),
                  ),
                  child: const Icon(
                    Icons.error_outline_rounded,
                    size: 22,
                    color: AppColors.statusDanger,
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
              ],
              Text(
                message,
                textAlign: TextAlign.center,
                style: AppTextStyles.bodySecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── 날짜 구분선 ───────────────────────────────────────────────────────────

class _DateDivider extends StatelessWidget {
  final DateTime date;

  const _DateDivider({required this.date});

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: ValueKey('party-chat-date-${_dateKey(date)}'),
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Center(
        // 얇은 선 대신 떠 있는 작은 캡슐로 날짜를 표시한다.
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: AppColors.surfaceSecondary,
            borderRadius: BorderRadius.circular(AppRadius.chip),
          ),
          child: Text(
            _formatDate(date),
            style: AppTextStyles.caption.copyWith(
              fontWeight: FontWeight.w700,
              color: AppColors.textMuted,
            ),
          ),
        ),
      ),
    );
  }

  static String _dateKey(DateTime date) {
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '${date.year}$month$day';
  }

  static String _formatDate(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final target = DateTime(date.year, date.month, date.day);
    final diff = today.difference(target).inDays;
    if (diff == 0) return '오늘';
    if (diff == 1) return '어제';
    return '${date.month}월 ${date.day}일';
  }
}

// ── 말풍선 ────────────────────────────────────────────────────────────────

enum _BubblePosition { single, top, middle, bottom }

/// 상대 말풍선 앞 프로필 자리. 그룹 중간·마지막 메시지는 이만큼 들여쓴다.
const double _avatarRadius = 14;
const double _avatarLane = _avatarRadius * 2 + 8;

/// 말풍선 최대 폭 비율(화면의 74%).
const double _bubbleMaxWidthRatio = 0.74;

class _MessageRow extends StatelessWidget {
  final PartyGroupMessage message;
  final bool isMine;
  final _BubblePosition position;
  final bool showTime;
  final VoidCallback onLongPress;

  const _MessageRow({
    required this.message,
    required this.isMine,
    required this.position,
    required this.showTime,
    required this.onLongPress,
  });

  /// 그룹의 첫 메시지에만 프로필·이름을 붙인다.
  bool get _isGroupHead =>
      position == _BubblePosition.single || position == _BubblePosition.top;

  @override
  Widget build(BuildContext context) {
    final maxBubbleWidth =
        MediaQuery.sizeOf(context).width * _bubbleMaxWidthRatio;

    return Semantics(
      label: isMine ? '내 메시지, 길게 눌러 삭제' : '상대 메시지, 길게 눌러 신고',
      child: GestureDetector(
        key: ValueKey('party-chat-message-${message.id}'),
        behavior: HitTestBehavior.opaque,
        onLongPress: onLongPress,
        child: Padding(
          padding: EdgeInsets.only(
            // cluster 시작은 넉넉히 띄우고, 같은 사람이 이어 보낸 메시지는
            // 3~4px로 촘촘히 묶어 하나의 덩어리처럼 보이게 한다.
            top: _isGroupHead ? 14 : 3,
            bottom: showTime ? 4 : 1,
          ),
          child: Column(
            crossAxisAlignment: isMine
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            children: [
              if (!isMine && _isGroupHead) ...[
                _SenderName(author: message.sender),
                const SizedBox(height: 4),
              ],
              Row(
                mainAxisAlignment: isMine
                    ? MainAxisAlignment.end
                    : MainAxisAlignment.start,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (!isMine)
                    _isGroupHead
                        ? _SenderAvatar(author: message.sender)
                        : const SizedBox(width: _avatarLane),
                  if (isMine && showTime) ...[
                    _MessageTime(dateTime: message.createdAt),
                    const SizedBox(width: 6),
                  ],
                  Flexible(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: maxBubbleWidth),
                      child: _Bubble(
                        text: message.text,
                        isMine: isMine,
                        position: position,
                      ),
                    ),
                  ),
                  if (!isMine && showTime) ...[
                    const SizedBox(width: 6),
                    _MessageTime(dateTime: message.createdAt),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SenderAvatar extends StatelessWidget {
  final CommunityAuthorSnapshot author;

  const _SenderAvatar({required this.author});

  @override
  Widget build(BuildContext context) {
    return Container(
      // ring(1.5*2) + 지름(28) + 오른쪽 여백(5) = 36 = _avatarLane.
      // 이어지는 메시지의 들여쓰기(_avatarLane)와 정확히 맞춘다.
      margin: const EdgeInsets.only(right: 5),
      padding: const EdgeInsets.all(1.5),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: AppColors.brandPrimary.withValues(alpha: 0.3),
        ),
      ),
      child: CircleAvatar(
        radius: _avatarRadius,
        backgroundColor: AppColors.surfaceSecondary,
        backgroundImage: author.photoUrl.isNotEmpty
            ? NetworkImage(author.photoUrl)
            : null,
        child: author.photoUrl.isEmpty
            ? const Icon(
                Icons.person_rounded,
                size: _avatarRadius,
                color: AppColors.textMuted,
              )
            : null,
      ),
    );
  }
}

class _SenderName extends StatelessWidget {
  final CommunityAuthorSnapshot author;

  const _SenderName({required this.author});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: _avatarLane),
      child: Text(
        author.displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontFamily: AppFonts.body,
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: AppColors.brandPrimaryStrong,
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final String text;
  final bool isMine;
  final _BubblePosition position;

  const _Bubble({
    required this.text,
    required this.isMine,
    required this.position,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        // 내 버블은 브랜드 민트 2-stop 그라데이션 + 흰 텍스트로 확실히 뜨게,
        // 상대 버블은 웜 캔버스 위의 흰 서피스 + 옅은 보더로 구분한다.
        gradient: isMine
            ? const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [AppColors.brandPrimary, AppColors.brandPrimaryStrong],
              )
            : null,
        color: isMine ? null : AppColors.surfacePrimary,
        borderRadius: _radius,
        border: isMine ? null : Border.all(color: AppColors.borderSubtle),
        boxShadow: [
          BoxShadow(
            color: isMine
                ? AppColors.brandPrimaryStrong.withValues(alpha: 0.18)
                : AppColors.textStrong.withValues(alpha: 0.05),
            blurRadius: isMine ? 12 : 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Text(
        text,
        style: TextStyle(
          fontFamily: AppFonts.body,
          fontSize: 15,
          height: 1.45,
          color: isMine ? AppColors.onBrandPrimary : AppColors.textStrong,
        ),
      ),
    );
  }

  BorderRadius get _radius {
    const large = Radius.circular(AppRadius.card);
    const small = Radius.circular(AppRadius.button);
    if (isMine) {
      switch (position) {
        case _BubblePosition.single:
          return const BorderRadius.all(large);
        case _BubblePosition.top:
          return const BorderRadius.only(
            topLeft: large,
            topRight: large,
            bottomLeft: large,
            bottomRight: small,
          );
        case _BubblePosition.middle:
          return const BorderRadius.only(
            topLeft: large,
            topRight: small,
            bottomLeft: large,
            bottomRight: small,
          );
        case _BubblePosition.bottom:
          return const BorderRadius.only(
            topLeft: large,
            topRight: small,
            bottomLeft: large,
            bottomRight: large,
          );
      }
    }

    switch (position) {
      case _BubblePosition.single:
        return const BorderRadius.all(large);
      case _BubblePosition.top:
        return const BorderRadius.only(
          topLeft: large,
          topRight: large,
          bottomLeft: small,
          bottomRight: large,
        );
      case _BubblePosition.middle:
        return const BorderRadius.only(
          topLeft: small,
          topRight: large,
          bottomLeft: small,
          bottomRight: large,
        );
      case _BubblePosition.bottom:
        return const BorderRadius.only(
          topLeft: small,
          topRight: large,
          bottomLeft: large,
          bottomRight: large,
        );
    }
  }
}

class _MessageTime extends StatelessWidget {
  final DateTime? dateTime;

  const _MessageTime({required this.dateTime});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Text(
        _formatTime(dateTime),
        style: const TextStyle(
          fontFamily: AppFonts.body,
          fontSize: 11,
          color: AppColors.textMuted,
        ),
      ),
    );
  }

  static String _formatTime(DateTime? dateTime) {
    if (dateTime == null) return '전송 중';
    final hour = dateTime.hour.toString().padLeft(2, '0');
    final minute = dateTime.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
}

// ── 입력창 ────────────────────────────────────────────────────────────────

/// 전송 버튼의 고정 크기.
///
/// 전역 filledButtonTheme의 minimumSize가 Size.fromHeight(48) — 즉 폭이
/// double.infinity다. Row의 non-flex 자식은 unbounded width 제약을 받으므로
/// 크기를 명시하지 않으면 "BoxConstraints forces an infinite width"가 난다
/// (Phase 4-3A에서 라운지·피드 상세가 이 문제로 깨졌다). IconButton은 별도
/// theme을 쓰지만, 같은 사고를 막기 위해 크기를 계속 고정해 둔다.
const double _sendButtonSize = 48;

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
    // 화면 하단에 붙은 평평한 바 대신, 좌우 여백을 두고 떠 있는 dock으로 만든다.
    return Padding(
      padding: EdgeInsets.only(
        left: AppSpacing.md,
        right: AppSpacing.md,
        top: AppSpacing.sm,
        bottom: AppSpacing.sm + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        padding: const EdgeInsets.fromLTRB(AppSpacing.md, 6, 6, 6),
        decoration: BoxDecoration(
          color: AppColors.surfacePrimary,
          borderRadius: BorderRadius.circular(AppRadius.hero),
          border: Border.all(color: AppColors.borderSubtle),
          boxShadow: [
            BoxShadow(
              color: AppColors.textStrong.withValues(alpha: 0.07),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
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
                style: AppTextStyles.body.copyWith(fontSize: 15),
                onSubmitted: (_) {
                  if (canSubmit) onSubmit();
                },
                decoration: InputDecoration(
                  hintText: '메시지를 입력하세요',
                  counterText: '',
                  filled: true,
                  fillColor: AppColors.surfaceSecondary,
                  hintStyle: AppTextStyles.bodySecondary.copyWith(
                    fontSize: 15,
                    color: AppColors.textMuted,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadius.heroSoft),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadius.heroSoft),
                    borderSide: BorderSide.none,
                  ),
                  // focus 때만 얇은 민트 보더를 준다(공통 composer 문법).
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadius.heroSoft),
                    borderSide: const BorderSide(
                      color: AppColors.brandPrimaryStrong,
                      width: 1.5,
                    ),
                  ),
                  disabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadius.heroSoft),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            SizedBox(
              width: _sendButtonSize,
              height: _sendButtonSize,
              child: IconButton.filled(
                key: const ValueKey('party-chat-send'),
                onPressed: canSubmit ? onSubmit : null,
                padding: EdgeInsets.zero,
                iconSize: 20,
                style: IconButton.styleFrom(
                  minimumSize: const Size(_sendButtonSize, _sendButtonSize),
                  maximumSize: const Size(_sendButtonSize, _sendButtonSize),
                  backgroundColor: AppColors.mintStrong,
                  foregroundColor: AppColors.onMint,
                  disabledBackgroundColor: AppColors.canvasSubtle,
                  disabledForegroundColor: AppColors.textMuted,
                ),
                icon: sending
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppColors.textMuted,
                        ),
                      )
                    : const Icon(Icons.send_rounded),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
