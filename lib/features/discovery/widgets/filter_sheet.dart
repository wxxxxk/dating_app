import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../../../core/constants/profile_options.dart';
import '../../../core/theme/app_colors.dart';
import '../../../models/user_profile.dart';
import '../../../shared/widgets/premium_components.dart';

/// 디스커버리 필터 설정 바텀시트.
///
/// 저장은 호출 화면에서 처리하고, 이 위젯은 사용자가 선택한 필터만 반환한다.
///
/// 디자인(Phase 3-B, Editorial Match Preferences): 흰 카드가 반복되는 설정
/// 화면 대신, 실제 적용되는 조건(나이·거리·관심 대상·관계 목표)을 하나의
/// primary surface에 모으고, 참고용(선호 스타일)·예고(프리미엄 필터)는 divider
/// 아래 약한 톤으로 분리한다. 값·반환·callback·문구 계약은 그대로 유지한다.
class DiscoveryFilterSheet extends StatefulWidget {
  final DiscoveryFilter initialFilter;
  final bool hasLocation;

  /// 위치를 다시 가져와서 성공 여부를 돌려주는 콜백.
  /// null이면(주입 안 됐으면) 재시도 버튼 자체를 숨긴다.
  final Future<bool> Function()? onRetryLocation;

  /// "선호 스타일" 섹션에 내 태그를 참고용으로 보여주기 위한 프로필.
  /// null이면(아직 로딩 전 등) 해당 섹션은 안내 문구만 보여준다.
  final UserProfile? myProfile;

  const DiscoveryFilterSheet({
    super.key,
    required this.initialFilter,
    required this.hasLocation,
    this.onRetryLocation,
    this.myProfile,
  });

  @override
  State<DiscoveryFilterSheet> createState() => _DiscoveryFilterSheetState();
}

class _DiscoveryFilterSheetState extends State<DiscoveryFilterSheet> {
  late RangeValues _ageRange;
  late double _maxDistanceKm;
  late bool _distanceUnlimited;
  late String _gender;
  late String? _relationshipGoal;

  // widget.hasLocation을 그대로 쓰지 않고 로컬 상태로 복제하는 이유:
  // "위치 다시 확인" 버튼을 누르면 시트를 닫았다 다시 여는 대신, 이 시트
  // 안에서 바로 배너/슬라이더 활성 상태를 갱신하기 위함이다.
  late bool _hasLocation = widget.hasLocation;
  bool _checkingLocation = false;

  @override
  void initState() {
    super.initState();
    _ageRange = RangeValues(
      widget.initialFilter.ageMin.toDouble(),
      widget.initialFilter.ageMax.toDouble(),
    );
    _maxDistanceKm = widget.initialFilter.maxDistanceKm ?? 30;
    _distanceUnlimited = widget.initialFilter.maxDistanceKm == null;
    _gender = widget.initialFilter.gender;
    _relationshipGoal = widget.initialFilter.relationshipGoal;
  }

  Future<void> _retryLocation() async {
    final retry = widget.onRetryLocation;
    if (retry == null || _checkingLocation) return;
    setState(() => _checkingLocation = true);
    final ok = await retry();
    if (!mounted) return;
    setState(() {
      _hasLocation = ok;
      _checkingLocation = false;
    });
  }

