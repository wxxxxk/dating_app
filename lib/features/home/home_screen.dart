import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/constants/profile_options.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/text_sanitizer.dart';
import '../../models/match_model.dart';
import '../../models/user_profile.dart';
import '../../services/auth/auth_service.dart';
import '../../services/charm/charm_service.dart';
import '../../services/database/firestore_service.dart';
import '../../services/discovery/discovery_service.dart';
import '../../services/fortune/fortune_calculator.dart';
import '../../services/fortune/fortune_service.dart';
import '../../services/jelly/jelly_purchase_service.dart';
import '../../services/jelly/jelly_service.dart';
import '../../services/likes/likes_service.dart';
import '../../services/matches/matches_service.dart';
import '../../services/profile/profile_insight_service.dart';
import '../../services/ideal_type/ideal_type_service.dart';
import '../../services/safety/safety_service.dart';
import '../../services/storage/storage_service.dart';
import '../../shared/widgets/loading_indicator.dart';
import '../../shared/widgets/premium_components.dart';
import '../../shared/widgets/primary_button.dart';
import '../auth/phone_login_screen.dart';
import '../charm/charm_report_screen.dart';
import '../ideal_type/ideal_type_screen.dart';
import '../jelly/jelly_shop_screen.dart';
import '../profile/profile_edit_screen.dart';
import '../profile/user_profile_screen.dart';
import '../profile/widgets/verification_badge.dart';
import '../safety/blocked_users_screen.dart';

/// 홈 화면 — 내 프로필을 카드 형태로 표시한다 (M2.5).
///
/// M2.5에서 표시되는 정보:
/// - 사진 갤러리 (PageView, 여러 장이면 좌우 스와이프)
/// - 이름·나이·성별·한줄 소개
/// - 상세 정보 (키·MBTI·종교·흡연·음주·학력)
/// - 관심사·성향·이상형 태그 칩
/// - 찾는 관계
/// - 프로필 편집 / 로그아웃 버튼
class HomeScreen extends StatefulWidget {
  final AuthService authService;
  final FirestoreService firestoreService;
  final StorageService storageService;
  final DiscoveryService discoveryService;
  final MatchesService matchesService;
  final CharmService charmService;
  final FortuneService fortuneService;
  final JellyService jellyService;
  final JellyPurchaseService jellyPurchaseService;
  final LikesService likesService;
  final SafetyService safetyService;
  final ProfileInsightService profileInsightService;
  final VoidCallback? onOpenDiscovery;

