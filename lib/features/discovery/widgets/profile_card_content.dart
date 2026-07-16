import 'package:flutter/material.dart';

import '../../../core/constants/profile_options.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/text_sanitizer.dart';
import '../../../models/public_profile.dart';
import '../../../models/user_profile.dart';
import '../../../services/location/location_service.dart';
import '../../profile/widgets/verification_badge.dart';

/// 디스커버리 카드에 표시되는 프로필 내용.
///
/// 사진, 이름/나이/MBTI, 소개글, 관심사 칩을 렌더링한다.
/// [SwipeCard]의 child로 사용된다.
class ProfileCardContent extends StatefulWidget {
  final PublicProfile profile;
  final UserLocation? currentUserLocation;
  final VoidCallback? onProfileTap;

  const ProfileCardContent({
    super.key,
    required this.profile,
    this.currentUserLocation,
    this.onProfileTap,
  });

  @override
  State<ProfileCardContent> createState() => _ProfileCardContentState();
}

class _ProfileCardContentState extends State<ProfileCardContent> {
  int _photoIndex = 0;
  final PageController _pageController = PageController();
  bool _precached = false;

  PublicProfile get profile => widget.profile;
  UserLocation? get currentUserLocation => widget.currentUserLocation;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 최초 빌드 이후 한 번, 현재 사진과 이웃 사진을 미리 캐시해둔다.
    if (!_precached) {
      _precached = true;
      _precacheAdjacent();
    }
  }

  @override
  void didUpdateWidget(covariant ProfileCardContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 카드가 다른 프로필로 교체된 경우(State는 재사용됨) — 사진 인덱스와
    // PageView 위치를 모두 처음으로 되돌려야 이전 프로필의 스크롤 위치가
    // 새 프로필에 잔상처럼 남지 않는다.
    if (oldWidget.profile.uid != widget.profile.uid) {
      _photoIndex = 0;
      if (_pageController.hasClients) {
        _pageController.jumpToPage(0);
      }
      _precacheAdjacent();
      return;
    }
    if (_photoIndex >= widget.profile.photoUrls.length) {
      _photoIndex = 0;
      if (_pageController.hasClients) {
        _pageController.jumpToPage(0);
      }
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  /// 현재 사진의 좌우 이웃 사진을 미리 디코드해둔다.
  ///
  /// precache가 끝나 있으면 실제로 그 사진으로 넘어갈 때 로딩 스켈레톤 없이
  /// 바로 표시된다 — 이게 "사진이 나타났다 사라지는" flicker를 없애는 핵심이다.
  void _precacheAdjacent() {
    final urls = profile.photoUrls;
    for (final i in [_photoIndex - 1, _photoIndex + 1]) {
      if (i >= 0 && i < urls.length) {
        precacheImage(NetworkImage(urls[i]), context);
      }
    }
  }

  void _showPreviousPhoto() {
    if (profile.photoUrls.length <= 1 || _photoIndex == 0) return;
    _pageController.animateToPage(
      _photoIndex - 1,
      duration: AppDurations.base,
      curve: AppCurves.standard,
    );
  }

  void _showNextPhoto() {
    if (profile.photoUrls.length <= 1 ||
        _photoIndex >= profile.photoUrls.length - 1) {
      return;
    }
    _pageController.animateToPage(
      _photoIndex + 1,
      duration: AppDurations.base,
      curve: AppCurves.standard,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.hero),
      child: Stack(
        fit: StackFit.expand,
        children: [
          _buildPhoto(),
          _buildGradientOverlay(),
          if (profile.photoUrls.length > 1) ...[
            _PhotoTapZones(
              onPrevious: _showPreviousPhoto,
              onNext: _showNextPhoto,
            ),
            _PhotoSegmentIndicator(
              count: profile.photoUrls.length,
              activeIndex: _photoIndex,
            ),
          ],
          _buildInfoPanel(),
        ],
      ),
    );
  }

  Widget _buildPhoto() {
    final urls = profile.photoUrls;
    if (urls.isEmpty) return const _PhotoFallback();
    if (urls.length == 1) return _CardPhotoImage(url: urls.first);

    // NeverScrollableScrollPhysics로 사용자의 좌우 드래그는 완전히 막아둔다.
    // 그래야 카드 전체를 좌우로 넘기는 SwipeCard의 제스처와 절대 경합하지
    // 않는다. 페이지 전환은 오직 _PhotoTapZones의 탭 → animateToPage 호출로만
    // 일어나므로, PageView는 "부드럽게 슬라이드되는 인디케이터" 역할만 한다.
    return PageView.builder(
      controller: _pageController,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: urls.length,
      onPageChanged: (index) {
        setState(() => _photoIndex = index);
        _precacheAdjacent();
      },
      itemBuilder: (context, index) => _CardPhotoImage(url: urls[index]),
    );
  }

  Widget _buildGradientOverlay() {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      height: 340,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            stops: const [0.0, 0.4, 1.0],
            colors: [
              AppColors.ink.withValues(alpha: 0),
              AppColors.ink.withValues(alpha: 0.2),
              AppColors.ink.withValues(alpha: 0.84),
            ],
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
    final distanceKm = LocationService.distanceToCoarse(
      currentUserLocation,
      profile.coarseLocation,
    );
    final distanceLabel = distanceKm == null
        ? null
        : LocationService.formatDistance(distanceKm);

    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onProfileTap,
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
                        color: AppColors.textOnDark,
                        fontSize: 27,
                        fontWeight: FontWeight.w900,
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

              if (profile.relationshipGoal != null) ...[
                const SizedBox(height: 7),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    if (profile.relationshipGoal != null)
                      _RelationshipGoalChip(goalKey: profile.relationshipGoal!),
                  ],
                ),
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
                  stripEmoji(profile.bio),
                  style: TextStyle(
                    color: AppColors.textOnDark.withValues(alpha: 0.76),
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
    // 표시용 접두어가 들어오면 본문만 사용한다.
    final catName = catLabel != null && catLabel.contains(' ')
        ? catLabel.substring(catLabel.indexOf(' ') + 1)
        : catLabel;

    final parts = [?catName, ?profile.jobTitle];
    if (parts.isEmpty) return const SizedBox.shrink();

    return Row(
      children: [
        Icon(
          Icons.work_rounded,
          size: 13,
          color: AppColors.surface.withValues(alpha: 0.6),
        ),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            parts.join(' · '),
            style: TextStyle(
              color: AppColors.surface.withValues(alpha: 0.7),
              fontSize: 13,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _PhotoTapZones extends StatelessWidget {
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  const _PhotoTapZones({required this.onPrevious, required this.onNext});

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: onPrevious,
            ),
          ),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: onNext,
            ),
          ),
        ],
      ),
    );
  }
}

