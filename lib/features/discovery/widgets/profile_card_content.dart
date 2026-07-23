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
    return LayoutBuilder(
      builder: (context, constraints) {
        final media = MediaQuery.of(context);
        // 카드가 낮거나(작은 기기·큰 글씨로 밀린 경우) 폭이 좁으면 compact.
        final compact =
            constraints.maxHeight < 480 ||
            media.size.width < 340 ||
            media.textScaler.scale(1) >= 1.25;
        return ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.hero),
          child: Column(
            children: [
              // Photo Stage — 사진만의 독립 영역(정보 오버레이 없음).
              Expanded(child: _buildPhotoStage()),
              // Editorial Profile Shelf — 사진 밖 밝은 정보 영역.
              _buildShelf(compact),
            ],
          ),
        );
      },
    );
  }

  Widget _buildPhotoStage() {
    return Stack(
      fit: StackFit.expand,
      children: [
        _buildPhoto(),
        // 사진과 shelf 경계를 아주 옅게 이어주는 하단 fade(카드가 어둡게 보이지
        // 않도록 40px, 최대 15% ink만). 정보 가독성용 검정 overlay는 없다.
        const Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: 40,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0x00000000), Color(0x261C1B19)],
              ),
            ),
          ),
        ),
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
      ],
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

  // ── Editorial Profile Shelf ────────────────────────────────────────────────

  /// 사진 아래 밝은 정보 영역. 프로필 카드에 통합된 editorial page처럼 보이도록
  /// 별도 카드가 아니라 상단 얇은 border로만 사진과 구분한다. shelf 전체가
  /// onProfileTap 대상이라 어디를 눌러도 프로필 상세로 진입한다.
  Widget _buildShelf(bool compact) {
    final relationshipLabel = profile.relationshipGoal == null
        ? null
        : ProfileOptions.keyToLabel(
            ProfileOptions.relationshipGoals,
            profile.relationshipGoal!,
          );
    final distanceKm = LocationService.distanceToCoarse(
      currentUserLocation,
      profile.coarseLocation,
    );
    final distanceLabel = distanceKm == null
        ? null
        : LocationService.formatDistance(distanceKm);

    // 핵심 정보 chip: 관계 목표 > 거리 > MBTI, 최대 3개. 인증은 이름 row에서
    // 다루므로 여기서 반복하지 않는다.
    final infoChips = <Widget>[
      if (relationshipLabel != null)
        _ShelfChip(
          icon: Icons.favorite_rounded,
          label: relationshipLabel,
          tone: _ShelfChipTone.mint,
        ),
      if (distanceLabel != null)
        _ShelfChip(
          icon: Icons.place_rounded,
          label: distanceLabel,
          tone: _ShelfChipTone.neutral,
        ),
      if (profile.mbti != null)
        _ShelfChip(label: profile.mbti!, tone: _ShelfChipTone.neutral),
    ].take(3).toList();

    final interestLabels = ProfileOptions.keysToLabels(
      ProfileOptions.interests,
      profile.interests,
    ).take(compact ? 2 : 3).toList();

    final bio = stripEmoji(profile.bio).trim();
    final hasBio = bio.isNotEmpty;
    final jobLabel = _jobLabel();
    final hasJob = jobLabel != null;
    // 직업은 bio가 없거나(빈 자리 대체) 여유가 있을 때(non-compact)만 노출한다.
    final showJob = hasJob && (!hasBio || !compact);
    final bioMaxLines = (!compact && !hasJob) ? 2 : 1;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onProfileTap,
      child: Container(
        width: double.infinity,
        decoration: const BoxDecoration(
          color: AppColors.surfacePrimary,
          border: Border(top: BorderSide(color: AppColors.borderSubtle)),
        ),
        padding: EdgeInsets.fromLTRB(
          19,
          compact ? 12 : 15,
          19,
          compact ? 13 : 16,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildNameRow(compact),
            if (infoChips.isNotEmpty) ...[
              SizedBox(height: compact ? 8 : 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: infoChips,
              ),
            ],
            if (showJob) ...[
              SizedBox(height: compact ? 7 : 9),
              _buildJobLine(jobLabel),
            ],
            if (hasBio) ...[
              SizedBox(height: showJob ? 3 : (compact ? 7 : 9)),
              Text(
                bio,
                style: const TextStyle(
                  color: AppColors.textBody,
                  fontSize: 13.5,
                  height: 1.45,
                ),
                maxLines: bioMaxLines,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            if (interestLabels.isNotEmpty) ...[
              SizedBox(height: compact ? 8 : 11),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: interestLabels
                    .map((label) => _ShelfTagChip(label: label))
                    .toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildNameRow(bool compact) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Text(
            '${profile.displayName}, ${profile.age}',
            style: TextStyle(
              color: AppColors.textStrong,
              fontSize: compact ? 22 : 25,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.2,
              height: 1.1,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (profile.verifications.hasAny) ...[
          const SizedBox(width: 8),
          VerificationBadges(
            verifications: profile.verifications,
            brightness: Brightness.light,
          ),
        ],
        const SizedBox(width: 4),
        // 프로필 상세 진입을 암시하는 chevron. 실제 tap은 shelf 전체가 처리한다.
        Semantics(
          button: true,
          label: '프로필 자세히 보기',
          child: const Icon(
            Icons.chevron_right_rounded,
            size: 22,
            color: AppColors.textMuted,
          ),
        ),
      ],
    );
  }

  Widget _buildJobLine(String label) {
    return Row(
      children: [
        const Icon(
          Icons.work_outline_rounded,
          size: 14,
          color: AppColors.textMuted,
        ),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            label,
            style: const TextStyle(
              color: AppColors.textMuted,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  String? _jobLabel() {
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
    if (parts.isEmpty) return null;
    return parts.join(' · ');
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
                height: 2.5,
                margin: EdgeInsets.only(right: index == count - 1 ? 0 : 4),
                decoration: BoxDecoration(
                  color: AppColors.surface.withValues(
                    alpha: active ? 0.95 : 0.3,
                  ),
                  borderRadius: BorderRadius.circular(AppRadius.chip),
                  boxShadow: active
                      ? [
                          BoxShadow(
                            color: AppColors.ink.withValues(alpha: 0.18),
                            blurRadius: 2,
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

enum _ShelfChipTone { mint, neutral }

/// 밝은 shelf 위의 핵심 정보 chip(관계 목표·거리·MBTI). 관계 목표만 mint soft,
/// 나머지는 중립 톤으로 두어 관계 목표가 가장 먼저 읽히게 한다.
class _ShelfChip extends StatelessWidget {
  final IconData? icon;
  final String label;
  final _ShelfChipTone tone;

  const _ShelfChip({this.icon, required this.label, required this.tone});

  @override
  Widget build(BuildContext context) {
    final mint = tone == _ShelfChipTone.mint;
    final bg = mint ? AppColors.surfaceMintSoft : AppColors.surfaceSecondary;
    final fg = mint ? AppColors.mintDeep : AppColors.textBody;
    return Container(
      constraints: const BoxConstraints(maxWidth: 220),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadius.chip),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: fg),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: fg,
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                height: 1,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// shelf 하단 관심사 chip. 정보 chip보다 한 단계 약한 중립 톤.
class _ShelfTagChip extends StatelessWidget {
  final String label;
  const _ShelfTagChip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surfaceSecondary,
        borderRadius: BorderRadius.circular(AppRadius.chip),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: AppColors.textBody,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          height: 1,
        ),
      ),
    );
  }
}