  const HomeScreen({
    super.key,
    required this.authService,
    required this.firestoreService,
    required this.storageService,
    required this.discoveryService,
    required this.matchesService,
    required this.charmService,
    required this.fortuneService,
    required this.jellyService,
    required this.jellyPurchaseService,
    required this.likesService,
    required this.safetyService,
    required this.profileInsightService,
    this.onOpenDiscovery,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  UserProfile? _profile;
  _DailyPick? _dailyPick;
  bool _loading = true;
  bool _dailyPickLoading = true;
  bool _verificationLoading = false;
  String? _errorMessage;
  // fortune_hub_screen.dart와 같은 패턴 — 상태 없는 서비스 래퍼라 화면마다
  // 로컬로 만들어 쓴다. app.dart의 전역 주입 체인에 추가할 필요가 없다.
  final _idealTypeService = IdealTypeService();

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _errorMessage = null;
      });
    }
    final uid = widget.authService.currentUser?.uid;
    if (uid == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }

    UserProfile? synced;
    try {
      final profile = await widget.firestoreService.getUserProfile(uid);
      synced = profile == null ? null : await _syncEmailVerification(profile);
      if (mounted) {
        setState(() {
          _profile = synced;
          _errorMessage = synced == null ? '프로필을 찾을 수 없습니다.' : null;
        });
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[HomeScreen] 프로필 로딩 실패: $e');
      if (mounted) {
        setState(() {
          _profile = null;
          _errorMessage = '프로필을 불러오지 못했어요. 네트워크를 확인한 뒤 다시 시도해주세요.';
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }

    if (synced != null) {
      await _loadDailyPick(synced);
    }
  }

  Future<void> _loadDailyPick(UserProfile myProfile) async {
    if (mounted) {
      setState(() => _dailyPickLoading = true);
    }
    try {
      final pick = await _findDailyPick(myProfile);
      if (!mounted) return;
      setState(() {
        _dailyPick = pick;
        _dailyPickLoading = false;
      });
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[HomeDailyPick] 추천 로딩 실패: $e');
        debugPrint('$st');
      }
      if (!mounted) return;
      setState(() {
        _dailyPick = null;
        _dailyPickLoading = false;
      });
    }
  }

  Future<_DailyPick?> _findDailyPick(UserProfile myProfile) async {
    try {
      final matches = await widget.matchesService
          .watchMatches(currentUid: myProfile.uid)
          .first
          .timeout(const Duration(seconds: 5));
      final matchPick = await _pickFromMatches(myProfile, matches);
      if (matchPick != null) return matchPick;
    } catch (e) {
      if (kDebugMode) debugPrint('[HomeDailyPick] 매칭 목록 조회 실패: $e');
    }

    Set<String> blockedUids = const {};
    try {
      blockedUids = await widget.safetyService.getBlockedRelationshipUids(
        myProfile.uid,
      );
    } catch (e) {
      if (kDebugMode) debugPrint('[HomeDailyPick] 차단 목록 조회 실패: $e');
    }

    final discoveryProfiles = await widget.discoveryService
        .getDiscoveryProfiles(
          currentUid: myProfile.uid,
          currentLocation: myProfile.location,
          filter: myProfile.discoveryFilter,
          excludedUids: blockedUids,
        )
        .timeout(const Duration(seconds: 5));
    if (discoveryProfiles.isEmpty) return null;
    return _buildDailyPick(
      myProfile: myProfile,
      otherProfile: discoveryProfiles.first,
      source: _DailyPickSource.discovery,
    );
  }

  Future<_DailyPick?> _pickFromMatches(
    UserProfile myProfile,
    List<MatchWithProfile> matches,
  ) async {
    if (matches.isEmpty) return null;
    final candidates = await Future.wait(
      matches.take(8).map((match) async {
        String? cachedReason;
        try {
          final cached = await widget.fortuneService.getCachedMatchFortune(
            match.match.matchId,
          );
          cachedReason = cached?.reasons
              .map((reason) => reason.text.trim())
              .firstWhere((text) => text.isNotEmpty, orElse: () => '');
          if (cachedReason != null && cachedReason.isEmpty) {
            cachedReason = cached?.summary.trim();
          }
        } catch (e) {
          if (kDebugMode) {
            debugPrint('[HomeDailyPick] 궁합 캐시 조회 실패: $e');
          }
        }
        return _buildDailyPick(
          myProfile: myProfile,
          otherProfile: match.otherProfile,
          source: _DailyPickSource.match,
          cachedReason: cachedReason,
        );
      }),
    );
    candidates.sort((a, b) => b.score.compareTo(a.score));
    return candidates.first;
  }

  _DailyPick _buildDailyPick({
    required UserProfile myProfile,
    required UserProfile otherProfile,
    required _DailyPickSource source,
    String? cachedReason,
  }) {
    final hint = FortuneCalculator.getCompatibilityHint(
      myProfile.birthDate,
      otherProfile.birthDate,
    );
    final hasCachedReason = cachedReason != null && cachedReason.isNotEmpty;
    final score = (_scoreForHint(hint) + (hasCachedReason ? 2 : 0)).clamp(
      72,
      96,
    );
    return _DailyPick(
      profile: otherProfile,
      score: score,
      reason: hasCachedReason ? cachedReason : _fallbackReason(hint, source),
    );
  }

  int _scoreForHint(CompatibilityHint hint) {
    switch (hint.level) {
      case '상생':
        return 94;
      case '조화':
        return 89;
      case '균형':
        return 84;
      case '보완':
        return 80;
      default:
        return 78;
    }
  }

  String _fallbackReason(CompatibilityHint hint, _DailyPickSource source) {
    final prefix = source == _DailyPickSource.match
        ? '이미 이어진 인연이라'
        : '오늘 먼저 대화해보기 좋은';
    switch (hint.level) {
      case '상생':
        return '$prefix 상생 흐름이 강해 대화가 자연스럽게 이어질 가능성이 높아요.';
      case '조화':
        return '$prefix 편안한 조화가 보여 서로의 템포를 맞추기 좋아요.';
      case '보완':
        return '$prefix 서로 다른 매력이 부족한 부분을 채워줄 수 있어요.';
      default:
        return '$prefix 균형 있는 흐름이라 가볍게 말을 걸기 좋아요.';
    }
  }

  Future<UserProfile> _syncEmailVerification(UserProfile profile) async {
    await widget.authService.reloadUser();
    final syncedVerifications = profile.verifications.copyWith(
      email: widget.authService.isEmailVerified,
    );
    if (syncedVerifications.email != profile.verifications.email) {
      await widget.firestoreService.updateUserVerifications(
        profile.uid,
        syncedVerifications,
      );
    }
    return profile.copyWith(verifications: syncedVerifications);
  }

  Future<void> _sendEmailVerification() async {
    setState(() => _verificationLoading = true);
    try {
      await widget.authService.sendEmailVerification();
      if (!mounted) return;
      _showSnack('인증 메일을 보냈어요. 메일함의 링크를 눌러주세요.');
    } on AuthFailure catch (e) {
      if (mounted) _showSnack(e.message);
    } finally {
      if (mounted) setState(() => _verificationLoading = false);
    }
  }

  Future<void> _refreshEmailVerification() async {
    final profile = _profile;
    if (profile == null) return;
    setState(() => _verificationLoading = true);
    try {
      final synced = await _syncEmailVerification(profile);
      if (!mounted) return;
      setState(() => _profile = synced);
      _showSnack(
        synced.verifications.email ? '이메일 인증이 확인됐어요.' : '아직 이메일 인증 전이에요.',
      );
    } finally {
      if (mounted) setState(() => _verificationLoading = false);
    }
  }

  Future<void> _openPhoneVerification() async {
    final profile = _profile;
    if (profile == null || profile.verifications.phone) return;

    final completed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => PhoneLoginScreen(
          authService: widget.authService,
          linkToCurrentUser: true,
          onVerificationCompleted: _markPhoneVerified,
        ),
      ),
    );
    if (!mounted) return;
    if (completed == true) {
      _showSnack('전화 인증이 완료됐어요.');
    }
  }

  Future<void> _markPhoneVerified() async {
    final profile = _profile;
    if (profile == null) return;
    final synced = profile.verifications.copyWith(phone: true);
    await widget.firestoreService.updateUserVerifications(profile.uid, synced);
    if (!mounted) return;
    setState(() => _profile = profile.copyWith(verifications: synced));
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _handleSignOut() async {
    try {
      await widget.authService.signOut();
    } on AuthFailure catch (e) {
      if (mounted) {
        _showSnack(e.message);
      }
    }
  }

  /// 프로필 편집 화면으로 이동하고, 돌아올 때 최신 프로필을 반영한다.
  Future<void> _openEditScreen() async {
    final profile = _profile;
    if (profile == null) return;

    final updated = await Navigator.push<UserProfile>(
      context,
      MaterialPageRoute(
        builder: (ctx) => ProfileEditScreen(
          profile: profile,
          firestoreService: widget.firestoreService,
          storageService: widget.storageService,
        ),
      ),
    );
    // 저장된 경우 재조회 없이 반영
    if (updated != null && mounted) {
      setState(() => _profile = updated);
    }
  }

  Future<void> _openBlockedUsers() async {
    final uid = widget.authService.currentUser?.uid;
    if (uid == null) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => BlockedUsersScreen(
          currentUid: uid,
          safetyService: widget.safetyService,
        ),
      ),
    );
  }

  Future<void> _openCharmReport() async {
    final uid = widget.authService.currentUser?.uid;
    if (uid == null) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => CharmReportScreen(
          currentUid: uid,
          charmService: widget.charmService,
        ),
      ),
    );
  }

  Future<void> _openIdealType() async {
    final profile = _profile;
    if (profile == null) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => IdealTypeScreen(
          profile: profile,
          idealTypeService: _idealTypeService,
        ),
      ),
    );
  }

  Future<void> _openDailyPickProfile() async {
    final current = _profile;
    final pick = _dailyPick;
    if (current == null || pick == null) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => UserProfileScreen(
          currentUid: current.uid,
          initialProfile: pick.profile,
          currentLocation: current.location,
          firestoreService: widget.firestoreService,
          safetyService: widget.safetyService,
          profileInsightService: widget.profileInsightService,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: LoadingIndicator());
    }

    final profile = _profile;
    if (profile == null) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(_errorMessage ?? '프로필을 불러올 수 없습니다.'),
              const SizedBox(height: 16),
              TextButton(onPressed: _loadProfile, child: const Text('다시 시도')),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('내 프로필'),
        backgroundColor: AppColors.background,
        foregroundColor: AppColors.textPrimary,
        actions: [
          JellyBalanceButton(
            currentUid: profile.uid,
            jellyService: widget.jellyService,
            jellyPurchaseService: widget.jellyPurchaseService,
            foregroundColor: AppColors.matchPrimary,
          ),
          IconButton(
            icon: const Icon(Icons.edit_rounded),
            tooltip: '프로필 편집',
            onPressed: _openEditScreen,
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
              child: _DailyPickHeroCard(
                loading: _dailyPickLoading,
                pick: _dailyPick,
                onPrimaryTap: _dailyPick == null
                    ? widget.onOpenDiscovery
                    : _openDailyPickProfile,
              ),
            ),
            // ── 사진 갤러리 ─────────────────────────────────────────────
            _PhotoGallery(photoUrls: profile.photoUrls),

            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── 이름·나이·성별 ──────────────────────────────────
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${profile.displayName}, ${profile.age}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 28,
                                fontWeight: FontWeight.bold,
                                color: AppColors.textPrimary,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          _Badge(label: _genderLabel(profile.gender)),
                        ],
                      ),
                      if (profile.mbti != null) ...[
                        const SizedBox(height: 8),
                        _Badge(
                          label: profile.mbti!,
                          color: AppColors.secondary.withValues(alpha: 0.12),
                          textColor: AppColors.secondary,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 10),

                  // ── 한줄 소개 ────────────────────────────────────────
                  if (profile.bio.isNotEmpty)
                    Text(
                      stripEmoji(profile.bio),
                      style: const TextStyle(
                        fontSize: 15,
                        color: AppColors.textSecondary,
                        height: 1.5,
                      ),
                    ),
                  const SizedBox(height: 18),

                  // ── 요약 지표 ────────────────────────────────────────
                  _ProfileSummaryGrid(
                    profile: profile,
                    likesService: widget.likesService,
                    jellyService: widget.jellyService,
                    onTapCompleteness: _openEditScreen,
                    onTapJelly: () => openJellyShop(
                      context: context,
                      currentUid: profile.uid,
                      jellyService: widget.jellyService,
                      jellyPurchaseService: widget.jellyPurchaseService,
                    ),
                  ),
                  const SizedBox(height: 20),

                  _VerificationSection(
                    verifications: profile.verifications,
                    loading: _verificationLoading,
                    onSendEmail: _sendEmailVerification,
                    onRefreshEmail: _refreshEmailVerification,
                    onVerifyPhone: _openPhoneVerification,
                  ),
                  const SizedBox(height: 24),

                  // ── 상세 정보 칩 ─────────────────────────────────────
                  if (_hasDetailInfo(profile)) ...[
                    _DetailInfoRow(profile: profile),
                    const SizedBox(height: 24),
                  ],

                  // ── 찾는 관계 ────────────────────────────────────────
                  if (profile.relationshipGoal != null) ...[
                    _SectionTitle(title: '찾는 관계'),
                    const SizedBox(height: 8),
                    _Badge(
                      label:
                          ProfileOptions.keyToLabel(
                            ProfileOptions.relationshipGoals,
                            profile.relationshipGoal!,
                          ) ??
                          '',
                      color: AppColors.matchPrimary.withValues(alpha: 0.1),
                      textColor: AppColors.matchPrimary,
                    ),
                    const SizedBox(height: 24),
                  ],

                  // ── 관심사 태그 ──────────────────────────────────────
                  if (profile.interests.isNotEmpty) ...[
                    _SectionTitle(title: '관심사'),
                    const SizedBox(height: 8),
                    _TagWrap(
                      keys: profile.interests,
                      options: ProfileOptions.interests,
                    ),
                    const SizedBox(height: 24),
                  ],

                  // ── 성향 태그 ────────────────────────────────────────
                  if (profile.personalityTags.isNotEmpty) ...[
                    _SectionTitle(title: '나를 표현하는 키워드'),
                    const SizedBox(height: 8),
                    _TagWrap(
                      keys: profile.personalityTags,
                      options: ProfileOptions.personalities,
                    ),
                    const SizedBox(height: 24),
                  ],

                  // ── 이상형 태그 ──────────────────────────────────────
                  if (profile.idealTags.isNotEmpty) ...[
                    _SectionTitle(title: '이런 친구를 원해요'),
                    const SizedBox(height: 8),
                    _TagWrap(
                      keys: profile.idealTags,
                      options: ProfileOptions.ideals,
                    ),
                    const SizedBox(height: 24),
                  ],

                  const SizedBox(height: 16),
                  // 버튼 위계: 시그니처 CTA(민트 fill)는 AI 이상형 하나만.
                  // 나머지는 outlined로 낮춰 화면이 버튼 무더기로 보이지
                  // 않게 한다.
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: FilledButton.icon(
                      onPressed: _openIdealType,
                      icon: const Icon(Icons.auto_awesome_rounded, size: 20),
                      label: const Text('AI 이상형 만들기'),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.mint,
                        foregroundColor: AppColors.onMint,
                        textStyle: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppRadius.button),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: OutlinedButton.icon(
                      onPressed: _openCharmReport,
                      icon: const Icon(Icons.diamond_outlined, size: 20),
                      label: const Text('내 매력 리포트'),
                      style: OutlinedButton.styleFrom(
                        backgroundColor: AppColors.surface,
                        foregroundColor: AppColors.mintDeep,
                        side: BorderSide(
                          color: AppColors.mintDeep.withValues(alpha: 0.55),
                        ),
                        textStyle: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  PrimaryButton(
                    label: '프로필 편집',
                    outlined: true,
                    onPressed: _openEditScreen,
                  ),
                  const SizedBox(height: 12),
                  PrimaryButton(
                    label: '차단 목록 관리',
                    outlined: true,
                    onPressed: _openBlockedUsers,
                  ),
                  const SizedBox(height: 12),
                  PrimaryButton(
                    label: '로그아웃',
                    outlined: true,
                    onPressed: _handleSignOut,
                  ),
                  const SizedBox(height: 40),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool _hasDetailInfo(UserProfile p) =>
      p.height != null ||
      p.religion != null ||
      p.smoking != null ||
      p.drinking != null ||
      p.education != null ||
      p.jobCategory != null ||
      (p.jobTitle != null && p.jobTitle!.isNotEmpty);

  String _genderLabel(String gender) {
    switch (gender) {
      case 'male':
        return '남성';
      case 'female':
        return '여성';
      default:
        return '기타';
    }
  }
}

enum _DailyPickSource { match, discovery }

class _DailyPick {
  final UserProfile profile;
  final int score;
  final String reason;

  const _DailyPick({
    required this.profile,
    required this.score,
    required this.reason,
  });
}

// ── 내부 위젯 ──────────────────────────────────────────────────────────────────

class _DailyPickHeroCard extends StatelessWidget {
  final bool loading;
  final _DailyPick? pick;
  final VoidCallback? onPrimaryTap;

  const _DailyPickHeroCard({
    required this.loading,
    required this.pick,
    required this.onPrimaryTap,
  });

  @override
  Widget build(BuildContext context) {
    final activePick = pick;
    final isFallback = activePick == null && !loading;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(22),
      // 발표용 긴급 안정화: 다크 히어로 대신 라이트 카드 + 민트 강조로 통일한다.
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.mintSoft, AppColors.surface],
        ),
        borderRadius: BorderRadius.circular(AppRadius.hero),
        border: Border.all(color: AppColors.mint.withValues(alpha: 0.3)),
        boxShadow: AppShadows.card,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const _AiBadge(),
              const Spacer(),
              if (loading)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else if (activePick != null)
                _ScorePill(score: activePick.score),
            ],
          ),
          const SizedBox(height: 16),
          const Text(
            '오늘의 인연',
            style: TextStyle(
              fontSize: 23,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.3,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            loading
                ? 'AI 추천 데이터를 확인하고 있어요.'
                : isFallback
                ? '아직 오늘의 추천을 준비하고 있어요.'
                : '오늘 AI가 가장 잘 맞는 사람으로 추천합니다.',
            style: const TextStyle(
              fontSize: 14,
              height: 1.45,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 18),
          if (loading)
            const _DailyPickLoadingBody()
          else if (activePick == null)
            const _DailyPickFallbackBody()
          else
            _DailyPickSuccessBody(pick: activePick),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: loading ? null : onPrimaryTap,
              icon: Icon(
                activePick == null
                    ? Icons.explore_rounded
                    : Icons.person_search_rounded,
                size: 19,
              ),
              label: Text(activePick == null ? '둘러보기 시작' : '프로필 보기'),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.mint,
                foregroundColor: AppColors.onMint,
                textStyle: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.button),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AiBadge extends StatelessWidget {
  const _AiBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.mint.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppRadius.chip),
        border: Border.all(color: AppColors.mint.withValues(alpha: 0.35)),
      ),
      child: const Text(
        'AI DAILY PICK',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.6,
          color: AppColors.mintDeep,
        ),
      ),
    );
  }
}

