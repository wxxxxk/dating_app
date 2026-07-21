import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../../core/constants/app_constants.dart';
import '../../models/community/community_comment.dart';
import '../../models/community/community_enums.dart';
import '../../models/community/community_post.dart';
import '../../models/community/community_reaction.dart';

/// 커뮤니티 작업 실패. 사용자에게는 [message]만 노출하고 raw Firebase 오류·
/// 본문·UID는 감춘다.
class CommunityActionError implements Exception {
  final String message;

  /// 금지 내용(전화번호·인증번호·송금 요청) 때문에 거부됐는지.
  final bool forbiddenText;

  const CommunityActionError(this.message, {this.forbiddenText = false});

  @override
  String toString() => 'CommunityActionError: $message';
}

/// 커뮤니티(라운지) 서비스 — Phase 4-2.
///
/// 읽기는 Firestore 구독, **쓰기는 전부 Cloud Functions callable**이다.
/// 클라이언트는 작성자 snapshot·status·카운트·timestamp를 만들지 않는다.
///
/// 작성자 정보는 콘텐츠에 저장된 authorSnapshot만 사용한다 — 게시물마다
/// publicProfiles를 다시 읽는 N+1 조회를 하지 않는다.
class CommunityService {
  CommunityService({FirebaseFirestore? firestore, FirebaseFunctions? functions})
    : _db = firestore ?? FirebaseFirestore.instance,
      _functions =
          functions ??
          FirebaseFunctions.instanceFor(region: AppConstants.functionsRegion);

  final FirebaseFirestore _db;
  final FirebaseFunctions _functions;

  static const String collectionPath = 'communityPosts';
  static const String commentsSubcollection = 'comments';
  static const String reactionsSubcollection = 'reactions';

  static const int minLimit = 1;
  static const int maxLimit = 50;
  static const int defaultLimit = 30;
  static const int defaultCommentLimit = 100;

  static const String createPostCallable = 'createLoungePost';
  static const String createCommentCallable = 'createCommunityComment';
  static const String toggleReactionCallable = 'toggleCommunityReaction';
  static const String deletePostCallable = 'deleteCommunityPost';
  static const String deleteCommentCallable = 'deleteCommunityComment';
  static const String reportCallable = 'reportCommunityContent';

  /// 서버가 금지 내용으로 거부했을 때 details에 담아 보내는 고정 code.
  static const String forbiddenTextErrorCode = 'community/forbidden_text';

  static const String genericErrorMessage = '잠시 후 다시 시도해주세요.';
  static const String forbiddenTextMessage =
      '개인정보·인증번호·송금 요청이 포함된 글은 올릴 수 없어요.';

  DocumentReference<Map<String, dynamic>> _postRef(String postId) =>
      _db.collection(collectionPath).doc(postId);

  // ── 읽기 ────────────────────────────────────────────────────────────────

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

  /// 게시물 한 건을 실시간 구독한다. 삭제·숨김되면 null을 흘려 상세 화면이
  /// "볼 수 없는 글" 상태로 바뀔 수 있게 한다.
  Stream<CommunityPost?> watchPost(String postId) {
    if (postId.isEmpty) return Stream.value(null);
    return _postRef(postId).snapshots().map((snap) {
      if (!snap.exists) return null;
      final post = CommunityPost.fromMap(snap.id, snap.data());
      if (post == null || !post.isVisible) return null;
      return post;
    });
  }

  /// 댓글을 오래된 순으로 구독한다. 쿼리 조건은 rules와 동일하게 active만.
  Stream<List<CommunityComment>> watchComments({
    required String postId,
    int limit = defaultCommentLimit,
  }) {
    if (postId.isEmpty) return Stream.value(const <CommunityComment>[]);
    return _postRef(postId)
        .collection(commentsSubcollection)
        .where(
          'status',
          isEqualTo: communityContentStatusToString(
            CommunityContentStatus.active,
          ),
        )
        .orderBy('createdAt')
        .limit(limit)
        .snapshots()
        .map(parseComments);
  }

  /// 본인 공감 여부만 구독한다. 다른 사용자의 reaction 문서는 rules가 막는다.
  Stream<bool> watchMyReaction({required String postId, required String uid}) {
    if (postId.isEmpty || uid.isEmpty) return Stream.value(false);
    return _postRef(postId)
        .collection(reactionsSubcollection)
        .doc(uid)
        .snapshots()
        .map((snap) => snap.exists);
  }

