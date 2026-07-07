import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/constants/profile_options.dart';
import '../../core/theme/app_colors.dart';
import '../../models/user_profile.dart';
import '../../services/database/firestore_service.dart';
import '../../services/storage/storage_service.dart';
import '../../shared/widgets/loading_indicator.dart';
import '../../shared/widgets/primary_button.dart';
import '../onboarding/tag_selection_step.dart';
import 'widgets/job_picker.dart';

/// 프로필 편집 화면.
///
/// 기존 [profile]을 받아 모든 필드를 인라인으로 편집하고,
/// "저장" 버튼 한 번으로 Firestore에 반영한다.
/// 저장 완료 후 `Navigator.pop(context, updatedProfile)`으로
/// HomeScreen에 최신 프로필을 전달해 재조회 없이 화면을 갱신한다.
///
/// [storageService]는 현재 사용하지 않지만, 사진 교체 기능 확장 시 필요하다.
class ProfileEditScreen extends StatefulWidget {
  final UserProfile profile;
  final FirestoreService firestoreService;
  final StorageService storageService;

  const ProfileEditScreen({
    super.key,
    required this.profile,
    required this.firestoreService,
    required this.storageService,
  });

  @override
  State<ProfileEditScreen> createState() => _ProfileEditScreenState();
}

class _ProfileEditScreenState extends State<ProfileEditScreen> {
  late final TextEditingController _nameController;
  late final TextEditingController _bioController;
  late final TextEditingController _heightController;