class _ScorePill extends StatelessWidget {
  final int score;

  const _ScorePill({required this.score});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: AppColors.fortuneAccent.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(AppRadius.chip),
        border: Border.all(
          color: AppColors.fortuneAccent.withValues(alpha: 0.3),
        ),
      ),
      child: Text(
        '궁합 $score%',
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w800,
          color: AppColors.fortuneAccent,
        ),
      ),
    );
  }
}

class _DailyPickLoadingBody extends StatelessWidget {
  const _DailyPickLoadingBody();

  @override
  Widget build(BuildContext context) {
    return const Text(
      '기존 궁합 캐시와 프로필 흐름을 바탕으로 오늘 먼저 보면 좋은 인연을 찾는 중이에요.',
      style: TextStyle(fontSize: 15, height: 1.55, color: AppColors.textPrimary),
    );
  }
}

class _DailyPickFallbackBody extends StatelessWidget {
  const _DailyPickFallbackBody();

  @override
  Widget build(BuildContext context) {
    return const Text(
      '둘러보기를 시작하면\nAI 추천 정확도가 높아집니다.',
      style: TextStyle(
        fontSize: 17,
        height: 1.55,
        fontWeight: FontWeight.w700,
        color: AppColors.textPrimary,
      ),
    );
  }
}

