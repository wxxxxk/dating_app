import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../dev/dummy_data_service.dart'; // 개발용 — 출시 전 제거
import '../../models/match_model.dart';
import '../../models/user_profile.dart';
import '../../services/auth/auth_service.dart';
import '../../services/chat/chat_service.dart';
import '../../services/database/firestore_service.dart';
import '../../services/discovery/discovery_service.dart';
import '../../services/fortune/fortune_service.dart';
import '../../services/jelly/jelly_purchase_service.dart';
import '../../services/jelly/jelly_service.dart';
import '../../services/location/location_service.dart';
import '../../services/matches/matches_service.dart';
import '../../services/profile/profile_insight_service.dart';
import '../../services/safety/safety_service.dart';
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
  final FortuneService fortuneService;
  final JellyService jellyService;
  final JellyPurchaseService jellyPurchaseService;
  final SafetyService safetyService;
  final ProfileInsightService profileInsightService;

  const DiscoveryScreen({
    super.key,
    required this.authService,
    required this.firestoreService,
    required this.discoveryService,
    required this.matchesService,
    required this.chatService,
    required this.fortuneService,
    required this.jellyService,
    required this.jellyPurchaseService,
    required this.safetyService,
    required this.profileInsightService,
  });

  @override
  State<DiscoveryScreen> createState() => _DiscoveryScreenState();
}

class _DiscoveryScreenState extends State<DiscoveryScreen> {
  List<UserProfile> _profiles = [];
  int _currentIndex = 0;
  bool _loading = true;
  String? _error;
  UserProfile? _currentUserProfile;
  UserLocation? _currentUserLocation;
  DiscoveryFilter _filter = const DiscoveryFilter();
  String _currentUserPhotoUrl = '';
  final _locationService = const LocationService();
  Timer? _boostTimer;
  _RewindCandidate? _rewindCandidate;
  bool _rewinding = false;

  // `GlobalKey<SwipeCardState>`로 현재 카드의 triggerSwipe()를 호출한다.
  final _swipeKey = GlobalKey<SwipeCardState>();

  @override
  void initState() {
    super.initState();
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
    super.dispose();
  }

