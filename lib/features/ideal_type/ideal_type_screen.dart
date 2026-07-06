import 'package:flutter/material.dart';

import '../../core/constants/profile_options.dart';
import '../../core/theme/app_colors.dart';
import '../../models/ideal_type_model.dart';
import '../../models/user_profile.dart';
import '../../services/ideal_type/ideal_type_service.dart';

class IdealTypeScreen extends StatefulWidget {
  final UserProfile profile;
  final IdealTypeService idealTypeService;

  const IdealTypeScreen({
    super.key,
    required this.profile,
    required this.idealTypeService,
  });

  @override
  State<IdealTypeScreen> createState() => _IdealTypeScreenState();
}

class _IdealTypeScreenState extends State<IdealTypeScreen> {
  late IdealTypeImageOptions _options;
  IdealTypeImageResult? _result;
  bool _loadingCache = true;
  bool _generating = false;

  @override
  void initState() {
    super.initState();
    final initialGender = widget.profile.discoveryFilter.gender;
    final gender = ['male', 'female'].contains(initialGender)
        ? initialGender
        : 'all';
    _options = IdealTypeImageOptions(
      gender: gender,
      idealTags: widget.profile.idealTags,
      mood: 'gentle',
      style: 'casual',
      hair: IdealTypeOptionSets.defaultHairForGender(gender),
      impression: 'warm',
      background: 'studio',
    );
    _loadCached();
  }

  void _selectGender(String gender) {
    final nextHair =
        IdealTypeOptionSets.isHairValidForGender(gender, _options.hair)
        ? _options.hair
        : IdealTypeOptionSets.defaultHairForGender(gender);
    setState(
      () => _options = _options.copyWith(gender: gender, hair: nextHair),
    );
  }

  Future<void> _loadCached() async {
    try {
      final cached = await widget.idealTypeService.getCachedImage(
        widget.profile.uid,
      );
      if (mounted) setState(() => _result = cached);
    } finally {
      if (mounted) setState(() => _loadingCache = false);
    }
  }

  Future<void> _generate() async {
    if (_generating) return;
    setState(() => _generating = true);
    try {
      final result = await widget.idealTypeService.generateImage(
        options: _options,
      );
      if (!mounted) return;
      setState(() => _result = result);
      _showSnack('이상형 이미지가 준비됐어요.');
    } catch (e) {
      if (!mounted) return;
      _showSnack('이미지 생성 실패: $e');
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text(
          'AI 이상형 만들기',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: AppColors.background,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
        children: [
          _SafetyNotice(),
          const SizedBox(height: 14),
          _OptionSection(
            title: '대상',
            options: IdealTypeOptionSets.genders,
            selected: _options.gender,
            onSelected: _selectGender,
          ),
          _OptionSection(
            title: '분위기',
            options: IdealTypeOptionSets.moods,
            selected: _options.mood,
            onSelected: (value) =>
                setState(() => _options = _options.copyWith(mood: value)),
          ),
          _OptionSection(
            title: '스타일',
            options: IdealTypeOptionSets.styles,
            selected: _options.style,
            onSelected: (value) =>
                setState(() => _options = _options.copyWith(style: value)),
          ),
          _OptionSection(
            title: '헤어',
            options: IdealTypeOptionSets.hairsForGender(_options.gender),
            selected: _options.hair,
            onSelected: (value) =>
                setState(() => _options = _options.copyWith(hair: value)),
          ),
          _OptionSection(
            title: '인상',
            options: IdealTypeOptionSets.impressions,
            selected: _options.impression,
            onSelected: (value) =>
                setState(() => _options = _options.copyWith(impression: value)),
          ),
          _OptionSection(
            title: '배경',
            options: IdealTypeOptionSets.backgrounds,
            selected: _options.background,
            onSelected: (value) =>
                setState(() => _options = _options.copyWith(background: value)),
          ),
          if (widget.profile.idealTags.isNotEmpty) ...[
            const SizedBox(height: 4),
            _IdealTagSummary(tags: widget.profile.idealTags),
          ],
          const SizedBox(height: 18),
          SizedBox(
            height: 52,
            child: FilledButton.icon(
              onPressed: _generating ? null : _generate,
              icon: _generating
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.auto_awesome_rounded),
              label: Text(_generating ? '이미지를 만들고 있어요' : '이상형 만들기'),
              style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
            ),
          ),
          const SizedBox(height: 18),
          if (_loadingCache)
            const Center(child: CircularProgressIndicator())
          else if (_result != null)
            _IdealImagePreview(result: _result!)
          else
            const _EmptyPreview(),
        ],
      ),
    );
  }
}

class _SafetyNotice extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded, color: AppColors.primary, size: 20),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'AI가 생성한 가상의 이미지입니다. 실제 앱 사용자가 아니며, 실존 인물을 의도하지 않습니다.',
              style: TextStyle(
                fontSize: 13,
                height: 1.4,
                color: AppColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _OptionSection extends StatelessWidget {
  final String title;
  final List<IdealTypeOption> options;
  final String selected;
  final ValueChanged<String> onSelected;

  const _OptionSection({
    required this.title,
    required this.options,
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w900,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: options.map((option) {
              final active = option.key == selected;
              return ChoiceChip(
                selected: active,
                label: Text(option.label),
                showCheckmark: false,
                selectedColor: AppColors.primary.withValues(alpha: 0.14),
                labelStyle: TextStyle(
                  color: active ? AppColors.primary : AppColors.textPrimary,
                  fontWeight: active ? FontWeight.w800 : FontWeight.w500,
                ),
                side: BorderSide(
                  color: active ? AppColors.primary : AppColors.border,
                ),
                onSelected: (_) => onSelected(option.key),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}

class _IdealTagSummary extends StatelessWidget {
  final List<String> tags;

  const _IdealTagSummary({required this.tags});

  @override
  Widget build(BuildContext context) {
    final labels = ProfileOptions.keysToLabels(ProfileOptions.ideals, tags);
    if (labels.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '프로필 이상형: ${labels.join(' · ')}',
        style: const TextStyle(
          fontSize: 13,
          height: 1.35,
          color: AppColors.textSecondary,
        ),
      ),
    );
  }
}

class _IdealImagePreview extends StatelessWidget {
  final IdealTypeImageResult result;

  const _IdealImagePreview({required this.result});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: AspectRatio(
            aspectRatio: 1,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.network(result.imageUrl, fit: BoxFit.cover),
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: 12,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.58),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      result.safetyLabel,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          result.summary,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w800,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          '실제 앱 사용자가 아닙니다.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
        ),
      ],
    );
  }
}

class _EmptyPreview extends StatelessWidget {
  const _EmptyPreview();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 180,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border),
      ),
      child: const Text(
        '옵션을 고르고 이상형 이미지를 만들어보세요',
        style: TextStyle(color: AppColors.textSecondary),
      ),
    );
  }
}
