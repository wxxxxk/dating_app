import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

/// Light Premium v1 공통 UI 컴포넌트.
///
/// premium_components.dart는 "프리미엄 톤(민트 fill/다크 서피스)"이 필요한
/// 특수 영역용이고, 이 파일은 그 아래 깔리는 앱 공통 base 문법이다:
/// 웜 캔버스 위의 흰색 카드, 브랜드 CTA, 섹션 헤더, 터치 피드백.
///
/// 파일럿(사주 허브)에서 실제로 두 번 이상 반복되는 패턴만 넣는다 —
/// 화면 하나를 위해 디자인 프레임워크를 만들지 않는다.

/// ── Premium trust 표현 규칙 (다음 확장 Phase에서 공통 적용) ─────────────────
///
/// 프리미엄을 shadow·glow·gradient로 표현하지 않는다. 신뢰는 장식이 아니라
/// **검증된 정보의 밀도**로 표현한다. 아래는 이 파일에 컴포넌트를 추가할 때
/// 지켜야 할 계약이다. 사주 허브에는 억지로 넣지 않았고, 실제로 그 정보를
/// 가진 화면(프로필 상세/매칭/온보딩)에서 구현한다.
///
/// - **verified badge**: 배지 자체가 아니라 "무엇이 검증됐는지"를 말한다.
///   `brandPrimaryStrong` 아이콘 + 라벨, 미검증은 배지를 숨긴다(회색 배지로
///   실패를 전시하지 않는다). 색만으로 구분하지 않고 항상 텍스트를 동반한다.
/// - **profile completeness**: 퍼센트 게이지를 크게 띄우지 않는다.
///   [AppSurfaceCard] 안의 얇은 브랜드 트랙 + "N개 항목 중 M개" 문구.
/// - **relationship intent**: 판단이 아니라 사실이므로 뉴트럴 칩
///   (`surfaceSecondary` + `borderSubtle`)로만 표기한다. expressive accent 금지.
/// - **safety/trust indicator**: 경고는 `statusWarning`, 위험은 `statusDanger`.
///   브랜드 민트로 안전을 표시하지 않는다(기능색과 신뢰색을 섞지 않는다).
/// - **locked information preview**: 블러 + 자물쇠만 있는 패널을 만들지 않는다.
///   보여줄 수 있는 실제 정보 일부를 먼저 노출하고, 잠긴 부분만 가린다.
///   잠금 해제 CTA는 항상 [AppBrandButton] 하나로 통일한다.

/// 터치 시 살짝 눌리는 피드백을 주는 래퍼.
///
/// [AnimatedScale]만 쓰고 콜백은 즉시 실행한다. Material/InkWell을 그대로
/// 유지해서 스플래시·semantics·최소 터치 영역이 사라지지 않게 한다.
/// 포인터가 카드 밖으로 빠지거나 화면이 전환돼도 눌린 상태로 남지 않도록
/// onTapCancel/onTapUp을 모두 처리한다.
class AppPressable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final BorderRadius borderRadius;

  const AppPressable({
    super.key,
    required this.child,
    required this.onTap,
    required this.borderRadius,
  });

  @override
  State<AppPressable> createState() => _AppPressableState();
}

class _AppPressableState extends State<AppPressable> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (widget.onTap == null || _pressed == value || !mounted) return;
    setState(() => _pressed = value);
  }

  @override
  void didUpdateWidget(covariant AppPressable oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 비활성으로 바뀌면 눌린 상태가 남지 않게 되돌린다.
    if (widget.onTap == null && _pressed) _pressed = false;
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    return AnimatedScale(
      scale: _pressed ? AppMotion.pressScale : 1,
      duration: AppMotion.press,
      curve: AppMotion.standard,
      child: Material(
        type: MaterialType.transparency,
        borderRadius: widget.borderRadius,
        child: InkWell(
          onTap: widget.onTap,
          onTapDown: enabled ? (_) => _setPressed(true) : null,
          onTapUp: enabled ? (_) => _setPressed(false) : null,
          onTapCancel: enabled ? () => _setPressed(false) : null,
          borderRadius: widget.borderRadius,
          splashColor: AppColors.brandPrimary.withValues(alpha: 0.07),
          highlightColor: AppColors.brandPrimary.withValues(alpha: 0.04),
          child: widget.child,
        ),
      ),
    );
  }
}

/// 카드 서피스의 강조 단계.
enum AppSurfaceTone {
  /// 흰색 + 옅은 보더. 기본값.
  plain,

  /// 브랜드 톤의 옅은 서피스 + 브랜드 보더. 화면당 1~2개로 제한한다.
  brand,

