import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:dating_app/models/community/community_author_snapshot.dart';
import 'package:dating_app/models/community/community_comment.dart';
import 'package:dating_app/models/community/community_enums.dart';
import 'package:dating_app/models/community/community_post.dart';
import 'package:dating_app/models/public_profile.dart';
import 'package:dating_app/models/user_profile.dart';
import 'package:flutter_test/flutter_test.dart';

/// Phase 4-1 — 커뮤니티 공통 모델 parser 테스트.
final _t = DateTime(2026, 7, 21, 12);

Map<String, dynamic> _authorMap({String uid = 'authorA'}) => {
  'uid': uid,
  'displayName': '작성자',
  'photoUrl': 'https://example.test/a.jpg',
  'photoVerified': true,
  'workVerified': false,
  'schoolVerified': true,
};

/// Phase 4-3: Feed 이미지 Storage 경로(테스트 기본 작성자 기준).
String _feedPath(String postId, {String authorUid = 'authorA', int index = 1}) {
  return 'communityFeed/$authorUid/$postId/image$index.jpg';
}

Map<String, dynamic> _postMap({
  String surface = 'lounge',
  String status = 'active',
  String visibility = 'authenticated',
  Object? authorUid = 'authorA',
  Map<String, dynamic>? author,
  Object? text = '오늘 날씨 좋네요',
  Object? imageUrls,
  Object? imagePaths,
  Object? reactionCount = 3,
  Object? commentCount = 1,
  Object? schemaVersion = 1,
  Object? createdAt,
}) {
  return {
    'surface': surface,
    'authorUid': authorUid,
    'authorSnapshot': author ?? _authorMap(),
    'text': text,
    'imageUrls': ?imageUrls,
    'imagePaths': ?imagePaths,
    'status': status,
    'visibility': visibility,
    'reactionCount': reactionCount,
    'commentCount': commentCount,
    'createdAt': createdAt ?? Timestamp.fromDate(_t),
    'updatedAt': Timestamp.fromDate(_t),
    'schemaVersion': schemaVersion,
  };
}

Map<String, dynamic> _commentMap({
  String postId = 'post1',
  String status = 'active',
  String authorUid = 'authorA',
  Map<String, dynamic>? author,
  Object? text = '좋은 글이에요',
  Object? schemaVersion = 1,
}) {
  return {
    'postId': postId,
    'authorUid': authorUid,
    'authorSnapshot': author ?? _authorMap(),
    'text': text,
    'status': status,
    'createdAt': Timestamp.fromDate(_t),
    'updatedAt': Timestamp.fromDate(_t),
    'schemaVersion': schemaVersion,
  };
}

