import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../models/community/community_enums.dart';
import '../../../models/community/community_post.dart';
import '../../../services/auth/auth_service.dart';
import '../../../services/community/community_service.dart';
import '../../../services/privacy/contact_avoidance_service.dart';
import '../../../services/safety/safety_service.dart';
import '../../../shared/widgets/app_components.dart';
import '../community_audience_filter.dart';
import '../community_report_sheet.dart';
import 'lounge_compose_sheet.dart';
import 'lounge_post_detail_screen.dart';
import 'lounge_widgets.dart';

/// 라운지 화면(Phase 4-2) — 커뮤니티 홈에서 push되는 독립 화면.
///
/// 게시물 목록을 보여주고 글쓰기·상세 진입을 담당한다. 차단·지인 피하기
/// 상대의 글은 표시만 건너뛴다(문서·카운트는 건드리지 않는다).
class LoungeScreen extends StatefulWidget {
  final AuthService authService;
  final CommunityService communityService;
  final SafetyService safetyService;
  final ContactAvoidanceService contactAvoidanceService;

  const LoungeScreen({
    super.key,
    required this.authService,
    required this.communityService,
    required this.safetyService,
    required this.contactAvoidanceService,
  });

  @override
  State<LoungeScreen> createState() => _LoungeScreenState();
}

