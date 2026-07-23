import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import '../../core/theme/app_colors.dart';
import '../../models/fortune_model.dart';
import '../../models/user_profile.dart';
import '../../services/fortune/fortune_calculator.dart';
import '../../services/fortune/fortune_service.dart';
import '../../services/share/share_image_service.dart';
import '../../shared/widgets/app_components.dart';
import 'widgets/ohaeng_radar_chart.dart';
import 'widgets/saju_precision_notice.dart';
import 'widgets/share_card.dart';

/// 내 사주 화면 — "내 사주 보기" 진입점.
///
/// 별자리/사주 오행은 [FortuneCalculator]로 기기에서 결정론적으로 계산하고,
/// 그 결과를 근거로 한 캐릭터 서사만 GPT(Cloud Function)에 요청한다.
class MyFortuneScreen extends StatefulWidget {
  final UserProfile profile;
  final FortuneService fortuneService;

  /// 출생시간이 없을 때 "태어난 시간 추가하기"를 눌렀을 때의 동작.
  /// null이면 버튼을 표시하지 않는다.
  final VoidCallback? onAddBirthTime;

  const MyFortuneScreen({
    super.key,
    required this.profile,
    required this.fortuneService,
    this.onAddBirthTime,
  });

  @override
  State<MyFortuneScreen> createState() => _MyFortuneScreenState();
}

class _MyFortuneScreenState extends State<MyFortuneScreen> {
  late final ZodiacInfo _zodiac;
  late final SajuInfo _saju;
  late final Map<String, double> _balance;

  bool _loading = true;
  bool _sharing = false;
  String? _error;
  FortuneNarrative? _narrative;

  @override
  void initState() {
    super.initState();
    _zodiac = FortuneCalculator.getZodiacSign(widget.profile.birthDate);
    _saju = FortuneCalculator.getSaju(widget.profile.birthDate);
    _balance = FortuneCalculator.getOhaengBalance(
      widget.profile.birthDate,
      birthTimeMinutes: widget.profile.birthProfile.hasKnownTime
          ? widget.profile.birthProfile.minutes
          : null,
    );
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final narrative = await widget.fortuneService.getMyFortune(
        uid: widget.profile.uid,
      );
      if (mounted) setState(() => _narrative = narrative);
    } on FortuneFailure catch (e) {
      if (kDebugMode) {
        debugPrint('[MyFortune] load_failed code=${e.code}');
      }
      if (mounted) setState(() => _error = 'load_failed');
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[MyFortune] load_failed category=${e.runtimeType}');
      }
      if (mounted) setState(() => _error = 'load_failed');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _shareFortuneResult() async {
    final narrative = _narrative;
    if (narrative == null || _sharing) return;

    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null
        ? Rect.zero
        : box.localToGlobal(Offset.zero) & box.size;

    setState(() => _sharing = true);
    try {
      await ShareImageService.sharePng(
        context: context,
        child: FortuneShareCard(
          profile: widget.profile,
          narrative: narrative,
          zodiac: _zodiac,
          saju: _saju,
          balance: _balance,
        ),
        fileName: 'fortune_${widget.profile.uid}.png',
        title: '나의 사주 결과',
        text: '나의 사주 캐릭터를 확인해보세요.',
        sharePositionOrigin: origin,
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[MyFortune] share_failed category=${e.runtimeType}');
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('공유 이미지를 만드는 데 실패했어요.')));
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  double get _horizontalPadding => MediaQuery.sizeOf(context).width < 360
      ? AppSpacing.screenHCompact
      : AppSpacing.screenH;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.warmCanvas,
      appBar: AppBar(
        title: const Text('내 사주', style: AppTextStyles.cardTitle),
        backgroundColor: AppColors.warmCanvas,
        surfaceTintColor: AppColors.warmCanvas,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: SafeArea(child: _buildBody()),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return _MyFortuneLoadingState(horizontal: _horizontalPadding);
    }
    if (_error != null) {
      return _MyFortuneErrorState(
        horizontal: _horizontalPadding,
        message: '내 사주 분석을 불러오지 못했어요.\n잠시 후 다시 시도해주세요.',
        onRetry: _load,
      );
    }

    final narrative = _narrative;
    if (narrative == null) return const SizedBox.shrink();

    final horizontal = _horizontalPadding;

    return Stack(
      children: [
        ListView(
          padding: EdgeInsets.fromLTRB(
            horizontal,
            AppSpacing.xs,
            horizontal,
            40,
          ),
          children: [
            // ── A. Identity header ───────────────────────────────────────────
            AppFadeSlideIn(
              child: _IdentityHeader(
                displayName: widget.profile.displayName,
                zodiac: _zodiac,
                saju: _saju,
                balance: _balance,
                // 절기 경계로 연주·월주가 확정되지 않으면 오행 분포도 확정되지
                // 않는다. 이때는 "어떤 기운이 중심"이라는 문장을 만들지 않는다.
                balanceConfirmed: !narrative.boundaryUncertain,
              ),
            ),
            const SizedBox(height: AppSpacing.xxl),

            // ── B. 핵심 분석 문장 ─────────────────────────────────────────────
            AppFadeSlideIn(
              delay: AppMotion.staggerDelay(1),
              child: _CharacterSection(narrative: narrative),
            ),
            const SizedBox(height: AppSpacing.xxl),

            // ── C. 오행 ──────────────────────────────────────────────────────
            // 기존 계약 유지: boundaryUncertain이면 가짜 중간값 대신 감춘다.
            if (!narrative.boundaryUncertain) ...[
              AppFadeSlideIn(
                delay: AppMotion.staggerDelay(2),
                child: _OhaengSection(balance: _balance, saju: _saju),
              ),
              const SizedBox(height: AppSpacing.xxl),
            ],

            // ── D. 해석 근거 ─────────────────────────────────────────────────
            if (narrative.reasons.isNotEmpty) ...[
              AppFadeSlideIn(
                delay: AppMotion.staggerDelay(3),
                child: _ReasonSection(reasons: narrative.reasons),
              ),
              const SizedBox(height: AppSpacing.xxl),
            ],

            // ── E. 출생정보 + 공유 ────────────────────────────────────────────
            _BirthInfoSection(
              profile: widget.profile,
              narrative: narrative,
              onAddBirthTime: widget.onAddBirthTime,
            ),
            const SizedBox(height: AppSpacing.xl),
            AppBrandButton(
              label: '결과 공유하기',
              icon: Icons.ios_share_rounded,
              onPressed: _sharing ? null : _shareFortuneResult,
            ),
          ],
        ),
        if (_sharing) const _ShareLoadingOverlay(),
      ],
    );
  }
}

