import 'package:cloud_firestore/cloud_firestore.dart';

/// 사용자의 마지막 위치 정보.
///
/// 정확한 좌표는 Firestore 내부 저장/거리 계산에만 쓰고, 화면에는 거리만 노출한다.
class UserLocation {
  final double lat;
  final double lng;
  final DateTime updatedAt;
  final String? label;

  const UserLocation({
    required this.lat,
    required this.lng,
    required this.updatedAt,
    this.label,
  });

  factory UserLocation.fromMap(Map<String, dynamic> map) {
    final rawUpdatedAt = map['updatedAt'];
    return UserLocation(
      lat: (map['lat'] as num?)?.toDouble() ?? 0,
      lng: (map['lng'] as num?)?.toDouble() ?? 0,
      updatedAt: rawUpdatedAt is Timestamp
          ? rawUpdatedAt.toDate()
          : DateTime.tryParse('${rawUpdatedAt ?? ''}') ?? DateTime(1970),
      label: map['label'] as String?,
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'lat': lat,
      'lng': lng,
      'updatedAt': Timestamp.fromDate(updatedAt),
      if (label != null && label!.isNotEmpty) 'label': label,
    };
  }
}

/// 프로필 신뢰도 표시용 인증 상태.
///
/// 현재는 이메일 인증만 Firebase Auth 상태와 동기화한다.
/// 전화/사진 인증은 추후 구현 전까지 false가 기본값이다.
class VerificationStatus {
  final bool email;
  final bool phone;
  final bool photo;

  const VerificationStatus({
    this.email = false,
    this.phone = false,
    this.photo = false,
  });

  factory VerificationStatus.fromMap(Map<String, dynamic>? map) {
    return VerificationStatus(
      email: map?['email'] == true,
      phone: map?['phone'] == true,
      photo: map?['photo'] == true,
    );
  }

  Map<String, dynamic> toFirestore() {
    return {'email': email, 'phone': phone, 'photo': photo};
  }

  bool get hasAny => email || phone || photo;

  VerificationStatus copyWith({bool? email, bool? phone, bool? photo}) {
    return VerificationStatus(
      email: email ?? this.email,
      phone: phone ?? this.phone,
      photo: photo ?? this.photo,
    );
  }
}

/// 디스커버리에서 사용할 필터 설정.
///
/// Firestore users/{uid}.discoveryFilter에 저장해 기기를 바꿔도 유지한다.
class DiscoveryFilter {
  static const int defaultAgeMin = 18;
  static const int defaultAgeMax = 80;

  // ProfileOptions.relationshipGoals와 같은 key 집합. 필터 라운드트립
  // 검증용으로 여기 한 번 더 둔다 — UI 라벨과는 무관한 순수 데이터 검증이라
  // core/constants(옵션 라벨 계층)에 대한 의존을 만들지 않기 위함이다.
  static const validRelationshipGoals = {
    'casual_friend',
    'light_romance',
    'serious_relationship',
    'open_to_anything',
  };

  final int ageMin;
  final int ageMax;
  final double? maxDistanceKm;
  final String gender; // 'male' | 'female' | 'all'
  final String? relationshipGoal; // null = 상관없음/전체

  const DiscoveryFilter({
    this.ageMin = defaultAgeMin,
    this.ageMax = defaultAgeMax,
    this.maxDistanceKm,
    this.gender = 'all',
    this.relationshipGoal,
  });

  factory DiscoveryFilter.fromMap(Map<String, dynamic>? map) {
    final rawAgeMin = (map?['ageMin'] as num?)?.toInt() ?? defaultAgeMin;
    final rawAgeMax = (map?['ageMax'] as num?)?.toInt() ?? defaultAgeMax;
    final ageMin = rawAgeMin.clamp(defaultAgeMin, defaultAgeMax);
    final ageMax = rawAgeMax.clamp(ageMin, defaultAgeMax);
    final rawMaxDistance = (map?['maxDistanceKm'] as num?)?.toDouble();
    final gender = map?['gender'] as String? ?? 'all';
    final rawRelationshipGoal = map?['relationshipGoal'] as String?;
    return DiscoveryFilter(
      ageMin: ageMin,
      ageMax: ageMax,
      maxDistanceKm: rawMaxDistance?.clamp(1, 50).toDouble(),
      gender: ['male', 'female', 'all'].contains(gender) ? gender : 'all',
      // 기존 문서엔 이 필드가 아예 없다 — null이면 그대로 "전체"로 안전 처리.
      // 알 수 없는 key가 저장돼 있어도(예: 옵션 목록이 나중에 바뀐 경우)
      // 조용히 무시하고 전체로 되돌린다.
      relationshipGoal: validRelationshipGoals.contains(rawRelationshipGoal)
          ? rawRelationshipGoal
          : null,
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'ageMin': ageMin,
      'ageMax': ageMax,
      'maxDistanceKm': maxDistanceKm,
      'gender': gender,
      'relationshipGoal': relationshipGoal,
    };
  }

