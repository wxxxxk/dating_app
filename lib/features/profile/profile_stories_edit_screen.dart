import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/constants/profile_story_prompts.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/text_sanitizer.dart';
import '../../models/profile_story.dart';
import '../../shared/widgets/premium_components.dart';
import '../../shared/widgets/primary_button.dart';

/// 사용자 작성형 이야기 카드 전용 편집 화면 — Editorial Story Composer.
///
/// Firestore/Auth/Storage/Functions에 의존하지 않는 순수 UI 화면이다. 부모가
/// 넘겨준 story 목록을 로컬에서만 편집하고, 완료 시 `Navigator.pop`으로
/// 정규화된 `List<ProfileStory>`를 반환한다. 반복되는 카드 대신 하나의
/// 인터뷰 편집 surface와 질문 선택 surface로 정리한다.
class ProfileStoriesEditScreen extends StatefulWidget {
  final List<ProfileStory> initialStories;

  const ProfileStoriesEditScreen({super.key, required this.initialStories});

  @override
  State<ProfileStoriesEditScreen> createState() =>
      _ProfileStoriesEditScreenState();
}

class _ProfileStoriesEditScreenState extends State<ProfileStoriesEditScreen> {
  late final List<ProfileStory> _stories;
  final Map<String, TextEditingController> _controllers = {};