// ═══ A. Identity header ══════════════════════════════════════════════════════

/// 화면 상단의 자기소개 영역.
///
/// 사실을 나열하되 오행과 별자리 사이의 인과관계를 새로 주장하지 않는다 —
/// "목의 기운이 두드러지는 물병자리"처럼 두 체계를 한 문장으로 묶지 않고,
/// 각각을 따로 진술한다.
class _IdentityHeader extends StatelessWidget {
  final String displayName;
  final ZodiacInfo zodiac;
  final SajuInfo saju;
  final Map<String, double> balance;
  final bool balanceConfirmed;

  const _IdentityHeader({
    required this.displayName,
    required this.zodiac,
    required this.saju,
    required this.balance,
    required this.balanceConfirmed,
  });

  String get _title {
    final name = displayName.trim();
    return name.isEmpty ? '나의 타고난 기운' : '$name님의 타고난 기운';
  }

  /// 첫 줄은 확정된 오행 분포가 있을 때만 만든다. 중심 기운은 일간 원소가
  /// 아니라 전체 분포의 최댓값이다 — 이 화면이 이미 설명하고 있는 구분이다.
  String? get _dominantLine {
    if (!balanceConfirmed) return null;
    final strongest = FortuneCalculator.strongestElement(balance);
    return '${strongest.key}의 기운이 중심을 이루고 있어요.';
  }

  String get _factLine =>
      '일간은 ${saju.dayMaster}(${saju.element})이고, 별자리는 ${zodiac.sign}예요.';

