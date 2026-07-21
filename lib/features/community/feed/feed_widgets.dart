import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../models/community/community_post.dart';
import '../../../services/community/community_media_service.dart';
import '../lounge/lounge_widgets.dart';

/// Feed 표시 요소(Phase 4-3).
///
/// 이미지는 **download URL 없이** 내부 Storage 경로에서 bytes를 직접 읽는다.
/// 경로 문자열은 어떤 경우에도 화면에 보여주지 않고, 실패하면 원인을 감춘
/// 중립 placeholder만 그린다.

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
    final future = mediaService.loadFeedImageBytes(storagePath: storagePath);
    _entries[storagePath] = future;
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
    return future;
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

  const FeedStorageImage({
    super.key,
    required this.mediaService,
    required this.storagePath,
    this.height,
    this.fit = BoxFit.cover,
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

  @override
  void didUpdateWidget(FeedStorageImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 경로가 바뀔 때만 다시 읽는다(단순 rebuild로는 재요청하지 않는다).
    if (oldWidget.storagePath != widget.storagePath) {
      _future = _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return _FeedImagePlaceholder(
            key: const ValueKey('feed-image-loading'),
            height: widget.height,
          );
        }
        final bytes = snap.data;
        if (bytes == null || bytes.isEmpty) {
          // 실패 이유(권한/네트워크/삭제)는 구분해 보여주지 않는다.
          return _FeedImagePlaceholder(
            key: const ValueKey('feed-image-unavailable'),
            height: widget.height,
            icon: Icons.image_not_supported_outlined,
          );
        }
        return Image.memory(
          bytes,
          key: const ValueKey('feed-image-loaded'),
          height: widget.height,
          width: double.infinity,
          fit: widget.fit,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => _FeedImagePlaceholder(
            height: widget.height,
            icon: Icons.image_not_supported_outlined,
          ),
        );
      },
    );
  }
}

class _FeedImagePlaceholder extends StatelessWidget {
  final double? height;
  final IconData? icon;

  const _FeedImagePlaceholder({super.key, this.height, this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      width: double.infinity,
      color: AppColors.background,
      alignment: Alignment.center,
      child: icon == null
          ? null
          : Icon(icon, size: 28, color: AppColors.textSecondary),
    );
  }
}

/// 목록용 Feed 카드. 대표 이미지 1장만 읽어 스크롤 비용을 줄인다.
class FeedPostCard extends StatelessWidget {
  static const double imageHeight = 220;

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
    return Material(
      key: ValueKey('feed-post-${post.id}'),
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(AppRadius.card),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.card),
        child: Container(
          width: double.infinity,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
                child: CommunityAuthorHeader(
                  author: post.author,
                  createdAt: post.createdAt,
                  trailing: SizedBox(
                    width: 32,
                    height: 32,
                    child: PopupMenuButton<String>(
                      key: ValueKey('feed-post-menu-${post.id}'),
                      padding: EdgeInsets.zero,
                      icon: const Icon(
                        Icons.more_horiz_rounded,
                        size: 18,
                        color: AppColors.textSecondary,
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
                          const PopupMenuItem(
                            value: 'delete',
                            child: Text('삭제하기'),
                          )
                        else
                          const PopupMenuItem(
                            value: 'report',
                            child: Text('신고하기'),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              if (coverPath != null)
                Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.zero,
                      child: FeedStorageImage(
                        mediaService: mediaService,
                        storagePath: coverPath,
                        height: imageHeight,
                      ),
                    ),
                    if (post.imagePaths.length > 1)
                      Positioned(
                        top: 10,
                        right: 10,
                        child: Container(
                          key: ValueKey('feed-post-image-count-${post.id}'),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.night.withValues(alpha: 0.72),
                            borderRadius: BorderRadius.circular(AppRadius.chip),
                          ),
                          child: Text(
                            '1/${post.imagePaths.length}',
                            style: const TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                              color: AppColors.onNight,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      post.text,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13.5,
                        height: 1.5,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 10),
                    CommunityCountRow(
                      reactionCount: post.reactionCount,
                      commentCount: post.commentCount,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 게시물이 삭제됐을 때 캐시에 남은 이미지를 버린다.
void evictFeedImageCache(Iterable<String> storagePaths) =>
    _FeedImageCache.evict(storagePaths);

@visibleForTesting
void clearFeedImageCacheForTest() => _FeedImageCache.clear();
