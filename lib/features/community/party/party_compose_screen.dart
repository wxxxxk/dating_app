import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../models/community/community_party.dart';
import '../../../services/community/community_service.dart';
import '../../../services/community/party_service.dart';
import '../community_text_guard.dart';
import 'party_widgets.dart';

/// 파티 작성 화면(Phase 4-4).
///
/// **정확한 주소·연락처·금액 입력 필드가 없다.** 지역은 광역 단위 선택뿐이고,
/// 제목·설명은 제출 전 클라이언트 안전 검사를 거친 뒤 서버가 다시 검사한다.
class PartyComposeScreen extends StatefulWidget {
  final PartyService partyService;

  const PartyComposeScreen({super.key, required this.partyService});

  @override
  State<PartyComposeScreen> createState() => _PartyComposeScreenState();
}

class _PartyComposeScreenState extends State<PartyComposeScreen> {
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();

  String _category = CommunityPartyOptions.categoryKeys.first;
  String _area = CommunityPartyOptions.areaKeys.first;
  DateTime? _startAt;
  int _maxParticipants = 4;

  bool _safetyConfirmed = false;
  bool _submitting = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _titleController.addListener(_onChanged);
    _descriptionController.addListener(_onChanged);
  }

  @override
  void dispose() {
    _titleController.removeListener(_onChanged);
    _descriptionController.removeListener(_onChanged);
    _titleController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  void _onChanged() => setState(() {});

  /// 서버와 같은 범위(최소 2시간 뒤 ~ 최대 30일)를 클라이언트에서도 강제한다.
  DateTime get _earliestStart =>
      DateTime.now().add(CommunityPartyOptions.minStartLead);
  DateTime get _latestStart =>
      DateTime.now().add(CommunityPartyOptions.maxStartAhead);

  bool get _startAtValid {
    final startAt = _startAt;
    if (startAt == null) return false;
    return !startAt.isBefore(_earliestStart) && !startAt.isAfter(_latestStart);
  }

  bool get _canSubmit =>
      !_submitting &&
      _safetyConfirmed &&
      _titleController.text.trim().isNotEmpty &&
      _descriptionController.text.trim().isNotEmpty &&
      _startAtValid;

  Future<void> _pickStartAt() async {
    final earliest = _earliestStart;
    final initial = _startAt != null && !_startAt!.isBefore(earliest)
        ? _startAt!
        : earliest;

    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      // 과거 날짜는 선택 자체가 불가능하다.
      firstDate: DateTime(earliest.year, earliest.month, earliest.day),
      lastDate: _latestStart,
    );
    if (date == null || !mounted) return;

    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (time == null || !mounted) return;

    final picked = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
    setState(() {
      _startAt = picked;
      _errorMessage = picked.isBefore(_earliestStart)
          ? '모임 시각은 지금부터 2시간 뒤부터 정할 수 있어요.'
          : null;
    });
  }

  Future<void> _submit() async {
    if (!_canSubmit) return;
    final title = _titleController.text.trim();
    final description = _descriptionController.text.trim();
    final startAt = _startAt;
    if (startAt == null) return;

    final allowed = await confirmCommunityTextBeforeSubmit(
      context,
      '$title\n$description',
    );
    if (!allowed || !mounted) return;

    setState(() {
      _submitting = true;
      _errorMessage = null;
    });
    try {
      final partyId = await widget.partyService.createParty(
        title: title,
        description: description,
        category: _category,
        area: _area,
        startAt: startAt,
        maxParticipants: _maxParticipants,
      );
      if (!mounted) return;
      Navigator.of(context).pop(partyId);
    } on CommunityActionError catch (e) {
      // 실패해도 입력은 그대로 유지한다.
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _errorMessage = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _errorMessage = CommunityService.genericErrorMessage;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final startAt = _startAt;
    return Scaffold(
      key: const ValueKey('party-compose-screen'),
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: const Text('파티 열기'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            20,
            8,
            20,
            24 + MediaQuery.of(context).viewInsets.bottom,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const PartySafetyNotice(),
              const SizedBox(height: 16),
              const _FieldLabel('제목'),
              TextField(
                key: const ValueKey('party-compose-title'),
                controller: _titleController,
                maxLength: CommunityPartyOptions.titleMaxLength,
                enabled: !_submitting,
                decoration: const InputDecoration(
                  hintText: '어떤 파티인지 한 줄로 알려주세요',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 6),
              const _FieldLabel('설명'),
              TextField(
                key: const ValueKey('party-compose-description'),
                controller: _descriptionController,
                maxLength: CommunityPartyOptions.descriptionMaxLength,
                minLines: 4,
                maxLines: 8,
                enabled: !_submitting,
                decoration: const InputDecoration(
                  hintText: '무엇을 함께 할지, 어떤 분들과 만나고 싶은지 적어주세요',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              const _FieldLabel('카테고리'),
              _OptionWrap(
                keyPrefix: 'party-compose-category',
                options: CommunityPartyOptions.categoryLabels,
                selected: _category,
                enabled: !_submitting,
                onSelected: (value) => setState(() => _category = value),
              ),
              const SizedBox(height: 16),
              const _FieldLabel('지역'),
              _OptionWrap(
                keyPrefix: 'party-compose-area',
                options: CommunityPartyOptions.areaLabels,
                selected: _area,
                enabled: !_submitting,
                onSelected: (value) => setState(() => _area = value),
              ),
              const SizedBox(height: 16),
              const _FieldLabel('모임 시각'),
              OutlinedButton.icon(
                key: const ValueKey('party-compose-start-at'),
                onPressed: _submitting ? null : _pickStartAt,
                icon: const Icon(Icons.schedule_rounded, size: 18),
                label: Text(
                  startAt == null ? '날짜와 시간 선택' : formatPartyStartAt(startAt),
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                '지금부터 2시간 뒤 ~ 30일 이내로 정할 수 있어요.',
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 16),
              const _FieldLabel('최대 인원'),
              _ParticipantStepper(
                value: _maxParticipants,
                enabled: !_submitting,
                onChanged: (value) => setState(() => _maxParticipants = value),
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                key: const ValueKey('party-compose-safety-check'),
                contentPadding: EdgeInsets.zero,
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                value: _safetyConfirmed,
                onChanged: _submitting
                    ? null
                    : (value) =>
                          setState(() => _safetyConfirmed = value == true),
                title: const Text(
                  '정확한 주소·연락처·금전 정보를 공개 설명에 적지 않았어요.',
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.4,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              if (_errorMessage != null) ...[
                const SizedBox(height: 4),
                Text(
                  _errorMessage!,
                  key: const ValueKey('party-compose-error'),
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: AppColors.error,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              FilledButton(
                key: const ValueKey('party-compose-submit'),
                onPressed: _canSubmit ? _submit : null,
                child: _submitting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('파티 열기'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  final String label;

  const _FieldLabel(this.label);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: AppColors.textPrimary,
        ),
      ),
    );
  }
}

/// key → 한국어 label 선택. 서버에는 항상 key만 보낸다.
class _OptionWrap extends StatelessWidget {
  final String keyPrefix;
  final Map<String, String> options;
  final String selected;
  final bool enabled;
  final ValueChanged<String> onSelected;

  const _OptionWrap({
    required this.keyPrefix,
    required this.options,
    required this.selected,
    required this.enabled,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final entry in options.entries)
          ChoiceChip(
            key: ValueKey('$keyPrefix-${entry.key}'),
            label: Text(entry.value),
            selected: selected == entry.key,
            onSelected: enabled ? (_) => onSelected(entry.key) : null,
          ),
      ],
    );
  }
}

class _ParticipantStepper extends StatelessWidget {
  final int value;
  final bool enabled;
  final ValueChanged<int> onChanged;

  const _ParticipantStepper({
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final canDecrease =
        enabled && value > CommunityPartyOptions.minParticipants;
    final canIncrease =
        enabled && value < CommunityPartyOptions.maxParticipants;
    return Row(
      children: [
        IconButton(
          key: const ValueKey('party-compose-participants-minus'),
          onPressed: canDecrease ? () => onChanged(value - 1) : null,
          icon: const Icon(Icons.remove_circle_outline_rounded),
        ),
        Text(
          '$value명',
          key: const ValueKey('party-compose-participants-value'),
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
        IconButton(
          key: const ValueKey('party-compose-participants-plus'),
          onPressed: canIncrease ? () => onChanged(value + 1) : null,
          icon: const Icon(Icons.add_circle_outline_rounded),
        ),
        const SizedBox(width: 6),
        const Expanded(
          child: Text(
            '호스트를 포함한 인원이에요 (3~8명).',
            style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
          ),
        ),
      ],
    );
  }
}
