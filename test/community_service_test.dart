// Firestore의 Query/Snapshot 타입은 sealed지만, 실제 네트워크 없이 쿼리
// 조건만 기록하기 위해 테스트 전용 fake로 구현한다(프로덕션 코드 아님).
// ignore_for_file: depend_on_referenced_packages, subtype_of_sealed_class
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:dating_app/models/community/community_enums.dart';
import 'package:dating_app/services/community/community_service.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// Phase 4-1 — CommunityService 쿼리·파싱 계약 테스트.
///
/// 실제 Firestore 접근은 Rules 테스트가 검증하고, 여기서는 쿼리 조건이
/// rules와 어긋나지 않는지와 스냅샷 파싱 규칙을 확인한다.
class _FakeApp extends Fake
    with MockPlatformInterfaceMixin
    implements FirebaseAppPlatform {
  @override
  String get name => defaultFirebaseAppName;
  @override
  FirebaseOptions get options => const FirebaseOptions(
    apiKey: 'k',
    appId: 'a',
    messagingSenderId: 's',
    projectId: 'p',
    storageBucket: 'b.appspot.com',
  );
}

class _FakeFirebasePlatform extends FirebasePlatform {
  @override
  FirebaseAppPlatform app([String name = defaultFirebaseAppName]) => _FakeApp();
  @override
  Future<FirebaseAppPlatform> initializeApp({
    String? name,
    FirebaseOptions? options,
  }) async => _FakeApp();
  @override
  List<FirebaseAppPlatform> get apps => [_FakeApp()];
}

/// where/orderBy/limit 호출을 기록하는 최소 fake.
class _RecordingFirestore extends Fake implements FirebaseFirestore {
  final calls = <String>[];

  @override
  CollectionReference<Map<String, dynamic>> collection(String path) {
    calls.add('collection:$path');
    return _RecordingCollection(this);
  }
}

class _RecordingQuery extends Fake implements Query<Map<String, dynamic>> {
  _RecordingQuery(this.db);

  final _RecordingFirestore db;

  @override
  Query<Map<String, dynamic>> where(
    Object field, {
    Object? isEqualTo,
    Object? isNotEqualTo,
    Object? isLessThan,
    Object? isLessThanOrEqualTo,
    Object? isGreaterThan,
    Object? isGreaterThanOrEqualTo,
    Object? arrayContains,
    Iterable<Object?>? arrayContainsAny,
    Iterable<Object?>? whereIn,
    Iterable<Object?>? whereNotIn,
    bool? isNull,
  }) {
    db.calls.add('where:$field==$isEqualTo');
    return this;
  }

  @override
  Query<Map<String, dynamic>> orderBy(Object field, {bool descending = false}) {
    db.calls.add('orderBy:$field:${descending ? 'desc' : 'asc'}');
    return this;
  }

  @override
  Query<Map<String, dynamic>> limit(int limit) {
    db.calls.add('limit:$limit');
    return this;
  }

  @override
  Stream<QuerySnapshot<Map<String, dynamic>>> snapshots({
    bool includeMetadataChanges = false,
    ListenSource source = ListenSource.defaultSource,
  }) {
    db.calls.add('snapshots');
    return const Stream.empty();
  }
}

/// CollectionReference로 반환돼야 하므로 Query fake와 같은 기록 동작을
/// 별도 클래스로 구현한다.
class _RecordingCollection extends Fake
    implements CollectionReference<Map<String, dynamic>> {
  _RecordingCollection(this.db);

  final _RecordingFirestore db;

  @override
  Query<Map<String, dynamic>> where(
    Object field, {
    Object? isEqualTo,
    Object? isNotEqualTo,
    Object? isLessThan,
    Object? isLessThanOrEqualTo,
    Object? isGreaterThan,
    Object? isGreaterThanOrEqualTo,
    Object? arrayContains,
    Iterable<Object?>? arrayContainsAny,
    Iterable<Object?>? whereIn,
    Iterable<Object?>? whereNotIn,
    bool? isNull,
  }) {
    db.calls.add('where:$field==$isEqualTo');
    return _RecordingQuery(db);
  }

  @override
  Query<Map<String, dynamic>> orderBy(Object field, {bool descending = false}) {
    db.calls.add('orderBy:$field:${descending ? 'desc' : 'asc'}');
    return _RecordingQuery(db);
  }

  @override
  Query<Map<String, dynamic>> limit(int limit) {
    db.calls.add('limit:$limit');
    return _RecordingQuery(db);
  }

  @override
  DocumentReference<Map<String, dynamic>> doc([String? path]) {
    db.calls.add('doc:$path');
    return _RecordingDocument(db);
  }
}