  late String _gender;
  String? _religion;
  String? _smoking;
  String? _drinking;
  String? _jobCategory;
  String? _jobTitle;
  String? _education;
  String? _mbti;
  String? _relationshipGoal;
  late List<String> _interests;
  late List<String> _personalityTags;
  late List<String> _idealTags;

  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    final p = widget.profile;
    _nameController = TextEditingController(text: p.displayName);
    _bioController = TextEditingController(text: p.bio);
    _heightController = TextEditingController(
      text: p.height != null ? p.height.toString() : '',
    );
    _gender = p.gender;
    _religion = p.religion;
    _smoking = p.smoking;
    _drinking = p.drinking;
    _jobCategory = p.jobCategory;
    _jobTitle = p.jobTitle;
    _education = p.education;
    _mbti = p.mbti;
    _relationshipGoal = p.relationshipGoal;
    _interests = List<String>.from(p.interests);
    _personalityTags = List<String>.from(p.personalityTags);
    _idealTags = List<String>.from(p.idealTags);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _bioController.dispose();
    _heightController.dispose();
    super.dispose();
  }

  // ── 저장 ─────────────────────────────────────────────────────────────────

  Future<void> _save() async {
    final name = _nameController.text.trim();
    final bio = _bioController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('이름을 입력해주세요.')));
      return;
    }
    if (bio.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('한줄 소개를 입력해주세요.')));
      return;
    }

    setState(() => _isLoading = true);
    try {
      final heightText = _heightController.text.trim();
      final updatedProfile = widget.profile.copyWith(
        displayName: name,
        bio: bio,
        gender: _gender,
        height: heightText.isNotEmpty ? int.tryParse(heightText) : null,
        religion: _religion,
        smoking: _smoking,
        drinking: _drinking,
        jobCategory: _jobCategory,
        jobTitle: (_jobTitle == null || _jobTitle!.isEmpty) ? null : _jobTitle,
        education: _education,
        mbti: _mbti,
        relationshipGoal: _relationshipGoal,
        interests: _interests,
        personalityTags: _personalityTags,
        idealTags: _idealTags,
        updatedAt: DateTime.now(),
      );
      await widget.firestoreService.createUserProfile(updatedProfile);

      if (mounted) {
        // 업데이트된 프로필을 HomeScreen에 전달해 재조회 없이 반영
        Navigator.pop(context, updatedProfile);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('저장 중 오류가 발생했습니다: $e')));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ── 단일 선택 바텀 시트 ──────────────────────────────────────────────────

  /// 단일 선택 바텀 시트.
  ///
  /// isScrollControlled + ConstrainedBox + ListView 조합으로
  /// 항목이 많아도(MBTI 16개 등) overflow 없이 스크롤된다.
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
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadius.sheet),
        ),
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
                Padding(
                  padding: const EdgeInsets.fromLTRB(0, 16, 0, 8),
                  child: Column(
                    children: [
                      Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: AppColors.border,
                          borderRadius: BorderRadius.circular(AppSpacing.xs),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
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
                            ? const Icon(
                                Icons.check_rounded,
                                color: AppColors.primary,
                              )
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

  /// 직업 선택 결과를 표시용 텍스트로 변환한다.
  String? _jobDisplayText() {
    if (_jobCategory == null && (_jobTitle == null || _jobTitle!.isEmpty)) {
      return null;
    }
    final catLabel = _jobCategory != null
        ? ProfileOptions.keyToLabel(
            ProfileOptions.jobCategoryOptions,
            _jobCategory!,
          )
        : null;
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

  // ── 태그 선택 전용 페이지로 이동 ────────────────────────────────────────

  Future<void> _openTagPage({
    required String title,
    required String subtitle,
    required List<TagOption> options,
    required List<String> current,
    required void Function(List<String>) onSaved,
  }) async {
    // TagSelectionStep을 전체 페이지로 래핑해서 편집 화면에 재사용한다.
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (ctx) => Scaffold(
          appBar: AppBar(
            title: Text(title),
            leading: IconButton(
              icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
              onPressed: () => Navigator.pop(ctx),
            ),
            backgroundColor: AppColors.background.withValues(alpha: 0),
            elevation: 0,
          ),
          body: SafeArea(
            child: TagSelectionStep(
              title: title,
              subtitle: subtitle,
              options: options,
              initialSelected: current,
              buttonLabel: '저장',
              onNext: (keys) {
                onSaved(keys);
                Navigator.pop(ctx);
              },
            ),
          ),
        ),
      ),
    );
  }

  // ── UI 빌더 ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // Scaffold를 루트로 두어야 키보드 대응(resizeToAvoidBottomInset)과
    // 높이 제약이 정상적으로 동작한다. 로딩 오버레이는 body 안 Stack에서 처리한다.
    return Scaffold(
      appBar: AppBar(
        title: const Text('프로필 편집'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
          onPressed: _isLoading ? null : () => Navigator.pop(context),
        ),
        backgroundColor: AppColors.background.withValues(alpha: 0),
        elevation: 0,
      ),
      body: Stack(
        children: [
          SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 120),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── 기본 정보 ────────────────────────────────────────────
                _SectionHeader(title: '기본 정보'),
                TextField(
                  controller: _nameController,
                  decoration: const InputDecoration(labelText: '이름'),
                ),
                const SizedBox(height: 16),
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
                const SizedBox(height: 16),
                TextField(
                  controller: _bioController,
                  decoration: const InputDecoration(
                    labelText: '한줄 소개',
                    counterText: '',
                  ),
                  maxLength: 100,
                  maxLines: 2,
                ),
                const SizedBox(height: 32),

                // ── 상세 정보 ────────────────────────────────────────────
                _SectionHeader(title: '상세 정보'),
                TextField(
                  controller: _heightController,
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(3),
                  ],
                  decoration: const InputDecoration(
                    labelText: '키 (cm)',
                    suffixText: 'cm',
                  ),
                ),
                _EditPickerField(
                  label: '직업',
                  value: _jobDisplayText(),
                  onTap: _openJobPicker,
                ),
                _EditPickerField(
                  label: '종교',
                  value: ProfileOptions.keyToLabel(
                    ProfileOptions.religions,
                    _religion ?? '',
                  ),
                  onTap: () => _showPicker(
                    title: '종교',
                    options: ProfileOptions.religions,
                    currentKey: _religion,
                    onSelected: (k) => setState(() => _religion = k),
                  ),
                ),
                _EditPickerField(
                  label: '흡연',
                  value: ProfileOptions.keyToLabel(
                    ProfileOptions.smokingOptions,
                    _smoking ?? '',
                  ),
                  onTap: () => _showPicker(
                    title: '흡연',
                    options: ProfileOptions.smokingOptions,
                    currentKey: _smoking,
                    onSelected: (k) => setState(() => _smoking = k),
                  ),
                ),
                _EditPickerField(
                  label: '음주',
                  value: ProfileOptions.keyToLabel(
                    ProfileOptions.drinkingOptions,
                    _drinking ?? '',
                  ),
                  onTap: () => _showPicker(
                    title: '음주',
                    options: ProfileOptions.drinkingOptions,
                    currentKey: _drinking,
                    onSelected: (k) => setState(() => _drinking = k),
                  ),
                ),
                _EditPickerField(
                  label: '최종학력',
                  value: ProfileOptions.keyToLabel(
                    ProfileOptions.educationOptions,
                    _education ?? '',
                  ),
                  onTap: () => _showPicker(
                    title: '최종학력',
                    options: ProfileOptions.educationOptions,
                    currentKey: _education,
                    onSelected: (k) => setState(() => _education = k),
                  ),
                ),
                _EditPickerField(
                  label: 'MBTI',
                  value: _mbti,
                  onTap: () => _showPicker(
                    title: 'MBTI',
                    options: ProfileOptions.mbtiOptions,
                    currentKey: _mbti,
                    onSelected: (k) => setState(() => _mbti = k),
                  ),
                ),
                const SizedBox(height: 32),

                // ── 관심사 ────────────────────────────────────────────────
                _SectionHeader(
                  title: '관심사',
                  trailing: TextButton(
                    onPressed: () => _openTagPage(
                      title: '관심사',
                      subtitle: '나의 취미·라이프스타일을 보여주세요',
                      options: ProfileOptions.interests,
                      current: _interests,
                      onSaved: (keys) => setState(() => _interests = keys),
                    ),
                    child: const Text(
                      '편집',
                      style: TextStyle(color: AppColors.primary),
                    ),
                  ),
                ),
                if (_interests.isEmpty)
                  const _EmptyTagHint(text: '관심사를 추가해보세요')
                else
                  _TagChipDisplay(
                    keys: _interests,
                    options: ProfileOptions.interests,
                  ),
                const SizedBox(height: 32),

                // ── 나를 표현하는 키워드 ─────────────────────────────────
                _SectionHeader(
                  title: '나를 표현하는 키워드',
                  trailing: TextButton(
                    onPressed: () => _openTagPage(
                      title: '성향 키워드',
                      subtitle: '나의 성격·스타일을 잘 나타내는 키워드를 골라보세요',
                      options: ProfileOptions.personalities,
                      current: _personalityTags,
                      onSaved: (keys) =>
                          setState(() => _personalityTags = keys),
                    ),
                    child: const Text(
                      '편집',
                      style: TextStyle(color: AppColors.primary),
                    ),
                  ),
                ),
                if (_personalityTags.isEmpty)
                  const _EmptyTagHint(text: '나를 표현하는 키워드를 추가해보세요')
                else
                  _TagChipDisplay(
                    keys: _personalityTags,
                    options: ProfileOptions.personalities,
                  ),
                const SizedBox(height: 32),

                // ── 이상형 ────────────────────────────────────────────────
                _SectionHeader(
                  title: '이런 친구를 원해요',
                  trailing: TextButton(
                    onPressed: () => _openTagPage(
                      title: '이상형 키워드',
                      subtitle: '내가 선호하는 상대의 키워드를 선택해주세요',
                      options: ProfileOptions.ideals,
                      current: _idealTags,
                      onSaved: (keys) => setState(() => _idealTags = keys),
                    ),
                    child: const Text(
                      '편집',
                      style: TextStyle(color: AppColors.primary),
                    ),
                  ),
                ),
                if (_idealTags.isEmpty)
                  const _EmptyTagHint(text: '원하는 친구 키워드를 추가해보세요')
                else
                  _TagChipDisplay(
                    keys: _idealTags,
                    options: ProfileOptions.ideals,
                  ),
                const SizedBox(height: 32),

                // ── 찾는 관계 ─────────────────────────────────────────────
                _SectionHeader(title: '찾는 관계'),
                _EditPickerField(
                  label: '어떤 인연을 찾나요?',
                  value: ProfileOptions.keyToLabel(
                    ProfileOptions.relationshipGoals,
                    _relationshipGoal ?? '',
                  ),
                  onTap: () => _showPicker(
                    title: '찾는 관계',
                    options: ProfileOptions.relationshipGoals,
                    currentKey: _relationshipGoal,
                    onSelected: (k) => setState(() => _relationshipGoal = k),
                  ),
                ),
                const SizedBox(height: 48),

                PrimaryButton(
                  label: '저장',
                  onPressed: _isLoading ? null : _save,
                ),
              ],
            ),
          ),
          if (_isLoading) const LoadingIndicator(overlay: true),
        ],
      ),
    );
  }
}

