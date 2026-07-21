import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../services/community/community_service.dart';
import '../../services/safety/safety_service.dart';

/// 커뮤니티 신고 사유 key → 표시 라벨(서버 allowlist와 동일한 key 집합).
const communityReportReasonLabels = <String, String>{
  'abusive_language': '욕설·모욕',
  'sexual_content': '성적 불쾌감',
  'hate_threat': '혐오·협박',
  'spam_scam': '사기·스팸',
  'personal_info': '개인정보 노출·요구',
  'impersonation': '사칭',
  'other': '기타',
};

const int communityReportDetailMaxLength = 500;

/// 신고 결과. 차단까지 했는지 화면이 알아야 목록을 즉시 갱신할 수 있다.
class CommunityReportOutcome {
  final bool reported;
  final bool blocked;

  const CommunityReportOutcome({required this.reported, required this.blocked});
}

/// 게시물·댓글 신고 시트(Phase 4-2).
///
/// 신고 문서에는 원문 snapshot을 담지 않는다(서버가 id 참조만 저장한다).
/// 신고와 차단은 서로 다른 경로다 — 신고가 실패하면 차단하지 않는다.
Future<CommunityReportOutcome?> showCommunityReportSheet(
  BuildContext context, {
  required CommunityService communityService,
  required SafetyService safetyService,
  required String currentUid,
  required String targetType,
  required String postId,
  String commentId = '',
  required String reportedUid,
}) {
  return showModalBottomSheet<CommunityReportOutcome>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.sheet)),
    ),
    builder: (_) => CommunityReportSheet(
      communityService: communityService,
      safetyService: safetyService,
      currentUid: currentUid,
      targetType: targetType,
      postId: postId,
      commentId: commentId,
      reportedUid: reportedUid,
    ),
  );
}

class CommunityReportSheet extends StatefulWidget {
  final CommunityService communityService;
  final SafetyService safetyService;
  final String currentUid;
  final String targetType;
  final String postId;
  final String commentId;
  final String reportedUid;

  const CommunityReportSheet({
    super.key,
    required this.communityService,
    required this.safetyService,
    required this.currentUid,
    required this.targetType,
    required this.postId,
    required this.commentId,
    required this.reportedUid,
  });

  @override
  State<CommunityReportSheet> createState() => _CommunityReportSheetState();
}

class _CommunityReportSheetState extends State<CommunityReportSheet> {
  final _detailController = TextEditingController();

  String? _reason;
  bool _blockAfterReport = false;
  bool _submitting = false;
  String? _errorMessage;

  @override
  void dispose() {
    _detailController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final reason = _reason;
    if (reason == null || _submitting) return;

    setState(() {
      _submitting = true;
      _errorMessage = null;
    });

    try {
      await widget.communityService.reportContent(
        targetType: widget.targetType,
        postId: widget.postId,
        commentId: widget.commentId,
        reason: reason,
        detail: _detailController.text,
      );
    } on CommunityActionError catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _errorMessage = e.message;
      });
      return;
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _errorMessage = CommunityService.genericErrorMessage;
      });
      return;
    }

    // 신고가 성공했을 때만 선택 차단을 진행한다(하나의 트랜잭션이 아니다).
    var blocked = false;
    if (_blockAfterReport && widget.reportedUid.isNotEmpty) {
      try {
        await widget.safetyService.blockUser(
          currentUid: widget.currentUid,
          blockedUid: widget.reportedUid,
        );
        blocked = true;
      } catch (e) {
        if (kDebugMode) debugPrint('[Community] 차단 실패 code=${e.runtimeType}');
      }
    }

    if (!mounted) return;
    Navigator.of(
      context,
    ).pop(CommunityReportOutcome(reported: true, blocked: blocked));
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      key: const ValueKey('community-report-sheet'),
      padding: EdgeInsets.only(bottom: bottomInset),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.targetType == 'comment' ? '댓글 신고' : '게시물 신고',
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.bold,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              '신고 내용은 운영팀만 확인해요. 상대에게 알리지 않아요.',
              style: TextStyle(
                fontSize: 12.5,
                height: 1.5,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 10),
            // 기존 신고 시트(message_report_sheet)와 같은 선택 UI를 쓴다.
            ...communityReportReasonLabels.entries.map((entry) {
              final selected = _reason == entry.key;
              return ListTile(
                key: ValueKey('community-report-reason-${entry.key}'),
                contentPadding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                leading: Icon(
                  selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                  color: selected ? AppColors.primary : AppColors.textSecondary,
                ),
                title: Text(
                  entry.value,
                  style: const TextStyle(
                    fontSize: 14,
                    color: AppColors.textPrimary,
                  ),
                ),
                onTap: _submitting
                    ? null
                    : () => setState(() => _reason = entry.key),
              );
            }),
            const SizedBox(height: 6),
            TextField(
              key: const ValueKey('community-report-detail'),
              controller: _detailController,
              maxLines: 3,
              maxLength: communityReportDetailMaxLength,
              enabled: !_submitting,
              decoration: const InputDecoration(
                hintText: '자세한 내용을 알려주시면 검토에 도움이 돼요. (선택)',
                border: OutlineInputBorder(),
              ),
            ),
            CheckboxListTile(
              key: const ValueKey('community-report-block'),
              contentPadding: EdgeInsets.zero,
              dense: true,
              controlAffinity: ListTileControlAffinity.leading,
              value: _blockAfterReport,
              onChanged: _submitting
                  ? null
                  : (value) =>
                        setState(() => _blockAfterReport = value == true),
              title: const Text(
                '신고 후 이 사용자 차단',
                style: TextStyle(fontSize: 14, color: AppColors.textPrimary),
              ),
            ),
            if (_errorMessage != null) ...[
              const SizedBox(height: 4),
              Text(
                _errorMessage!,
                key: const ValueKey('community-report-error'),
                style: const TextStyle(fontSize: 12.5, color: AppColors.error),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    key: const ValueKey('community-report-cancel'),
                    onPressed: _submitting
                        ? null
                        : () => Navigator.of(context).pop(),
                    child: const Text('취소'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    key: const ValueKey('community-report-submit'),
                    onPressed: _reason == null || _submitting ? null : _submit,
                    child: _submitting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('신고하기'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
