import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../services/jelly/jelly_service.dart';

/// 젤리 사용/충전 내역 화면.
///
/// users/{uid}/jellyTransactions를 최신순으로 읽기만 한다 — 새 쓰기 경로는
/// 없다(JellyService의 기존 charge/spend 트랜잭션이 이미 기록해둔 데이터).
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
        title: const Text(
          '젤리 내역',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: AppColors.background,
        elevation: 0,
      ),
      body: StreamBuilder<List<JellyTransaction>>(
        stream: jellyService.watchTransactions(currentUid),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return const Center(
              child: Text(
                '내역을 불러오지 못했어요',
                style: TextStyle(color: AppColors.textSecondary),
              ),
            );
          }
          final items = snap.data ?? const [];
          if (items.isEmpty) {
            return const Center(
              child: Text(
                '아직 거래 내역이 없어요',
                style: TextStyle(color: AppColors.textSecondary),
              ),
            );
          }
          return ListView.separated(
            padding: EdgeInsets.fromLTRB(
              20,
              12,
              20,
              28 + MediaQuery.of(context).padding.bottom,
            ),
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, index) => _TransactionTile(tx: items[index]),
          );
        },
      ),
    );
  }
}

class _TransactionTile extends StatelessWidget {
  final JellyTransaction tx;
  const _TransactionTile({required this.tx});

  @override
  Widget build(BuildContext context) {
    final isCharge = tx.isCharge;
    final color = isCharge ? AppColors.wood : AppColors.textSecondary;
    final sign = isCharge ? '+' : '';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.button),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(
              isCharge
                  ? Icons.add_rounded
                  : Icons.local_fire_department_rounded,
              color: color,
              size: 20,
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
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                if (tx.createdAt != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    _formatDate(tx.createdAt!),
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '$sign${tx.amount}',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w900,
              color: color,
            ),
          ),
        ],
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