// ── 내부 헬퍼 위젯들 ──────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String title;
  final Widget? trailing;

  const _SectionHeader({required this.title, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.bold,
              color: AppColors.textPrimary,
            ),
          ),
          const Spacer(),
          ?trailing,
        ],
      ),
    );
  }
}

class _EditPickerField extends StatelessWidget {
  final String label;
  final String? value;
  final VoidCallback onTap;

  const _EditPickerField({
    required this.label,
    required this.value,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hasValue = value != null && value!.isNotEmpty;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.button),
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
            Text(
              hasValue ? value! : '선택',
              style: TextStyle(
                fontSize: 15,
                color: hasValue
                    ? AppColors.textPrimary
                    : AppColors.textSecondary,
              ),
            ),
            const SizedBox(width: 4),
            const Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: AppColors.textSecondary,
            ),
          ],
        ),
      ),
    );
  }
}

/// 태그 key 목록을 label로 변환해서 칩으로 표시한다.
class _TagChipDisplay extends StatelessWidget {
  final List<String> keys;
  final List<TagOption> options;

  const _TagChipDisplay({required this.keys, required this.options});

  @override
  Widget build(BuildContext context) {
    final labels = ProfileOptions.keysToLabels(options, keys);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: labels
          .map(
            (label) => Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(AppRadius.chip),
                border: Border.all(
                  color: AppColors.primary.withValues(alpha: 0.3),
                ),
              ),
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.primary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          )
          .toList(),
    );
  }
}

class _EmptyTagHint extends StatelessWidget {
  final String text;
  const _EmptyTagHint({required this.text});

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(fontSize: 14, color: AppColors.textSecondary),
    );
  }
}

class _GenderSelector extends StatelessWidget {
  final String selected;
  final ValueChanged<String> onChanged;

  const _GenderSelector({required this.selected, required this.onChanged});

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
                height: 44,
                decoration: BoxDecoration(
                  color: isSelected ? AppColors.primary : AppColors.surface,
                  borderRadius: BorderRadius.circular(AppRadius.button),
                  border: Border.all(
                    color: isSelected ? AppColors.primary : AppColors.border,
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
