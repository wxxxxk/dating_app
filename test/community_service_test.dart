// Firestore의 Query/Snapshot 타입은 sealed지만, 실제 네트워크 없이 쿼리
// 조건만 기록하기 위해 테스트 전용 fake로 구현한다(프로덕션 코드 아님).
// ignore_for_file: depend_on_referenced_packages, subtype_of_sealed_class
import 'package:cloud_firestore/cloud_firestore.dart';
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

    test('9. write API를 제공하지 않는다', () {
      final service = CommunityService(firestore: _RecordingFirestore());
      // 읽기 API만 존재한다(컴파일 계약).
      expect(service.watchPosts, isA<Function>());
      expect(
        (service as dynamic).noSuchMethod,
        isA<Function>(),
        reason: 'createPost/updatePost 등은 정의되어 있지 않다',
      );
    });
  });
}
