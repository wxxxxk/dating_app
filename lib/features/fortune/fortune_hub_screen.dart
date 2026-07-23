import 'package:flutter/material.dart';

import '../../core/constants/profile_options.dart';
import '../../core/theme/app_colors.dart';
import '../../models/fortune_model.dart';
import '../../models/match_model.dart';
import '../../models/user_profile.dart';
import '../../services/auth/auth_service.dart';
import '../../services/database/firestore_service.dart';
import '../../services/fortune/fortune_calculator.dart';
import '../../services/fortune/fortune_service.dart';
import '../../services/profile/birth_profile_service.dart';
import '../../services/ideal_type/ideal_type_service.dart';
import '../../services/matches/matches_service.dart';
import '../../shared/widgets/app_components.dart';
import 'birth_time_completion_screen.dart';
import 'fortune_hub_controller.dart';
import 'fortune_route_names.dart';
import 'fortune_history_screen.dart';
import '../ideal_type/ideal_type_screen.dart';
import 'match_fortune_screen.dart';
import 'my_fortune_screen.dart';

/// 사주 탭 허브 화면 (하단 내비 3번째 탭).
///
/// 사주 관련 기능을 한 곳에 모은다:
/// - 오늘의 운세(애정 중심, 매일 갱신)
/// - 내 사주 요약 → 탭하면 [MyFortuneScreen] 상세로
/// - 매칭된 상대와 궁합 보기
///
/// 사주는 매칭 로직을 지배하지 않는 독립 코너다 — 여기서 매칭 순서를 바꾸거나
/// 스와이프 카드에 궁합 힌트를 얹지 않는다(의도적 제외).
class FortuneHubScreen extends StatefulWidget {
  final AuthService authService;
  final FirestoreService firestoreService;
  final MatchesService matchesService;
  final FortuneService fortuneService;

  /// "새로운 인연을 만나보세요" CTA 탭 시 둘러보기 탭으로 전환한다.
  final VoidCallback onExploreTap;

  /// 이 화면이 보이는 탭인지. [MainShell]이 IndexedStack으로 State를 보존하므로,
  /// 탭 재진입은 initState가 아니라 이 값의 false→true 전환으로 알 수 있다.
  final bool isActive;

  /// 테스트용 시계 주입. production에서는 [DateTime.now]를 쓴다.
  final DateTime Function()? nowProvider;

  const FortuneHubScreen({
    super.key,
    required this.authService,
    required this.firestoreService,
    required this.matchesService,
    required this.fortuneService,
    required this.onExploreTap,
    this.isActive = true,
    this.nowProvider,
  });

  @override
  State<FortuneHubScreen> createState() => _FortuneHubScreenState();
}

