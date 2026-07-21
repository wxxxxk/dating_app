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
    backgroundColor: AppColors.background,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.sheet)),
    ),
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
        child: Column(
          key: const ValueKey('message-action-sheet'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(child: _SheetHandle()),
            const SizedBox(height: 16),
            const Text(
              '선택한 메시지',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 6),
            _MessagePreview(text: messagePreview, maxLines: 2),
            const SizedBox(height: 10),
            ListTile(
              key: const ValueKey('message-action-report'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.flag_outlined, color: AppColors.error),
              title: const Text(
                '메시지 신고',
                style: TextStyle(color: AppColors.error),
              ),
              onTap: () => Navigator.of(sheetContext).pop(true),
            ),
            ListTile(
              key: const ValueKey('message-action-close'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(
                Icons.close_rounded,
                color: AppColors.textSecondary,
              ),
              title: const Text('닫기'),
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
    backgroundColor: AppColors.background,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.sheet)),
    ),
    builder: (_) => _MessageReportSheet(messagePreview: messagePreview),
  );
}

class _SheetHandle extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 42,
      height: 4,
      decoration: BoxDecoration(
        color: AppColors.border,
        borderRadius: BorderRadius.circular(AppRadius.chip),
      ),
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
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.button),
        border: Border.all(color: AppColors.border),
      ),
      child: Text(
        text.trim(),
        key: const ValueKey('message-report-preview'),
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontSize: 13,
          height: 1.45,
          color: AppColors.textPrimary,
        ),
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
              Center(child: _SheetHandle()),
              const SizedBox(height: 18),
              const Text(
                '이 메시지를 신고할까요?',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                '운영 검토를 위해 메시지와 대화 정보를 함께 확인해요.',
                style: TextStyle(
                  fontSize: 13,
                  height: 1.45,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 12),
              _MessagePreview(text: widget.messagePreview, maxLines: 3),
              const SizedBox(height: 6),
              ...messageReportReasonLabels.entries.map((entry) {
                final selected = _reason == entry.key;
                return ListTile(
                  key: ValueKey('message-report-reason-${entry.key}'),
                  contentPadding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  leading: Icon(
                    selected
                        ? Icons.radio_button_checked_rounded
                        : Icons.radio_button_unchecked_rounded,
                    color: selected
                        ? AppColors.primary
                        : AppColors.textSecondary,
                  ),
                  title: Text(entry.value),
                  onTap: () => setState(() => _reason = entry.key),
                );
              }),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('message-report-detail-field'),
                controller: _detailController,
                maxLines: 3,
                maxLength: reportDetailMaxLength,
                decoration: const InputDecoration(
                  labelText: '상세 내용 (선택)',
                  hintText: '상황을 간단히 적어주세요',
                ),
              ),
              CheckboxListTile(
                key: const ValueKey('message-report-block-checkbox'),
                value: _blockUser,
                contentPadding: EdgeInsets.zero,
                title: const Text('신고 후 이 사용자 차단'),
                subtitle: const Text('차단하면 서로 볼 수 없어요.'),
                onChanged: (value) =>
                    setState(() => _blockUser = value ?? false),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      key: const ValueKey('message-report-cancel-button'),
                      onPressed: () => Navigator.pop(context),
                      child: const Text('취소'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      key: const ValueKey('message-report-submit-button'),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.error,
                        foregroundColor: AppColors.surface,
                      ),
                      onPressed: _submit,
                      child: const Text('신고하기'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
