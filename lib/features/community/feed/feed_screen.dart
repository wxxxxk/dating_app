import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../models/community/community_enums.dart';
import '../../../models/community/community_post.dart';
import '../../../services/auth/auth_service.dart';
import '../../../services/community/community_media_service.dart';
import '../../../services/community/community_service.dart';
import '../../../services/privacy/contact_avoidance_service.dart';
import '../../../services/safety/safety_service.dart';
import '../../../shared/widgets/app_components.dart';
import '../community_audience_filter.dart';
import '../community_report_sheet.dart';
import 'feed_compose_screen.dart';
import 'feed_post_detail_screen.dart';
import 'feed_widgets.dart';

/// 피드 화면(Phase 4-3, Design Phase 1-J) — 커뮤니티 홈에서 push되는 독립 화면.
///
/// 사진 게시물 목록을 보여주고 작성·상세 진입을 담당한다. 차단·지인 피하기
/// 상대의 글은 표시만 건너뛴다(문서·카운트는 건드리지 않는다).
///
/// 라운지가 텍스트 중심의 대화 스트림이라면, 피드는 사진이 먼저 읽히는
/// 비주얼 스토리 스트림이다 — 웜 캔버스 위에 사진 프레임을 띄운다.
class FeedScreen extends StatefulWidget {
  final AuthService authService;
  final CommunityService communityService;
  final CommunityMediaService mediaService;
  final SafetyService safetyService;
  final ContactAvoidanceService contactAvoidanceService;

  const FeedScreen({
    super.key,
    required this.authService,
    required this.communityService,
    required this.mediaService,
    required this.safetyService,
    required this.contactAvoidanceService,
  });

  @override
  State<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends State<FeedScreen> {
  /// build()에서 만들면 setState마다 재구독되므로 화면 수명 동안 하나만 둔다.
  late final Stream<List<CommunityPost>> _postsStream = widget.communityService
      .watchPosts(surface: CommunityPostSurface.feed);

  late final CommunityAudienceFilter _audience = CommunityAudienceFilter(
    safetyService: widget.safetyService,
    contactAvoidanceService: widget.contactAvoidanceService,
  );

  /// 같은 요청이 두 번 나가지 않게 하는 진행 중 표시.
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _audience.start(
      uid: _currentUid,
      onChanged: () {
        if (mounted) setState(() {});
      },
    );
  }

  @override
  void dispose() {
    _audience.dispose();
    super.dispose();
  }

