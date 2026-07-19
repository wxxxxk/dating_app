import '../core/constants/profile_story_prompts.dart';

/// 이야기 카드(프로필 스토리) 한 장.
///
/// 사용자가 고른 프롬프트 [promptKey]와 직접 작성한 [answer]로 구성된다.
/// prompt label(질문 문구)은 저장하지 않는다 — 표시할 때 카탈로그
/// ([ProfileStoryPrompts.labelFor])에서 찾는다. AI나 문장 생성 로직은 없다.
class ProfileStory {
  final String promptKey;
  final String answer;

  const ProfileStory({required this.promptKey, required this.answer});

  /// Firestore 저장용 map. label/createdAt/ID 등 부가 필드는 넣지 않는다.
  Map<String, dynamic> toMap() => {'promptKey': promptKey, 'answer': answer};

  /// Firestore 원시 값에서 방어적으로 복원한다. 유효하지 않으면 null.
  ///
  /// - map이 아니면 null
  /// - promptKey가 String이 아니거나 비어 있으면 null
  /// - answer가 String이 아니거나 비어 있으면 null
  /// - unknown promptKey(카탈로그에 없는 key)는 여기서 거르지 않고 보존한다 —
  ///   유효성 검증은 UI·Rules의 책임이며, 카탈로그가 바뀌어도 기존 저장
  ///   데이터를 이 저수준 parser가 손실시키지 않도록 하기 위함이다.
  /// - 원본 map 참조는 보관하지 않는다(필드만 복사).
  static ProfileStory? tryFromMap(Object? raw) {
    if (raw is! Map) return null;
    final promptKey = raw['promptKey'];
    final answer = raw['answer'];
    if (promptKey is! String || promptKey.isEmpty) return null;
    if (answer is! String || answer.isEmpty) return null;
    return ProfileStory(promptKey: promptKey, answer: answer);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ProfileStory &&
          other.promptKey == promptKey &&
          other.answer == answer);

  @override
  int get hashCode => Object.hash(promptKey, answer);

  @override
  String toString() => 'ProfileStory(promptKey: $promptKey, answer: $answer)';
}

/// Firestore 원시 값을 안전한 `List<ProfileStory>`로 정규화한다.
///
/// UserProfile과 PublicProfile이 공유하는 단일 parsing 동작이다.
/// - list가 아니거나 null이면 빈 리스트
/// - malformed entry는 개별 제외(전체 프로필 parsing이 실패하지 않는다)
/// - 같은 promptKey가 여러 번 나오면 첫 유효 항목만 유지(first-wins)
/// - 최대 [ProfileStoryPrompts.maxStories]개까지만 유지
/// - 입력 순서 유지, unknown promptKey도 구조가 정상이면 보존
/// - 반환 리스트는 외부에서 수정할 수 없는 unmodifiable
/// - 원본 Firestore list/map은 변경하지 않는다
List<ProfileStory> normalizeProfileStories(Object? raw) {
  if (raw is! List) return const <ProfileStory>[];
  final result = <ProfileStory>[];
  final seenPromptKeys = <String>{};
  for (final entry in raw) {
    final story = ProfileStory.tryFromMap(entry);
    if (story == null) continue;
    if (seenPromptKeys.contains(story.promptKey)) continue;
    seenPromptKeys.add(story.promptKey);
    result.add(story);
    if (result.length >= ProfileStoryPrompts.maxStories) break;
  }
  return List<ProfileStory>.unmodifiable(result);
}
