// 이야기 카드(프로필 스토리) 프롬프트 카탈로그.
//
// 사용자가 고정 프롬프트 중 최대 3개를 골라 짧은 자유 답변을 작성하는
// "이야기 카드"의 질문 세트다. 가치관(ValueQuestions)과 동일한 설계 원칙을
// 따른다:
// - Firestore에는 안정적인 영문 key(promptKey)와 사용자가 작성한 answer만
//   저장한다. label(질문 문구)은 저장하지 않는다.
// - UI에는 label을 표시한다. label(한글)이 바뀌어도 key는 유지된다.
// - users/{uid}.profileStories와 publicProfiles/{uid}.profileStories,
//   Rules가 모두 이 카탈로그의 key를 계약으로 공유한다.
//
// 이번 단계(Phase 1-2-B)에서는 카탈로그·모델·직렬화·Rules 계약까지만 다룬다.
// 입력 UI와 상대 프로필 표시 UI는 다음 단계에서 진행한다.

/// 이야기 카드 프롬프트 하나.
///
/// [key]   Firestore 저장용 promptKey. 영문 snake_case로 절대 바꾸지 않는다.
/// [label] UI 표시용 질문 문구. 기획 변경 시 여기만 수정한다.
class ProfileStoryPrompt {
  final String key;
  final String label;

  const ProfileStoryPrompt({required this.key, required this.label});
}

/// 이야기 카드 프롬프트 카탈로그 컨테이너.
///
/// 인스턴스를 만들 수 없는 상수 모음이다. 조회 함수는 알 수 없는 key에서
/// 예외를 던지지 않고 null 또는 false를 반환한다 — 카탈로그가 바뀌어도
/// 기존 저장 데이터를 읽다가 앱이 깨지지 않게 하기 위함이다.
class ProfileStoryPrompts {
  ProfileStoryPrompts._();

  /// 사용자가 노출할 수 있는 이야기 카드 최대 개수.
  static const int maxStories = 3;

  /// 답변 최대 길이(글자 수). 최소 길이는 1자.
  static const int maxAnswerLength = 100;

  /// 확정 프롬프트 세트(8개). 순서가 선택 화면 기본 순서다.
  static const List<ProfileStoryPrompt> all = [
    ProfileStoryPrompt(key: 'happy_moment', label: '요즘 가장 행복한 순간은?'),
    ProfileStoryPrompt(key: 'weekend', label: '완벽한 주말을 보낸다면?'),
    ProfileStoryPrompt(key: 'get_closer', label: '나와 가까워지는 가장 좋은 방법은?'),
    ProfileStoryPrompt(key: 'into_lately', label: '요즘 푹 빠져 있는 것은?'),
    ProfileStoryPrompt(key: 'comfort_food', label: '기분 좋아지는 음식은?'),
    ProfileStoryPrompt(key: 'travel_style', label: '함께라면 이런 여행'),
    ProfileStoryPrompt(key: 'small_happiness', label: '나를 웃게 하는 사소한 것'),
    ProfileStoryPrompt(key: 'date_idea', label: '같이 해보고 싶은 데이트'),
  ];

  /// promptKey로 프롬프트를 찾는다. 없으면 null.
  static ProfileStoryPrompt? byKey(String key) {
    for (final prompt in all) {
      if (prompt.key == key) return prompt;
    }
    return null;
  }

  /// promptKey에 해당하는 표시용 질문 문구. 없으면 null.
  static String? labelFor(String key) => byKey(key)?.label;

  /// 해당 promptKey가 카탈로그에 존재하는 유효한 key인지.
  static bool isValidKey(String key) => byKey(key) != null;
}
