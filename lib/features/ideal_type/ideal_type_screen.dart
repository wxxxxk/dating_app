import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/constants/profile_options.dart';
import '../../core/theme/app_colors.dart';
import '../../models/ideal_type_model.dart';
import '../../models/user_profile.dart';
import '../../services/ideal_type/ideal_type_service.dart';
import '../../shared/widgets/premium_components.dart';

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
  String? _errorMessage;
  bool _loadingCache = true;
  bool _generating = false;

  final _optionsSectionKey = GlobalKey();
  final _scrollController = ScrollController();
  late final TextEditingController _refinementController;

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
      mood: IdealTypeOptionSets.defaultMoodForGender(gender),
      style: IdealTypeOptionSets.defaultStyleForGender(gender),
      hair: IdealTypeOptionSets.defaultHairForGender(gender),
      impression: IdealTypeOptionSets.defaultImpressionForGender(gender),
      background: 'studio',
    );
    _refinementController = TextEditingController();
    _loadCached();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _refinementController.dispose();
    super.dispose();
  }

  void _selectGender(String gender) {
    final nextHair =
        IdealTypeOptionSets.isHairValidForGender(gender, _options.hair)
        ? _options.hair
        : IdealTypeOptionSets.defaultHairForGender(gender);
    final nextMood =
        IdealTypeOptionSets.isMoodValidForGender(gender, _options.mood)
        ? _options.mood
        : IdealTypeOptionSets.defaultMoodForGender(gender);
    final nextStyle =
        IdealTypeOptionSets.isStyleValidForGender(gender, _options.style)
        ? _options.style
        : IdealTypeOptionSets.defaultStyleForGender(gender);
    final nextImpression =
        IdealTypeOptionSets.isImpressionValidForGender(
          gender,
          _options.impression,
        )
        ? _options.impression
        : IdealTypeOptionSets.defaultImpressionForGender(gender);
    setState(
      () => _options = _options.copyWith(
        gender: gender,
        hair: nextHair,
        mood: nextMood,
        style: nextStyle,
        impression: nextImpression,
      ),
    );
  }

  Future<void> _loadCached() async {
    try {
      final cached = await widget.idealTypeService.getCachedImage(
        widget.profile.uid,
      );
      if (mounted) {
        setState(() {
          _result = cached;
          // "선택한 취향" 칩은 항상 _options(현재 선택 상태)를 그대로 보여준다.
          // initState에서 _options는 기본값으로 새로 초기화되므로, 캐시에
          // 저장된 이전 생성 결과의 옵션과 맞춰두지 않으면 "화면에 보이는
          // 이미지"와 "선택한 취향 칩"이 서로 다른 조건을 표시하는 것처럼
          // 보일 수 있다(재진입할 때마다 매번 발생 가능한 혼동 — 실제
          // 서버 응답이 잘못된 게 아니라 클라이언트 로컬 상태가 리셋된
          // 것뿐이다). refinementText는 매번 새로 입력하는 값이라 여기서는
          // 복원하지 않는다.
          final cachedOptions = cached?.options;
          if (cachedOptions != null) {
            _options = _options.copyWith(
              gender: cachedOptions.gender,
              mood: cachedOptions.mood,
              style: cachedOptions.style,
              hair: cachedOptions.hair,
              impression: cachedOptions.impression,
              background: cachedOptions.background,
            );
          }
        });
      }
    } catch (e, stackTrace) {
      // 캐시 조회 실패는 이미지 생성 화면 진입을 막지 않는다. 상세 원인은 개발 로그에만 남긴다.
      if (kDebugMode) {
        debugPrint('[IdealType] 캐시 조회 실패: $e');
        debugPrint('$stackTrace');
      }
    } finally {
      if (mounted) setState(() => _loadingCache = false);
    }
  }

  Future<void> _generate() async {
    if (_generating) return;
    setState(() {
      _generating = true;
      _errorMessage = null;
    });
    try {
      final result = await widget.idealTypeService.generateImage(
        options: _options,
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        _errorMessage = null;
      });
      _showSnack('이상형 이미지가 준비됐어요.');
    } catch (e, stackTrace) {
      if (kDebugMode) {
        debugPrint('[IdealType] 이미지 생성 실패: $e');
        debugPrint('$stackTrace');
      }
      if (!mounted) return;
      setState(() => _errorMessage = _friendlyErrorMessage(e));
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  String _friendlyErrorMessage(Object error) {
    // 서버(HttpsError)가 보낸 메시지는 전부 사용자에게 보여줘도 되도록 미리
    // 다듬어둔 문구다(raw exception이 아니다) — 있으면 그대로 쓰고, 없으면
    // 일반 문구로 대체한다.
    if (error is FirebaseFunctionsException) {
      final message = error.message;
      if (message != null && message.trim().isNotEmpty) return message;
    }
    return '잠시 후 다시 시도하거나 다른 스타일로 시도해보세요.';
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _scrollToOptions() {
    final ctx = _optionsSectionKey.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      duration: AppDurations.base,
      curve: AppCurves.standard,
    );
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
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
      ),
      body: ListView(
        controller: _scrollController,
        padding: EdgeInsets.fromLTRB(
          20,
          12,
          20,
          // 하단 잘림 방지: 고정 28에 시스템 내비게이션 바(제스처/3버튼 모두)
          // 인셋을 더한다. 기기별로 이 인셋이 0일 수도, 클 수도 있어서
          // 하드코딩된 값만으로는 특정 기기에서 마지막 버튼이 잘릴 수 있었다.
          28 + MediaQuery.of(context).padding.bottom,
        ),
        children: [
          _SafetyNotice(),
          const SizedBox(height: 14),
          Container(
            key: _optionsSectionKey,
            child: _OptionsCard(
              options: _options,
              profile: widget.profile,
              onGenderSelected: _selectGender,
              onMoodSelected: (v) =>
                  setState(() => _options = _options.copyWith(mood: v)),
              onStyleSelected: (v) =>
                  setState(() => _options = _options.copyWith(style: v)),
              onHairSelected: (v) =>
                  setState(() => _options = _options.copyWith(hair: v)),
              onImpressionSelected: (v) =>
                  setState(() => _options = _options.copyWith(impression: v)),
              onBackgroundSelected: (v) =>
                  setState(() => _options = _options.copyWith(background: v)),
            ),
          ),
          const SizedBox(height: 14),
          _RefinementInput(
            controller: _refinementController,
            onChanged: (v) =>
                setState(() => _options = _options.copyWith(refinementText: v)),
          ),
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
              label: Text(
                _generating
                    ? '이미지를 만들고 있어요'
                    : (_result == null ? '이상형 만들기' : '다시 생성'),
              ),
              // 이 화면의 핵심 액션 버튼 — 시그니처 CTA(민트 fill + 다크 잉크).
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.mint,
                foregroundColor: AppColors.onMint,
              ),
            ),
          ),
          const SizedBox(height: 18),
          if (_errorMessage != null) ...[
            _IdealImageErrorCard(
              message: _errorMessage!,
              onRetry: _generating ? null : _generate,
            ),
            const SizedBox(height: 18),
          ],
          if (_loadingCache)
            const Center(child: CircularProgressIndicator())
          else if (_generating)
            const _GeneratingCard()
          else if (_result != null)
            _IdealTypeReportCard(
              key: ValueKey(_result!.inputHash),
              result: _result!,
              options: _options,
              onRegenerate: _generate,
              onEditOptions: _scrollToOptions,
            )
          else
            const _EmptyPreview(),
        ],
      ),
    );
  }
}

