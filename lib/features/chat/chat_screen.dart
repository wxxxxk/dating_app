import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../models/appointment_safety_checkin.dart';
import '../../models/chat_appointment.dart';
import '../../models/chat_presence.dart';
import '../../models/fortune_model.dart';
import '../../models/message_model.dart';
import '../../models/public_profile.dart';
import '../../services/chat/appointment_safety_service.dart';
import '../../services/chat/chat_presence_service.dart';
import '../../services/chat/chat_service.dart';
import '../../services/fortune/fortune_service.dart';
import '../../services/matches/matches_service.dart';
import '../../services/safety/safety_service.dart';
import '../../shared/widgets/app_components.dart';
import '../safety/message_report_sheet.dart';
import '../safety/report_sheet.dart';
import 'appointment_safety_widgets.dart';
import 'chat_appointment_widgets.dart';
import 'chat_safety.dart';
import 'chat_safety_widgets.dart';

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
  final AppointmentSafetyService appointmentSafetyService;
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
    required this.appointmentSafetyService,
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
  ConversationHelperStatus _tipsStatus = ConversationHelperStatus.idle;
  List<ConversationTip> _tips = const [];
  ConversationTipsErrorKind? _tipsErrorKind;

  /// 요청 세대. 늦게 도착한 이전 응답을 버리는 기준이다.
  int _tipsGeneration = 0;

  /// 진행 중인 요청이 대상으로 삼은 context.
  String? _tipsRequestMessageId;
  bool _sending = false;
  bool _checkingBlock = true;
  bool _blocked = false;
  bool _hasMessages = false;
  bool _showConversationTips = false;
  bool _unmatched = false;
  bool _unmatching = false;
  bool _submittingAppointment = false;
  // 안전 가이드 배너 닫기는 이 화면 세션에만 반영한다(영구 저장하지 않음).
  bool _safetyBannerDismissed = false;
  // 민감정보 경고 시트가 열려 있는 동안 중복 전송 시도를 막는다.
  bool _confirmingSafety = false;
  // 메시지 신고 제출 중 중복 제출을 막는다.
  bool _reportingMessage = false;
  // 이 화면 세션에서 이미 신고한 messageId. Firestore(메시지 문서)에는 신고
  // 표시를 쓰지 않으므로 재진입하면 초기화되는 것이 정상이다.
  final Set<String> _reportedMessageIdsThisSession = {};
  final Map<String, Stream<ChatAppointment?>> _appointmentStreams = {};
  // 카드 rebuild마다 checkin stream을 새로 만들지 않도록 캐시한다.
  final Map<String, Stream<AppointmentSafetyCheckin?>>
  _appointmentSafetyStreams = {};
  // 안전 확인 제출 중 중복 제출을 막는다.
  bool _submittingSafetyCheck = false;
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
        .watchPresence(matchId: widget.matchId, uid: widget.otherProfile.uid)
        .listen((presence) {
          if (!mounted) return;
          setState(() => _otherPresence = presence);
        }, onError: (Object e) => _debugLog('[Chat] presence 구독 실패: $e'));
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
            _debugLog(
              '[Chat] presence 갱신 실패 matchId=${widget.matchId} error=$e',
            );
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

  /// 전송 진입점. 민감정보 가능성이 있으면 전송 전에 한 번 더 확인받는다.
  ///
  /// 경고 시트가 열려 있는 동안에는 입력창을 비우지 않는다 — 사용자가 "다시
  /// 확인"을 고르면 작성 중이던 내용이 그대로 남아 있어야 한다.
  Future<void> _send() async {
    final text = _textController.text;
    if (text.trim().isEmpty ||
        _sending ||
        _confirmingSafety ||
        _blocked ||
        _unmatched) {
      return;
    }

    final detection = detectChatSafetyRisks(text);
    if (detection.hasRisk) {
      setState(() => _confirmingSafety = true);
      final bool? confirmed;
      try {
        confirmed = await showChatSafetyWarningSheet(
          context: context,
          risks: detection.risks,
        );
      } finally {
        if (mounted) setState(() => _confirmingSafety = false);
      }
      // 취소(또는 시트 바깥 탭)면 전송하지 않고 입력 내용을 그대로 둔다.
      if (confirmed != true || !mounted) return;
      if (_blocked || _unmatched) return;
    }

    // 확인을 마쳤으므로 detector를 다시 거치지 않고 캡처한 원문만 전송한다.
    await _performSend(text);
  }

  /// 실제 전송. [text]는 _send가 캡처한 원문이며 여기서 재탐지하지 않는다
  /// (확인 후 경고가 반복되지 않게 하기 위함).
  Future<void> _performSend(String text) async {
    if (_sending) return;

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
      // 메시지를 보냈으면 이전 추천 context는 더 이상 최신이 아니다.
      if (mounted) setState(() => _resetTipsState(reason: 'request_cancelled'));
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

  /// appointmentId별 본인 checkin 스트림 캐시. 상대 것은 조회하지 않는다.
  Stream<AppointmentSafetyCheckin?> _appointmentSafetyStream(
    String appointmentId,
  ) {
    return _appointmentSafetyStreams.putIfAbsent(
      appointmentId,
      () => widget.appointmentSafetyService.watchCheckin(
        matchId: widget.matchId,
        appointmentId: appointmentId,
        uid: widget.currentUid,
      ),
    );
  }

  /// 만남 전 체크리스트 → 완료 시각 기록. 체크 항목 값은 저장하지 않는다.
  Future<void> _openPreSafetyCheck(String appointmentId) async {
    if (_submittingSafetyCheck) return;
    final completed = await showPreDateSafetySheet(context);
    if (completed != true || !mounted) return;

    setState(() => _submittingSafetyCheck = true);
    try {
      await widget.appointmentSafetyService.completePreCheck(
        matchId: widget.matchId,
        appointmentId: appointmentId,
        uid: widget.currentUid,
      );
      if (mounted) _showSnack('만남 전 안전 확인을 기록했어요.');
    } catch (e) {
      _debugLog('[Safety] 사전 안전 확인 실패 appointmentId=$appointmentId error=$e');
      if (mounted) _showSnack('안전 확인을 저장하지 못했어요. 잠시 후 다시 시도해주세요.');
    } finally {
      if (mounted) setState(() => _submittingSafetyCheck = false);
    }
  }

  /// 만남 후 상태 기록. needsSupport면 곧바로 도움 안내를 연다.
  Future<void> _openPostSafetyCheck(
    String appointmentId,
    DateTime scheduledAt,
  ) async {
    if (_submittingSafetyCheck) return;
    final status = await showPostDateSafetySheet(context);
    if (status == null || !mounted) return;

    setState(() => _submittingSafetyCheck = true);
    try {
      await widget.appointmentSafetyService.completePostCheck(
        matchId: widget.matchId,
        appointmentId: appointmentId,
        uid: widget.currentUid,
        scheduledAt: scheduledAt,
        status: status,
      );
      if (!mounted) return;
      _showSnack('상태를 기록했어요.');
      if (status == AppointmentPostSafetyStatus.needsSupport) {
        await _openSupportActions();
      }
    } on AppointmentSafetyValidationError catch (e) {
      // 검증 실패 문구는 사용자에게 보여줘도 안전한 고정 문구다.
      if (mounted) _showSnack(e.message);
    } catch (e) {
      _debugLog('[Safety] 사후 안전 확인 실패 appointmentId=$appointmentId error=$e');
      if (mounted) _showSnack('상태를 저장하지 못했어요. 잠시 후 다시 시도해주세요.');
    } finally {
      if (mounted) setState(() => _submittingSafetyCheck = false);
    }
  }

  /// 도움 안내 시트. 신고·차단을 자동 실행하지 않고 기존 흐름으로 연결만 한다.
  Future<void> _openSupportActions() async {
    final action = await showAppointmentSupportSheet(context);
    if (action == null || !mounted) return;
    switch (action) {
      case AppointmentSupportAction.reportUser:
        await _reportUser();
      case AppointmentSupportAction.blockUser:
        await _blockUser();
      case AppointmentSupportAction.safetyGuide:
        await showChatSafetyGuideSheet(context);
    }
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

  /// 추천 문장을 composer에 적용한다. **자동 전송하지 않는다.**
  ///
  /// 작성 중인 draft가 있으면 확인 없이 덮어쓰지 않는다 — 사용자가 쓰던 문장이
  /// 사라지는 건 되돌릴 수 없다.
  Future<void> _applySuggestion(String message) async {
    if (_blocked || _unmatched) return;
    final draft = _textController.text.trim();
    if (draft.isEmpty) {
      _fillInput(message);
      return;
    }

    final action = await showModalBottomSheet<_DraftAction>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 18, 20, 6),
              child: Text(
                '작성 중인 문장이 있어요',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
              ),
            ),
            ListTile(
              key: const Key('conversation-draft-replace'),
              leading: const Icon(Icons.swap_horiz_rounded),
              title: const Text('기존 문장 교체'),
              onTap: () => Navigator.of(sheetContext).pop(_DraftAction.replace),
            ),
            ListTile(
              key: const Key('conversation-draft-append'),
              leading: const Icon(Icons.playlist_add_rounded),
              title: const Text('뒤에 이어 붙이기'),
              onTap: () => Navigator.of(sheetContext).pop(_DraftAction.append),
            ),
            ListTile(
              key: const Key('conversation-draft-cancel'),
              leading: const Icon(Icons.close_rounded),
              title: const Text('취소'),
              onTap: () => Navigator.of(sheetContext).pop(_DraftAction.cancel),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case _DraftAction.replace:
        _fillInput(message);
        break;
      case _DraftAction.append:
        _fillInput('$draft $message');
        break;
      case _DraftAction.cancel:
      case null:
        break; // draft를 그대로 둔다.
    }
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
          // 새 메시지가 오면 이전 추천 context는 무효다.
          _resetTipsState(reason: 'context_changed');
        }
      });
    });
  }

  /// 추천 상태를 초기화한다. 진행 중인 요청도 무효화한다.
  void _resetTipsState({required String reason}) {
    _tipsGeneration += 1;
    _tipsRequestMessageId = null;
    _showConversationTips = false;
    _tipsStatus = ConversationHelperStatus.idle;
    _tips = const [];
    _tipsErrorKind = null;
    _debugLog('[ConversationTips] $reason');
  }

  Future<void> _requestConversationTips({bool forceRefresh = false}) async {
    if (_blocked || _unmatched || !_hasMessages) return;
    // 진행 중이면 중복 호출하지 않는다.
    if (_tipsStatus == ConversationHelperStatus.loading) return;
    if (!forceRefresh && _tipsStatus == ConversationHelperStatus.ready) {
      setState(() => _showConversationTips = true);
      return;
    }

    final requestId = ++_tipsGeneration;
    final requestMessageId = _latestConversationTipMessageId;
    _tipsRequestMessageId = requestMessageId;
    setState(() {
      _showConversationTips = true;
      _tipsStatus = ConversationHelperStatus.loading;
      _tipsErrorKind = null;
    });

    try {
      final result = await widget.fortuneService.getConversationTips(
        widget.matchId,
      );
      if (!_isCurrentTipsRequest(requestId, requestMessageId)) {
        _debugLog('[ConversationTips] stale_response_ignored');
        return;
      }
      if (result.tips.isEmpty) {
        setState(() {
          _tipsStatus = ConversationHelperStatus.error;
          _tipsErrorKind = ConversationTipsErrorKind.invalidResponse;
        });
        return;
      }
      setState(() {
        _tips = result.tips;
        _tipsStatus = ConversationHelperStatus.ready;
        _tipsErrorKind = null;
      });
    } on ConversationTipsFailure catch (failure) {
      if (!_isCurrentTipsRequest(requestId, requestMessageId)) {
        _debugLog('[ConversationTips] stale_response_ignored');
        return;
      }
      setState(() {
        _tipsErrorKind = failure.kind;
        _tipsStatus = switch (failure.kind) {
          ConversationTipsErrorKind.rateLimited =>
            ConversationHelperStatus.rateLimited,
          ConversationTipsErrorKind.unavailable =>
            ConversationHelperStatus.unavailable,
          ConversationTipsErrorKind.unusableChat ||
          ConversationTipsErrorKind.noMessages =>
            ConversationHelperStatus.unavailable,
          _ => ConversationHelperStatus.error,
        };
      });
    } catch (_) {
      if (!_isCurrentTipsRequest(requestId, requestMessageId)) return;
      setState(() {
        _tipsStatus = ConversationHelperStatus.error;
        _tipsErrorKind = ConversationTipsErrorKind.unknown;
      });
    }
  }

  /// 응답 반영 전 context가 그대로인지 확인한다.
  bool _isCurrentTipsRequest(int requestId, String? requestMessageId) {
    if (!mounted) return false;
    if (requestId != _tipsGeneration) return false;
    if (_tipsRequestMessageId != requestMessageId) return false;
    if (_latestConversationTipMessageId != requestMessageId) return false;
    if (_blocked || _unmatched) return false;
    return true;
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

  /// 신고 가능한 메시지인가. 일반 텍스트 + 상대가 보낸 것만 허용한다.
  /// 약속 카드/약속 응답 시스템 행과 내 메시지는 대상이 아니다(rules도 동일).
  bool _canReportMessage(MessageModel message) {
    return message.type == ChatMessageType.text &&
        message.senderId.isNotEmpty &&
        message.senderId != widget.currentUid;
  }

  /// 메시지 신고 흐름: 액션 시트 → 신고 폼 → 신고 적재 → (선택) 차단.
  ///
  /// 로그·오류 메시지 어디에도 메시지 원문이나 senderId를 남기지 않는다.
  Future<void> _reportMessage(MessageModel message) async {
    if (!_canReportMessage(message) || _reportingMessage) return;

    if (_reportedMessageIdsThisSession.contains(message.id)) {
      _showSnack('이미 신고한 메시지예요.');
      return;
    }

    final wantsReport = await showMessageActionSheet(
      context: context,
      messagePreview: message.text,
    );
    if (wantsReport != true || !mounted) return;

    final submission = await showMessageReportSheet(
      context: context,
      messagePreview: message.text,
    );
    if (submission == null || !mounted) return;

    setState(() => _reportingMessage = true);
    try {
      await widget.safetyService.reportMessage(
        reporterUid: widget.currentUid,
        reportedUid: message.senderId,
        matchId: widget.matchId,
        messageId: message.id,
        reason: submission.reason,
        detail: submission.detail,
      );
      if (submission.blockUser) {
        await widget.safetyService.blockUser(
          currentUid: widget.currentUid,
          blockedUid: message.senderId,
        );
      }
      _reportedMessageIdsThisSession.add(message.id);
      if (!mounted) return;
      if (submission.blockUser) {
        setState(() => _blocked = true);
        _goOffline();
      }
      _showSnack(
        submission.blockUser ? '메시지를 신고하고 사용자를 차단했어요.' : '메시지 신고가 접수되었어요.',
      );
    } catch (e) {
      // 원문·발신자 정보는 로그에 남기지 않는다. messageId 참조만 남긴다.
      _debugLog(
        '[Safety] 메시지 신고 실패 matchId=${widget.matchId} messageId=${message.id}',
      );
      if (mounted) _showSnack('메시지 신고에 실패했어요. 잠시 후 다시 시도해주세요.');
    } finally {
      if (mounted) setState(() => _reportingMessage = false);
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
      builder: (ctx) => const _BoundaryConfirmDialog(
        icon: Icons.block_rounded,
        iconColor: AppColors.statusDanger,
        iconBackground: AppColors.statusDangerSoft,
        title: '차단하기',
        description: '차단하면 서로 디스커버리, 매칭, 채팅에서 볼 수 없어요.',
        confirmLabel: '차단',
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
      builder: (ctx) => const _BoundaryConfirmDialog(
        icon: Icons.link_off_rounded,
        iconColor: AppColors.expressiveAccent,
        iconBackground: AppColors.expressiveAccentSoft,
        title: '매칭을 해제할까요?',
        description: '해제하면 서로의 매칭 목록에서 사라지고 더 이상 대화할 수 없어요.',
        confirmLabel: '해제',
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
    // 차단·매칭 해제 상태에서는 안내 배너를 띄우지 않는다(대화가 불가능하므로).
    // 키보드가 올라온 동안에도 숨긴다 — 작은 화면에서 입력 중 표시·대화 코치
    // 패널까지 함께 뜨면 세로 공간이 모자라고, 입력 중에는 안내가 방해가 된다.
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    final showSafetyBanner =
        showPresence && !_safetyBannerDismissed && !keyboardOpen;
    final presence = showPresence ? _otherPresence : null;
    final now = DateTime.now();
    final otherOnline = presence?.isActuallyOnline(now: now) ?? false;
    final otherTyping = presence?.isActuallyTyping(now: now) ?? false;

    return Scaffold(
      backgroundColor: AppColors.warmCanvas,
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        backgroundColor: AppColors.surfacePrimary,
        foregroundColor: AppColors.textStrong,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleSpacing: 0,
        title: Row(
          children: [
            Semantics(
              image: true,
              label: '${other.displayName} 프로필 사진',
              child: Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: AppColors.canvasSubtle,
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.borderSubtle),
                ),
                clipBehavior: Clip.antiAlias,
                child: photoUrl == null
                    ? const Icon(
                        Icons.person_rounded,
                        size: 20,
                        color: AppColors.textMuted,
                      )
                    : Image.network(
                        photoUrl,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => const Icon(
                          Icons.person_rounded,
                          size: 20,
                          color: AppColors.textMuted,
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                other.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: AppFonts.body,
                  fontWeight: FontWeight.w800,
                  fontSize: 17.5,
                  color: AppColors.textStrong,
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
            color: AppColors.surfacePrimary,
            elevation: 3,
            shadowColor: Colors.black26,
            offset: const Offset(0, 8),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
              side: const BorderSide(color: AppColors.borderSubtle),
            ),
            onSelected: (value) {
              if (value == 'safety_guide') showChatSafetyGuideSheet(context);
              if (value == 'report') _reportUser();
              if (value == 'block') _blockUser();
              if (value == 'unmatch') _confirmUnmatch();
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'safety_guide',
                height: 44,
                child: _SafetyMenuRow(
                  icon: Icons.verified_user_outlined,
                  label: '안전하게 대화하기',
                  iconColor: AppColors.mintDeep,
                ),
              ),
              const PopupMenuItem(
                value: 'report',
                height: 44,
                child: _SafetyMenuRow(
                  icon: Icons.flag_outlined,
                  label: '신고하기',
                  iconColor: AppColors.textBody,
                ),
              ),
              const PopupMenuItem(
                value: 'block',
                height: 44,
                child: _SafetyMenuRow(
                  icon: Icons.block_rounded,
                  label: '차단하기',
                  iconColor: AppColors.statusDanger,
                  labelColor: AppColors.statusDanger,
                ),
              ),
              if (!_unmatched) ...[
                const PopupMenuDivider(),
                const PopupMenuItem(
                  value: 'unmatch',
                  height: 44,
                  child: _SafetyMenuRow(
                    icon: Icons.link_off_rounded,
                    label: '매칭 해제',
                    iconColor: AppColors.error,
                    labelColor: AppColors.error,
                  ),
                ),
              ],
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
                  ChatSafetyBannerSlot(
                    visible: showSafetyBanner,
                    onOpenGuide: () => showChatSafetyGuideSheet(context),
                    onDismiss: () =>
                        setState(() => _safetyBannerDismissed = true),
                  ),
                  Expanded(child: _ChatBackdrop(child: _buildMessageList())),
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
          return const Center(
            child: SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2.4,
                color: AppColors.brandPrimary,
              ),
            ),
          );
        }
        if (snap.hasError) {
          _debugLog(
            '[Chat] 메시지 목록 로드 실패 matchId=${widget.matchId} error=${snap.error}',
          );
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.error_outline_rounded,
                    size: 30,
                    color: AppColors.statusDanger,
                  ),
                  SizedBox(height: 12),
                  Text(
                    '메시지를 불러오지 못했어요.',
                    style: TextStyle(color: AppColors.textBody),
                  ),
                ],
              ),
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
            otherProfile: widget.otherProfile,
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
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
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
      final appointmentId = msg.appointmentId!;
      return AppointmentMessageCard(
        appointmentId: appointmentId,
        currentUid: widget.currentUid,
        stream: _appointmentStream(appointmentId),
        onRespond: (status) => _respondToAppointment(appointmentId, status),
        // 안전 확인은 매칭 해제 후에도 본인에게 허용한다(차단 상태에서는 화면
        // 자체가 _BlockedChatState로 바뀌어 카드가 보이지 않는다).
        safetyCheckinStream: _appointmentSafetyStream(appointmentId),
        onOpenPreSafetyCheck: () => _openPreSafetyCheck(appointmentId),
        onOpenPostSafetyCheck: (scheduledAt) =>
            _openPostSafetyCheck(appointmentId, scheduledAt),
        onOpenSupportActions: _openSupportActions,
      );
    }
    if (msg.isAppointmentResponse) {
      return AppointmentResponseRow(text: msg.text);
    }
    final bubble = _MessageBubble(
      message: msg,
      isMine: msg.senderId == widget.currentUid,
      position: _bubblePosition(messages, index),
      showTime: _shouldShowTime(messages, index),
    );
    if (!_canReportMessage(msg)) return bubble;
    // 상대의 일반 텍스트만 길게 눌러 신고할 수 있다.
    return Semantics(
      label: '상대 메시지, 길게 눌러 신고',
      child: GestureDetector(
        key: ValueKey('message-reportable-${msg.id}'),
        behavior: HitTestBehavior.opaque,
        onLongPress: () => _reportMessage(msg),
        child: bubble,
      ),
    );
  }

  Widget _buildConversationCoach() {
    if (!_hasMessages || _unmatched) return const SizedBox.shrink();
    return _ConversationCoachPanel(
      status: _tipsStatus,
      tips: _tips,
      errorKind: _tipsErrorKind,
      expanded: _showConversationTips,
      onRequest: () => unawaited(_requestConversationTips()),
      onRetry: () => unawaited(_requestConversationTips(forceRefresh: true)),
      onSelected: (message) => unawaited(_applySuggestion(message)),
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
    final canSend = !_sending;
    // 떠 있는 composer dock — 평평한 하단 입력줄이 아니라 라운드 서피스 +
    // 부드러운 shadow로 "가장 자주 쓰는 입력"이라는 위계를 준다.
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
        decoration: BoxDecoration(
          color: AppColors.surfacePrimary,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: AppColors.borderSubtle),
          boxShadow: AppShadows.card,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            ChatAppointmentButton(
              onPressed: _submittingAppointment ? null : _openAppointmentSheet,
            ),
            const SizedBox(width: 2),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: TextField(
                  controller: _textController,
                  focusNode: _inputFocusNode,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  onChanged: _onInputChanged,
                  onSubmitted: (_) => _send(),
                  style: const TextStyle(
                    fontSize: 15,
                    height: 1.4,
                    color: AppColors.textStrong,
                  ),
                  decoration: InputDecoration(
                    hintText: '메시지를 입력하세요',
                    hintStyle: const TextStyle(color: AppColors.textMuted),
                    filled: true,
                    fillColor: AppColors.surfaceSecondary,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 11,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: const BorderSide(
                        color: AppColors.brandPrimaryStrong,
                        width: 1.5,
                      ),
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            Semantics(
              button: true,
              label: '메시지 전송',
              child: SizedBox(
                width: 46,
                height: 46,
                child: IconButton.filled(
                  onPressed: canSend ? _send : null,
                  icon: const Icon(Icons.arrow_upward_rounded, size: 22),
                  style: IconButton.styleFrom(
                    backgroundColor: AppColors.brandPrimaryStrong,
                    foregroundColor: AppColors.onBrandPrimary,
                    disabledBackgroundColor: AppColors.canvasSubtle,
                    disabledForegroundColor: AppColors.textMuted,
                    shape: const CircleBorder(),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 메시지 영역 배경 — warmCanvas 위 상단에만 아주 옅은 mint/coral tonal wash와
/// 옅은 ConnectionMotif를 깔아, 단색 배경보다 따뜻하게 보이게 한다. 장식은
/// 스크린리더에서 제외하고 메시지 가독성을 우선한다.
class _ChatBackdrop extends StatelessWidget {
  final Widget child;
  const _ChatBackdrop({required this.child});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppColors.surfaceMintSoft, AppColors.warmCanvas],
          stops: [0, 0.28],
        ),
      ),
      child: Stack(
        children: [
          const Positioned(
            top: 12,
            right: -10,
            width: 96,
            height: 56,
            child: ExcludeSemantics(
              child: IgnorePointer(
                child: ConnectionMotif(strokeWidth: 1.4, opacity: 0.4),
              ),
            ),
          ),
          child,
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: AppColors.surfaceSecondary,
          borderRadius: BorderRadius.circular(AppRadius.surface),
          border: Border.all(color: AppColors.borderSubtle),
        ),
        child: const Row(
          children: [
            Icon(
              Icons.lock_outline_rounded,
              size: 18,
              color: AppColors.textMuted,
            ),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                '매칭이 해제되어 더 이상 대화할 수 없어요.',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textBody,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 안전 메뉴 항목 한 줄 — 아이콘 + 라벨. 항목마다 최소 높이는 PopupMenuItem이
/// 관리하고, 여기서는 색으로 안전/보호/종료 의미만 구분한다.
class _SafetyMenuRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color iconColor;
  final Color? labelColor;

  const _SafetyMenuRow({
    required this.icon,
    required this.label,
    required this.iconColor,
    this.labelColor,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 19, color: iconColor),
        const SizedBox(width: 12),
        Text(
          label,
          style: TextStyle(
            fontSize: 14.5,
            fontWeight: FontWeight.w600,
            color: labelColor ?? AppColors.textStrong,
          ),
        ),
      ],
    );
  }
}

/// 차단·매칭 해제 확인 다이얼로그의 공통 presentation.
///
/// 두 흐름 모두 작은 아이콘 + 제목 + 설명 + 취소/실행 구조를 쓰되, 아이콘 accent
/// 색으로 위험 정도를 구분한다(차단=danger, 매칭 해제=coral). Navigator 반환값은
/// 호출부가 `true`(실행) / `false`·`null`(취소)로 그대로 해석한다.
class _BoundaryConfirmDialog extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final Color iconBackground;
  final String title;
  final String description;
  final String confirmLabel;

  const _BoundaryConfirmDialog({
    required this.icon,
    required this.iconColor,
    required this.iconBackground,
    required this.title,
    required this.description,
    required this.confirmLabel,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surfacePrimary,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      icon: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: iconBackground,
          shape: BoxShape.circle,
        ),
        child: ExcludeSemantics(child: Icon(icon, size: 22, color: iconColor)),
      ),
      title: Text(
        title,
        textAlign: TextAlign.center,
        style: const TextStyle(
          fontSize: 19,
          fontWeight: FontWeight.w800,
          color: AppColors.textStrong,
        ),
      ),
      content: Text(
        description,
        textAlign: TextAlign.center,
        style: const TextStyle(
          fontSize: 13.5,
          height: 1.5,
          color: AppColors.textBody,
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(20, 4, 20, 18),
      actions: [
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => Navigator.pop(context, false),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.textBody,
                  side: const BorderSide(color: AppColors.borderStrong),
                  minimumSize: const Size.fromHeight(47),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.control),
                  ),
                ),
                child: const Text('취소'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton(
                onPressed: () => Navigator.pop(context, true),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.statusDanger,
                  foregroundColor: AppColors.surface,
                  minimumSize: const Size.fromHeight(47),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.control),
                  ),
                ),
                child: Text(
                  confirmLabel,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
            ),
          ],
        ),
      ],
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
            Icon(Icons.block_rounded, size: 54, color: AppColors.textMuted),
            SizedBox(height: 16),
            Text(
              '차단된 사용자와는 채팅할 수 없어요.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AppColors.textStrong,
              ),
            ),
            SizedBox(height: 8),
            Text(
              '차단 목록에서 해제하면 다시 대화할 수 있어요.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textBody),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final PublicProfile otherProfile;
  final Future<List<Icebreaker>> icebreakersFuture;
  final ValueChanged<String> onSelected;

  const _EmptyState({
    required this.otherProfile,
    required this.icebreakersFuture,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final photoUrl = otherProfile.photoUrls.isNotEmpty
        ? otherProfile.photoUrls.first
        : null;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 44, 20, 24),
      child: Column(
        children: [
          SizedBox(
            height: 96,
            child: Stack(
              alignment: Alignment.center,
              children: [
                const Positioned.fill(
                  child: ExcludeSemantics(
                    child: IgnorePointer(
                      child: ConnectionMotif(
                        opacity: 0.55,
                        primaryColor: AppColors.brandPrimary,
                        accentColor: AppColors.expressiveAccent,
                      ),
                    ),
                  ),
                ),
                Semantics(
                  image: true,
                  label: '${otherProfile.displayName} 프로필 사진',
                  child: Container(
                    width: 76,
                    height: 76,
                    decoration: BoxDecoration(
                      color: AppColors.surfacePrimary,
                      shape: BoxShape.circle,
                      border: Border.all(color: AppColors.borderSubtle),
                      boxShadow: AppShadows.card,
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: photoUrl == null
                        ? const Icon(
                            Icons.person_rounded,
                            size: 34,
                            color: AppColors.textMuted,
                          )
                        : Image.network(
                            photoUrl,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => const Icon(
                              Icons.person_rounded,
                              size: 34,
                              color: AppColors.textMuted,
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          const Text(
            '첫 메시지를 보내보세요',
            style: TextStyle(fontSize: 15, color: AppColors.textBody),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          _IcebreakerSection(future: icebreakersFuture, onSelected: onSelected),
        ],
      ),
    );
  }
}

/// draft가 있을 때 사용자가 고르는 동작.
enum _DraftAction { replace, append, cancel }

class _ConversationCoachPanel extends StatelessWidget {
  final ConversationHelperStatus status;
  final List<ConversationTip> tips;
  final ConversationTipsErrorKind? errorKind;
  final bool expanded;
  final VoidCallback onRequest;
  final VoidCallback onRetry;
  final ValueChanged<String> onSelected;

  const _ConversationCoachPanel({
    required this.status,
    required this.tips,
    required this.errorKind,
    required this.expanded,
    required this.onRequest,
    required this.onRetry,
    required this.onSelected,
  });

  String get _errorMessage {
    switch (errorKind) {
      case ConversationTipsErrorKind.rateLimited:
        return '요청이 많아요. 잠시 후 다시 시도해 주세요.';
      case ConversationTipsErrorKind.unusableChat:
        return '지금은 이 대화에서 추천을 쓸 수 없어요.';
      case ConversationTipsErrorKind.noMessages:
        return '대화가 시작되면 추천을 만들어 드릴게요.';
      default:
        return '추천 문장을 불러오지 못했어요. 잠시 후 다시 시도해 주세요.';
    }
  }

  Widget _body() {
    switch (status) {
      case ConversationHelperStatus.loading:
        return const _ConversationTipsLoading(
          key: Key('conversation-helper-loading'),
        );
      case ConversationHelperStatus.ready:
        return _ConversationTipsReady(
          key: const Key('conversation-helper-ready'),
          tips: tips,
          onRetry: onRetry,
          onSelected: onSelected,
        );
      case ConversationHelperStatus.rateLimited:
      case ConversationHelperStatus.unavailable:
      case ConversationHelperStatus.error:
        return _ConversationTipsError(
          key: const Key('conversation-helper-error'),
          message: _errorMessage,
          onRetry: onRetry,
        );
      case ConversationHelperStatus.idle:
        return const SizedBox.shrink();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: AppColors.surfaceMintSoft,
        borderRadius: BorderRadius.circular(AppRadius.surface),
        border: Border.all(
          color: AppColors.brandPrimary.withValues(alpha: 0.28),
        ),
      ),
      child: AnimatedSwitcher(
        duration: AppDurations.fast,
        child: expanded && status != ConversationHelperStatus.idle
            ? KeyedSubtree(
                key: const ValueKey('conversation-tips'),
                child: _body(),
              )
            : Align(
                key: const ValueKey('conversation-button'),
                alignment: Alignment.centerLeft,
                // premium accent로 "이건 AI가 돕는 기능"이라는 신호를 준다 —
                // 전송 버튼(primary)과 구분되게.
                child: TextButton.icon(
                  key: const Key('conversation-helper-button'),
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

class _ConversationTipsReady extends StatelessWidget {
  final List<ConversationTip> tips;
  final VoidCallback onRetry;
  final ValueChanged<String> onSelected;

  const _ConversationTipsReady({
    super.key,
    required this.tips,
    required this.onRetry,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
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
              key: const Key('conversation-helper-retry'),
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
            key: Key('conversation-suggestion-${tip.keySuffix}'),
            tip: tip,
            onTap: () => onSelected(tip.message),
          ),
        ),
      ],
    );
  }
}

class _ConversationTipsLoading extends StatelessWidget {
  const _ConversationTipsLoading({super.key});

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
  final String message;
  final VoidCallback onRetry;

  const _ConversationTipsError({
    super.key,
    required this.message,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            message,
            style: const TextStyle(
              fontSize: 14,
              color: AppColors.textSecondary,
            ),
          ),
        ),
        TextButton(
          key: const Key('conversation-helper-retry'),
          onPressed: onRetry,
          child: const Text('재시도'),
        ),
      ],
    );
  }
}

class _ConversationTipButton extends StatelessWidget {
  final ConversationTip tip;
  final VoidCallback onTap;

  const _ConversationTipButton({
    super.key,
    required this.tip,
    required this.onTap,
  });

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
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: AppColors.surfaceSecondary,
            borderRadius: BorderRadius.circular(AppRadius.chip),
          ),
          child: Text(
            _formatDate(date),
            style: const TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              color: AppColors.textMuted,
            ),
          ),
        ),
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
              constraints: BoxConstraints(
                maxWidth: MediaQuery.sizeOf(context).width * 0.78,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              decoration: BoxDecoration(
                // 내 버블: 시그니처 민트 fill + 다크 잉크 텍스트.
                // 상대 버블: 흰 서피스 + 옅은 보더. 둘 다 아주 약한 shadow로
                // warmCanvas 위에서 살짝 떠 보이게 한다.
                color: isMine ? AppColors.mint : AppColors.surfacePrimary,
                borderRadius: _radius,
                border: isMine
                    ? null
                    : Border.all(color: AppColors.borderSubtle),
                boxShadow: AppShadows.card,
              ),
              child: Text(
                message.text,
                style: TextStyle(
                  fontSize: 15,
                  color: isMine ? AppColors.onMint : AppColors.textStrong,
                  height: 1.48,
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
        style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
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
      padding: const EdgeInsets.only(left: 68, right: 16, bottom: 8),
      decoration: const BoxDecoration(
        color: AppColors.surfacePrimary,
        border: Border(bottom: BorderSide(color: AppColors.borderSubtle)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: isOnline ? AppColors.brandPrimary : AppColors.borderStrong,
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
                fontSize: 11.5,
                color: AppColors.textMuted,
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
