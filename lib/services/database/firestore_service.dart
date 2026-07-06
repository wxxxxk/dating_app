import 'package:cloud_firestore/cloud_firestore.dart';

import '../../core/constants/app_constants.dart';
import '../../models/user_profile.dart';

/// Firestore 접근을 감싸는 서비스.
///
/// 왜 감싸나(AuthService와 같은 이유):
/// - 화면이 FirebaseFirestore.instance를 직접 만지면 컬렉션 이름이 흩어지고
///   쿼리 로직이 UI에 섞인다.
/// - 여기 한 곳에 DB 접근을 모아 두면 테스트/교체/재사용이 쉽다.
///
/// 이번 마일스톤은 인증까지가 목표라 메서드는 "뼈대"만 둔다.
/// (실제 화면 연결은 프로필 마일스톤에서)
class FirestoreService {
  FirestoreService({FirebaseFirestore? firestore})
    : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  /// users 컬렉션 참조. withConverter로 모델 ↔ Map 변환을 자동화한다.
  ///
  /// withConverter를 쓰면 get()/snapshots() 결과가 곧바로 UserProfile로 나와서
  /// 매번 fromFirestore를 호출할 필요가 없다.
  CollectionReference<UserProfile> get _users => _db
      .collection(AppConstants.usersCollection)
      .withConverter<UserProfile>(
        fromFirestore: (snap, _) => UserProfile.fromFirestore(snap),
        toFirestore: (profile, _) => profile.toFirestore(),
      );

  /// 새 유저 프로필 생성.
  ///
  /// 문서 ID로 uid를 쓰면 "한 유저당 한 문서"가 보장되고 조회가 단순해진다.
  Future<void> createUserProfile(UserProfile profile) async {
    await _users.doc(profile.uid).set(profile);
  }

  /// uid로 유저 프로필 조회. 없으면 null.
  Future<UserProfile?> getUserProfile(String uid) async {
    final snapshot = await _users.doc(uid).get();
    return snapshot.data();
  }

  /// 유저 프로필 부분 갱신.
  ///
  /// set(merge:true) 대신 update를 쓰면 "문서가 반드시 존재"해야 한다는
  /// 의미가 분명해진다(없으면 에러). 부분 필드만 바꿀 때 사용.
  Future<void> updateUserProfile(
    String uid,
    Map<String, dynamic> fields,
  ) async {
    await _db.collection(AppConstants.usersCollection).doc(uid).update(fields);
  }

  /// 마지막 위치만 부분 갱신한다.
  ///
  /// 기존 프로필 필드를 덮어쓰지 않도록 users/{uid}.location 맵만 업데이트한다.
  Future<void> updateUserLocation(String uid, UserLocation location) async {
    await updateUserProfile(uid, {'location': location.toFirestore()});
  }

  /// 인증 상태를 users/{uid}.verifications에 반영한다.
  ///
  /// 프로토타입에서는 클라이언트가 FirebaseAuth.emailVerified를 읽어 동기화한다.
  /// 실서비스에서는 Cloud Functions/Admin SDK로 서버 검증 후 true를 써야
  /// 사용자가 임의로 인증 상태를 조작하는 위험을 줄일 수 있다.
  Future<void> updateUserVerifications(
    String uid,
    VerificationStatus verifications,
  ) async {
    await updateUserProfile(uid, {
      'verifications': verifications.toFirestore(),
    });
  }

  /// 디스커버리 필터 설정을 저장한다.
  ///
  /// users/{uid} 본인 write 규칙으로 커버된다.
  Future<void> updateDiscoveryFilter(String uid, DiscoveryFilter filter) async {
    await updateUserProfile(uid, {'discoveryFilter': filter.toFirestore()});
  }
}