/// 옵션 선택 6종 + 내 프로필 이상형 태그 참고를 하나의 카드로 묶는다.
/// filter_sheet.dart의 섹션 카드와 같은 시각 언어(surface + 얇은 테두리)를
/// 써서 "정교한 조건 설정" 느낌을 이어간다.
class _OptionsCard extends StatelessWidget {
  final IdealTypeImageOptions options;
  final UserProfile profile;
  final ValueChanged<String> onGenderSelected;
  final ValueChanged<String> onMoodSelected;
  final ValueChanged<String> onStyleSelected;
  final ValueChanged<String> onHairSelected;
  final ValueChanged<String> onImpressionSelected;
  final ValueChanged<String> onBackgroundSelected;

  const _OptionsCard({
    required this.options,
    required this.profile,
    required this.onGenderSelected,
    required this.onMoodSelected,
    required this.onStyleSelected,
    required this.onHairSelected,
    required this.onImpressionSelected,
    required this.onBackgroundSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.mint.withValues(alpha: 0.22)),
        boxShadow: AppShadows.card,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '취향 선택',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: AppColors.mintDeep,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            '아래 조건으로 AI가 이상형 이미지를 생성해요.',
            style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 12),
          _OptionSection(
            title: '대상',
            options: IdealTypeOptionSets.genders,
            selected: options.gender,
            onSelected: onGenderSelected,
          ),
          _OptionSection(
            title: '분위기',
            options: IdealTypeOptionSets.moodsForGender(options.gender),
            selected: options.mood,
            onSelected: onMoodSelected,
          ),
          _OptionSection(
            title: '스타일',
            options: IdealTypeOptionSets.stylesForGender(options.gender),
            selected: options.style,
            onSelected: onStyleSelected,
          ),
          _OptionSection(
            title: '헤어',
            options: IdealTypeOptionSets.hairsForGender(options.gender),
            selected: options.hair,
            onSelected: onHairSelected,
          ),
          _OptionSection(
            title: '인상',
            options: IdealTypeOptionSets.impressionsForGender(options.gender),
            selected: options.impression,
            onSelected: onImpressionSelected,
          ),
          _OptionSection(
            title: '배경',
            options: IdealTypeOptionSets.backgrounds,
            selected: options.background,
            onSelected: onBackgroundSelected,
            last: true,
          ),
          if (profile.idealTags.isNotEmpty) ...[
            const SizedBox(height: 4),
            _IdealTagSummary(tags: profile.idealTags),
          ],
        ],
      ),
    );
  }
}

