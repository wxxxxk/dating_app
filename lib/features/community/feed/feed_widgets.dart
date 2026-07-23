import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../models/community/community_post.dart';
import '../../../services/community/community_media_service.dart';
import '../../../shared/widgets/app_components.dart';
import '../lounge/lounge_widgets.dart';

/// Feed 표시 요소(Phase 4-3, Design Phase 1-J).
///
/// 이미지는 **download URL 없이** 내부 Storage 경로에서 bytes를 직접 읽는다.
/// 경로 문자열은 어떤 경우에도 화면에 보여주지 않고, 실패하면 원인을 감춘
/// 중립 placeholder만 그린다.
///
/// 디자인은 "웜 캔버스 위에 뜬 사진" 문법이다 — 흰 카드로 작성자·사진·본문을
/// 함께 묶지 않고, 사진만 큰 라운드 프레임으로 띄우고 작성자·본문은 캔버스
/// 위에 얹는다. 라운지(텍스트 divider 스트림)와 시각적으로 구분한다.

/// 스크롤 중 같은 이미지를 반복해서 내려받지 않도록 두는 작은 메모리 캐시.
///
/// 화면(Element)이 재사용될 때마다 요청이 나가는 것을 막는 용도라 크기를
/// 작게 유지한다 — 오래된 항목부터 버린다.
class _FeedImageCache {
  static const int maxEntries = 8;
  static final LinkedHashMap<String, Future<Uint8List?>> _entries =
      LinkedHashMap<String, Future<Uint8List?>>();

  static Future<Uint8List?> load({
    required CommunityMediaService mediaService,
    required String storagePath,
  }) {
    final cached = _entries.remove(storagePath);
    if (cached != null) {
      _entries[storagePath] = cached;
      return cached;
    }
    // 진행 중인 요청은 계속 공유해 중복 다운로드를 막되(dedup), **성공한
    // bytes만** 캐시에 남긴다. 실패(null/empty/예외)를 캐시에 남기면 IAM이나
    // 네트워크가 복구된 뒤에도 같은 실패가 영구히 재생되기 때문이다.
    late final Future<Uint8List?> future;
    future = mediaService
        .loadFeedImageBytes(storagePath: storagePath)
        .then((bytes) {
          if (bytes == null || bytes.isEmpty) {
            _evictIfSame(storagePath, future);
          }
          return bytes;
        })
        .onError<Object>((error, stack) {
          _evictIfSame(storagePath, future);
          return null;
        });
    _entries[storagePath] = future;
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
    return future;
  }

  /// 그 사이에 다른 요청이 자리를 차지했다면 건드리지 않는다.
  static void _evictIfSame(String storagePath, Future<Uint8List?> future) {
    if (identical(_entries[storagePath], future)) {
      _entries.remove(storagePath);
    }
  }

  /// 게시물이 삭제되는 등으로 더 이상 유효하지 않은 항목을 버린다.
  static void evict(Iterable<String> storagePaths) {
    for (final path in storagePaths) {
      _entries.remove(path);
    }
  }

  @visibleForTesting
  static void clear() => _entries.clear();
}

/// Storage 경로에서 bytes를 읽어 그리는 이미지.
class FeedStorageImage extends StatefulWidget {
  final CommunityMediaService mediaService;
  final String storagePath;
  final double? height;
  final BoxFit fit;

  /// 성공적으로 로드된 이미지에만 붙는 접근성 라벨(경로는 절대 넣지 않는다).
  final String semanticLabel;

  const FeedStorageImage({
    super.key,
    required this.mediaService,
    required this.storagePath,
    this.height,
    this.fit = BoxFit.cover,
    this.semanticLabel = '피드 게시물 사진',
  });

  @override
  State<FeedStorageImage> createState() => _FeedStorageImageState();
}

class _FeedStorageImageState extends State<FeedStorageImage> {
  late Future<Uint8List?> _future = _load();

  Future<Uint8List?> _load() => _FeedImageCache.load(
    mediaService: widget.mediaService,
    storagePath: widget.storagePath,
  );

  /// 재시도 중복 탭 방지. 자동 재시도는 하지 않는다.
  bool _retrying = false;

