import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../services/safety/safety_service.dart';

/// 메시지 신고 시트 결과.
class MessageReportSubmission {
  final String reason;
  final String? detail;
  final bool blockUser;

  const MessageReportSubmission({
    required this.reason,
    required this.detail,
    required this.blockUser,
  });
}

/// 길게 누른 메시지에 대한 액션 시트. 오동작(의도치 않은 롱프레스)으로 바로
/// 신고 폼이 열리지 않도록 한 단계 둔다. 복사·삭제·답장은 제공하지 않는다.
///
/// 신고를 선택하면 `true`를 반환한다.
Future<bool?> showMessageActionSheet({
  required BuildContext context,
  required String messagePreview,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    backgroundColor: AppColors.surfacePrimary,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(AppRadius.sheet),
      ),
    ),
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
        child: Column(
          key: const ValueKey('message-action-sheet'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Center(child: _SheetHandle()),
            const SizedBox(height: 16),
            const Text(
              '선택한 메시지',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: AppColors.textMuted,
              ),
            ),
            const SizedBox(height: 6),
            _MessagePreview(text: messagePreview, maxLines: 2),
            const SizedBox(height: 12),
            _BoundaryActionRow(
              rowKey: const ValueKey('message-action-report'),
              icon: Icons.flag_outlined,
              label: '메시지 신고',
              accent: AppColors.statusDanger,
              danger: true,
              onTap: () => Navigator.of(sheetContext).pop(true),
            ),
            const SizedBox(height: 6),
            _BoundaryActionRow(
              rowKey: const ValueKey('message-action-close'),
              icon: Icons.close_rounded,
              label: '닫기',
              accent: AppColors.textMuted,
              muted: true,
              onTap: () => Navigator.of(sheetContext).pop(false),
            ),
          ],
        ),
      ),
    ),
  );
}

/// 메시지 신고 사유·상세 내용을 입력받는 바텀시트.
///
/// [messagePreview]는 **화면 표시 용도로만** 쓰인다 — 상태로 보관하거나 로그·
/// Firestore에 남기지 않는다. 신고 문서에는 matchId/messageId 참조만 저장된다.
Future<MessageReportSubmission?> showMessageReportSheet({
  required BuildContext context,
  required String messagePreview,
}) {
  return showModalBottomSheet<MessageReportSubmission>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surfacePrimary,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(AppRadius.sheet),
      ),
    ),
    builder: (_) => _MessageReportSheet(messagePreview: messagePreview),
  );
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

/// 신고 시트 헤더 — flag 아이콘 + 제목 + 설명. 과도한 danger 배경을 쓰지 않는다.
class _ReportHeader extends StatelessWidget {
  final String title;
  final String? description;