/// 옵션 선택 외에 짧은 직접 수정 요청(refinementText)을 입력하는 카드.
/// 서버가 항상 길이 제한/키워드 차단을 거친 뒤에만 prompt에 반영한다 —
/// 여기서는 UI 표시용 maxLength만 걸고, 최종 검증은 서버가 한다.
class _RefinementInput extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  static const _maxLength = 100;

  const _RefinementInput({required this.controller, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '직접 수정 요청 (선택)',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: controller,
            style: const TextStyle(color: AppColors.textPrimary),
            maxLength: _maxLength,
            maxLines: 2,
            minLines: 1,
            onChanged: onChanged,
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: AppColors.surface,
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.button),
                borderSide: const BorderSide(color: AppColors.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.button),
                borderSide: const BorderSide(color: AppColors.mint, width: 1.5),
              ),
              hintText: '원하는 느낌을 짧게 적어보세요',
              hintStyle: const TextStyle(color: AppColors.textSecondary),
              helperText: '예: 더 자연스럽게, 배경은 깔끔하게, 웃는 느낌으로',
              helperStyle: const TextStyle(color: AppColors.textSecondary),
              counterStyle: const TextStyle(color: AppColors.textSecondary),
              helperMaxLines: 2,
            ),
          ),
        ],
      ),
    );
  }
}