class _DailyPickSuccessBody extends StatelessWidget {
  final _DailyPick pick;

  const _DailyPickSuccessBody({required this.pick});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _DailyPickAvatar(profile: pick.profile),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                pick.profile.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.2,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '"${pick.reason}"',
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 15,
                  height: 1.5,
                  fontWeight: FontWeight.w500,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DailyPickAvatar extends StatelessWidget {
  final UserProfile profile;

  const _DailyPickAvatar({required this.profile});

  @override
  Widget build(BuildContext context) {
    final imageUrl = profile.photoUrls.isEmpty ? null : profile.photoUrls.first;
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.button),
      child: Container(
        width: 78,
        height: 98,
        color: AppColors.textPrimary.withValues(alpha: 0.08),
        child: imageUrl == null
            ? const Icon(
                Icons.person_rounded,
                color: AppColors.textSecondary,
                size: 38,
              )
            : Image.network(
                imageUrl,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const Icon(
                  Icons.person_rounded,
                  color: AppColors.textSecondary,
                  size: 38,
                ),
              ),
      ),
    );
  }
}

/// 사진 PageView — 여러 장이면 좌우 스와이프, 1장이면 정적 표시.
class _PhotoGallery extends StatefulWidget {
  final List<String> photoUrls;
  const _PhotoGallery({required this.photoUrls});