  /// 캔버스보다 살짝 눌러 앉힌 보조 블록(카드 안의 부가 정보 등).
  muted,
}

/// Light Premium 기본 카드.
///
/// 밝은 테마에서 계층은 진한 그림자가 아니라 흰색 서피스 + 옅은 보더 +
/// 아주 약한 shadow + 여백으로 만든다.
class AppSurfaceCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final AppSurfaceTone tone;
  final double radius;

  /// 히어로처럼 한 단계 더 떠 보여야 하는 카드에만 true.
  final bool elevated;

  const AppSurfaceCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.cardPadding),
    this.onTap,
    this.tone = AppSurfaceTone.plain,
    this.radius = AppRadius.surface,
    this.elevated = false,
  });

  Color get _background => switch (tone) {
    AppSurfaceTone.plain => AppColors.surfacePrimary,
    AppSurfaceTone.brand => AppColors.surfaceMintSoft,
    AppSurfaceTone.muted => AppColors.surfaceSecondary,
  };

  Color get _border => switch (tone) {
    AppSurfaceTone.plain => AppColors.borderSubtle,
    AppSurfaceTone.brand => AppColors.brandPrimary.withValues(alpha: 0.22),
    AppSurfaceTone.muted => AppColors.borderSubtle,
  };

  @override
  Widget build(BuildContext context) {
    final borderRadius = BorderRadius.circular(radius);
    final surface = Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: _background,
        borderRadius: borderRadius,
        border: Border.all(color: _border),
        boxShadow: elevated
            ? [
                BoxShadow(
                  color: AppColors.textStrong.withValues(alpha: 0.05),
                  blurRadius: 18,
                  offset: const Offset(0, 6),
                ),
              ]
            : null,
      ),
      child: child,
    );

    if (onTap == null) return surface;
    return AppPressable(
      onTap: onTap,
      borderRadius: borderRadius,
      child: surface,
    );
  }
}

/// 섹션 제목 + (선택) 부제 + (선택) trailing.
class AppSectionHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;

  const AppSectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: AppTextStyles.sectionTitle),
              if (subtitle != null) ...[
                const SizedBox(height: AppSpacing.xs),
                Text(subtitle!, style: AppTextStyles.caption),
              ],
            ],
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: AppSpacing.md),
          trailing!,
        ],
      ],
    );
  }
}

enum AppBrandButtonVariant { filled, outline }

/// 브랜드 CTA 버튼.
///
/// fill은 [AppColors.brandPrimaryStrong]을 쓴다 — 흰 글자와의 대비를
/// 확보하기 위해서다(brandPrimary + 흰 글자는 대비가 부족하다).
class AppBrandButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool loading;
  final AppBrandButtonVariant variant;
  final double height;

  const AppBrandButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.loading = false,
    this.variant = AppBrandButtonVariant.filled,
    this.height = 52,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !loading;
    final outlined = variant == AppBrandButtonVariant.outline;
    final foreground = outlined
        ? AppColors.brandPrimaryStrong
        : AppColors.onBrandPrimary;

    // loading일 때도 라벨은 남긴다 — 진행 중 상태를 문구로 알려주는 화면이
    // 있고(예: "이미지를 만들고 있어요"), 스피너만 남기면 그 계약이 깨진다.
    // 스피너는 아이콘 자리를 대신하므로 버튼 크기도 변하지 않는다.
    final child = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (loading) ...[
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2, color: foreground),
          ),
          const SizedBox(width: AppSpacing.sm),
        ] else if (icon != null) ...[
          Icon(icon, size: 18),
          const SizedBox(width: AppSpacing.sm),
        ],
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );

    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppRadius.control),
    );
    const textStyle = TextStyle(
      fontFamily: AppFonts.body,
      fontSize: 15,
      height: 1.2,
      fontWeight: FontWeight.w700,
    );

    return SizedBox(
      width: double.infinity,
      height: height,
      child: outlined
          ? OutlinedButton(
              onPressed: enabled ? onPressed : null,
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.brandPrimaryStrong,
                backgroundColor: AppColors.surfacePrimary,
                disabledForegroundColor: AppColors.textMuted,
                side: BorderSide(
                  color: enabled
                      ? AppColors.brandPrimary.withValues(alpha: 0.55)
                      : AppColors.borderStrong,
                ),
                shape: shape,
                textStyle: textStyle,
              ),
              child: child,
            )
          : FilledButton(
              onPressed: enabled ? onPressed : null,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.brandPrimaryStrong,
                foregroundColor: AppColors.onBrandPrimary,
                disabledBackgroundColor: AppColors.canvasSubtle,
                disabledForegroundColor: AppColors.textMuted,
                shape: shape,
                textStyle: textStyle,
              ),
              child: child,
            ),
    );
  }
}