  String? get _currentUid => widget.authService.currentUser?.uid;

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openCompose() async {
    if (_busy) return;
    _busy = true;
    try {
      final created = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => FeedComposeScreen(
            authService: widget.authService,
            communityService: widget.communityService,
            mediaService: widget.mediaService,
          ),
        ),
      );
      // 새 글은 stream이 곧바로 반영하므로 목록을 따로 다시 읽지 않는다.
      if (created == true) _showMessage('피드에 올렸어요.');
    } finally {
      _busy = false;
    }
  }

  void _openDetail(CommunityPost post) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FeedPostDetailScreen(
          postId: post.id,
          authService: widget.authService,
          communityService: widget.communityService,
          mediaService: widget.mediaService,
          safetyService: widget.safetyService,
          contactAvoidanceService: widget.contactAvoidanceService,
        ),
      ),
    );
  }

  Future<void> _deletePost(CommunityPost post) async {
    if (_busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('게시물을 삭제할까요?'),
        content: const Text('삭제하면 사진도 함께 지워지고 다시 되돌릴 수 없어요.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('삭제하기'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    _busy = true;
    try {
      await widget.communityService.deletePost(postId: post.id);
      // 서버가 실제 파일을 지웠으므로 남은 bytes 캐시도 버린다.
      evictFeedImageCache(post.imagePaths);
      _showMessage('게시물을 삭제했어요.');
    } on CommunityActionError catch (e) {
      _showMessage(e.message);
    } catch (_) {
      _showMessage(CommunityService.genericErrorMessage);
    } finally {
      _busy = false;
    }
  }

  Future<void> _reportPost(CommunityPost post) async {
    final uid = _currentUid;
    if (uid == null || _busy) return;
    _busy = true;
    try {
      final outcome = await showCommunityReportSheet(
        context,
        communityService: widget.communityService,
        safetyService: widget.safetyService,
        currentUid: uid,
        targetType: 'post',
        postId: post.id,
        reportedUid: post.authorUid,
      );
      if (outcome == null || !mounted) return;
      if (outcome.blocked) {
        await _audience.refreshBlocked(
          uid: uid,
          onChanged: () {
            if (mounted) setState(() {});
          },
        );
      }
      _showMessage(outcome.blocked ? '신고하고 차단했어요.' : '신고를 접수했어요.');
    } finally {
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final uid = _currentUid;
    // FAB가 마지막 게시물을 가리지 않도록 실제 확장 FAB 높이 + 여백 + 시스템
    // 하단 인셋을 합쳐 리스트 아래 여백을 만든다(하드코딩 대신).
    final listBottomPadding = 84 + MediaQuery.of(context).padding.bottom;

    return Scaffold(
      key: const ValueKey('feed-screen'),
      backgroundColor: AppColors.warmCanvas,
      appBar: AppBar(
        backgroundColor: AppColors.warmCanvas,
        surfaceTintColor: AppColors.warmCanvas,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: const Text('피드', style: AppTextStyles.cardTitle),
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const ValueKey('feed-create-post-button'),
        onPressed: _openCompose,
        backgroundColor: AppColors.brandPrimaryStrong,
        foregroundColor: AppColors.onBrandPrimary,
        elevation: 2,
        highlightElevation: 3,
        icon: const Icon(Icons.add_a_photo_rounded, size: 20),
        label: const Text(
          '피드 올리기',
          style: TextStyle(
            fontFamily: AppFonts.body,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _FeedHeader(),
            const Padding(
              padding: EdgeInsets.fromLTRB(
                AppSpacing.screenH,
                0,
                AppSpacing.screenH,
                AppSpacing.lg,
              ),
              child: _FeedSafetyNotice(),
            ),
            Expanded(
              child: StreamBuilder<List<CommunityPost>>(
                stream: _postsStream,
                builder: (context, snap) {
                  if (snap.hasError) {
                    return const _FeedError();
                  }
                  if (snap.connectionState == ConnectionState.waiting &&
                      !snap.hasData) {
                    return const _FeedLoading(key: ValueKey('feed-loading'));
                  }

                  final posts = (snap.data ?? const <CommunityPost>[])
                      .where(
                        (post) => !_audience.isExcluded(
                          authorUid: post.authorUid,
                          selfUid: uid,
                        ),
                      )
                      .toList();

                  if (posts.isEmpty) return const _FeedEmpty();

                  return ListView.separated(
                    key: const ValueKey('feed-post-list'),
                    padding: EdgeInsets.fromLTRB(
                      AppSpacing.screenH,
                      AppSpacing.xs,
                      AppSpacing.screenH,
                      listBottomPadding,
                    ),
                    itemCount: posts.length,
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: AppSpacing.xl),
                    itemBuilder: (_, index) {
                      final post = posts[index];
                      return FeedPostCard(
                        post: post,
                        mediaService: widget.mediaService,
                        isMine: uid != null && post.authorUid == uid,
                        onTap: () => _openDetail(post),
                        onDelete: () => _deletePost(post),
                        onReport: () => _reportPost(post),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 목록 위 compact header.
///
/// 사진이 첫 화면에 빨리 보여야 하므로 큰 히어로를 만들지 않는다. 설명 문장은
/// 아래 안전 안내 첫 줄(`일상과 취향을 사진으로 나눠보세요.`)이 이미 담당하므로
/// 여기서 중복해 쓰지 않는다.
class _FeedHeader extends StatelessWidget {
  const _FeedHeader();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.screenH,
        AppSpacing.sm,
        AppSpacing.screenH,
        AppSpacing.lg,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '일상과 취향',
                  style: AppTextStyles.caption.copyWith(
                    color: AppColors.brandPrimaryStrong,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.4,
                  ),
                ),
                const SizedBox(height: 3),
                const Text('오늘의 순간을 함께 나눠요', style: AppTextStyles.sectionTitle),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          // 라운지의 ConnectionMotif와 구분되는 photo-frame 문법. 장식이라
          // semantics에서 제외한다.
          const ExcludeSemantics(
            child: IgnorePointer(
              child: SizedBox(
                width: 58,
                height: 42,
                child: _PhotoFramesMotif(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 겹쳐 놓인 두 장의 추상 사진 프레임. 가짜 사진·사용자를 만들지 않고 형태만
/// 암시한다 — 피드가 "사진을 나누는 곳"임을 헤더에서 한 번에 읽힌다.
class _PhotoFramesMotif extends StatelessWidget {
  const _PhotoFramesMotif();

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned(
          left: 0,
          bottom: 0,
          child: Transform.rotate(
            angle: -0.10,
            child: _PhotoFrame(
              fill: AppColors.surfaceMintSoft,
              border: AppColors.brandPrimary.withValues(alpha: 0.35),
              dot: AppColors.brandPrimary.withValues(alpha: 0.5),
            ),
          ),
        ),
        Positioned(
          right: 0,
          top: 0,
          child: Transform.rotate(
            angle: 0.12,
            child: _PhotoFrame(
              fill: AppColors.expressiveAccentSoft,
              border: AppColors.expressiveAccent.withValues(alpha: 0.4),
              dot: AppColors.expressiveAccent.withValues(alpha: 0.55),
            ),
          ),
        ),
      ],
    );
  }
}

class _PhotoFrame extends StatelessWidget {
  final Color fill;
  final Color border;
  final Color dot;

  const _PhotoFrame({
    required this.fill,
    required this.border,
    required this.dot,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 34,
      height: 30,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: border),
      ),
      child: Align(
        alignment: Alignment.bottomLeft,
        child: Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
        ),
      ),
    );
  }
}

/// 안전 안내. 문구는 그대로 두고 경고처럼 보이지 않게 뉴트럴로만 구분한다.
class _FeedSafetyNotice extends StatelessWidget {
  const _FeedSafetyNotice();

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
          Icon(Icons.shield_outlined, size: 17, color: AppColors.textMuted),
          SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              '일상과 취향을 사진으로 나눠보세요.\n'
              '사진에 연락처·신분증·인증번호·금융정보가 보이지 않는지 확인해주세요.',
              style: AppTextStyles.caption,
            ),
          ),
        ],
      ),
    );
  }
}

// ═══ 상태 화면 ═══════════════════════════════════════════════════════════════

/// 목록 자리를 유지하는 skeleton. 이전 목록을 다시 보여주지 않는다.
class _FeedLoading extends StatelessWidget {
  const _FeedLoading({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.screenH,
        AppSpacing.xs,
        AppSpacing.screenH,
        AppSpacing.xxl,
      ),
      physics: const NeverScrollableScrollPhysics(),
      children: [
        for (var i = 0; i < 2; i++) ...[
          const _FeedPostSkeleton(),
          const SizedBox(height: AppSpacing.xl),
        ],
        Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.brandPrimary.withValues(alpha: 0.6),
            ),
          ),
        ),
      ],
    );
  }
}

class _FeedPostSkeleton extends StatelessWidget {
  const _FeedPostSkeleton();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            _SkeletonBox(width: 40, height: 40, radius: 999),
            SizedBox(width: AppSpacing.md),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _SkeletonBox(width: 92, height: 13),
                SizedBox(height: 6),
                _SkeletonBox(width: 58, height: 11),
              ],
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        const _SkeletonBox(height: 220, radius: AppRadius.heroSoft),
        const SizedBox(height: AppSpacing.md),
        const _SkeletonBox(height: 13),
        const SizedBox(height: AppSpacing.sm),
        Align(
          alignment: Alignment.centerLeft,
          child: _SkeletonBox(width: 180, height: 13),
        ),
      ],
    );
  }
}

