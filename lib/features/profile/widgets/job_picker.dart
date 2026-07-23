import 'package:flutter/material.dart';

import '../../../core/constants/profile_options.dart';
import '../../../core/theme/app_colors.dart';
import '../../../shared/widgets/primary_button.dart';

/// 직업 카테고리 → 세부 직업명 2단계 입력 흐름 진입점.
///
/// 반환값: 완료 시 ({categoryKey, title}), 취소 시 null.
/// 온보딩과 프로필 편집 양쪽에서 재사용한다.
Future<({String categoryKey, String title})?> pushJobPicker(
  BuildContext context, {
  String? initialCategoryKey,
  String? initialTitle,
}) {
  return Navigator.push<({String categoryKey, String title})>(
    context,
    MaterialPageRoute(
      builder: (_) => _JobCategoryPage(
        initialCategoryKey: initialCategoryKey,
        initialTitle: initialTitle,
      ),
    ),
  );
}

// ── 1단계: 직업 카테고리 선택 ──────────────────────────────────────────────────

class _JobCategoryPage extends StatelessWidget {
  final String? initialCategoryKey;
  final String? initialTitle;

  const _JobCategoryPage({this.initialCategoryKey, this.initialTitle});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text(
          '직업',
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
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 12, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '어떤 일을 하고 있나요?',
                  style: TextStyle(
                    fontSize: 23,
                    fontWeight: FontWeight.w900,
                    color: AppColors.textStrong,
                    height: 1.2,
                  ),
                ),
                SizedBox(height: 6),
                Text(
                  '카테고리를 선택하면 세부 직업명을 입력할 수 있어요',
                  style: TextStyle(fontSize: 13.5, color: AppColors.textMuted),
                ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Container(
                decoration: BoxDecoration(
                  color: AppColors.surfacePrimary,
                  borderRadius: BorderRadius.circular(AppRadius.surface),
                  border: Border.all(color: AppColors.borderSubtle),
                ),
                clipBehavior: Clip.antiAlias,
                child: ListView.separated(
                  padding: EdgeInsets.zero,
                  itemCount: ProfileOptions.jobCategoryOptions.length,
                  separatorBuilder: (_, _) => const Divider(
                    height: 1,
                    indent: 16,
                    color: AppColors.borderSubtle,
                  ),
                  itemBuilder: (ctx, i) {
                    final opt = ProfileOptions.jobCategoryOptions[i];
                    final isSelected = opt.key == initialCategoryKey;
                    return _JobCategoryRow(
                      label: opt.label,
                      selected: isSelected,
                      onTap: () async {
                        final title = await Navigator.push<String>(
                          ctx,
                          MaterialPageRoute(
                            builder: (_) => _JobTitlePage(
                              categoryKey: opt.key,
                              categoryLabel: opt.label,
                              // 카테고리가 바뀌면 기존 직업명 초기화
                              initialTitle: isSelected ? initialTitle : null,
                            ),
                          ),
                        );
                        if (title != null && ctx.mounted) {
                          // 선택 완료: 카테고리+직업명을 들고 카테고리 페이지도 닫는다
                          Navigator.pop(ctx, (
                            categoryKey: opt.key,
                            title: title,
                          ));
                        }
                      },
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 직업 카테고리 목록의 한 행. 선택된 카테고리는 pale mint + mintDeep + check,
/// 나머지는 deep charcoal + neutral chevron. label의 기존 장식 문자열은 그대로.
class _JobCategoryRow extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _JobCategoryRow({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: selected,
      button: true,
      label: label,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 56),
          color: selected ? AppColors.surfaceMintSoft : null,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
                    color: selected ? AppColors.mintDeep : AppColors.textStrong,
                  ),
                ),
              ),
              if (selected)
                const Icon(
                  Icons.check_rounded,
                  size: 20,
                  color: AppColors.mintDeep,
                )
              else
                const ExcludeSemantics(
                  child: Icon(
                    Icons.chevron_right_rounded,
                    size: 20,
                    color: AppColors.textMuted,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── 2단계: 세부 직업명 입력 ────────────────────────────────────────────────────

class _JobTitlePage extends StatefulWidget {
  final String categoryKey;
  final String categoryLabel;
  final String? initialTitle;

  const _JobTitlePage({
    required this.categoryKey,
    required this.categoryLabel,
    this.initialTitle,
  });

  @override
  State<_JobTitlePage> createState() => _JobTitlePageState();
}

class _JobTitlePageState extends State<_JobTitlePage> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialTitle ?? '');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    FocusScope.of(context).unfocus();
    // 직업명이 비어도 빈 문자열로 저장 — 빈 값은 HomeScreen에서 표시 생략
    Navigator.pop(context, _controller.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    // 카테고리 라벨에서 앞의 장식 문자열과 공백을 제거한다.
    final label = widget.categoryLabel;
    final spaceIdx = label.indexOf(' ');
    final categoryName = spaceIdx != -1 ? label.substring(spaceIdx + 1) : label;

    return Scaffold(
      backgroundColor: AppColors.background,
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        title: const Text(
          '직업명',
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
      // SingleChildScrollView로 감싸서 키보드가 올라올 때 콘텐츠가 밀리지 않게
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 선택된 카테고리 뱃지 (pale mint)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: AppColors.surfaceMintSoft,
                borderRadius: BorderRadius.circular(AppRadius.chip),
              ),
              child: Text(
                categoryName,
                style: const TextStyle(
                  fontSize: 13.5,
                  color: AppColors.mintDeep,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(height: 22),
            const Text(
              '직업명은 무엇인가요?',
              style: TextStyle(
                fontSize: 23,
                fontWeight: FontWeight.w900,
                color: AppColors.textStrong,
                height: 1.2,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              '구체적인 직업명을 입력해주세요',
              style: TextStyle(fontSize: 13.5, color: AppColors.textMuted),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _controller,
              autofocus: true,
              textInputAction: TextInputAction.done,
              maxLength: 30,
              onSubmitted: (_) => _save(),
              style: const TextStyle(
                fontSize: 15.5,
                color: AppColors.textStrong,
              ),
              decoration: InputDecoration(
                hintText: _hintText(widget.categoryKey),
                hintStyle: const TextStyle(color: AppColors.textMuted),
                filled: true,
                fillColor: AppColors.surfaceSecondary,
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.control),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.control),
                  borderSide: const BorderSide(
                    color: AppColors.brandPrimaryStrong,
                    width: 1.5,
                  ),
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.control),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 28),
            PrimaryButton(label: '저장', onPressed: _save),
          ],
        ),
      ),
    );
  }

  static String _hintText(String categoryKey) {
    switch (categoryKey) {
      case 'student':
        return '예: 컴퓨터공학과 4학년';
      case 'medical':
        return '예: 인턴 의사, 간호사';
      case 'it':
        return '예: 백엔드 개발자, iOS 개발자';
      case 'research':
        return '예: 학부연구생, 연구원';
      case 'education':
        return '예: 초등학교 교사, 학원 강사';
      default:
        return '예: 구체적인 직업명';
    }
  }
}
