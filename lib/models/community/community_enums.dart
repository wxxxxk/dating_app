/// 커뮤니티 공통 enum(Phase 4-1).
///
/// Lounge와 Feed가 공유한다. Party·Square·그룹 채팅은 데이터 모양이 달라
/// 여기에 미리 넣지 않는다(Phase 4-4/4-5에서 별도 정의).
library;

/// 게시물이 속한 커뮤니티 표면.
enum CommunityPostSurface { lounge, feed }

String communityPostSurfaceToString(CommunityPostSurface surface) =>
    surface.name;

/// 알 수 없는 값은 null. 임의의 표면으로 추측하지 않는다.
CommunityPostSurface? communityPostSurfaceFromString(Object? value) {
  switch (value) {
    case 'lounge':
      return CommunityPostSurface.lounge;
    case 'feed':
      return CommunityPostSurface.feed;
    default:
      return null;
  }
}

/// 게시물·댓글 노출 상태.
enum CommunityContentStatus { active, hidden, removed }

String communityContentStatusToString(CommunityContentStatus status) =>
    status.name;

/// **알 수 없는 값을 active로 오인하지 않는다.** 모르면 null을 돌려주고,
/// 호출부는 표시하지 않는 쪽(fail-closed)으로 처리한다.
CommunityContentStatus? communityContentStatusFromString(Object? value) {
  switch (value) {
    case 'active':
      return CommunityContentStatus.active;
    case 'hidden':
      return CommunityContentStatus.hidden;
    case 'removed':
      return CommunityContentStatus.removed;
    default:
      return null;
  }
}

/// 공개 범위. 현재는 로그인 사용자 공개만 지원한다.
/// 친구 전용·매치 전용 같은 미구현 값을 미리 만들지 않는다.
enum CommunityVisibility { authenticated }

String communityVisibilityToString(CommunityVisibility visibility) =>
    visibility.name;

CommunityVisibility? communityVisibilityFromString(Object? value) {
  if (value == 'authenticated') return CommunityVisibility.authenticated;
  return null;
}
