import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/constants/profile_options.dart';
import '../../core/theme/app_colors.dart';
import '../../shared/widgets/primary_button.dart';
import '../profile/widgets/job_picker.dart';

/// 온보딩 스텝 2 — 상세 정보 입력.
///
/// 키·종교·흡연·음주·직업(2단계)·최종학력·MBTI를 수집한다.
/// 모두 선택 사항이므로 아무것도 입력하지 않고 "다음"으로 진행할 수 있다.
class DetailInfoStep extends StatefulWidget {
  /// 초기값 — 프로필 편집 화면에서 기존 값을 채워 넣을 때 사용.
  final int? initialHeight;
  final String? initialReligion;
  final String? initialSmoking;
  final String? initialDrinking;
  final String? initialJobCategory;
  final String? initialJobTitle;
  final String? initialEducation;
  final String? initialMbti;

  final void Function({
    required int? height,
    required String? religion,
    required String? smoking,
    required String? drinking,
    required String? jobCategory,
    required String? jobTitle,
    required String? education,
    required String? mbti,
  }) onNext;

  const DetailInfoStep({
    super.key,
    this.initialHeight,
    this.initialReligion,
    this.initialSmoking,
    this.initialDrinking,
    this.initialJobCategory,
    this.initialJobTitle,
    this.initialEducation,
    this.initialMbti,
    required this.onNext,
  });

  @override
  State<DetailInfoStep> createState() => _DetailInfoStepState();
}

class _DetailInfoStepState extends State<DetailInfoStep> {
  late final TextEditingController _heightController;

  String? _religion;
  String? _smoking;
  String? _drinking;
  String? _jobCategory;
  String? _jobTitle;
  String? _education;
  String? _mbti;

  @override
  void initState() {
    super.initState();
    _heightController = TextEditingController(
      text: widget.initialHeight?.toString() ?? '',
    );
    _religion = widget.initialReligion;
    _smoking = widget.initialSmoking;
    _drinking = widget.initialDrinking;
    _jobCategory = widget.initialJobCategory;
    _jobTitle = widget.initialJobTitle;
    _education = widget.initialEducation;
    _mbti = widget.initialMbti;
  }

  @override
  void dispose() {
    _heightController.dispose();
    super.dispose();
  }

  void _handleNext() {
    final heightText = _heightController.text.trim();
    widget.onNext(
      height: heightText.isNotEmpty ? int.tryParse(heightText) : null,
      religion: _religion,
      smoking: _smoking,
      drinking: _drinking,
      jobCategory: _jobCategory,
      jobTitle: _jobTitle?.isEmpty == true ? null : _jobTitle,
      education: _education,
      mbti: _mbti,
    );
  }