  bool get hasActiveFilters =>
      ageMin != defaultAgeMin ||
      ageMax != defaultAgeMax ||
      maxDistanceKm != null ||
      gender != 'all' ||
      relationshipGoal != null;

  DiscoveryFilter copyWith({
    int? ageMin,
    int? ageMax,
    double? maxDistanceKm,
    bool clearDistance = false,
    String? gender,
    String? relationshipGoal,
    bool clearRelationshipGoal = false,
  }) {
    final nextAgeMin = ageMin ?? this.ageMin;
    final nextAgeMax = ageMax ?? this.ageMax;
    return DiscoveryFilter(
      ageMin: nextAgeMin.clamp(defaultAgeMin, defaultAgeMax),
      ageMax: nextAgeMax.clamp(nextAgeMin, defaultAgeMax),
      maxDistanceKm: clearDistance ? null : maxDistanceKm ?? this.maxDistanceKm,
      gender: gender ?? this.gender,
      relationshipGoal: clearRelationshipGoal
          ? null
          : relationshipGoal ?? this.relationshipGoal,
    );
  }
}

/// 유저 프로필 모델 (M2.5 확장).
///
/// Firestore는 `Map<String, dynamic>`으로 데이터를 주고받는다.
/// 모델로 감싸면 키 오타나 타입 실수를 컴파일 타임에 잡을 수 있고
/// 직렬화 로직이 한 곳에 모인다.
///
/// AI 매칭 대비 설계:
/// - 태그는 영문 key로 저장 (label이 바뀌어도 매칭 로직 안전).
/// - 배열 필드(interests 등)는 항상 배열 타입 보장 (array-contains 쿼리 일관성).
/// - personaVector 자리만 미리 마련 (2차 페르소나 매칭 때 채운다).
class UserProfile {
  final String uid;
  final String displayName;
  final DateTime birthDate; // 시간 제외 날짜만. 향후 사주 기능에서 시간 추가 예정.
  final String gender; // 매칭 필터 키: "male" | "female" | "other"
  final String bio;

  // photoUrls[0] = 메인 사진. 최대 4장(메인 1 + 일상 3).
  final List<String> photoUrls;
  final DateTime createdAt;
  final DateTime updatedAt;

  // ── M2.5 상세 정보 (모두 nullable — 기존 유저 문서 호환) ──────────────────
  final int? height; // cm
  final String?
  religion; // key: "none" | "protestant" | "catholic" | "buddhism" | "other"
  final String?
  smoking; // key: "non_smoker" | "trying_to_quit" | "occasionally" | "vaping" | "daily"
  final String?
  drinking; // key: "non_drinker" | "rarely" | "occasionally" | "socially" | "frequently"
  final String? jobCategory; // 직업 카테고리 key (정규화, 매칭/필터용)
  final String? jobTitle; // 세부 직업명 (자유 입력, 표시용)
  final String?
  education; // key: "high_school" | "university" | "graduate" | "other"
  final String? mbti; // "ISTJ" ~ "ENTJ" 16개

  // ── M2.5 태그 (항상 배열 — null 없이 빈 리스트로 기본값) ─────────────────
  // Firestore key 목록으로 저장. UI 표시는 ProfileOptions.keyToLabel() 사용.
  final List<String> interests; // 관심사 key 목록 (최대 8)
  final List<String> personalityTags; // 성향 key 목록 (최대 8)
  final List<String> idealTags; // 이상형 key 목록 (최대 8)
  final String? relationshipGoal; // 찾는 관계 key (단일 선택)

  // ── AI 매칭 대비 — 이번 마일스톤은 빈 자리 예약. 2차 페르소나 매칭 때 채운다. ──
  final List<double>? personaVector;

  // ── 위치 기반 디스커버리 — 없으면 거리 표시/거리순 정렬에서 제외한다. ──
  final UserLocation? location;

  // ── 신뢰도 표시용 인증 상태 — 기존 유저 문서는 모두 false로 기본 처리. ──
  final VerificationStatus verifications;

  // ── 디스커버리 필터 설정 — 없으면 기본값으로 처리한다. ──
  final DiscoveryFilter discoveryFilter;

  // ── 목업 가상재화/수익화 상태 — 기존 유저 문서는 기본값으로 안전 처리. ──
  final int jelly;
  final DateTime? boostUntil;
  final bool likesUnlocked;