  @override
  Widget build(BuildContext context) {
    final dominant = _dominantLine;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.heroPadding),
      decoration: BoxDecoration(
        // 민트·코랄 tonal gradient. 둘 다 흰색에 가까운 값이라 텍스트 대비를
        // 해치지 않는 범위에서만 온기를 더한다.
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppColors.surfacePrimary,
            AppColors.expressiveAccentSoft,
            AppColors.surfaceMintSoft,
          ],
          stops: [0.1, 0.62, 1],
        ),
        borderRadius: BorderRadius.circular(AppRadius.heroSoft),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: Stack(
        children: [
          // 이 화면에서 모티프는 여기 한 번만 쓴다. "나의 여러 성향이 하나의
          // 정체성으로 이어진다"는 의미다. 장식이므로 semantics에서 제외한다.
          Positioned(
            top: -10,
            right: -10,
            width: 104,
            height: 62,
            child: ExcludeSemantics(
              child: IgnorePointer(
                child: ConnectionMotif(strokeWidth: 1.4, opacity: 0.6),
              ),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '사주 인사이트',
                style: AppTextStyles.caption.copyWith(
                  color: AppColors.brandPrimaryStrong,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.4,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              ConstrainedBox(
                // 긴 이름이 모티프 영역을 침범하지 않게 폭을 제한한다.
                constraints: const BoxConstraints(maxWidth: 250),
                child: Text(
                  _title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.screenTitle,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              if (dominant != null) ...[
                Text(dominant, style: AppTextStyles.body),
                const SizedBox(height: AppSpacing.xs),
              ],
              Text(_factLine, style: AppTextStyles.bodySecondary),
              const SizedBox(height: AppSpacing.lg20),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: [
                  _MetaChip(
                    label: '일간',
                    value: '${saju.dayMaster}(${saju.element})',
                  ),
                  _MetaChip(label: '별자리', value: zodiac.sign),
                  _MetaChip(label: '원소', value: zodiac.element),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 라벨 + 값 compact chip. 모든 정보를 같은 크기 카드로 만들지 않기 위한
/// 보조 metadata 표현이다.
class _MetaChip extends StatelessWidget {
  final String label;
  final String value;

  const _MetaChip({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: 6,
      ),
      decoration: BoxDecoration(
        color: AppColors.surfacePrimary.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(AppRadius.chip),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: AppTextStyles.caption),
          const SizedBox(width: 6),
          // 큰 글자 설정에서 chip이 화면 밖으로 밀리지 않도록 값 쪽이 줄어든다.
          Flexible(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.caption.copyWith(
                color: AppColors.textStrong,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ═══ B. 핵심 분석 ════════════════════════════════════════════════════════════

/// 캐릭터 타입 + 요약. 카드에 가두지 않고 캔버스 위에 그대로 읽히게 둔다.
class _CharacterSection extends StatelessWidget {
  final FortuneNarrative narrative;

  const _CharacterSection({required this.narrative});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionLabel('사주 캐릭터'),
        const SizedBox(height: AppSpacing.md),
        // 이 화면에서 명조(insight)를 쓰는 유일한 자리다.
        // 문장 전체를 민트로 칠하지 않고 짙은 차콜로 읽히게 한다.
        Text(narrative.characterType, style: AppTextStyles.insight),
        const SizedBox(height: AppSpacing.lg),
        Text(narrative.summary, style: AppTextStyles.body),
      ],
    );
  }
}

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
        Text(
          text,
          style: AppTextStyles.caption.copyWith(
            color: AppColors.brandPrimaryStrong,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.3,
          ),
        ),
      ],
    );
  }
}

// ═══ C. 오행 ═════════════════════════════════════════════════════════════════

/// 오행 밸런스 레이더 차트 + 강함/부족 요약 + 보완 매칭 안내.
///
/// 전통 오행 5색은 레이더 차트 축과 비율 목록의 **작은 점**에만 남긴다.
/// 5색 pill을 나란히 세워 화면 톤을 깨뜨리던 구성을 걷어내고, 화면의 주
/// 브랜드는 계속 민트가 갖게 한다.
class _OhaengSection extends StatelessWidget {
  final Map<String, double> balance;
  final SajuInfo saju;
  const _OhaengSection({required this.balance, required this.saju});

  /// 오행 이름 뒤에 붙는 주격 조사(이/가). 다섯 글자뿐이라 표를 직접 둔다.
  static const _particle = {'목': '이', '화': '가', '토': '가', '금': '이', '수': '가'};

  @override
  Widget build(BuildContext context) {
    final strong = FortuneCalculator.strongestElement(balance);
    final weak = FortuneCalculator.weakestElement(balance);
    final nourishing = FortuneCalculator.nourishingElement(weak.key);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionLabel('오행 밸런스'),
        const SizedBox(height: AppSpacing.md),
        Text(
          '${strong.key}${_particle[strong.key]} 강하고 ${weak.key}${_particle[weak.key]} 부족해요',
          style: AppTextStyles.sectionTitle,
        ),
        const SizedBox(height: AppSpacing.lg),
        AppSurfaceCard(
          padding: const EdgeInsets.all(AppSpacing.lg20),
          child: Column(
            children: [
              Semantics(
                // 레이더 차트는 색과 도형으로만 값을 전달한다. 스크린리더에는
                // 아래 비율 목록과 같은 내용을 문장으로 전달한다.
                label: _chartSemanticsLabel(),
                excludeSemantics: true,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.xl,
                  ),
                  child: OhaengRadarChart(balance: balance),
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              _OhaengRatioList(balance: balance),
              const SizedBox(height: AppSpacing.lg),
              const Divider(height: 1, color: AppColors.borderSubtle),
              const SizedBox(height: AppSpacing.lg),
              _DayMasterNote(saju: saju),
              const SizedBox(height: AppSpacing.md),
              const Text(
                '일간은 나의 기본 성향, 오행 밸런스는 년·월·일 6글자의 전체 기운이에요. '
                '그래서 일간 원소와 가장 강한 원소가 다를 수 있어요.',
                style: AppTextStyles.caption,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                '출생 시각과 지장간은 반영하지 않은 간단 분석이에요.',
                style: AppTextStyles.caption.copyWith(fontSize: 11),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.lg,
          ),
          decoration: BoxDecoration(
            color: AppColors.surfaceMintSoft,
            borderRadius: BorderRadius.circular(AppRadius.small),
            border: Border.all(
              color: AppColors.brandPrimary.withValues(alpha: 0.22),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.auto_awesome_rounded,
                size: 18,
                color: AppColors.brandPrimaryStrong,
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '이런 사람과 잘 맞아요',
                      style: AppTextStyles.label.copyWith(
                        color: AppColors.textStrong,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '$nourishing${_particle[nourishing]} 기운을 가진 상대가 당신의 부족한 부분을 채워줄 수 있어요.',
                      style: AppTextStyles.bodySecondary,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _chartSemanticsLabel() {
    final parts = ohaengOrder
        .map((key) => '$key ${((balance[key] ?? 0) * 100).round()}퍼센트')
        .join(', ');
    return '오행 밸런스 차트. $parts.';
  }
}

/// 오행 비율 목록.
///
/// 전통 5색은 지름 7px 점에만 남기고, 막대는 브랜드 민트 하나로 통일한다.
/// 값은 색이 아니라 숫자로도 읽히므로 색각 이상에서도 구분된다.
class _OhaengRatioList extends StatelessWidget {
  final Map<String, double> balance;
  const _OhaengRatioList({required this.balance});

  @override
  Widget build(BuildContext context) {
    final maxValue = ohaengOrder
        .map((key) => balance[key] ?? 0)
        .fold<double>(0, (a, b) => a > b ? a : b);

    return Column(
      children: [
        for (final key in ohaengOrder) ...[
          if (key != ohaengOrder.first) const SizedBox(height: AppSpacing.sm),
          _OhaengRatioRow(
            element: key,
            value: balance[key] ?? 0,
            maxValue: maxValue,
          ),
        ],
      ],
    );
  }
}

class _OhaengRatioRow extends StatelessWidget {
  final String element;
  final double value;
  final double maxValue;

  const _OhaengRatioRow({
    required this.element,
    required this.value,
    required this.maxValue,
  });

  @override
  Widget build(BuildContext context) {
    final percent = (value * 100).round();
    // 막대 길이는 원본 비율을 최댓값 기준으로 정규화한 표시용 길이다.
    // 숫자는 항상 원본 퍼센트를 그대로 보여준다.
    final ratio = maxValue <= 0 ? 0.0 : (value / maxValue).clamp(0.0, 1.0);
    final dotColor = ohaengColors[element] ?? AppColors.textMuted;
    // 원소 글자와 퍼센트 열은 정렬을 위해 폭을 고정하되, 큰 글자 설정에서
    // 글자가 잘리지 않도록 배율만큼 함께 넓힌다.
    final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.6);

    return Row(
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
        ),
        const SizedBox(width: AppSpacing.sm),
        SizedBox(
          width: 16 * scale,
          child: Text(
            element,
            style: AppTextStyles.caption.copyWith(
              color: AppColors.textBody,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.chip),
            child: LinearProgressIndicator(
              value: ratio,
              minHeight: 6,
              backgroundColor: AppColors.canvasSubtle,
              valueColor: const AlwaysStoppedAnimation<Color>(
                AppColors.brandPrimary,
              ),
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        SizedBox(
          width: 34 * scale,
          child: Text(
            '$percent%',
            textAlign: TextAlign.right,
            style: AppTextStyles.caption.copyWith(
              color: AppColors.textBody,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

class _DayMasterNote extends StatelessWidget {
  final SajuInfo saju;
  const _DayMasterNote({required this.saju});

  @override
  Widget build(BuildContext context) {
    final dotColor = ohaengColors[saju.element] ?? AppColors.brandPrimary;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: AppColors.surfaceSecondary,
        borderRadius: BorderRadius.circular(AppRadius.chip),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
          ),
          const SizedBox(width: AppSpacing.sm),
          // Row가 min이라 기본적으로는 내용 폭만 차지하지만, 큰 글자 설정에서
          // 카드 폭을 넘기면 줄바꿈되도록 Flexible로 감싼다.
          Flexible(
            child: Text(
              '일간 ${saju.dayMaster}(${saju.element}) · 본질 원소',
              style: AppTextStyles.caption.copyWith(
                color: AppColors.textBody,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ═══ D. 해석 근거 ════════════════════════════════════════════════════════════

class _ReasonSection extends StatelessWidget {
  final List<FortuneReason> reasons;
  const _ReasonSection({required this.reasons});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionLabel('이렇게 해석했어요'),
        const SizedBox(height: AppSpacing.lg),
        for (var i = 0; i < reasons.length; i++) ...[
          if (i > 0) ...[
            const SizedBox(height: AppSpacing.md),
            const Divider(height: 1, color: AppColors.borderSubtle),
            const SizedBox(height: AppSpacing.md),
          ],
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                margin: const EdgeInsets.only(top: 7),
                width: 5,
                height: 5,
                decoration: const BoxDecoration(
                  color: AppColors.brandPrimary,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Text(
                  reasons[i].text,
                  style: AppTextStyles.bodySecondary.copyWith(
                    color: AppColors.textStrong,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

// ═══ E. 출생정보 ═════════════════════════════════════════════════════════════

/// 생년월일·출생시간 상태를 담는 하단 compact 섹션.
///
/// 개인정보이므로 히어로에 크게 띄우지 않고, 장식 없이 사실만 적는다.
/// 출생시간 추가 CTA는 기존 [SajuPrecisionNotice]가 그대로 담당한다 — 이
/// 위젯은 궁합 화면과 공유하고 전용 테스트가 키/문구를 고정하고 있어서
/// 이번 Phase에서 손대지 않는다.
class _BirthInfoSection extends StatelessWidget {
  final UserProfile profile;
  final FortuneNarrative narrative;
  final VoidCallback? onAddBirthTime;

  const _BirthInfoSection({
    required this.profile,
    required this.narrative,
    required this.onAddBirthTime,
  });

  @override
  Widget build(BuildContext context) {
    final birth = profile.birthDate;
    final hasKnownTime = profile.birthProfile.hasKnownTime;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionLabel('해석에 쓴 정보'),
        const SizedBox(height: AppSpacing.lg),
        _BirthInfoRow(
          label: '생년월일',
          value: '${birth.year}년 ${birth.month}월 ${birth.day}일',
        ),
        const SizedBox(height: AppSpacing.sm),
        _BirthInfoRow(
          label: '태어난 시간',
          // 상태를 색이 아니라 텍스트로 말한다.
          value: hasKnownTime ? '입력함' : '입력하지 않음',
        ),
        const SizedBox(height: AppSpacing.lg),
        SajuPrecisionNotice(
          hasKnownTime: hasKnownTime,
          boundaryUncertain: narrative.boundaryUncertain,
          onAddBirthTime: onAddBirthTime,
        ),
      ],
    );
  }
}

class _BirthInfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _BirthInfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 78, child: Text(label, style: AppTextStyles.caption)),
        Expanded(
          child: Text(
            value,
            style: AppTextStyles.caption.copyWith(
              color: AppColors.textBody,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

// ═══ 상태 화면 ═══════════════════════════════════════════════════════════════

/// FortuneHub / FortuneHistory와 같은 skeleton 문법. 새 데이터 호출은 없다 —
/// 기존 `_loading` 플래그의 표현만 바꾼 것이다.
class _MyFortuneLoadingState extends StatelessWidget {
  final double horizontal;

  const _MyFortuneLoadingState({required this.horizontal});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.fromLTRB(
        horizontal,
        AppSpacing.xs,
        horizontal,
        AppSpacing.xxl,
      ),
      physics: const NeverScrollableScrollPhysics(),
      children: [
        Container(
          padding: const EdgeInsets.all(AppSpacing.heroPadding),
          decoration: BoxDecoration(
            color: AppColors.surfacePrimary,
            borderRadius: BorderRadius.circular(AppRadius.heroSoft),
            border: Border.all(color: AppColors.borderSubtle),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const _SkeletonBar(width: 76, height: 12),
                  const Spacer(),
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.brandPrimary.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              const _SkeletonBar(width: 196, height: 24),
              const SizedBox(height: AppSpacing.lg),
              const _SkeletonBar(height: 14),
              const SizedBox(height: AppSpacing.sm),
              const _SkeletonBar(width: 214, height: 14),
              const SizedBox(height: AppSpacing.lg20),
              const Row(
                children: [
                  _SkeletonBar(width: 82, height: 26),
                  SizedBox(width: AppSpacing.sm),
                  _SkeletonBar(width: 74, height: 26),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.xxl),
        const _SkeletonBar(width: 88, height: 12),
        const SizedBox(height: AppSpacing.md),
        const _SkeletonBar(width: 208, height: 26),
        const SizedBox(height: AppSpacing.lg),
        const _SkeletonBar(height: 14),
        const SizedBox(height: AppSpacing.sm),
        const _SkeletonBar(height: 14),
        const SizedBox(height: AppSpacing.sm),
        const _SkeletonBar(width: 180, height: 14),
        const SizedBox(height: AppSpacing.xxl),
        const _SkeletonBar(height: 172, radius: AppRadius.surface),
      ],
    );
  }
}

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

class _MyFortuneErrorState extends StatelessWidget {
  final double horizontal;
  final String message;
  final VoidCallback onRetry;

  const _MyFortuneErrorState({
    required this.horizontal,
    required this.message,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.fromLTRB(
        horizontal,
        AppSpacing.xl,
        horizontal,
        AppSpacing.xxl,
      ),
      children: [
        AppSurfaceCard(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: AppColors.statusDangerSoft,
                    borderRadius: BorderRadius.circular(AppRadius.small),
                  ),
                  child: const Icon(
                    Icons.error_outline_rounded,
                    size: 24,
                    color: AppColors.statusDanger,
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              Text(
                message,
                textAlign: TextAlign.center,
                style: AppTextStyles.bodySecondary,
              ),
              const SizedBox(height: AppSpacing.lg20),
              AppBrandButton(
                label: '다시 시도',
                icon: Icons.refresh_rounded,
                onPressed: onRetry,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 공유 이미지 생성 중 오버레이. 동작·콜백은 그대로 두고 색만 새 토큰으로
/// 맞춘다. 공유 이미지 자체(FortuneShareCard / ShareImageService)는 별도
/// Phase에서 다룬다.
class _ShareLoadingOverlay extends StatelessWidget {
  const _ShareLoadingOverlay();

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: ColoredBox(
        color: AppColors.textStrong.withValues(alpha: 0.26),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg20,
              vertical: AppSpacing.lg,
            ),
            decoration: BoxDecoration(
              color: AppColors.surfacePrimary,
              borderRadius: BorderRadius.circular(AppRadius.small),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.brandPrimaryStrong,
                  ),
                ),
                SizedBox(width: AppSpacing.md),
                Text('공유 이미지 생성 중', style: AppTextStyles.bodySecondary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
