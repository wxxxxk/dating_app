import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/validators.dart';
import '../../shared/widgets/primary_button.dart';

/// 온보딩 스텝 1 — 기본 정보 입력.
///
/// 이름·생년월일·성별·한줄소개를 수집한 뒤 [onNext] 콜백으로 올려 보낸다.
/// M2.5에서는 마지막 스텝이 아니라 중간 스텝이 됐으므로
/// 저장 로직 없이 데이터 수집 + "다음"으로 진행하는 역할만 한다.
class BasicInfoStep extends StatefulWidget {
  /// 데이터가 유효하면 호출되는 콜백 (비동기 불필요 — 저장은 마지막 스텝에서).
  final void Function({
    required String name,
    required DateTime birthDate,
    required String gender,
    required String bio,
  })
  onNext;

  const BasicInfoStep({super.key, required this.onNext});

  @override
  State<BasicInfoStep> createState() => _BasicInfoStepState();
}

class _BasicInfoStepState extends State<BasicInfoStep> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _birthDateController = TextEditingController();
  final _bioController = TextEditingController();

  DateTime? _birthDate;
  String? _gender;

  @override
  void dispose() {
    _nameController.dispose();
    _birthDateController.dispose();
    _bioController.dispose();
    super.dispose();
  }

  Future<void> _pickBirthDate() async {
    // 만 18세 미만 선택 불가
    final maxDate = DateTime.now().subtract(const Duration(days: 365 * 18));
    final picked = await showDatePicker(
      context: context,
      initialDate: _birthDate ?? DateTime(2000),
      firstDate: DateTime(1940),
      lastDate: maxDate,
      helpText: '생년월일 선택',
      confirmText: '확인',
      cancelText: '취소',
    );
    if (picked != null) {
      setState(() {
        _birthDate = picked;
        _birthDateController.text =
            '${picked.year}.${picked.month.toString().padLeft(2, '0')}.${picked.day.toString().padLeft(2, '0')}';
      });
    }
  }

  void _handleNext() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (_birthDate == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('생년월일을 선택해주세요.')));
      return;
    }
    if (_gender == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('성별을 선택해주세요.')));
      return;
    }
    widget.onNext(
      name: _nameController.text.trim(),
      birthDate: _birthDate!,
      gender: _gender!,
      bio: _bioController.text.trim(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '기본 정보 입력',
              style: TextStyle(
                fontFamily: AppFonts.display,
                fontSize: 26,
                fontWeight: FontWeight.bold,
                color: AppColors.textPrimary,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            const Text(
              '매칭과 사주 풀이에 함께 쓰이는 정보예요',
              style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 28),

            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(AppRadius.card),
                border: Border.all(color: AppColors.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 이름
                  TextFormField(
                    controller: _nameController,
                    decoration: const InputDecoration(labelText: '이름'),
                    textInputAction: TextInputAction.next,
                    validator: Validators.name,
                  ),
                  const SizedBox(height: 20),

                  // 생년월일 — 사주 풀이에도 함께 쓰이므로 fortuneAccent를 절제해서 사용
                  TextFormField(
                    controller: _birthDateController,
                    readOnly: true,
                    onTap: _pickBirthDate,
                    decoration: const InputDecoration(
                      labelText: '생년월일',
                      hintText: '날짜를 선택하세요',
                      helperText: '나의 사주 운세 계산에도 사용돼요',
                      suffixIcon: Icon(
                        Icons.calendar_today_rounded,
                        size: 18,
                        color: AppColors.fortuneAccent,
                      ),
                    ),
                    validator: (_) =>
                        _birthDate == null ? '생년월일을 선택해주세요.' : null,
                  ),
                  const SizedBox(height: 24),

                  // 성별
                  const Text(
                    '성별',
                    style: TextStyle(
                      fontSize: 13,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _GenderSelector(
                    selected: _gender,
                    onChanged: (g) => setState(() => _gender = g),
                  ),
                  const SizedBox(height: 20),

                  // 한줄 소개
                  TextFormField(
                    controller: _bioController,
                    decoration: const InputDecoration(
                      labelText: '한줄 소개',
                      hintText: '나를 소개하는 한 문장을 써보세요',
                      counterText: '',
                    ),
                    maxLength: 100,
                    validator: (v) =>
                        Validators.required(v, fieldName: '한줄 소개'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),

            PrimaryButton(
              label: '다음',
              color: AppColors.matchPrimary,
              onPressed: _handleNext,
            ),
          ],
        ),
      ),
    );
  }
}

/// 남성/여성/기타 중 하나를 선택하는 토글 버튼 그룹.
class _GenderSelector extends StatelessWidget {
  final String? selected;
  final ValueChanged<String> onChanged;

  const _GenderSelector({required this.selected, required this.onChanged});

  // (key, label) 쌍. gender key는 AI 매칭 필터에 직접 사용되므로 변경하지 않는다.
  static const _options = [('male', '남성'), ('female', '여성'), ('other', '기타')];

  @override
  Widget build(BuildContext context) {
    return Row(
      children: _options.map((opt) {
        final value = opt.$1;
        final label = opt.$2;
        final isSelected = selected == value;
        return Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: GestureDetector(
              onTap: () => onChanged(value),
              child: AnimatedContainer(
                duration: AppDurations.fast,
                alignment: Alignment.center,
                height: 48,
                decoration: BoxDecoration(
                  color: isSelected
                      ? AppColors.matchPrimary
                      : AppColors.surface,
                  borderRadius: BorderRadius.circular(AppRadius.button),
                  border: Border.all(
                    color: isSelected
                        ? AppColors.matchPrimary
                        : AppColors.border,
                  ),
                ),
                child: Text(
                  label,
                  style: TextStyle(
                    color: isSelected
                        ? AppColors.surface
                        : AppColors.textPrimary,
                    fontWeight: isSelected
                        ? FontWeight.w600
                        : FontWeight.normal,
                    fontSize: 14,
                  ),
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}
