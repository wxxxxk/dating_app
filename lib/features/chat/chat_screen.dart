import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../models/fortune_model.dart';
import '../../models/message_model.dart';
import '../../models/user_profile.dart';
import '../../services/chat/chat_service.dart';
import '../../services/fortune/fortune_service.dart';
import '../../services/safety/safety_service.dart';
import '../safety/report_sheet.dart';

/// 매칭 상대와의 1:1 실시간 채팅 화면.
///
/// matches/{matchId}/messages 서브컬렉션을 StreamBuilder로 구독해
/// 새 메시지가 도착하면 즉시 리스트에 반영하고 하단으로 자동 스크롤한다.
class ChatScreen extends StatefulWidget {
  final String matchId;
  final UserProfile otherProfile;
  final String currentUid;
  final ChatService chatService;
  final FortuneService fortuneService;
  final SafetyService safetyService;

  const ChatScreen({
    super.key,
    required this.matchId,
    required this.otherProfile,
    required this.currentUid,
    required this.chatService,
    required this.fortuneService,
    required this.safetyService,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  late final Stream<List<MessageModel>> _stream;
  final _textController = TextEditingController();
  final _inputFocusNode = FocusNode();
  final _scrollController = ScrollController();
  Future<List<Icebreaker>>? _icebreakersFuture;
  bool _sending = false;
  bool _checkingBlock = true;
  bool _blocked = false;
  String? _lastReadMarker;
  // 실제 typing 이벤트가 연결되면 이 값만 갱신하면 된다.
  final bool _isOtherTyping = false;

  @override
  void initState() {
    super.initState();
    _stream = widget.chatService.watchMessages(widget.matchId);
    _markMatchRead();
    _checkBlocked();
  }

  @override
  void dispose() {
    _textController.dispose();
    _inputFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _textController.text;
    if (text.trim().isEmpty || _sending || _blocked) return;

    // 입력창은 전송 시도와 동시에 비워 즉각 반응하게 하고, 실패 시 되돌린다.
    _textController.clear();
    setState(() => _sending = true);
    try {
      await widget.chatService.sendMessage(
        matchId: widget.matchId,
        senderId: widget.currentUid,
        text: text,
      );
      _scrollToBottom();
    } catch (e) {
      _textController.text = text;
      _debugLog('[Chat] 메시지 전송 실패 matchId=${widget.matchId} error=$e');
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('메시지를 보내지 못했어요.')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _scrollToBottom() {
    // 새 프레임이 그려진 뒤(리스트 길이 갱신 후) 스크롤해야 maxScrollExtent가 정확하다.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  Future<List<Icebreaker>> _ensureIcebreakers() {
    if (_icebreakersFuture != null) {
      _debugLog('[Icebreakers] 기존 요청 재사용 matchId=${widget.matchId}');
      return _icebreakersFuture!;
    }

    _debugLog('[Icebreakers] 요청 생성 matchId=${widget.matchId}');
    _icebreakersFuture = widget.fortuneService
        .getIcebreakers(widget.matchId)
        .then((items) {
          _debugLog(
            '[Icebreakers] 화면 수신 matchId=${widget.matchId} count=${items.length}',
          );
          return items;
        })
        .catchError((Object e, StackTrace st) {
          // 채팅 핵심 기능을 막지 않기 위해 화면에는 실패를 노출하지 않고 로그만 남긴다.
          _debugLog('[Icebreakers] 화면 숨김 matchId=${widget.matchId} error=$e');
          _debugLog('$st');
          return <Icebreaker>[];
        });
    return _icebreakersFuture!;
  }

  void _fillInput(String message) {
    if (_blocked) return;
    _textController.text = message;
    _textController.selection = TextSelection.collapsed(offset: message.length);
    _inputFocusNode.requestFocus();
  }

  Future<void> _checkBlocked() async {
    try {
      final blocked = await widget.safetyService.isBlockedBetween(
        currentUid: widget.currentUid,
        otherUid: widget.otherProfile.uid,
      );
      if (!mounted) return;
      setState(() {
        _blocked = blocked;
        _checkingBlock = false;
      });
    } catch (e) {
      _debugLog('[Safety] 채팅 차단 상태 확인 실패: $e');
      if (mounted) setState(() => _checkingBlock = false);
    }
  }

  Future<void> _markMatchRead() async {
    try {
      await widget.chatService.markMatchRead(
        matchId: widget.matchId,
        currentUid: widget.currentUid,
      );
    } catch (e) {
      _debugLog('[Chat] 읽음 상태 갱신 실패 matchId=${widget.matchId} error=$e');
    }
  }

  void _markLatestMessagesRead(List<MessageModel> messages) {
    MessageModel? latest;
    for (final message in messages.reversed) {
      if (message.createdAt != null) {
        latest = message;
        break;
      }
    }
    if (latest == null) return;

    final marker = '${latest.id}:${latest.createdAt!.microsecondsSinceEpoch}';
    if (_lastReadMarker == marker) return;
    _lastReadMarker = marker;
    _markMatchRead();
  }

  void _debugLog(String message) {
    if (kDebugMode) {
      debugPrint(message);
    }
  }

  Future<void> _reportUser() async {
    final submission = await showReportSheet(context);
    if (submission == null) return;

    try {
      await widget.safetyService.reportUser(
        reporterUid: widget.currentUid,
        reportedUid: widget.otherProfile.uid,
        reason: submission.reason,
        detail: submission.detail,
      );
      if (submission.blockUser) {
        await widget.safetyService.blockUser(
          currentUid: widget.currentUid,
          blockedUid: widget.otherProfile.uid,
        );
      }
      if (!mounted) return;
      setState(() => _blocked = submission.blockUser || _blocked);
      _showSnack(submission.blockUser ? '신고가 접수되고 차단했어요.' : '신고가 접수되었어요.');
    } catch (e) {
      _debugLog(
        '[Safety] 신고 실패 reportedUid=${widget.otherProfile.uid} error=$e',
      );
      if (mounted) _showSnack('신고에 실패했어요. 잠시 후 다시 시도해주세요.');
    }
  }

  Future<void> _blockUser() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('차단하기'),
        content: const Text('차단하면 서로 디스커버리, 매칭, 채팅에서 볼 수 없어요.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('차단'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await widget.safetyService.blockUser(
        currentUid: widget.currentUid,
        blockedUid: widget.otherProfile.uid,
      );
      if (!mounted) return;
      setState(() => _blocked = true);
      _showSnack('차단했어요.');
    } catch (e) {
      _debugLog(
        '[Safety] 차단 실패 blockedUid=${widget.otherProfile.uid} error=$e',
      );
      if (mounted) _showSnack('차단에 실패했어요. 잠시 후 다시 시도해주세요.');
    }
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final other = widget.otherProfile;
    final photoUrl = other.photoUrls.isNotEmpty ? other.photoUrls[0] : null;

    return Scaffold(
      backgroundColor: AppColors.background,
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        titleSpacing: 0,
        title: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundImage: photoUrl != null ? NetworkImage(photoUrl) : null,
              backgroundColor: AppColors.border,
              child: photoUrl == null
                  ? const Icon(
                      Icons.person,
                      size: 18,
                      color: AppColors.textSecondary,
                    )
                  : null,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                other.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 17,
                ),
              ),
            ),
          ],
        ),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(28),
          child: _ChatStatusBar(label: '온라인'),
        ),
        actions: [
          PopupMenuButton<String>(
            tooltip: '안전 메뉴',
            onSelected: (value) {
              if (value == 'report') _reportUser();
              if (value == 'block') _blockUser();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'report', child: Text('신고하기')),
              PopupMenuItem(value: 'block', child: Text('차단하기')),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: _checkingBlock
            ? const Center(child: CircularProgressIndicator())
            : _blocked
            ? const _BlockedChatState()
            : Column(
                children: [
                  Expanded(child: _buildMessageList()),
                  _TypingSlot(isTyping: _isOtherTyping),
                  _buildInputBar(),
                ],
              ),
      ),
    );
  }

  Widget _buildMessageList() {
    return StreamBuilder<List<MessageModel>>(
      stream: _stream,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          _debugLog(
            '[Chat] 메시지 목록 로드 실패 matchId=${widget.matchId} error=${snap.error}',
          );
          return const Center(
            child: Text(
              '메시지를 불러오지 못했어요.',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          );
        }
        final messages = snap.data ?? [];
        _debugLog(
          '[Chat] messages matchId=${widget.matchId} count=${messages.length}',
        );
        if (messages.isEmpty) {
          _debugLog('[Icebreakers] 빈 채팅방 표시 조건 충족 matchId=${widget.matchId}');
          return _EmptyState(
            icebreakersFuture: _ensureIcebreakers(),
            onSelected: _fillInput,
          );
        }

        _markLatestMessagesRead(messages);
        _scrollToBottom();
        return ListView.builder(
          controller: _scrollController,
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          itemCount: messages.length,
          itemBuilder: (_, i) {
            final msg = messages[i];
            final isMine = msg.senderId == widget.currentUid;
            final showDateDivider = _shouldShowDateDivider(messages, i);
            final position = _bubblePosition(messages, i);
            final showTime = _shouldShowTime(messages, i);
            return Column(
              key: ValueKey('message-row-${msg.id}'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (showDateDivider) _DateDivider(date: msg.createdAt!),
                _AnimatedMessageRow(
                  child: _MessageBubble(
                    message: msg,
                    isMine: isMine,
                    position: position,
                    showTime: showTime,
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  bool _shouldShowDateDivider(List<MessageModel> messages, int index) {
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

  _BubblePosition _bubblePosition(List<MessageModel> messages, int index) {
    final joinsPrevious = _isGroupedWith(messages, index - 1, index);
    final joinsNext = _isGroupedWith(messages, index, index + 1);
    if (joinsPrevious && joinsNext) return _BubblePosition.middle;
    if (joinsNext) return _BubblePosition.top;
    if (joinsPrevious) return _BubblePosition.bottom;
    return _BubblePosition.single;
  }

  bool _shouldShowTime(List<MessageModel> messages, int index) {
    final current = messages[index];
    if (current.createdAt == null) return true;
    if (index == messages.length - 1) return true;

    final next = messages[index + 1];
    if (current.senderId != next.senderId) return true;
    if (next.createdAt == null) return true;
    return !_isSameMinute(current.createdAt!, next.createdAt!);
  }

  bool _isGroupedWith(
    List<MessageModel> messages,
    int firstIndex,
    int secondIndex,
  ) {
    if (firstIndex < 0 || secondIndex >= messages.length) return false;
    final first = messages[firstIndex];
    final second = messages[secondIndex];
    if (first.senderId != second.senderId) return false;
    final firstTime = first.createdAt;
    final secondTime = second.createdAt;
    if (firstTime == null || secondTime == null) return false;
    if (!_isSameDate(firstTime, secondTime)) return false;
    return secondTime.difference(firstTime).abs() <= const Duration(minutes: 5);
  }

  bool _isSameMinute(DateTime a, DateTime b) {
    return a.year == b.year &&
        a.month == b.month &&
        a.day == b.day &&
        a.hour == b.hour &&
        a.minute == b.minute;
  }

  Widget _buildInputBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: const BoxDecoration(
        color: AppColors.background,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _textController,
              focusNode: _inputFocusNode,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _send(),
              decoration: InputDecoration(
                hintText: '메시지를 입력하세요',
                filled: true,
                fillColor: AppColors.surface,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            onPressed: _sending ? null : _send,
            icon: const Icon(Icons.send_rounded),
            color: AppColors.primary,
          ),
        ],
      ),
    );
  }
}

class _BlockedChatState extends StatelessWidget {
  const _BlockedChatState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.block_rounded, size: 54, color: AppColors.textSecondary),
            SizedBox(height: 16),
            Text(
              '차단된 사용자와는 채팅할 수 없어요.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
            SizedBox(height: 8),
            Text(
              '차단 목록에서 해제하면 다시 대화할 수 있어요.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final Future<List<Icebreaker>> icebreakersFuture;
  final ValueChanged<String> onSelected;

  const _EmptyState({
    required this.icebreakersFuture,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 56, 20, 24),
      child: Column(
        children: [
          const Text(
            '첫 메시지를 보내보세요',
            style: TextStyle(fontSize: 15, color: AppColors.textSecondary),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 28),
          _IcebreakerSection(future: icebreakersFuture, onSelected: onSelected),
        ],
      ),
    );
  }
}

class _IcebreakerSection extends StatelessWidget {
  final Future<List<Icebreaker>> future;
  final ValueChanged<String> onSelected;

  const _IcebreakerSection({required this.future, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Icebreaker>>(
      future: future,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          _debugLog('[Icebreakers] 렌더 상태 loading');
          return const _IcebreakerLoadingCard();
        }

        final icebreakers = snap.data ?? [];
        _debugLog('[Icebreakers] 렌더 상태 done count=${icebreakers.length}');
        if (icebreakers.isEmpty) return const SizedBox.shrink();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '대화 시작이 어렵다면?',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
            const SizedBox(height: 10),
            ...icebreakers.map(
              (item) => _IcebreakerCard(
                icebreaker: item,
                onTap: () => onSelected(item.message),
              ),
            ),
          ],
        );
      },
    );
  }
}

void _debugLog(String message) {
  if (kDebugMode) {
    debugPrint(message);
  }
}

class _IcebreakerLoadingCard extends StatelessWidget {
  const _IcebreakerLoadingCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border),
      ),
      child: const Row(
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              '대화 물꼬를 추천하고 있어요',
              style: TextStyle(fontSize: 14, color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

class _IcebreakerCard extends StatelessWidget {
  final Icebreaker icebreaker;
  final VoidCallback onTap;

  const _IcebreakerCard({required this.icebreaker, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  icebreaker.topic,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: AppColors.primary,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  icebreaker.message,
                  style: const TextStyle(
                    fontSize: 14,
                    height: 1.4,
                    color: AppColors.textPrimary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DateDivider extends StatelessWidget {
  final DateTime date;

  const _DateDivider({required this.date});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Row(
        children: [
          const Expanded(child: Divider(color: AppColors.border, height: 1)),
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 10),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: AppColors.border),
            ),
            child: Text(
              _formatDate(date),
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: AppColors.textSecondary,
              ),
            ),
          ),
          const Expanded(child: Divider(color: AppColors.border, height: 1)),
        ],
      ),
    );
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

enum _BubblePosition { single, top, middle, bottom }

class _AnimatedMessageRow extends StatelessWidget {
  final Widget child;

  const _AnimatedMessageRow({required this.child});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) {
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, 8 * (1 - value)),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final MessageModel message;
  final bool isMine;
  final _BubblePosition position;
  final bool showTime;

  const _MessageBubble({
    required this.message,
    required this.isMine,
    required this.position,
    required this.showTime,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(top: _topSpacing, bottom: showTime ? 5 : 1),
      child: Row(
        mainAxisAlignment: isMine
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (isMine && showTime) _MessageTime(dateTime: message.createdAt),
          if (isMine && showTime) const SizedBox(width: 6),
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: isMine ? AppColors.primary : AppColors.surface,
                borderRadius: _radius,
                border: isMine ? null : Border.all(color: AppColors.border),
              ),
              child: Text(
                message.text,
                style: TextStyle(
                  fontSize: 15,
                  color: isMine ? Colors.white : AppColors.textPrimary,
                  height: 1.4,
                ),
              ),
            ),
          ),
          if (!isMine && showTime) const SizedBox(width: 6),
          if (!isMine && showTime) _MessageTime(dateTime: message.createdAt),
        ],
      ),
    );
  }

  double get _topSpacing {
    switch (position) {
      case _BubblePosition.single:
      case _BubblePosition.top:
        return 8;
      case _BubblePosition.middle:
      case _BubblePosition.bottom:
        return 2;
    }
  }

  BorderRadius get _radius {
    const large = Radius.circular(18);
    const small = Radius.circular(6);
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
        style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
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

class _ChatStatusBar extends StatelessWidget {
  final String label;

  const _ChatStatusBar({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 28,
      width: double.infinity,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.only(left: 72, right: 16, bottom: 8),
      decoration: const BoxDecoration(
        color: AppColors.background,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: const BoxDecoration(
              color: Color(0xFF34C759),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 5),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 11,
              color: AppColors.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _TypingSlot extends StatelessWidget {
  final bool isTyping;

  const _TypingSlot({required this.isTyping});

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 160),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      child: isTyping
          ? const Padding(
              key: ValueKey('typing-on'),
              padding: EdgeInsets.fromLTRB(16, 2, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: _TypingIndicator(),
              ),
            )
          : const SizedBox(key: ValueKey('typing-off'), height: 0),
    );
  }
}

class _TypingIndicator extends StatefulWidget {
  const _TypingIndicator();

  @override
  State<_TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<_TypingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(
          3,
          (index) => _TypingDot(controller: _controller, index: index),
        ),
      ),
    );
  }
}

class _TypingDot extends StatelessWidget {
  final AnimationController controller;
  final int index;

  const _TypingDot({required this.controller, required this.index});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        final shifted = (controller.value + index * 0.18) % 1.0;
        final lift = shifted < 0.5 ? shifted * 2 : (1 - shifted) * 2;
        return Transform.translate(
          offset: Offset(0, -3 * lift),
          child: Opacity(opacity: 0.35 + 0.65 * lift, child: child),
        );
      },
      child: Container(
        width: 6,
        height: 6,
        margin: const EdgeInsets.symmetric(horizontal: 2),
        decoration: const BoxDecoration(
          color: AppColors.textSecondary,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