class _FortuneHubScreenState extends State<FortuneHubScreen>
    with WidgetsBindingObserver {
  late final FortuneHubController _controller;
  final _birthProfileService = BirthProfileService();
  final _idealTypeService = IdealTypeService();

  /// 시간을 몰라요로 저장한 사용자가 "지금 입력"을 골랐을 때만 true.
  /// 컨트롤러의 needsBirthProfile 판정과는 별개의 사용자 선택이다.
  bool _birthTimeRequested = false;

  Stream<List<MatchWithProfile>>? _matchesStream;

  Future<T?> _pushFortuneDetail<T>({
    required String routeName,
    required WidgetBuilder builder,
  }) {
    // 사주 상세 라우트가 중간에 남으면 pop 전환 중 내 사주 화면이 비칠 수 있다.
    // 항상 루트(MainShell) 바로 위에 현재 상세 화면만 쌓아 깜빡임을 막는다.
    return Navigator.of(context).pushAndRemoveUntil<T>(
      MaterialPageRoute<T>(
        settings: RouteSettings(name: routeName),
        builder: builder,
      ),
      (route) => route.isFirst,
    );
  }

  @override
  void initState() {
    super.initState();
    final uid = widget.authService.currentUser?.uid;
    if (uid != null) {
      _matchesStream = widget.matchesService.watchMatches(currentUid: uid);
    }
    _controller = FortuneHubController(
      fortuneService: widget.fortuneService,
      loadProfile: widget.firestoreService.getUserProfile,
      initialUid: uid,
      nowProvider: widget.nowProvider,
    )..addListener(_onControllerChanged);
    WidgetsBinding.instance.addObserver(this);
    _controller.loadInitial();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller
      ..removeListener(_onControllerChanged)
      ..dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant FortuneHubScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 비활성 → 활성으로 바뀐 순간에만 1회. 활성 상태의 rebuild는 통과시키지
    // 않으므로 탭 안에서 setState가 반복돼도 중복 요청이 생기지 않는다.
    if (!oldWidget.isActive && widget.isActive) _syncAccountAndDate();
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  /// 계정이 바뀌었으면 계정 전환을, 아니면 날짜 재확인을 수행한다.
  void _syncAccountAndDate() {
    final uid = widget.authService.currentUser?.uid;
    if (uid != _controller.activeUid) {
      _controller.updateAccount(uid);
      return;
    }
    _controller.handleResume();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state != AppLifecycleState.resumed) return;
    // 계정이 바뀌어 있으면 이전 사용자 결과를 먼저 버린다.
    _syncAccountAndDate();
  }

  /// 상세 화면에서 돌아왔을 때도 날짜 context를 다시 확인한다.
  void _onReturnFromDetail() {
    if (!mounted) return;
    _controller.handleResume();
  }

  void _openMyFortune() {
    final profile = _controller.profile;
    if (profile == null) return;
    _pushFortuneDetail<void>(
      routeName: FortuneRouteNames.my,
      builder: (_) => MyFortuneScreen(
        profile: profile,
        fortuneService: widget.fortuneService,
        // 시간을 몰라요로 저장한 사용자도 나중에 추가할 수 있게 한다.
        onAddBirthTime: profile.birthProfile.hasKnownTime
            ? null
            : () {
                Navigator.of(context).pop();
                setState(() => _birthTimeRequested = true);
              },
      ),
    ).then((_) => _onReturnFromDetail());
  }

  void _openFortuneHistory() {
    if (_controller.activeUid == null) return;
    _pushFortuneDetail<void>(
      routeName: FortuneRouteNames.history,
      // 같은 controller를 넘겨 오늘 운세와 최근 기록이 같은 KST 날짜·계정
      // context를 공유하게 한다. 소유권은 이 화면에 남는다(dispose하지 않는다).
      builder: (_) => FortuneHistoryScreen(controller: _controller),
    ).then((_) => _onReturnFromDetail());
  }

  void _openIdealType() {
    final profile = _controller.profile;
    if (profile == null) return;
    _pushFortuneDetail<void>(
      routeName: FortuneRouteNames.idealType,
      builder: (_) => IdealTypeScreen(
        profile: profile,
        idealTypeService: _idealTypeService,
      ),
    ).then((_) => _onReturnFromDetail());
  }

  void _openMatchFortune(MatchWithProfile match) {
    final uid = widget.authService.currentUser?.uid;
    if (uid == null) return;

    _pushFortuneDetail<void>(
      routeName: FortuneRouteNames.match,
      builder: (_) => MatchFortuneScreen(
        matchId: match.match.matchId,
        currentUid: uid,
        otherProfile: match.otherProfile,
        firestoreService: widget.firestoreService,
        fortuneService: widget.fortuneService,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 2줄 타이틀이라 큰 글자 설정에서 기본 toolbarHeight(60)를 넘길 수 있다.
    // 넘치면 AppBar에서 overflow가 나므로 배율만큼 늘려준다.
    final textScale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.6);
    return Scaffold(
      backgroundColor: AppColors.warmCanvas,
      appBar: AppBar(
        toolbarHeight: 60 * textScale,
        // 캔버스와 같은 색 + elevation 0으로, 기본 Material AppBar처럼
        // 콘텐츠 위에 떠 보이지 않게 한다.
        backgroundColor: AppColors.warmCanvas,
        surfaceTintColor: AppColors.warmCanvas,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleSpacing: AppSpacing.screenH,
        title: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('사주', style: AppTextStyles.screenTitle),
            SizedBox(height: 2),
            Text('오늘의 흐름과 인연을 확인해보세요', style: AppTextStyles.caption),
          ],
        ),
      ),
      body: SafeArea(child: _buildBody()),
    );
  }

  Widget _buildBody() {
    final status = _controller.dailyStatus;
    final profile = _controller.profile;

    // 기존 사용자 출생시간 보완 — 저장하면 다시 표시되지 않는다.
    final needsBirthTime =
        status == DailyFortuneStatus.needsBirthProfile || _birthTimeRequested;
    if (needsBirthTime && profile != null) {
      return BirthTimeCompletionScreen(
        key: const Key('daily-fortune-needs-birth-profile'),
        birthDate: profile.birthDate,
        birthProfileService: _birthProfileService,
        onCompleted: () {
          setState(() => _birthTimeRequested = false);
          _controller.refreshAfterBirthProfileCompleted();
        },
      );
    }

    switch (status) {
      case DailyFortuneStatus.idle:
      case DailyFortuneStatus.loading:
        return const _FortuneHubLoadingState(key: Key('daily-fortune-loading'));
      case DailyFortuneStatus.rateLimited:
        return _FortuneHubErrorState(
          key: const Key('daily-fortune-rate-limited'),
          icon: Icons.hourglass_bottom_rounded,
          tone: _FortuneHubStateTone.warning,
          title: '조금만 기다려 주세요',
          message: '요청이 많아요. 잠시 후 다시 시도해 주세요.',
          onRetry: _controller.retryDaily,
        );
      case DailyFortuneStatus.unavailable:
        return _FortuneHubErrorState(
          key: const Key('daily-fortune-unavailable'),
          icon: Icons.wifi_tethering_off_rounded,
          tone: _FortuneHubStateTone.neutral,
          title: '연결이 불안정해요',
          message: '오늘의 운세를 불러오지 못했어요.\n네트워크를 확인하고 다시 시도해 주세요.',
          onRetry: _controller.retryDaily,
        );
      case DailyFortuneStatus.error:
        return _FortuneHubErrorState(
          key: const Key('daily-fortune-error'),
          icon: Icons.error_outline_rounded,
          tone: _FortuneHubStateTone.danger,
          title: '잠시 문제가 생겼어요',
          message: '오늘의 운세를 불러오지 못했어요.',
          onRetry: _controller.retryDaily,
        );
      case DailyFortuneStatus.needsBirthProfile:
        // 프로필이 아직 없으면 위 분기를 못 탄다. 로딩으로 유지한다.
        return const _FortuneHubLoadingState(key: Key('daily-fortune-loading'));
      case DailyFortuneStatus.ready:
        break;
    }

    final daily = _controller.dailyFortune;
    final zodiac = _controller.zodiac;
    final saju = _controller.saju;
    // saju/zodiac은 profile에서 계산되므로 여기서 profile이 null일 수는 없지만,
    // 타입상 non-null이 보장되지 않으므로 같은 가드에 포함시킨다.
    if (daily == null || zodiac == null || saju == null || profile == null) {
      return const SizedBox.shrink();
    }

    // 화면은 기능 카드 목록이 아니라 3개 구역으로 읽힌다:
    //   A. Today Insight  — 캔버스 위 editorial 히어로(카드 아님)
    //   B. My Insight     — 프로필/사주에서 뽑은 개인화 문장 + 실제 7일 흐름
    //   C. Connection     — 실제 매칭 상대 사진 + AI 이상형 preview
    // 각 블록은 아이콘이 아니라 실제 데이터(점수/추이/사진/개인화 문장)를
    // 시각 중심에 둔다.
    final horizontal = MediaQuery.sizeOf(context).width < 360
        ? AppSpacing.screenHCompact
        : AppSpacing.screenH;

    return ListView(
      key: const Key('daily-fortune-ready'),
      padding: EdgeInsets.fromLTRB(
        horizontal,
        0,
        horizontal,
        40 + MediaQuery.of(context).padding.bottom,
      ),
      children: [
        // ── A. Today Insight ────────────────────────────────────────────────
        AppFadeSlideIn(
          child: _TodayInsight(
            daily: daily,
            dateKey:
                _controller.loadedDailyDateKey ?? _controller.currentDateKey,
            onOpenHistory: _openFortuneHistory,
          ),
        ),
        const SizedBox(height: AppSpacing.xxl),

        // ── B. My Insight ───────────────────────────────────────────────────
        AppFadeSlideIn(
          delay: AppMotion.staggerDelay(1),
          child: const AppSectionHeader(
            title: '내 인사이트',
            subtitle: '타고난 기운과 최근 애정운의 흐름',
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        AppFadeSlideIn(
          delay: AppMotion.staggerDelay(1),
          child: _MyInsightCard(
            profile: profile,
            zodiac: zodiac,
            saju: saju,
            history: _controller.history,
            historyStatus: _controller.historyStatus,
            onTap: _openMyFortune,
          ),
        ),
        const SizedBox(height: AppSpacing.xxl),

        // ── C. Connection ───────────────────────────────────────────────────
        AppFadeSlideIn(
          delay: AppMotion.staggerDelay(2),
          child: const AppSectionHeader(
            title: '인연',
            subtitle: '이미 이어진 사람과, 아직 만나지 않은 사람',
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        AppFadeSlideIn(
          delay: AppMotion.staggerDelay(2),
          child: _MatchFortuneSection(
            matchesStream: _matchesStream,
            onTapMatch: _openMatchFortune,
            onExploreTap: widget.onExploreTap,
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        AppFadeSlideIn(
          delay: AppMotion.staggerDelay(3),
          child: _IdealTypePreviewCard(onTap: _openIdealType),
        ),
        const SizedBox(height: AppSpacing.xxl),

        // 둘러보기(Discovery)로 보내는 보조 CTA. 화면의 primary는 콘텐츠이므로
        // 여기서는 outline 위계를 유지한다.
        AppFadeSlideIn(
          delay: AppMotion.staggerDelay(4),
          child: AppBrandButton(
            label: '새로운 인연을 만나보세요',
            variant: AppBrandButtonVariant.outline,
            onPressed: widget.onExploreTap,
          ),
        ),
      ],
    );
  }
}

/// 로딩 중에도 화면 레이아웃(히어로 + 카드 2개)이 유지되도록 자리를 잡아준다.
/// 이전 날짜/이전 계정의 운세를 다시 보여주지 않는다 — placeholder만 그린다.
class _FortuneHubLoadingState extends StatelessWidget {
  const _FortuneHubLoadingState({super.key});

  @override
  Widget build(BuildContext context) {
    final horizontal = MediaQuery.sizeOf(context).width < 360
        ? AppSpacing.screenHCompact
        : AppSpacing.screenH;
    return ListView(
      padding: EdgeInsets.fromLTRB(
        horizontal,
        AppSpacing.sm,
        horizontal,
        AppSpacing.xxl,
      ),
      physics: const NeverScrollableScrollPhysics(),
      children: [
        AppSurfaceCard(
          padding: const EdgeInsets.all(AppSpacing.heroPadding),
          elevated: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const _SkeletonBar(width: 148, height: 13),
                  const Spacer(),
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.brandPrimary.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.lg),
              const _SkeletonBar(width: 180, height: 26),
              const SizedBox(height: AppSpacing.lg),
              const _SkeletonBar(height: 13),
              const SizedBox(height: AppSpacing.sm),
              const _SkeletonBar(height: 13),
              const SizedBox(height: AppSpacing.sm),
              const _SkeletonBar(width: 210, height: 13),
              const SizedBox(height: AppSpacing.lg20),
              const _SkeletonBar(height: 44, radius: AppRadius.small),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        const AppSurfaceCard(
          child: Row(
            children: [
              _SkeletonBar(width: 40, height: 40, radius: AppRadius.small),
              SizedBox(width: AppSpacing.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _SkeletonBar(width: 92, height: 15),
                    SizedBox(height: AppSpacing.sm),
                    _SkeletonBar(height: 12),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        const AppSurfaceCard(
          child: Row(
            children: [
              _SkeletonBar(width: 40, height: 40, radius: AppRadius.small),
              SizedBox(width: AppSpacing.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _SkeletonBar(width: 120, height: 15),
                    SizedBox(height: AppSpacing.sm),
                    _SkeletonBar(height: 12),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 정적 placeholder 블록. 무한 반복 shimmer를 쓰지 않는다(패키지 추가 금지 +
/// 반복 애니메이션 최소화 원칙).
class _SkeletonBar extends StatelessWidget {
  final double? width;
  final double height;
  final double radius;

  const _SkeletonBar({
    this.width,
    required this.height,
    this.radius = AppRadius.chip,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: AppColors.canvasSubtle,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

enum _FortuneHubStateTone { neutral, warning, danger }

class _FortuneHubErrorState extends StatelessWidget {
  final IconData icon;
  final _FortuneHubStateTone tone;
  final String title;
  final String message;
  final VoidCallback onRetry;

  const _FortuneHubErrorState({
    super.key,
    required this.icon,
    required this.tone,
    required this.title,
    required this.message,
    required this.onRetry,
  });

  ({Color foreground, Color background}) get _accent => switch (tone) {
    _FortuneHubStateTone.neutral => (
      foreground: AppColors.textBody,
      background: AppColors.canvasSubtle,
    ),
    _FortuneHubStateTone.warning => (
      foreground: AppColors.statusWarning,
      background: AppColors.statusWarningSoft,
    ),
    _FortuneHubStateTone.danger => (
      foreground: AppColors.statusDanger,
      background: AppColors.statusDangerSoft,
    ),
  };

  @override
  Widget build(BuildContext context) {
    final minHeight =
        MediaQuery.sizeOf(context).height -
        kToolbarHeight -
        MediaQuery.paddingOf(context).vertical;
    final safeMinHeight = minHeight < 0 ? 0.0 : minHeight;
    final accent = _accent;

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.screenH,
        vertical: AppSpacing.xl,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: safeMinHeight),
        child: Center(
          child: AppFadeSlideIn(
            child: AppSurfaceCard(
              padding: const EdgeInsets.all(AppSpacing.xl),
              elevated: true,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        color: accent.background,
                        borderRadius: BorderRadius.circular(AppRadius.small),
                      ),
                      child: Icon(icon, size: 26, color: accent.foreground),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: AppTextStyles.cardTitle,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    style: AppTextStyles.bodySecondary,
                  ),
                  const SizedBox(height: AppSpacing.lg20),
                  AppBrandButton(
                    key: const Key('daily-fortune-retry'),
                    label: '다시 시도',
                    icon: Icons.refresh_rounded,
                    onPressed: onRetry,
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

/// ── A. Today Insight ────────────────────────────────────────────────────────
///
/// 이 블록은 카드가 아니다. 캔버스 위에 직접 타이포와 콘텐츠를 얹고, 보더 대신
/// 시그니처 모티프(두 점 + 연결 곡선)와 아주 옅은 브랜드 워시로만 영역을
/// 구분한다. "기능 카드 목록"의 첫 항목처럼 보이지 않게 하기 위해서다.
class _TodayInsight extends StatelessWidget {
  final DailyFortune daily;

  /// 이 운세가 속한 KST 날짜. 기기 로컬 날짜(`DateTime.now()`)로 라벨을 만들면
  /// 자정 근처나 다른 시간대 기기에서 카드 내용과 날짜가 어긋난다.
  final String dateKey;

  /// 히어로 내부 secondary action — 최근 기록으로 이동.
  final VoidCallback onOpenHistory;

  const _TodayInsight({
    required this.daily,
    required this.dateKey,
    required this.onOpenHistory,
  });

  static const _weekdays = ['월', '화', '수', '목', '금', '토', '일'];

  @override
  Widget build(BuildContext context) {
    final parts = dateKey.split('-');
    final date = DateTime.utc(
      int.tryParse(parts.first) ?? 2000,
      parts.length > 1 ? int.tryParse(parts[1]) ?? 1 : 1,
      parts.length > 2 ? int.tryParse(parts[2]) ?? 1 : 1,
    );
    final dateLabel =
        '${date.month}월 ${date.day}일 (${_weekdays[date.weekday - 1]})';

    return Stack(
      children: [
        // 시그니처 모티프. 장식이지만 반복 애니메이션은 아니고, 진입 시 곡선이
        // 한 번 이어지는 연출만 한다.
        Positioned(
          top: 0,
          right: -8,
          width: 132,
          height: 96,
          child: IgnorePointer(
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: AppMotion.entrance * 2,
              curve: AppMotion.emphasized,
              builder: (context, t, _) =>
                  ConnectionMotif(progress: t, opacity: 0.9),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(
            top: AppSpacing.lg,
            bottom: AppSpacing.xs,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('$dateLabel의 애정운', style: AppTextStyles.label),
              const SizedBox(height: AppSpacing.md),
              // 히어로 문구는 모티프 영역을 침범하지 않도록 폭을 제한한다.
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 260),
                child: Text(daily.mood, style: AppTextStyles.insight),
              ),
              const SizedBox(height: AppSpacing.md),
              Text(daily.message, style: AppTextStyles.body),
              const SizedBox(height: AppSpacing.lg20),
              _LoveScoreMeter(score: daily.loveScore),
              const SizedBox(height: AppSpacing.lg20),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.lg,
                  vertical: AppSpacing.md,
                ),
                decoration: BoxDecoration(
                  color: AppColors.surfaceMintSoft,
                  borderRadius: BorderRadius.circular(AppRadius.small),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.tips_and_updates_rounded,
                      size: 18,
                      color: AppColors.brandPrimaryStrong,
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Text(
                        daily.advice,
                        style: AppTextStyles.bodySecondary.copyWith(
                          color: AppColors.textStrong,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: onOpenHistory,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.sm,
                      vertical: AppSpacing.sm,
                    ),
                    foregroundColor: AppColors.brandPrimaryStrong,
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('지난 7일 기록 보기'),
                      SizedBox(width: 2),
                      Icon(Icons.arrow_forward_rounded, size: 15),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 애정운 1~5 인디케이터.
///
/// 세그먼트가 왼쪽부터 순차적으로 채워지며 한 번만 나타난다(반복 없음).
/// 색상만으로 값을 전달하지 않도록 "5점 중 N점" 텍스트를 함께 둔다.
/// 백분율(%)로 바꾸지 않는다 — 원래 척도의 의미를 유지한다.
class _LoveScoreMeter extends StatelessWidget {
  final int score;

  const _LoveScoreMeter({required this.score});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: AppMotion.entrance,
      curve: AppMotion.standard,
      builder: (context, t, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                for (var i = 0; i < 5; i++) ...[
                  if (i > 0) const SizedBox(width: 6),
                  Expanded(
                    child: Container(
                      height: 8,
                      decoration: BoxDecoration(
                        color: i < score
                            ? Color.lerp(
                                AppColors.canvasSubtle,
                                AppColors.brandPrimary,
                                ((t * 5) - i).clamp(0.0, 1.0),
                              )
                            : AppColors.canvasSubtle,
                        borderRadius: BorderRadius.circular(AppRadius.chip),
                      ),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Text('오늘의 애정운 5점 중 $score점', style: AppTextStyles.caption),
          ],
        );
      },
    );
  }
}

/// ── B. My Insight ───────────────────────────────────────────────────────────
///
/// 아이콘 + 제목 + chevron 카드 두 개를 나열하던 자리를, 실제 데이터가 시각
/// 중심이 되는 카드 하나로 합친다:
/// - 프로필/사주에서 뽑은 개인화 문장(새 계산·서버 호출 없음, 이미 로드된
///   [UserProfile]/[SajuInfo]/[ZodiacInfo]를 문장으로 조합하기만 한다)
/// - 컨트롤러가 이미 읽어둔 최근 7일 loveScore의 실제 추이
class _MyInsightCard extends StatelessWidget {
  final UserProfile profile;
  final ZodiacInfo zodiac;
  final SajuInfo saju;
  final List<FortuneHistoryEntry> history;
  final FortuneHistoryStatus historyStatus;
  final VoidCallback onTap;

  const _MyInsightCard({
    required this.profile,
    required this.zodiac,
    required this.saju,
    required this.history,
    required this.historyStatus,
    required this.onTap,
  });

  /// 이미 로드된 필드만 문장으로 조합한다. 값이 없으면 그 부분을 통째로 뺀다 —
  /// "정보를 입력해 주세요" 같은 빈 자리 문구로 카드를 채우지 않는다.
  String get _personalLine {
    final name = profile.displayName.trim();
    final subject = name.isEmpty ? '나는' : '$name님은';
    final traits = ProfileOptions.keysToLabels(
      ProfileOptions.personalities,
      profile.personalityTags,
    ).take(2).toList();

    final first = '$subject ${saju.element}의 기운을 타고난 ${zodiac.sign}예요.';
    if (traits.isEmpty) return first;
    return '$first 주변에는 ${traits.join(' · ')} 사람으로 남아요.';
  }

  List<String> get _chips {
    final mbti = (profile.mbti?.isNotEmpty ?? false) ? profile.mbti : null;
    final goal = profile.relationshipGoal == null
        ? null
        : ProfileOptions.keyToLabel(
            ProfileOptions.relationshipGoals,
            profile.relationshipGoal!,
          );
    return [
      zodiac.sign,
      '오행 ${saju.element}',
      '일간 ${saju.dayMaster}',
      ?mbti,
      ?goal,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final scored = history
        .map((entry) => entry.fortune?.loveScore)
        .toList(growable: false);
    final recordedCount = scored.whereType<int>().length;

    return AppSurfaceCard(
      padding: const EdgeInsets.all(AppSpacing.lg20),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_personalLine, style: AppTextStyles.body.copyWith(height: 1.55)),
          const SizedBox(height: AppSpacing.lg),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [for (final label in _chips) _InsightChip(label: label)],
          ),
          const SizedBox(height: AppSpacing.lg20),
          const Divider(height: 1, color: AppColors.borderSubtle),
          const SizedBox(height: AppSpacing.lg),
          Row(
            children: [
              Expanded(
                child: Text(
                  recordedCount >= 2
                      ? '최근 7일 애정운 흐름 · $recordedCount일 기록됨'
                      : '최근 7일 애정운 흐름',
                  style: AppTextStyles.caption,
                ),
              ),
              const Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: AppColors.textMuted,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          SizedBox(
            height: 46,
            child:
                historyStatus == FortuneHistoryStatus.ready &&
                    recordedCount >= 2
                ? _SevenDayTrend(scores: scored)
                : const _TrendEmptyPreview(),
          ),
        ],
      ),
    );
  }
}

/// 사주/프로필 요소를 표시하는 작은 뉴트럴 칩. 전통 문양/금색 장식 대신
/// 절제된 정보 태그로만 다룬다.
class _InsightChip extends StatelessWidget {
  final String label;

  const _InsightChip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: 6,
      ),
      decoration: BoxDecoration(
        color: AppColors.surfaceSecondary,
        borderRadius: BorderRadius.circular(AppRadius.chip),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppTextStyles.caption.copyWith(
          color: AppColors.textBody,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// 최근 7일 loveScore 스파크라인. 컨트롤러가 **이미 읽어둔** history를 그리기만
/// 한다 — 새 계산도, 새 요청도 없다. 기록이 없는 날은 점을 찍지 않고 선을
/// 잇기만 해서 "앱을 열지 않은 날"과 "점수 0"이 혼동되지 않게 한다.
class _SevenDayTrend extends StatelessWidget {
  /// 과거→오늘 순서가 아니라 컨트롤러가 주는 순서(오늘이 index 0)를 그대로
  /// 받는다. 그리기 직전에만 뒤집어 시간순으로 표시한다.
  final List<int?> scores;

  const _SevenDayTrend({required this.scores});

  @override
  Widget build(BuildContext context) {
    final chronological = scores.reversed.toList(growable: false);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: AppMotion.entrance * 2,
      curve: AppMotion.standard,
      builder: (context, t, _) => CustomPaint(
        painter: _SevenDayTrendPainter(scores: chronological, progress: t),
        size: Size.infinite,
      ),
    );
  }
}

class _SevenDayTrendPainter extends CustomPainter {
  final List<int?> scores;
  final double progress;

  _SevenDayTrendPainter({required this.scores, required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    if (scores.length < 2 || size.isEmpty) return;

    const minScore = 1.0;
    const maxScore = 5.0;
    const topPad = 6.0;
    const bottomPad = 6.0;
    final usableHeight = size.height - topPad - bottomPad;
    if (usableHeight <= 0) return;

    final stepX = size.width / (scores.length - 1);
    double yFor(double score) =>
        topPad +
        (1 - (score - minScore) / (maxScore - minScore)) * usableHeight;

    // 기록이 있는 지점만 잇는다. 중간에 빈 날이 있어도 선은 이어지되 점은 없다.
    final points = <Offset>[];
    for (var i = 0; i < scores.length; i++) {
      final score = scores[i];
      if (score == null) continue;
      points.add(Offset(i * stepX, yFor(score.toDouble())));
    }
    if (points.length < 2) return;

    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (var i = 1; i < points.length; i++) {
      final prev = points[i - 1];
      final next = points[i];
      final midX = (prev.dx + next.dx) / 2;
      path.cubicTo(midX, prev.dy, midX, next.dy, next.dx, next.dy);
    }

    // 왼쪽부터 선이 그려지는 reveal. 반복하지 않는 1회 연출이다.
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, size.width * progress, size.height));
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = AppColors.brandPrimary,
    );
    canvas.restore();

    for (final point in points) {
      if (point.dx > size.width * progress + 1) continue;
      final isLast = point == points.last;
      canvas.drawCircle(
        point,
        isLast ? 4.2 : 2.6,
        Paint()..color = AppColors.surfacePrimary,
      );
      canvas.drawCircle(
        point,
        isLast ? 4.2 : 2.6,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = isLast ? 2.4 : 1.6
          ..color = AppColors.brandPrimary,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SevenDayTrendPainter old) =>
      old.progress != progress || old.scores != scores;
}

/// 기록이 부족할 때의 정돈된 empty preview. 오류처럼 보이지 않게 한다.
class _TrendEmptyPreview extends StatelessWidget {
  const _TrendEmptyPreview();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceSecondary,
        borderRadius: BorderRadius.circular(AppRadius.small),
      ),
      alignment: Alignment.center,
      child: const Text('기록이 쌓이면 흐름이 그려져요', style: AppTextStyles.caption),
    );
  }
}

/// ── C. Connection — AI 이상형 ───────────────────────────────────────────────
///
/// 생성된 이상형 이미지의 thumbnail을 쓰는 것이 이상적이지만, 이 화면은
/// 이상형 결과를 읽어오지 않는다(읽어오려면 Firestore 조회를 새로 추가해야
/// 하고, 그건 디자인 범위를 넘는다). 그래서 아이콘 하나 대신 시그니처
/// 모티프 기반 abstract visual preview를 카드의 시각 중심으로 쓴다.
class _IdealTypePreviewCard extends StatelessWidget {
  final VoidCallback onTap;

  const _IdealTypePreviewCard({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return AppSurfaceCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      onTap: onTap,
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.small),
            child: SizedBox(
              width: 84,
              height: 84,
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      AppColors.expressiveAccentSoft,
                      AppColors.brandPrimarySoft,
                    ],
                  ),
                ),
                child: TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: 1),
                  duration: AppMotion.entrance * 2,
                  curve: AppMotion.emphasized,
                  builder: (context, t, _) => ConnectionMotif(
                    progress: t,
                    accentColor: AppColors.expressiveAccent,
                    strokeWidth: 2,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.lg),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('AI 이상형', style: AppTextStyles.cardTitle),
                SizedBox(height: 4),
                Text('아직 만나지 않은 사람의 얼굴을 그려봐요', style: AppTextStyles.caption),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          const Icon(
            Icons.chevron_right_rounded,
            size: 22,
            color: AppColors.textMuted,
          ),
        ],
      ),
    );
  }
}

/// ── C. Connection — 궁합 ───────────────────────────────────────────────────
///
/// 상대의 실제 프로필 사진을 카드의 시각 중심에 둔다. 목록 전체를 나열하지
/// 않고 최근 3명까지만 preview하고, 나머지는 개수로만 알린다 — 사주 허브는
/// 매칭 목록의 복제본이 아니기 때문이다.
class _MatchFortuneSection extends StatelessWidget {
  static const int _previewLimit = 3;

  final Stream<List<MatchWithProfile>>? matchesStream;
  final ValueChanged<MatchWithProfile> onTapMatch;
  final VoidCallback onExploreTap;

  const _MatchFortuneSection({
    required this.matchesStream,
    required this.onTapMatch,
    required this.onExploreTap,
  });

  @override
  Widget build(BuildContext context) {
    final stream = matchesStream;
    if (stream == null) return _ConnectionEmptyPreview(onTap: onExploreTap);

    return StreamBuilder<List<MatchWithProfile>>(
      stream: stream,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const AppSurfaceCard(
            child: Row(
              children: [
                SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: AppSpacing.md),
                Text('불러오는 중이에요', style: AppTextStyles.caption),
              ],
            ),
          );
        }
        final matches = snap.data ?? [];
        if (matches.isEmpty) {
          return _ConnectionEmptyPreview(onTap: onExploreTap);
        }

        final preview = matches.take(_previewLimit).toList(growable: false);
        final remaining = matches.length - preview.length;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final mwp in preview) ...[
              _MatchFortuneTile(mwp: mwp, onTap: () => onTapMatch(mwp)),
              const SizedBox(height: AppSpacing.sm),
            ],
            if (remaining > 0)
              Padding(
                padding: const EdgeInsets.only(
                  top: AppSpacing.xs,
                  left: AppSpacing.xs,
                ),
                child: Text(
                  '외 $remaining명과 이어져 있어요',
                  style: AppTextStyles.caption,
                ),
              ),
          ],
        );
      },
    );
  }
}

/// 아직 매칭이 없을 때. 오류나 잠긴 기능처럼 보이지 않도록, 시그니처 모티프로
/// "아직 이어지지 않은 두 점"을 그대로 보여준다.
class _ConnectionEmptyPreview extends StatelessWidget {
  final VoidCallback onTap;

  const _ConnectionEmptyPreview({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return AppSurfaceCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      onTap: onTap,
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.small),
            child: Container(
              width: 84,
              height: 84,
              color: AppColors.surfaceSecondary,
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: 1),
                duration: AppMotion.entrance * 2,
                curve: AppMotion.emphasized,
                builder: (context, t, _) =>
                    ConnectionMotif(progress: t, strokeWidth: 2, opacity: 0.85),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.lg),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('아직 이어진 인연이 없어요', style: AppTextStyles.cardTitle),
                SizedBox(height: 4),
                Text(
                  '매칭이 생기면 두 사람의 흐름을 여기서 읽을 수 있어요',
                  style: AppTextStyles.caption,
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          const Icon(
            Icons.chevron_right_rounded,
            size: 22,
            color: AppColors.textMuted,
          ),
        ],
      ),
    );
  }
}

/// 매칭 상대 한 명. 사진이 카드의 시각 중심이고, 텍스트는 그 옆을 받친다.
class _MatchFortuneTile extends StatelessWidget {
  final MatchWithProfile mwp;
  final VoidCallback onTap;
  const _MatchFortuneTile({required this.mwp, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final profile = mwp.otherProfile;
    final photoUrl = profile.photoUrls.isNotEmpty ? profile.photoUrls[0] : null;

    return AppSurfaceCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      onTap: onTap,
      child: Row(
        children: [
          // 실제 프로필 사진. 실패/미등록이면 뉴트럴 플레이스홀더로 떨어진다.
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.small),
            child: Container(
              width: 64,
              height: 64,
              color: AppColors.surfaceSecondary,
              child: photoUrl == null
                  ? const Icon(
                      Icons.person_rounded,
                      color: AppColors.textMuted,
                      size: 26,
                    )
                  : Image.network(
                      photoUrl,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const Icon(
                        Icons.person_rounded,
                        color: AppColors.textMuted,
                        size: 26,
                      ),
                    ),
            ),
          ),
          const SizedBox(width: AppSpacing.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${profile.displayName}, ${profile.age}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.cardTitle.copyWith(fontSize: 15),
                ),
                const SizedBox(height: 4),
                // 두 사람이 이어져 있다는 사실 자체를 모티프로 표시한다.
                Row(
                  children: [
                    SizedBox(
                      width: 34,
                      height: 14,
                      child: TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0, end: 1),
                        duration: AppMotion.entrance * 2,
                        curve: AppMotion.emphasized,
                        builder: (context, t, _) =>
                            ConnectionMotif(progress: t, strokeWidth: 1.2),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    const Expanded(
                      child: Text(
                        '서버 공개 API 연결 후 제공 예정',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.caption,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          const Icon(
            Icons.chevron_right_rounded,
            size: 22,
            color: AppColors.textMuted,
          ),
        ],
      ),
    );
  }
}
