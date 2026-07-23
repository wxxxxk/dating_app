import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/constants/profile_options.dart';
import '../../core/theme/app_colors.dart';
import '../../models/ideal_type_model.dart';
import '../../models/user_profile.dart';
import '../../services/ideal_type/ideal_type_service.dart';
import '../../shared/widgets/app_components.dart';

class IdealTypeScreen extends StatefulWidget {
  final UserProfile profile;
  final IdealTypeService idealTypeService;

  const IdealTypeScreen({
    super.key,
    required this.profile,
    required this.idealTypeService,
  });

  @override
  State<IdealTypeScreen> createState() => _IdealTypeScreenState();
}

class _IdealTypeScreenState extends State<IdealTypeScreen> {
  late IdealTypeImageOptions _options;
  IdealTypeImageResult? _result;
  String? _errorMessage;
  bool _loadingCache = true;
  bool _generating = false;

  final _optionsSectionKey = GlobalKey();
  final _scrollController = ScrollController();
  late final TextEditingController _refinementController;

  @override
  void initState() {
    super.initState();
    final initialGender = widget.profile.discoveryFilter.gender;
    final gender = ['male', 'female'].contains(initialGender)
        ? initialGender
        : 'all';
    _options = IdealTypeImageOptions(
      gender: gender,
      idealTags: widget.profile.idealTags,
      mood: IdealTypeOptionSets.defaultMoodForGender(gender),
      style: IdealTypeOptionSets.defaultStyleForGender(gender),
      hair: IdealTypeOptionSets.defaultHairForGender(gender),
      impression: IdealTypeOptionSets.defaultImpressionForGender(gender),
      background: 'studio',
    );
    _refinementController = TextEditingController();
    _loadCached();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _refinementController.dispose();
    super.dispose();
  }

  void _selectGender(String gender) {
    final nextHair =
        IdealTypeOptionSets.isHairValidForGender(gender, _options.hair)
        ? _options.hair
        : IdealTypeOptionSets.defaultHairForGender(gender);
    final nextMood =
        IdealTypeOptionSets.isMoodValidForGender(gender, _options.mood)
        ? _options.mood
        : IdealTypeOptionSets.defaultMoodForGender(gender);
    final nextStyle =
        IdealTypeOptionSets.isStyleValidForGender(gender, _options.style)
        ? _options.style
        : IdealTypeOptionSets.defaultStyleForGender(gender);
    final nextImpression =
        IdealTypeOptionSets.isImpressionValidForGender(
          gender,
          _options.impression,
        )
        ? _options.impression
        : IdealTypeOptionSets.defaultImpressionForGender(gender);
    setState(
      () => _options = _options.copyWith(
        gender: gender,
        hair: nextHair,
        mood: nextMood,
        style: nextStyle,
        impression: nextImpression,
      ),
    );
  }

  Future<void> _loadCached() async {
    try {
      final cached = await widget.idealTypeService.getCachedImage(
        widget.profile.uid,
      );
      if (mounted) {
        setState(() {
          _result = cached;
          // "선택한 취향" 칩은 항상 _options(현재 선택 상태)를 그대로 보여준다.
          // initState에서 _options는 기본값으로 새로 초기화되므로, 캐시에
          // 저장된 이전 생성 결과의 옵션과 맞춰두지 않으면 "화면에 보이는
          // 이미지"와 "선택한 취향 칩"이 서로 다른 조건을 표시하는 것처럼
          // 보일 수 있다(재진입할 때마다 매번 발생 가능한 혼동 — 실제
          // 서버 응답이 잘못된 게 아니라 클라이언트 로컬 상태가 리셋된
          // 것뿐이다). refinementText는 매번 새로 입력하는 값이라 여기서는
          // 복원하지 않는다.
          final cachedOptions = cached?.options;
          if (cachedOptions != null) {
            _options = _options.copyWith(
              gender: cachedOptions.gender,
              mood: cachedOptions.mood,
              style: cachedOptions.style,
              hair: cachedOptions.hair,
              impression: cachedOptions.impression,
              background: cachedOptions.background,
            );
          }
        });
      }
    } catch (e, stackTrace) {
      // 캐시 조회 실패는 이미지 생성 화면 진입을 막지 않는다. 상세 원인은 개발 로그에만 남긴다.
      if (kDebugMode) {
        debugPrint('[IdealType] 캐시 조회 실패: $e');
        debugPrint('$stackTrace');
      }
    } finally {
      if (mounted) setState(() => _loadingCache = false);
    }
  }