  void _toggleUnlimited() {
    if (!_hasLocation) return;
    setState(() => _distanceUnlimited = !_distanceUnlimited);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.88,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            const Center(child: _SheetHandle()),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _FilterHeader(),
                    const SizedBox(height: 18),
                    _buildPrimarySurface(),
                    const SizedBox(height: 22),
                    _buildReferenceSection(),
                    const SizedBox(height: 14),
                    const _PremiumFilterTeaser(),
                  ],
                ),
              ),
            ),
            _buildActionBar(),
          ],
        ),
      ),
    );
  }

  // ── 실제 적용 조건(primary surface) ──────────────────────────────────────────

  Widget _buildPrimarySurface() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
      decoration: BoxDecoration(
        color: AppColors.surfacePrimary,
        borderRadius: BorderRadius.circular(AppRadius.surface),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionEyebrow(label: '적용되는 조건'),
          const SizedBox(height: 16),
          _buildAgeField(),
          const _FieldDivider(),
          _buildDistanceField(),
          const _FieldDivider(),
          _buildGenderField(),
          const _FieldDivider(),
          _buildGoalField(),
        ],
      ),
    );
  }

  Widget _buildAgeField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _FieldLabel(
          title: '나이',
          value: '${_ageRange.start.round()}~${_ageRange.end.round()}세',
        ),
        const SizedBox(height: 2),
        _sliderTheme(
          child: RangeSlider(
            min: DiscoveryFilter.defaultAgeMin.toDouble(),
            max: DiscoveryFilter.defaultAgeMax.toDouble(),
            divisions:
                DiscoveryFilter.defaultAgeMax - DiscoveryFilter.defaultAgeMin,
            values: _ageRange,
            labels: RangeLabels(
              '${_ageRange.start.round()}세',
              '${_ageRange.end.round()}세',
            ),
            onChanged: (values) => setState(() => _ageRange = values),
          ),
        ),
      ],
    );
  }

  Widget _buildDistanceField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _FieldLabel(
          title: '거리',
          value: _distanceUnlimited ? '무제한' : '${_maxDistanceKm.round()}km 이내',
        ),
        const SizedBox(height: 2),
        // 무제한이거나 위치가 없으면 slider의 시각 강도를 낮춰, 값이 활성처럼
        // 보이지 않게 한다(상태는 onChanged=null로 이미 잠겨 있음).
        Opacity(
          opacity: (_distanceUnlimited || !_hasLocation) ? 0.4 : 1,
          child: _sliderTheme(
            child: Slider(
              min: 1,
              max: 50,
              divisions: 49,
              value: _maxDistanceKm,
              label: '${_maxDistanceKm.round()}km',
              onChanged: _hasLocation && !_distanceUnlimited
                  ? (value) => setState(() => _maxDistanceKm = value)
                  : null,
            ),
          ),
        ),
        _UnlimitedToggle(
          value: _distanceUnlimited,
          enabled: _hasLocation,
          onTap: _toggleUnlimited,
        ),
        if (!_hasLocation) ...[
          const SizedBox(height: 8),
          _LocationWarningBanner(
            checking: _checkingLocation,
            onRetry: widget.onRetryLocation == null ? null : _retryLocation,
            onOpenSettings: () => Geolocator.openAppSettings(),
          ),
        ],
      ],
    );
  }

  Widget _buildGenderField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _FieldLabel(title: '관심 대상'),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<String>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 'all', label: Text('전체')),
              ButtonSegment(value: 'female', label: Text('여성')),
              ButtonSegment(value: 'male', label: Text('남성')),
            ],
            selected: {_gender},
            onSelectionChanged: (value) {
              setState(() => _gender = value.first);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildGoalField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _FieldLabel(title: '관계 목표'),
        const SizedBox(height: 12),
        _RelationshipGoalPicker(
          selected: _relationshipGoal,
          onChanged: (value) => setState(() => _relationshipGoal = value),
        ),
      ],
    );
  }

  // ── 참고 정보(선호 스타일) — divider 아래 약한 톤 ────────────────────────────

  Widget _buildReferenceSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 1, color: AppColors.borderSubtle),
        const SizedBox(height: 18),
        const _SectionEyebrow(label: '내 프로필 참고'),
        const SizedBox(height: 6),
        const Text(
          '선호 스타일',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w800,
            color: AppColors.textStrong,
          ),
        ),
        const SizedBox(height: 10),
        _StylePreferencePreview(profile: widget.myProfile),
      ],
    );
  }

  // ── 하단 고정 action bar ─────────────────────────────────────────────────────

  Widget _buildActionBar() {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surfacePrimary,
        border: Border(top: BorderSide(color: AppColors.borderSubtle)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: () {
                Navigator.pop(context, const DiscoveryFilter());
              },
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
                foregroundColor: AppColors.textBody,
                side: const BorderSide(color: AppColors.borderStrong),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.control),
                ),
              ),
              child: const Text('초기화'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: FilledButton(
              onPressed: _apply,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.control),
                ),
              ),
              child: const Text(
                '적용',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _apply() {
    Navigator.pop(
      context,
      DiscoveryFilter(
        ageMin: _ageRange.start.round(),
        ageMax: _ageRange.end.round(),
        maxDistanceKm: _distanceUnlimited || !_hasLocation
            ? null
            : _maxDistanceKm.roundToDouble(),
        gender: _gender,
        relationshipGoal: _relationshipGoal,
      ),
    );
  }

  /// 나이·거리 slider 공통 톤 — active는 brandPrimaryStrong, inactive는 옅은
  /// canvasSubtle, thumb는 과한 glow 없이 명확하게. semantics는 기본 유지.
  Widget _sliderTheme({required Widget child}) {
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: 4,
        activeTrackColor: AppColors.brandPrimaryStrong,
        inactiveTrackColor: AppColors.canvasSubtle,
        thumbColor: AppColors.brandPrimaryStrong,
        overlayColor: AppColors.brandPrimaryStrong.withValues(alpha: 0.12),
        rangeThumbShape: const RoundRangeSliderThumbShape(
          enabledThumbRadius: 9,
        ),
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 9),
      ),
      child: child,
    );
  }
}