/// 네트워크 사진 1장을 표시한다.
///
/// 로딩 중엔 [_PhotoSkeleton]을 보여주다 디코드가 끝나면 AnimatedSwitcher로
/// 부드럽게 크로스페이드한다. 실패하면 [_PhotoFallback]으로 안정적으로
/// 대체하고(성공→실패→성공을 오가며 깜빡이지 않음), URL이 바뀌기 전까지는
/// 다시 전환되지 않는다.
class _CardPhotoImage extends StatelessWidget {
  final String url;
  const _CardPhotoImage({required this.url});

  @override
  Widget build(BuildContext context) {
    return Image.network(
      url,
      key: ValueKey(url),
      fit: BoxFit.cover,
      width: double.infinity,
      height: double.infinity,
      loadingBuilder: (context, child, progress) {
        final loaded = progress == null;
        return AnimatedSwitcher(
          duration: AppDurations.base,
          child: loaded
              ? KeyedSubtree(key: const ValueKey('loaded'), child: child)
              : const _PhotoSkeleton(key: ValueKey('loading')),
        );
      },
      errorBuilder: (_, _, _) => const _PhotoFallback(),
    );
  }
}

/// 사진이 없거나(신규 유저) 로드에 실패했을 때 쓰는 고정 placeholder.
///
/// 이미지가 실패할 때마다 다른 모양으로 바뀌면 그게 또 다른 flicker처럼
/// 보이므로, 항상 이 하나의 스타일로만 고정한다.
class _PhotoFallback extends StatelessWidget {
  const _PhotoFallback();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surface,
      alignment: Alignment.center,
      child: const Icon(
        Icons.person_rounded,
        size: 80,
        color: AppColors.textSecondary,
      ),
    );
  }
}