  void _retry() {
    if (_retrying) return;
    _retrying = true;
    _FeedImageCache.evict([widget.storagePath]);
    final future = _load();
    // 화살표 본문으로 쓰면 대입식이 Future를 반환해 setState가 거부한다.
    setState(() {
      _future = future;
    });
    future.whenComplete(() {
      if (mounted) _retrying = false;
    });
  }

  @override
  void didUpdateWidget(FeedStorageImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 경로가 바뀔 때만 다시 읽는다(단순 rebuild로는 재요청하지 않는다).
    if (oldWidget.storagePath != widget.storagePath) {
      _retrying = false;
      _future = _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return _FeedImageLoading(
            key: const ValueKey('feed-image-loading'),
            height: widget.height,
          );
        }
        final bytes = snap.data;
        if (bytes == null || bytes.isEmpty) {
          // 실패 이유(권한/네트워크/삭제)는 구분해 보여주지 않는다.
          return _FeedImageUnavailable(
            key: const ValueKey('feed-image-unavailable'),
            height: widget.height,
            onRetry: _retry,
          );
        }
        return Image.memory(
          bytes,
          key: const ValueKey('feed-image-loaded'),
          height: widget.height,
          width: double.infinity,
          fit: widget.fit,
          gaplessPlayback: true,
          semanticLabel: widget.semanticLabel,
          errorBuilder: (_, _, _) => _FeedImagePlaceholder(
            height: widget.height,
            icon: Icons.image_not_supported_outlined,
          ),
        );
      },
    );
  }
}

/// 로딩 중 자리. 완료 전 layout shift가 없도록 media stage와 높이가 같고,
/// 반복되는 큰 스피너 대신 옅은 사진 힌트 + 작은 인디케이터 하나만 둔다.
class _FeedImageLoading extends StatelessWidget {
  final double? height;