  @override
  State<_PhotoGallery> createState() => _PhotoGalleryState();
}

class _PhotoGalleryState extends State<_PhotoGallery> {
  int _currentPage = 0;

  @override
  Widget build(BuildContext context) {
    final urls = widget.photoUrls;
    final height = MediaQuery.of(context).size.width - 40; // 카드 좌우 여백 제외

    if (urls.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Container(
          height: height,
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(AppRadius.hero),
            border: Border.all(color: AppColors.border),
          ),
          child: const Icon(
            Icons.person_rounded,
            size: 80,
            color: AppColors.textSecondary,
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.hero),
        child: Stack(
          children: [
            SizedBox(
              height: height,
              child: PageView.builder(
                itemCount: urls.length,
                onPageChanged: (i) => setState(() => _currentPage = i),
                itemBuilder: (ctx, i) => Image.network(
                  urls[i],
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => Container(
                    color: AppColors.surface,
                    child: const Icon(
                      Icons.broken_image_rounded,
                      size: 60,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              ),
            ),
            // 도트 인디케이터 — 사진이 2장 이상일 때만 표시
            if (urls.length > 1)
              Positioned(
                bottom: 12,
                left: 0,
                right: 0,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(urls.length, (i) {
                    final active = i == _currentPage;
                    return AnimatedContainer(
                      duration: AppDurations.fast,
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      width: active ? 16 : 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: AppColors.surface.withValues(
                          alpha: active ? 1 : 0.54,
                        ),
                        borderRadius: BorderRadius.circular(AppSpacing.xs),
                      ),
                    );
                  }),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _VerificationSection extends StatelessWidget {
  final VerificationStatus verifications;
  final bool loading;
  final VoidCallback onSendEmail;
  final VoidCallback onRefreshEmail;
  final VoidCallback onVerifyPhone;

  const _VerificationSection({
    required this.verifications,
    required this.loading,
    required this.onSendEmail,
    required this.onRefreshEmail,
    required this.onVerifyPhone,
  });

  @override
  Widget build(BuildContext context) {
    return PremiumSectionCard(
      title: '인증 현황',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          VerificationBadges(
            verifications: verifications,
            showUnverified: true,
          ),
          const SizedBox(height: 12),
          if (!verifications.email) ...[
            const Text(
              '이메일 인증을 완료하면 프로필에 신뢰 배지가 표시돼요.',
              style: TextStyle(
                fontSize: 13,
                color: AppColors.textSecondary,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: loading ? null : onSendEmail,
                  icon: const Icon(Icons.mark_email_unread_rounded, size: 17),
                  label: const Text('이메일 인증하기'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.mint,
                    foregroundColor: AppColors.onMint,
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: loading ? null : onRefreshEmail,
                  icon: loading
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh_rounded, size: 17),
                  label: const Text('인증 확인'),
                ),
              ],
            ),
          ],
          if (!verifications.phone) ...[
            if (!verifications.email) const SizedBox(height: 14),
            const Text(
              '전화번호 인증을 완료하면 상대에게 더 신뢰감 있게 보여요.',
              style: TextStyle(
                fontSize: 13,
                color: AppColors.textSecondary,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: onVerifyPhone,
              icon: const Icon(Icons.phone_iphone_rounded, size: 17),
              label: const Text('전화 인증하기'),
            ),
          ],
          if (verifications.email && verifications.phone)
            const Text(
              '사진 인증은 다음 단계에서 연결할 수 있게 자리만 준비해뒀어요.',
              style: TextStyle(
                fontSize: 13,
                color: AppColors.textSecondary,
                height: 1.4,
              ),
            ),
        ],
      ),
    );
  }
}

/// 상세 정보를 아이콘+값 칩으로 표시하는 행.
class _DetailInfoRow extends StatelessWidget {
  final UserProfile profile;
  const _DetailInfoRow({required this.profile});

  @override
  Widget build(BuildContext context) {
    final items = <_DetailItem>[];

    if (profile.height != null) {
      items.add(
        _DetailItem(
          icon: Icons.straighten_rounded,
          label: '${profile.height}cm',
        ),
      );
    }
    if (profile.religion != null) {
      final label = ProfileOptions.keyToLabel(
        ProfileOptions.religions,
        profile.religion!,
      );
      if (label != null) {
        items.add(_DetailItem(icon: Icons.spa_rounded, label: label));
      }
    }
    if (profile.smoking != null) {
      final label = ProfileOptions.keyToLabel(
        ProfileOptions.smokingOptions,
        profile.smoking!,
      );
      if (label != null) {
        items.add(_DetailItem(icon: Icons.smoke_free_rounded, label: label));
      }
    }
    if (profile.drinking != null) {
      final label = ProfileOptions.keyToLabel(
        ProfileOptions.drinkingOptions,
        profile.drinking!,
      );
      if (label != null) {
        items.add(_DetailItem(icon: Icons.local_bar_rounded, label: label));
      }
    }
    if (profile.education != null) {
      final label = ProfileOptions.keyToLabel(
        ProfileOptions.educationOptions,
        profile.education!,
      );
      if (label != null) {
        items.add(_DetailItem(icon: Icons.school_rounded, label: label));
      }
    }
    // 직업: "카테고리 · 세부직업명" 형태로 표시 (카테고리만 있어도 표시)
    final catLabel = profile.jobCategory != null
        ? ProfileOptions.keyToLabel(
            ProfileOptions.jobCategoryOptions,
            profile.jobCategory!,
          )
        : null;
    final catName = catLabel != null
        ? (catLabel.contains(' ')
              ? catLabel.substring(catLabel.indexOf(' ') + 1)
              : catLabel)
        : null;
    final jobParts = [
      ?catName,
      if (profile.jobTitle != null && profile.jobTitle!.isNotEmpty)
        profile.jobTitle!,
    ];
    if (jobParts.isNotEmpty) {
      items.add(
        _DetailItem(icon: Icons.work_rounded, label: jobParts.join(' · ')),
      );
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: items
          .map((item) => _DetailChip(icon: item.icon, label: item.label))
          .toList(),
    );
  }
}

class _DetailItem {
  final IconData icon;
  final String label;
  const _DetailItem({required this.icon, required this.label});
}

class _DetailChip extends StatelessWidget {
  final IconData icon;
  final String label;
  const _DetailChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.chip),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: AppColors.textSecondary),
          const SizedBox(width: AppSpacing.xs),
          Text(
            label,
            style: const TextStyle(fontSize: 13, color: AppColors.textPrimary),
          ),
        ],
      ),
    );
  }
}