class _LoungeScreenState extends State<LoungeScreen> {
  /// build()에서 만들면 setState마다 재구독되므로 화면 수명 동안 하나만 둔다.
  late final Stream<List<CommunityPost>> _postsStream = widget.communityService
      .watchPosts(surface: CommunityPostSurface.lounge);

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
      final created = await showLoungeComposeSheet(
        context,
        communityService: widget.communityService,
      );
      // 새 글은 stream이 곧바로 반영하므로 목록을 따로 다시 읽지 않는다.
      if (created) _showMessage('글을 올렸어요.');
    } finally {
      _busy = false;
    }
  }

  void _openDetail(CommunityPost post) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LoungePostDetailScreen(
          postId: post.id,
          authService: widget.authService,
          communityService: widget.communityService,
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
        title: const Text('글을 삭제할까요?'),
        content: const Text('삭제하면 라운지에서 바로 사라져요.'),
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
      _showMessage('글을 삭제했어요.');
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
    // FAB가 마지막 글을 가리지 않도록 실제 확장 FAB 높이 + 여백 + 시스템
    // 하단 인셋을 합쳐 리스트 아래 여백을 만든다(하드코딩 96 대신).
    final listBottomPadding = 84 + MediaQuery.of(context).padding.bottom;

    return Scaffold(
      key: const ValueKey('lounge-screen'),
      backgroundColor: AppColors.warmCanvas,
      appBar: AppBar(
        backgroundColor: AppColors.warmCanvas,
        surfaceTintColor: AppColors.warmCanvas,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: const Text('라운지', style: AppTextStyles.cardTitle),
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const ValueKey('lounge-create-post-button'),
        onPressed: _openCompose,
        backgroundColor: AppColors.brandPrimaryStrong,
        foregroundColor: AppColors.onBrandPrimary,
        elevation: 2,
        highlightElevation: 3,
        icon: const Icon(Icons.edit_rounded, size: 20),
        label: const Text(
          '글쓰기',
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
            const _LoungeHeader(),
            const Padding(
              padding: EdgeInsets.fromLTRB(
                AppSpacing.screenH,
                0,
                AppSpacing.screenH,
                AppSpacing.lg,
              ),
              child: _LoungeSafetyNotice(),
            ),
            Expanded(
              child: StreamBuilder<List<CommunityPost>>(
                stream: _postsStream,
                builder: (context, snap) {
                  if (snap.hasError) {
                    return const _LoungeError();
                  }
                  if (snap.connectionState == ConnectionState.waiting &&
                      !snap.hasData) {
                    return const _LoungeLoading(
                      key: ValueKey('lounge-loading'),
                    );
                  }

                  final posts = (snap.data ?? const <CommunityPost>[])
                      .where(
                        (post) => !_audience.isExcluded(
                          authorUid: post.authorUid,
                          selfUid: uid,
                        ),
                      )
                      .toList();

                  if (posts.isEmpty) return const _LoungeEmpty();

                  // 게시물은 캔버스 위를 흐르는 스트림으로 그린다 — 흰 카드가
                  // 반복되지 않도록 배경을 두지 않고 얇은 divider로만 나눈다.
                  return ListView.builder(
                    key: const ValueKey('lounge-post-list'),
                    padding: EdgeInsets.only(bottom: listBottomPadding),
                    itemCount: posts.length,
                    itemBuilder: (_, index) {
                      final post = posts[index];
                      return _LoungePostTile(
                        post: post,
                        isMine: uid != null && post.authorUid == uid,
                        showDivider: index != posts.length - 1,
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
/// 라운지는 콘텐츠를 빨리 보여줘야 하는 화면이라 큰 히어로를 만들지 않는다.
/// 설명 문장은 아래 안전 안내의 첫 줄(`가벼운 이야기부터 시작해보세요.`)이
/// 이미 담당하므로 여기서 중복해 쓰지 않는다.
class _LoungeHeader extends StatelessWidget {
  const _LoungeHeader();

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
                  '가벼운 대화',
                  style: AppTextStyles.caption.copyWith(
                    color: AppColors.brandPrimaryStrong,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.4,
                  ),
                ),
                const SizedBox(height: 3),
                const Text(
                  '지금 어떤 이야기를 나누고 싶나요?',
                  style: AppTextStyles.sectionTitle,
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          // 커뮤니티 허브보다 작고 약하게. 장식이라 semantics에서 제외한다.
          const ExcludeSemantics(
            child: IgnorePointer(
              child: SizedBox(
                width: 52,
                height: 30,
                child: ConnectionMotif(strokeWidth: 1.4, opacity: 0.5),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 안전 안내. 문구는 그대로 두고 경고처럼 보이지 않게 뉴트럴로만 구분한다.
class _LoungeSafetyNotice extends StatelessWidget {
  const _LoungeSafetyNotice();

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
              '가벼운 이야기부터 시작해보세요.\n개인정보·연락처·인증번호·금전 정보는 공개하지 마세요.',
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
class _LoungeLoading extends StatelessWidget {
  const _LoungeLoading({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: AppSpacing.xxl),
      physics: const NeverScrollableScrollPhysics(),
      children: [
        for (var i = 0; i < 3; i++) const _LoungePostSkeleton(),
        const SizedBox(height: AppSpacing.lg),
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

class _LoungePostSkeleton extends StatelessWidget {
  const _LoungePostSkeleton();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.screenH,
        vertical: AppSpacing.lg20,
      ),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.borderSubtle)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              _SkeletonBox(width: 36, height: 36, radius: 999),
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
          const SizedBox(height: AppSpacing.lg),
          const _SkeletonBox(height: 13),
          const SizedBox(height: AppSpacing.sm),
          const _SkeletonBox(height: 13),
          const SizedBox(height: AppSpacing.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: _SkeletonBox(width: 180, height: 13),
          ),
        ],
      ),
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

/// 아직 글이 없는 상태. 오류처럼 보이지 않게 하고, 글쓰기 CTA는 FAB가 이미
/// 담당하므로 여기에 버튼을 또 두지 않는다.
class _LoungeEmpty extends StatelessWidget {
  const _LoungeEmpty();

  @override
  Widget build(BuildContext context) {
    return ListView(
      key: const ValueKey('lounge-empty'),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.screenH,
        AppSpacing.xxl,
        AppSpacing.screenH,
        AppSpacing.xxl,
      ),
      children: [
        const ExcludeSemantics(
          child: Center(
            child: SizedBox(width: 96, height: 64, child: _EmptyBubbles()),
          ),
        ),
        const SizedBox(height: AppSpacing.lg20),
        const Text(
          '아직 올라온 이야기가 없어요.\n첫 이야기를 남겨보세요.',
          textAlign: TextAlign.center,
          style: AppTextStyles.bodySecondary,
        ),
      ],
    );
  }
}

/// 아직 이어지지 않은 두 말풍선. 가짜 글·사용자·숫자를 만들지 않는다.
class _EmptyBubbles extends StatelessWidget {
  const _EmptyBubbles();

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned(
          left: 0,
          top: 0,
          child: _EmptyBubble(
            width: 56,
            height: 30,
            color: AppColors.surfaceMintSoft,
            borderColor: AppColors.brandPrimary.withValues(alpha: 0.3),
          ),
        ),
        Positioned(
          right: 0,
          bottom: 0,
          child: _EmptyBubble(
            width: 50,
            height: 28,
            color: AppColors.expressiveAccentSoft,
            borderColor: AppColors.expressiveAccent.withValues(alpha: 0.3),
          ),
        ),
      ],
    );
  }
}

class _EmptyBubble extends StatelessWidget {
  final double width;
  final double height;
  final Color color;
  final Color borderColor;

  const _EmptyBubble({
    required this.width,
    required this.height,
    required this.color,
    required this.borderColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(AppRadius.small),
        border: Border.all(color: borderColor),
      ),
    );
  }
}

/// raw Firestore 오류는 노출하지 않고 고정 문구만 보여준다.
class _LoungeError extends StatefulWidget {
  const _LoungeError();

  @override
  State<_LoungeError> createState() => _LoungeErrorState();
}

class _LoungeErrorState extends State<_LoungeError> {
  @override
  Widget build(BuildContext context) {
    return ListView(
      key: const ValueKey('lounge-error'),
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
                '라운지 이야기를 불러오지 못했어요.',
                textAlign: TextAlign.center,
                style: AppTextStyles.bodySecondary,
              ),
              const SizedBox(height: AppSpacing.lg),
              AppBrandButton(
                key: const ValueKey('lounge-retry'),
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

/// 스트림의 게시물 한 줄.
///
/// 흰 카드 대신 캔버스 위에 바로 얹고 얇은 divider로만 나눈다. 첫 글을
/// 특별 취급하거나 인기/최신 배지를 붙이지 않는다 — 모든 글이 같은 위계다.
class _LoungePostTile extends StatelessWidget {
  final CommunityPost post;
  final bool isMine;
  final bool showDivider;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback onReport;

  const _LoungePostTile({
    required this.post,
    required this.isMine,
    required this.showDivider,
    required this.onTap,
    required this.onDelete,
    required this.onReport,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      key: ValueKey('lounge-post-${post.id}'),
      color: Colors.transparent,
      child: AppPressable(
        onTap: onTap,
        borderRadius: BorderRadius.zero,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.screenH,
            vertical: AppSpacing.lg20,
          ),
          decoration: BoxDecoration(
            border: showDivider
                ? const Border(
                    bottom: BorderSide(color: AppColors.borderSubtle),
                  )
                : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CommunityAuthorHeader(
                author: post.author,
                createdAt: post.createdAt,
                trailing: _PostMenu(
                  postId: post.id,
                  isMine: isMine,
                  onDelete: onDelete,
                  onReport: onReport,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              // 본문이 이 화면의 주인공이다. 브랜드 색을 입히지 않는다.
              Text(
                post.text,
                maxLines: 6,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.body.copyWith(fontSize: 14.5),
              ),
              const SizedBox(height: AppSpacing.md),
              CommunityCountRow(
                reactionCount: post.reactionCount,
                commentCount: post.commentCount,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PostMenu extends StatelessWidget {
  final String postId;
  final bool isMine;
  final VoidCallback onDelete;
  final VoidCallback onReport;

  const _PostMenu({
    required this.postId,
    required this.isMine,
    required this.onDelete,
    required this.onReport,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      // 본문보다 강해 보이지 않게 아이콘 톤은 muted로 두되, 터치 영역은
      // 넉넉히 확보한다.
      width: 40,
      height: 40,
      child: PopupMenuButton<String>(
        key: ValueKey('lounge-post-menu-$postId'),
        padding: EdgeInsets.zero,
        tooltip: '게시물 메뉴',
        icon: const Icon(
          Icons.more_horiz_rounded,
          size: 20,
          color: AppColors.textMuted,
        ),
        onSelected: (value) {
          if (value == 'delete') {
            onDelete();
          } else if (value == 'report') {
            onReport();
          }
        },
        itemBuilder: (_) => [
          if (isMine)
            const PopupMenuItem(value: 'delete', child: Text('삭제하기'))
          else
            const PopupMenuItem(value: 'report', child: Text('신고하기')),
        ],
      ),
    );
  }
}
