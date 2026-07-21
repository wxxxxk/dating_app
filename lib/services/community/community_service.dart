import 'package:cloud_firestore/cloud_firestore.dart';

import '../../models/community/community_enums.dart';
import '../../models/community/community_post.dart';

/// 커뮤니티 게시물 읽기 서비스(Phase 4-1).
///
/// 이번 단계는 **읽기 전용**이다. createPost/updatePost/deletePost/댓글/반응/
/// 신고 API는 제공하지 않으며 firestore.rules도 client write를 전면 차단한다.
///
/// 작성자 정보는 게시물에 저장된 authorSnapshot만 사용한다 — 게시물마다
/// publicProfiles를 다시 읽는 N+1 조회를 하지 않는다.
class CommunityService {
  CommunityService({FirebaseFirestore? firestore})
    : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  static const String collectionPath = 'communityPosts';
  static const int minLimit = 1;
  static const int maxLimit = 50;
  static const int defaultLimit = 30;

  /// 표면별 활성 게시물을 최신순으로 구독한다.
  ///
  /// 쿼리 조건(status/visibility)은 firestore.rules의 read 조건과 일치해야
  /// 한다 — 전체를 읽어와 클라이언트에서 거르지 않는다.
  Stream<List<CommunityPost>> watchPosts({
    required CommunityPostSurface surface,
    int limit = defaultLimit,
  }) {
    final safeLimit = limit.clamp(minLimit, maxLimit);
    return _db
        .collection(collectionPath)
        .where('surface', isEqualTo: communityPostSurfaceToString(surface))
        .where(
          'status',
          isEqualTo: communityContentStatusToString(
            CommunityContentStatus.active,
          ),
        )
        .where(
          'visibility',
          isEqualTo: communityVisibilityToString(
            CommunityVisibility.authenticated,
          ),
        )
        .orderBy('createdAt', descending: true)
        .limit(safeLimit)
        .snapshots()
        .map(parsePosts);
  }

  /// 스냅샷 → 표시 가능한 게시물 목록(순수 함수).
  /// malformed 문서와 비활성 상태는 조용히 건너뛰고, 같은 id는 한 번만 담는다.
  static List<CommunityPost> parsePosts(
    QuerySnapshot<Map<String, dynamic>> snapshot,
  ) {
    final posts = <CommunityPost>[];
    final seen = <String>{};
    for (final doc in snapshot.docs) {
      final post = CommunityPost.fromMap(doc.id, doc.data());
      if (post == null || !post.isVisible) continue;
      if (!seen.add(post.id)) continue;
      posts.add(post);
    }
    return List<CommunityPost>.unmodifiable(posts);
  }
}
