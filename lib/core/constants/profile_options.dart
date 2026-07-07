// 프로필 선택 옵션 상수 모음.
//
// AI 매칭 대비 설계 원칙:
// - Firestore에는 안정적인 영문 key를 저장하고, UI에는 label을 표시한다.
// - label(한글)이 바뀌어도 key(매칭 입력값)가 유지되어 AI 모델이 안정적이다.
// - key는 벡터화·유사도 계산·array-contains 쿼리에 직접 사용된다.

/// 태그 하나를 나타내는 불변 객체.
///
/// [key]   Firestore 저장용. 영문 snake_case로 절대 바꾸지 않는다.
/// [label] UI 표시용. 이모지·한글 포함 가능. 기획 변경 시 여기만 수정한다.
class TagOption {
  final String key;
  final String label;

  const TagOption({required this.key, required this.label});
}

class ProfileOptions {
  ProfileOptions._();

  // ===== 관심사 (interests) =====
  // 최대 8개 선택. 취미·라이프스타일 표현용.
  static const List<TagOption> interests = [
    TagOption(key: 'movie', label: '영화'),
    TagOption(key: 'netflix', label: '넷플릭스'),
    TagOption(key: 'drama_binge', label: '드라마 정주행'),
    TagOption(key: 'tv_variety', label: 'TV 예능'),
    TagOption(key: 'home_cafe', label: '홈카페'),
    TagOption(key: 'chatting', label: '수다'),
    TagOption(key: 'dancing', label: '댄스'),
    TagOption(key: 'spacing_out', label: '멍 때리기'),
    TagOption(key: 'cooking', label: '요리'),
    TagOption(key: 'baking', label: '베이킹'),
    TagOption(key: 'drawing', label: '그림 그리기'),
    TagOption(key: 'plants', label: '반려식물'),
    TagOption(key: 'knitting', label: '뜨개질'),
    TagOption(key: 'music_instrument', label: '악기 연주'),
    TagOption(key: 'photography', label: '사진 찍기'),
    TagOption(key: 'webtoon', label: '웹툰'),
    TagOption(key: 'saju_tarot', label: '사주/타로'),
    TagOption(key: 'makeup', label: '메이크업'),
    TagOption(key: 'nail_art', label: '네일아트'),
    TagOption(key: 'interior', label: '인테리어'),
    TagOption(key: 'ballet', label: '발레'),
    TagOption(key: 'cleaning', label: '청소'),
    TagOption(key: 'scuba_diving', label: '스쿠버다이빙'),
    TagOption(key: 'skateboard', label: '스케이트보드'),
    TagOption(key: 'sneaker_collect', label: '신발 수집'),
    TagOption(key: 'stocks', label: '주식'),
    TagOption(key: 'bitcoin', label: '비트코인'),
    TagOption(key: 'anime', label: '애니메이션'),
  ];

  // ===== 나를 표현하는 키워드 (성향 태그) =====
  // 자기 자신의 성격·스타일을 표현. 매칭 시 "나와 비슷한 사람" 계산에 활용.
  static const List<TagOption> personalities = [
    TagOption(key: 'petite', label: '아담한'),
    TagOption(key: 'dependable', label: '듬직한'),
    TagOption(key: 'cheerful', label: '잘 웃는'),
    TagOption(key: 'no_swearing', label: '욕 안하는'),
    TagOption(key: 'nice_voice', label: '목소리 좋은'),
    TagOption(key: 'initiates_talk', label: '먼저 말걸어주는'),
    TagOption(key: 'good_listener', label: '얘기를 잘 들어주는'),
    TagOption(key: 'stylish', label: '옷 잘입는'),
    TagOption(key: 'active', label: '활발한'),
    TagOption(key: 'quiet', label: '조용한'),
    TagOption(key: 'affectionate', label: '애교가 많은'),
    TagOption(key: 'mature', label: '어른스러운'),
    TagOption(key: 'passionate', label: '열정적인'),
    TagOption(key: 'calm', label: '차분한'),
    TagOption(key: 'quirky', label: '또라이 같은'),
    TagOption(key: 'polite', label: '예의 바른'),
    TagOption(key: 'witty', label: '재치있는'),
    TagOption(key: 'serious', label: '진지한'),
    TagOption(key: 'confident', label: '자신감 있는'),
    TagOption(key: 'humble', label: '허세 없는'),
    TagOption(key: 'whimsical', label: '엉뚱한'),
    TagOption(key: 'intellectual', label: '지적인'),
    TagOption(key: 'diligent', label: '성실한'),
    TagOption(key: 'free_spirited', label: '자유분방한'),
    TagOption(key: 'emotional', label: '감성적인'),
    TagOption(key: 'detail_oriented', label: '꼼꼼한'),
    TagOption(key: 'logical', label: '논리적인'),
    TagOption(key: 'spontaneous', label: '즉흥적인'),
    TagOption(key: 'sensitive', label: '섬세한'),
    TagOption(key: 'cool', label: '쿨한'),
    TagOption(key: 'responsible', label: '책임감이 강한'),
    TagOption(key: 'homebody', label: '집순이/집돌이'),
    TagOption(key: 'alpha', label: '상여자/상남자'),
    TagOption(key: 'loyal', label: '일편단심'),
  ];

