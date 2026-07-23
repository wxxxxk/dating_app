import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../models/match_model.dart';
import '../../models/public_profile.dart';
import '../../models/user_profile.dart';
import '../../services/auth/auth_service.dart';
import '../../services/chat/appointment_safety_service.dart';
import '../../services/chat/chat_presence_service.dart';
import '../../services/chat/chat_service.dart';
import '../../services/database/firestore_service.dart';
import '../../services/discovery/discovery_service.dart';
import '../../services/fortune/fortune_service.dart';
import '../../services/jelly/jelly_purchase_service.dart';
import '../../services/jelly/jelly_service.dart';
import '../../services/location/location_service.dart';
import '../../services/matches/matches_service.dart';
import '../../services/privacy/contact_avoidance_service.dart';
import '../../services/safety/safety_service.dart';
import '../../shared/widgets/premium_components.dart';
import '../chat/chat_screen.dart';
import '../jelly/jelly_shop_screen.dart';
import '../matches/widgets/match_celebration_overlay.dart';
import '../profile/user_profile_screen.dart';
import '../safety/report_sheet.dart';
import 'widgets/filter_sheet.dart';
import 'widgets/profile_card_content.dart';
import 'widgets/swipe_card.dart';

/// 디스커버리 (스와이프) 화면.
///
/// 카드 스택 UI로 프로필을 한 명씩 보여주고,
/// 드래그 또는 하단 버튼으로 LIKE / PASS 스와이프를 처리한다.
///
/// M4 매칭 흐름:
/// 1. like 스와이프 → recordSwipe 기록
/// 2. Cloud Function(onSwipeCreated)이 상호 like 판정 → matches/{matchId} 생성
/// 3. 1.5초 후 & 3.5초 후 매치 존재 여부를 폴링
/// 4. 매치 발견 시 MatchCelebrationOverlay 표시
class DiscoveryScreen extends StatefulWidget {
  final AuthService authService;
  final FirestoreService firestoreService;
  final DiscoveryService discoveryService;
  final MatchesService matchesService;
  final ChatService chatService;
  final ChatPresenceService presenceService;
  final AppointmentSafetyService appointmentSafetyService;
  final FortuneService fortuneService;
  final JellyService jellyService;
  final JellyPurchaseService jellyPurchaseService;
  final SafetyService safetyService;
  final ContactAvoidanceService contactAvoidanceService;

  const DiscoveryScreen({
    super.key,
    required this.authService,
    required this.firestoreService,
    required this.discoveryService,
    required this.matchesService,
    required this.chatService,
    required this.presenceService,
    required this.appointmentSafetyService,
    required this.fortuneService,
    required this.jellyService,
    required this.jellyPurchaseService,
    required this.safetyService,
    required this.contactAvoidanceService,
  });

  @override
  State<DiscoveryScreen> createState() => _DiscoveryScreenState();
}

class _DiscoveryScreenState extends State<DiscoveryScreen> {
  List<PublicProfile> _profiles = [];
  int _currentIndex = 0;
  bool _loading = true;
  String? _error;
  UserProfile? _currentUserProfile;
  UserLocation? _currentUserLocation;
  DiscoveryFilter _filter = const DiscoveryFilter();
  String _currentUserPhotoUrl = '';
  final _locationService = const LocationService();
  Timer? _boostTimer;
  // 지인 피하기(Phase 3-4A): pair 변경을 화면 수명 동안 구독해 즉시 반영한다.
  StreamSubscription<Set<String>>? _avoidedUidsSub;
  Set<String> _avoidedUids = {};
  Timer? _avoidanceReloadDebounce;
  _RewindCandidate? _rewindCandidate;
  bool _rewinding = false;
  String? _rewindEntryAction;
  int _rewindEntryToken = 0;

  // `GlobalKey<SwipeCardState>`로 현재 카드의 triggerSwipe()를 호출한다.
  final _swipeKey = GlobalKey<SwipeCardState>();

