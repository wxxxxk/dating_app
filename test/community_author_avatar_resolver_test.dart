import 'package:dating_app/features/community/lounge/lounge_widgets.dart';
import 'package:dating_app/models/community/community_author_snapshot.dart';
import 'package:dating_app/services/community/community_author_avatar_resolver.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// R0-A 회귀 방지: 커뮤니티 작성자 아바타가 현재 공개 프로필 사진으로
/// 최신화되고, 조회 실패 시 snapshot → placeholder로 fallback하며, 같은
/// 작성자를 카드마다 중복 조회하지 않는지 검증한다.
///
/// Firestore 없이 resolver 로더를 주입해 테스트한다(실제 UID/URL 미노출).

CommunityAuthorSnapshot _snapshot({required String uid, String photoUrl = ''}) {
  return CommunityAuthorSnapshot(
    uid: uid,
    displayName: '작성자',
    photoUrl: photoUrl,
    photoVerified: false,
    workVerified: false,
    schoolVerified: false,
  );
}

Widget _hostHeader(CommunityAuthorSnapshot author) {
  return MaterialApp(
    home: Scaffold(
      body: CommunityAuthorHeader(
        author: author,
        createdAt: DateTime(2026, 1, 1),
      ),
    ),
  );
}

String? _avatarUrl(WidgetTester tester) {
  final avatar = tester.widget<CircleAvatar>(find.byType(CircleAvatar));
  final image = avatar.backgroundImage;
  return image is NetworkImage ? image.url : null;
}

bool _avatarHasPlaceholder(WidgetTester tester) {
  final avatar = tester.widget<CircleAvatar>(find.byType(CircleAvatar));
  return avatar.backgroundImage == null && avatar.child is Icon;
}

void main() {
  final resolver = CommunityAuthorAvatarResolver.instance;

  tearDown(() => resolver.debugSetLoader(null));

  group('CommunityAuthorAvatarResolver', () {
    test('현재 공개 대표 사진 URL을 돌려준다', () async {
      resolver.debugSetLoader((uid) async => 'new');
      expect(await resolver.resolvePhotoUrl('author-1'), 'new');
    });

    test('같은 작성자는 하나의 조회를 공유한다(중복 조회 폭증 방지)', () async {
      var calls = 0;
      resolver.debugSetLoader((uid) async {
        calls += 1;
        return 'new';
      });

      // 같은 uid를 10번 요청해도 로더는 한 번만 호출된다.
      await Future.wait([
        for (var i = 0; i < 10; i++) resolver.resolvePhotoUrl('author-1'),
      ]);
      expect(calls, 1);

      // 다른 uid는 별도 1회.
      await resolver.resolvePhotoUrl('author-2');
      expect(calls, 2);
    });

    test('조회 실패/사진 없음은 null을 돌려준다(화면 fallback용)', () async {
      resolver.debugSetLoader((uid) async => null);
      expect(await resolver.resolvePhotoUrl('author-1'), isNull);
    });

    test('빈 uid는 조회 없이 null', () async {
      var calls = 0;
      resolver.debugSetLoader((uid) async {
        calls += 1;
        return 'new';
      });
      expect(await resolver.resolvePhotoUrl(''), isNull);
      expect(calls, 0);
    });
  });

  group('CommunityAuthorHeader 아바타 hydration', () {
    testWidgets('현재 공개 사진(new)으로 표시한다 — snapshot(old)이 아니라', (tester) async {
      resolver.debugSetLoader((uid) async => 'new');

      await tester.pumpWidget(
        _hostHeader(_snapshot(uid: 'author-1', photoUrl: 'old')),
      );
      await tester.pumpAndSettle();

      expect(_avatarUrl(tester), 'new');
      tester.takeException(); // NetworkImage 로드 시도(테스트 env)는 무시
    });

    testWidgets('조회 실패 시 snapshot 사진(old)으로 fallback', (tester) async {
      resolver.debugSetLoader((uid) async => null);

      await tester.pumpWidget(
        _hostHeader(_snapshot(uid: 'author-1', photoUrl: 'old')),
      );
      await tester.pumpAndSettle();

      expect(_avatarUrl(tester), 'old');
      tester.takeException();
    });

    testWidgets('현재 사진도 snapshot도 없으면 placeholder', (tester) async {
      resolver.debugSetLoader((uid) async => null);

      await tester.pumpWidget(
        _hostHeader(_snapshot(uid: 'author-1', photoUrl: '')),
      );
      await tester.pumpAndSettle();

      expect(_avatarHasPlaceholder(tester), isTrue);
    });
  });
}