  @override
  void initState() {
    super.initState();
    _stories = _normalizeInitialStories(widget.initialStories);
    for (final story in _stories) {
      if (ProfileStoryPrompts.isValidKey(story.promptKey)) {
        _controllers[story.promptKey] = TextEditingController(
          text: story.answer,
        );
      }
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  List<ProfileStory> _normalizeInitialStories(List<ProfileStory> raw) {
    final result = <ProfileStory>[];
    final seenPromptKeys = <String>{};
    for (final story in List<ProfileStory>.from(raw)) {
      if (story.promptKey.isEmpty || story.answer.isEmpty) continue;
      if (seenPromptKeys.contains(story.promptKey)) continue;
      seenPromptKeys.add(story.promptKey);
      result.add(story);
      if (result.length >= ProfileStoryPrompts.maxStories) break;
    }
    return result;
  }

  int get _slotCount => _stories.length;

  bool get _hasUnknownStories {
    return _stories.any(
      (story) => !ProfileStoryPrompts.isValidKey(story.promptKey),
    );
  }

  Set<String> get _selectedKnownPromptKeys {
    return _stories
        .where((story) => ProfileStoryPrompts.isValidKey(story.promptKey))
        .map((story) => story.promptKey)
        .toSet();
  }

  void _addPrompt(ProfileStoryPrompt prompt) {
    if (_slotCount >= ProfileStoryPrompts.maxStories) return;
    if (_selectedKnownPromptKeys.contains(prompt.key)) return;
    setState(() {
      _stories.add(ProfileStory(promptKey: prompt.key, answer: ''));
      _controllers[prompt.key] = TextEditingController();
    });
  }

  void _removePrompt(String promptKey) {
    setState(() {
      _stories.removeWhere((story) => story.promptKey == promptKey);
      _controllers.remove(promptKey)?.dispose();
    });
  }

  String _sanitizeAnswer(String value) {
    final withoutControls = value.replaceAll(
      RegExp(r'[\u0000-\u0009\u000B-\u001F\u007F]'),
      '',
    );
    final sanitized = stripEmoji(withoutControls);
    return sanitized.length > ProfileStoryPrompts.maxAnswerLength
        ? sanitized.substring(0, ProfileStoryPrompts.maxAnswerLength)
        : sanitized;
  }

  void _onDone() {
    final result = <ProfileStory>[];
    final seenPromptKeys = <String>{};

    for (final story in _stories) {
      if (seenPromptKeys.contains(story.promptKey)) continue;
      seenPromptKeys.add(story.promptKey);

      if (!ProfileStoryPrompts.isValidKey(story.promptKey)) {
        result.add(story);
      } else {
        final answer = _sanitizeAnswer(
          _controllers[story.promptKey]?.text ?? '',
        );
        if (answer.isEmpty) continue;
        result.add(ProfileStory(promptKey: story.promptKey, answer: answer));
      }

      if (result.length >= ProfileStoryPrompts.maxStories) break;
    }

    Navigator.pop(context, List<ProfileStory>.unmodifiable(result));
  }

  @override
  Widget build(BuildContext context) {
    final selectedKeys = _selectedKnownPromptKeys;
    final editableStories = _stories
        .where((story) => ProfileStoryPrompts.isValidKey(story.promptKey))
        .toList();
    final availablePrompts = ProfileStoryPrompts.all
        .where((prompt) => !selectedKeys.contains(prompt.key))
        .toList();
    final canAddMore = _slotCount < ProfileStoryPrompts.maxStories;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text(
          '나의 이야기',
          style: TextStyle(
            fontSize: 21,
            fontWeight: FontWeight.w800,
            color: AppColors.textStrong,
            letterSpacing: -0.2,
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        backgroundColor: AppColors.background,
        foregroundColor: AppColors.textStrong,
        elevation: 0,
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                children: [
                  const Text(
                    '나를 더 잘 보여주는 질문을 골라 짧게 답해보세요.\n'
                    '답변은 상대 프로필에 공개돼요.',
                    style: TextStyle(
                      fontSize: 13,
                      color: AppColors.textMuted,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const PremiumNoticeCard(
                    icon: Icons.privacy_tip_outlined,
                    title: '안전 안내',
                    description: '연락처나 SNS 계정은 매칭 후에 공유해주세요.',
                  ),
                  const SizedBox(height: 14),
                  _ComposerProgress(
                    slotCount: _slotCount,
                    atMax: _slotCount >= ProfileStoryPrompts.maxStories,
                    hasUnknown: _hasUnknownStories,
                  ),
                  const SizedBox(height: 16),
                  // 편집 항목·질문은 ListView의 개별 child로 둔다(lazy build 유지).
                  // 하나의 Container로 묶으면 스크롤·hit test 위치가 어긋난다.
                  for (final story in editableStories) ...[
                    _StoryComposerItem(
                      promptKey: story.promptKey,
                      controller: _controllers[story.promptKey]!,
                      onRemove: () => _removePrompt(story.promptKey),
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (availablePrompts.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    const Text(
                      '질문 선택',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: AppColors.textStrong,
                      ),
                    ),
                    const SizedBox(height: 10),
                    for (final prompt in availablePrompts) ...[
                      _PromptOptionRow(
                        prompt: prompt,
                        enabled: canAddMore,
                        onTap: () => _addPrompt(prompt),
                      ),
                      const SizedBox(height: 8),
                    ],
                  ],
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                20,
                8,
                20,
                12 + MediaQuery.of(context).padding.bottom,
              ),
              child: PrimaryButton(
                key: const ValueKey('profile-stories-done'),
                label: '완료',
                onPressed: _onDone,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 작성 현황 + 최대/보존 안내를 한 묶음으로 담는 compact 헤더.
class _ComposerProgress extends StatelessWidget {
  final int slotCount;
  final bool atMax;
  final bool hasUnknown;

  const _ComposerProgress({
    required this.slotCount,
    required this.atMax,
    required this.hasUnknown,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$slotCount / ${ProfileStoryPrompts.maxStories} 카드',
          key: const ValueKey('profile-stories-progress'),
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w800,
            color: AppColors.mintDeep,
          ),
        ),
        if (atMax) ...[
          const SizedBox(height: 6),
          const Text(
            '이야기 카드는 최대 3개까지 작성할 수 있어요.',
            style: TextStyle(fontSize: 12, color: AppColors.textMuted),
          ),
        ],
        if (hasUnknown) ...[
          const SizedBox(height: 6),
          const Text(
            '현재 앱에서 편집할 수 없는 이야기 카드가 유지되고 있어요.',
            style: TextStyle(fontSize: 12, color: AppColors.textMuted),
          ),
        ],
      ],
    );
  }
}

/// 인터뷰 편집 항목 — prompt label + 답변 입력 + 삭제. 밝은 흰 표면 위에
/// 하나의 이야기 편집 단위를 담는다.
class _StoryComposerItem extends StatelessWidget {
  final String promptKey;
  final TextEditingController controller;
  final VoidCallback onRemove;

  const _StoryComposerItem({
    required this.promptKey,
    required this.controller,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final label = ProfileStoryPrompts.labelFor(promptKey) ?? '';
    return Container(
      key: ValueKey('profile-story-card-$promptKey'),
      decoration: BoxDecoration(
        color: AppColors.surfacePrimary,
        borderRadius: BorderRadius.circular(AppRadius.surface),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: AppColors.expressiveAccent,
                    height: 1.3,
                  ),
                ),
              ),
              IconButton(
                key: ValueKey('profile-story-remove-$promptKey'),
                tooltip: '삭제',
                icon: const Icon(Icons.close_rounded, size: 20),
                color: AppColors.textMuted,
                visualDensity: VisualDensity.compact,
                onPressed: onRemove,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextField(
              key: ValueKey('profile-story-answer-$promptKey'),
              controller: controller,
              minLines: 1,
              maxLines: 3,
              maxLength: ProfileStoryPrompts.maxAnswerLength,
              style: const TextStyle(
                fontSize: 14.5,
                height: 1.45,
                color: AppColors.textStrong,
              ),
              inputFormatters: [
                LengthLimitingTextInputFormatter(
                  ProfileStoryPrompts.maxAnswerLength,
                ),
              ],
              decoration: InputDecoration(
                hintText: '짧게 답변을 적어주세요',
                counterText: '',
                isDense: true,
                filled: true,
                fillColor: AppColors.surfaceSecondary,
                hintStyle: const TextStyle(
                  fontSize: 14,
                  color: AppColors.textMuted,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.control),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.control),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.control),
                  borderSide: const BorderSide(
                    color: AppColors.mint,
                    width: 1.6,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 남은 질문 한 줄 — 전체 tap으로 이야기 카드에 추가한다. 밝은 흰 표면 위에
/// 얇은 보더로 담아 질문 목록이 하나의 흐름으로 읽히게 한다.
class _PromptOptionRow extends StatelessWidget {
  final ProfileStoryPrompt prompt;
  final bool enabled;
  final VoidCallback onTap;

  const _PromptOptionRow({
    required this.prompt,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: ValueKey('profile-story-prompt-${prompt.key}'),
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(AppRadius.surface),
      child: AnimatedOpacity(
        duration: AppDurations.fast,
        opacity: enabled ? 1 : 0.45,
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.surfacePrimary,
            borderRadius: BorderRadius.circular(AppRadius.surface),
            border: Border.all(color: AppColors.borderSubtle),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  prompt.label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textStrong,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.add_circle_outline_rounded,
                size: 20,
                color: enabled ? AppColors.mintDeep : AppColors.textMuted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
