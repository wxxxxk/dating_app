import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../models/chat_appointment.dart';
import '../../models/chat_presence.dart';
import '../../models/fortune_model.dart';
import '../../models/message_model.dart';
import '../../models/public_profile.dart';
import '../../services/chat/chat_presence_service.dart';
import '../../services/chat/chat_service.dart';
import '../../services/fortune/fortune_service.dart';
import '../../services/matches/matches_service.dart';
import '../../services/safety/safety_service.dart';
import '../safety/report_sheet.dart';
import 'chat_appointment_widgets.dart';

/// 매칭 상대와의 1:1 실시간 채팅 화면.
///
/// matches/{matchId}/messages 서브컬렉션을 StreamBuilder로 구독해
/// 새 메시지가 도착하면 즉시 리스트에 반영하고 하단으로 자동 스크롤한다.
class ChatScreen extends StatefulWidget {
  final String matchId;
  final PublicProfile otherProfile;
  final String currentUid;
  final ChatService chatService;
  final ChatPresenceService presenceService;
  final FortuneService fortuneService;
  final MatchesService matchesService;
  final SafetyService safetyService;

  const ChatScreen({
    super.key,
    required this.matchId,
    required this.otherProfile,
    required this.currentUid,
    required this.chatService,
    required this.presenceService,
    required this.fortuneService,
    required this.matchesService,
    required this.safetyService,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  /// heartbeat 주기. stale 판정(90초)보다 충분히 짧아야 정상 foreground 상태가
  /// 만료로 오인되지 않는다.
  static const Duration heartbeatInterval = Duration(seconds: 30);

  /// 마지막 입력 후 이 시간이 지나면 입력 중 표시를 내린다.
  static const Duration typingIdleTimeout = Duration(seconds: 2);

  /// "N분 전 접속" 문구 갱신 주기. 초 단위 rebuild는 하지 않는다.
  static const Duration statusRefreshInterval = Duration(seconds: 30);

  late final Stream<List<MessageModel>> _stream;
  final _textController = TextEditingController();
  final _inputFocusNode = FocusNode();
  final _scrollController = ScrollController();
  Future<List<Icebreaker>>? _icebreakersFuture;
  Future<List<ConversationTip>>? _conversationTipsFuture;
  bool _sending = false;
  bool _checkingBlock = true;
  bool _blocked = false;
  bool _hasMessages = false;
  bool _showConversationTips = false;
  bool _unmatched = false;
  bool _unmatching = false;
  bool _submittingAppointment = false;
  final Map<String, Stream<ChatAppointment?>> _appointmentStreams = {};
  String? _lastReadMarker;
  String? _latestConversationTipMessageId;
  StreamSubscription<bool>? _unmatchedSub;

  // ── presence(접속/입력 중) 상태 ────────────────────────────────────────
  StreamSubscription<ChatPresence?>? _presenceSub;
  Timer? _presenceHeartbeat;
  Timer? _typingDebounce;
  Timer? _statusTicker;
  ChatPresence? _otherPresence;
  bool _localTyping = false;
  AppLifecycleState _lifecycleState = AppLifecycleState.resumed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _stream = widget.chatService.watchMessages(widget.matchId);
    _markMatchRead();
    _checkBlocked();
    _watchOtherPresence();
    _writePresence(isOnline: true, isTyping: false);
    _startHeartbeat();
    _startStatusTicker();
    // 채팅방을 열어둔 채로 상대가 매칭을 해제해도 바로 반영되도록 구독한다.
    // 실제 차단은 firestore.rules(메시지 create)가 서버 단에서 하므로,
    // 이 구독은 UX(입력창 비활성화·안내) 목적이다.
    _unmatchedSub = widget.chatService.watchIsUnmatched(widget.matchId).listen((
      value,
    ) {
      if (!mounted) return;
      setState(() => _unmatched = value);
      // 매칭이 해제되면 내 presence도 즉시 내린다.
      if (value) _goOffline();
    }, onError: (Object e) => _debugLog('[Chat] unmatch 상태 구독 실패: $e'));
  }

  @override
  void dispose() {
    _typingDebounce?.cancel();
    _presenceHeartbeat?.cancel();
    _statusTicker?.cancel();
    _presenceSub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    // 화면을 벗어나면 offline로 내린다. dispose에서는 await할 수 없으므로
    // best-effort로 보내고, 실패해도 상대는 heartbeat 만료로 offline을 본다.
    _localTyping = false;
    _writePresence(isOnline: false, isTyping: false);
    _textController.dispose();
    _inputFocusNode.dispose();
    _scrollController.dispose();
    _unmatchedSub?.cancel();
    super.dispose();
  }

  // ── presence ──────────────────────────────────────────────────────────

  /// presence를 갱신해도 되는 상태인지. 차단/매칭 해제 상태에서는 접속 정보를
  /// 더 이상 흘리지 않는다.
  bool get _presenceEnabled => !_blocked && !_unmatched;

  bool get _isForeground => _lifecycleState == AppLifecycleState.resumed;

  void _watchOtherPresence() {
    _presenceSub = widget.presenceService
        .watchPresence(
          matchId: widget.matchId,
          uid: widget.otherProfile.uid,
        )
        .listen(
          (presence) {
            if (!mounted) return;
            setState(() => _otherPresence = presence);
          },
          onError: (Object e) => _debugLog('[Chat] presence 구독 실패: $e'),
        );
  }

  /// presence write는 항상 best-effort — 실패해도 채팅 기능을 막지 않고
  /// 사용자 화면에 오류를 노출하지 않는다.
  void _writePresence({required bool isOnline, required bool isTyping}) {
    unawaited(
      widget.presenceService
          .setPresence(
            matchId: widget.matchId,
            uid: widget.currentUid,
            isOnline: isOnline,
            isTyping: isTyping,
          )
          .catchError((Object e) {
            _debugLog('[Chat] presence 갱신 실패 matchId=${widget.matchId} error=$e');
          }),
    );
  }

  void _startHeartbeat() {
    _presenceHeartbeat?.cancel();
    if (!_presenceEnabled) return;
    _presenceHeartbeat = Timer.periodic(heartbeatInterval, (_) {
      if (!mounted || !_presenceEnabled || !_isForeground) return;
      // 현재 typing 상태를 함께 실어 heartbeat가 입력 중 표시를 되돌리지 않게 한다.
      _writePresence(isOnline: true, isTyping: _localTyping);
    });
  }

  /// "N분 전 접속" 문구가 시간이 지나도 굳어 있지 않도록 주기적으로 rebuild한다.
  void _startStatusTicker() {
    _statusTicker?.cancel();
    _statusTicker = Timer.periodic(statusRefreshInterval, (_) {
      if (!mounted) return;
      setState(() {});
    });
  }

  /// 백그라운드 전환·차단·매칭 해제·화면 이탈 시 공통 offline 처리.
  void _goOffline() {
    _presenceHeartbeat?.cancel();
    _presenceHeartbeat = null;
    _typingDebounce?.cancel();
    _typingDebounce = null;
    _localTyping = false;
    _writePresence(isOnline: false, isTyping: false);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    _lifecycleState = state;
    if (state == AppLifecycleState.resumed) {
      if (!_presenceEnabled) return;
      _localTyping = false;
      _writePresence(isOnline: true, isTyping: false);
      _startHeartbeat();
      return;
    }
    // inactive / paused / hidden / detached 는 모두 offline으로 본다.
    _goOffline();
  }

  /// 입력창 변경 핸들러. 키 입력마다 write하지 않고, true/false 상태가 실제로
  /// 바뀔 때만 Firestore에 반영한다.
  void _onInputChanged(String value) {
    if (!_presenceEnabled || !_isForeground) {
      _setLocalTyping(false);
      return;
    }
    if (value.trim().isEmpty) {
      _setLocalTyping(false);
      return;
    }
    _setLocalTyping(true);
    _typingDebounce?.cancel();
    _typingDebounce = Timer(typingIdleTimeout, () {
      if (!mounted) return;
      _setLocalTyping(false);
    });
  }

  void _setLocalTyping(bool typing) {
    if (!typing) {
      _typingDebounce?.cancel();
      _typingDebounce = null;
    }
    if (_localTyping == typing) return;
    _localTyping = typing;
    _writePresence(
      isOnline: _presenceEnabled && _isForeground,
      isTyping: typing,
    );
  }

  Future<void> _send() async {
    final text = _textController.text;
    if (text.trim().isEmpty || _sending || _blocked || _unmatched) return;

    // 전송을 시작하는 순간 입력 중 표시는 내린다.
    _setLocalTyping(false);

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

  /// 같은 appointmentId의 스트림을 캐시해 리스트 rebuild마다 재구독되지 않게 한다.
  Stream<ChatAppointment?> _appointmentStream(String appointmentId) {
    return _appointmentStreams.putIfAbsent(
      appointmentId,
      () => widget.chatService.watchAppointment(
        matchId: widget.matchId,
        appointmentId: appointmentId,
      ),
    );
  }

  Future<void> _openAppointmentSheet() async {
    if (_blocked || _unmatched || _submittingAppointment) return;
    final proposed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.background,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadius.sheet),
        ),
      ),
      builder: (_) => AppointmentProposalSheet(onSubmit: _submitAppointment),
    );
    if (proposed == true && mounted) {
      _scrollToBottom();
      _showSnack('약속을 제안했어요.');
    }
  }

  /// 시트가 호출하는 실제 제안 로직. 성공 여부를 반환하고, 실패 시 시트가 열린
  /// 채로 입력을 유지하도록 false를 돌려준다. raw 오류는 화면에 노출하지 않는다.
  Future<bool> _submitAppointment({
    required DateTime scheduledAt,
    required String place,
    required String note,
  }) async {
    if (_submittingAppointment) return false;
    setState(() => _submittingAppointment = true);
    try {
      await widget.chatService.proposeAppointment(
        matchId: widget.matchId,
        proposerUid: widget.currentUid,
        recipientUid: widget.otherProfile.uid,
        scheduledAt: scheduledAt,
        place: place,
        note: note,
      );
      return true;
    } catch (e) {
      _debugLog('[Chat] 약속 제안 실패 matchId=${widget.matchId} error=$e');
      return false;
    } finally {
      if (mounted) setState(() => _submittingAppointment = false);
    }
  }

  Future<void> _respondToAppointment(
    String appointmentId,
    ChatAppointmentStatus status,
  ) async {
    await widget.chatService.respondToAppointment(
      matchId: widget.matchId,
      appointmentId: appointmentId,
      responderUid: widget.currentUid,
      status: status,
    );
  }

  void _scrollToBottom() {
    // 새 프레임이 그려진 뒤(리스트 길이 갱신 후) 스크롤해야 maxScrollExtent가 정확하다.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: AppDurations.base,
        curve: AppCurves.standard,
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
    if (_blocked || _unmatched) return;
    _textController.text = message;
    _textController.selection = TextSelection.collapsed(offset: message.length);
    _inputFocusNode.requestFocus();
  }

  void _syncConversationCoachState({
    required bool hasMessages,
    String? latestMessageId,
  }) {
    if (_hasMessages == hasMessages &&
        _latestConversationTipMessageId == latestMessageId) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          (_hasMessages == hasMessages &&
              _latestConversationTipMessageId == latestMessageId)) {
        return;
      }
      setState(() {
        final messageChanged =
            _latestConversationTipMessageId != null &&
            _latestConversationTipMessageId != latestMessageId;
        _hasMessages = hasMessages;
        _latestConversationTipMessageId = latestMessageId;
        if (!hasMessages || messageChanged) {
          _showConversationTips = false;
          _conversationTipsFuture = null;
        }
      });
    });
  }

  void _requestConversationTips({bool forceRefresh = false}) {
    if (_blocked || _unmatched || !_hasMessages) return;
    setState(() {
      _showConversationTips = true;
      if (forceRefresh || _conversationTipsFuture == null) {
        _debugLog('[ConversationTips] 요청 생성 matchId=${widget.matchId}');
        _conversationTipsFuture = widget.fortuneService.getConversationTips(
          widget.matchId,
        );
      }
    });
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
      if (blocked) _goOffline();
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
      if (_blocked) _goOffline();
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
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.error,
              foregroundColor: AppColors.surface,
            ),
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
      _goOffline();
      _showSnack('차단했어요.');
    } catch (e) {
      _debugLog(
        '[Safety] 차단 실패 blockedUid=${widget.otherProfile.uid} error=$e',
      );
      if (mounted) _showSnack('차단에 실패했어요. 잠시 후 다시 시도해주세요.');
    }
  }

  Future<void> _confirmUnmatch() async {
    if (_unmatching || _unmatched) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('매칭을 해제할까요?'),
        content: const Text('해제하면 서로의 매칭 목록에서 사라지고 더 이상 대화할 수 없어요.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.error,
              foregroundColor: AppColors.surface,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('해제'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _unmatching = true);
    try {
      await widget.matchesService.unmatch(
        matchId: widget.matchId,
        uid: widget.currentUid,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('매칭을 해제했어요.')));
      Navigator.pop(context);
    } catch (e) {
      _debugLog('[Chat] 매칭 해제 실패 matchId=${widget.matchId} error=$e');
      if (mounted) {
        setState(() => _unmatching = false);
        _showSnack('매칭 해제에 실패했어요. 잠시 후 다시 시도해주세요.');
      }
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

    // 차단/매칭 해제 상태에서는 상대 접속 정보를 노출하지 않는다.
    final showPresence = !_checkingBlock && _presenceEnabled;
    final presence = showPresence ? _otherPresence : null;
    final now = DateTime.now();
    final otherOnline = presence?.isActuallyOnline(now: now) ?? false;
    final otherTyping = presence?.isActuallyTyping(now: now) ?? false;

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
                      Icons.person_rounded,
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
        bottom: showPresence
            ? PreferredSize(
                preferredSize: const Size.fromHeight(28),
                child: _ChatStatusBar(
                  label: chatPresenceLabel(presence: presence, now: now),
                  isOnline: otherOnline,
                ),
              )
            : null,
        actions: [
          PopupMenuButton<String>(
            tooltip: '안전 메뉴',
            onSelected: (value) {
              if (value == 'report') _reportUser();
              if (value == 'block') _blockUser();
              if (value == 'unmatch') _confirmUnmatch();
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'report', child: Text('신고하기')),
              const PopupMenuItem(value: 'block', child: Text('차단하기')),
              if (!_unmatched)
                const PopupMenuItem(
                  value: 'unmatch',
                  child: Text(
                    '매칭 해제',
                    style: TextStyle(color: AppColors.error),
                  ),
                ),
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
                  _TypingSlot(isTyping: otherTyping),
                  _buildConversationCoach(),
                  _unmatched ? const _UnmatchedInputBar() : _buildInputBar(),
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
          _syncConversationCoachState(hasMessages: false);
          _debugLog('[Icebreakers] 빈 채팅방 표시 조건 충족 matchId=${widget.matchId}');
          return _EmptyState(
            icebreakersFuture: _ensureIcebreakers(),
            onSelected: _fillInput,
          );
        }

        _syncConversationCoachState(
          hasMessages: true,
          latestMessageId: messages.last.id,
        );
        _markLatestMessagesRead(messages);
        _scrollToBottom();
        return ListView.builder(
          controller: _scrollController,
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          itemCount: messages.length,
          itemBuilder: (_, i) {
            final msg = messages[i];
            final showDateDivider = _shouldShowDateDivider(messages, i);
            return Column(
              key: ValueKey('message-row-${msg.id}'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (showDateDivider) _DateDivider(date: msg.createdAt!),
                _AnimatedMessageRow(child: _buildMessageContent(messages, i)),
              ],
            );
          },
        );
      },
    );
  }

  /// 메시지 종류별 렌더링. 약속 제안은 카드, 응답은 가운데 시스템 행,
  /// 나머지는 기존 말풍선. 약속/시스템 메시지는 말풍선 grouping과 섞지 않는다.
  Widget _buildMessageContent(List<MessageModel> messages, int index) {
    final msg = messages[index];
    if (msg.isAppointment) {
      return AppointmentMessageCard(
        appointmentId: msg.appointmentId!,
        currentUid: widget.currentUid,
        stream: _appointmentStream(msg.appointmentId!),
        onRespond: (status) =>
            _respondToAppointment(msg.appointmentId!, status),
      );
    }
    if (msg.isAppointmentResponse) {
      return AppointmentResponseRow(text: msg.text);
    }
    return _MessageBubble(
      message: msg,
      isMine: msg.senderId == widget.currentUid,
      position: _bubblePosition(messages, index),
      showTime: _shouldShowTime(messages, index),
    );
  }

  Widget _buildConversationCoach() {
    if (!_hasMessages || _unmatched) return const SizedBox.shrink();
    return _ConversationCoachPanel(
      future: _conversationTipsFuture,
      expanded: _showConversationTips,
      onRequest: () => _requestConversationTips(),
      onRetry: () => _requestConversationTips(forceRefresh: true),
      onSelected: _fillInput,
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
    // 다음 메시지가 약속 카드/시스템 행이면 그룹이 끊기므로 시간을 표시한다.
    if (!next.isPlainText) return true;
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
    // 약속 카드/응답 시스템 행은 텍스트 말풍선 grouping에 섞지 않는다.
    if (!first.isPlainText || !second.isPlainText) return false;
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
          ChatAppointmentButton(
            onPressed: _submittingAppointment ? null : _openAppointmentSheet,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: TextField(
              controller: _textController,
              focusNode: _inputFocusNode,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onChanged: _onInputChanged,
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
                  borderRadius: BorderRadius.circular(AppRadius.button),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            onPressed: _sending ? null : _send,
            icon: const Icon(Icons.send_rounded),
            style: IconButton.styleFrom(
              backgroundColor: AppColors.mintStrong,
              foregroundColor: AppColors.onMint,
              disabledBackgroundColor: AppColors.divider,
            ),
          ),
        ],
      ),
    );
  }
}

