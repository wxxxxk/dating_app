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

  /// Feed 이미지 개수 제약(Phase 4-3).
  static const int minFeedImages = 1;
  static const int maxFeedImages = 4;
  static const int imagePathMaxLength = 512;

  /// Feed 이미지 Storage root. storage.rules의 match 경로와 1:1 대응한다.
  static const String feedStorageRoot = 'communityFeed';

  /// Feed 이미지에서 허용하는 확장자. HEIC/HEIF는 decode 호환성 때문에 제외.
  static const Set<String> allowedFeedImageExtensions = {'jpg', 'jpeg', 'png'};

  final String id;
  final CommunityPostSurface surface;
  final String authorUid;
  final CommunityAuthorSnapshot author;
  final String text;
  final List<String> imageUrls;

  /// Feed 이미지의 **내부 Storage 경로**(Phase 4-3).
  ///
  /// download URL·token은 저장하지 않는다 — 앱 밖으로 새어나가면 게시물을
  /// 지워도 이미지가 계속 열리기 때문이다. 표시할 때만 인증된 사용자가
  /// bytes를 읽는다. Lounge 게시물에서는 항상 비어 있다.
  final List<String> imagePaths;

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
    List<String> imagePaths = const [],
    required this.status,
    required this.visibility,
    required this.reactionCount,
    required this.commentCount,
    required this.createdAt,
    required this.updatedAt,
    required this.schemaVersion,
  }) : imageUrls = List<String>.unmodifiable(imageUrls),
       imagePaths = List<String>.unmodifiable(imagePaths);

  /// 이 게시물이 이미지를 가지고 있는가.
  bool get hasImages => imagePaths.isNotEmpty;

  /// Feed 이미지 경로 prefix(순수 함수). storage.rules·서버 검증과 같은 규칙.
  static String feedImagePathPrefix({
    required String authorUid,
    required String postId,
  }) {
    return '$feedStorageRoot/$authorUid/$postId/';
  }

  /// 경로가 이 작성자·게시물의 Feed 이미지 경로 형식인가(순수 함수).
  ///
  /// prefix 아래에 있고, 하위 디렉터리 없이 파일 하나이며, 허용 확장자여야
  /// 한다. 서버(createFeedPost)와 동일한 규칙을 클라이언트에서도 검사한다.
  static bool isValidFeedImagePath({
    required String path,
    required String authorUid,
    required String postId,
  }) {
    if (path.isEmpty || path.length > imagePathMaxLength) return false;
    final prefix = feedImagePathPrefix(authorUid: authorUid, postId: postId);
    if (!path.startsWith(prefix)) return false;

    final fileName = path.substring(prefix.length);
    if (fileName.isEmpty || fileName.contains('/')) return false;

    final dot = fileName.lastIndexOf('.');
    if (dot <= 0 || dot == fileName.length - 1) return false;
    final extension = fileName.substring(dot + 1).toLowerCase();
    return allowedFeedImageExtensions.contains(extension);
  }

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

    final imagePaths = _parseImagePaths(data['imagePaths']);
    if (imagePaths == null) return null;

    // surface별 이미지 계약. 여기서 어긋나면 문서를 통째로 건너뛴다.
    if (!_imagesValidForSurface(
      surface: surface,
      authorUid: authorUid,
      postId: id,
      imageUrls: imageUrls,
      imagePaths: imagePaths,
    )) {
      return null;
    }

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
      imagePaths: imagePaths,
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

  /// 없으면 빈 목록, 타입/개수/길이/중복이 어긋나면 null(=문서 거부).
  ///
  /// 경로 자체가 작성자·게시물과 맞는지는 [_imagesValidForSurface]에서 본다
  /// (여기서는 id를 모르는 호출도 안전하게 통과시킨다).
  static List<String>? _parseImagePaths(Object? value) {
    if (value == null) return const [];
    if (value is! List) return null;
    if (value.length > maxFeedImages) return null;
    final paths = <String>[];
    for (final item in value) {
      if (item is! String) return null;
      if (item.isEmpty || item.length > imagePathMaxLength) return null;
      // 같은 파일을 두 번 넣어 개수 제한을 우회하지 못하게 한다.
      if (paths.contains(item)) return null;
      paths.add(item);
    }
    return paths;
  }

  /// surface별 이미지 계약(순수 함수).
  ///
  /// - lounge: 이미지가 하나도 없어야 한다(텍스트 전용).
  /// - feed: imageUrls는 비어 있고, imagePaths가 1~4개이며 모두 이 작성자·
  ///   게시물 경로 아래여야 한다.
  static bool _imagesValidForSurface({
    required CommunityPostSurface surface,
    required String authorUid,
    required String postId,
    required List<String> imageUrls,
    required List<String> imagePaths,
  }) {
    if (imageUrls.isNotEmpty) return false;

    switch (surface) {
      case CommunityPostSurface.lounge:
        return imagePaths.isEmpty;
      case CommunityPostSurface.feed:
        if (imagePaths.length < minFeedImages) return false;
        if (imagePaths.length > maxFeedImages) return false;
        return imagePaths.every(
          (path) => isValidFeedImagePath(
            path: path,
            authorUid: authorUid,
            postId: postId,
          ),
        );
    }
  }

  /// 음수·비정수 카운트는 신뢰하지 않는다.
  static int? _parseCount(Object? value) {
    if (value is! int) return null;
    if (value < 0) return null;
    return value;
  }
}
