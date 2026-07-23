import 'package:flutter/material.dart';

import '../../core/constants/value_questions.dart';
import '../../core/theme/app_colors.dart';
import '../../shared/widgets/primary_button.dart';

/// 가치관 질문 전용 편집 화면.
///
/// 6개 가치관 질문에 단일 선택으로 답하는 순수 UI 화면이다. Firestore/Auth/
/// Storage/Functions/UID 어디에도 의존하지 않는다 — 선택 상태만 로컬에서
/// 관리하고, "완료"를 누르면 현재 답변 map을 `Navigator.pop`으로 부모
/// (ProfileEditScreen)에 돌려준다. 실제 저장(dual-write)은 부모의 "저장"
/// 버튼에서만 일어난다.
class ValueAnswersEditScreen extends StatefulWidget {
  /// 부모가 넘겨준 현재 답변(questionKey → answerKey). 방어 복사해서 쓴다.
  final Map<String, String> initialAnswers;

  const ValueAnswersEditScreen({super.key, required this.initialAnswers});

  @override
  State<ValueAnswersEditScreen> createState() => _ValueAnswersEditScreenState();
}

class _ValueAnswersEditScreenState extends State<ValueAnswersEditScreen> {
  late Map<String, String> _valueAnswers;

  @override
  void initState() {
    super.initState();
    // 방어 복사한 뒤, "현재 catalog에 존재하는 질문인데 answer가 유효하지 않은"
    // 항목만 제거해 선택 안 된 상태로 정규화한다.
    //
    // unknown question key(향후 추가될 미래 질문)는 화면에 표시하지 않지만
    // 그대로 보존한다 — 구버전 앱으로 편집해도 미래 데이터를 잃지 않기 위함.
    final normalized = <String, String>{};
    widget.initialAnswers.forEach((questionKey, answerKey) {
      final isKnown = ValueQuestions.byKey(questionKey) != null;
      if (isKnown && !ValueQuestions.isValidAnswer(questionKey, answerKey)) {
        return; // 현재 질문의 invalid answer → 정규화로 제거
      }
      normalized[questionKey] = answerKey;
    });
    _valueAnswers = normalized;
  }

  /// catalog에 존재하고 answer가 유효한 답변만 센다(unknown key 제외).
  int get _answeredCount {
    var count = 0;
    for (final question in ValueQuestions.all) {
      final answer = _valueAnswers[question.key];
      if (answer != null &&
          ValueQuestions.isValidAnswer(question.key, answer)) {
        count += 1;
      }
    }
    return count;
  }

  void _onOptionTap(ValueQuestion question, ValueOption option) {
    setState(() {
      if (_valueAnswers[question.key] == option.key) {
        // 같은 선택지를 다시 누르면 해제
        _valueAnswers.remove(question.key);
      } else {
        // 단일 선택 — 이전 선택을 덮어쓴다
        _valueAnswers[question.key] = option.key;
      }
    });
  }

  void _onDone() {
    // 저장하지 않고 map만 부모로 반환한다.
    Navigator.pop(context, Map<String, String>.from(_valueAnswers));
  }

  @override
  Widget build(BuildContext context) {
    final total = ValueQuestions.all.length;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text(
          '나의 가치관',
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
                children: [
                  const Text(
                    '연애와 관계에서 중요하게 생각하는 방식을 알려주세요.\n'
                    '답변은 상대 프로필과 매칭 설명에 활용돼요.',
                    style: TextStyle(
                      fontSize: 13,
                      color: AppColors.textSecondary,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    '$_answeredCount / $total 답변',
                    key: const ValueKey('value-answers-progress'),
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: AppColors.mintDeep,
                    ),
                  ),
                  const SizedBox(height: 20),
                  for (var i = 0; i < ValueQuestions.all.length; i++) ...[
                    if (i > 0) ...[
                      const SizedBox(height: 22),
                      const Divider(height: 1, color: AppColors.borderSubtle),
                      const SizedBox(height: 22),
                    ],
                    _ValueQuestionSection(
                      question: ValueQuestions.all[i],
                      selectedKey: _valueAnswers[ValueQuestions.all[i].key],
                      onSelected: (option) =>
                          _onOptionTap(ValueQuestions.all[i], option),
                    ),
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
                key: const ValueKey('value-answers-done'),
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

/// 질문 1개 + 선택지 chip 묶음. 두꺼운 카드 대신 여백과 divider로 구분되는
/// 밝은 editorial 섹션으로 표현한다.
class _ValueQuestionSection extends StatelessWidget {
  final ValueQuestion question;
  final String? selectedKey;
  final ValueChanged<ValueOption> onSelected;

  const _ValueQuestionSection({
    required this.question,
    required this.selectedKey,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      key: ValueKey('value-question-${question.key}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          question.profileLabel,
          style: const TextStyle(
            fontSize: 16.5,
            fontWeight: FontWeight.w800,
            color: AppColors.textStrong,
            height: 1.3,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          question.prompt,
          style: const TextStyle(
            fontSize: 13,
            color: AppColors.textMuted,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: question.options.map((option) {
            return _ValueOptionChip(
              key: ValueKey('value-option-${question.key}-${option.key}'),
              label: option.label,
              selected: option.key == selectedKey,
              onTap: () => onSelected(option),
            );
          }).toList(),
        ),
      ],
    );
  }
}

/// 단일 선택 chip. 선택 문법은 앱 공통과 동일: 민트 fill + 다크 잉크 텍스트.
class _ValueOptionChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ValueOptionChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: AppDurations.fast,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: selected ? AppColors.mint : AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.chip),
          border: Border.all(
            color: selected ? AppColors.mint : AppColors.border,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: selected ? AppColors.onMint : AppColors.textPrimary,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