  const UserProfile({
    required this.uid,
    required this.displayName,
    required this.birthDate,
    required this.gender,
    required this.bio,
    this.photoUrls = const [],
    required this.createdAt,
    required this.updatedAt,
    this.height,
    this.religion,
    this.smoking,
    this.drinking,
    this.jobCategory,
    this.jobTitle,
    this.education,
    this.mbti,
    this.interests = const [],
    this.personalityTags = const [],
    this.idealTags = const [],
    this.relationshipGoal,
    this.personaVector,
    this.location,
    this.verifications = const VerificationStatus(),
    this.discoveryFilter = const DiscoveryFilter(),
    this.jelly = 0,
    this.boostUntil,
    this.likesUnlocked = false,
  });

  /// 프로필 완성도(0~100). 새 Firestore 필드 없이 기존 데이터만으로 계산한다.
  ///
  /// 사진 4장(최대) + 상세정보 7개 항목 + 태그 3종 + 관계목표 1개를
  /// 동일 가중치로 채점한다. 온보딩 필수 항목(이름/생년월일/성별/기본 태그 등)은
  /// 항상 채워져 있어 점수에 넣지 않는다 — 선택 항목을 더 채울수록 오르는
  /// 지표로만 쓴다.
  int get completenessPercent {
    var filled = 0;
    const total = 4 + 7 + 3 + 1;

    filled += photoUrls.length.clamp(0, 4);

    final detailFields = [
      height,
      religion,
      smoking,
      drinking,
      jobCategory,
      education,
      mbti,
    ];
    filled += detailFields.where((field) => field != null).length;

    if (interests.isNotEmpty) filled++;
    if (personalityTags.isNotEmpty) filled++;
    if (idealTags.isNotEmpty) filled++;

    if (relationshipGoal != null) filled++;

    return ((filled / total) * 100).round().clamp(0, 100);
  }

  /// 기준일([referenceDate]) 시점의 만 나이를 계산한다.
  ///
  /// 생일이 아직 지나지 않았으면 1을 뺀다. 월/일 비교만 하므로 새 DateTime을
  /// 만들지 않고, 2월 29일 생일도 예외 없이 처리된다(비윤년에는 3월 1일부터
  /// 생일이 지난 것으로 본다). 테스트에서 기준일을 주입할 수 있도록
  /// [age] getter와 분리했다.
  int ageAt(DateTime referenceDate) {
    int years = referenceDate.year - birthDate.year;
    final hadBirthday =
        (referenceDate.month > birthDate.month) ||
        (referenceDate.month == birthDate.month &&
            referenceDate.day >= birthDate.day);
    if (!hadBirthday) years--;
    return years;
  }

  /// 생년월일로 현재 나이를 계산한다. 생일이 아직 안 지났으면 1을 뺀다.
  int get age => ageAt(DateTime.now());