  const _FeedImageLoading({super.key, this.height});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      width: double.infinity,
      color: AppColors.surfaceSecondary,
      alignment: Alignment.center,
      child: Stack(
        alignment: Alignment.center,
        children: const [
          ExcludeSemantics(
            child: Icon(
              Icons.photo_outlined,
              size: 30,
              color: AppColors.borderStrong,
            ),
          ),
          SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.brandPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

/// 이미지를 읽지 못했을 때의 중립 placeholder + 수동 재시도.
class _FeedImageUnavailable extends StatelessWidget {
  final double? height;
  final VoidCallback onRetry;

  const _FeedImageUnavailable({super.key, this.height, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      width: double.infinity,
      color: AppColors.surfaceSecondary,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.image_not_supported_outlined,
            size: 30,
            color: AppColors.textMuted,
          ),
          const SizedBox(height: AppSpacing.sm),
          const Text(
            '사진을 불러오지 못했어요.',
            textAlign: TextAlign.center,
            style: AppTextStyles.caption,
          ),
          const SizedBox(height: AppSpacing.xs),
          // 최소 44px 터치 영역을 확보한다.
          SizedBox(
            height: 44,
            child: TextButton(
              key: const ValueKey('feed-image-retry'),
              onPressed: onRetry,
              style: TextButton.styleFrom(
                foregroundColor: AppColors.brandPrimaryStrong,
                textStyle: const TextStyle(
                  fontFamily: AppFonts.body,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              child: const Text('다시 시도'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Image.memory decode 실패 등 정적 fallback(수동 재시도 없는 자리 유지용).
class _FeedImagePlaceholder extends StatelessWidget {
  final double? height;
  final IconData? icon;

  const _FeedImagePlaceholder({this.height, this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      width: double.infinity,
      color: AppColors.surfaceSecondary,
      alignment: Alignment.center,
      child: icon == null
          ? null
          : Icon(icon, size: 30, color: AppColors.textMuted),
    );
  }
}

/// 목록용 Feed 카드. 대표 이미지 1장만 읽어 스크롤 비용을 줄인다.
///
/// 흰 카드로 전체를 감싸지 않는다 — 사진만 큰 라운드 프레임으로 캔버스 위에
/// 띄우고, 작성자와 본문은 그 위/아래에 얹어 사진이 게시물의 중심이 되게 한다.
class FeedPostCard extends StatelessWidget {
  /// media stage 높이 범위. 320px 좁은 화면에서도 납작하지 않고, 큰 화면에서
  /// 이미지 하나가 화면을 다 차지하지 않도록 위/아래를 모두 clamp한다.
  static const double minImageHeight = 200;
  static const double maxImageHeight = 300;

  /// 대략 4:3(가로 대비 세로). 원본 비율을 완전히 보존한다고 오해시키지 않도록
  /// cover로 채우되, loading/unavailable/loaded 세 상태가 같은 높이를 쓴다.
  static const double _aspectFactor = 0.75;

  final CommunityPost post;
  final CommunityMediaService mediaService;
  final bool isMine;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback onReport;

  const FeedPostCard({
    super.key,
    required this.post,
    required this.mediaService,
    required this.isMine,
    required this.onTap,
    required this.onDelete,
    required this.onReport,
  });

  @override
  Widget build(BuildContext context) {
    final coverPath = post.imagePaths.isEmpty ? null : post.imagePaths.first;
    return AppPressable(
      key: ValueKey('feed-post-${post.id}'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.heroSoft),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 작성자 정보는 사진 위에 얹어 "누가 올린 순간인지"를 먼저 읽힌다.
            CommunityAuthorHeader(
              author: post.author,
              createdAt: post.createdAt,
              avatarRadius: 18,
              trailing: _FeedPostMenu(
                postId: post.id,
                isMine: isMine,
                onDelete: onDelete,
                onReport: onReport,
              ),
            ),
            if (coverPath != null) ...[
              const SizedBox(height: AppSpacing.md),
              _MediaStage(
                post: post,
                coverPath: coverPath,
                mediaService: mediaService,
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            // 사진을 설명하는 본문. 브랜드 색을 입히지 않는다.
            Text(
              post.text,
              maxLines: 4,
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
    );
  }
}

/// 대표 사진 한 장을 큰 라운드 프레임으로 띄운다. 여러 장이면 실제 장수만
/// 표시하고(추가 다운로드 없음), 사진 위에 작성자·본문·CTA를 얹지 않는다.
class _MediaStage extends StatelessWidget {
  final CommunityPost post;
  final String coverPath;
  final CommunityMediaService mediaService;

  const _MediaStage({
    required this.post,
    required this.coverPath,
    required this.mediaService,
  });

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(AppRadius.heroSoft);
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = (constraints.maxWidth * FeedPostCard._aspectFactor)
            .clamp(FeedPostCard.minImageHeight, FeedPostCard.maxImageHeight);
        return Stack(
          children: [
            // 캔버스에서 살짝 떠 보이도록 아주 옅은 섀도우만 준다(글로우·보더 X).
            Container(
              decoration: BoxDecoration(
                borderRadius: radius,
                boxShadow: [
                  BoxShadow(
                    color: AppColors.textStrong.withValues(alpha: 0.06),
                    blurRadius: 16,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: radius,
                child: FeedStorageImage(
                  mediaService: mediaService,
                  storagePath: coverPath,
                  height: height,
                  semanticLabel: '${post.author.displayName}님의 피드 사진',
                ),
              ),
            ),
            if (post.imagePaths.length > 1)
              Positioned(
                top: 12,
                right: 12,
                child: Container(
                  key: ValueKey('feed-post-image-count-${post.id}'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.night.withValues(alpha: 0.72),
                    borderRadius: BorderRadius.circular(AppRadius.chip),
                  ),
                  child: Text(
                    '1/${post.imagePaths.length}',
                    style: const TextStyle(
                      fontFamily: AppFonts.body,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: AppColors.onNight,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// 게시물 메뉴. 본문·사진보다 강해 보이지 않게 muted 아이콘을 쓰되 터치
/// 영역은 넉넉히 확보한다.
class _FeedPostMenu extends StatelessWidget {
  final String postId;
  final bool isMine;
  final VoidCallback onDelete;
  final VoidCallback onReport;

  const _FeedPostMenu({
    required this.postId,
    required this.isMine,
    required this.onDelete,
    required this.onReport,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 40,
      height: 40,
      child: PopupMenuButton<String>(
        key: ValueKey('feed-post-menu-$postId'),
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

/// 게시물이 삭제됐을 때 캐시에 남은 이미지를 버린다.
void evictFeedImageCache(Iterable<String> storagePaths) =>
    _FeedImageCache.evict(storagePaths);

@visibleForTesting
void clearFeedImageCacheForTest() => _FeedImageCache.clear();
