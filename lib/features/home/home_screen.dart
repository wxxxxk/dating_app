import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/constants/profile_options.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/text_sanitizer.dart';
import '../../models/match_model.dart';
import '../../models/public_profile.dart';
import 'today_match.dart';
import '../../models/user_profile.dart';
import '../../models/affiliation_verification_request.dart';
import '../../models/photo_verification_request.dart';
import '../../services/privacy/contact_avoidance_service.dart';
import '../../services/verification/affiliation_verification_service.dart';
import '../../services/verification/photo_verification_service.dart';
import '../../services/auth/account_deletion_service.dart';
import '../../services/auth/auth_service.dart';
import '../../services/charm/charm_service.dart';
import '../../services/database/firestore_service.dart';
import '../../services/discovery/discovery_service.dart';
import '../../services/fortune/fortune_service.dart';
import '../../services/jelly/jelly_purchase_service.dart';
import '../../services/jelly/jelly_service.dart';
import '../../services/likes/likes_service.dart';
import '../../services/matches/matches_service.dart';
import '../../services/ideal_type/ideal_type_service.dart';
import '../../services/safety/safety_service.dart';
import '../../services/storage/storage_service.dart';
import '../../shared/widgets/loading_indicator.dart';
import '../../shared/widgets/premium_components.dart';
import '../../shared/widgets/primary_button.dart';
import '../../shared/widgets/profile_photo_view.dart';
import '../auth/phone_login_screen.dart';
import '../charm/charm_report_screen.dart';
import 'account_deletion_screen.dart';
import '../ideal_type/ideal_type_screen.dart';
import '../jelly/jelly_shop_screen.dart';
import '../profile/profile_edit_screen.dart';
import '../profile/user_profile_screen.dart';
import '../profile/widgets/verification_badge.dart';
import '../privacy/contact_avoidance_screen.dart';
import '../privacy/screen_protection_widgets.dart';
import '../safety/blocked_users_screen.dart';
import '../verification/affiliation_verification_screen.dart';
import '../verification/photo_verification_screen.dart';

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
  final VoidCallback? onOpenDiscovery;
  final AccountDeletionService? accountDeletionService;

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
    this.onOpenDiscovery,
    this.accountDeletionService,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  UserProfile? _profile;
  TodayMatchResult? _dailyPick;
  TodayMatchState _dailyPickState = TodayMatchState.loading;

  /// 세션 캐시. 같은 사용자·같은 KST 날짜면 탭 이동·rebuild에도 같은 결과를 쓴다.
  /// 계정이 바뀌면 uid가 달라져 자연히 miss된다.
  TodayMatchResult? _cachedPick;
  String? _cachedPickUid;

  bool _loading = true;
  bool _verificationLoading = false;
  String? _errorMessage;
  // fortune_hub_screen.dart와 같은 패턴 — 상태 없는 서비스 래퍼라 화면마다
  // 로컬로 만들어 쓴다. app.dart의 전역 주입 체인에 추가할 필요가 없다.
  final _idealTypeService = IdealTypeService();
  // 상태 없는 서비스 래퍼라 화면 로컬로 둔다(app.dart 주입 체인 변경 불필요).
  final _photoVerificationService = PhotoVerificationService();
  final _affiliationVerificationService = AffiliationVerificationService();
  final _contactAvoidanceService = ContactAvoidanceService();

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
      if (profile == null) {
        synced = null;
      } else {
        try {
          synced = await _syncAuthVerificationBadges(profile);
        } on AuthFailure catch (e) {
          if (kDebugMode) {
            debugPrint('[HomeScreen] 인증 배지 동기화 실패: ${e.message}');
          }
          synced = profile;
        }
      }
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
      setState(() => _dailyPickState = TodayMatchState.loading);
    }
    final dateKey = kstDateKey(DateTime.now());
    final filter = myProfile.discoveryFilter;
    final viewerFingerprint = buildViewerEligibilityFingerprint(
      viewerUid: myProfile.uid,
      ageMin: filter.ageMin,
      ageMax: filter.ageMax,
      maxDistanceKm: filter.maxDistanceKm,
      gender: filter.gender,
      relationshipGoal: filter.relationshipGoal,
      hasLocation: myProfile.location != null,
    );

    try {
      var blockedUids = const <String>{};
      final candidates = await collectTodayMatchCandidates(
        viewerUid: myProfile.uid,
        loadBlockedUids: (uid) async {
          final result = await widget.safetyService
              .getBlockedRelationshipUids(uid)
              .timeout(const Duration(seconds: 5));
          blockedUids = result;
          return result;
        },
        loadMatchCandidates: (_) async {
          final matches = await widget.matchesService
              .watchMatches(currentUid: myProfile.uid)
              .first
              .timeout(const Duration(seconds: 5));
          return _matchCandidates(matches);
        },
        loadDiscoveryProfiles: (blocked) => widget.discoveryService
            .getDiscoveryProfiles(
              currentUid: myProfile.uid,
              currentLocation: myProfile.location,
              filter: filter,
              excludedUids: blocked,
            )
            .timeout(const Duration(seconds: 5)),
        onLog: (event) {
          if (kDebugMode) debugPrint('[HomeDailyPick] $event');
        },
      );

      final fingerprints = candidateFingerprints(candidates);

      // 캐시 재사용은 날짜·차단·후보 프로필·내 추천 조건을 모두 다시 확인한
      // 뒤에만 허용한다.
      final cached = _cachedPick;
      if (cached != null &&
          _cachedPickUid == myProfile.uid &&
          cached.isReusableFor(
            dateKey: dateKey,
            eligibleCandidateFingerprints: fingerprints,
            blockedUids: blockedUids,
            viewerEligibilityFingerprint: viewerFingerprint,
          )) {
        _logDailyPick(
          dateKey: dateKey,
          source: 'cache',
          eligibleCount: fingerprints.length,
          state: 'ready',
        );
        if (!mounted) return;
        setState(() {
          _dailyPick = cached;
          _dailyPickState = TodayMatchState.ready;
        });
        return;
      }

      final selected = selectTodayCandidate(
        viewerUid: myProfile.uid,
        dateKey: dateKey,
        candidates: candidates,
      );

      if (selected == null) {
        // 정상 조회 결과 후보가 0명. 이전 카드를 남기지 않는다.
        _cachedPick = null;
        _cachedPickUid = myProfile.uid;
        _logDailyPick(
          dateKey: dateKey,
          source: 'fresh',
          eligibleCount: 0,
          state: 'empty',
        );
        if (!mounted) return;
        setState(() {
          _dailyPick = null;
          _dailyPickState = TodayMatchState.empty;
        });
        return;
      }

      // 후보가 그대로여도 최신 PublicProfile로 result를 다시 만든다 —
      // 사진·소개가 바뀌었으면 카드와 문구가 함께 갱신되어야 한다.
      final result = buildTodayMatchResult(
        candidate: selected,
        dateKey: dateKey,
        viewerEligibilityFingerprint: viewerFingerprint,
      );
      _cachedPick = result;
      _cachedPickUid = myProfile.uid;
      _logDailyPick(
        dateKey: dateKey,
        source: 'fresh',
        eligibleCount: fingerprints.length,
        state: 'ready',
      );
      if (!mounted) return;
      setState(() {
        _dailyPick = result;
        _dailyPickState = TodayMatchState.ready;
      });
    } catch (e) {
      // 차단 확인 실패·후보 조회 실패 모두 error다. 빈 후보(empty)로 접지
      // 않고, 이전 카드도 남기지 않는다(차단된 상대가 남을 수 있다).
      if (kDebugMode) {
        debugPrint(
          '[HomeDailyPick] today_match_failed '
          'reason=${e is BlockLookupFailure
              ? 'block_lookup'
              : e is CandidateLookupFailure
              ? 'candidate_lookup'
              : 'unknown'}',
        );
      }
      _cachedPick = null;
      _cachedPickUid = null;
      if (!mounted) return;
      setState(() {
        _dailyPick = null;
        _dailyPickState = TodayMatchState.error;
      });
    }
  }

  /// 민감정보 없는 진단 로그. UID·이름·사진 URL·후보 ID·지문을 남기지 않는다.
  void _logDailyPick({
    required String dateKey,
    required String source,
    required int eligibleCount,
    required String state,
  }) {
    if (!kDebugMode) return;
    debugPrint(
      '[HomeDailyPick] dateKey=$dateKey source=$source '
      'eligibleCandidateCount=$eligibleCount state=$state '
      'algorithmVersion=$kTodayMatchAlgorithmVersion',
    );
  }

  /// 매칭된 상대는 그 매칭의 궁합 캐시 문구를 자기 문구로 들고 온다.
  /// matchId 기반이라 다른 후보의 문구가 섞일 수 없다.
  Future<List<TodayMatchCandidate>> _matchCandidates(
    List<MatchWithProfile> matches,
  ) async {
    if (matches.isEmpty) return const [];
    return Future.wait(
      matches.take(8).map((match) async {
        String? reason;
        try {
          final cached = await widget.fortuneService.getCachedMatchFortune(
            match.match.matchId,
          );
          final firstReason = cached?.reasons
              .map((r) => r.text.trim())
              .where((text) => text.isNotEmpty)
              .cast<String?>()
              .firstWhere((text) => text != null, orElse: () => null);
          reason = firstReason ?? cached?.summary.trim();
        } catch (e) {
          if (kDebugMode) {
            debugPrint('[HomeDailyPick] match_fortune_cache_failed');
          }
        }
        return TodayMatchCandidate(
          profile: match.otherProfile,
          source: TodayMatchSource.match,
          candidateReason: reason,
        );
      }),
    );
  }

  Future<void> _retryDailyPick() async {
    final profile = _profile;
    if (profile == null) return;
    if (_dailyPickState == TodayMatchState.loading) return;
    await _loadDailyPick(profile);
  }

  Future<UserProfile> _syncAuthVerificationBadges(
    UserProfile profile, {
    bool force = false,
  }) async {
    await widget.authService.reloadUser();
    final shouldSync =
        force ||
        widget.authService.isEmailVerified != profile.verifications.email ||
        widget.authService.hasPhoneNumber != profile.verifications.phone ||
        profile.verifications.photo;
    if (!shouldSync) {
      return profile;
    }
    final verifications = await widget.authService.syncAuthVerificationBadges();
    return profile.copyWith(verifications: verifications);
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
      final synced = await _syncAuthVerificationBadges(profile, force: true);
      if (!mounted) return;
      setState(() => _profile = synced);
      _showSnack(
        synced.verifications.email ? '이메일 인증이 확인됐어요.' : '아직 이메일 인증 전이에요.',
      );
    } on AuthFailure catch (e) {
      if (mounted) _showSnack(e.message);
    } finally {
      if (mounted) setState(() => _verificationLoading = false);
    }
  }

  /// 사진 인증 화면으로 이동한다. 인증 배지는 서버 승인 후에만 반영되므로
  /// 여기서는 요청 화면만 열고 verifications를 직접 건드리지 않는다.
  Future<void> _openPhotoVerification() async {
    final uid = widget.authService.currentUser?.uid;
    if (uid == null) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PhotoVerificationScreen(
          uid: uid,
          service: _photoVerificationService,
        ),
      ),
    );
  }

  /// 직장·학교 인증 화면으로 이동한다. 배지는 서버 승인 후에만 반영된다.
  Future<void> _openAffiliationVerification(
    AffiliationVerificationType type,
  ) async {
    final uid = widget.authService.currentUser?.uid;
    if (uid == null) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AffiliationVerificationScreen(
          uid: uid,
          type: type,
          service: _affiliationVerificationService,
        ),
      ),
    );
  }

  Future<void> _openPhoneVerification() async {
    final profile = _profile;
    if (profile == null ||
        profile.verifications.phone ||
        _verificationLoading) {
      return;
    }

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
    if (mounted) setState(() => _verificationLoading = true);
    try {
      final synced = await _syncAuthVerificationBadges(profile, force: true);
      if (!synced.verifications.phone) {
        throw const AuthFailure('전화 인증 상태를 확인하지 못했어요. 잠시 후 다시 시도해주세요.');
      }
      if (!mounted) return;
      setState(() => _profile = synced);
    } finally {
      if (mounted) setState(() => _verificationLoading = false);
    }
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

  Future<void> _openAccountDeletion() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            AccountDeletionScreen(service: widget.accountDeletionService),
      ),
    );
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

  /// 지인 피하기 화면. 전화 인증 여부는 서버에서도 다시 확인한다.
  Future<void> _openContactAvoidance() async {
    final uid = widget.authService.currentUser?.uid;
    if (uid == null) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => ContactAvoidanceScreen(
          uid: uid,
          service: _contactAvoidanceService,
          phoneVerified: _profile?.verifications.phone ?? false,
          onVerifyPhone: () {
            Navigator.pop(context);
            _openPhoneVerification();
          },
        ),
      ),
    );
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
                state: _dailyPickState,
                pick: _dailyPick,
                onPrimaryTap: _dailyPick == null
                    ? widget.onOpenDiscovery
                    : _openDailyPickProfile,
                onRetry: _retryDailyPick,
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
                    photoRequestStream: _photoVerificationService.watchRequest(
                      widget.authService.currentUser?.uid ?? '',
                    ),
                    onVerifyPhoto: _openPhotoVerification,
                    workRequestStream: _affiliationVerificationService
                        .watchRequest(
                          uid: widget.authService.currentUser?.uid ?? '',
                          type: AffiliationVerificationType.work,
                        ),
                    schoolRequestStream: _affiliationVerificationService
                        .watchRequest(
                          uid: widget.authService.currentUser?.uid ?? '',
                          type: AffiliationVerificationType.school,
                        ),
                    onVerifyAffiliation: _openAffiliationVerification,
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
                    key: const Key('open-contact-avoidance'),
                    label: '지인 피하기',
                    outlined: true,
                    onPressed: _openContactAvoidance,
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    '연락처에 있는 사람을 서로 추천에서 숨겨요',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  ScreenProtectionInfoRow(
                    onTap: () => showScreenProtectionInfoSheet(context),
                  ),
                  const SizedBox(height: 6),
                  PrimaryButton(
                    label: '차단 목록 관리',
                    outlined: true,
                    onPressed: _openBlockedUsers,
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: OutlinedButton.icon(
                      key: const Key('open-account-deletion'),
                      onPressed: _openAccountDeletion,
                      icon: const Icon(Icons.delete_forever_rounded, size: 20),
                      label: const Text('회원 탈퇴'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.error,
                        side: BorderSide(
                          color: AppColors.error.withValues(alpha: 0.45),
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

// ── 내부 위젯 ──────────────────────────────────────────────────────────────────

class _DailyPickHeroCard extends StatelessWidget {
  final TodayMatchState state;
  final TodayMatchResult? pick;
  final VoidCallback? onPrimaryTap;
  final VoidCallback onRetry;

  const _DailyPickHeroCard({
    required this.state,
    required this.pick,
    required this.onPrimaryTap,
    required this.onRetry,
  });

  Key get _stateKey => switch (state) {
    TodayMatchState.loading => const Key('today-match-loading'),
    TodayMatchState.ready => const Key('today-match-ready'),
    TodayMatchState.empty => const Key('today-match-empty'),
    TodayMatchState.error => const Key('today-match-error'),
  };

  @override
  Widget build(BuildContext context) {
    final loading = state == TodayMatchState.loading;
    // ready가 아니면 후보 카드를 그리지 않는다 — 이전 카드가 남지 않게.
    final activePick = state == TodayMatchState.ready ? pick : null;
    return Container(
      key: _stateKey,
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
                ),
              // 점수 pill은 제거했다. 앱에 궁합 점수 소스가 없어서
              // "추천 82%"가 상수로 만들어진 값이었다.
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
            switch (state) {
              TodayMatchState.loading => '오늘의 추천을 확인하고 있어요.',
              TodayMatchState.ready => '오늘 하루 같은 추천이 유지돼요.',
              TodayMatchState.empty =>
                '오늘 소개할 새로운 인연을 준비하고 있어요.\n새로운 프로필이 등록되면 알려드릴게요.',
              TodayMatchState.error => '추천을 불러오지 못했어요. 잠시 후 다시 시도해 주세요.',
            },
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
          if (state == TodayMatchState.error)
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                key: const Key('today-match-retry-button'),
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded, size: 19),
                label: const Text('다시 시도'),
              ),
            )
          else
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

class _DailyPickLoadingBody extends StatelessWidget {
  const _DailyPickLoadingBody();

  @override
  Widget build(BuildContext context) {
    return const Text(
      '기존 매칭 흐름과 공개 프로필을 바탕으로 오늘 먼저 보면 좋은 인연을 찾는 중이에요.',
      style: TextStyle(
        fontSize: 15,
        height: 1.55,
        color: AppColors.textPrimary,
      ),
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
  final TodayMatchResult pick;

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
  final PublicProfile profile;

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
            : ProfilePhotoThumbnail(url: imageUrl, boxWidth: 78, boxHeight: 98),
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.hero),
        child: Stack(
          children: [
            // 예전에는 height를 화면폭과 같게 줘서 모든 사진이 강제로
            // 정사각 crop됐다. 이제 대표 사진의 실제 비율을 따른다.
            ProfilePhotoDetailView(
              photoUrls: urls,
              onPageChanged: (i) => setState(() => _currentPage = i),
            ),
            if (urls.length > 1)
              Positioned(
                bottom: 12,
                left: 0,
                right: 0,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(
                    urls.length,
                    (i) => AnimatedContainer(
                      duration: AppDurations.fast,
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      width: i == _currentPage ? 18 : 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: i == _currentPage
                            ? AppColors.surface
                            : AppColors.surface.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(3),
                      ),
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

class _VerificationSection extends StatelessWidget {
  final VerificationStatus verifications;
  final bool loading;
  final VoidCallback onSendEmail;
  final VoidCallback onRefreshEmail;
  final VoidCallback onVerifyPhone;

  /// 사진 인증 요청 상태 스트림. 공개 배지의 최종 진실은 어디까지나
  /// verifications.photo이고, 이 스트림은 "검토 중/재제출 필요" 안내에만 쓴다.
  final Stream<PhotoVerificationRequest?> photoRequestStream;
  final VoidCallback onVerifyPhoto;

  /// 직장·학교 요청 상태 스트림. 공개 배지의 최종 진실은 verifications이고,
  /// 이 스트림들은 "검토 중/다시 제출 필요" 안내에만 쓴다.
  final Stream<AffiliationVerificationRequest?> workRequestStream;
  final Stream<AffiliationVerificationRequest?> schoolRequestStream;
  final void Function(AffiliationVerificationType type) onVerifyAffiliation;

  const _VerificationSection({
    required this.verifications,
    required this.loading,
    required this.onSendEmail,
    required this.onRefreshEmail,
    required this.onVerifyPhone,
    required this.photoRequestStream,
    required this.onVerifyPhoto,
    required this.workRequestStream,
    required this.schoolRequestStream,
    required this.onVerifyAffiliation,
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
          if (!verifications.email || !verifications.phone)
            const SizedBox(height: 14),
          _PhotoVerificationRow(
            verified: verifications.photo,
            requestStream: photoRequestStream,
            onTap: onVerifyPhoto,
          ),
          const SizedBox(height: 14),
          _AffiliationVerificationRow(
            type: AffiliationVerificationType.work,
            verified: verifications.work,
            requestStream: workRequestStream,
            onTap: () => onVerifyAffiliation(AffiliationVerificationType.work),
          ),
          const SizedBox(height: 14),
          _AffiliationVerificationRow(
            type: AffiliationVerificationType.school,
            verified: verifications.school,
            requestStream: schoolRequestStream,
            onTap: () =>
                onVerifyAffiliation(AffiliationVerificationType.school),
          ),
        ],
      ),
    );
  }
}

/// 인증 현황 카드의 사진 인증 행.
///
/// 공개 배지(verifications.photo)가 true면 무조건 "인증 완료"로 본다.
/// 요청 상태(pending/rejected)는 진행 안내 용도로만 쓰고, request status만으로
/// 인증 완료를 표시하지 않는다.
class _PhotoVerificationRow extends StatelessWidget {
  final bool verified;
  final Stream<PhotoVerificationRequest?> requestStream;
  final VoidCallback onTap;

  const _PhotoVerificationRow({
    required this.verified,
    required this.requestStream,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (verified) {
      return const Row(
        key: ValueKey('home-photo-verification-done'),
        children: [
          Icon(Icons.verified_rounded, size: 17, color: AppColors.mintDeep),
          SizedBox(width: 6),
          Text(
            '사진 인증 완료',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: AppColors.mintDeep,
            ),
          ),
        ],
      );
    }

    return StreamBuilder<PhotoVerificationRequest?>(
      stream: requestStream,
      builder: (context, snap) {
        final request = snap.data;
        final pending = request?.isPending ?? false;
        final rejected = request?.isRejected ?? false;
        return Column(
          key: const ValueKey('home-photo-verification-row'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              pending
                  ? '사진 인증을 검토하고 있어요. 결과가 나오면 배지에 반영돼요.'
                  : rejected
                  ? '사진 인증이 반려됐어요. 안내를 확인하고 다시 제출해주세요.'
                  : '사진 인증을 완료하면 프로필에 사진 인증 배지가 표시돼요.',
              style: const TextStyle(
                fontSize: 13,
                color: AppColors.textSecondary,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              key: const ValueKey('home-photo-verification-button'),
              onPressed: onTap,
              icon: const Icon(Icons.photo_camera_rounded, size: 17),
              label: Text(
                pending
                    ? '검토 중'
                    : rejected
                    ? '다시 제출 필요'
                    : '사진 인증하기',
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 인증 현황 카드의 직장·학교 인증 행.
///
/// 공개 배지(verifications.work/school)가 true면 "인증 완료"로 본다. 요청
/// 상태(pending/rejected)는 진행 안내 용도로만 쓰고, request status만으로
/// 인증 완료를 표시하지 않는다.
class _AffiliationVerificationRow extends StatelessWidget {
  final AffiliationVerificationType type;
  final bool verified;
  final Stream<AffiliationVerificationRequest?> requestStream;
  final VoidCallback onTap;

  const _AffiliationVerificationRow({
    required this.type,
    required this.verified,
    required this.requestStream,
    required this.onTap,
  });

  String get _label => affiliationVerificationTypeLabel(type);
  String get _keyPrefix =>
      'home-${affiliationVerificationTypeToString(type)}-verification';

  @override
  Widget build(BuildContext context) {
    if (verified) {
      return Row(
        key: ValueKey('$_keyPrefix-done'),
        children: [
          Icon(
            type == AffiliationVerificationType.work
                ? Icons.badge_rounded
                : Icons.school_rounded,
            size: 17,
            color: AppColors.mintDeep,
          ),
          const SizedBox(width: 6),
          Text(
            '$_label 완료',
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: AppColors.mintDeep,
            ),
          ),
        ],
      );
    }

    return StreamBuilder<AffiliationVerificationRequest?>(
      stream: requestStream,
      builder: (context, snap) {
        final request = snap.data;
        final pending = request?.isPending ?? false;
        final rejected = request?.isRejected ?? false;
        return Column(
          key: ValueKey('$_keyPrefix-row'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              pending
                  ? '$_label 자료를 검토하고 있어요. 결과가 나오면 배지에 반영돼요.'
                  : rejected
                  ? '$_label 자료가 반려됐어요. 안내를 확인하고 다시 제출해주세요.'
                  : '$_label을 완료하면 프로필에 인증 배지가 표시돼요.',
              style: const TextStyle(
                fontSize: 13,
                color: AppColors.textSecondary,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              key: ValueKey('$_keyPrefix-button'),
              onPressed: onTap,
              icon: Icon(
                type == AffiliationVerificationType.work
                    ? Icons.badge_outlined
                    : Icons.school_outlined,
                size: 17,
              ),
              label: Text(
                pending
                    ? '검토 중'
                    : rejected
                    ? '다시 제출 필요'
                    : '인증하기',
              ),
            ),
          ],
        );
      },
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