  Future<void> _generate() async {
    if (_generating) return;
    setState(() {
      _generating = true;
      _errorMessage = null;
    });
    try {
      final result = await widget.idealTypeService.generateImage(
        options: _options,
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        _errorMessage = null;
      });
      _showSnack('이상형 이미지가 준비됐어요.');
    } catch (e, stackTrace) {
      if (kDebugMode) {
        debugPrint('[IdealType] 이미지 생성 실패: $e');
        debugPrint('$stackTrace');
      }
      if (!mounted) return;
      setState(() => _errorMessage = _friendlyErrorMessage(e));
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  String _friendlyErrorMessage(Object error) {
    // 서버(HttpsError)가 보낸 메시지는 전부 사용자에게 보여줘도 되도록 미리
    // 다듬어둔 문구다(raw exception이 아니다) — 있으면 그대로 쓰고, 없으면
    // 일반 문구로 대체한다.
    if (error is FirebaseFunctionsException) {
      final message = error.message;
      if (message != null && message.trim().isNotEmpty) return message;
    }
    return '잠시 후 다시 시도하거나 다른 스타일로 시도해보세요.';
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _scrollToOptions() {
    final ctx = _optionsSectionKey.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      duration: AppDurations.base,
      curve: AppCurves.standard,
    );
  }

  double get _horizontalPadding => MediaQuery.sizeOf(context).width < 360
      ? AppSpacing.screenHCompact
      : AppSpacing.screenH;

  @override
  Widget build(BuildContext context) {
    final result = _result;
    final horizontal = _horizontalPadding;

    return Scaffold(
      backgroundColor: AppColors.warmCanvas,
      appBar: AppBar(
        title: const Text('AI 이상형', style: AppTextStyles.cardTitle),
        backgroundColor: AppColors.warmCanvas,
        surfaceTintColor: AppColors.warmCanvas,
        foregroundColor: AppColors.textStrong,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: ListView(
        controller: _scrollController,
        padding: EdgeInsets.fromLTRB(
          horizontal,
          AppSpacing.xs,
          horizontal,
          // 하단 잘림 방지: 고정 28에 시스템 내비게이션 바(제스처/3버튼 모두)
          // 인셋을 더한다. 기기별로 이 인셋이 0일 수도, 클 수도 있어서
          // 하드코딩된 값만으로는 특정 기기에서 마지막 버튼이 잘릴 수 있었다.
          28 + MediaQuery.of(context).padding.bottom,
        ),
        children: [
          // ── A. Editorial header ─────────────────────────────────────────
          const _EditorialHeader(),
          const SizedBox(height: AppSpacing.lg20),

          // ── B. Visual stage ─────────────────────────────────────────────
          // 캐시 확인 / 결과 없음 / 생성 중 / 결과가 모두 같은 자리, 같은
          // 크기(1:1)에서 전환된다. 상태가 바뀌어도 레이아웃이 튀지 않는다.
          _IdealTypeVisualStage(
            loadingCache: _loadingCache,
            generating: _generating,
            result: result,
          ),
          if (!_loadingCache && !_generating && result != null) ...[
            const SizedBox(height: AppSpacing.sm),
            const Text('실제 앱 사용자가 아닙니다.', style: AppTextStyles.caption),
          ],
          const SizedBox(height: AppSpacing.lg),

          // ── C. 안전 고지 ────────────────────────────────────────────────
          const _SafetyNotice(),

          // ── D. 결과 리포트 (결과가 있을 때만) ─────────────────────────────
          if (!_loadingCache && !_generating && result != null) ...[
            const SizedBox(height: AppSpacing.xxl),
            _IdealTypeResultReport(
              // inputHash가 바뀌면 새로 마운트되어 등장 애니메이션이 다시
              // 재생된다(재생성할 때마다 "새 결과가 왔다"는 신호).
              key: ValueKey('report-${result.inputHash}'),
              result: result,
              options: _options,
              onRegenerate: _generate,
              onEditOptions: _scrollToOptions,
            ),
          ],
          const SizedBox(height: AppSpacing.xxl),

          // ── E. 취향 편집 ────────────────────────────────────────────────
          Container(
            key: _optionsSectionKey,
            child: _PreferenceEditor(
              options: _options,
              profile: widget.profile,
              onGenderSelected: _selectGender,
              onMoodSelected: (v) =>
                  setState(() => _options = _options.copyWith(mood: v)),
              onStyleSelected: (v) =>
                  setState(() => _options = _options.copyWith(style: v)),
              onHairSelected: (v) =>
                  setState(() => _options = _options.copyWith(hair: v)),
              onImpressionSelected: (v) =>
                  setState(() => _options = _options.copyWith(impression: v)),
              onBackgroundSelected: (v) =>
                  setState(() => _options = _options.copyWith(background: v)),
            ),
          ),
          const SizedBox(height: AppSpacing.xl),

          // ── F. 직접 수정 요청 ───────────────────────────────────────────
          _RefinementInput(
            controller: _refinementController,
            onChanged: (v) =>
                setState(() => _options = _options.copyWith(refinementText: v)),
          ),
          const SizedBox(height: AppSpacing.xl),

          // ── G. Primary CTA ──────────────────────────────────────────────
          AppBrandButton(
            label: _generating
                ? '이미지를 만들고 있어요'
                : (result == null ? '이상형 만들기' : '다시 생성'),
            icon: _generating ? null : Icons.auto_awesome_rounded,
            loading: _generating,
            onPressed: _generating ? null : _generate,
          ),

          // ── H. 생성 오류 ────────────────────────────────────────────────
          if (_errorMessage != null) ...[
            const SizedBox(height: AppSpacing.lg),
            _IdealImageErrorCard(
              message: _errorMessage!,
              onRetry: _generating ? null : _generate,
            ),
          ],
        ],
      ),
    );
  }
}

// ═══ A. Editorial header ═════════════════════════════════════════════════════

class _EditorialHeader extends StatelessWidget {
  const _EditorialHeader();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '나의 취향을 이미지로',
          style: AppTextStyles.caption.copyWith(
            color: AppColors.brandPrimaryStrong,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.4,
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        const Text('AI로 그려보는 나의 이상형', style: AppTextStyles.screenTitle),
        const SizedBox(height: AppSpacing.xs),
        const Text(
          '분위기와 스타일을 고르면 가상의 이상형 이미지를 만들어드려요.',
          style: AppTextStyles.bodySecondary,
        ),
      ],
    );
  }
}