/// 앱의 시그니처 모티프 — **두 점과 그것을 잇는 곡선**.
///
/// "두 사람이 이어진다"는 제품의 한 문장을 추상 도형 하나로 고정한 것이다.
/// 전통 사주 문양·하트·별 대신 이 모티프만 장식으로 쓴다. 두 점은 서로 다른
/// 사람이라 색이 다르다: 하나는 brand(기능), 하나는 expressive(감정).
///
/// [progress]로 곡선이 한 번 그려지는 연출을 만들 수 있다(반복 금지 —
/// 상태를 이해시키는 1회 연출로만 쓴다).
class ConnectionMotif extends StatelessWidget {
  final double progress;
  final Color primaryColor;
  final Color accentColor;
  final double strokeWidth;

  /// 배경 워시로 깔 때처럼 아주 옅게 쓸 때의 전체 불투명도.
  final double opacity;

  const ConnectionMotif({
    super.key,
    this.progress = 1,
    this.primaryColor = AppColors.brandPrimary,
    this.accentColor = AppColors.expressiveAccent,
    this.strokeWidth = 1.6,
    this.opacity = 1,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: opacity,
      child: CustomPaint(
        painter: _ConnectionMotifPainter(
          progress: progress.clamp(0, 1),
          primaryColor: primaryColor,
          accentColor: accentColor,
          strokeWidth: strokeWidth,
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _ConnectionMotifPainter extends CustomPainter {
  final double progress;
  final Color primaryColor;
  final Color accentColor;
  final double strokeWidth;

  _ConnectionMotifPainter({
    required this.progress,
    required this.primaryColor,
    required this.accentColor,
    required this.strokeWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;

    final left = Offset(size.width * 0.18, size.height * 0.66);
    final right = Offset(size.width * 0.82, size.height * 0.34);
    final control = Offset(size.width * 0.5, size.height * 0.02);
    final radius = size.shortestSide * 0.11;

    // 두 점을 잇는 곡선. progress만큼만 그려서 "이어지는" 연출을 만든다.
    final path = Path()
      ..moveTo(left.dx, left.dy)
      ..quadraticBezierTo(control.dx, control.dy, right.dx, right.dy);
    final metrics = path.computeMetrics().toList();
    if (metrics.isNotEmpty) {
      final metric = metrics.first;
      canvas.drawPath(
        metric.extractPath(0, metric.length * progress),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth
          ..strokeCap = StrokeCap.round
          ..color = primaryColor.withValues(alpha: 0.55),
      );
    }

    // 왼쪽 점: 기능(brand), 오른쪽 점: 감정(expressive).
    canvas.drawCircle(
      left,
      radius,
      Paint()..color = primaryColor.withValues(alpha: 0.18),
    );
    canvas.drawCircle(
      left,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..color = primaryColor.withValues(alpha: 0.6),
    );

    final accentScale = Curves.easeOutCubic.transform(progress);
    canvas.drawCircle(
      right,
      radius * accentScale,
      Paint()..color = accentColor.withValues(alpha: 0.22),
    );
    canvas.drawCircle(
      right,
      radius * accentScale,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..color = accentColor.withValues(alpha: 0.7 * accentScale),
    );
  }

  @override
  bool shouldRepaint(covariant _ConnectionMotifPainter old) =>
      old.progress != progress ||
      old.primaryColor != primaryColor ||
      old.accentColor != accentColor ||
      old.strokeWidth != strokeWidth;
}

/// 진입 시 fade + 약한 상승 슬라이드.
///
/// AnimatedSwitcher를 쓰지 않는다 — 전환 중 이전 상태 위젯이 트리에 남으면
/// "이전 날짜/이전 계정 결과가 화면에 남지 않는다"는 기존 계약이 흔들린다.
/// 대신 새로 마운트되는 쪽만 스스로 등장한다.
class AppFadeSlideIn extends StatelessWidget {
  final Widget child;
  final Duration delay;
  final Duration duration;
  final double offsetY;

  const AppFadeSlideIn({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.duration = AppMotion.entrance,
    this.offsetY = AppMotion.entranceOffsetY,
  });

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: duration + delay,
      curve: Interval(
        delay.inMilliseconds /
            (duration + delay).inMilliseconds.clamp(1, 1 << 30),
        1,
        curve: AppMotion.standard,
      ),
      builder: (context, t, child) => Opacity(
        opacity: t.clamp(0, 1),
        child: Transform.translate(
          offset: Offset(0, (1 - t) * offsetY),
          child: child,
        ),
      ),
      child: child,
    );
  }
}