  /// Firestore 문서 → UserProfile.
  ///
  /// 신규 필드가 없는 기존 문서도 안전하게 읽도록
  /// 모든 필드에 null 가드와 기본값을 적용한다.
  factory UserProfile.fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final d = doc.data() ?? <String, dynamic>{};
    return UserProfile(
      uid: doc.id,
      displayName: d['displayName'] as String? ?? '',
      birthDate: (d['birthDate'] as Timestamp?)?.toDate() ?? DateTime(2000),
      gender: d['gender'] as String? ?? 'other',
      bio: d['bio'] as String? ?? '',
      photoUrls: (d['photoUrls'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
      createdAt: (d['createdAt'] as Timestamp?)?.toDate() ?? DateTime(1970),
      updatedAt: (d['updatedAt'] as Timestamp?)?.toDate() ?? DateTime(1970),
      // M2.5 신규 필드 — 문서에 없으면 null/빈 배열로 기본값
      height: d['height'] as int?,
      religion: d['religion'] as String?,
      smoking: d['smoking'] as String?,
      drinking: d['drinking'] as String?,
      jobCategory: d['jobCategory'] as String?,
      // 기존 문서의 job 필드를 jobTitle로 폴백 (기존 유저 호환)
      jobTitle: (d['jobTitle'] as String?) ?? (d['job'] as String?),
      education: d['education'] as String?,
      mbti: d['mbti'] as String?,
      interests: (d['interests'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
      personalityTags: (d['personalityTags'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
      idealTags: (d['idealTags'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
      relationshipGoal: d['relationshipGoal'] as String?,
      personaVector: (d['personaVector'] as List<dynamic>?)
          ?.map((e) => (e as num).toDouble())
          .toList(),
      location: d['location'] is Map
          ? UserLocation.fromMap(
              Map<String, dynamic>.from(d['location'] as Map),
            )
          : null,
      verifications: VerificationStatus.fromMap(
        d['verifications'] is Map
            ? Map<String, dynamic>.from(d['verifications'] as Map)
            : null,
      ),
      discoveryFilter: DiscoveryFilter.fromMap(
        d['discoveryFilter'] is Map
            ? Map<String, dynamic>.from(d['discoveryFilter'] as Map)
            : null,
      ),
      jelly: (d['jelly'] as num?)?.toInt() ?? 0,
      boostUntil: (d['boostUntil'] as Timestamp?)?.toDate(),
      likesUnlocked: d['likesUnlocked'] == true,
    );
  }

  /// UserProfile → Firestore에 저장할 Map.
  ///
  /// uid는 문서 ID이므로 본문에 포함하지 않는다.
  /// 배열 필드는 null이 아닌 빈 배열로 저장해 array-contains 쿼리 일관성을 보장한다.
  Map<String, dynamic> toFirestore() {
    return {
      'displayName': displayName,
      'birthDate': Timestamp.fromDate(birthDate),
      'gender': gender,
      'bio': bio,
      'photoUrls': photoUrls,
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': Timestamp.fromDate(updatedAt),
      // nullable 필드: null이면 명시적으로 null 저장 (필드 존재 자체는 보장)
      'height': height,
      'religion': religion,
      'smoking': smoking,
      'drinking': drinking,
      'jobCategory': jobCategory,
      'jobTitle': jobTitle,
      'education': education,
      'mbti': mbti,
      // 배열은 항상 배열 타입 (null 없음)
      'interests': interests,
      'personalityTags': personalityTags,
      'idealTags': idealTags,
      'relationshipGoal': relationshipGoal,
      // 아직 쓰지 않는 벡터는 값이 있을 때만 저장
      if (personaVector != null) 'personaVector': personaVector,
      // 위치는 허용한 유저만 저장한다. 없으면 기존 문서 호환을 위해 생략한다.
      if (location != null) 'location': location!.toFirestore(),
      'verifications': verifications.toFirestore(),
      'discoveryFilter': discoveryFilter.toFirestore(),
      'jelly': jelly,
      if (boostUntil != null) 'boostUntil': Timestamp.fromDate(boostUntil!),
      'likesUnlocked': likesUnlocked,
    };
  }

  /// 일부 필드만 바꾼 새 인스턴스를 반환한다 (불변 객체 갱신 패턴).
  ///
  /// nullable 필드(height 등)는 null을 전달하면 "변경 안 함"으로 처리된다.
  /// 명시적으로 null로 초기화하려면 새 UserProfile을 직접 생성하라.
  UserProfile copyWith({
    String? displayName,
    DateTime? birthDate,
    String? gender,
    String? bio,
    List<String>? photoUrls,
    DateTime? updatedAt,
    int? height,
    String? religion,
    String? smoking,
    String? drinking,
    String? jobCategory,
    String? jobTitle,
    String? education,
    String? mbti,
    List<String>? interests,
    List<String>? personalityTags,
    List<String>? idealTags,
    String? relationshipGoal,
    List<double>? personaVector,
    UserLocation? location,
    VerificationStatus? verifications,
    DiscoveryFilter? discoveryFilter,
    int? jelly,
    DateTime? boostUntil,
    bool? clearBoostUntil,
    bool? likesUnlocked,
  }) {
    return UserProfile(
      uid: uid,
      displayName: displayName ?? this.displayName,
      birthDate: birthDate ?? this.birthDate,
      gender: gender ?? this.gender,
      bio: bio ?? this.bio,
      photoUrls: photoUrls ?? this.photoUrls,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      height: height ?? this.height,
      religion: religion ?? this.religion,
      smoking: smoking ?? this.smoking,
      drinking: drinking ?? this.drinking,
      jobCategory: jobCategory ?? this.jobCategory,
      jobTitle: jobTitle ?? this.jobTitle,
      education: education ?? this.education,
      mbti: mbti ?? this.mbti,
      interests: interests ?? this.interests,
      personalityTags: personalityTags ?? this.personalityTags,
      idealTags: idealTags ?? this.idealTags,
      relationshipGoal: relationshipGoal ?? this.relationshipGoal,
      personaVector: personaVector ?? this.personaVector,
      location: location ?? this.location,
      verifications: verifications ?? this.verifications,
      discoveryFilter: discoveryFilter ?? this.discoveryFilter,
      jelly: jelly ?? this.jelly,
      boostUntil: clearBoostUntil == true
          ? null
          : boostUntil ?? this.boostUntil,
      likesUnlocked: likesUnlocked ?? this.likesUnlocked,
    );
  }
}