// ═══ B. Visual stage ═════════════════════════════════════════════════════════

/// 이 화면의 모든 상태가 공유하는 단일 시각 프레임.
///
/// 항상 1:1 비율이고 radius/clip이 같아서, 캐시 확인 → 결과 없음 → 생성 중 →
/// 결과로 넘어가도 세로 크기가 변하지 않는다(레이아웃 점프 없음).
/// 생성 이미지가 정사각형 계약이므로 비율을 임의로 4:5로 바꾸지 않는다.
class _IdealTypeVisualStage extends StatelessWidget {
  final bool loadingCache;
  final bool generating;
  final IdealTypeImageResult? result;

  const _IdealTypeVisualStage({
    required this.loadingCache,
    required this.generating,
    required this.result,
  });

  Widget _stageChild() {
    if (loadingCache) {
      return const _CacheLoadingStage(key: ValueKey('stage-cache'));
    }
    if (generating) {
      return const _GeneratingStage(key: ValueKey('stage-generating'));
    }
    final current = result;
    if (current != null) {
      return _ResultStage(
        key: ValueKey('stage-${current.inputHash}'),
        result: current,
      );
    }
    return const _EmptyStage(key: ValueKey('stage-empty'));
  }

  /// 넓은 화면(태블릿/가로 모드)에서 1:1이 그대로 커지면 스테이지 하나가
  /// 화면을 다 먹는다. 비율은 유지하되 한 변의 상한만 둔다.
  static const double _maxSide = 420;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = constraints.maxWidth < _maxSide
            ? constraints.maxWidth
            : _maxSide;
        return Center(
          child: SizedBox(
            width: side,
            height: side,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.heroSoft),
              child: AnimatedSwitcher(
                duration: AppMotion.content,
                switchInCurve: AppMotion.standard,
                switchOutCurve: AppMotion.standard,
                child: _stageChild(),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// stage 배경으로 쓰는 아주 옅은 민트·코랄 tonal gradient.
/// 이미지가 있는 상태에서는 쓰지 않는다 — 사진이 주인공이다.
class _StageBackdrop extends StatelessWidget {
  final Widget child;

  const _StageBackdrop({required this.child});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppColors.surfacePrimary,
            AppColors.expressiveAccentSoft,
            AppColors.surfaceMintSoft,
          ],
          stops: [0.1, 0.6, 1],
        ),
        border: Border.all(color: AppColors.borderSubtle),
        borderRadius: BorderRadius.circular(AppRadius.heroSoft),
      ),
      child: child,
    );
  }
}

