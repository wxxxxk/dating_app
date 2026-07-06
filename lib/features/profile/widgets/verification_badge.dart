import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../models/user_profile.dart';

/// 프로필 신뢰도 표시용 작은 인증 배지 묶음.
///
/// 디스커버리 카드/매칭 목록처럼 공간이 좁은 곳에서는 인증된 항목만 표시한다.
class VerificationBadges extends StatelessWidget {
  final VerificationStatus verifications;
  final bool showUnverified;
  final Brightness brightness;

  const VerificationBadges({
    super.key,
    required this.verifications,
    this.showUnverified = false,
    this.brightness = Brightness.light,
  });

  @override
  Widget build(BuildContext context) {
    final badges = [
      _VerificationBadgeData(
        icon: Icons.mark_email_read_outlined,
        label: '이메일',
        verified: verifications.email,
      ),
      _VerificationBadgeData(
        icon: Icons.phone_iphone_rounded,
        label: '전화',
        verified: verifications.phone,
      ),
      _VerificationBadgeData(
        icon: Icons.photo_camera_front_outlined,
        label: '사진',
        verified: verifications.photo,
      ),
    ].where((badge) => showUnverified || badge.verified).toList();

    if (badges.isEmpty) return const SizedBox.shrink();

    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: badges
          .map(
            (badge) => _VerificationBadge(data: badge, brightness: brightness),
          )
          .toList(),
    );
  }
}

class _VerificationBadge extends StatelessWidget {
  final _VerificationBadgeData data;
  final Brightness brightness;

  const _VerificationBadge({required this.data, required this.brightness});

  @override
  Widget build(BuildContext context) {
    final verified = data.verified;
    final dark = brightness == Brightness.dark;
    final bgColor = verified
        ? (dark
              ? Colors.white.withValues(alpha: 0.2)
              : AppColors.primary.withValues(alpha: 0.1))
        : AppColors.surface;
    final fgColor = verified
        ? (dark ? Colors.white : AppColors.primary)
        : AppColors.textSecondary;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: verified ? fgColor.withValues(alpha: 0.24) : AppColors.border,
          width: 0.7,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(data.icon, size: 13, color: fgColor),
          const SizedBox(width: 4),
          Text(
            verified ? '${data.label} 인증' : '${data.label} 미인증',
            style: TextStyle(
              color: fgColor,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              height: 1,
            ),
          ),
        ],
      ),
    );
  }
}

class _VerificationBadgeData {
  final IconData icon;
  final String label;
  final bool verified;

  const _VerificationBadgeData({
    required this.icon,
    required this.label,
    required this.verified,
  });
}
