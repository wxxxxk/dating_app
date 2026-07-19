import 'package:cloud_firestore/cloud_firestore.dart';

import 'user_profile.dart';

/// 유한한 double만 통과시킨다. NaN/Infinity, 숫자가 아닌 값은 null로 처리한다.
double? _finiteDouble(dynamic value) {
  if (value is num) {
    final d = value.toDouble();
    if (d.isFinite) return d;
  }
  return null;
}

/// Firestore Map/원시 리스트를 안전하게 `List<String>`으로 변환한다.
///
/// null이거나 리스트가 아니면 빈 리스트를 반환한다. 반환값은 호출부에서
/// 다시 방어 복사되므로 여기서는 일반 리스트로 돌려준다.
List<String> _stringList(dynamic value) {
  if (value is List) {
    return value.map((e) => e.toString()).toList();
  }
  return const <String>[];
}

DateTime? _timestampDate(dynamic value) {
  if (value is Timestamp) return value.toDate();
  if (value is DateTime) return value;
  return null;
}

/// Firestore 원시 값을 안전한 `Map<String, String>`으로 변환한다.
///
/// Map이 아니면 빈 map, key·value가 모두 String인 항목만 보존한다(숫자/bool/
/// list/중첩 map 무시). 원본 map을 그대로 노출하지 않도록 새 map을 반환한다.
/// 알 수 없는 문자열 key-value는 이 저수준 parser에서 제거하지 않는다 —
/// 카탈로그 유효성 검증은 UI와 Rules의 책임이며, 카탈로그가 바뀌어도 기존
/// 저장 데이터를 손실시키지 않기 위함이다.
Map<String, String> _stringMap(dynamic value) {
  if (value is! Map) return const {};
  final result = <String, String>{};
  value.forEach((key, val) {
    if (key is String && val is String) {
      result[key] = val;
    }
  });
  return result;
}

int? _intOrNull(dynamic value) {
  if (value is num) return value.toInt();
  return null;
}

String? _stringOrNull(dynamic value) => value is String ? value : null;

/// 공개 프로필의 근사 위치.
///
/// 정확한 [UserLocation]의 위도·경도를 소수점 둘째 자리로 양자화해 저장한다.
/// 원본 좌표(약 11m 정밀도)는 절대 공개 문서로 복사하지 않으며, `label`도
/// 포함하지 않는다. 뷰어는 자신의 정확 좌표(비공개)와 상대의 이 근사 좌표로
/// 거리 밴드("3km 이내")만 계산한다.
class CoarseLocation {
  final double lat;
  final double lng;
  final DateTime? updatedAt;

  const CoarseLocation({required this.lat, required this.lng, this.updatedAt});

  /// 좌표 양자화 단일 진입점. 소수점 둘째 자리로 반올림한다.
  ///
  /// 예) 37.56647 → 37.57, 126.97796 → 126.98.
  static double quantize(double value) => (value * 100).roundToDouble() / 100;

  /// 정확한 [UserLocation]에서 근사 위치를 만든다. 좌표는 즉시 양자화된다.
  factory CoarseLocation.fromUserLocation(UserLocation location) {
    return CoarseLocation(
      lat: quantize(location.lat),
      lng: quantize(location.lng),
      updatedAt: location.updatedAt,
    );
  }

  /// 저장된 Map에서 근사 위치를 복원한다.
  ///
  /// lat/lng가 없거나 유한한 숫자가 아니면 null을 반환한다 — Discovery가
  /// 위치 없는 프로필로 안전하게 취급할 수 있게 한다. 읽을 때도 방어적으로
  /// 다시 양자화해 불변식을 유지한다.
  static CoarseLocation? fromMap(Map<String, dynamic>? map) {
    if (map == null) return null;
    final lat = _finiteDouble(map['lat']);
    final lng = _finiteDouble(map['lng']);
    if (lat == null || lng == null) return null;

    final rawUpdatedAt = map['updatedAt'];
    DateTime? updatedAt;
    if (rawUpdatedAt is Timestamp) {
      updatedAt = rawUpdatedAt.toDate();
    } else if (rawUpdatedAt != null) {
      updatedAt = DateTime.tryParse('$rawUpdatedAt');
    }

    return CoarseLocation(
      lat: quantize(lat),
      lng: quantize(lng),
      updatedAt: updatedAt,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'lat': lat,
      'lng': lng,
      if (updatedAt != null) 'updatedAt': Timestamp.fromDate(updatedAt!),
    };
  }
}

