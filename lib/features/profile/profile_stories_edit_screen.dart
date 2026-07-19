import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/constants/profile_story_prompts.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/text_sanitizer.dart';
import '../../models/profile_story.dart';
import '../../shared/widgets/premium_components.dart';
import '../../shared/widgets/primary_button.dart';

/// 사용자 작성형 이야기 카드 전용 편집 화면.
///
/// Firestore/Auth/Storage/Functions에 의존하지 않는 순수 UI 화면이다. 부모가
/// 넘겨준 story 목록을 로컬에서만 편집하고, 완료 시 `Navigator.pop`으로
/// 정규화된 `List<ProfileStory>`를 반환한다.
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('나의 이야기'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        backgroundColor: AppColors.background.withValues(alpha: 0),
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
                      color: AppColors.textSecondary,
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
                  Text(
                    '$_slotCount / ${ProfileStoryPrompts.maxStories} 카드',
                    key: const ValueKey('profile-stories-progress'),
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: AppColors.mintDeep,
                    ),
                  ),
                  if (_slotCount >= ProfileStoryPrompts.maxStories) ...[
                    const SizedBox(height: 6),
                    const Text(
                      '이야기 카드는 최대 3개까지 작성할 수 있어요.',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                  if (_hasUnknownStories) ...[
                    const SizedBox(height: 6),
                    const Text(
                      '현재 앱에서 편집할 수 없는 이야기 카드가 유지되고 있어요.',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                  const SizedBox(height: 18),
                  for (final story in _stories)
                    if (ProfileStoryPrompts.isValidKey(story.promptKey)) ...[
                      _StoryEditCard(
                        promptKey: story.promptKey,
                        controller: _controllers[story.promptKey]!,
                        onRemove: () => _removePrompt(story.promptKey),
                      ),
                      const SizedBox(height: 14),
                    ],
                  const SizedBox(height: 4),
                  const Text(
                    '질문 선택',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 10),
                  for (final prompt in ProfileStoryPrompts.all)
                    if (!selectedKeys.contains(prompt.key)) ...[
                      _PromptOptionTile(
                        prompt: prompt,
                        enabled: _slotCount < ProfileStoryPrompts.maxStories,
                        onTap: () => _addPrompt(prompt),
                      ),
                      const SizedBox(height: 8),
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

class _StoryEditCard extends StatelessWidget {
  final String promptKey;
  final TextEditingController controller;
  final VoidCallback onRemove;

  const _StoryEditCard({
    required this.promptKey,
    required this.controller,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final label = ProfileStoryPrompts.labelFor(promptKey) ?? '';
    return PremiumSectionCard(
      key: ValueKey('profile-story-card-$promptKey'),
      title: label,
      trailing: IconButton(
        key: ValueKey('profile-story-remove-$promptKey'),
        tooltip: '삭제',
        icon: const Icon(Icons.close_rounded, size: 20),
        color: AppColors.textSecondary,
        onPressed: onRemove,
      ),
      child: TextField(
        key: ValueKey('profile-story-answer-$promptKey'),
        controller: controller,
        minLines: 1,
        maxLines: 3,
        maxLength: ProfileStoryPrompts.maxAnswerLength,
        inputFormatters: [
          LengthLimitingTextInputFormatter(ProfileStoryPrompts.maxAnswerLength),
        ],
        decoration: const InputDecoration(
          hintText: '짧게 답변을 적어주세요',
          counterText: '',
        ),
      ),
    );
  }
}

class _PromptOptionTile extends StatelessWidget {
  final ProfileStoryPrompt prompt;
  final bool enabled;
  final VoidCallback onTap;

  const _PromptOptionTile({
    required this.prompt,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: ValueKey('profile-story-prompt-${prompt.key}'),
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(AppRadius.button),
      child: AnimatedOpacity(
        duration: AppDurations.fast,
        opacity: enabled ? 1 : 0.45,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(AppRadius.button),
            border: Border.all(color: AppColors.border),
          ),
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
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.add_circle_outline_rounded,
                size: 20,
                color: enabled ? AppColors.primary : AppColors.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