/// 입력창 자리를 대체하는 안내 바 — 매칭이 해제된 뒤에도 기존 대화 기록은
/// 그대로 보여주되(삭제하지 않음), 새 메시지만 보낼 수 없게 막는다.
class _UnmatchedInputBar extends StatelessWidget {
  const _UnmatchedInputBar();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.error.withValues(alpha: 0.06),
        border: const Border(top: BorderSide(color: AppColors.border)),
      ),
      child: const Row(
        children: [
          Icon(Icons.block_rounded, size: 18, color: AppColors.error),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              '매칭이 해제되어 더 이상 대화할 수 없어요.',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: AppColors.error,
              ),
            ),
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

class _ConversationCoachPanel extends StatelessWidget {
  final Future<List<ConversationTip>>? future;
  final bool expanded;
  final VoidCallback onRequest;
  final VoidCallback onRetry;
  final ValueChanged<String> onSelected;

  const _ConversationCoachPanel({
    required this.future,
    required this.expanded,
    required this.onRequest,
    required this.onRetry,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.mint.withValues(alpha: 0.3)),
        boxShadow: AppShadows.card,
      ),
      child: AnimatedSwitcher(
        duration: AppDurations.fast,
        child: expanded && future != null
            ? _ConversationTipsFuture(
                key: const ValueKey('conversation-tips'),
                future: future!,
                onRetry: onRetry,
                onSelected: onSelected,
              )
            : Align(
                key: const ValueKey('conversation-button'),
                alignment: Alignment.centerLeft,
                // premium accent로 "이건 AI가 돕는 기능"이라는 신호를 준다 —
                // 전송 버튼(primary)과 구분되게.
                child: TextButton.icon(
                  onPressed: onRequest,
                  icon: const Icon(Icons.auto_awesome_rounded, size: 18),
                  label: const Text(
                    '대화 이어가기',
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                  ),
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.mintDeep,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    textStyle: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
              ),
      ),
    );
  }
}

