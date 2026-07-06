import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../models/user_profile.dart';

/// 디스커버리 필터 설정 바텀시트.
///
/// 저장은 호출 화면에서 처리하고, 이 위젯은 사용자가 선택한 필터만 반환한다.
class DiscoveryFilterSheet extends StatefulWidget {
  final DiscoveryFilter initialFilter;
  final bool hasLocation;

  const DiscoveryFilterSheet({
    super.key,
    required this.initialFilter,
    required this.hasLocation,
  });

  @override
  State<DiscoveryFilterSheet> createState() => _DiscoveryFilterSheetState();
}

class _DiscoveryFilterSheetState extends State<DiscoveryFilterSheet> {
  late RangeValues _ageRange;
  late double _maxDistanceKm;
  late bool _distanceUnlimited;
  late String _gender;

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
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.border,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              '필터',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 22),
            _SectionHeader(
              title: '나이',
              value: '${_ageRange.start.round()}~${_ageRange.end.round()}세',
            ),
            RangeSlider(
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
            const SizedBox(height: 12),
            _SectionHeader(
              title: '거리',
              value: _distanceUnlimited
                  ? '무제한'
                  : '${_maxDistanceKm.round()}km 이내',
            ),
            Row(
              children: [
                Checkbox(
                  value: _distanceUnlimited,
                  onChanged: widget.hasLocation
                      ? (value) {
                          setState(() => _distanceUnlimited = value ?? true);
                        }
                      : null,
                ),
                const Text('거리 제한 없음'),
              ],
            ),
            Slider(
              min: 1,
              max: 50,
              divisions: 49,
              value: _maxDistanceKm,
              label: '${_maxDistanceKm.round()}km',
              onChanged: widget.hasLocation && !_distanceUnlimited
                  ? (value) => setState(() => _maxDistanceKm = value)
                  : null,
            ),
            if (!widget.hasLocation)
              const Text(
                '현재 위치가 없어 거리 필터는 적용되지 않아요.',
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
              ),
            const SizedBox(height: 18),
            const _SectionHeader(title: '관심 성별'),
            const SizedBox(height: 10),
            SegmentedButton<String>(
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
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () {
                      Navigator.pop(context, const DiscoveryFilter());
                    },
                    child: const Text('초기화'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: _apply,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.primary,
                    ),
                    child: const Text('적용'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _apply() {
    Navigator.pop(
      context,
      DiscoveryFilter(
        ageMin: _ageRange.start.round(),
        ageMax: _ageRange.end.round(),
        maxDistanceKm: _distanceUnlimited || !widget.hasLocation
            ? null
            : _maxDistanceKm.roundToDouble(),
        gender: _gender,
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final String? value;

  const _SectionHeader({required this.title, this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: AppColors.textPrimary,
            ),
          ),
        ),
        if (value != null)
          Text(
            value!,
            style: const TextStyle(
              fontSize: 13,
              color: AppColors.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
      ],
    );
  }
}