class _SheetHandle extends StatelessWidget {
  const _SheetHandle();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 42,
      height: 4,
      decoration: BoxDecoration(
        color: AppColors.borderStrong,
        borderRadius: BorderRadius.circular(AppRadius.chip),
      ),
    );
  }
}

/// 시트 상단 header — 매우 옅은 mint wash + tune 아이콘 + 제목/설명.
class _FilterHeader extends StatelessWidget {
  const _FilterHeader();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surfaceMintSoft,
        borderRadius: BorderRadius.circular(AppRadius.surface),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: const BoxDecoration(
              color: AppColors.surfacePrimary,
              shape: BoxShape.circle,
            ),
            child: const ExcludeSemantics(
              child: Icon(
                Icons.tune_rounded,
                size: 20,
                color: AppColors.mintDeep,
              ),
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '어떤 인연을 찾고 있나요?',
                  style: TextStyle(
                    fontSize: 21,
                    fontWeight: FontWeight.w800,
                    color: AppColors.textStrong,
                    height: 1.2,
                  ),
                ),
                SizedBox(height: 6),
                Text(
                  '조건은 추천 후보를 더 정교하게 만드는 데 사용돼요.',
                  style: TextStyle(
                    fontSize: 13.5,
                    color: AppColors.textBody,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 섹션 구분용 작은 대문자 eyebrow(강한 카드 대신 톤/여백으로 구분).
class _SectionEyebrow extends StatelessWidget {
  final String label;
  const _SectionEyebrow({required this.label});

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w800,
        color: AppColors.textMuted,
        letterSpacing: 0.4,
      ),
    );
  }
}

/// primary surface 내부 field 사이 subtle divider(중첩 카드 대신 여백+선으로 구분).
class _FieldDivider extends StatelessWidget {
  const _FieldDivider();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 18),
      child: Divider(height: 1, color: AppColors.borderSubtle),
    );
  }
}

/// 거리 제한 없음 토글 — Checkbox + Text를 하나의 tap 영역으로 정리한다.
/// onChanged 의미(무제한 on/off)와 위치 없음 시 비활성은 그대로 유지한다.
class _UnlimitedToggle extends StatelessWidget {
  final bool value;
  final bool enabled;
  final VoidCallback onTap;