  @override
  void initState() {
    super.initState();
    _watchAvoidedUids();
    _loadDiscovery();
    _boostTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final boostUntil = _currentUserProfile?.boostUntil;
      if (boostUntil != null && boostUntil.isAfter(DateTime.now()) && mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _boostTimer?.cancel();
    _avoidanceReloadDebounce?.cancel();
    _avoidedUidsSub?.cancel();
    super.dispose();
  }

  // ── 데이터 로드 ────────────────────────────────────────────────────────────

  /// 지인 피하기 pair 상대 목록을 화면 수명 동안 구독한다.
  ///
  /// 새로 추가된 상대는 현재 카드 목록에서 즉시 빼고, 해제된 상대는 debounce 뒤
  /// 전체 재조회로 후보에 되돌린다. 구독 오류는 Discovery 전체를 막지 않는다.
  void _watchAvoidedUids() {
    final uid = widget.authService.currentUser?.uid;
    if (uid == null) return;
    _avoidedUidsSub = widget.contactAvoidanceService
        .watchAvoidedUids(uid)
        .listen(
          _onAvoidedUidsChanged,
          onError: (Object e) {
            if (kDebugMode) debugPrint('[Discovery] 지인 피하기 구독 실패: $e');
          },
        );
  }

  void _onAvoidedUidsChanged(Set<String> next) {
    if (!mounted) return;
    // 값이 실제로 바뀌지 않았으면 아무 것도 하지 않는다(불필요한 재조회 방지).
    if (setEquals(_avoidedUids, next)) return;

    final added = next.difference(_avoidedUids);
    final removed = _avoidedUids.difference(next);
    _avoidedUids = next;

    if (added.isNotEmpty) _removeAvoidedFromDeck(added);
    if (removed.isNotEmpty) _scheduleAvoidanceReload();
  }

  /// 새로 제외된 상대를 현재 덱에서 즉시 지운다. 보고 있던 카드가 사라져도
  /// 인덱스가 범위를 벗어나지 않도록 보정한다.
  void _removeAvoidedFromDeck(Set<String> added) {
    if (_profiles.isEmpty) return;
    final currentUid = _currentIndex < _profiles.length
        ? _profiles[_currentIndex].uid
        : null;
    final remaining = _profiles
        .where((profile) => !added.contains(profile.uid))
        .toList();
    if (remaining.length == _profiles.length) return;

    // 보고 있던 카드가 남아 있으면 그 카드를 계속 보여주고,
    // 제외됐다면 같은 자리(다음 유효 카드)로 넘어간다.
    var nextIndex = currentUid == null
        ? _currentIndex
        : remaining.indexWhere((profile) => profile.uid == currentUid);
    if (nextIndex < 0) {
      nextIndex = _currentIndex.clamp(
        0,
        remaining.isEmpty ? 0 : remaining.length,
      );
    }

    setState(() {
      _profiles = remaining;
      _currentIndex = remaining.isEmpty
          ? 0
          : nextIndex.clamp(0, remaining.length);
      // 되돌리기 후보가 제외 대상이면 함께 정리한다.
      if (_rewindCandidate != null &&
          added.contains(_rewindCandidate!.profile.uid)) {
        _rewindCandidate = null;
      }
    });
  }

  /// pair 해제는 후보 복원을 위해 전체 재조회가 필요하다. 연속 변경을 묶는다.
  void _scheduleAvoidanceReload() {
    _avoidanceReloadDebounce?.cancel();
    _avoidanceReloadDebounce = Timer(const Duration(milliseconds: 600), () {
      if (!mounted) return;
      _loadDiscovery();
    });
  }

  Future<void> _loadDiscovery() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final uid = widget.authService.currentUser?.uid;
      if (uid == null) return;
      final profile = await widget.firestoreService.getUserProfile(uid);
      final refreshedLocation = await _locationService
          .updateCurrentUserLocation(
            uid: uid,
            firestoreService: widget.firestoreService,
          );
      final currentLocation = refreshedLocation ?? profile?.location;
      final filter = profile?.discoveryFilter ?? const DiscoveryFilter();
      final blockedUids = await widget.safetyService.getBlockedRelationshipUids(
        uid,
      );
      // 지인 피하기(Phase 3-4) 상대는 차단 UID와 합쳐 후보 조회 단계에서 뺀다 —
      // 화면에 잠깐 보였다가 사라지는 flash를 만들지 않기 위해서다.
      // 최신 pair 집합은 _avoidedUidsSub가 계속 갱신한다.
      final profiles = await widget.discoveryService.getDiscoveryProfiles(
        currentUid: uid,
        currentLocation: currentLocation,
        filter: filter,
        excludedUids: {...blockedUids, ..._avoidedUids},
      );
      final photoUrls = profile?.photoUrls ?? const <String>[];
      if (mounted) {
        setState(() {
          _currentUserProfile = profile?.copyWith(location: currentLocation);
          _currentUserLocation = currentLocation;
          _filter = filter;
          _currentUserPhotoUrl = photoUrls.isNotEmpty ? photoUrls[0] : '';
          _profiles = profiles;
          _currentIndex = 0;
          _rewindCandidate = null;
          _rewinding = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ── 스와이프 처리 ──────────────────────────────────────────────────────────

  Future<void> _onSwiped(String targetUid, String action) async {
    final currentUid = widget.authService.currentUser?.uid;
    if (currentUid == null) return;
    if (_currentIndex >= _profiles.length) return;

    final swipedIndex = _currentIndex;
    final swipedProfile = _profiles[swipedIndex];

    if (action == 'superlike') {
      final spent = await widget.jellyService.spend(
        uid: currentUid,
        amount: JellyCosts.superlike,
        reason: 'superlike',
      );
      if (!spent) {
        _swipeKey.currentState?.resetPosition();
        _showJellyShortage(
          '슈퍼라이크에는 젤리 ${JellyCosts.superlike}개가 필요해요.',
          reasonIcon: Icons.star_rounded,
          requiredAmount: JellyCosts.superlike,
        );
        return;
      }
    }

    // 과금/검증이 끝난 뒤 카드와 Firestore 기록을 진행한다.
    setState(() {
      _currentIndex++;
      _rewindCandidate = (action == 'pass' || action == 'like')
          ? _RewindCandidate(
              profile: swipedProfile,
              previousIndex: swipedIndex,
              action: action,
            )
          : null;
    });
    _recordAndCheckMatch(
      currentUid: currentUid,
      targetUid: targetUid,
      action: action,
    );
  }

  Future<void> _recordAndCheckMatch({
    required String currentUid,
    required String targetUid,
    required String action,
  }) async {
    // 스와이프 기록 실패는 치명적 — 이후 매치 체크도 의미 없으므로 early return.
    try {
      await widget.discoveryService.recordSwipe(
        currentUid: currentUid,
        targetUid: targetUid,
        action: action,
      );
    } catch (e) {
      _debugLog('[Discovery] 스와이프 기록 실패: $e');
      if (mounted && _rewindCandidate?.profile.uid == targetUid) {
        setState(() => _rewindCandidate = null);
      }
      return;
    }

    if (action != 'like' && action != 'superlike') return;

    // 매치 폴링 실패는 치명적이지 않음 — 축하 오버레이가 안 뜰 뿐이다.
    // 가장 흔한 원인: firestore.rules의 matches 규칙이 콘솔에 미배포된 경우.
    try {
      await _pollForMatch(currentUid: currentUid, targetUid: targetUid);
    } catch (e) {
      _debugLog('[Discovery] 매치 확인 실패 (rules 미배포 가능성): $e');
    }
  }

  /// like 스와이프 후 Cloud Function이 matches 문서를 생성했는지 두 번 폴링한다.
  ///
  /// 1.5초 후 첫 번째 확인 (Cloud Function 웜 인스턴스 기준).
  /// 3.5초 후 두 번째 확인 (콜드 스타트 대비).
  Future<void> _pollForMatch({
    required String currentUid,
    required String targetUid,
  }) async {
    for (final delay in [AppDurations.emphasis, const Duration(seconds: 2)]) {
      await Future.delayed(delay);
      if (!mounted) return;
      final result = await widget.matchesService.checkForMatch(
        currentUid: currentUid,
        targetUid: targetUid,
      );
      if (result != null && mounted) {
        if (_rewindCandidate?.profile.uid == targetUid) {
          setState(() => _rewindCandidate = null);
        }
        _showCelebration(result);
        return;
      }
    }
  }

  void _showCelebration(MatchWithProfile match) {
    final uid = widget.authService.currentUser?.uid;
    if (uid != null) {
      widget.matchesService
          .markCelebrated(matchId: match.match.matchId, uid: uid)
          .catchError((e) {
            _debugLog('[Discovery] 매칭 축하 기록 실패: $e');
          });
    }
    showGeneralDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: AppColors.ink.withValues(alpha: 0),
      pageBuilder: (ctx, _, _) => MatchCelebrationOverlay(
        match: match,
        currentUserPhotoUrl: _currentUserPhotoUrl,
        onKeepSwiping: () => Navigator.pop(ctx),
        onChat: () => _openChatFromCelebration(ctx, match),
      ),
    );
  }

  void _openChatFromCelebration(
    BuildContext overlayContext,
    MatchWithProfile match,
  ) {
    final uid = widget.authService.currentUser?.uid;
    if (uid == null) return;
    // 오버레이(dialog)를 먼저 닫고, 그 위에 쌓이지 않도록 원래 화면 스택에서 push한다.
    Navigator.pop(overlayContext);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          matchId: match.match.matchId,
          otherProfile: match.otherProfile,
          currentUid: uid,
          chatService: widget.chatService,
          presenceService: widget.presenceService,
          appointmentSafetyService: widget.appointmentSafetyService,
          fortuneService: widget.fortuneService,
          matchesService: widget.matchesService,
          safetyService: widget.safetyService,
        ),
      ),
    );
  }