void main() {
  group('1~4. enum 변환', () {
    test('1~2. surface는 lounge/feed만 인정한다', () {
      expect(communityPostSurfaceFromString('lounge'), CommunityPostSurface.lounge);
      expect(communityPostSurfaceFromString('feed'), CommunityPostSurface.feed);
      for (final unknown in ['party', 'square', 'LOUNGE', '', null, 1]) {
        expect(communityPostSurfaceFromString(unknown), isNull, reason: '$unknown');
      }
      expect(
        communityPostSurfaceToString(CommunityPostSurface.feed),
        'feed',
      );
    });

    test('3~4. status는 세 값만 인정하고 unknown을 active로 보지 않는다', () {
      expect(
        communityContentStatusFromString('active'),
        CommunityContentStatus.active,
      );
      expect(
        communityContentStatusFromString('hidden'),
        CommunityContentStatus.hidden,
      );
      expect(
        communityContentStatusFromString('removed'),
        CommunityContentStatus.removed,
      );
      for (final unknown in ['deleted', 'ACTIVE', '', null, true]) {
        expect(
          communityContentStatusFromString(unknown),
          isNull,
          reason: '$unknown',
        );
      }
    });

    test('visibility는 authenticated만 지원한다', () {
      expect(
        communityVisibilityFromString('authenticated'),
        CommunityVisibility.authenticated,
      );
      for (final unknown in ['public', 'matches', 'friends', null]) {
        expect(communityVisibilityFromString(unknown), isNull);
      }
    });
  });

  group('5~10. 작성자 snapshot', () {
    test('5~8. 공개 프로필에서 만든다', () {
      final profile = PublicProfile(
        uid: 'authorA',
        displayName: '  민지  ',
        age: 27,
        gender: 'female',
        photoUrls: const [
          'https://example.test/main.jpg',
          'https://example.test/second.jpg',
        ],
        verifications: const VerificationStatus(
          email: true,
          phone: true,
          photo: true,
          work: false,
          school: true,
        ),
      );

      final snapshot = CommunityAuthorSnapshot.fromPublicProfile(profile);

      expect(snapshot.uid, 'authorA');
      expect(snapshot.displayName, '민지');
      // 6. 대표 사진은 첫 항목
      expect(snapshot.photoUrl, 'https://example.test/main.jpg');
      // 8. photo/work/school만 복사한다
      expect(snapshot.photoVerified, isTrue);
      expect(snapshot.workVerified, isFalse);
      expect(snapshot.schoolVerified, isTrue);
      expect(snapshot.hasAnyBadge, isTrue);
    });

    test('7. 사진이 없으면 빈 문자열', () {
      final profile = PublicProfile(uid: 'authorA', displayName: '이름');
      expect(CommunityAuthorSnapshot.fromPublicProfile(profile).photoUrl, '');
    });

    test('displayName은 40자로 자른다', () {
      final profile = PublicProfile(uid: 'a', displayName: '가' * 50);
      expect(
        CommunityAuthorSnapshot.fromPublicProfile(profile).displayName.length,
        40,
      );
    });

    test('9. 비공개 필드는 map에 담기지 않는다', () {
      final profile = PublicProfile(
        uid: 'authorA',
        displayName: '민지',
        age: 27,
        gender: 'female',
        verifications: const VerificationStatus(email: true, phone: true),
      );
      final map = CommunityAuthorSnapshot.fromPublicProfile(profile).toMap();

      expect(map.keys.toSet(), {
        'uid',
        'displayName',
        'photoUrl',
        'photoVerified',
        'workVerified',
        'schoolVerified',
      });
      for (final forbidden in [
        'birthDate',
        'age',
        'gender',
        'location',
        'coarseLocation',
        'phone',
        'email',
        'jelly',
        'fcmTokens',
        'contactHash',
        'jobTitle',
        'education',
        'verifications',
      ]) {
        expect(map.containsKey(forbidden), isFalse, reason: forbidden);
      }
      // 이메일·전화 인증 여부는 커뮤니티 배지에 쓰지 않는다.
      expect(map.values.contains(true), isFalse);
    });

    test('10. malformed author map은 null로 처리한다', () {
      expect(CommunityAuthorSnapshot.fromMap(null), isNull);
      expect(CommunityAuthorSnapshot.fromMap({}), isNull);
      expect(
        CommunityAuthorSnapshot.fromMap({..._authorMap(), 'uid': 42}),
        isNull,
      );
      expect(
        CommunityAuthorSnapshot.fromMap({..._authorMap(), 'displayName': '  '}),
        isNull,
      );
      expect(
        CommunityAuthorSnapshot.fromMap({
          ..._authorMap(),
          'displayName': '가' * 41,
        }),
        isNull,
      );
      // photoUrl 타입 오류는 빈 문자열로 폴백, unknown field는 무시
      final parsed = CommunityAuthorSnapshot.fromMap({
        ..._authorMap(),
        'photoUrl': 99,
        'secret': 'x',
        'photoVerified': 'yes',
      });
      expect(parsed!.photoUrl, '');
      expect(parsed.photoVerified, isFalse);
    });
  });

  group('CommunityPost', () {
    test('1~2. lounge/feed 게시물을 파싱한다', () {
      final lounge = CommunityPost.fromMap('post1', _postMap());
      expect(lounge, isNotNull);
      expect(lounge!.surface, CommunityPostSurface.lounge);
      expect(lounge.id, 'post1');
      expect(lounge.author.uid, 'authorA');
      expect(lounge.text, '오늘 날씨 좋네요');
      expect(lounge.reactionCount, 3);
      expect(lounge.commentCount, 1);
      expect(lounge.createdAt, _t);
      expect(lounge.isVisible, isTrue);

      expect(lounge.imagePaths, isEmpty);
      expect(lounge.hasImages, isFalse);

      // Feed 게시물은 imagePaths가 1~4개 있어야 한다(Phase 4-3).
      final feed = CommunityPost.fromMap(
        'post2',
        _postMap(surface: 'feed', imagePaths: [_feedPath('post2')]),
      );
      expect(feed!.surface, CommunityPostSurface.feed);
      expect(feed.imagePaths, [_feedPath('post2')]);
      expect(feed.hasImages, isTrue);
    });

    test('3~5. 필수 필드가 어긋나면 거부한다', () {
      // 3. authorUid malformed
      expect(CommunityPost.fromMap('p', _postMap(authorUid: '')), isNull);
      expect(CommunityPost.fromMap('p', _postMap(authorUid: 42)), isNull);
      // 4. authorUid와 snapshot uid 불일치
      expect(
        CommunityPost.fromMap(
          'p',
          _postMap(authorUid: 'authorA', author: _authorMap(uid: 'other')),
        ),
        isNull,
      );
      // 5. unknown visibility/surface/status
      expect(
        CommunityPost.fromMap('p', _postMap(visibility: 'public')),
        isNull,
      );
      expect(CommunityPost.fromMap('p', _postMap(surface: 'party')), isNull);
      expect(CommunityPost.fromMap('p', _postMap(status: 'deleted')), isNull);
      // 문서 id가 없으면 거부
      expect(CommunityPost.fromMap('', _postMap()), isNull);
      expect(CommunityPost.fromMap('p', null), isNull);
    });

    test('6. 음수·비정수 count를 거부한다', () {
      expect(CommunityPost.fromMap('p', _postMap(reactionCount: -1)), isNull);
      expect(CommunityPost.fromMap('p', _postMap(commentCount: -5)), isNull);
      expect(CommunityPost.fromMap('p', _postMap(reactionCount: '3')), isNull);
      expect(CommunityPost.fromMap('p', _postMap(commentCount: 1.5)), isNull);
    });

    test('7. malformed Timestamp는 null로 두되 문서는 유지한다', () {
      final parsed = CommunityPost.fromMap(
        'p',
        _postMap(createdAt: 'not-a-timestamp'),
      );
      expect(parsed, isNotNull);
      expect(parsed!.createdAt, isNull);
    });

    test('8. imageUrls는 비어 있어야 하고 타입 제약을 지킨다', () {
      // 없으면 빈 목록
      final parsed = CommunityPost.fromMap('p', _postMap())!;
      expect(parsed.imageUrls, isEmpty);
      expect(() => parsed.imageUrls.add('x'), throwsUnsupportedError);

      // Phase 4-3: download URL은 저장하지 않는 계약이라 값이 있으면 거부한다.
      expect(
        CommunityPost.fromMap(
          'p',
          _postMap(imageUrls: ['https://example.test/1.jpg']),
        ),
        isNull,
      );
      // 4개 초과 / 타입 오류 / 너무 긴 URL은 그대로 거부
      expect(
        CommunityPost.fromMap('p', _postMap(imageUrls: List.filled(5, 'a'))),
        isNull,
      );
      expect(CommunityPost.fromMap('p', _postMap(imageUrls: 'a')), isNull);
      expect(CommunityPost.fromMap('p', _postMap(imageUrls: [1])), isNull);
      expect(
        CommunityPost.fromMap('p', _postMap(imageUrls: ['a' * 2049])),
        isNull,
      );
    });

    // ── Phase 4-3: Feed 이미지 계약 ──────────────────────────────────────
    test('Feed 1~3. Lounge는 imagePaths가 없거나 비어야 하고 있으면 거부한다', () {
      // 1. 기존 문서(필드 자체가 없음) 호환
      expect(CommunityPost.fromMap('p', _postMap())!.imagePaths, isEmpty);
      // 2. 빈 목록 허용
      expect(
        CommunityPost.fromMap('p', _postMap(imagePaths: <String>[]))!.imagePaths,
        isEmpty,
      );
      // 3. 이미지가 붙은 Lounge 문서는 거부
      expect(
        CommunityPost.fromMap('p', _postMap(imagePaths: [_feedPath('p')])),
        isNull,
      );
    });

    test('Feed 4~8. Feed는 imagePaths가 1~4개여야 한다', () {
      // 4~6. 1개·4개 정상
      final one = CommunityPost.fromMap(
        'p',
        _postMap(surface: 'feed', imagePaths: [_feedPath('p')]),
      );
      expect(one!.imagePaths.length, 1);

      final four = CommunityPost.fromMap(
        'p',
        _postMap(
          surface: 'feed',
          imagePaths: [
            for (var i = 1; i <= 4; i++) _feedPath('p', index: i),
          ],
        ),
      );
      expect(four!.imagePaths.length, 4);

      // 7. 0개 거부 (필드 없음 / 빈 목록 모두)
      expect(CommunityPost.fromMap('p', _postMap(surface: 'feed')), isNull);
      expect(
        CommunityPost.fromMap(
          'p',
          _postMap(surface: 'feed', imagePaths: <String>[]),
        ),
        isNull,
      );
      // 8. 5개 거부
      expect(
        CommunityPost.fromMap(
          'p',
          _postMap(
            surface: 'feed',
            imagePaths: [
              for (var i = 1; i <= 5; i++) _feedPath('p', index: i),
            ],
          ),
        ),
        isNull,
      );
    });

    test('Feed 9. imageUrls가 비어 있지 않은 Feed는 거부한다', () {
      expect(
        CommunityPost.fromMap(
          'p',
          _postMap(
            surface: 'feed',
            imagePaths: [_feedPath('p')],
            imageUrls: ['https://example.test/a.jpg'],
          ),
        ),
        isNull,
      );
    });

    test('Feed 10. 작성자·postId가 경로와 어긋나면 거부한다', () {
      // 다른 사용자 경로
      expect(
        CommunityPost.fromMap(
          'p',
          _postMap(
            surface: 'feed',
            imagePaths: [_feedPath('p', authorUid: 'someoneElse')],
          ),
        ),
        isNull,
      );
      // 다른 게시물 경로
      expect(
        CommunityPost.fromMap(
          'p',
          _postMap(surface: 'feed', imagePaths: [_feedPath('otherPost')]),
        ),
        isNull,
      );
      // prefix 밖 경로 / 하위 디렉터리 / 허용되지 않은 확장자
      expect(
        CommunityPost.fromMap(
          'p',
          _postMap(surface: 'feed', imagePaths: ['users/authorA/p/a.jpg']),
        ),
        isNull,
      );
      expect(
        CommunityPost.fromMap(
          'p',
          _postMap(
            surface: 'feed',
            imagePaths: ['communityFeed/authorA/p/nested/a.jpg'],
          ),
        ),
        isNull,
      );
      expect(
        CommunityPost.fromMap(
          'p',
          _postMap(
            surface: 'feed',
            imagePaths: ['communityFeed/authorA/p/a.heic'],
          ),
        ),
        isNull,
      );
    });

    test('Feed 11~12. 중복 경로는 거부하고 목록은 불변이다', () {
      // 11. 중복 경로
      expect(
        CommunityPost.fromMap(
          'p',
          _postMap(
            surface: 'feed',
            imagePaths: [_feedPath('p'), _feedPath('p')],
          ),
        ),
        isNull,
      );
      // 타입 오류·길이 초과도 거부
      expect(
        CommunityPost.fromMap('p', _postMap(surface: 'feed', imagePaths: [1])),
        isNull,
      );
      expect(
        CommunityPost.fromMap('p', _postMap(surface: 'feed', imagePaths: 'a')),
        isNull,
      );
      expect(
        CommunityPost.fromMap(
          'p',
          _postMap(
            surface: 'feed',
            imagePaths: ['communityFeed/authorA/p/${'a' * 520}.jpg'],
          ),
        ),
        isNull,
      );

      // 12. 불변 목록
      final parsed = CommunityPost.fromMap(
        'p',
        _postMap(surface: 'feed', imagePaths: [_feedPath('p')]),
      )!;
      expect(() => parsed.imagePaths.add('x'), throwsUnsupportedError);
    });

    test('9. hidden/removed는 표시 대상이 아니다', () {
      final hidden = CommunityPost.fromMap('p', _postMap(status: 'hidden'));
      expect(hidden!.isVisible, isFalse);
      final removed = CommunityPost.fromMap('p', _postMap(status: 'removed'));
      expect(removed!.isVisible, isFalse);
    });

    test('10~11. unknown field는 무시하고 비공개 값은 담지 않는다', () {
      final parsed = CommunityPost.fromMap('p', {
        ..._postMap(),
        'authorPhone': '010-1234-5678',
        'internalScore': 5,
      });
      expect(parsed, isNotNull);
      expect(parsed!.author.uid, 'authorA');
      expect(parsed.text, '오늘 날씨 좋네요');
    });

    test('text 길이 경계와 schemaVersion을 검증한다', () {
      expect(CommunityPost.fromMap('p', _postMap(text: '  ')), isNull);
      expect(CommunityPost.fromMap('p', _postMap(text: 'ㄱ' * 1001)), isNull);
      expect(
        CommunityPost.fromMap('p', _postMap(text: 'ㄱ' * 1000)),
        isNotNull,
      );
      expect(CommunityPost.fromMap('p', _postMap(schemaVersion: 2)), isNull);
      expect(CommunityPost.fromMap('p', _postMap(schemaVersion: null)), isNull);
    });
  });

  group('CommunityComment', () {
    test('1. 정상 댓글을 파싱한다', () {
      final parsed = CommunityComment.fromMap('c1', _commentMap());
      expect(parsed, isNotNull);
      expect(parsed!.id, 'c1');
      expect(parsed.postId, 'post1');
      expect(parsed.author.uid, 'authorA');
      expect(parsed.isVisible, isTrue);
    });

    test('2. text 길이 경계', () {
      expect(CommunityComment.fromMap('c', _commentMap(text: '')), isNull);
      expect(CommunityComment.fromMap('c', _commentMap(text: '  ')), isNull);
      expect(
        CommunityComment.fromMap('c', _commentMap(text: 'ㄱ' * 500)),
        isNotNull,
      );
      expect(
        CommunityComment.fromMap('c', _commentMap(text: 'ㄱ' * 501)),
        isNull,
      );
    });

    test('3. author 불일치·필수 필드 누락을 거부한다', () {
      expect(
        CommunityComment.fromMap(
          'c',
          _commentMap(authorUid: 'authorA', author: _authorMap(uid: 'x')),
        ),
        isNull,
      );
      expect(CommunityComment.fromMap('c', _commentMap(postId: '')), isNull);
      expect(
        CommunityComment.fromMap('c', _commentMap(schemaVersion: 2)),
        isNull,
      );
      expect(CommunityComment.fromMap('', _commentMap()), isNull);
    });

    test('4~5. malformed Timestamp와 비활성 상태', () {
      final parsed = CommunityComment.fromMap('c', {
        ..._commentMap(),
        'createdAt': 12345,
      });
      expect(parsed!.createdAt, isNull);

      final hidden = CommunityComment.fromMap(
        'c',
        _commentMap(status: 'hidden'),
      );
      expect(hidden!.isVisible, isFalse);
      expect(
        CommunityComment.fromMap('c', _commentMap(status: 'unknown')),
        isNull,
      );
    });
  });
}