class _IdealImageErrorCard extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;

  const _IdealImageErrorCard({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.error.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(AppRadius.button),
        border: Border.all(color: AppColors.error.withValues(alpha: 0.22)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(
                Icons.error_outline_rounded,
                color: AppColors.error,
                size: 20,
              ),
              SizedBox(width: 8),
              Text(
                '이미지 생성에 실패했어요',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w900,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            message,
            style: const TextStyle(
              fontSize: 13,
              height: 1.4,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('다시 시도'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.primary,
                side: const BorderSide(color: AppColors.primary),
              ),
            ),
          ),
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
        borderRadius: BorderRadius.circular(AppRadius.button),
        border: Border.all(color: AppColors.mint.withValues(alpha: 0.2)),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 단순 안전 고지라 특정 색 역할(매칭/사주)을 주지 않고 중립 회색을
          // 쓴다 — 화면 전체가 초록으로 바뀌면서 남는 유일한 빨간 아이콘이
          // 되지 않도록.
          Icon(Icons.info_outline_rounded, color: AppColors.mint, size: 20),
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
  final bool last;

  const _OptionSection({
    required this.title,
    required this.options,
    required this.selected,
    required this.onSelected,
    this.last = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: options.map((option) {
              final active = option.key == selected;
              // 옵션 선택 칩 전체가 이 화면에서 가장 자주 보이는 요소라,
              // matchPrimary로 통일해야 "AI 이상형 = 프리미엄 기능"이라는
              // 인상이 화면 전체에 스며든다(버튼 하나만 초록색인 게 아니라).
              return Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () => onSelected(option.key),
                  borderRadius: BorderRadius.circular(AppRadius.chip),
                  child: AnimatedContainer(
                    duration: AppDurations.fast,
                    curve: AppCurves.standard,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: active
                          ? AppColors.mint
                          : AppColors.surface,
                      borderRadius: BorderRadius.circular(AppRadius.chip),
                      border: Border.all(
                        color: active ? AppColors.mint : AppColors.divider,
                      ),
                      boxShadow: active ? AppShadows.mintGlow : null,
                    ),
                    child: Text(
                      option.label,
                      style: TextStyle(
                        color: active
                            ? AppColors.onMint
                            : AppColors.textPrimary,
                        fontWeight: active ? FontWeight.w800 : FontWeight.w600,
                      ),
                    ),
                  ),
                ),
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
        color: AppColors.mint.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(AppRadius.button),
        border: Border.all(color: AppColors.mint.withValues(alpha: 0.2)),
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

/// 생성 중 상태를 보여주는 카드. 실제 진행률 신호가 없으므로 가짜 퍼센트바
/// 대신, 몇 초 간격으로 문구만 자연스럽게 바꿔가며 "진행되고 있다"는 느낌만
/// 준다 — 정확한 단계 수를 주장하지 않는다.
class _GeneratingCard extends StatefulWidget {
  const _GeneratingCard();

  @override
  State<_GeneratingCard> createState() => _GeneratingCardState();
}

class _GeneratingCardState extends State<_GeneratingCard>
    with SingleTickerProviderStateMixin {
  static const _messages = ['AI가 취향을 해석하고 있어요', '이미지를 생성하는 중이에요', '조금만 기다려주세요'];

  late final AnimationController _pulseController;
  int _messageIndex = 0;
  Timer? _messageTimer;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat(reverse: true);
    _messageTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!mounted) return;
      setState(() => _messageIndex = (_messageIndex + 1) % _messages.length);
    });
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _messageTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 20),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.premiumBorder),
      ),
      child: Column(
        children: [
          FadeTransition(
            opacity: Tween<double>(
              begin: 0.4,
              end: 1,
            ).animate(_pulseController),
            child: const Icon(
              Icons.auto_awesome_rounded,
              size: 32,
              color: AppColors.mint,
            ),
          ),
          const SizedBox(height: 16),
          AnimatedSwitcher(
            duration: AppDurations.base,
            child: Text(
              _messages[_messageIndex],
              key: ValueKey(_messageIndex),
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 결과 리포트 전체 — 헤더 + 히어로 이미지 + 선택 취향 칩 + AI 해석.
///
/// key(ValueKey(inputHash))가 바뀔 때마다 새로 마운트되므로, 재생성할 때마다
/// TweenAnimationBuilder가 처음부터 다시 실행되어 자연스러운 fade+scale-in이
/// 반복된다(새 이미지가 나올 때마다 "등장"하는 느낌).
class _IdealTypeReportCard extends StatelessWidget {
  final IdealTypeImageResult result;
  final IdealTypeImageOptions options;
  final VoidCallback onRegenerate;
  final VoidCallback onEditOptions;

  const _IdealTypeReportCard({
    super.key,
    required this.result,
    required this.options,
    required this.onRegenerate,
    required this.onEditOptions,
  });

  List<String> _optionLabels() {
    String labelOf(List<IdealTypeOption> set, String key) {
      for (final option in set) {
        if (option.key == key) return option.label;
      }
      return key;
    }

    return [
      labelOf(IdealTypeOptionSets.genders, options.gender),
      labelOf(IdealTypeOptionSets.moodsForGender(options.gender), options.mood),
      labelOf(
        IdealTypeOptionSets.stylesForGender(options.gender),
        options.style,
      ),
      labelOf(IdealTypeOptionSets.hairsForGender(options.gender), options.hair),
      labelOf(
        IdealTypeOptionSets.impressionsForGender(options.gender),
        options.impression,
      ),
      labelOf(IdealTypeOptionSets.backgrounds, options.background),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: AppDurations.emphasis,
      curve: AppCurves.standard,
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.scale(scale: 0.97 + 0.03 * value, child: child),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'AI 이상형 리포트',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w900,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            '선택한 취향을 바탕으로 생성한 AI 이미지예요.',
            style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 14),

          // ── 히어로 이미지 ──────────────────────────────────────────
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.card),
            child: AspectRatio(
              aspectRatio: 1,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.network(
                    result.imageUrl,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Container(
                      color: AppColors.surface,
                      alignment: Alignment.center,
                      child: const Icon(
                        Icons.broken_image_rounded,
                        color: AppColors.textSecondary,
                        size: 40,
                      ),
                    ),
                  ),
                  // 하단 gradient scrim — 실사 카드와 같은 톤(ink)을 재사용해
                  // "이것도 우리 앱의 사진 카드"라는 일관된 언어를 유지한다.
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: 90,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            AppColors.ink.withValues(alpha: 0),
                            AppColors.ink.withValues(alpha: 0.55),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 12,
                    top: 12,
                    child: PremiumBadge(label: 'AI 생성 이미지', solid: true),
                  ),
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: 12,
                    child: Text(
                      result.safetyLabel,
                      style: const TextStyle(
                        color: AppColors.surface,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            '실제 앱 사용자가 아닙니다.',
            style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 16),

          // ── 선택한 취향 ────────────────────────────────────────────
          const Text(
            '선택한 취향',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: _optionLabels()
                .map(
                  (label) => Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(AppRadius.chip),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Text(
                      label,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 16),

          // ── AI 해석 ────────────────────────────────────────────────
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(AppRadius.card),
              border: Border.all(color: AppColors.mint.withValues(alpha: 0.2)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(
                      Icons.auto_awesome_rounded,
                      size: 16,
                      color: AppColors.mint,
                    ),
                    SizedBox(width: 6),
                    Text(
                      'AI가 해석한 이상형',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  result.summary.trim().isNotEmpty
                      ? result.summary
                      : 'AI가 이 이상형에 대한 설명을 아직 준비하지 못했어요.',
                  style: const TextStyle(
                    fontSize: 14,
                    height: 1.55,
                    color: AppColors.textPrimary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),

          // ── CTA ────────────────────────────────────────────────────
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onEditOptions,
                  icon: const Icon(Icons.tune_rounded, size: 18),
                  label: const Text('조건 수정'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.mintDeep,
                    side: const BorderSide(color: AppColors.mintDeep),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  onPressed: onRegenerate,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('다시 생성'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.mint,
                    foregroundColor: AppColors.onMint,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
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
        borderRadius: BorderRadius.circular(AppRadius.button),
        border: Border.all(color: AppColors.border),
      ),
      child: const Text(
        '옵션을 고르고 이상형 이미지를 만들어보세요',
        style: TextStyle(color: AppColors.textSecondary),
      ),
    );
  }
}