class _ConversationTipsFuture extends StatelessWidget {
  final Future<List<ConversationTip>> future;
  final VoidCallback onRetry;
  final ValueChanged<String> onSelected;

  const _ConversationTipsFuture({
    super.key,
    required this.future,
    required this.onRetry,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<ConversationTip>>(
      future: future,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          _debugLog('[ConversationTips] 렌더 상태 loading');
          return const _ConversationTipsLoading();
        }
        if (snap.hasError) {
          _debugLog('[ConversationTips] 렌더 상태 error');
          return _ConversationTipsError(onRetry: onRetry);
        }

        final tips = snap.data ?? [];
        _debugLog('[ConversationTips] 렌더 상태 done count=${tips.length}');
        if (tips.isEmpty) {
          return _ConversationTipsEmpty(onRetry: onRetry);
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.auto_awesome_rounded,
                  size: 17,
                  color: AppColors.mint,
                ),
                const SizedBox(width: 6),
                const Expanded(
                  child: Text(
                    '대화 이어가기',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '다시 시도',
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh_rounded),
                  color: AppColors.textSecondary,
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: 6),
            ...tips.map(
              (tip) => _ConversationTipButton(
                tip: tip,
                onTap: () => onSelected(tip.message),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ConversationTipsLoading extends StatelessWidget {
  const _ConversationTipsLoading();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: [
        SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        SizedBox(width: 12),
        Expanded(
          child: Text(
            '다음 화제를 추천하고 있어요',
            style: TextStyle(fontSize: 14, color: AppColors.textSecondary),
          ),
        ),
      ],
    );
  }
}

class _ConversationTipsError extends StatelessWidget {
  final VoidCallback onRetry;

  const _ConversationTipsError({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Expanded(
          child: Text(
            '지금은 제안을 불러올 수 없어요.',
            style: TextStyle(fontSize: 14, color: AppColors.textSecondary),
          ),
        ),
        TextButton(onPressed: onRetry, child: const Text('재시도')),
      ],
    );
  }
}

class _ConversationTipsEmpty extends StatelessWidget {
  final VoidCallback onRetry;

  const _ConversationTipsEmpty({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Expanded(
          child: Text(
            '지금은 추천할 화제가 부족해요.',
            style: TextStyle(fontSize: 14, color: AppColors.textSecondary),
          ),
        ),
        TextButton(onPressed: onRetry, child: const Text('재시도')),
      ],
    );
  }
}

class _ConversationTipButton extends StatelessWidget {
  final ConversationTip tip;
  final VoidCallback onTap;