  // ── 데이터 로드 ────────────────────────────────────────────────────────────

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
      final profiles = await widget.discoveryService.getDiscoveryProfiles(
        currentUid: uid,
        currentLocation: currentLocation,
        filter: filter,
        excludedUids: blockedUids,
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
          ? _RewindCandidate(profile: swipedProfile, previousIndex: swipedIndex)
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
          fortuneService: widget.fortuneService,
          safetyService: widget.safetyService,
        ),
      ),
    );
  }

  Future<void> _reportProfile(UserProfile profile) async {
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

  Future<void> _blockProfile(UserProfile profile) async {
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

  void _openProfile(UserProfile profile) {
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
          profileInsightService: widget.profileInsightService,
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
      ),
    );
    if (result == null) return;

    await widget.firestoreService.updateDiscoveryFilter(uid, result);
    if (!mounted) return;
    setState(() => _filter = result);
    await _loadDiscovery();
  }

  // ── 더미 유저 생성 (개발용 — 출시 전 제거) ────────────────────────────────

  Future<void> _generateDummies() async {
    final uid = widget.authService.currentUser?.uid;
    if (uid == null) return;
    final service = DummyDataService(firestoreService: widget.firestoreService);
    final count = await service.generateDummies(currentUid: uid);
    if (!mounted) return;
    if (count == 0) {
      _showSnack('더미 유저가 이미 존재해요.');
    } else {
      _showSnack('$count명 생성 완료. dummy_001·003·006에게 like하면 즉시 매칭!');
    }
    await _loadDiscovery();
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
      case 'dummies':
        _generateDummies();
        return;
    }
  }

  // ── 빌드 ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final boostLabel = _boostRemainingLabel();
    return Scaffold(
      backgroundColor: AppColors.surface,
      appBar: AppBar(
        title: const Text(
          '둘러보기',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: AppColors.background,
        elevation: 0,
        actions: [
          if (widget.authService.currentUser?.uid != null)
            JellyBalanceButton(
              currentUid: widget.authService.currentUser!.uid,
              jellyService: widget.jellyService,
              jellyPurchaseService: widget.jellyPurchaseService,
            ),
          IconButton(
            onPressed: _loading ? null : _activateBoost,
            icon: Icon(
              Icons.flash_on_rounded,
              color: boostLabel == null ? null : AppColors.primary,
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
              // 개발용 — 출시 전 제거
              if (kDebugMode)
                const PopupMenuItem(
                  value: 'dummies',
                  child: Row(
                    children: [
                      Icon(Icons.person_add_rounded, size: 20),
                      SizedBox(width: 10),
                      Text('더미 유저 생성'),
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
                  child: ProfileCardContent(
                    profile: _profiles[_currentIndex + 1],
                    currentUserBirthDate: _currentUserProfile?.birthDate,
                    currentUserLocation: _currentUserLocation,
                  ),
                ),
              ),
            ),

          // 현재 카드 (드래그 가능)
          // profileUid를 전달해야 SwipeCard.didUpdateWidget에서 카드 교체를
          // 감지하고 _offset을 Offset.zero로 초기화한다.
          // 이 초기화가 없으면 이전 카드의 fly-off 위치가 남아 잔상이 생긴다.
          Positioned.fill(
            child: SwipeCard(
              key: _swipeKey,
              profileUid: _profiles[_currentIndex].uid,
              onSwiped: (action) =>
                  _onSwiped(_profiles[_currentIndex].uid, action),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ProfileCardContent(
                    profile: _profiles[_currentIndex],
                    currentUserBirthDate: _currentUserProfile?.birthDate,
                    currentUserLocation: _currentUserLocation,
                    onProfileTap: () => _openProfile(_profiles[_currentIndex]),
                  ),
                  Positioned(
                    top: 12,
                    right: 12,
                    child: _SafetyMenuButton(
                      onReport: () => _reportProfile(_profiles[_currentIndex]),
                      onBlock: () => _blockProfile(_profiles[_currentIndex]),
                    ),
                  ),
                ],
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
          _ActionButton(
            icon: Icons.undo_rounded,
            color: AppColors.textSecondary,
            size: 50,
            onPressed: canRewind ? _handleRewind : null,
          ),
          // PASS 버튼
          _ActionButton(
            icon: Icons.close_rounded,
            color: AppColors.error,
            size: 56,
            onPressed: () => _handleButtonSwipe('pass'),
          ),
          // SUPER LIKE 버튼
          // 추후 결제/일일제한 연동: 지금은 발표용으로 무제한 허용한다.
          _ActionButton(
            icon: Icons.star_rounded,
            color: AppColors.water,
            size: 60,
            onPressed: () => _handleButtonSwipe('superlike'),
          ),
          // LIKE 버튼
          _ActionButton(
            icon: Icons.favorite_rounded,
            color: AppColors.wood,
            size: 64,
            onPressed: () => _handleButtonSwipe('like'),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
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
              _filter.hasActiveFilters ? '필터로 인해 볼 사람이 없어요' : '지금은 새로운 사람이 없어요',
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
                  : '나중에 다시 확인하거나\n더미 유저를 생성해보세요.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: AppColors.textSecondary,
                height: 1.6,
              ),
            ),
            const SizedBox(height: 28),
            if (_filter.hasActiveFilters) ...[
              OutlinedButton.icon(
                onPressed: _openFilterSheet,
                icon: const Icon(Icons.tune_rounded),
                label: const Text('필터 조정하기'),
              ),
              const SizedBox(height: 10),
            ],
            FilledButton.icon(
              onPressed: _loadDiscovery,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('새로고침'),
              style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
            ),
          ],
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

// ── 하단 액션 버튼 ─────────────────────────────────────────────────────────────

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final double size;
  final VoidCallback? onPressed;

  const _ActionButton({
    required this.icon,
    required this.color,
    required this.size,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final effectiveColor = enabled
        ? color
        : AppColors.textSecondary.withValues(alpha: 0.35);
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: AppColors.background,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: AppColors.ink.withValues(alpha: 0.1),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
          border: Border.all(
            color: effectiveColor.withValues(alpha: 0.3),
            width: 1.5,
          ),
        ),
        child: Icon(icon, color: effectiveColor, size: size * 0.5),
      ),
    );
  }
}

class _RewindCandidate {
  final UserProfile profile;
  final int previousIndex;

  const _RewindCandidate({required this.profile, required this.previousIndex});
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