class _SkeletonBox extends StatelessWidget {
  final double? width;
  final double height;
  final double radius;

  const _SkeletonBox({this.width, required this.height, this.radius = 999});

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

/// 아직 사진이 없는 상태. 오류처럼 보이지 않게 하고, 작성 CTA는 FAB가 이미
/// 담당하므로 여기에 버튼을 또 두지 않는다.
class _FeedEmpty extends StatelessWidget {
  const _FeedEmpty();

  @override
  Widget build(BuildContext context) {
    return ListView(
      key: const ValueKey('feed-empty'),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.screenH,
        AppSpacing.xxl,
        AppSpacing.screenH,
        AppSpacing.xxl,
      ),
      children: [
        const ExcludeSemantics(
          child: Center(
            child: SizedBox(width: 104, height: 72, child: _EmptyPhotoFrames()),
          ),
        ),
        const SizedBox(height: AppSpacing.lg20),
        const Text(
          '아직 올라온 사진이 없어요.\n첫 사진을 남겨보세요.',
          textAlign: TextAlign.center,
          style: AppTextStyles.bodySecondary,
        ),
      ],
    );
  }
}

/// 아직 채워지지 않은 두 장의 사진 프레임. 가짜 사진·사용자·숫자를 만들지 않는다.
class _EmptyPhotoFrames extends StatelessWidget {
  const _EmptyPhotoFrames();

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned(
          left: 4,
          bottom: 0,
          child: Transform.rotate(
            angle: -0.08,
            child: _EmptyPhotoFrame(
              fill: AppColors.surfaceMintSoft,
              border: AppColors.brandPrimary.withValues(alpha: 0.3),
            ),
          ),
        ),
        Positioned(
          right: 4,
          top: 0,
          child: Transform.rotate(
            angle: 0.10,
            child: _EmptyPhotoFrame(
              fill: AppColors.expressiveAccentSoft,
              border: AppColors.expressiveAccent.withValues(alpha: 0.3),
            ),
          ),
        ),
      ],
    );
  }
}

