import 'package:cloud_firestore/cloud_firestore.dart';

import 'community_author_snapshot.dart';
import 'community_enums.dart';

/// communityPosts/{postId}/comments/{commentId} 문서 모델(Phase 4-1).
///
/// 이번 단계는 **모델과 parser만** 둔다. 조회·작성 경로는 열지 않았고
/// firestore.rules도 이 서브컬렉션 접근을 전면 차단한다(Phase 4-2에서 개방).
class CommunityComment {
  static const int textMaxLength = 500;
  static const int supportedSchemaVersion = 1;

  final String id;
  final String postId;
  final String authorUid;
  final CommunityAuthorSnapshot author;
  final String text;
  final CommunityContentStatus status;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final int schemaVersion;

  const CommunityComment({
    required this.id,
    required this.postId,
    required this.authorUid,
    required this.author,
    required this.text,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    required this.schemaVersion,
  });

  bool get isVisible => status == CommunityContentStatus.active;

  /// 필수 필드가 malformed면 null을 반환한다(부분 렌더링 방지).
  static CommunityComment? fromMap(String id, Map<String, dynamic>? data) {
    if (id.isEmpty || data == null) return null;

    final postId = data['postId'];
    if (postId is! String || postId.isEmpty) return null;

    final status = communityContentStatusFromString(data['status']);
    if (status == null) return null;

    final authorUid = data['authorUid'];
    if (authorUid is! String || authorUid.isEmpty) return null;

    final author = CommunityAuthorSnapshot.fromMap(
      data['authorSnapshot'] is Map
          ? Map<String, dynamic>.from(data['authorSnapshot'] as Map)
          : null,
    );
    if (author == null || author.uid != authorUid) return null;

    final rawText = data['text'];
    if (rawText is! String) return null;
    final text = rawText.trim();
    if (text.isEmpty || text.length > textMaxLength) return null;

    if (data['schemaVersion'] != supportedSchemaVersion) return null;

    final createdAt = data['createdAt'];
    final updatedAt = data['updatedAt'];

    return CommunityComment(
      id: id,
      postId: postId,
      authorUid: authorUid,
      author: author,
      text: text,
      status: status,
      createdAt: createdAt is Timestamp ? createdAt.toDate() : null,
      updatedAt: updatedAt is Timestamp ? updatedAt.toDate() : null,
      schemaVersion: supportedSchemaVersion,
    );
  }

  static CommunityComment? fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    return fromMap(doc.id, doc.data());
  }
}