/// 태그 key 목록 → label → Wrap 칩 표시.
class _TagWrap extends StatelessWidget {
  final List<String> keys;
  final List<TagOption> options;

  const _TagWrap({required this.keys, required this.options});

  @override
  Widget build(BuildContext context) {
    final labels = ProfileOptions.keysToLabels(options, keys);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: labels
          .map(
            (label) => Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(AppRadius.chip),
                border: Border.all(color: AppColors.border),
              ),
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 14,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
          )
          .toList(),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;
  const _SectionTitle({required this.title});

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.bold,
        color: AppColors.textPrimary,
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final String label;
  final Color? color;
  final Color? textColor;

  const _Badge({required this.label, this.color, this.textColor});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color ?? AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.button),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 13,
          color: textColor ?? AppColors.textSecondary,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

/// "내 상태를 한눈에" 보여주는 2x2 요약 카드 그리드.
///
/// 완성도는 UserProfile.completenessPercent(클라이언트 계산, 새 필드 없음),
/// 받은 좋아요/젤리는 기존 스트림을 그대로 재사용한다. 어떤 스트림이 실패해도
/// (권한 문제 등) 화면 전체가 깨지지 않도록 각 카드가 독립적으로 기본값(0)을
/// 보여준다.
class _ProfileSummaryGrid extends StatelessWidget {
  final UserProfile profile;
  final LikesService likesService;
  final JellyService jellyService;
  final VoidCallback onTapCompleteness;
  final VoidCallback onTapJelly;

