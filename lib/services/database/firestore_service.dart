import 'package:cloud_firestore/cloud_firestore.dart';

import '../../core/constants/app_constants.dart';
import '../../models/public_profile.dart';
import '../../models/user_profile.dart';

/// Firestore 접근을 감싸는 서비스.
///
/// 왜 감싸나(AuthService와 같은 이유):
/// - 화면이 FirebaseFirestore.instance를 직접 만지면 컬렉션 이름이 흩어지고
///   쿼리 로직이 UI에 섞인다.
/// - 여기 한 곳에 DB 접근을 모아 두면 테스트/교체/재사용이 쉽다.
///
/// 공개/비공개 경계(Phase 0-B):
/// - `users/{uid}`         비공개 원장(정확 birthDate/위치·재화·토큰·AI 캐시).
///                         구버전 호환 기간에는 기존 공개 프로필 필드도 임시 유지.
/// - `publicProfiles/{uid}` 다른 인증 사용자에게 공개되는 최소 프로필.
///                         정확 birthDate/정확 위치/재화/토큰/AI 캐시 없음.
///
/// 두 문서 write는 항상 하나의 [WriteBatch]로 원자적으로 커밋한다.
class FirestoreService {
  FirestoreService({FirebaseFirestore? firestore})
    : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  /// 프로필 편집으로 `users/{uid}`에 부분 갱신할 수 있는 필드 key 집합(고정).
  ///
  /// 재화/토큰/위치/인증/AI 캐시/불변 필드(birthDate, createdAt 등)는 포함하지
  /// 않는다. [buildLegacyEditableUserFields]가 정확히 이 key만 방출한다.
  static const Set<String> legacyEditableUserKeys = {
    'displayName',
    'gender',
    'bio',
    'photoUrls',
    'height',
    'religion',
    'smoking',
    'drinking',
    'jobCategory',
    'jobTitle',
    'education',
    'mbti',
    'interests',
    'personalityTags',
    'idealTags',
    'relationshipGoal',
    'updatedAt',
  };

  /// 신규 온보딩 생성 시 클라이언트가 `users/{uid}`에 쓸 수 있는 필드 key 집합.
  ///
  /// 재화/부스트/유료 unlock/AI 캐시/권한 필드는 신규 문서에도 클라이언트가
  /// 직접 만들지 않는다. 읽기 모델은 누락된 재화 필드를 기본값으로 처리한다.
  static const Set<String> clientCreatableUserKeys = {
    'displayName',
    'birthDate',
    'gender',
    'bio',
    'photoUrls',
    'createdAt',
    'updatedAt',
    'height',
    'religion',
    'smoking',
    'drinking',
    'jobCategory',
    'jobTitle',
    'education',
    'mbti',
    'interests',
    'personalityTags',
    'idealTags',
    'relationshipGoal',
    'location',
    'verifications',
    'discoveryFilter',
  };

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

  /// 공개 프로필 컬렉션 참조(읽기용).
  CollectionReference<PublicProfile> get _publicProfiles => _db
      .collection(AppConstants.publicProfilesCollection)
      .withConverter<PublicProfile>(
        fromFirestore: (snap, _) =>
            PublicProfile.fromMap(uid: snap.id, data: snap.data() ?? {}),
        toFirestore: (profile, _) => profile.toOwnerEditableFirestore(),
      );

  /// 공개 프로필 컬렉션 원시 참조(쓰기용). owner-editable payload만 쓴다.
  CollectionReference<Map<String, dynamic>> get _publicProfileMaps =>
      _db.collection(AppConstants.publicProfilesCollection);

  /// 프로필 편집으로 `users/{uid}`에 부분 갱신할 필드 Map을 만든다.
  ///
  /// Firebase 호출 없이 테스트 가능한 순수 함수. 반환 Map의 key 집합은 항상
  /// [legacyEditableUserKeys]와 정확히 같다. nullable 필드는 사용자가 값을
  /// 지웠을 때 기존 값도 제거되도록 `null`을 명시적으로 포함한다.
  static Map<String, dynamic> buildLegacyEditableUserFields(
    UserProfile profile,
  ) {
    return {
      'displayName': profile.displayName,
      'gender': profile.gender,
      'bio': profile.bio,
      'photoUrls': profile.photoUrls,
      'height': profile.height,
      'religion': profile.religion,
      'smoking': profile.smoking,
      'drinking': profile.drinking,
      'jobCategory': profile.jobCategory,
      'jobTitle': profile.jobTitle,
      'education': profile.education,
      'mbti': profile.mbti,
      'interests': profile.interests,
      'personalityTags': profile.personalityTags,
      'idealTags': profile.idealTags,
      'relationshipGoal': profile.relationshipGoal,
      'updatedAt': Timestamp.fromDate(profile.updatedAt),
    };
  }

  static Map<String, dynamic> buildClientCreatableUserFields(
    UserProfile profile,
  ) {
    return {
      'displayName': profile.displayName,
      'birthDate': Timestamp.fromDate(profile.birthDate),
      'gender': profile.gender,
      'bio': profile.bio,
      'photoUrls': profile.photoUrls,
      'createdAt': Timestamp.fromDate(profile.createdAt),
      'updatedAt': Timestamp.fromDate(profile.updatedAt),
      'height': profile.height,
      'religion': profile.religion,
      'smoking': profile.smoking,
      'drinking': profile.drinking,
      'jobCategory': profile.jobCategory,
      'jobTitle': profile.jobTitle,
      'education': profile.education,
      'mbti': profile.mbti,
      'interests': profile.interests,
      'personalityTags': profile.personalityTags,
      'idealTags': profile.idealTags,
      'relationshipGoal': profile.relationshipGoal,
      if (profile.location != null) 'location': profile.location!.toFirestore(),
      'verifications': const VerificationStatus().toFirestore(),
      'discoveryFilter': profile.discoveryFilter.toFirestore(),
    };
  }

