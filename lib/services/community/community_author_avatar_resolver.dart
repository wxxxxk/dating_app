import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../../core/constants/app_constants.dart';

/// 커뮤니티 작성자 대표 사진을 **현재 공개 프로필** 기준으로 최신화하는
/// 프로세스 단위 resolver.
///
/// 게시물 문서의 `authorSnapshot.photoUrl`은 작성 시점에 복사된 값이라,
/// 작성자가 프로필 사진을 바꿔도 예전 게시물에는 옛 사진이 남는다. 이
/// resolver는 `authorUid`로 `publicProfiles/{uid}`의 현재 대표 사진
/// (`photoUrls.first`)을 조회해 캐시하고, **같은 작성자의 여러 카드가 하나의
/// 조회를 공유**한다(카드마다 조회하지 않는다 → N+1 방지).
///
/// 계약:
/// - 비공개 `users/{uid}`는 절대 읽지 않는다(공개 프로필만).
/// - 게시물마다 Firestore listener를 만들지 않는다(one-shot get + 캐시).
/// - 조회 실패·사진 없음이면 `null`을 돌려주고, 화면이 snapshot photoUrl →
///   placeholder 순서로 안전하게 fallback한다.
/// - TTL이 지나면 다음 조회에서 최신값을 다시 가져와, 오래된 값을 영구
///   고정하지 않는다.
typedef AuthorPhotoLoader = Future<String?> Function(String uid);

class CommunityAuthorAvatarResolver {
  CommunityAuthorAvatarResolver._();

  /// 공용 위젯(CommunityAuthorHeader)이 서비스 주입 없이 쓰는 단일 인스턴스.
  static final CommunityAuthorAvatarResolver instance =
      CommunityAuthorAvatarResolver._();

  /// 같은 값을 잠깐 재사용하되 영구 고정하지 않는 캐시 수명.
  static const Duration cacheTtl = Duration(minutes: 3);

  final Map<String, _AvatarCacheEntry> _cache = {};

  /// 테스트에서 Firestore 없이 로더를 주입하기 위한 hook. null이면 기본
  /// (publicProfiles 조회) 로더를 쓴다.
  AuthorPhotoLoader? _loaderOverride;

  @visibleForTesting
  void debugSetLoader(AuthorPhotoLoader? loader) {
    _loaderOverride = loader;
    _cache.clear();
  }

  @visibleForTesting
  void debugClear() => _cache.clear();

  /// [uid]의 현재 대표 사진 URL을 돌려준다.
  ///
  /// 같은 uid의 진행 중 조회는 하나의 Future로 공유하고, TTL 안에서는 재조회
  /// 하지 않는다. 빈 uid는 조회 없이 null.
  Future<String?> resolvePhotoUrl(String uid) {
    if (uid.isEmpty) return Future<String?>.value(null);

    final now = DateTime.now();
    final existing = _cache[uid];
    if (existing != null && now.difference(existing.fetchedAt) < cacheTtl) {
      return existing.future;
    }

    final future = (_loaderOverride ?? _loadFromPublicProfile)(uid);
    _cache[uid] = _AvatarCacheEntry(future: future, fetchedAt: now);
    return future;
  }

  /// 기본 로더: `publicProfiles/{uid}`의 대표 사진만 읽는다.
  ///
  /// Firebase 미초기화(위젯 테스트)·조회 실패는 모두 조용히 null → 화면은
  /// snapshot/placeholder로 fallback한다. 실패도 캐시에 남겨 TTL 동안 재시도
  /// 폭주를 막고, TTL 이후 다시 조회한다.
  Future<String?> _loadFromPublicProfile(String uid) async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection(AppConstants.publicProfilesCollection)
          .doc(uid)
          .get();
      final data = doc.data();
      if (data == null) return null;
      final photoUrls = data['photoUrls'];
      if (photoUrls is List) {
        for (final item in photoUrls) {
          if (item is String && item.isNotEmpty) return item;
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}

class _AvatarCacheEntry {
  final Future<String?> future;
  final DateTime fetchedAt;

  const _AvatarCacheEntry({required this.future, required this.fetchedAt});
}