  // ── 쓰기(전부 서버 callable) ─────────────────────────────────────────────

  /// 라운지 게시물을 작성하고 새 postId를 돌려준다.
  Future<String> createLoungePost({required String text}) async {
    final data = await _call(createPostCallable, {'text': text});
    final postId = data['postId'];
    if (postId is! String || postId.isEmpty) {
      throw const CommunityActionError(genericErrorMessage);
    }
    return postId;
  }

  Future<String> createComment({
    required String postId,
    required String text,
  }) async {
    final data = await _call(createCommentCallable, {
      'postId': postId,
      'text': text,
    });
    final commentId = data['commentId'];
    if (commentId is! String || commentId.isEmpty) {
      throw const CommunityActionError(genericErrorMessage);
    }
    return commentId;
  }

  /// 공감 추가/취소. 서버가 보정한 카운트를 함께 돌려준다.
  Future<CommunityReactionResult> toggleReaction({
    required String postId,
  }) async {
    final data = await _call(toggleReactionCallable, {'postId': postId});
    final result = CommunityReactionResult.fromMap(data);
    if (result == null) throw const CommunityActionError(genericErrorMessage);
    return result;
  }

  Future<void> deletePost({required String postId}) async {
    await _call(deletePostCallable, {'postId': postId});
  }

  Future<void> deleteComment({
    required String postId,
    required String commentId,
  }) async {
    await _call(deleteCommentCallable, {
      'postId': postId,
      'commentId': commentId,
    });
  }

  Future<void> reportContent({
    required String targetType,
    required String postId,
    String commentId = '',
    required String reason,
    String? detail,
  }) async {
    final trimmedDetail = detail?.trim() ?? '';
    await _call(reportCallable, {
      'targetType': targetType,
      'postId': postId,
      'commentId': commentId,
      'reason': reason,
      if (trimmedDetail.isNotEmpty) 'detail': trimmedDetail,
    });
  }

  /// callable 호출 공통 처리. raw Firebase 오류는 밖으로 내보내지 않고,
  /// 입력 text/uid도 로그로 남기지 않는다.
  Future<Map<Object?, Object?>> _call(
    String name,
    Map<String, dynamic> payload,
  ) async {
    try {
      final result = await _functions.httpsCallable(name).call(payload);
      final data = result.data;
      if (data is Map) return data;
      // 알 수 없는 응답 형태는 성공으로 취급하지 않는다.
      throw const CommunityActionError(genericErrorMessage);
    } on CommunityActionError {
      rethrow;
    } on FirebaseFunctionsException catch (e) {
      throw mapFunctionsException(e);
    } catch (_) {
      throw const CommunityActionError(genericErrorMessage);
    }
  }

  /// 서버 code → 고정 안내 문구. 서버 message를 그대로 노출하지 않는다.
  static CommunityActionError mapFunctionsException(
    FirebaseFunctionsException e,
  ) {
    final details = e.details;
    if (details is Map && details['code'] == forbiddenTextErrorCode) {
      return const CommunityActionError(
        forbiddenTextMessage,
        forbiddenText: true,
      );
    }
    switch (e.code) {
      case 'unauthenticated':
        return const CommunityActionError('로그인이 필요해요.');
      case 'permission-denied':
        return const CommunityActionError('권한이 없어요.');
      case 'not-found':
        return const CommunityActionError('이미 삭제됐거나 볼 수 없는 글이에요.');
      case 'resource-exhausted':
        return const CommunityActionError(genericErrorMessage);
      case 'failed-precondition':
        return const CommunityActionError('프로필을 먼저 완성한 뒤 이용할 수 있어요.');
      case 'invalid-argument':
        return const CommunityActionError('입력한 내용을 다시 확인해주세요.');
      default:
        return const CommunityActionError(genericErrorMessage);
    }
  }

  // ── 파싱(순수 함수) ──────────────────────────────────────────────────────

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

  /// 스냅샷 → 표시 가능한 댓글 목록(순수 함수).
  static List<CommunityComment> parseComments(
    QuerySnapshot<Map<String, dynamic>> snapshot,
  ) {
    final comments = <CommunityComment>[];
    final seen = <String>{};
    for (final doc in snapshot.docs) {
      final comment = CommunityComment.fromMap(doc.id, doc.data());
      if (comment == null || !comment.isVisible) continue;
      if (!seen.add(comment.id)) continue;
      comments.add(comment);
    }
    return List<CommunityComment>.unmodifiable(comments);
  }
}