/// 서브컬렉션 경로(댓글·공감) 기록용 문서 fake.
class _RecordingDocument extends Fake
    implements DocumentReference<Map<String, dynamic>> {
  _RecordingDocument(this.db);

  final _RecordingFirestore db;

  @override
  CollectionReference<Map<String, dynamic>> collection(String path) {
    db.calls.add('collection:$path');
    return _RecordingCollection(db);
  }

  @override
  Stream<DocumentSnapshot<Map<String, dynamic>>> snapshots({
    bool includeMetadataChanges = false,
    ListenSource source = ListenSource.defaultSource,
  }) {
    db.calls.add('docSnapshots');
    return const Stream.empty();
  }
}

/// callable 호출을 기록하는 최소 fake.
class _FakeFunctions extends Fake implements FirebaseFunctions {
  _FakeFunctions({this.response, this.error});

  final Object? response;
  final Object? error;
  final List<({String name, Object? params})> calls = [];

  @override
  HttpsCallable httpsCallable(String name, {HttpsCallableOptions? options}) {
    return _FakeCallable(this, name);
  }
}

class _FakeCallable extends Fake implements HttpsCallable {
  _FakeCallable(this.fns, this.name);

  final _FakeFunctions fns;
  final String name;

  @override
  Future<HttpsCallableResult<T>> call<T>([Object? parameters]) async {
    fns.calls.add((name: name, params: parameters));
    final error = fns.error;
    if (error != null) throw error;
    return _FakeCallableResult<T>(fns.response as T);
  }
}

class _FakeCallableResult<T> extends Fake implements HttpsCallableResult<T> {
  _FakeCallableResult(this.data);

  @override
  final T data;
}

/// parsePosts용 최소 스냅샷 fake.
class _FakeQuerySnapshot extends Fake
    implements QuerySnapshot<Map<String, dynamic>> {
  _FakeQuerySnapshot(this.docs);

  @override
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> docs;
}

class _FakeDoc extends Fake
    implements QueryDocumentSnapshot<Map<String, dynamic>> {
  _FakeDoc(this.id, this._data);

  @override
  final String id;
  final Map<String, dynamic> _data;

  @override
  Map<String, dynamic> data() => _data;
}

Map<String, dynamic> _post({
  String surface = 'lounge',
  String status = 'active',
  String visibility = 'authenticated',
  String authorUid = 'authorA',
  Object? text = '내용',
}) {
  return {
    'surface': surface,
    'authorUid': authorUid,
    'authorSnapshot': {
      'uid': authorUid,
      'displayName': '작성자',
      'photoUrl': '',
      'photoVerified': false,
      'workVerified': false,
      'schoolVerified': false,
    },
    'text': text,
    'imageUrls': const <String>[],
    'status': status,
    'visibility': visibility,
    'reactionCount': 0,
    'commentCount': 0,
    'createdAt': Timestamp.fromDate(DateTime(2026, 7, 21)),
    'updatedAt': Timestamp.fromDate(DateTime(2026, 7, 21)),
    'schemaVersion': 1,
  };
}

