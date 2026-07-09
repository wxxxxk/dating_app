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

/// 신고 사유와 상세 내용을 입력받는 바텀시트.
Future<ReportSubmission?> showReportSheet(BuildContext context) {
  return showModalBottomSheet<ReportSubmission>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.background,
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

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 8, 20, 20 + bottomInset),
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
                  borderRadius: BorderRadius.circular(AppRadius.chip),
                ),
              ),
            ),
            const SizedBox(height: 18),
            const Text(
              '신고하기',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 14),
            ...reportReasonLabels.entries.map((entry) {
              final selected = _reason == entry.key;
              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                  color: selected ? AppColors.primary : AppColors.textSecondary,
                ),
                title: Text(entry.value),
                onTap: () => setState(() => _reason = entry.key),
              );
            }),
            const SizedBox(height: 8),
            TextField(
              controller: _detailController,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: '상세 내용 (선택)',
                hintText: '상황을 간단히 적어주세요',
              ),
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
              value: _blockUser,
              contentPadding: EdgeInsets.zero,
              title: const Text('신고 후 이 사용자 차단'),
              subtitle: const Text('차단하면 서로 볼 수 없어요.'),
              onChanged: (value) => setState(() => _blockUser = value ?? true),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.error,
                  foregroundColor: AppColors.surface,
                ),
                onPressed: () {
                  Navigator.pop(
                    context,
                    ReportSubmission(
                      reason: _reason,
                      detail: _detailController.text.trim().isEmpty
                          ? null
                          : _detailController.text.trim(),
                      blockUser: _blockUser,
                    ),
                  );
                },
                child: const Text('신고 제출'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