/// 캐시 확인 중. 오류 카드로 만들지 않고, 결과가 들어올 자리를 잡아둔다.
/// 이전 사용자/이전 결과의 이미지는 이 단계에서 절대 그리지 않는다.
class _CacheLoadingStage extends StatelessWidget {
  const _CacheLoadingStage({super.key});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '이전에 만든 이상형을 확인하고 있어요',
      child: ExcludeSemantics(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: AppColors.surfacePrimary,
            border: Border.all(color: AppColors.borderSubtle),
            borderRadius: BorderRadius.circular(AppRadius.heroSoft),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  color: AppColors.canvasSubtle,
                  borderRadius: BorderRadius.circular(AppRadius.surface),
                ),
              ),
              const SizedBox(height: AppSpacing.lg20),
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppColors.brandPrimary.withValues(alpha: 0.6),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              const Text('이전에 만든 이상형을 확인하고 있어요', style: AppTextStyles.caption),
            ],
          ),
        ),
      ),
    );
  }
}

/// 아직 아무것도 생성하지 않은 상태.
///
/// 두 점이 아직 완전히 이어지지 않은 모티프로 "곧 만들어질 무언가"를 암시한다.
/// 실제 얼굴 placeholder나 성별 일러스트는 쓰지 않는다.
class _EmptyStage extends StatelessWidget {
  const _EmptyStage({super.key});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '아직 생성한 이상형 이미지가 없습니다. 취향을 선택하면 이곳에 이미지가 나타납니다.',
      child: ExcludeSemantics(
        child: _StageBackdrop(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.xl),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // 비어 있는 초상 프레임 — 얼굴을 그리지 않고 자리만 암시한다.
                Container(
                  width: 108,
                  height: 132,
                  decoration: BoxDecoration(
                    color: AppColors.surfacePrimary.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(AppRadius.surface),
                    border: Border.all(
                      color: AppColors.brandPrimary.withValues(alpha: 0.28),
                    ),
                  ),
                  child: const Padding(
                    padding: EdgeInsets.all(AppSpacing.lg),
                    // 이 화면의 모티프는 여기 1회만. 두 점이 아직 이어지는
                    // 중이라는 뜻으로 progress를 끝까지 채우지 않는다.
                    child: ConnectionMotif(progress: 0.55, strokeWidth: 1.6),
                  ),
                ),
                const SizedBox(height: AppSpacing.lg20),
                const Text('아직 그려지지 않은 이상형', style: AppTextStyles.cardTitle),
                const SizedBox(height: AppSpacing.sm),
                const Text(
                  '취향을 선택하면 이곳에 가상의 이상형 이미지가 나타나요.',
                  textAlign: TextAlign.center,
                  style: AppTextStyles.caption,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 생성 중 상태.
///
/// 실제 진행률 신호가 없으므로 가짜 퍼센트·단계 표시를 만들지 않는다.
/// 기존 계약대로 1100ms pulse와 3초 문구 전환만 유지한다.
class _GeneratingStage extends StatefulWidget {
  const _GeneratingStage({super.key});

  @override
  State<_GeneratingStage> createState() => _GeneratingStageState();
}

class _GeneratingStageState extends State<_GeneratingStage>
    with SingleTickerProviderStateMixin {
  static const _messages = ['AI가 취향을 해석하고 있어요', '이미지를 생성하는 중이에요', '조금만 기다려주세요'];

  late final AnimationController _pulseController;
  int _messageIndex = 0;
  Timer? _messageTimer;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat(reverse: true);
    _messageTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!mounted) return;
      setState(() => _messageIndex = (_messageIndex + 1) % _messages.length);
    });
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _messageTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      label: _messages[_messageIndex],
      child: ExcludeSemantics(
        child: _StageBackdrop(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.xl),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 108,
                  height: 132,
                  decoration: BoxDecoration(
                    color: AppColors.surfacePrimary.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(AppRadius.surface),
                    border: Border.all(
                      color: AppColors.brandPrimary.withValues(alpha: 0.28),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    // 차분한 opacity pulse만. scale bounce·particle은 쓰지 않는다.
                    child: FadeTransition(
                      opacity: Tween<double>(
                        begin: 0.45,
                        end: 1,
                      ).animate(_pulseController),
                      child: const ConnectionMotif(strokeWidth: 1.6),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.lg20),
                AnimatedSwitcher(
                  duration: AppMotion.content,
                  child: Text(
                    _messages[_messageIndex],
                    key: ValueKey(_messageIndex),
                    textAlign: TextAlign.center,
                    style: AppTextStyles.cardTitle.copyWith(fontSize: 15),
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                const Text(
                  '완성되면 이곳에 이미지가 나타나요.',
                  textAlign: TextAlign.center,
                  style: AppTextStyles.caption,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 생성 결과 이미지.
///
/// 이미지가 주인공이므로 위에 얹는 것은 최소한이다 — 좌상단 배지와 하단
/// safetyLabel뿐. 모티프·옵션 칩·CTA·민트 glow는 올리지 않는다.
class _ResultStage extends StatelessWidget {
  final IdealTypeImageResult result;

  const _ResultStage({super.key, required this.result});

  @override
  Widget build(BuildContext context) {
    final hasUrl = result.imageUrl.trim().isNotEmpty;

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: AppMotion.entrance,
      curve: AppMotion.standard,
      builder: (context, t, child) => Opacity(
        opacity: t.clamp(0, 1),
        child: Transform.scale(scale: 0.985 + 0.015 * t, child: child),
      ),
      child: Semantics(
        image: true,
        label: 'AI로 생성한 이상형 이미지. ${result.safetyLabel}',
        child: ExcludeSemantics(
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (hasUrl)
                Image.network(
                  result.imageUrl,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const _StageImageFallback(),
                )
              else
                const _StageImageFallback(),
              // 아주 약한 하단 scrim — 배지/문구 가독성만 확보하고 사진을
              // 어둡게 덮지 않는다.
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: 108,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        AppColors.textStrong.withValues(alpha: 0),
                        AppColors.textStrong.withValues(alpha: 0.58),
                      ],
                    ),
                  ),
                ),
              ),
              const Positioned(
                left: AppSpacing.md,
                top: AppSpacing.md,
                child: _StageBadge(label: 'AI 생성 이미지'),
              ),
              Positioned(
                left: AppSpacing.md,
                right: AppSpacing.md,
                bottom: AppSpacing.md,
                child: Text(
                  result.safetyLabel,
                  style: AppTextStyles.caption.copyWith(
                    color: AppColors.textOnImage,
                    fontWeight: FontWeight.w700,
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

/// 이미지 URL이 비었거나 로딩에 실패했을 때. stage 크기는 그대로 두고,
/// 시스템 broken image 아이콘을 크게 띄우지 않는다.
class _StageImageFallback extends StatelessWidget {
  const _StageImageFallback();

  @override
  Widget build(BuildContext context) {
    return _StageBackdrop(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: AppColors.surfacePrimary.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(AppRadius.small),
            ),
            child: const Icon(
              Icons.image_not_supported_outlined,
              size: 24,
              color: AppColors.textMuted,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          const Text('이미지를 표시할 수 없어요', style: AppTextStyles.caption),
        ],
      ),
    );
  }
}

class _StageBadge extends StatelessWidget {
  final String label;

  const _StageBadge({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.brandPrimaryStrong.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(AppRadius.chip),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.auto_awesome_rounded,
            size: 12,
            color: AppColors.onBrandPrimary,
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: AppTextStyles.caption.copyWith(
              color: AppColors.onBrandPrimary,
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

// ═══ C. 안전 고지 ═════════════════════════════════════════════════════════════

/// 필수 고지. 문구를 숨기거나 줄이지 않되, 경고처럼 보이지 않게 뉴트럴
/// 서피스로만 구분한다(warning yellow / danger red 사용 금지).
class _SafetyNotice extends StatelessWidget {
  const _SafetyNotice();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      decoration: BoxDecoration(
        color: AppColors.surfaceSecondary,
        borderRadius: BorderRadius.circular(AppRadius.small),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline_rounded,
            color: AppColors.textMuted,
            size: 18,
          ),
          SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              'AI가 생성한 가상의 이미지입니다. 실제 앱 사용자가 아니며, 실존 인물을 의도하지 않습니다.',
              style: AppTextStyles.caption,
            ),
          ),
        ],
      ),
    );
  }
}

// ═══ D. 결과 리포트 ═══════════════════════════════════════════════════════════

/// 이미지 아래에 오는 읽기 영역 — AI 해석 + 이 이미지를 만든 조건 + 액션.
///
/// 이미지는 위쪽 visual stage가 담당하므로 여기서는 다시 그리지 않는다.
class _IdealTypeResultReport extends StatelessWidget {
  final IdealTypeImageResult result;
  final IdealTypeImageOptions options;
  final VoidCallback onRegenerate;
  final VoidCallback onEditOptions;

  const _IdealTypeResultReport({
    super.key,
    required this.result,
    required this.options,
    required this.onRegenerate,
    required this.onEditOptions,
  });

  /// 화면에 보이는 이미지를 만든 조건의 라벨. 값 자체는 [options]에서만 오고,
  /// 캐시 진입 시 `_loadCached`가 이미 result.options로 맞춰둔 상태다.
  List<({String label, String value})> _optionEntries() {
    String labelOf(List<IdealTypeOption> set, String key) {
      for (final option in set) {
        if (option.key == key) return option.label;
      }
      return key;
    }

    return [
      (
        label: '대상',
        value: labelOf(IdealTypeOptionSets.genders, options.gender),
      ),
      (
        label: '분위기',
        value: labelOf(
          IdealTypeOptionSets.moodsForGender(options.gender),
          options.mood,
        ),
      ),
      (
        label: '스타일',
        value: labelOf(
          IdealTypeOptionSets.stylesForGender(options.gender),
          options.style,
        ),
      ),
      (
        label: '헤어',
        value: labelOf(
          IdealTypeOptionSets.hairsForGender(options.gender),
          options.hair,
        ),
      ),
      (
        label: '인상',
        value: labelOf(
          IdealTypeOptionSets.impressionsForGender(options.gender),
          options.impression,
        ),
      ),
      (
        label: '배경',
        value: labelOf(IdealTypeOptionSets.backgrounds, options.background),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    // 큰 글자 설정에서 두 버튼을 가로로 붙이면 라벨이 깨진다. 그때는 세로로.
    final stackActions = MediaQuery.textScalerOf(context).scale(1) > 1.15;

    return AppFadeSlideIn(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionLabel('AI가 해석한 이상형'),
          const SizedBox(height: AppSpacing.md),
          Text(
            result.summary.trim().isNotEmpty
                ? result.summary
                : 'AI가 이 이상형에 대한 설명을 아직 준비하지 못했어요.',
            style: AppTextStyles.body,
          ),
          const SizedBox(height: AppSpacing.xxl),

          const _SectionLabel('선택한 취향'),
          const SizedBox(height: AppSpacing.lg),
          for (final entry in _optionEntries()) ...[
            if (entry != _optionEntries().first)
              const Divider(height: 1, color: AppColors.borderSubtle),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width:
                        62 *
                        MediaQuery.textScalerOf(
                          context,
                        ).scale(1).clamp(1.0, 1.6),
                    child: Text(entry.label, style: AppTextStyles.caption),
                  ),
                  Expanded(
                    child: Text(
                      entry.value,
                      style: AppTextStyles.caption.copyWith(
                        color: AppColors.textStrong,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.xl),

          if (stackActions) ...[
            AppBrandButton(
              label: '조건 수정',
              icon: Icons.tune_rounded,
              variant: AppBrandButtonVariant.outline,
              onPressed: onEditOptions,
            ),
            const SizedBox(height: AppSpacing.md),
            AppBrandButton(
              label: '다시 생성',
              icon: Icons.refresh_rounded,
              onPressed: onRegenerate,
            ),
          ] else
            Row(
              children: [
                Expanded(
                  child: AppBrandButton(
                    label: '조건 수정',
                    icon: Icons.tune_rounded,
                    variant: AppBrandButtonVariant.outline,
                    onPressed: onEditOptions,
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: AppBrandButton(
                    label: '다시 생성',
                    icon: Icons.refresh_rounded,
                    onPressed: onRegenerate,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// 민트 짧은 바 + caps 라벨. 사주 영역 화면들이 공유하는 섹션 헤딩 문법.
/// (내 사주/궁합 화면에도 같은 모양이 있으나, 그 파일들은 이번 Phase의
/// 수정 대상이 아니라 공통 컴포넌트 승격은 다음 정리 Phase로 미룬다.)
class _SectionLabel extends StatelessWidget {
  final String text;

  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 14,
          height: 2,
          decoration: BoxDecoration(
            color: AppColors.brandPrimary,
            borderRadius: BorderRadius.circular(AppRadius.chip),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Flexible(
          child: Text(
            text,
            style: AppTextStyles.caption.copyWith(
              color: AppColors.brandPrimaryStrong,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.3,
            ),
          ),
        ),
      ],
    );
  }
}

// ═══ E. 취향 편집 ═════════════════════════════════════════════════════════════

/// 옵션 6종을 의미 단위로 묶어 읽기 쉽게 정리한다.
///
/// 옵션의 key/label/순서/유효성 규칙은 [IdealTypeOptionSets] 그대로다 —
/// 여기서 바꾸는 것은 화면상의 묶음과 여백뿐이다.
class _PreferenceEditor extends StatelessWidget {
  final IdealTypeImageOptions options;
  final UserProfile profile;
  final ValueChanged<String> onGenderSelected;
  final ValueChanged<String> onMoodSelected;
  final ValueChanged<String> onStyleSelected;
  final ValueChanged<String> onHairSelected;
  final ValueChanged<String> onImpressionSelected;
  final ValueChanged<String> onBackgroundSelected;

  const _PreferenceEditor({
    required this.options,
    required this.profile,
    required this.onGenderSelected,
    required this.onMoodSelected,
    required this.onStyleSelected,
    required this.onHairSelected,
    required this.onImpressionSelected,
    required this.onBackgroundSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionLabel('취향 선택'),
        const SizedBox(height: AppSpacing.md),
        const Text(
          '아래 조건으로 AI가 이상형 이미지를 생성해요.',
          style: AppTextStyles.bodySecondary,
        ),
        if (profile.idealTags.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.lg),
          _IdealTagSummary(tags: profile.idealTags),
        ],
        const SizedBox(height: AppSpacing.xl),

        _OptionGroup(
          title: '누구를 그릴까요',
          sections: [
            _OptionSectionData(
              title: '대상',
              options: IdealTypeOptionSets.genders,
              selected: options.gender,
              onSelected: onGenderSelected,
            ),
          ],
        ),
        _OptionGroup(
          title: '어떤 분위기인가요',
          sections: [
            _OptionSectionData(
              title: '분위기',
              options: IdealTypeOptionSets.moodsForGender(options.gender),
              selected: options.mood,
              onSelected: onMoodSelected,
            ),
            _OptionSectionData(
              title: '인상',
              options: IdealTypeOptionSets.impressionsForGender(options.gender),
              selected: options.impression,
              onSelected: onImpressionSelected,
            ),
          ],
        ),
        _OptionGroup(
          title: '어떤 스타일인가요',
          last: true,
          sections: [
            _OptionSectionData(
              title: '스타일',
              options: IdealTypeOptionSets.stylesForGender(options.gender),
              selected: options.style,
              onSelected: onStyleSelected,
            ),
            _OptionSectionData(
              title: '헤어',
              options: IdealTypeOptionSets.hairsForGender(options.gender),
              selected: options.hair,
              onSelected: onHairSelected,
            ),
            _OptionSectionData(
              title: '배경',
              options: IdealTypeOptionSets.backgrounds,
              selected: options.background,
              onSelected: onBackgroundSelected,
            ),
          ],
        ),
      ],
    );
  }
}

class _OptionSectionData {
  final String title;
  final List<IdealTypeOption> options;
  final String selected;
  final ValueChanged<String> onSelected;

  const _OptionSectionData({
    required this.title,
    required this.options,
    required this.selected,
    required this.onSelected,
  });
}

/// 의미가 가까운 옵션들을 한 덩어리로 묶는다. 그룹마다 큰 카드를 만들지 않고
/// 캔버스 위에 두되, 그룹 사이만 얇은 divider로 나눈다.
class _OptionGroup extends StatelessWidget {
  final String title;
  final List<_OptionSectionData> sections;
  final bool last;

  const _OptionGroup({
    required this.title,
    required this.sections,
    this.last = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: AppTextStyles.sectionTitle),
        const SizedBox(height: AppSpacing.lg),
        for (final section in sections) ...[
          if (section != sections.first)
            const SizedBox(height: AppSpacing.lg20),
          Text(
            section.title,
            style: AppTextStyles.label.copyWith(color: AppColors.textBody),
          ),
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              for (final option in section.options)
                _OptionChip(
                  label: option.label,
                  selected: option.key == section.selected,
                  onTap: () => section.onSelected(option.key),
                ),
            ],
          ),
        ],
        if (!last) ...[
          const SizedBox(height: AppSpacing.xl),
          const Divider(height: 1, color: AppColors.borderSubtle),
          const SizedBox(height: AppSpacing.xl),
        ],
      ],
    );
  }
}

/// 옵션 칩.
///
/// 선택 상태를 solid mint + glow로 표현하던 것을 걷어내고, 옅은 민트 fill +
/// 진한 민트 보더/텍스트 + 체크 표시로 바꾼다. 색만이 아니라 체크 아이콘과
/// semantics로도 선택 여부가 전달된다.
class _OptionChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _OptionChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: ExcludeSemantics(
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(AppRadius.chip),
            child: AnimatedContainer(
              duration: AppMotion.small,
              curve: AppMotion.standard,
              constraints: const BoxConstraints(minHeight: 44),
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg,
                vertical: AppSpacing.sm,
              ),
              decoration: BoxDecoration(
                color: selected
                    ? AppColors.brandPrimarySoft
                    : AppColors.surfacePrimary,
                borderRadius: BorderRadius.circular(AppRadius.chip),
                border: Border.all(
                  color: selected
                      ? AppColors.brandPrimaryStrong
                      : AppColors.borderSubtle,
                  width: selected ? 1.4 : 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (selected) ...[
                    const Icon(
                      Icons.check_rounded,
                      size: 15,
                      color: AppColors.brandPrimaryStrong,
                    ),
                    const SizedBox(width: 5),
                  ],
                  Flexible(
                    child: Text(
                      label,
                      style: AppTextStyles.label.copyWith(
                        fontSize: 14,
                        color: selected
                            ? AppColors.brandPrimaryStrong
                            : AppColors.textBody,
                        fontWeight: selected
                            ? FontWeight.w800
                            : FontWeight.w600,
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

/// 프로필에 저장해 둔 이상형 태그. 참고 정보이지 현재 생성 조건이 아니라는
/// 점이 드러나도록 라벨을 붙이고, 큰 민트 박스로 만들지 않는다.
class _IdealTagSummary extends StatelessWidget {
  final List<String> tags;

  const _IdealTagSummary({required this.tags});

  @override
  Widget build(BuildContext context) {
    final labels = ProfileOptions.keysToLabels(ProfileOptions.ideals, tags);
    if (labels.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      decoration: BoxDecoration(
        color: AppColors.surfaceSecondary,
        borderRadius: BorderRadius.circular(AppRadius.small),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '프로필에 저장된 취향',
            style: AppTextStyles.caption.copyWith(
              fontWeight: FontWeight.w800,
              color: AppColors.textBody,
            ),
          ),
          const SizedBox(height: 3),
          Text(labels.join(' · '), style: AppTextStyles.caption),
        ],
      ),
    );
  }
}

// ═══ F. 직접 수정 요청 ════════════════════════════════════════════════════════

/// 옵션 선택 외에 짧은 직접 수정 요청(refinementText)을 입력하는 섹션.
/// 서버가 항상 길이 제한/키워드 차단을 거친 뒤에만 prompt에 반영한다 —
/// 여기서는 UI 표시용 maxLength만 걸고, 최종 검증은 서버가 한다.
class _RefinementInput extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  static const _maxLength = 100;

  const _RefinementInput({required this.controller, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            const Text('직접 수정 요청', style: AppTextStyles.sectionTitle),
            const SizedBox(width: 6),
            Text('(선택)', style: AppTextStyles.caption),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        TextField(
          controller: controller,
          style: AppTextStyles.bodySecondary.copyWith(
            color: AppColors.textStrong,
          ),
          maxLength: _maxLength,
          maxLines: 2,
          minLines: 1,
          onChanged: onChanged,
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: AppColors.surfacePrimary,
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppRadius.control),
              borderSide: const BorderSide(color: AppColors.borderSubtle),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppRadius.control),
              borderSide: const BorderSide(
                color: AppColors.brandPrimaryStrong,
                width: 1.5,
              ),
            ),
            hintText: '원하는 느낌을 짧게 적어보세요',
            hintStyle: AppTextStyles.bodySecondary.copyWith(
              color: AppColors.textMuted,
            ),
            helperText: '예: 더 자연스럽게, 배경은 깔끔하게, 웃는 느낌으로',
            helperStyle: AppTextStyles.caption,
            counterStyle: AppTextStyles.caption,
            helperMaxLines: 2,
          ),
        ),
      ],
    );
  }
}

// ═══ H. 생성 오류 ═════════════════════════════════════════════════════════════

/// 서버가 준 사용자용 메시지를 그대로 보여준다. 오류를 다시 분류하거나
/// 문구를 재작성하지 않고, 전체를 붉은 카드로 만들지도 않는다.
class _IdealImageErrorCard extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;

  const _IdealImageErrorCard({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return AppSurfaceCard(
      padding: const EdgeInsets.all(AppSpacing.lg20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: AppColors.statusDangerSoft,
                  borderRadius: BorderRadius.circular(AppRadius.small),
                ),
                child: const Icon(
                  Icons.error_outline_rounded,
                  size: 18,
                  color: AppColors.statusDanger,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              const Expanded(
                child: Text('이미지 생성에 실패했어요', style: AppTextStyles.cardTitle),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Text(message, style: AppTextStyles.bodySecondary),
          const SizedBox(height: AppSpacing.lg),
          AppBrandButton(
            label: '다시 시도',
            icon: Icons.refresh_rounded,
            variant: AppBrandButtonVariant.outline,
            onPressed: onRetry,
          ),
        ],
      ),
    );
  }
}