  // ===== 이상형 태그 (idealTags) =====
  // "내가 선호하는 친구"를 설명. 매칭 시 상대방의 성향 태그와 교차 비교에 활용.
  static const List<TagOption> ideals = [
    TagOption(key: 'good_looking', label: '예쁘고 잘생긴'),
    TagOption(key: 'stylish', label: '옷 잘 입는'),
    TagOption(key: 'dependable', label: '듬직한'),
    TagOption(key: 'petite', label: '아담한'),
    TagOption(key: 'older', label: '연상'),
    TagOption(key: 'younger', label: '연하'),
    TagOption(key: 'same_age', label: '동갑'),
    TagOption(key: 'same_area', label: '같은 동네'),
    TagOption(key: 'near_work', label: '직장 근처'),
    TagOption(key: 'same_hobby', label: '취미가 같은'),
    TagOption(key: 'easy_to_talk', label: '말이 통하는'),
    TagOption(key: 'cheerful', label: '잘 웃는'),
    TagOption(key: 'no_swearing', label: '욕 안하는'),
    TagOption(key: 'nice_voice', label: '목소리 좋은'),
    TagOption(key: 'initiates_talk', label: '먼저 말걸어주는'),
    TagOption(key: 'good_listener', label: '얘기를 잘 들어주는'),
    TagOption(key: 'active', label: '활발한'),
    TagOption(key: 'quiet', label: '조용한'),
    TagOption(key: 'affectionate', label: '애교가 많은'),
    TagOption(key: 'mature', label: '어른스러운'),
    TagOption(key: 'passionate', label: '열정적인'),
    TagOption(key: 'calm', label: '차분한'),
    TagOption(key: 'quirky', label: '또라이 같은'),
    TagOption(key: 'polite', label: '예의 바른'),
    TagOption(key: 'witty', label: '재치있는'),
    TagOption(key: 'serious', label: '진지한'),
    TagOption(key: 'confident', label: '자신감 있는'),
    TagOption(key: 'humble', label: '허세 없는'),
    TagOption(key: 'whimsical', label: '엉뚱한'),
    TagOption(key: 'intellectual', label: '지적인'),
    TagOption(key: 'diligent', label: '성실한'),
    TagOption(key: 'free_spirited', label: '자유분방한'),
  ];

  // ===== 찾는 관계 (relationshipGoal) — 단일 선택 =====
  // 매칭 필터에서 "같은 목적의 사람끼리 우선 연결"에 사용.
  static const List<TagOption> relationshipGoals = [
    TagOption(key: 'casual_friend', label: '부담없는 동네 친구를 원해요'),
    TagOption(key: 'light_romance', label: '두근두근 썸타고 싶어요'),
    TagOption(key: 'serious_relationship', label: '진지한 연애를 시작하고 싶어요'),
    TagOption(key: 'open_to_anything', label: '정해두지 않고 느낌 가는대로'),
  ];

  // ===== 종교 =====
  static const List<TagOption> religions = [
    TagOption(key: 'none', label: '무교'),
    TagOption(key: 'protestant', label: '기독교'),
    TagOption(key: 'catholic', label: '천주교'),
    TagOption(key: 'buddhism', label: '불교'),
    TagOption(key: 'other', label: '기타'),
  ];