Map<String, dynamic> _comment({
  String status = 'active',
  String authorUid = 'authorA',
  Object? text = '댓글이에요',
}) {
  return {
    'postId': 'p1',
    'authorUid': authorUid,
    'authorSnapshot': {
      'uid': authorUid,
      'displayName': '작성자',
      'photoUrl': '',
      'photoVerified': false,
      'workVerified': false,
      'schoolVerified': false,
    },
    'text': text,
    'status': status,
    'createdAt': Timestamp.fromDate(DateTime(2026, 7, 21)),
    'updatedAt': Timestamp.fromDate(DateTime(2026, 7, 21)),
    'schemaVersion': 1,
  };
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    FirebasePlatform.instance = _FakeFirebasePlatform();
  });

  group('1~6. 쿼리 계약', () {
    test('1~5. lounge 쿼리는 rules 조건과 정렬을 모두 포함한다', () {
      final db = _RecordingFirestore();
      CommunityService(
        firestore: db,
      ).watchPosts(surface: CommunityPostSurface.lounge).listen((_) {});

      expect(db.calls, [
        'collection:communityPosts',
        'where:surface==lounge',
        'where:status==active',
        'where:visibility==authenticated',
        'orderBy:createdAt:desc',
        'limit:30',
        'snapshots',
      ]);
    });

    test('2. feed 쿼리는 surface만 다르다', () {
      final db = _RecordingFirestore();
      CommunityService(
        firestore: db,
      ).watchPosts(surface: CommunityPostSurface.feed).listen((_) {});

      expect(db.calls.contains('where:surface==feed'), isTrue);
      expect(db.calls.contains('where:status==active'), isTrue);
      expect(db.calls.contains('where:visibility==authenticated'), isTrue);
    });

    test('6. limit은 1~50으로 제한된다', () {
      for (final entry in {0: 1, 1: 1, 30: 30, 50: 50, 500: 50, -3: 1}.entries) {
        final db = _RecordingFirestore();
        CommunityService(firestore: db)
            .watchPosts(
              surface: CommunityPostSurface.lounge,
              limit: entry.key,
            )
            .listen((_) {});
        expect(
          db.calls.contains('limit:${entry.value}'),
          isTrue,
          reason: '${entry.key} → ${entry.value}',
        );
      }
    });
  });

  group('7~9. 스냅샷 파싱', () {
    test('7. malformed·비활성 문서를 건너뛴다', () {
      final posts = CommunityService.parsePosts(
        _FakeQuerySnapshot([
          _FakeDoc('ok', _post()),
          // malformed: text 없음 / author 불일치 / unknown status
          _FakeDoc('bad1', _post(text: null)),
          _FakeDoc('bad2', {..._post(), 'authorUid': 'other'}),
          _FakeDoc('bad3', _post(status: 'exploded')),
          // 비활성 상태는 쿼리에서도 걸러지지만 방어적으로 한 번 더 뺀다.
          _FakeDoc('hidden', _post(status: 'hidden')),
          _FakeDoc('removed', _post(status: 'removed')),
        ]),
      );

      expect(posts.map((p) => p.id), ['ok']);
    });

    test('중복 id는 한 번만 담고 결과는 불변이다', () {
      final posts = CommunityService.parsePosts(
        _FakeQuerySnapshot([
          _FakeDoc('p1', _post()),
          _FakeDoc('p1', _post()),
          _FakeDoc('p2', _post()),
        ]),
      );

      expect(posts.map((p) => p.id), ['p1', 'p2']);
      expect(() => posts.add(posts.first), throwsUnsupportedError);
    });

    test('8. 작성자 정보는 저장된 snapshot만 쓴다(추가 조회 없음)', () {
      // publicProfiles를 읽었다면 _RecordingFirestore.calls에 남는다.
      final db = _RecordingFirestore();
      CommunityService(
        firestore: db,
      ).watchPosts(surface: CommunityPostSurface.lounge).listen((_) {});

      expect(
        db.calls.where((c) => c.contains('publicProfiles')),
        isEmpty,
      );
      expect(db.calls.where((c) => c.contains('users')), isEmpty);

      final posts = CommunityService.parsePosts(
        _FakeQuerySnapshot([_FakeDoc('p1', _post())]),
      );
      expect(posts.single.author.displayName, '작성자');
    });

    test('9. 댓글 파싱도 active만 담고 중복 id를 걸러낸다', () {
      final comments = CommunityService.parseComments(
        _FakeQuerySnapshot([
          _FakeDoc('c1', _comment()),
          _FakeDoc('c1', _comment()),
          _FakeDoc('bad', _comment(text: null)),
          _FakeDoc('removed', _comment(status: 'removed')),
        ]),
      );

      expect(comments.map((c) => c.id), ['c1']);
      expect(() => comments.add(comments.first), throwsUnsupportedError);
    });
  });

  // ── Phase 4-2: 쓰기 계약 ─────────────────────────────────────────────
  group('10~16. callable 계약', () {
    CommunityService serviceWith(_FakeFunctions fns, [_RecordingFirestore? db]) {
      return CommunityService(
        firestore: db ?? _RecordingFirestore(),
        functions: fns,
      );
    }

    test('10. 게시물 작성은 본문만 보내고 postId를 돌려준다', () async {
      final fns = _FakeFunctions(response: {'postId': 'p1'});
      final postId = await serviceWith(fns).createLoungePost(text: '첫 글');

      expect(postId, 'p1');
      expect(fns.calls.single.name, 'createLoungePost');
      // 작성자·상태·카운트·timestamp는 클라이언트가 보내지 않는다.
      expect(fns.calls.single.params, {'text': '첫 글'});
    });

    test('11. 댓글 작성 payload는 postId와 본문뿐이다', () async {
      final fns = _FakeFunctions(response: {'commentId': 'c1'});
      final id = await serviceWith(
        fns,
      ).createComment(postId: 'p1', text: '댓글');

      expect(id, 'c1');
      expect(fns.calls.single.name, 'createCommunityComment');
      expect(fns.calls.single.params, {'postId': 'p1', 'text': '댓글'});
    });

    test('12. 공감 toggle 응답을 그대로 전달한다', () async {
      final fns = _FakeFunctions(
        response: {'reacted': true, 'reactionCount': 3},
      );
      final result = await serviceWith(fns).toggleReaction(postId: 'p1');

      expect(result.reacted, isTrue);
      expect(result.reactionCount, 3);
      expect(fns.calls.single.name, 'toggleCommunityReaction');
      expect(fns.calls.single.params, {'postId': 'p1'});
    });

    test('13~14. 삭제 callable payload', () async {
      final fns = _FakeFunctions(response: {'deleted': true});
      final service = serviceWith(fns);
      await service.deletePost(postId: 'p1');
      await service.deleteComment(postId: 'p1', commentId: 'c1');

      expect(fns.calls[0].name, 'deleteCommunityPost');
      expect(fns.calls[0].params, {'postId': 'p1'});
      expect(fns.calls[1].name, 'deleteCommunityComment');
      expect(fns.calls[1].params, {'postId': 'p1', 'commentId': 'c1'});
    });

    test('15. 신고 payload는 허용된 필드만 담는다', () async {
      final fns = _FakeFunctions(response: {'reported': true});
      await serviceWith(fns).reportContent(
        targetType: 'comment',
        postId: 'p1',
        commentId: 'c1',
        reason: 'spam_scam',
        detail: '  광고 같아요  ',
      );

      expect(fns.calls.single.name, 'reportCommunityContent');
      expect(fns.calls.single.params, {
        'targetType': 'comment',
        'postId': 'p1',
        'commentId': 'c1',
        'reason': 'spam_scam',
        'detail': '광고 같아요',
      });
    });

    test('16. 형태가 어긋난 응답과 raw 오류는 고정 문구로 바뀐다', () async {
      final malformed = _FakeFunctions(response: 'not-a-map');
      await expectLater(
        serviceWith(malformed).createLoungePost(text: '글'),
        throwsA(
          isA<CommunityActionError>().having(
            (e) => e.message,
            'message',
            CommunityService.genericErrorMessage,
          ),
        ),
      );

      final missingId = _FakeFunctions(response: {'unexpected': 1});
      await expectLater(
        serviceWith(missingId).createLoungePost(text: '글'),
        throwsA(isA<CommunityActionError>()),
      );

      final raw = _FakeFunctions(
        error: FirebaseFunctionsException(
          code: 'permission-denied',
          message: 'raw server message',
        ),
      );
      await expectLater(
        serviceWith(raw).deletePost(postId: 'p1'),
        throwsA(
          isA<CommunityActionError>()
              .having((e) => e.message, 'message', '권한이 없어요.')
              .having((e) => e.forbiddenText, 'forbiddenText', isFalse),
        ),
      );
    });

    test('금지 내용 거부는 고정 code로 구분한다', () async {
      final fns = _FakeFunctions(
        error: FirebaseFunctionsException(
          code: 'invalid-argument',
          message: 'raw server message',
          details: {'code': CommunityService.forbiddenTextErrorCode},
        ),
      );

      await expectLater(
        serviceWith(fns).createLoungePost(text: '010-1234-5678'),
        throwsA(
          isA<CommunityActionError>()
              .having(
                (e) => e.message,
                'message',
                CommunityService.forbiddenTextMessage,
              )
              .having((e) => e.forbiddenText, 'forbiddenText', isTrue),
        ),
      );
    });
  });

  group('17~18. 읽기 쿼리(댓글·본인 공감)', () {
    test('17. 댓글 쿼리는 active + createdAt 오름차순이다', () {
      final db = _RecordingFirestore();
      CommunityService(
        firestore: db,
        functions: _FakeFunctions(),
      ).watchComments(postId: 'p1').listen((_) {});

      expect(db.calls, [
        'collection:communityPosts',
        'doc:p1',
        'collection:comments',
        'where:status==active',
        'orderBy:createdAt:asc',
        'limit:100',
        'snapshots',
      ]);
    });

    test('18. 본인 공감은 자기 문서 하나만 읽는다', () {
      final db = _RecordingFirestore();
      CommunityService(
        firestore: db,
        functions: _FakeFunctions(),
      ).watchMyReaction(postId: 'p1', uid: 'me').listen((_) {});

      expect(db.calls, [
        'collection:communityPosts',
        'doc:p1',
        'collection:reactions',
        'doc:me',
        'docSnapshots',
      ]);
      // 다른 사용자의 공감 목록을 훑는 쿼리는 없다.
      expect(db.calls.where((c) => c.startsWith('where:')), isEmpty);
    });
  });
}