/// 사진 로딩 중 보여주는 은은한 펄스 스켈레톤.
class _PhotoSkeleton extends StatefulWidget {
  const _PhotoSkeleton({super.key});

  @override
  State<_PhotoSkeleton> createState() => _PhotoSkeletonState();
}

class _PhotoSkeletonState extends State<_PhotoSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _opacity = Tween<double>(
      begin: 0.5,
      end: 0.85,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _opacity,
      builder: (context, _) => Container(
        color: AppColors.divider.withValues(alpha: _opacity.value),
        alignment: Alignment.center,
        child: Icon(
          Icons.person_rounded,
          size: 80,
          color: AppColors.surface.withValues(alpha: _opacity.value),
        ),
      ),
    );
  }
}

class _PhotoSegmentIndicator extends StatelessWidget {
  final int count;
  final int activeIndex;

  const _PhotoSegmentIndicator({
    required this.count,
    required this.activeIndex,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 10,
      left: 12,
      right: 12,
      child: SafeArea(
        bottom: false,
        child: Row(
          children: List.generate(count, (index) {
            final active = index == activeIndex;
            return Expanded(
              child: AnimatedContainer(
                duration: AppDurations.fast,
                curve: AppCurves.standard,
                height: 3,
                margin: EdgeInsets.only(right: index == count - 1 ? 0 : 4),
                decoration: BoxDecoration(
                  color: AppColors.surface.withValues(
                    alpha: active ? 0.95 : 0.36,
                  ),
                  borderRadius: BorderRadius.circular(AppRadius.chip),
                  boxShadow: active
                      ? [
                          BoxShadow(
                            color: AppColors.ink.withValues(alpha: 0.22),
                            blurRadius: 3,
                          ),
                        ]
                      : null,
                ),
              ),
            );
          }),
        ),
      ),
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
        color: AppColors.surfaceDark.withValues(alpha: 0.78),
        borderRadius: BorderRadius.circular(AppRadius.chip),
        border: Border.all(
          color: AppColors.mint.withValues(alpha: 0.28),
          width: 0.5,
        ),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: AppColors.textOnDark,
          fontSize: 12,
          fontWeight: FontWeight.w700,
          height: 1,
        ),
      ),
    );
  }
}

/// 상대가 찾는 관계(예: "진지한 연애를 시작하고 싶어요")를 사진 위에 작게
/// 보여준다. 사람 사진을 압도하지 않도록 다른 보조 칩과 같은 크기/톤을 쓴다.
class _RelationshipGoalChip extends StatelessWidget {
  final String goalKey;
  const _RelationshipGoalChip({required this.goalKey});

  @override
  Widget build(BuildContext context) {
    final label = ProfileOptions.keyToLabel(
      ProfileOptions.relationshipGoals,
      goalKey,
    );
    if (label == null) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.surfaceDark.withValues(alpha: 0.78),
        borderRadius: BorderRadius.circular(AppRadius.chip),
        border: Border.all(
          color: AppColors.mint.withValues(alpha: 0.28),
          width: 0.6,
        ),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: AppColors.textOnDark,
          fontSize: 12,
          fontWeight: FontWeight.w600,
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
        color: AppColors.surfaceDark.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(AppRadius.button),
        border: Border.all(
          color: AppColors.mint.withValues(alpha: 0.32),
          width: 0.5,
        ),
      ),
      child: Text(
        mbti,
        style: const TextStyle(
          color: AppColors.mint,
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
        color: AppColors.surfaceDark.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(AppRadius.button),
        border: Border.all(
          color: AppColors.mint.withValues(alpha: 0.28),
          width: 0.5,
        ),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: AppColors.textOnDark,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          height: 1,
        ),
      ),
    );
  }
}
