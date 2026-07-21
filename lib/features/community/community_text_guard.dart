import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../chat/chat_safety.dart';

/// 공개 글(게시물·댓글) 제출 전 클라이언트 사전 확인(Phase 4-2).
///
/// 채팅 전송 경고와 같은 순수 detector([detectChatSafetyRisks])를 재사용하되,
/// **공개 글에서는 전화번호·인증번호·송금 요청을 아예 막는다**(채팅은 경고 후
/// 사용자가 계속 보낼 수 있는 계약이며, 그 계약은 바꾸지 않는다).
///
/// 외부 연락처(카카오톡/SNS)는 hard block 대상이 아니라 확인 후 진행이다.
/// 입력 원문은 저장·로그·전송하지 않는다.
const String communityBlockedTextMessage = '개인정보·인증번호·송금 요청은 공개 글에 올릴 수 없어요.';

/// 공개 글에서 제출 자체를 막는 위험 신호.
const Set<ChatSafetyRisk> communityBlockedRisks = {
  ChatSafetyRisk.phoneNumber,
  ChatSafetyRisk.verificationCode,
  ChatSafetyRisk.financialRequest,
};

/// 제출해도 되는지 확인한다. 막히면 false, 계속 진행이면 true.
///
/// 입력 내용은 호출부가 그대로 유지한다(이 함수는 텍스트를 바꾸지 않는다).
Future<bool> confirmCommunityTextBeforeSubmit(
  BuildContext context,
  String text,
) async {
  final detection = detectChatSafetyRisks(text);
  if (!detection.hasRisk) return true;

  if (detection.risks.any(communityBlockedRisks.contains)) {
    if (!context.mounted) return false;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          key: ValueKey('community-blocked-text-snackbar'),
          content: Text(communityBlockedTextMessage),
        ),
      );
    return false;
  }

  if (!detection.risks.contains(ChatSafetyRisk.externalContact)) return true;
  if (!context.mounted) return false;

  final proceed = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.sheet)),
    ),
    builder: (sheetContext) => const _ExternalContactWarningSheet(),
  );
  return proceed == true;
}

class _ExternalContactWarningSheet extends StatelessWidget {
  const _ExternalContactWarningSheet();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        key: const ValueKey('community-external-contact-warning'),
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '외부 연락처를 공개하시겠어요?',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              '공개 글에 카카오톡·SNS 계정을 올리면 원하지 않는 연락을 받을 수 있어요.',
              style: TextStyle(
                fontSize: 13.5,
                height: 1.5,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    key: const ValueKey('community-external-contact-cancel'),
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('다시 확인'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    key: const ValueKey('community-external-contact-continue'),
                    onPressed: () => Navigator.of(context).pop(true),
                    child: const Text('그래도 게시하기'),
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
