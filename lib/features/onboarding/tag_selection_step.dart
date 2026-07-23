import 'package:flutter/material.dart';

import '../../core/constants/profile_options.dart';
import '../../core/theme/app_colors.dart';
import '../../shared/widgets/primary_button.dart';
import '../profile/widgets/tag_selector.dart';

/// 태그 선택 화면의 표현 방식.
///
/// [onboarding] — 온보딩 스텝의 기본 렌더(명조 display 헤드라인). 픽셀·계약이
/// 기존과 동일하다. [profileEdit] — 프로필 편집에서 열 때만 쓰는 밝은
/// Editorial 렌더. 상단 AppBar가 제목을 이미 보여주므로 본문에서는 큰 제목을
/// 반복하지 않고 subtitle만 안내로 노출한다. 선택 로직/최대 개수/콜백은 동일.
enum TagSelectionPresentation { onboarding, profileEdit }

/// 온보딩 스텝 3·4·5 — 태그 선택 (관심사·성향·이상형).
///
/// [TagSelector] 위젯을 래핑하여 제목·설명·선택 상태·다음 버튼을 제공한다.
/// 온보딩과 프로필 편집 화면 양쪽에서 공통 사용하기 위해 [buttonLabel]을 파라미터로 받는다.
class TagSelectionStep extends StatefulWidget {
  final String title;
  final String subtitle;
  final List<TagOption> options;
  final List<String> initialSelected; // 편집 모드에서 기존 선택값을 미리 채울 때 사용
  final int maxSelection;
  final String buttonLabel;

  /// 화면 표현 방식(기본: 온보딩). 프로필 편집에서만 [profileEdit]로 연다.
  final TagSelectionPresentation presentation;

  /// 버튼 탭 시 현재 선택된 key 목록을 넘겨준다.
  final void Function(List<String> selectedKeys) onNext;

  const TagSelectionStep({
    super.key,
    required this.title,
    required this.subtitle,
    required this.options,
    this.initialSelected = const [],
    this.maxSelection = 8,
    this.buttonLabel = '다음',
    this.presentation = TagSelectionPresentation.onboarding,
    required this.onNext,
  });

  @override
  State<TagSelectionStep> createState() => _TagSelectionStepState();
}

class _TagSelectionStepState extends State<TagSelectionStep> {
  late List<String> _selectedKeys;

  @override
  void initState() {
    super.initState();
    _selectedKeys = List<String>.from(widget.initialSelected);
  }

  @override
  Widget build(BuildContext context) {
    final isProfileEdit =
        widget.presentation == TagSelectionPresentation.profileEdit;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          // 편집 모드는 AppBar가 제목을 이미 보여줘 상단 여백을 줄인다.
          padding: EdgeInsets.fromLTRB(24, isProfileEdit ? 8 : 28, 24, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 편집 모드에서는 큰 명조 제목을 반복하지 않는다(AppBar가 담당).
              if (!isProfileEdit) ...[
                Text(
                  widget.title,
                  style: const TextStyle(
                    fontFamily: AppFonts.display,
                    fontSize: 26,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 6),
              ],
              Text(
                widget.subtitle,
                style: TextStyle(
                  fontSize: 14,
                  color: isProfileEdit
                      ? AppColors.textMuted
                      : AppColors.textSecondary,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),

        // 태그 그리드 — 스크롤 영역
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: TagSelector(
              options: widget.options,
              selectedKeys: _selectedKeys,
              maxSelection: widget.maxSelection,
              onChanged: (updated) => setState(() => _selectedKeys = updated),
            ),
          ),
        ),

        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
          child: PrimaryButton(
            label: widget.buttonLabel,
            color: AppColors.matchPrimary,
            // 0개 선택해도 진행 가능(선택 사항)
            onPressed: () => widget.onNext(_selectedKeys),
          ),
        ),
      ],
    );
  }
}