  const _ReportHeader({required this.title, this.description});

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
          child: const Icon(
            Icons.flag_outlined,
            size: 20,
            color: AppColors.statusDanger,
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

/// 신고 대상 메시지 미리보기. 원문을 가공해 보관하지 않고 표시만 한다.
class _MessagePreview extends StatelessWidget {
  final String text;
  final int maxLines;

  const _MessagePreview({required this.text, required this.maxLines});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surfaceSecondary,
        borderRadius: BorderRadius.circular(AppRadius.control),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.format_quote_rounded,
            size: 16,
            color: AppColors.textMuted,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text.trim(),
              key: const ValueKey('message-report-preview'),
              maxLines: maxLines,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 13,
                height: 1.45,
                color: AppColors.textStrong,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MessageReportSheet extends StatefulWidget {
  final String messagePreview;

  const _MessageReportSheet({required this.messagePreview});

  @override
  State<_MessageReportSheet> createState() => _MessageReportSheetState();
}

class _MessageReportSheetState extends State<_MessageReportSheet> {
  String _reason = messageReportReasonLabels.keys.first;
  bool _blockUser = false;
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
      MessageReportSubmission(
        reason: _reason,
        detail: detail.isEmpty ? null : detail,
        blockUser: _blockUser,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.85;

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(20, 8, 20, 20 + bottomInset),
          child: Column(
            key: const ValueKey('message-report-sheet'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Center(child: _SheetHandle()),
              const SizedBox(height: 18),
              const _ReportHeader(
                title: '이 메시지를 신고할까요?',
                description: '운영 검토를 위해 메시지와 대화 정보를 함께 확인해요.',
              ),
              const SizedBox(height: 14),
              _MessagePreview(text: widget.messagePreview, maxLines: 3),
              const SizedBox(height: 14),
              _ReasonGroup(
                labels: messageReportReasonLabels,
                selected: _reason,
                keyPrefix: 'message-report-reason-',
                onSelect: (key) => setState(() => _reason = key),
              ),
              const SizedBox(height: 14),
              TextField(
                key: const ValueKey('message-report-detail-field'),
                controller: _detailController,
                maxLines: 3,
                maxLength: reportDetailMaxLength,
                style: const TextStyle(color: AppColors.textStrong),
                decoration: _reportDetailDecoration(),
              ),
              const SizedBox(height: 4),
              _BlockAfterReportTile(
                tileKey: const ValueKey('message-report-block-checkbox'),
                value: _blockUser,
                onChanged: (value) => setState(() => _blockUser = value),
              ),
              const SizedBox(height: 16),
              _ReportActions(
                cancelKey: const ValueKey('message-report-cancel-button'),
                submitKey: const ValueKey('message-report-submit-button'),
                submitLabel: '신고하기',
                onCancel: () => Navigator.pop(context),
                onSubmit: _submit,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── 두 신고 시트가 공유하는 작은 presentation 조각 (같은 파일 내 private) ──────

/// 신고 상세 입력 필드 데코레이션 — focus 시 mint, 전체 red border를 쓰지 않는다.
InputDecoration _reportDetailDecoration() {
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
class _ReasonGroup extends StatelessWidget {
  final Map<String, String> labels;
  final String selected;
  final String keyPrefix;
  final ValueChanged<String> onSelect;

  const _ReasonGroup({
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
            _ReasonOption(
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

class _ReasonOption extends StatelessWidget {
  final Key optionKey;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ReasonOption({
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
              Icon(
                selected
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_unchecked_rounded,
                size: 20,
                color: selected
                    ? AppColors.brandPrimaryStrong
                    : AppColors.textMuted,
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
class _BlockAfterReportTile extends StatelessWidget {
  final Key tileKey;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _BlockAfterReportTile({
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
              Icon(
                value
                    ? Icons.check_box_rounded
                    : Icons.check_box_outline_blank_rounded,
                size: 22,
                color: value ? AppColors.statusDanger : AppColors.textMuted,
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

/// 취소(neutral) / 신고(danger) 하단 action. 좁은 폭에서는 세로로 쌓는다.
class _ReportActions extends StatelessWidget {
  final Key cancelKey;
  final Key submitKey;
  final String submitLabel;
  final VoidCallback onCancel;
  final VoidCallback onSubmit;

  const _ReportActions({
    required this.cancelKey,
    required this.submitKey,
    required this.submitLabel,
    required this.onCancel,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    final cancel = OutlinedButton(
      key: cancelKey,
      onPressed: onCancel,
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.textBody,
        side: const BorderSide(color: AppColors.borderStrong),
        minimumSize: const Size.fromHeight(50),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.control),
        ),
      ),
      child: const Text('취소'),
    );
    final submit = FilledButton(
      key: submitKey,
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.statusDanger,
        foregroundColor: AppColors.surface,
        minimumSize: const Size.fromHeight(50),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.control),
        ),
      ),
      onPressed: onSubmit,
      child: Text(
        submitLabel,
        style: const TextStyle(fontWeight: FontWeight.w800),
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 300) {
          return Column(children: [submit, const SizedBox(height: 8), cancel]);
        }
        return Row(
          children: [
            Expanded(child: cancel),
            const SizedBox(width: 10),
            Expanded(child: submit),
          ],
        );
      },
    );
  }
}

/// 액션 시트의 명확한 tap row (신고 / 닫기).
class _BoundaryActionRow extends StatelessWidget {
  final Key rowKey;
  final IconData icon;
  final String label;
  final Color accent;
  final bool danger;
  final bool muted;
  final VoidCallback onTap;

  const _BoundaryActionRow({
    required this.rowKey,
    required this.icon,
    required this.label,
    required this.accent,
    required this.onTap,
    this.danger = false,
    this.muted = false,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: rowKey,
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.control),
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: danger
              ? AppColors.statusDangerSoft
              : AppColors.surfaceSecondary,
          borderRadius: BorderRadius.circular(AppRadius.control),
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: accent),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: muted ? FontWeight.w600 : FontWeight.w700,
                  color: danger
                      ? AppColors.statusDanger
                      : (muted ? AppColors.textMuted : AppColors.textStrong),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