/// `publicProfiles/{uid}`에 저장·조회되는 공개 프로필 모델.
///
/// 비공개 원장(`users/{uid}`, [UserProfile])과 명확히 분리된 경계다. 공개
/// 문서에는 다른 인증 사용자에게 보여도 되는 최소 필드만 담고, 정확한
/// 생년월일·정밀 좌표·재화·토큰·AI 캐시 같은 민감/서버 데이터는 절대
/// 포함하지 않는다.
///
/// 필드는 세 부류로 나뉜다.
/// - owner-editable: 사용자가 프로필 편집으로 바꾸는 공개 표시 필드.
/// - server-managed: 공개 문서에서 읽히지만 일반 편집으로는 못 바꾸는 필드
///   ([verifications]/[rankingBoostUntil]/[profileUpdatedAt]/[schemaVersion]).
/// - 이 둘의 합이 backfill payload다.
///
/// 이번 단계에서는 모델·직렬화 경계만 정의하며, 실제 Firestore 읽기/쓰기
/// 경로나 화면 전환은 하지 않는다.
class PublicProfile {
  /// 현재 공개 스키마 버전. 신규 문서는 이 값으로 생성된다.
  static const int currentSchemaVersion = 1;

  /// age가 없거나 유효 범위를 벗어난 문서를 나타내는 안전 기본값.
  ///
  /// 정상 나이로 위조하지 않고 이 값(-1)을 둬서, 향후 Discovery가
  /// 비정상 프로필을 명시적으로 제외할 수 있게 한다.
  static const int unknownAge = -1;

  /// owner-editable payload가 항상 방출하는 key 집합(고정).
  static const Set<String> ownerEditableKeys = {
    'displayName',
    'age',
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
    'valueAnswers',
    'coarseLocation',
  };

  /// server-managed payload가 항상 방출하는 key 집합(고정).
  static const Set<String> serverManagedKeys = {
    'verifications',
    'rankingBoostUntil',
    'profileUpdatedAt',
    'schemaVersion',
  };

  /// backfill payload가 방출하는 key 집합(owner-editable ∪ server-managed).
  static const Set<String> backfillKeys = {
    ...ownerEditableKeys,
    ...serverManagedKeys,
  };

  // ── 문서 ID ─────────────────────────────────────────────────────────────
  final String uid; // 문서 ID. 본문에는 저장하지 않는다.

  // ── owner-editable 공개 표시 필드 ────────────────────────────────────────
  final String displayName;
  final int age; // 정확 birthDate로 계산한 정수 나이. birthDate 자체는 비공개.
  final String gender;
  final String bio;
  final List<String> photoUrls;

  final int? height;
  final String? religion;
  final String? smoking;
  final String? drinking;
  final String? jobCategory;
  final String? jobTitle;
  final String? education;
  final String? mbti;

  final List<String> interests;
  final List<String> personalityTags;
  final List<String> idealTags;
  final String? relationshipGoal;

  /// 가치관 답변(questionKey → answerKey). 비민감 취향 데이터라 공개 문서에 포함.
  final Map<String, String> valueAnswers;

  final CoarseLocation? coarseLocation;

  // ── server-managed 필드(공개 read, 일반 편집 불가) ───────────────────────
  final VerificationStatus verifications;
  final DateTime? rankingBoostUntil;
  final DateTime? profileUpdatedAt;
  final int schemaVersion;