  // ===== 흡연 (5단계) =====
  // 기존 key(occasional_smoker, daily_smoker)는 저장 문서에 남을 수 있지만
  // keyToLabel()이 null을 반환하면 UI에서 자동으로 "선택" 상태로 표시되어 안전하다.
  static const List<TagOption> smokingOptions = [
    TagOption(key: 'non_smoker', label: '비흡연'),
    TagOption(key: 'trying_to_quit', label: '금연 중'),
    TagOption(key: 'occasionally', label: '가끔 피움'),
    TagOption(key: 'vaping', label: '전자담배'),
    TagOption(key: 'daily', label: '매일 피움'),
  ];

  // ===== 음주 (5단계) =====
  static const List<TagOption> drinkingOptions = [
    TagOption(key: 'non_drinker', label: '안 마심'),
    TagOption(key: 'rarely', label: '거의 안 마심'),
    TagOption(key: 'occasionally', label: '가끔 마심'),
    TagOption(key: 'socially', label: '어울릴 때 마심'),
    TagOption(key: 'frequently', label: '자주 마심'),
  ];

  // ===== 직업 카테고리 =====
  // jobCategory로 정규화된 key 저장. 세부 직업명(jobTitle)은 자유 입력으로 별도 저장.
  static const List<TagOption> jobCategoryOptions = [
    TagOption(key: 'student', label: '학생'),
    TagOption(key: 'soldier', label: '군인'),
    TagOption(key: 'education', label: '교육직'),
    TagOption(key: 'finance', label: '금융직'),
    TagOption(key: 'medical', label: '의료직'),
    TagOption(key: 'business_owner', label: '사업가'),
    TagOption(key: 'public_corp', label: '공기업'),
    TagOption(key: 'public_servant', label: '공무원'),
    TagOption(key: 'professional', label: '전문직'),
    TagOption(key: 'food_service', label: '요식업/외식업'),
    TagOption(key: 'service', label: '서비스업'),
    TagOption(key: 'self_employed', label: '자영업'),
    TagOption(key: 'freelancer', label: '프리랜서'),
    TagOption(key: 'it', label: 'IT 업계'),
    TagOption(key: 'research', label: '연구/기술직'),
    TagOption(key: 'construction', label: '건축/건설직'),
    TagOption(key: 'unemployed', label: '무직'),
    TagOption(key: 'etc', label: '기타'),
  ];

  // ===== 최종학력 =====
  static const List<TagOption> educationOptions = [
    TagOption(key: 'high_school', label: '고등학교'),
    TagOption(key: 'university', label: '대학교'),
    TagOption(key: 'graduate', label: '대학원'),
    TagOption(key: 'other', label: '기타'),
  ];

  // ===== MBTI =====
  static const List<TagOption> mbtiOptions = [
    TagOption(key: 'ISTJ', label: 'ISTJ'),
    TagOption(key: 'ISFJ', label: 'ISFJ'),
    TagOption(key: 'INFJ', label: 'INFJ'),
    TagOption(key: 'INTJ', label: 'INTJ'),
    TagOption(key: 'ISTP', label: 'ISTP'),
    TagOption(key: 'ISFP', label: 'ISFP'),
    TagOption(key: 'INFP', label: 'INFP'),
    TagOption(key: 'INTP', label: 'INTP'),
    TagOption(key: 'ESTP', label: 'ESTP'),
    TagOption(key: 'ESFP', label: 'ESFP'),
    TagOption(key: 'ENFP', label: 'ENFP'),
    TagOption(key: 'ENTP', label: 'ENTP'),
    TagOption(key: 'ESTJ', label: 'ESTJ'),
    TagOption(key: 'ESFJ', label: 'ESFJ'),
    TagOption(key: 'ENFJ', label: 'ENFJ'),
    TagOption(key: 'ENTJ', label: 'ENTJ'),
  ];

  /// key → label 변환. 없으면 null.
  ///
  /// 화면 표시 시 Firestore의 key를 한글 label로 바꿔야 할 때 쓴다.
  static String? keyToLabel(List<TagOption> options, String key) {
    for (final opt in options) {
      if (opt.key == key) return opt.label;
    }
    return null;
  }

  /// 여러 key → label 목록 변환. 없는 key는 건너뛴다.
  static List<String> keysToLabels(List<TagOption> options, List<String> keys) {
    return keys.map((k) => keyToLabel(options, k)).whereType<String>().toList();
  }
}