  /// 클라이언트가 `publicProfiles/{uid}`에 쓸 수 있는 owner-editable payload.
  ///
  /// server-managed 필드([toServerManagedFirestore]/[toBackfillFirestore])는
  /// 절대 클라이언트 write에 쓰지 않는다.
  static Map<String, dynamic> _publicOwnerPayload(UserProfile profile) {
    return PublicProfile.fromUserProfile(profile).toOwnerEditableFirestore();
  }

  /// 새 유저 프로필 생성(온보딩 신규 사용자).
  ///
  /// 하나의 batch에서 비공개 원장 전체 생성과 공개 프로필 owner payload를
  /// 함께 커밋한다. 신규 생성이므로 `users/{uid}`는 전체 저장을 허용한다.
  Future<void> createUserProfile(UserProfile profile) async {
    final batch = _db.batch();

    // users/{uid}: 클라이언트 생성 허용 필드만 저장한다.
    batch.set(
      _db.collection(AppConstants.usersCollection).doc(profile.uid),
      buildClientCreatableUserFields(profile),
    );

    // publicProfiles/{uid}: owner-editable 필드만. server-managed 필드 미포함.
    batch.set(
      _publicProfileMaps.doc(profile.uid),
      _publicOwnerPayload(profile),
      SetOptions(merge: true),
    );

    await batch.commit();
  }

  /// uid로 유저 프로필 조회. 없으면 null.
  Future<UserProfile?> getUserProfile(String uid) async {
    final snapshot = await _users.doc(uid).get();
    return snapshot.data();
  }

  /// uid로 공개 프로필 조회. 없으면 null.
  ///
  /// 다른 사용자 표시 정보는 이 경로만 사용한다. `publicProfiles`가 없을 때
  /// `users`로 fallback하지 않는다.
  Future<PublicProfile?> getPublicProfile(String uid) async {
    final snapshot = await _publicProfiles.doc(uid).get();
    return snapshot.data();
  }

  /// uid로 공개 프로필을 실시간 구독한다. 없으면 null.
  Stream<PublicProfile?> watchPublicProfile(String uid) {
    return _publicProfiles.doc(uid).snapshots().map((snapshot) {
      return snapshot.data();
    });
  }

  /// 프로필 편집 저장(부분 갱신).
  ///
  /// 기존 [createUserProfile]의 전체 `set()`을 쓰지 않는다 — 그러면
  /// `users/{uid}`의 FCM 토큰·AI 캐시·재화 등 서버/비편집 상태가 삭제된다.
  /// 대신 하나의 batch에서:
  /// - `users/{uid}`는 [legacyEditableUserKeys] 필드만 `update()`
  /// - `publicProfiles/{uid}`는 owner-editable payload를 merge
  ///   (server-managed 공개 필드는 보존됨)
  Future<void> updateEditableUserProfile(UserProfile profile) async {
    final batch = _db.batch();

    batch.update(
      _db.collection(AppConstants.usersCollection).doc(profile.uid),
      buildLegacyEditableUserFields(profile),
    );

    batch.set(
      _publicProfileMaps.doc(profile.uid),
      _publicOwnerPayload(profile),
      SetOptions(merge: true),
    );

    await batch.commit();
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

  /// 마지막 위치를 정확/근사 이중으로 원자적 갱신한다.
  ///
  /// 하나의 batch에서:
  /// - `users/{uid}.location`         정확 좌표(비공개 원장)
  /// - `publicProfiles/{uid}.coarseLocation` 소수점 둘째 자리 근사 좌표(label 없음)
  ///
  /// 공개 문서가 아직 없는 기존 사용자도 있으므로 공개 위치는 merge로 쓴다 —
  /// backfill 전에는 `coarseLocation`만 가진 부분 공개 문서가 생길 수 있다.
  Future<void> updateUserLocation(String uid, UserLocation location) async {
    final batch = _db.batch();

    batch.update(_db.collection(AppConstants.usersCollection).doc(uid), {
      'location': location.toFirestore(),
    });

    batch.set(_publicProfileMaps.doc(uid), {
      'coarseLocation': CoarseLocation.fromUserLocation(location).toMap(),
    }, SetOptions(merge: true));

    await batch.commit();
  }

  /// 인증 상태를 users/{uid}.verifications에 반영한다.
  ///
  /// 프로토타입에서는 클라이언트가 FirebaseAuth.emailVerified를 읽어 동기화한다.
  /// 실서비스에서는 Cloud Functions/Admin SDK로 서버 검증 후 true를 써야
  /// 사용자가 임의로 인증 상태를 조작하는 위험을 줄일 수 있다.
  ///
  /// Phase 0-B: 아직 `publicProfiles.verifications`에는 복사하지 않는다 —
  /// 공개 verifications는 향후 Admin backfill/서버 동기화에서 처리한다.
  Future<void> updateUserVerifications(
    String uid,
    VerificationStatus verifications,
  ) async {
    if (verifications.hasAny) return;
    await updateUserProfile(uid, {
      'verifications': verifications.toFirestore(),
    });
  }

  /// 디스커버리 필터 설정을 저장한다.
  ///
  /// users/{uid} 본인 write 규칙으로 커버된다. 비공개 원장 전용 필드이므로
  /// 공개 문서에는 쓰지 않는다.
  Future<void> updateDiscoveryFilter(String uid, DiscoveryFilter filter) async {
    await updateUserProfile(uid, {'discoveryFilter': filter.toFirestore()});
  }
}