  const _UnlimitedToggle({
    required this.value,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(AppRadius.control),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            IgnorePointer(
              child: Checkbox(
                value: value,
                onChanged: enabled ? (_) {} : null,
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '거리 제한 없음',
              style: TextStyle(
                fontSize: 14,
                fontWeight: value ? FontWeight.w700 : FontWeight.w500,
                color: enabled ? AppColors.textStrong : AppColors.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 관계 목표 단일 선택 — "전체"(null 취급)를 첫 칩으로 두고, 나머지는
/// ProfileOptions.relationshipGoals를 그대로 재사용한다(온보딩/프로필 편집과
/// 같은 문구 → 사용자가 같은 개념을 다시 배울 필요가 없다).
class _RelationshipGoalPicker extends StatelessWidget {
  final String? selected;
  final ValueChanged<String?> onChanged;

  const _RelationshipGoalPicker({
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _GoalChip(
          label: '전체',
          active: selected == null,
          onTap: () => onChanged(null),
        ),
        ...ProfileOptions.relationshipGoals.map(
          (option) => _GoalChip(
            label: option.label,
            active: selected == option.key,
            onTap: () => onChanged(option.key),
          ),
        ),
      ],
    );
  }
}

class _GoalChip extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _GoalChip({
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: active,
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.chip),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            color: active
                ? AppColors.surfaceMintSoft
                : AppColors.surfaceSecondary,
            borderRadius: BorderRadius.circular(AppRadius.chip),
            border: Border.all(
              color: active ? AppColors.mintDeep : AppColors.borderSubtle,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (active) ...[
                const Icon(
                  Icons.check_rounded,
                  size: 15,
                  color: AppColors.mintDeep,
                ),
                const SizedBox(width: 4),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: active ? FontWeight.w800 : FontWeight.w500,
                  color: active ? AppColors.mintDeep : AppColors.textBody,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "선호 스타일" — 실제 필터가 아니라 내 프로필 태그를 참고용으로만 보여준다.
/// 실제로 후보를 좁히지 않으므로 선택 가능한 칩처럼 보이지 않게(비활성 톤,
/// onTap 없음) 의도적으로 다르게 그린다 — 필터인 척 속이지 않기 위함이다.
class _StylePreferencePreview extends StatelessWidget {
  final UserProfile? profile;

  const _StylePreferencePreview({required this.profile});

  @override
  Widget build(BuildContext context) {
    final p = profile;
    if (p == null) {
      return const Text(
        '프로필을 불러오는 중이에요',
        style: TextStyle(fontSize: 13, color: AppColors.textMuted),
      );
    }

    final labels = [
      ...ProfileOptions.keysToLabels(ProfileOptions.interests, p.interests),
      ...ProfileOptions.keysToLabels(
        ProfileOptions.personalities,
        p.personalityTags,
      ),
      ...ProfileOptions.keysToLabels(ProfileOptions.ideals, p.idealTags),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '내 프로필의 관심사·성향·이상형 태그예요. 아직 필터로 좁히는 기능은 아니고,'
          ' 추천 후보를 정교하게 만드는 데 참고로 쓰여요.',
          style: TextStyle(
            fontSize: 12,
            color: AppColors.textMuted,
            height: 1.45,
          ),
        ),
        const SizedBox(height: 10),
        if (labels.isEmpty)
          const Text(
            '프로필 편집에서 태그를 추가해보세요',
            style: TextStyle(fontSize: 13, color: AppColors.textMuted),
          )
        else
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: labels
                .take(8)
                .map(
                  (label) => Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.canvasSubtle,
                      borderRadius: BorderRadius.circular(AppRadius.chip),
                    ),
                    child: Text(
                      label,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
      ],
    );
  }
}

/// 아직 제공되지 않는 상세 필터에 대한 예고 카드.
///
/// 구체적인 필드(학력/연소득/자산 등)는 절대 언급하지 않는다 — 실제로 없는
/// 기능을 있는 것처럼 보이게 하지 않기 위함이다. 순수 안내 문구만 보여준다.
class _PremiumFilterTeaser extends StatelessWidget {
  const _PremiumFilterTeaser();

  @override
  Widget build(BuildContext context) {
    return const PremiumNoticeCard(
      icon: Icons.workspace_premium_outlined,
      title: '프리미엄 필터',
      description: '더 세밀한 조건 필터는 추후 제공 예정이에요.',
    );
  }
}

/// 위치가 없어 거리 필터가 무시되고 있음을 알리는 배너.
///
/// 조용히 "무제한"으로 동작하는 대신, 원인(위치 없음)과 해결 방법(설정 열기 /
/// 다시 확인)을 바로 옆에서 보여준다. 위험(danger red)이 아니라 안내(amber)다.
class _LocationWarningBanner extends StatelessWidget {
  final bool checking;
  final VoidCallback? onRetry;
  final VoidCallback onOpenSettings;

  const _LocationWarningBanner({
    required this.checking,
    required this.onRetry,
    required this.onOpenSettings,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.statusWarningSoft,
        borderRadius: BorderRadius.circular(AppRadius.control),
        border: Border.all(
          color: AppColors.statusWarning.withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.location_off_rounded,
                size: 18,
                color: AppColors.statusWarning,
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  '위치 권한을 허용해야 거리 필터를 사용할 수 있어요. 지금은 거리와 '
                  '무관하게 모든 사람이 보여요.',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.5,
                    color: AppColors.textBody,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              if (onRetry != null) ...[
                TextButton(
                  onPressed: checking ? null : onRetry,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 44),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: checking
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('위치 다시 확인'),
                ),
                const SizedBox(width: 4),
              ],
              TextButton(
                onPressed: onOpenSettings,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 44),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('앱 설정 열기'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// field header — 왼쪽 label + 오른쪽 현재 값(mint). 값을 큰 badge로 과장하지
/// 않고 compact tonal text로만 보여준다.
class _FieldLabel extends StatelessWidget {
  final String title;
  final String? value;

  const _FieldLabel({required this.title, this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: AppColors.textStrong,
            ),
          ),
        ),
        if (value != null)
          Text(
            value!,
            style: const TextStyle(
              fontSize: 13.5,
              color: AppColors.mintDeep,
              fontWeight: FontWeight.w800,
            ),
          ),
      ],
    );
  }
}