  PublicProfile({
    required this.uid,
    this.displayName = '',
    this.age = unknownAge,
    this.gender = 'other',
    this.bio = '',
    List<String> photoUrls = const [],
    this.height,
    this.religion,
    this.smoking,
    this.drinking,
    this.jobCategory,
    this.jobTitle,
    this.education,
    this.mbti,
    List<String> interests = const [],
    List<String> personalityTags = const [],
    List<String> idealTags = const [],
    this.relationshipGoal,
    Map<String, String> valueAnswers = const {},
    this.coarseLocation,
    this.verifications = const VerificationStatus(),
    this.rankingBoostUntil,
    this.profileUpdatedAt,
    this.schemaVersion = currentSchemaVersion,
  }) : photoUrls = List<String>.unmodifiable(photoUrls),
       interests = List<String>.unmodifiable(interests),
       personalityTags = List<String>.unmodifiable(personalityTags),
       idealTags = List<String>.unmodifiable(idealTags),
       valueAnswers = Map<String, String>.unmodifiable(valueAnswers);

  /// age 값이 유효 범위(0~130) 안에 있는지. Discovery 제외 판정용.
  bool get hasValidAge => age >= 0 && age <= 130;

  /// 비공개 [UserProfile]에서 공개 프로필을 파생한다.
  ///
  /// - [age]는 [UserProfile.ageAt]로 계산한다([referenceDate] 없으면 현재 시각).
  /// - 정확한 위치는 반드시 [CoarseLocation]으로 양자화한다.
  /// - [UserProfile.boostUntil]은 **절대 복사하지 않는다**. 결과의
  ///   [rankingBoostUntil]은 항상 null이다. `users/{uid}.boostUntil`은 아직
  ///   클라이언트가 수정 가능한 레거시 필드라, 이를 server-managed 공개 필드로
  ///   자동 매핑하면 사용자가 Discovery 랭킹 값을 위조할 수 있다.
  ///   [rankingBoostUntil]은 Cloud Functions 또는 Admin backfill만 설정하며,
  ///   기존 운영 데이터의 부스트 보존은 Phase 0-B 후속 Admin backfill에서
  ///   명시적으로 처리한다.
  /// - [birthDate]는 어떤 형태로도 공개 모델에 포함하지 않는다.
  factory PublicProfile.fromUserProfile(
    UserProfile profile, {
    DateTime? referenceDate,
  }) {
    final reference = referenceDate ?? DateTime.now();
    return PublicProfile(
      uid: profile.uid,
      displayName: profile.displayName,
      age: profile.ageAt(reference),
      gender: profile.gender,
      bio: profile.bio,
      photoUrls: profile.photoUrls,
      height: profile.height,
      religion: profile.religion,
      smoking: profile.smoking,
      drinking: profile.drinking,
      jobCategory: profile.jobCategory,
      jobTitle: profile.jobTitle,
      education: profile.education,
      mbti: profile.mbti,
      interests: profile.interests,
      personalityTags: profile.personalityTags,
      idealTags: profile.idealTags,
      relationshipGoal: profile.relationshipGoal,
      valueAnswers: profile.valueAnswers,
      coarseLocation: profile.location != null
          ? CoarseLocation.fromUserLocation(profile.location!)
          : null,
      verifications: profile.verifications,
      // boostUntil은 신뢰 경계상 복사 금지 — 항상 null. server/admin만 설정한다.
      rankingBoostUntil: null,
      profileUpdatedAt: profile.updatedAt,
      schemaVersion: currentSchemaVersion,
    );
  }

  /// `publicProfiles/{uid}` 문서 Map에서 공개 프로필을 복원한다.
  ///
  /// 누락 필드와 구형 문서를 안전하게 처리한다. [age]가 없거나 유효 범위를
  /// 벗어나면 정상 나이로 위조하지 않고 [unknownAge]로 둔다.
  factory PublicProfile.fromMap({
    required String uid,
    required Map<String, dynamic> data,
  }) {
    return PublicProfile(
      uid: uid,
      displayName: _stringOrNull(data['displayName']) ?? '',
      age: _parseAge(data['age']),
      gender: _stringOrNull(data['gender']) ?? 'other',
      bio: _stringOrNull(data['bio']) ?? '',
      photoUrls: _stringList(data['photoUrls']),
      height: _intOrNull(data['height']),
      religion: _stringOrNull(data['religion']),
      smoking: _stringOrNull(data['smoking']),
      drinking: _stringOrNull(data['drinking']),
      jobCategory: _stringOrNull(data['jobCategory']),
      jobTitle: _stringOrNull(data['jobTitle']),
      education: _stringOrNull(data['education']),
      mbti: _stringOrNull(data['mbti']),
      interests: _stringList(data['interests']),
      personalityTags: _stringList(data['personalityTags']),
      idealTags: _stringList(data['idealTags']),
      relationshipGoal: _stringOrNull(data['relationshipGoal']),
      valueAnswers: _stringMap(data['valueAnswers']),
      coarseLocation: CoarseLocation.fromMap(
        data['coarseLocation'] is Map
            ? Map<String, dynamic>.from(data['coarseLocation'] as Map)
            : null,
      ),
      verifications: VerificationStatus.fromMap(
        data['verifications'] is Map
            ? Map<String, dynamic>.from(data['verifications'] as Map)
            : null,
      ),
      rankingBoostUntil: _timestampDate(data['rankingBoostUntil']),
      profileUpdatedAt: _timestampDate(data['profileUpdatedAt']),
      schemaVersion: _intOrNull(data['schemaVersion']) ?? currentSchemaVersion,
    );
  }

