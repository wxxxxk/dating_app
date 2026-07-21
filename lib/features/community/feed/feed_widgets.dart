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
          return _FeedImagePlaceholder(
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
          errorBuilder: (_, _, _) => _FeedImagePlaceholder(
            height: widget.height,
            icon: Icons.image_not_supported_outlined,
          ),
        );
      },
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
      color: AppColors.background,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.image_not_supported_outlined,
            size: 28,
            color: AppColors.textSecondary,
          ),
          const SizedBox(height: 8),
          const Text(
            '사진을 불러오지 못했어요.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 4),
          TextButton(
            key: const ValueKey('feed-image-retry'),
            onPressed: onRetry,
            child: const Text('다시 시도'),
          ),
        ],
      ),
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
