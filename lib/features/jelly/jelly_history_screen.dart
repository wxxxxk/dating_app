import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../services/jelly/jelly_service.dart';

/// 젤리 사용/충전 내역 화면.
///
/// users/{uid}/jellyTransactions를 최신순으로 읽기만 한다 — 새 쓰기 경로는
/// 없다(JellyService의 기존 charge/spend 트랜잭션이 이미 기록해둔 데이터).
///
/// 디자인(Phase 3-E, Editorial Wallet Timeline): 거래마다 독립 카드를 반복하는
/// 대신, 충전 화면과 같은 밝은 surface 하나에 subtle divider로 이어지는
/// 타임라인으로 정리한다. stream·순서·금액·날짜·읽기 전용 계약은 그대로 둔다.
class JellyHistoryScreen extends StatelessWidget {
  final String currentUid;
  final JellyService jellyService;

  const JellyHistoryScreen({
    super.key,
    required this.currentUid,
    required this.jellyService,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        titleSpacing: 20,
        title: const Text(
          '젤리 내역',
          style: TextStyle(
            fontSize: 21,
            fontWeight: FontWeight.w800,
            color: AppColors.textStrong,
            letterSpacing: -0.2,
          ),
        ),
        backgroundColor: AppColors.background,
        foregroundColor: AppColors.textStrong,
        elevation: 0,
      ),
      body: StreamBuilder<List<JellyTransaction>>(
        stream: jellyService.watchTransactions(currentUid),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(
              child: SizedBox(
                width: 26,
                height: 26,
                child: CircularProgressIndicator(strokeWidth: 2.4),
              ),
            );
          }
          if (snap.hasError) {
            return const _HistoryMessage(
              icon: Icons.cloud_off_rounded,
              message: '내역을 불러오지 못했어요',
            );
          }
          final items = snap.data ?? const [];
          if (items.isEmpty) {
            return const _HistoryMessage(
              icon: Icons.receipt_long_rounded,
              message: '아직 거래 내역이 없어요',
              tinted: true,
            );
          }
          return ListView(
            padding: EdgeInsets.fromLTRB(
              20,
              16,
              20,
              28 + MediaQuery.of(context).padding.bottom,
            ),
            children: [_TransactionTimeline(items: items)],
          );
        },
      ),
    );
  }
}

/// 충전·사용 기록을 하나의 연속된 surface에 divider로 이어 보여준다.
class _TransactionTimeline extends StatelessWidget {
  final List<JellyTransaction> items;

  const _TransactionTimeline({required this.items});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfacePrimary,
        borderRadius: BorderRadius.circular(AppRadius.surface),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) const Divider(height: 1, color: AppColors.borderSubtle),
            _TransactionRow(tx: items[i]),
          ],
        ],
      ),
    );
  }
}

class _TransactionRow extends StatelessWidget {
  final JellyTransaction tx;
  const _TransactionRow({required this.tx});

  @override
  Widget build(BuildContext context) {
    final isCharge = tx.isCharge;
    // 충전은 mint, 사용은 중립 톤. 사용은 오류가 아니므로 danger red를 쓰지 않고,
    // 색상만이 아니라 icon(add/remove)과 부호로도 구분되게 한다.
    final iconBg = isCharge
        ? AppColors.surfaceMintSoft
        : AppColors.surfaceSecondary;
    final iconColor = isCharge ? AppColors.mintDeep : AppColors.textBody;
    final amountColor = isCharge ? AppColors.mintDeep : AppColors.textStrong;
    final sign = isCharge ? '+' : '';

    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 72),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(color: iconBg, shape: BoxShape.circle),
              child: ExcludeSemantics(
                child: Icon(
                  isCharge ? Icons.add_rounded : Icons.remove_rounded,
                  color: iconColor,
                  size: 20,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tx.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textStrong,
                    ),
                  ),
                  if (tx.createdAt != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      _formatDate(tx.createdAt!),
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(
              '$sign${tx.amount}',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w900,
                color: amountColor,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _formatDate(DateTime value) {
    final d = value.toLocal();
    final hour = d.hour < 12 ? '오전' : '오후';
    final h12 = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final minute = d.minute.toString().padLeft(2, '0');
    return '${d.month}/${d.day} $hour $h12:$minute';
  }
}

/// empty / error 공통 editorial 상태 — 작은 아이콘 + 기존 문구.
class _HistoryMessage extends StatelessWidget {
  final IconData icon;
  final String message;
  final bool tinted;

  const _HistoryMessage({
    required this.icon,
    required this.message,
    this.tinted = false,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: tinted
                    ? AppColors.surfaceMintSoft
                    : AppColors.surfaceSecondary,
                shape: BoxShape.circle,
              ),
              child: ExcludeSemantics(
                child: Icon(
                  icon,
                  size: 32,
                  color: tinted ? AppColors.mintDeep : AppColors.textMuted,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 14.5,
                fontWeight: FontWeight.w600,
                color: AppColors.textBody,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
