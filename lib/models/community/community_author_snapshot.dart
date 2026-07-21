import '../public_profile.dart';

/// 커뮤니티 콘텐츠에 함께 저장되는 **공개** 작성자 정보(Phase 4-1).
///
/// 게시물마다 publicProfiles를 다시 조회(N+1)하지 않도록 작성 시점의 공개
/// 정보를 복사해 둔다. 비공개 문서(users/{uid})의 값은 절대 담지 않는다 —
/// 생년월일·정확한 위치·전화번호·이메일·젤리·FCM 토큰·연락처 해시·인증 증빙
/// 경로·기관명·매칭/신고 정보는 모두 제외 대상이다.
class CommunityAuthorSnapshot {
  static const int displayNameMaxLength = 40;
  static const int photoUrlMaxLength = 2048;

  final String uid;
  final String displayName;
  final String photoUrl;

  /// 공개 프로필의 server-managed 인증 상태. 커뮤니티 배지는 이 셋만 쓴다
  /// (email/phone 인증 여부는 커뮤니티에 노출하지 않는다).
  final bool photoVerified;
  final bool workVerified;
  final bool schoolVerified;

  const CommunityAuthorSnapshot({
    required this.uid,
    required this.displayName,
    required this.photoUrl,
    required this.photoVerified,
    required this.workVerified,
    required this.schoolVerified,
  });

  bool get hasAnyBadge => photoVerified || workVerified || schoolVerified;

  /// 공개 프로필에서 스냅샷을 만든다.
  factory CommunityAuthorSnapshot.fromPublicProfile(PublicProfile profile) {
    final name = profile.displayName.trim();
    final photoUrls = profile.photoUrls;
    return CommunityAuthorSnapshot(
      uid: profile.uid,
      displayName: name.length > displayNameMaxLength
          ? name.substring(0, displayNameMaxLength)
          : name,
      photoUrl: photoUrls.isNotEmpty ? photoUrls.first : '',
      photoVerified: profile.verifications.photo,
      workVerified: profile.verifications.work,
      schoolVerified: profile.verifications.school,
    );
  }

  /// Firestore map 파싱. uid/displayName이 유효하지 않으면 null을 반환해
  /// 호출부가 해당 콘텐츠를 통째로 건너뛰게 한다. unknown field는 무시한다.
  static CommunityAuthorSnapshot? fromMap(Map<String, dynamic>? data) {
    if (data == null) return null;

    final uid = data['uid'];
    if (uid is! String || uid.isEmpty) return null;

    final rawName = data['displayName'];
    if (rawName is! String) return null;
    final displayName = rawName.trim();
    if (displayName.isEmpty || displayName.length > displayNameMaxLength) {
      return null;
    }

    final rawPhoto = data['photoUrl'];
    final photoUrl = rawPhoto is String && rawPhoto.length <= photoUrlMaxLength
        ? rawPhoto
        : '';

    return CommunityAuthorSnapshot(
      uid: uid,
      displayName: displayName,
      photoUrl: photoUrl,
      photoVerified: data['photoVerified'] == true,
      workVerified: data['workVerified'] == true,
      schoolVerified: data['schoolVerified'] == true,
    );
  }

  /// 저장/전송용 map. 허용된 6개 key만 방출한다.
  Map<String, dynamic> toMap() {
    return {
      'uid': uid,
      'displayName': displayName,
      'photoUrl': photoUrl,
      'photoVerified': photoVerified,
      'workVerified': workVerified,
      'schoolVerified': schoolVerified,
    };
  }
}
