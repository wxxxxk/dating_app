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
      appBar: AppBar(
        title: const Text('직업'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 16, 24, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '어떤 일을 하고 있나요?',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  '카테고리를 선택하면 세부 직업명을 입력할 수 있어요',
                  style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: ProfileOptions.jobCategoryOptions.length,
              itemBuilder: (ctx, i) {
                final opt = ProfileOptions.jobCategoryOptions[i];
                final isSelected = opt.key == initialCategoryKey;
                return ListTile(
                  title: Text(
                    opt.label,
                    style: TextStyle(
                      fontSize: 16,
                      color: isSelected
                          ? AppColors.primary
                          : AppColors.textPrimary,
                      fontWeight:
                          isSelected ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                  trailing: isSelected
                      ? const Icon(Icons.check, color: AppColors.primary)
                      : const Icon(Icons.chevron_right,
                          color: AppColors.textSecondary, size: 20),
                  onTap: () async {
                    final title =
                        await Navigator.push<String>(
                      ctx,
                      MaterialPageRoute(
                        builder: (_) => _JobTitlePage(
                          categoryKey: opt.key,
                          categoryLabel: opt.label,
                          // 카테고리가 바뀌면 기존 직업명 초기화
                          initialTitle:
                              isSelected ? initialTitle : null,
                        ),
                      ),
                    );
                    if (title != null && ctx.mounted) {
                      // 선택 완료: 카테고리+직업명을 들고 카테고리 페이지도 닫는다
                      Navigator.pop(
                        ctx,
                        (categoryKey: opt.key, title: title),
                      );
                    }
                  },
                );
              },
            ),
          ),
        ],
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
    // 카테고리 라벨에서 앞의 이모지+공백 제거 (예: '🎒 학생' → '학생')
    final label = widget.categoryLabel;
    final spaceIdx = label.indexOf(' ');
    final categoryName = spaceIdx != -1 ? label.substring(spaceIdx + 1) : label;

    return Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        title: const Text('직업명'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      // SingleChildScrollView로 감싸서 키보드가 올라올 때 콘텐츠가 밀리지 않게
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 선택된 카테고리 뱃지
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                categoryName,
                style: const TextStyle(
                  fontSize: 14,
                  color: AppColors.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              '직업명은 무엇인가요?',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              '구체적인 직업명을 입력해주세요',
              style: TextStyle(
                fontSize: 14,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 28),
            TextField(
              controller: _controller,
              autofocus: true,
              textInputAction: TextInputAction.done,
              maxLength: 30,
              onSubmitted: (_) => _save(),
              decoration: InputDecoration(
                hintText: _hintText(widget.categoryKey),
              ),
            ),
            const SizedBox(height: 32),
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
