import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_colors.dart';

/// 프리미엄 톤(다크 민트/그린 accent)이 필요한 화면(AI 이상형, 필터 예고,
/// 젤리/부스트, 멤버십/상태 배지)에서 반복되는 카드/배지 패턴을 모아둔
/// 작은 공통 위젯 모음이다.
///
/// 왜 여기 모으나:
/// - filter_sheet.dart(프리미엄 필터 예고)와 ideal_type_screen.dart(AI 생성
///   배지, 안내 카드)에서 거의 같은 모양의 위젯을 각자 복제해서 쓰고 있었다.
/// - 새 화면(젤리샵 등)에서도 같은 톤이 필요해서, 이번에 공통 위젯으로
///   뺀다. 과도한 옵션은 만들지 않는다 — 실제로 반복되는 형태만 옮긴다.

/// 아이콘 + 제목 + 설명으로 구성된 프리미엄 톤 안내 카드.
///
/// 예: "프리미엄 필터는 추후 제공 예정이에요", "AI가 생성한 가상의
/// 이미지입니다" 같은, 강조는 필요하지만 경고는 아닌 안내 문구에 쓴다.
class PremiumNoticeCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;

  const PremiumNoticeCard({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.premiumSoft,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.premiumBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: AppColors.premium),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: AppColors.premium,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 작은 아이콘 + 텍스트 pill 배지. "AI 생성 이미지" 같은 짧은 상태 표시에
/// 쓴다. [solid]가 true면 배경을 꽉 채운 강조형(사진 위 오버레이용), false면
/// 옅은 배경의 은은한 형태(일반 카드 안)로 표시한다.
class PremiumBadge extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool solid;

  const PremiumBadge({
    super.key,
    required this.label,
    this.icon = Icons.auto_awesome_rounded,
    this.solid = false,
  });

  @override
  Widget build(BuildContext context) {
    final foreground = solid ? AppColors.surface : AppColors.premium;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: solid
            ? AppColors.premium.withValues(alpha: 0.9)
            : AppColors.premiumSoft,
        borderRadius: BorderRadius.circular(AppRadius.chip),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: foreground),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: foreground,
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

/// 제목 + (선택) 부제목 + 본문으로 구성된 표준 섹션 카드.
///
/// 홈/프로필 편집/젤리 화면에서 "카드 안에 소제목 + 내용"이 반복되던 것을
/// 하나로 통일한다. 카드 배경/테두리/여백만 통일하고, 내용(child)은 각
/// 화면이 자유롭게 구성한다 — 과도한 옵션을 만들지 않는다.
class PremiumSectionCard extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget child;
  final EdgeInsetsGeometry padding;
  final bool dark;

  const PremiumSectionCard({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.dark = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: dark ? AppColors.surfaceDark : AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(
          color: dark
              ? AppColors.mint.withValues(alpha: 0.24)
              : AppColors.border,
        ),
        boxShadow: dark ? AppShadows.mintGlow : AppShadows.card,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: dark ? AppColors.textOnDark : AppColors.textPrimary,
                  ),
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 12), trailing!],
            ],
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(
              subtitle!,
              style: TextStyle(
                fontSize: 12,
                color: dark
                    ? AppColors.textMutedOnDark
                    : AppColors.textSecondary,
              ),
            ),
          ],
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class PremiumProfileImageCard extends StatelessWidget {
  final Widget child;
  final double radius;
  final bool glow;

  /// Discovery editorial 액자 톤. 사진이 흰 카드 안에 담긴 느낌 대신 사진
  /// 자체가 액자처럼 보이도록, mint 틴트 대신 아주 얇은 중립 보더 + 부드러운
  /// 단일 섀도우만 쓴다. 기본값(false)은 기존 렌더를 그대로 유지하므로 다른
  /// 화면(user_profile_screen 등)에는 영향이 없다.
  final bool softFrame;

  const PremiumProfileImageCard({
    super.key,
    required this.child,
    this.radius = AppRadius.hero,
    this.glow = false,
    this.softFrame = false,
  });

  @override
  Widget build(BuildContext context) {
    if (softFrame) {
      return Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          boxShadow: AppShadows.card,
        ),
        foregroundDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: AppColors.borderSubtle),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: child,
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: glow ? AppShadows.mintGlow : AppShadows.hero,
      ),
      foregroundDecoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: AppColors.mint.withValues(alpha: glow ? 0.28 : 0.14),
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: child,
      ),
    );
  }
}

class PremiumStatusPill extends StatelessWidget {
  final String label;
  final IconData? icon;
  final Color color;
  final bool compact;

  const PremiumStatusPill({
    super.key,
    required this.label,
    this.icon,
    this.color = AppColors.mint,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : 10,
        vertical: compact ? 4 : 6,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppRadius.chip),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: compact ? 12 : 14, color: color),
            const SizedBox(width: 4),
          ],
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 180),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color,
                fontSize: compact ? 11 : 12,
                fontWeight: FontWeight.w800,
                height: 1,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class PremiumLockedPanel extends StatelessWidget {
  final String title;
  final String description;
  final String actionLabel;
  final VoidCallback? onPressed;
  final bool loading;

  const PremiumLockedPanel({
    super.key,
    required this.title,
    required this.description,
    required this.actionLabel,
    required this.onPressed,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.mintSoft,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.mint.withValues(alpha: 0.3)),
        boxShadow: AppShadows.card,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const PremiumStatusPill(
            label: 'MEMBERSHIP',
            icon: Icons.lock_rounded,
            color: AppColors.mintDeep,
          ),
          const SizedBox(height: 14),
          Text(
            title,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            description,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 13,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: loading ? null : onPressed,
              child: loading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(actionLabel),
            ),
          ),
        ],
      ),
    );
  }
}

class PremiumActionCircleButton extends StatefulWidget {
  final IconData icon;
  final Color color;
  final double size;
  final VoidCallback? onPressed;
  final String? tooltip;

  const PremiumActionCircleButton({
    super.key,
    required this.icon,
    required this.color,
    required this.size,
    required this.onPressed,
    this.tooltip,
  });

  @override
  State<PremiumActionCircleButton> createState() =>
      _PremiumActionCircleButtonState();
}

class _PremiumActionCircleButtonState extends State<PremiumActionCircleButton> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (widget.onPressed == null || _pressed == value) return;
    setState(() => _pressed = value);
  }

  void _activate() {
    final callback = widget.onPressed;
    if (callback == null) return;
    HapticFeedback.lightImpact();
    callback();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final color = enabled
        ? widget.color
        : AppColors.inkSecondary.withValues(alpha: 0.45);
    final button = GestureDetector(
      onTapDown: (_) => _setPressed(true),
      onTapCancel: () => _setPressed(false),
      onTapUp: (_) => _setPressed(false),
      onTap: _activate,
      child: AnimatedScale(
        scale: _pressed ? 0.9 : 1,
        duration: AppDurations.fast,
        curve: AppCurves.standard,
        child: AnimatedContainer(
          duration: AppDurations.fast,
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            color: AppColors.surface,
            shape: BoxShape.circle,
            border: Border.all(color: color.withValues(alpha: 0.55)),
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: _pressed ? 0.1 : 0.18),
                blurRadius: _pressed ? 8 : 16,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: Icon(widget.icon, color: color, size: widget.size * 0.46),
        ),
      ),
    );
    return widget.tooltip == null
        ? button
        : Tooltip(message: widget.tooltip!, child: button);
  }
}