  /// age를 안전하게 파싱한다. 없거나 유효 범위(0~130) 밖이면 [unknownAge].
  static int _parseAge(dynamic value) {
    if (value is num) {
      final i = value.toInt();
      if (i >= 0 && i <= 130) return i;
    }
    return unknownAge;
  }

  /// 사용자가 프로필 편집으로 갱신할 수 있는 공개 필드만 담은 payload.
  ///
  /// server-managed 필드([verifications]/[rankingBoostUntil]/
  /// [profileUpdatedAt]/[schemaVersion])와 모든 비공개 필드는 포함하지 않는다.
  ///
  /// 향후 클라이언트 dual-write는 **이 메서드만** 사용해야 한다.
  /// [toServerManagedFirestore]/[toBackfillFirestore]를 클라이언트 쓰기에
  /// 쓰면 사용자가 서버 신뢰 필드를 위조할 수 있다.
  Map<String, dynamic> toOwnerEditableFirestore() {
    return {
      'displayName': displayName,
      'age': age,
      'gender': gender,
      'bio': bio,
      'photoUrls': photoUrls.toList(),
      'height': height,
      'religion': religion,
      'smoking': smoking,
      'drinking': drinking,
      'jobCategory': jobCategory,
      'jobTitle': jobTitle,
      'education': education,
      'mbti': mbti,
      'interests': interests.toList(),
      'personalityTags': personalityTags.toList(),
      'idealTags': idealTags.toList(),
      'relationshipGoal': relationshipGoal,
      'valueAnswers': Map<String, String>.from(valueAnswers),
      'coarseLocation': coarseLocation?.toMap(),
    };
  }

  /// 서버(Admin SDK)만 갱신하는 필드 payload.
  ///
  /// ⚠️ **신뢰 경계**: trusted server/admin 데이터에만 사용한다. 클라이언트가
  /// 이 payload를 Firestore에 직접 쓰면 [verifications]/[rankingBoostUntil]을
  /// 위조할 수 있으므로, 클라이언트 dual-write는 절대 이 메서드를 쓰지 않는다.
  Map<String, dynamic> toServerManagedFirestore() {
    return {
      'verifications': verifications.toFirestore(),
      'rankingBoostUntil': rankingBoostUntil != null
          ? Timestamp.fromDate(rankingBoostUntil!)
          : null,
      'profileUpdatedAt': profileUpdatedAt != null
          ? Timestamp.fromDate(profileUpdatedAt!)
          : null,
      'schemaVersion': schemaVersion,
    };
  }

  /// Admin SDK backfill용 전체 공개 문서 payload.
  ///
  /// owner-editable + server-managed 필드를 모두 담되, 비공개 필드는 절대
  /// 포함하지 않는다.
  ///
  /// ⚠️ **신뢰 경계**: trusted server/admin(backfill)에서만 사용한다.
  /// server-managed 필드를 포함하므로 클라이언트 쓰기 경로에서는 절대
  /// 사용하지 않는다.
  Map<String, dynamic> toBackfillFirestore() {
    return {...toOwnerEditableFirestore(), ...toServerManagedFirestore()};
  }
}
