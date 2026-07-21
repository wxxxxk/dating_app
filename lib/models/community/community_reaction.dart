/// toggleCommunityReaction callable 응답(Phase 4-2).
///
/// 서버는 공감 여부와 보정된 카운트만 돌려준다 — 누가 공감했는지(UID 목록)는
/// 어떤 경로로도 클라이언트에 내려오지 않는다.
class CommunityReactionResult {
  final bool reacted;
  final int reactionCount;

  const CommunityReactionResult({
    required this.reacted,
    required this.reactionCount,
  });

  /// 형태가 어긋난 응답은 null. 호출부는 서버 값 대신 기존 stream 값을 쓴다.
  static CommunityReactionResult? fromMap(Map<Object?, Object?>? data) {
    if (data == null) return null;
    final reacted = data['reacted'];
    final count = data['reactionCount'];
    if (reacted is! bool) return null;
    if (count is! int || count < 0) return null;
    return CommunityReactionResult(reacted: reacted, reactionCount: count);
  }
}