  const _ProfileSummaryGrid({
    required this.profile,
    required this.likesService,
    required this.jellyService,
    required this.onTapCompleteness,
    required this.onTapJelly,
  });

  @override
  Widget build(BuildContext context) {
    final boostActive =
        profile.boostUntil != null &&
        profile.boostUntil!.isAfter(DateTime.now());

    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisSpacing: 10,
      mainAxisSpacing: 10,
      childAspectRatio: 1.55,
      children: [
        _StatCard(
          icon: Icons.auto_awesome_rounded,
          label: '프로필 완성도',
          value: '${profile.completenessPercent}%',
          onTap: onTapCompleteness,
        ),
        StreamBuilder<List<ReceivedLike>>(
          stream: likesService.watchReceivedLikes(currentUid: profile.uid),
          builder: (context, snap) {
            final count = snap.data?.length ?? 0;
            return _StatCard(
              icon: Icons.favorite_rounded,
              label: '받은 좋아요',
              value: '$count',
            );
          },
        ),
        StreamBuilder<int>(
          stream: jellyService.watchBalance(profile.uid),
          builder: (context, snap) {
            final balance = snap.data ?? 0;
            return _StatCard(
              icon: Icons.local_fire_department_rounded,
              label: '젤리 잔액',
              value: '$balance',
              onTap: onTapJelly,
            );
          },
        ),
        _StatCard(
          icon: Icons.bolt_rounded,
          label: '부스트',
          value: boostActive ? '진행 중' : '비활성',
          valueColor: boostActive ? AppColors.premium : null,
          accentColor: boostActive ? AppColors.premium : null,
        ),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color? valueColor;
  final VoidCallback? onTap;
  // 부스트가 활성 상태처럼 "지금 프리미엄 효과가 켜져 있다"는 신호가 필요한
  // 카드에만 넘긴다 — 기본은 null(앱 기본 primary 톤)이라 나머지 카드는
  // 그대로 유지된다.
  final Color? accentColor;

  const _StatCard({
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor,
    this.onTap,
    this.accentColor,
  });

  @override
  Widget build(BuildContext context) {
    // 4개 지표(완성도/받은 좋아요/젤리/부스트) 전부 "내 매칭 상태" 관련
    // 수치라 기본 accent를 matchPrimary(premium green)로 통일한다.
    final accent = accentColor ?? AppColors.matchPrimary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.card),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: AppColors.border),
          boxShadow: AppShadows.card,
        ),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 17, color: accent),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
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
                  const SizedBox(height: 2),
                  Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w900,
                      color: valueColor ?? AppColors.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
