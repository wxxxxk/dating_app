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
      nextIndex = _currentIndex.clamp(0, remaining.isEmpty ? 0 : remaining.length);
    }

    setState(() {
      _profiles = remaining;
      _currentIndex = remaining.isEmpty ? 0 : nextIndex.clamp(0, remaining.length);
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
        _showJellyShortage('슈퍼라이크에는 젤리 ${JellyCosts.superlike}개가 필요해요.');
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
          await _showJellyShortage('되돌리기에는 젤리 ${JellyCosts.rewind}개가 필요해요.');
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

  Future<void> _showJellyShortage(String message) async {
    final uid = widget.authService.currentUser?.uid;
    if (uid == null) return;
    final goShop = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('젤리가 부족해요'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('닫기'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('충전하기'),
          ),
        ],
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
      await _showJellyShortage('부스트에는 젤리 ${JellyCosts.boost}개가 필요해요.');
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
        title: const Text(
          '둘러보기',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: AppColors.background,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        actions: [
          if (widget.authService.currentUser?.uid != null)
            JellyBalanceButton(
              currentUid: widget.authService.currentUser!.uid,
              jellyService: widget.jellyService,
              jellyPurchaseService: widget.jellyPurchaseService,
              foregroundColor: AppColors.matchPrimary,
            ),
          IconButton(
            onPressed: _loading ? null : _activateBoost,
            icon: Icon(
              Icons.flash_on_rounded,
              // 부스트는 젤리로 사는 프리미엄 기능이라 활성 상태는
              // matchPrimary(premium green)로 표시한다.
              color: boostLabel == null ? null : AppColors.matchPrimary,
            ),
            tooltip: boostLabel == null ? '부스트' : '부스트 남은 시간 $boostLabel',
          ),
          IconButton(
            icon: Icon(
              _filter.hasActiveFilters
                  ? Icons.filter_alt_rounded
                  : Icons.filter_alt_rounded,
            ),
            tooltip: '필터',
            onPressed: _loading ? null : _openFilterSheet,
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
      return const Center(child: CircularProgressIndicator());
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
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _buildCardStack(int remaining) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Stack(
        alignment: Alignment.topCenter,
        children: [
          // 다음 카드 — 뒤에 살짝 보임 (스케일 + 수직 오프셋으로 깊이감)
          if (remaining >= 2)
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Transform.scale(
                  scale: 0.95,
                  alignment: Alignment.topCenter,
                  child: PremiumProfileImageCard(
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
                  glow: true,
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // REWIND 버튼 — 세션 내 직전 pass/like 한 번만 되돌린다.
          PremiumActionCircleButton(
            icon: Icons.undo_rounded,
            color: AppColors.textSecondary,
            size: 50,
            onPressed: canRewind ? _handleRewind : null,
            tooltip: '되돌리기',
          ),
          // PASS 버튼
          PremiumActionCircleButton(
            icon: Icons.close_rounded,
            color: AppColors.error,
            size: 56,
            onPressed: () => _handleButtonSwipe('pass'),
            tooltip: '패스',
          ),
          // SUPER LIKE 버튼 — like(민트)와 구분되는 딥 블루(water) 프리미엄 톤.
          // 추후 결제/일일제한 연동: 지금은 발표용으로 무제한 허용한다.
          PremiumActionCircleButton(
            icon: Icons.star_rounded,
            color: AppColors.water,
            size: 60,
            onPressed: () => _handleButtonSwipe('superlike'),
            tooltip: '슈퍼라이크',
          ),
          // LIKE 버튼 — 시그니처 민트. 이 화면의 대표 긍정 액션.
          PremiumActionCircleButton(
            icon: Icons.favorite_rounded,
            color: AppColors.mint,
            size: 64,
            onPressed: () => _handleButtonSwipe('like'),
            tooltip: '좋아요',
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Container(
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(AppRadius.hero),
            border: Border.all(color: AppColors.border),
            boxShadow: AppShadows.card,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.search_off_rounded,
                size: 72,
                color: AppColors.textSecondary,
              ),
              const SizedBox(height: 20),
              Text(
                _filter.hasActiveFilters
                    ? '필터로 인해 볼 사람이 없어요'
                    : '지금은 새로운 사람이 없어요',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _filter.hasActiveFilters
                    ? '나이·거리·성별 조건을 조금 완화해보세요.'
                    : '잠시 후 다시 확인하면\n새로운 인연이 나타날 수 있어요.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: AppColors.textSecondary,
                  height: 1.6,
                ),
              ),
              if (_currentUserLocation == null) ...[
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.error.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(AppRadius.button),
                    border: Border.all(
                      color: AppColors.error.withValues(alpha: 0.24),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.location_off_rounded,
                        size: 16,
                        color: AppColors.error,
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          '현재 위치를 불러오지 못해 거리 필터가 적용되지 않았어요.',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppColors.textPrimary.withValues(
                              alpha: 0.85,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 28),
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
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.wifi_off_rounded,
              size: 56,
              color: AppColors.textSecondary,
            ),
            const SizedBox(height: 16),
            const Text(
              '불러오기에 실패했어요',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
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
