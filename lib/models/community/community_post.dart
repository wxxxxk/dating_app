import 'package:cloud_firestore/cloud_firestore.dart';

import 'community_author_snapshot.dart';
import 'community_enums.dart';

/// communityPosts/{postId} 문서 모델(Phase 4-1).
///
/// Lounge와 Feed가 같은 컬렉션을 [surface]로 구분해 공유한다.
/// 이번 단계는 **읽기 전용**이라 client write payload(toCreateMap)는 만들지
/// 않는다 — 작성 계약은 Phase 4-2에서 rules와 함께 연다.
class CommunityPost {
  static const int textMaxLength = 1000;
  static const int maxImageUrls = 4;
  static const int imageUrlMaxLength = 2048;
  static const int supportedSchemaVersion = 1;

  final String id;
  final CommunityPostSurface surface;
  final String authorUid;
  final CommunityAuthorSnapshot author;
  final String text;
  final List<String> imageUrls;
  final CommunityContentStatus status;
  final CommunityVisibility visibility;
  final int reactionCount;
  final int commentCount;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final int schemaVersion;

  CommunityPost({
    required this.id,
    required this.surface,
    required this.authorUid,
    required this.author,
    required this.text,
    required List<String> imageUrls,
    required this.status,
    required this.visibility,
    required this.reactionCount,
    required this.commentCount,
    required this.createdAt,
    required this.updatedAt,
    required this.schemaVersion,
  }) : imageUrls = List<String>.unmodifiable(imageUrls);

  /// 화면에 보여도 되는 상태인가. 알 수 없는 상태는 status 파싱 단계에서
  /// 이미 걸러지므로 여기서는 active만 통과시킨다.
  bool get isVisible => status == CommunityContentStatus.active;

  /// Firestore 문서 파싱. 필수 필드가 malformed면 null을 반환해 목록에서
  /// 조용히 건너뛰게 한다(부분적으로 깨진 카드를 그리지 않는다).
  static CommunityPost? fromMap(String id, Map<String, dynamic>? data) {
    if (id.isEmpty || data == null) return null;

    final surface = communityPostSurfaceFromString(data['surface']);
    if (surface == null) return null;

    final status = communityContentStatusFromString(data['status']);
    if (status == null) return null;

    final visibility = communityVisibilityFromString(data['visibility']);
    if (visibility == null) return null;

    final authorUid = data['authorUid'];
    if (authorUid is! String || authorUid.isEmpty) return null;

    final author = CommunityAuthorSnapshot.fromMap(
      data['authorSnapshot'] is Map
          ? Map<String, dynamic>.from(data['authorSnapshot'] as Map)
          : null,
    );
    // 작성자 정보가 없거나 본문 uid와 어긋나면 신뢰하지 않는다.
    if (author == null || author.uid != authorUid) return null;

    final rawText = data['text'];
    if (rawText is! String) return null;
    final text = rawText.trim();
    if (text.isEmpty || text.length > textMaxLength) return null;

    final imageUrls = _parseImageUrls(data['imageUrls']);
    if (imageUrls == null) return null;

    final reactionCount = _parseCount(data['reactionCount']);
    final commentCount = _parseCount(data['commentCount']);
    if (reactionCount == null || commentCount == null) return null;

    if (data['schemaVersion'] != supportedSchemaVersion) return null;

    final createdAt = data['createdAt'];
    final updatedAt = data['updatedAt'];

    return CommunityPost(
      id: id,
      surface: surface,
      authorUid: authorUid,
      author: author,
      text: text,
      imageUrls: imageUrls,
      status: status,
      visibility: visibility,
      reactionCount: reactionCount,
      commentCount: commentCount,
      // 서버 타임스탬프 확정 전(pending write)에는 null일 수 있다.
      createdAt: createdAt is Timestamp ? createdAt.toDate() : null,
      updatedAt: updatedAt is Timestamp ? updatedAt.toDate() : null,
      schemaVersion: supportedSchemaVersion,
    );
  }

  static CommunityPost? fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    return fromMap(doc.id, doc.data());
  }

  /// 없으면 빈 목록, 타입/개수/길이가 어긋나면 null(=문서 거부).
  static List<String>? _parseImageUrls(Object? value) {
    if (value == null) return const [];
    if (value is! List) return null;
    if (value.length > maxImageUrls) return null;
    final urls = <String>[];
    for (final item in value) {
      if (item is! String) return null;
      if (item.isEmpty || item.length > imageUrlMaxLength) return null;
      urls.add(item);
    }
    return urls;
  }

  /// 음수·비정수 카운트는 신뢰하지 않는다.
  static int? _parseCount(Object? value) {
    if (value is! int) return null;
    if (value < 0) return null;
    return value;
  }
}