  /// 단일 선택 바텀 시트.
  ///
  /// isScrollControlled: true + ConstrainedBox + ListView로 항목이
  /// 많아도(MBTI 16개 등) overflow 없이 스크롤된다.
  Future<void> _showPicker({
    required String title,
    required List<TagOption> options,
    required String? currentKey,
    required void Function(String?) onSelected,
  }) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.7,
          ),
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 핸들 + 타이틀 (고정 헤더)
                Padding(
                  padding: const EdgeInsets.fromLTRB(0, 16, 0, 8),
                  child: Column(
                    children: [
                      Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: AppColors.border,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ],
                  ),
                ),
                // 스크롤 가능한 옵션 목록
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: options.map((opt) {
                      final isSelected = opt.key == currentKey;
                      return ListTile(
                        title: Text(
                          opt.label,
                          style: TextStyle(
                            color: isSelected
                                ? AppColors.primary
                                : AppColors.textPrimary,
                            fontWeight: isSelected
                                ? FontWeight.w600
                                : FontWeight.normal,
                          ),
                        ),
                        trailing: isSelected
                            ? const Icon(Icons.check,
                                color: AppColors.primary)
                            : null,
                        onTap: () {
                          Navigator.pop(ctx);
                          onSelected(opt.key);
                        },
                      );
                    }).toList(),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 직업 2단계 선택 (카테고리 → 직업명).
  Future<void> _openJobPicker() async {
    final result = await pushJobPicker(
      context,
      initialCategoryKey: _jobCategory,
      initialTitle: _jobTitle,
    );
    if (result != null && mounted) {
      setState(() {
        _jobCategory = result.categoryKey;
        _jobTitle = result.title.isEmpty ? null : result.title;
      });
    }
  }

  /// 직업 선택 결과를 한 줄 텍스트로 변환한다.
  String? _jobDisplayText() {
    if (_jobCategory == null && (_jobTitle == null || _jobTitle!.isEmpty)) {
      return null;
    }
    final catLabel = _jobCategory != null
        ? ProfileOptions.keyToLabel(
            ProfileOptions.jobCategoryOptions, _jobCategory!)
        : null;
    // 카테고리 라벨에서 앞 이모지 제거 (예: '🎒 학생' → '학생')
    String? catName;
    if (catLabel != null) {
      final spaceIdx = catLabel.indexOf(' ');
      catName = spaceIdx != -1 ? catLabel.substring(spaceIdx + 1) : catLabel;
    }
    final parts = [
      ?catName,
      if (_jobTitle != null && _jobTitle!.isNotEmpty) _jobTitle!,
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '상세 정보 입력',
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.bold,
              color: AppColors.textPrimary,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          const Text(
            '모두 선택 사항이에요',
            style: TextStyle(fontSize: 14, color: AppColors.textSecondary),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),

          // 키 (숫자 직접 입력)
          TextField(
            controller: _heightController,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(3),
            ],
            decoration: const InputDecoration(
              labelText: '키 (cm)',
              hintText: '예: 172',
              suffixText: 'cm',
            ),
          ),
          const SizedBox(height: 8),

          // 직업 (2단계 피커)
          _PickerField(
            label: '직업',
            value: _jobDisplayText(),
            onTap: _openJobPicker,
          ),

          // 단일 선택 필드들
          _PickerField(
            label: '종교',
            value: ProfileOptions.keyToLabel(
                ProfileOptions.religions, _religion ?? ''),
            onTap: () => _showPicker(
              title: '종교',
              options: ProfileOptions.religions,
              currentKey: _religion,
              onSelected: (k) => setState(() => _religion = k),
            ),
          ),
          _PickerField(
            label: '흡연',
            value: ProfileOptions.keyToLabel(
                ProfileOptions.smokingOptions, _smoking ?? ''),
            onTap: () => _showPicker(
              title: '흡연',
              options: ProfileOptions.smokingOptions,
              currentKey: _smoking,
              onSelected: (k) => setState(() => _smoking = k),
            ),
          ),
          _PickerField(
            label: '음주',
            value: ProfileOptions.keyToLabel(
                ProfileOptions.drinkingOptions, _drinking ?? ''),
            onTap: () => _showPicker(
              title: '음주',
              options: ProfileOptions.drinkingOptions,
              currentKey: _drinking,
              onSelected: (k) => setState(() => _drinking = k),
            ),
          ),
          _PickerField(
            label: '최종학력',
            value: ProfileOptions.keyToLabel(
                ProfileOptions.educationOptions, _education ?? ''),
            onTap: () => _showPicker(
              title: '최종학력',
              options: ProfileOptions.educationOptions,
              currentKey: _education,
              onSelected: (k) => setState(() => _education = k),
            ),
          ),
          _PickerField(
            label: 'MBTI',
            value: _mbti,
            onTap: () => _showPicker(
              title: 'MBTI',
              options: ProfileOptions.mbtiOptions,
              currentKey: _mbti,
              onSelected: (k) => setState(() => _mbti = k),
            ),
          ),
          const SizedBox(height: 40),

          PrimaryButton(label: '다음', onPressed: _handleNext),
        ],
      ),
    );
  }
}

/// 단일 선택 항목을 표시하는 탭 가능한 필드 행.
class _PickerField extends StatelessWidget {
  final String label;
  final String? value;
  final VoidCallback onTap;

  const _PickerField({
    required this.label,
    required this.value,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hasValue = value != null && value!.isNotEmpty;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Row(
          children: [
            Text(
              label,
              style: const TextStyle(
                fontSize: 15,
                color: AppColors.textPrimary,
              ),
            ),
            const Spacer(),
            Flexible(
              child: Text(
                hasValue ? value! : '선택',
                textAlign: TextAlign.end,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 15,
                  color: hasValue
                      ? AppColors.textPrimary
                      : AppColors.textSecondary,
                ),
              ),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right,
                size: 18, color: AppColors.textSecondary),
          ],
        ),
      ),
    );
  }
}
