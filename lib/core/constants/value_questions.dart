// 가치관 질문 카탈로그.
//
// 연애·관계에서 중요하게 여기는 기준을 단일 선택으로 표현하게 하는 고정
// 질문 세트다. 태그(ProfileOptions)와 동일한 설계 원칙을 따른다:
// - Firestore에는 안정적인 영문 key(question key / answer key)만 저장한다.
// - UI에는 label을 표시한다. label(한글)이 바뀌어도 key(매칭·AI 입력값)는 유지된다.
// - 향후 users/{uid}.valueAnswers(Map<questionKey, answerKey>)와 publicProfiles,
//   AI 프롬프트가 모두 이 카탈로그의 key를 계약으로 공유한다.
//
// 이번 단계(Phase 1-1-B)에서는 카탈로그 정의와 UserProfile 읽기 계약까지만
// 다룬다. 실제 쓰기/공개/Rules 활성화는 다음 단계에서 진행한다.

/// 가치관 질문의 선택지 하나.
///
/// [key]   Firestore 저장용 answer key. 영문 snake_case로 절대 바꾸지 않는다.
/// [label] UI 표시용. 기획 변경 시 여기만 수정한다.
class ValueOption {
  final String key;
  final String label;

  const ValueOption({required this.key, required this.label});
}

/// 가치관 질문 하나.
///
/// [key]          Firestore 저장용 question key. 절대 바꾸지 않는다.
/// [prompt]       사용자에게 보이는 질문 문구.
/// [profileLabel] 프로필에서 답변 앞에 붙는 짧은 라벨.
/// [options]      단일 선택 선택지 목록.
class ValueQuestion {
  final String key;
  final String prompt;
  final String profileLabel;
  final List<ValueOption> options;

  const ValueQuestion({
    required this.key,
    required this.prompt,
    required this.profileLabel,
    required this.options,
  });
}

/// 가치관 질문 카탈로그 컨테이너.
///
/// 인스턴스를 만들 수 없는 상수 모음이다. 조회 함수는 알 수 없는 key에서
/// 예외를 던지지 않고 null 또는 false를 반환한다 — 카탈로그가 바뀌어도
/// 기존 저장 데이터를 읽다가 앱이 깨지지 않게 하기 위함이다.
class ValueQuestions {
  ValueQuestions._();

  /// 확정 질문 세트(6문항, 각 3~5개 선택지, 단일 선택).
  static const List<ValueQuestion> all = [
    ValueQuestion(
      key: 'contact_frequency',
      prompt: '연인과 연락은 얼마나 자주 하고 싶나요?',
      profileLabel: '연락 빈도',
      options: [
        ValueOption(key: 'all_day', label: '틈날 때마다 자주'),
        ValueOption(key: 'few_times', label: '하루에 몇 번'),
        ValueOption(key: 'once_a_day', label: '하루 한 번쯤'),
        ValueOption(key: 'when_needed', label: '필요할 때 편하게'),
      ],
    ),
    ValueQuestion(
      key: 'conflict_style',
      prompt: '갈등이 생기면 어떻게 푸는 편인가요?',
      profileLabel: '갈등 해결',
      options: [
        ValueOption(key: 'talk_now', label: '바로 대화로 풀기'),
        ValueOption(key: 'cool_down', label: '진정한 뒤 대화하기'),
        ValueOption(key: 'text_first', label: '글로 먼저 정리하기'),
        ValueOption(key: 'soften', label: '분위기를 풀고 천천히 대화하기'),
      ],
    ),
    ValueQuestion(
      key: 'date_style',
      prompt: '어떤 데이트를 더 좋아하나요?',
      profileLabel: '데이트 스타일',
      options: [
        ValueOption(key: 'active', label: '활동적인 야외 데이트'),
        ValueOption(key: 'cozy', label: '편안한 실내 데이트'),
        ValueOption(key: 'foodie', label: '맛집 탐방'),
        ValueOption(key: 'culture', label: '전시·공연 관람'),
      ],
    ),
    ValueQuestion(
      key: 'alone_time',
      prompt: '혼자만의 시간은 얼마나 필요한가요?',
      profileLabel: '혼자만의 시간',
      options: [
        ValueOption(key: 'a_lot', label: '많이 필요한 편'),
        ValueOption(key: 'some', label: '어느 정도 필요'),
        ValueOption(key: 'little', label: '조금만 있으면 충분'),
        ValueOption(key: 'together', label: '대부분 함께하고 싶음'),
      ],
    ),
    ValueQuestion(
      key: 'affection_expression',
      prompt: '애정은 주로 어떻게 표현하나요?',
      profileLabel: '표현 방식',
      options: [
        ValueOption(key: 'words', label: '말로 표현하기'),
        ValueOption(key: 'actions', label: '챙김과 행동으로'),
        ValueOption(key: 'gifts', label: '선물과 이벤트로'),
        ValueOption(key: 'time', label: '함께하는 시간으로'),
      ],
    ),
    ValueQuestion(
      key: 'life_rhythm',
      prompt: '생활 리듬은 어느 쪽에 가깝나요?',
      profileLabel: '생활 리듬',
      options: [
        ValueOption(key: 'morning', label: '아침형'),
        ValueOption(key: 'night', label: '저녁형'),
        ValueOption(key: 'flexible', label: '일정에 따라 유동적'),
      ],
    ),
  ];

  /// question key로 질문을 찾는다. 없으면 null.
  static ValueQuestion? byKey(String questionKey) {
    for (final question in all) {
      if (question.key == questionKey) return question;
    }
    return null;
  }

  /// (question key, answer key)로 선택지를 찾는다. 없으면 null.
  static ValueOption? optionByKey(String questionKey, String answerKey) {
    final question = byKey(questionKey);
    if (question == null) return null;
    for (final option in question.options) {
      if (option.key == answerKey) return option;
    }
    return null;
  }

  /// (question key, answer key)에 해당하는 표시용 라벨. 없으면 null.
  static String? answerLabel(String questionKey, String answerKey) {
    return optionByKey(questionKey, answerKey)?.label;
  }

  /// 해당 조합이 카탈로그에 존재하는 유효한 답변인지.
  static bool isValidAnswer(String questionKey, String answerKey) {
    return optionByKey(questionKey, answerKey) != null;
  }
}