class _EmptyPhotoFrame extends StatelessWidget {
  final Color fill;
  final Color border;

  const _EmptyPhotoFrame({required this.fill, required this.border});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 56,
      height: 48,
      padding: const EdgeInsets.all(7),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(AppRadius.small),
        border: Border.all(color: border),
      ),
      child: Align(
        alignment: Alignment.bottomLeft,
        child: Icon(
          Icons.image_outlined,
          size: 16,
          color: border.withValues(alpha: 0.9),
        ),
      ),
    );
  }
}

/// raw Firestore 오류는 노출하지 않고 고정 문구만 보여준다.
class _FeedError extends StatefulWidget {
  const _FeedError();

  @override
  State<_FeedError> createState() => _FeedErrorState();
}

class _FeedErrorState extends State<_FeedError> {
  @override
  Widget build(BuildContext context) {
    return ListView(
      key: const ValueKey('feed-error'),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.screenH,
        AppSpacing.lg,
        AppSpacing.screenH,
        AppSpacing.xxl,
      ),
      children: [
        AppSurfaceCard(
          padding: const EdgeInsets.all(AppSpacing.lg20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: AppColors.statusDangerSoft,
                    borderRadius: BorderRadius.circular(AppRadius.small),
                  ),
                  child: const Icon(
                    Icons.error_outline_rounded,
                    size: 22,
                    color: AppColors.statusDanger,
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              const Text(
                '피드를 불러오지 못했어요.',
                textAlign: TextAlign.center,
                style: AppTextStyles.bodySecondary,
              ),
              const SizedBox(height: AppSpacing.lg),
              AppBrandButton(
                key: const ValueKey('feed-retry'),
                label: '다시 시도',
                icon: Icons.refresh_rounded,
                variant: AppBrandButtonVariant.outline,
                // 같은 stream을 계속 구독하므로 재빌드로 다시 그리게만 한다.
                onPressed: () => setState(() {}),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
