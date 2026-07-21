import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import 'chat_safety.dart';

/// 배너 자리를 항상 차지하는 슬롯(`_TypingSlot`과 같은 패턴).
///
/// 배너를 조건부로 children 목록에서 통째로 빼면 Column의 자식 순서/타입이
/// 바뀌어 아래쪽 메시지 목록 StreamBuilder가 재생성된다(재구독·스크롤 초기화).
/// 슬롯을 항상 두고 내부에서만 표시를 전환해 그 재생성을 막는다.
class ChatSafetyBannerSlot extends StatelessWidget {
  final bool visible;
  final VoidCallback onOpenGuide;
  final VoidCallback onDismiss;

  const ChatSafetyBannerSlot({
    super.key,
    required this.visible,
    required this.onOpenGuide,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.shrink();
    return ChatSafetyBanner(onOpenGuide: onOpenGuide, onDismiss: onDismiss);
  }
}

/// 채팅 상단 안전 가이드 배너.
///
/// 세션 한정 안내다 — 닫기는 현재 ChatScreen 상태에만 반영하고, Firestore나
/// SharedPreferences에 저장하지 않는다(화면을 다시 열면 다시 보이는 것이 정상).
class ChatSafetyBanner extends StatelessWidget {
  final VoidCallback onOpenGuide;
  final VoidCallback onDismiss;

  const ChatSafetyBanner({
    super.key,
    required this.onOpenGuide,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: const ValueKey('chat-safety-guide-banner'),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Material(
        color: AppColors.mintSoft,
        borderRadius: BorderRadius.circular(AppRadius.button),
        child: InkWell(
          key: const ValueKey('chat-safety-guide-open-button'),
          onTap: onOpenGuide,
          borderRadius: BorderRadius.circular(AppRadius.button),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.shield_outlined,
                  size: 18,
                  color: AppColors.mintDeep,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '안전하게 대화해요',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      const Text(
                        '연락처·인증번호·송금 요청은 충분히 신뢰한 뒤 확인하세요.',
                        style: TextStyle(
                          fontSize: 11.5,
                          height: 1.35,
                          color: AppColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '자세히',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: AppColors.mintDeep,
                          decoration: TextDecoration.underline,
                          decorationColor: AppColors.mintDeep,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  key: const ValueKey('chat-safety-guide-dismiss-button'),
                  tooltip: '안내 닫기',
                  onPressed: onDismiss,
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  color: AppColors.textSecondary,
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 전체 안전 가이드 바텀시트. 읽기 전용 안내이며, 신고 폼을 중복 구현하지 않고
/// 기존 우측 상단 메뉴(신고/차단)를 안내만 한다.
Future<void> showChatSafetyGuideSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.background,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.sheet)),
    ),
    builder: (_) => const _ChatSafetyGuideSheet(),
  );
}

class _SafetyGuideItem {
  final IconData icon;
  final String title;
  final String body;

  const _SafetyGuideItem({
    required this.icon,
    required this.title,
    required this.body,
  });
}

const List<_SafetyGuideItem> _guideItems = [
  _SafetyGuideItem(
    icon: Icons.lock_outline_rounded,
    title: '개인정보는 천천히',
    body: '전화번호, 집 주소, 직장 위치처럼 개인을 특정할 수 있는 정보는 충분히 신뢰한 뒤 공유하세요.',
  ),
  _SafetyGuideItem(
    icon: Icons.password_rounded,
    title: '인증번호는 공유하지 않기',
    body: '인증번호, 비밀번호, 보안코드는 누구에게도 보내지 마세요.',
  ),
  _SafetyGuideItem(
    icon: Icons.account_balance_wallet_outlined,
    title: '송금 요청 주의',
    body: '선입금, 대리 결제, 급한 송금을 요구받으면 대화를 멈추고 확인하세요.',
  ),
  _SafetyGuideItem(
    icon: Icons.place_outlined,
    title: '첫 만남은 공개된 장소에서',
    body:
        '사람이 많은 장소에서 만나고, 믿을 수 있는 사람에게 일정을 알려두세요. 약속 장소와 메모에는 집 주소 대신 '
        '공개된 장소를 적고, 전화번호나 SNS 계정은 넣지 마세요.',
  ),
];

class _ChatSafetyGuideSheet extends StatelessWidget {
  const _ChatSafetyGuideSheet();

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    // 작은 화면·키보드 노출 상황에서도 overflow 없이 스크롤되게 한다.
    final maxHeight = MediaQuery.sizeOf(context).height * 0.82;

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(20, 8, 20, 20 + bottomInset),
          child: Column(
            key: const ValueKey('chat-safety-guide-sheet'),
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
              Row(
                children: [
                  const Icon(
                    Icons.verified_user_outlined,
                    size: 20,
                    color: AppColors.mintDeep,
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      '안전하게 대화하는 방법',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              ..._guideItems.map(
                (item) => Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: AppColors.mintSoft,
                          borderRadius: BorderRadius.circular(
                            AppRadius.button,
                          ),
                        ),
                        child: Icon(
                          item.icon,
                          size: 18,
                          color: AppColors.mintDeep,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.title,
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                                color: AppColors.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              item.body,
                              style: const TextStyle(
                                fontSize: 13,
                                height: 1.45,
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 2),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(AppRadius.button),
                  border: Border.all(color: AppColors.border),
                ),
                child: const Text(
                  '불편하거나 수상한 상황에서는 우측 상단 메뉴에서 신고하거나 차단할 수 있어요.',
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.45,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const ValueKey('chat-safety-guide-confirm-button'),
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('확인했어요'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 민감정보가 포함됐을 수 있는 메시지의 전송 전 확인 시트.
///
/// 원문 메시지는 시트에 다시 표시하지 않고, 탐지된 종류 라벨만 보여준다.
/// `true`를 pop하면 전송, 그 외(취소·바깥 탭)에는 전송하지 않는다.
Future<bool?> showChatSafetyWarningSheet({
  required BuildContext context,
  required Set<ChatSafetyRisk> risks,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.background,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.sheet)),
    ),
    builder: (_) => _ChatSafetyWarningSheet(risks: risks),
  );
}

class _ChatSafetyWarningSheet extends StatelessWidget {
  final Set<ChatSafetyRisk> risks;

  const _ChatSafetyWarningSheet({required this.risks});

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.82;

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(20, 8, 20, 20 + bottomInset),
          child: Column(
            key: const ValueKey('chat-safety-warning-sheet'),
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
                '보내기 전에 확인해주세요',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                '개인정보나 금전·인증 관련 내용이 포함됐을 수 있어요.\n상대를 충분히 신뢰하는지 다시 확인해주세요.',
                style: TextStyle(
                  fontSize: 13.5,
                  height: 1.5,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: risks
                    .map(
                      (risk) => Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 7,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.surface,
                          borderRadius: BorderRadius.circular(AppRadius.chip),
                          border: Border.all(color: AppColors.border),
                        ),
                        child: Text(
                          chatSafetyRiskLabel(risk),
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      key: const ValueKey('chat-safety-warning-cancel-button'),
                      onPressed: () => Navigator.of(context).pop(false),
                      child: const Text('다시 확인'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      key: const ValueKey('chat-safety-warning-confirm-button'),
                      // 경고색이 아니라 중립 톤 — 사용자를 비난하지 않는다.
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.surface,
                        foregroundColor: AppColors.textPrimary,
                        side: const BorderSide(color: AppColors.border),
                      ),
                      onPressed: () => Navigator.of(context).pop(true),
                      child: const Text('그래도 보내기'),
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
