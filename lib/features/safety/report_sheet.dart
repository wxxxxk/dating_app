import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../services/safety/safety_service.dart';

class ReportSubmission {
  final String reason;
  final String? detail;
  final bool blockUser;

  const ReportSubmission({
    required this.reason,
    required this.detail,
    required this.blockUser,
  });
}

/// 사용자 신고 사유와 상세 내용을 입력받는 바텀시트.
///
/// 메시지 신고 시트(`message_report_sheet.dart`)와 같은 Calm Boundary 디자인
/// 문법을 쓰지만, 메시지 미리보기는 두지 않는다. 반환값·기본값·문구는 유지한다.
Future<ReportSubmission?> showReportSheet(BuildContext context) {
  return showModalBottomSheet<ReportSubmission>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surfacePrimary,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(AppRadius.sheet),
      ),
    ),
    builder: (_) => const _ReportSheet(),
  );
}

class _ReportSheet extends StatefulWidget {
  const _ReportSheet();

  @override
  State<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends State<_ReportSheet> {
  String _reason = reportReasonLabels.keys.first;
  bool _blockUser = true;
  final _detailController = TextEditingController();

  @override
  void dispose() {
    _detailController.dispose();
    super.dispose();
  }

  void _submit() {
    final detail = _detailController.text.trim();
    if (detail.length > reportDetailMaxLength) return;
    Navigator.pop(
      context,
      ReportSubmission(
        reason: _reason,
        detail: detail.isEmpty ? null : detail,
        blockUser: _blockUser,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    // 작은 화면·키보드 노출 상황에서 내용이 잘리지 않도록 스크롤 가능하게 한다.
    final maxHeight = MediaQuery.sizeOf(context).height * 0.85;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(20, 8, 20, 20 + bottomInset),
          child: Column(
            key: const ValueKey('report-sheet'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Center(child: _ReportSheetHandle()),
              const SizedBox(height: 18),
              const _ReportSheetHeader(
                title: '신고하기',
                description: '불편했던 이유를 알려주세요. 접수 내용은 운영 검토에만 사용해요.',
              ),
              const SizedBox(height: 14),
              _ReportReasonGroup(
                labels: reportReasonLabels,
                selected: _reason,
                keyPrefix: 'report-reason-',
                onSelect: (key) => setState(() => _reason = key),
              ),
              const SizedBox(height: 14),
              TextField(
                key: const ValueKey('report-detail-field'),
                controller: _detailController,
                maxLines: 3,
                maxLength: reportDetailMaxLength,
                style: const TextStyle(color: AppColors.textStrong),
                decoration: _reportSheetDetailDecoration(),
              ),
              const SizedBox(height: 4),
              _ReportBlockAfterTile(
                tileKey: const ValueKey('report-block-checkbox'),
                value: _blockUser,
                onChanged: (value) => setState(() => _blockUser = value),
              ),
              const SizedBox(height: 16),
              _ReportSubmitButton(
                buttonKey: const ValueKey('report-submit-button'),
                onSubmit: _submit,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── report_sheet 전용 presentation 조각 (message_report_sheet와 같은 문법) ─────

class _ReportSheetHandle extends StatelessWidget {
  const _ReportSheetHandle();

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

/// 신고 시트 헤더 — flag 아이콘 + 제목 + 설명. 과도한 danger 배경을 쓰지 않는다.
class _ReportSheetHeader extends StatelessWidget {
  final String title;
  final String? description;

  const _ReportSheetHeader({required this.title, this.description});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: const BoxDecoration(
            color: AppColors.statusDangerSoft,
            shape: BoxShape.circle,
          ),
          child: const ExcludeSemantics(
            child: Icon(
              Icons.flag_outlined,
              size: 20,
              color: AppColors.statusDanger,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  height: 1.25,
                  color: AppColors.textStrong,
                ),
              ),
              if (description != null) ...[
                const SizedBox(height: 6),
                Text(
                  description!,
                  style: const TextStyle(
                    fontSize: 13,
                    height: 1.45,
                    color: AppColors.textBody,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// 신고 상세 입력 필드 데코레이션 — focus 시 mint, 전체 red border를 쓰지 않는다.
InputDecoration _reportSheetDetailDecoration() {
  return InputDecoration(
    labelText: '상세 내용 (선택)',
    hintText: '상황을 간단히 적어주세요',
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
  );
}

/// 신고 사유 선택 그룹 — 하나의 surface 안에서 divider로 구분, 선택 시 mint.
class _ReportReasonGroup extends StatelessWidget {
  final Map<String, String> labels;
  final String selected;
  final String keyPrefix;
  final ValueChanged<String> onSelect;

  const _ReportReasonGroup({
    required this.labels,
    required this.selected,
    required this.keyPrefix,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final entries = labels.entries.toList();
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfacePrimary,
        borderRadius: BorderRadius.circular(AppRadius.surface),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < entries.length; i++) ...[
            if (i > 0)
              const Divider(
                height: 1,
                thickness: 1,
                color: AppColors.borderSubtle,
              ),
            _ReportReasonOption(
              optionKey: ValueKey('$keyPrefix${entries[i].key}'),
              label: entries[i].value,
              selected: selected == entries[i].key,
              onTap: () => onSelect(entries[i].key),
            ),
          ],
        ],
      ),
    );
  }
}

class _ReportReasonOption extends StatelessWidget {
  final Key optionKey;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ReportReasonOption({
    required this.optionKey,
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
        key: optionKey,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          constraints: const BoxConstraints(minHeight: 48),
          color: selected
              ? AppColors.surfaceMintSoft
              : AppColors.surfacePrimary,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          child: Row(
            children: [
              ExcludeSemantics(
                child: Icon(
                  selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                  size: 20,
                  color: selected
                      ? AppColors.brandPrimaryStrong
                      : AppColors.textMuted,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected ? AppColors.textStrong : AppColors.textBody,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "신고 후 차단" 선택 — 신고와 별개 선택임을 명확히 하는 pale danger surface.
class _ReportBlockAfterTile extends StatelessWidget {
  final Key tileKey;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _ReportBlockAfterTile({
    required this.tileKey,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      checked: value,
      child: InkWell(
        key: tileKey,
        onTap: () => onChanged(!value),
        borderRadius: BorderRadius.circular(AppRadius.control),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: value
                ? AppColors.statusDangerSoft
                : AppColors.surfaceSecondary,
            borderRadius: BorderRadius.circular(AppRadius.control),
          ),
          child: Row(
            children: [
              ExcludeSemantics(
                child: Icon(
                  value
                      ? Icons.check_box_rounded
                      : Icons.check_box_outline_blank_rounded,
                  size: 22,
                  color: value ? AppColors.statusDanger : AppColors.textMuted,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '신고 후 이 사용자 차단',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textStrong,
                      ),
                    ),
                    const SizedBox(height: 2),
                    const Text(
                      '차단하면 서로 볼 수 없어요.',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 신고 제출 버튼 — danger filled, 좁은 화면에서도 label이 잘리지 않는 높이.
class _ReportSubmitButton extends StatelessWidget {
  final Key buttonKey;
  final VoidCallback onSubmit;

  const _ReportSubmitButton({required this.buttonKey, required this.onSubmit});

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      key: buttonKey,
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.statusDanger,
        foregroundColor: AppColors.surface,
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.control),
        ),
      ),
      onPressed: onSubmit,
      child: const Text('신고 제출', style: TextStyle(fontWeight: FontWeight.w800)),
    );
  }
}
