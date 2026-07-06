import 'package:flutter/material.dart';

import '../../../core/constants/profile_options.dart';
import '../../../core/theme/app_colors.dart';
import '../../../models/user_profile.dart';
import '../../../services/fortune/fortune_calculator.dart';
import '../../../services/location/location_service.dart';
import '../../profile/widgets/verification_badge.dart';

/// 디스커버리 카드에 표시되는 프로필 내용.
///
/// 사진, 이름/나이/MBTI, 소개글, 관심사 칩을 렌더링한다.
/// [SwipeCard]의 child로 사용된다.
class ProfileCardContent extends StatelessWidget {
  final UserProfile profile;
  final DateTime? currentUserBirthDate;
  final UserLocation? currentUserLocation;

  const ProfileCardContent({
    super.key,
    required this.profile,
    this.currentUserBirthDate,
    this.currentUserLocation,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: Stack(
        fit: StackFit.expand,
        children: [_buildPhoto(), _buildGradientOverlay(), _buildInfoPanel()],
      ),
    );
  }

  Widget _buildPhoto() {
    if (profile.photoUrls.isEmpty) {
      return Container(
        color: AppColors.surface,
        child: const Icon(
          Icons.person,
          size: 80,
          color: AppColors.textSecondary,
        ),
      );
    }
    return Image.network(
      profile.photoUrls.first,
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => Container(
        color: AppColors.surface,
        child: const Icon(
          Icons.person,
          size: 80,
          color: AppColors.textSecondary,
        ),
      ),
    );
  }

  Widget _buildGradientOverlay() {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      height: 280,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Colors.black.withValues(alpha: 0.82), Colors.transparent],
          ),
        ),
      ),
    );
  }

  Widget _buildInfoPanel() {
    final interestLabels = ProfileOptions.keysToLabels(
      ProfileOptions.interests,
      profile.interests,
    ).take(4).toList();
    final compatibilityHint = currentUserBirthDate == null
        ? null
        : FortuneCalculator.getCompatibilityHint(
            currentUserBirthDate!,
            profile.birthDate,
          );
    final distanceKm = LocationService.distanceBetween(
      currentUserLocation,
      profile.location,
    );
    final distanceLabel = distanceKm == null
        ? null
        : LocationService.formatDistance(distanceKm);

    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // 이름 + 나이 + MBTI
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Flexible(
                  child: Text(
                    '${profile.displayName}, ${profile.age}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.2,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (profile.mbti != null) ...[
                  const SizedBox(width: 8),
                  _MbtiChip(mbti: profile.mbti!),
                ],
                if (distanceLabel != null) ...[
                  const SizedBox(width: 8),
                  _DistanceChip(label: distanceLabel),
                ],
              ],
            ),

            if (compatibilityHint != null) ...[
              const SizedBox(height: 7),
              _CompatibilityChip(hint: compatibilityHint),
            ],
            if (profile.verifications.hasAny) ...[
              const SizedBox(height: 7),
              VerificationBadges(
                verifications: profile.verifications,
                brightness: Brightness.dark,
              ),
            ],

            // 직업
            if (profile.jobTitle != null || profile.jobCategory != null) ...[
              const SizedBox(height: 4),
              _jobLine(),
            ],

            // 소개글
            if (profile.bio.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                profile.bio,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 13,
                  height: 1.45,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],

            // 관심사 칩
            if (interestLabels.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: interestLabels
                    .map((label) => _TagChip(label: label))
                    .toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _jobLine() {
    final catLabel = profile.jobCategory != null
        ? ProfileOptions.keyToLabel(
            ProfileOptions.jobCategoryOptions,
            profile.jobCategory!,
          )
        : null;
    // 이모지 접두어 제거 (예: '🌐 IT 업계' → 'IT 업계')
    final catName = catLabel != null && catLabel.contains(' ')
        ? catLabel.substring(catLabel.indexOf(' ') + 1)
        : catLabel;

    final parts = [?catName, ?profile.jobTitle];
    if (parts.isEmpty) return const SizedBox.shrink();

    return Row(
      children: [
        const Icon(Icons.work_outline, size: 13, color: Colors.white60),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            parts.join(' · '),
            style: const TextStyle(color: Colors.white70, fontSize: 13),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _DistanceChip extends StatelessWidget {
  final String label;
  const _DistanceChip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.26),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white30, width: 0.5),
      ),
      child: Text(
        '🔥 $label',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w700,
          height: 1,
        ),
      ),
    );
  }
}

class _CompatibilityChip extends StatelessWidget {
  final CompatibilityHint hint;
  const _CompatibilityChip({required this.hint});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.26),
          width: 0.6,
        ),
      ),
      child: Text(
        '${hint.emoji} ${hint.shortLabel}',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w700,
          height: 1,
        ),
      ),
    );
  }
}

class _MbtiChip extends StatelessWidget {
  final String mbti;
  const _MbtiChip({required this.mbti});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white30, width: 0.5),
      ),
      child: Text(
        mbti,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _TagChip extends StatelessWidget {
  final String label;
  const _TagChip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white24, width: 0.5),
      ),
      child: Text(
        label,
        style: const TextStyle(color: Colors.white, fontSize: 12, height: 1),
      ),
    );
  }
}