  const _ConversationTipButton({required this.tip, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.button),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.button),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.button),
              border: Border.all(color: AppColors.mint.withValues(alpha: 0.24)),
            ),
            child: Text(
              tip.message,
              style: const TextStyle(
                fontSize: 14,
                height: 1.35,
                color: AppColors.textPrimary,
              ),
            ),
          ),
        ),
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
        borderRadius: BorderRadius.circular(AppRadius.button),
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
        borderRadius: BorderRadius.circular(AppRadius.button),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.button),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.button),
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
              borderRadius: BorderRadius.circular(AppRadius.chip),
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
      duration: AppDurations.fast,
      curve: AppCurves.standard,
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
                // 내 버블: 시그니처 민트 fill + 다크 잉크 텍스트.
                // (구 seal red 버블은 경고/에러처럼 읽혀서 폐기)
                color: isMine ? AppColors.mint : AppColors.surface,
                borderRadius: _radius,
                border: isMine ? null : Border.all(color: AppColors.border),
              ),
              child: Text(
                message.text,
                style: TextStyle(
                  fontSize: 15,
                  color: isMine ? AppColors.onMint : AppColors.textPrimary,
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
  final bool isOnline;

  const _ChatStatusBar({required this.label, required this.isOnline});

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
            decoration: BoxDecoration(
              color: isOnline ? AppColors.wood : AppColors.divider,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              label,
              key: const ValueKey('chat-status-label'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 11,
                color: AppColors.textSecondary,
                fontWeight: FontWeight.w600,
              ),
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
      duration: AppDurations.fast,
      switchInCurve: AppCurves.standard,
      switchOutCurve: AppCurves.exit,
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
      duration: AppDurations.emphasis,
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
        borderRadius: BorderRadius.circular(AppRadius.card),
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