  Future<void> _reportProfile(PublicProfile profile) async {
    final uid = widget.authService.currentUser?.uid;
    if (uid == null) return;
    final submission = await showReportSheet(context);
    if (submission == null) return;

    try {
      await widget.safetyService.reportUser(
        reporterUid: uid,
        reportedUid: profile.uid,
        reason: submission.reason,
        detail: submission.detail,
      );
      if (submission.blockUser) {
        await widget.safetyService.blockUser(
          currentUid: uid,
          blockedUid: profile.uid,
        );
        _hideCurrentProfile(profile.uid);
      }
      if (!mounted) return;
      _showSnack(submission.blockUser ? '신고가 접수되고 차단했어요.' : '신고가 접수되었어요.');
    } catch (e) {
      _debugLog('[Safety] 신고 실패 reportedUid=${profile.uid} error=$e');
      if (mounted) _showSnack('신고에 실패했어요. 잠시 후 다시 시도해주세요.');
    }
  }

  Future<void> _blockProfile(PublicProfile profile) async {
    final uid = widget.authService.currentUser?.uid;
    if (uid == null) return;
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
        currentUid: uid,
        blockedUid: profile.uid,
      );
      _hideCurrentProfile(profile.uid);
      if (mounted) _showSnack('차단했어요.');
    } catch (e) {
      _debugLog('[Safety] 차단 실패 blockedUid=${profile.uid} error=$e');
      if (mounted) _showSnack('차단에 실패했어요. 잠시 후 다시 시도해주세요.');
    }
  }

  void _hideCurrentProfile(String profileUid) {
    if (!mounted) return;
    final current = _currentIndex < _profiles.length
        ? _profiles[_currentIndex]
        : null;
    if (current?.uid != profileUid) return;
    setState(() => _currentIndex++);
  }

  void _openProfile(PublicProfile profile) {
    final uid = widget.authService.currentUser?.uid;
    if (uid == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => UserProfileScreen(
          currentUid: uid,
          initialProfile: profile,
          currentLocation: _currentUserLocation,
          firestoreService: widget.firestoreService,
          safetyService: widget.safetyService,
        ),
      ),
    );
  }

  // ── 하단 버튼 탭 ───────────────────────────────────────────────────────────

  void _handleButtonSwipe(String action) {
    _swipeKey.currentState?.triggerSwipe(action);
  }

  Future<void> _handleRewind() async {
    final uid = widget.authService.currentUser?.uid;
    final candidate = _rewindCandidate;
    if (uid == null || candidate == null || _rewinding) return;

    setState(() => _rewinding = true);
    try {
      final result = await widget.jellyService.rewindSwipe(
        uid: uid,
        targetUid: candidate.profile.uid,
      );
      if (!mounted) return;

      switch (result) {
        case RewindSwipeResult.success:
          setState(() {
            final restoreIndex = candidate.previousIndex
                .clamp(0, _profiles.length)
                .toInt();
            _profiles.removeWhere(
              (profile) => profile.uid == candidate.profile.uid,
            );
            _profiles.insert(restoreIndex, candidate.profile);
            _currentIndex = restoreIndex;
            _rewindCandidate = null;
            _rewindEntryAction = candidate.action;
            _rewindEntryToken++;
          });
          _showSnack('방금 넘긴 카드를 되돌렸어요.');
          return;
        case RewindSwipeResult.insufficientJelly:
          await _showJellyShortage(
            '되돌리기에는 젤리 ${JellyCosts.rewind}개가 필요해요.',
            reasonIcon: Icons.replay_rounded,
            requiredAmount: JellyCosts.rewind,
          );
          return;
        case RewindSwipeResult.alreadyMatched:
          setState(() => _rewindCandidate = null);
          _showSnack('이미 매칭된 상대는 되돌릴 수 없어요.');
          return;
        case RewindSwipeResult.unavailable:
          setState(() => _rewindCandidate = null);
          _showSnack('되돌릴 수 있는 카드가 없어요.');
          return;
      }
    } catch (e) {
      _debugLog('[Discovery] 되돌리기 실패: $e');
      if (mounted) _showSnack('되돌리기에 실패했어요. 잠시 후 다시 시도해주세요.');
    } finally {
      if (mounted) setState(() => _rewinding = false);
    }
  }

  Future<void> _openFilterSheet() async {
    final uid = widget.authService.currentUser?.uid;
    if (uid == null) return;
    final result = await showModalBottomSheet<DiscoveryFilter>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.background,
      builder: (_) => DiscoveryFilterSheet(
        initialFilter: _filter,
        hasLocation: _currentUserLocation != null,
        onRetryLocation: _retryLocationForFilter,
        myProfile: _currentUserProfile,
      ),
    );
    if (result == null) return;

    await widget.firestoreService.updateDiscoveryFilter(uid, result);
    if (!mounted) return;
    setState(() => _filter = result);
    await _loadDiscovery();
  }

  /// 필터 시트의 "위치 다시 확인" 버튼에서 호출한다.
  /// 위치를 다시 가져와 화면 상태(_currentUserLocation)도 함께 갱신한다.
  Future<bool> _retryLocationForFilter() async {
    final uid = widget.authService.currentUser?.uid;
    if (uid == null) return false;
    final location = await _locationService.updateCurrentUserLocation(
      uid: uid,
      firestoreService: widget.firestoreService,
    );
    if (mounted && location != null) {
      setState(() => _currentUserLocation = location);
    }
    return location != null;
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
      );
  }

  void _debugLog(String message) {
    if (kDebugMode) {
      debugPrint(message);
    }
  }

  Future<void> _showJellyShortage(
    String message, {
    IconData reasonIcon = Icons.local_fire_department_rounded,
    int? requiredAmount,
  }) async {
    final uid = widget.authService.currentUser?.uid;
    if (uid == null) return;
    final goShop = await showDialog<bool>(
      context: context,
      builder: (ctx) => _JellyShortageDialog(
        message: message,
        reasonIcon: reasonIcon,
        requiredAmount: requiredAmount,
      ),
    );
    if (goShop == true && mounted) {
      await openJellyShop(
        context: context,
        currentUid: uid,
        jellyService: widget.jellyService,
        jellyPurchaseService: widget.jellyPurchaseService,
      );
    }
  }

  Future<void> _activateBoost() async {
    final uid = widget.authService.currentUser?.uid;
    if (uid == null) return;
    final boostUntil = _currentUserProfile?.boostUntil;
    if (boostUntil != null && boostUntil.isAfter(DateTime.now())) return;

    final ok = await widget.jellyService.activateBoost(uid);
    if (!ok) {
      await _showJellyShortage(
        '부스트에는 젤리 ${JellyCosts.boost}개가 필요해요.',
        reasonIcon: Icons.bolt_rounded,
        requiredAmount: JellyCosts.boost,
      );
      return;
    }
    final nextBoostUntil = DateTime.now().add(JellyCosts.boostDuration);
    if (!mounted) return;
    setState(() {
      _currentUserProfile = _currentUserProfile?.copyWith(
        boostUntil: nextBoostUntil,
      );
    });
    _showSnack('30분 부스트가 시작됐어요.');
    await _loadDiscovery();
  }

  String? _boostRemainingLabel() {
    final boostUntil = _currentUserProfile?.boostUntil;
    if (boostUntil == null) return null;
    final remaining = boostUntil.difference(DateTime.now());
    if (remaining.isNegative) return null;
    final minutes = remaining.inMinutes.toString().padLeft(2, '0');
    final seconds = (remaining.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  void _handleMoreAction(String value) {
    switch (value) {
      case 'refresh':
        if (!_loading) _loadDiscovery();
        return;
    }
  }

  // ── 빌드 ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final boostLabel = _boostRemainingLabel();
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        titleSpacing: 20,
        title: const Text(
          '둘러보기',
          style: TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 21,
            color: AppColors.textStrong,
            letterSpacing: -0.2,
          ),
        ),
        backgroundColor: AppColors.background,
        foregroundColor: AppColors.textStrong,
        elevation: 0,
        actions: [
          if (widget.authService.currentUser?.uid != null)
            JellyBalanceButton(
              currentUid: widget.authService.currentUser!.uid,
              jellyService: widget.jellyService,
              jellyPurchaseService: widget.jellyPurchaseService,
              foregroundColor: AppColors.matchPrimary,
            ),
          _BoostAction(
            remainingLabel: boostLabel,
            enabled: !_loading,
            onPressed: _activateBoost,
          ),
          _FilterAction(
            active: _filter.hasActiveFilters,
            enabled: !_loading,
            onPressed: _openFilterSheet,
          ),
          PopupMenuButton<String>(
            tooltip: '더보기',
            onSelected: _handleMoreAction,
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'refresh',
                child: Row(
                  children: [
                    Icon(Icons.refresh_rounded, size: 20),
                    SizedBox(width: 10),
                    Text('새로고침'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return _buildLoading();
    }

    if (_error != null) {
      return _buildError();
    }

    final remaining = _profiles.length - _currentIndex;

    if (remaining <= 0) {
      return _buildEmptyState();
    }

    return Column(
      children: [
        Expanded(child: _buildCardStack(remaining)),
        _buildActionButtons(),
      ],
    );
  }

  /// 로딩 중에도 최종 레이아웃(카드 + dock)의 골격을 유지해 화면이 갑자기
  /// 바뀌지 않게 한다. shimmer 패키지 없이 정적 스켈레톤 + 작은 spinner만 쓴다.
  Widget _buildLoading() {
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
            child: Container(
              decoration: BoxDecoration(
                color: AppColors.surfaceSecondary,
                borderRadius: BorderRadius.circular(AppRadius.hero),
                border: Border.all(color: AppColors.borderSubtle),
              ),
              child: const Center(
                child: SizedBox(
                  width: 26,
                  height: 26,
                  child: CircularProgressIndicator(strokeWidth: 2.4),
                ),
              ),
            ),
          ),
        ),
        const _DockPlaceholder(),
      ],
    );
  }

  Widget _buildCardStack(int remaining) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
      child: Stack(
        alignment: Alignment.topCenter,
        children: [
          // 다음 카드 — 뒤에서 아주 살짝만 보이게(깊이감만, 축소감 없이).
          if (remaining >= 2)
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Transform.scale(
                  scale: 0.98,
                  alignment: Alignment.topCenter,
                  child: PremiumProfileImageCard(
                    softFrame: true,
                    child: ProfileCardContent(
                      profile: _profiles[_currentIndex + 1],
                      currentUserLocation: _currentUserLocation,
                    ),
                  ),
                ),
              ),
            ),

          // 현재 카드 (드래그 가능)
          // profileUid를 전달해야 SwipeCard.didUpdateWidget에서 카드 교체를
          // 감지하고 _offset을 Offset.zero로 초기화한다.
          // 이 초기화가 없으면 이전 카드의 fly-off 위치가 남아 잔상이 생긴다.
          Positioned.fill(
            child: TweenAnimationBuilder<double>(
              key: ValueKey(_profiles[_currentIndex].uid),
              tween: Tween(begin: 0, end: 1),
              duration: AppDurations.base,
              curve: AppCurves.standard,
              builder: (context, value, child) => Opacity(
                opacity: value,
                child: Transform.translate(
                  offset: Offset(0, 14 * (1 - value)),
                  child: child,
                ),
              ),
              child: SwipeCard(
                key: _swipeKey,
                profileUid: _profiles[_currentIndex].uid,
                rewindEntryAction: _rewindEntryAction,
                rewindEntryToken: _rewindEntryToken,
                onSwiped: (action) =>
                    _onSwiped(_profiles[_currentIndex].uid, action),
                child: PremiumProfileImageCard(
                  softFrame: true,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ProfileCardContent(
                        profile: _profiles[_currentIndex],
                        currentUserLocation: _currentUserLocation,
                        onProfileTap: () =>
                            _openProfile(_profiles[_currentIndex]),
                      ),
                      Positioned(
                        top: 12,
                        right: 12,
                        child: _SafetyMenuButton(
                          onReport: () =>
                              _reportProfile(_profiles[_currentIndex]),
                          onBlock: () =>
                              _blockProfile(_profiles[_currentIndex]),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButtons() {
    final canRewind = _rewindCandidate != null && !_rewinding;
    // 되돌리기·넘기기·좋아요·슈퍼라이크를 하나의 dock으로 묶는다.
    // 넘기기/좋아요는 label 포함 pill로 가장 빠르게 구분되고, 되돌리기와
    // 슈퍼라이크는 compact 보조 버튼으로 위계를 낮춘다.
    return _DiscoveryActionDock(
      onRewind: canRewind ? _handleRewind : null,
      onPass: () => _handleButtonSwipe('pass'),
      onLike: () => _handleButtonSwipe('like'),
      onSuperlike: () => _handleButtonSwipe('superlike'),
    );
  }

  Widget _buildEmptyState() {
    // 큰 흰 카드 대신 warm canvas 위에 절제된 motif + 문구 + 액션만 둔다.
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(32, 24, 32, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 84,
              height: 84,
              decoration: const BoxDecoration(
                color: AppColors.surfaceMintSoft,
                shape: BoxShape.circle,
              ),
              child: Icon(
                _filter.hasActiveFilters
                    ? Icons.tune_rounded
                    : Icons.travel_explore_rounded,
                size: 38,
                color: AppColors.matchPrimary,
              ),
            ),
            const SizedBox(height: 22),
            Text(
              _filter.hasActiveFilters ? '필터로 인해 볼 사람이 없어요' : '지금은 새로운 사람이 없어요',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w800,
                color: AppColors.textStrong,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _filter.hasActiveFilters
                  ? '나이·거리·성별 조건을 조금 완화해보세요.'
                  : '잠시 후 다시 확인하면\n새로운 인연이 나타날 수 있어요.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 14,
                color: AppColors.textBody,
                height: 1.6,
              ),
            ),
            if (_currentUserLocation == null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: AppColors.statusWarningSoft,
                  borderRadius: BorderRadius.circular(AppRadius.control),
                  border: Border.all(
                    color: AppColors.statusWarning.withValues(alpha: 0.3),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.location_off_rounded,
                      size: 16,
                      color: AppColors.statusWarning,
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        '현재 위치를 불러오지 못해 거리 필터가 적용되지 않았어요.',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.textBody,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 26),
            if (_filter.hasActiveFilters) ...[
              OutlinedButton.icon(
                onPressed: _openFilterSheet,
                icon: const Icon(Icons.tune_rounded),
                label: const Text('필터 조정하기'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.mintDeep,
                  side: const BorderSide(color: AppColors.mintDeep),
                ),
              ),
              const SizedBox(height: 10),
            ],
            FilledButton.icon(
              onPressed: _loadDiscovery,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('새로고침'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildError() {
    // 원인(_error)은 사용자에게 노출하지 않고 안전한 안내 문구만 보여준다.
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: const BoxDecoration(
                color: AppColors.surfaceSecondary,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.wifi_off_rounded,
                size: 32,
                color: AppColors.textBody,
              ),
            ),
            const SizedBox(height: 18),
            const Text(
              '불러오기에 실패했어요',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AppColors.textStrong,
              ),
            ),
            const SizedBox(height: 20),
            OutlinedButton(
              onPressed: _loadDiscovery,
              child: const Text('다시 시도'),
            ),
          ],
        ),
      ),
    );
  }
}

class _RewindCandidate {
  final PublicProfile profile;
  final int previousIndex;
  final String action;

  const _RewindCandidate({
    required this.profile,
    required this.previousIndex,
    required this.action,
  });
}

/// AppBar 부스트 진입. 비활성은 compact neutral icon, 활성은 bolt + MM:SS pill.
/// onPressed는 기존 _activateBoost로 고정 — 활성 중이면 내부에서 no-op 처리된다.
class _BoostAction extends StatelessWidget {
  final String? remainingLabel;
  final bool enabled;
  final VoidCallback onPressed;

  const _BoostAction({
    required this.remainingLabel,
    required this.enabled,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final label = remainingLabel;
    if (label == null) {
      return IconButton(
        onPressed: enabled ? onPressed : null,
        icon: const Icon(Icons.flash_on_rounded, color: AppColors.textBody),
        tooltip: '부스트',
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      child: Tooltip(
        message: '부스트 남은 시간 $label',
        child: Material(
          color: AppColors.surfaceMintSoft,
          borderRadius: BorderRadius.circular(AppRadius.chip),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: enabled ? onPressed : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.flash_on_rounded,
                    size: 16,
                    color: AppColors.matchPrimary,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    label,
                    style: const TextStyle(
                      color: AppColors.matchPrimary,
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                      height: 1,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// AppBar 필터 진입. 활성 필터가 있으면 tonal 배경 + 작은 dot(색상만으로 상태를
/// 전달하지 않도록)으로 표시한다. callback·tooltip은 유지한다.
class _FilterAction extends StatelessWidget {
  final bool active;
  final bool enabled;
  final VoidCallback onPressed;

  const _FilterAction({
    required this.active,
    required this.enabled,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final button = IconButton(
      onPressed: enabled ? onPressed : null,
      tooltip: '필터',
      icon: Icon(
        Icons.filter_alt_rounded,
        color: active ? AppColors.matchPrimary : AppColors.textBody,
      ),
      style: active
          ? IconButton.styleFrom(backgroundColor: AppColors.surfaceMintSoft)
          : null,
    );
    if (!active) return button;
    return Stack(
      alignment: Alignment.center,
      children: [
        button,
        Positioned(
          top: 9,
          right: 7,
          child: Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: AppColors.matchPrimary,
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.background, width: 1.5),
            ),
          ),
        ),
      ],
    );
  }
}

/// 하단 액션 dock — 되돌리기 · 넘기기 · 좋아요 · 슈퍼라이크를 한 줄로 묶는다.
class _DiscoveryActionDock extends StatelessWidget {
  final VoidCallback? onRewind;
  final VoidCallback onPass;
  final VoidCallback onLike;
  final VoidCallback onSuperlike;

  const _DiscoveryActionDock({
    required this.onRewind,
    required this.onPass,
    required this.onLike,
    required this.onSuperlike,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
        child: Container(
          padding: const EdgeInsets.all(7),
          decoration: BoxDecoration(
            color: AppColors.surfacePrimary,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: AppColors.borderSubtle),
            boxShadow: AppShadows.card,
          ),
          child: Row(
            children: [
              _DockCircleButton(
                icon: Icons.undo_rounded,
                tooltip: '되돌리기',
                color: AppColors.textBody,
                onPressed: onRewind,
              ),
              const SizedBox(width: 7),
              Expanded(
                child: _DockPillButton(
                  icon: Icons.close_rounded,
                  label: '넘기기',
                  tooltip: '패스',
                  filled: false,
                  onPressed: onPass,
                ),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: _DockPillButton(
                  icon: Icons.favorite_rounded,
                  label: '좋아요',
                  tooltip: '좋아요',
                  filled: true,
                  onPressed: onLike,
                ),
              ),
              const SizedBox(width: 7),
              _DockCircleButton(
                icon: Icons.star_rounded,
                tooltip: '슈퍼라이크',
                color: AppColors.water,
                onPressed: onSuperlike,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 되돌리기·슈퍼라이크용 compact 원형 버튼(보조 action). 48px tap target.
class _DockCircleButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final Color color;
  final VoidCallback? onPressed;

  const _DockCircleButton({
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final fg = enabled ? color : AppColors.textMuted.withValues(alpha: 0.5);
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        enabled: enabled,
        label: tooltip,
        child: SizedBox(
          width: 48,
          height: 52,
          child: Material(
            color: AppColors.surfaceSecondary,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onPressed,
              child: Center(child: Icon(icon, color: fg, size: 22)),
            ),
          ),
        ),
      ),
    );
  }
}

/// 넘기기(neutral) · 좋아요(mint filled) label pill. 가장 빠르게 구분되는 주 action.
class _DockPillButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final String tooltip;
  final bool filled;
  final VoidCallback onPressed;

  const _DockPillButton({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.filled,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    // 좋아요는 비비드 민트 fill + onMint 텍스트(디자인 시스템 규칙). 넘기기는
    // 빨강 배경 대신 중립 surface로 두어 화면이 경고처럼 보이지 않게 한다.
    final bg = filled ? AppColors.mint : AppColors.surfaceSecondary;
    final fg = filled ? AppColors.onMint : AppColors.textStrong;
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        height: 52,
        child: Material(
          color: bg,
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: 19, color: fg),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: fg,
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 로딩 중 dock 자리를 지키는 정적 placeholder(레이아웃 shift 방지용).
class _DockPlaceholder extends StatelessWidget {
  const _DockPlaceholder();

  @override
  Widget build(BuildContext context) {
    Widget block({double? width, bool expand = false}) {
      final box = Container(
        height: 52,
        width: width,
        decoration: BoxDecoration(
          color: AppColors.canvasSubtle,
          borderRadius: BorderRadius.circular(16),
        ),
      );
      return expand ? Expanded(child: box) : box;
    }

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
        child: Container(
          padding: const EdgeInsets.all(7),
          decoration: BoxDecoration(
            color: AppColors.surfacePrimary,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: AppColors.borderSubtle),
            boxShadow: AppShadows.card,
          ),
          child: Row(
            children: [
              const SizedBox(
                width: 48,
                height: 52,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: AppColors.canvasSubtle,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              const SizedBox(width: 7),
              block(expand: true),
              const SizedBox(width: 7),
              block(expand: true),
              const SizedBox(width: 7),
              const SizedBox(
                width: 48,
                height: 52,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: AppColors.canvasSubtle,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 젤리 부족 안내(슈퍼라이크·되돌리기·부스트 공용). 오류가 아니라 "필요한
/// 리소스 안내"로 보이도록 danger 대신 pale mint 톤을 쓴다. [message]는 각
/// 기능이 넘기는 기존 문구를 그대로 쓰고, [reasonIcon]으로 어떤 기능인지만
/// 힌트하며, [requiredAmount]가 있으면 필요한 젤리 수를 강조한다.
/// Navigator.pop(true=충전하기 / false=닫기) 계약은 호출부가 그대로 해석한다.
class _JellyShortageDialog extends StatelessWidget {
  final String message;
  final IconData reasonIcon;
  final int? requiredAmount;

  const _JellyShortageDialog({
    required this.message,
    required this.reasonIcon,
    required this.requiredAmount,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surfacePrimary,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      icon: Container(
        width: 48,
        height: 48,
        decoration: const BoxDecoration(
          color: AppColors.surfaceMintSoft,
          shape: BoxShape.circle,
        ),
        child: ExcludeSemantics(
          child: Icon(reasonIcon, size: 24, color: AppColors.mintDeep),
        ),
      ),
      title: const Text(
        '젤리가 부족해요',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w800,
          color: AppColors.textStrong,
        ),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 14,
              height: 1.5,
              color: AppColors.textBody,
            ),
          ),
          if (requiredAmount != null) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              decoration: BoxDecoration(
                color: AppColors.surfaceMintSoft,
                borderRadius: BorderRadius.circular(AppRadius.chip),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const ExcludeSemantics(
                    child: Icon(
                      Icons.local_fire_department_rounded,
                      size: 16,
                      color: AppColors.mintDeep,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '필요한 젤리 $requiredAmount개',
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w800,
                      color: AppColors.mintDeep,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
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
                  minimumSize: const Size.fromHeight(50),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.control),
                  ),
                ),
                child: const Text('닫기'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton(
                onPressed: () => Navigator.pop(context, true),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(50),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.control),
                  ),
                ),
                child: const Text(
                  '충전하기',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _SafetyMenuButton extends StatelessWidget {
  final VoidCallback onReport;
  final VoidCallback onBlock;

  const _SafetyMenuButton({required this.onReport, required this.onBlock});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.ink.withValues(alpha: 0.28),
      shape: const CircleBorder(),
      child: PopupMenuButton<String>(
        icon: const Icon(Icons.more_vert_rounded, color: AppColors.surface),
        tooltip: '안전 메뉴',
        color: AppColors.background,
        onSelected: (value) {
          if (value == 'report') onReport();
          if (value == 'block') onBlock();
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'report', child: Text('신고하기')),
          PopupMenuItem(value: 'block', child: Text('차단하기')),
        ],
      ),
    );
  }
}
