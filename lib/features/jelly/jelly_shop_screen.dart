import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../services/jelly/jelly_service.dart';

class JellyShopScreen extends StatelessWidget {
  final String currentUid;
  final JellyService jellyService;

  const JellyShopScreen({
    super.key,
    required this.currentUid,
    required this.jellyService,
  });

  static const _products = [
    _JellyProduct(amount: 30, priceLabel: '₩1,900'),
    _JellyProduct(amount: 100, priceLabel: '₩4,900', badge: '인기'),
    _JellyProduct(amount: 300, priceLabel: '₩12,900', badge: '최대 혜택'),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text(
          '젤리 충전',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: AppColors.background,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
        children: [
          _BalanceHeader(currentUid: currentUid, jellyService: jellyService),
          const SizedBox(height: 14),
          const Text(
            '목업 결제 상품',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w900,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            '시연용 충전입니다. 실제 결제는 발생하지 않아요.',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: 14),
          ..._products.map(
            (product) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _ProductTile(
                product: product,
                onTap: () => _confirmCharge(context, product),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmCharge(
    BuildContext context,
    _JellyProduct product,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('목업 충전'),
        content: Text(
          '젤리 ${product.amount}개를 ${product.priceLabel} 상품으로 충전할까요?\n\n실제 결제는 발생하지 않습니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('충전'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    // TODO: 출시 시 in_app_purchase 연동 및 서버 영수증 검증으로 교체.
    await jellyService.charge(
      uid: currentUid,
      amount: product.amount,
      reason: 'mock_purchase_${product.amount}',
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('젤리 ${product.amount}개 충전 완료')));
  }
}

class JellyBalanceButton extends StatelessWidget {
  final String currentUid;
  final JellyService jellyService;
  final Color? foregroundColor;

  const JellyBalanceButton({
    super.key,
    required this.currentUid,
    required this.jellyService,
    this.foregroundColor,
  });

  @override
  Widget build(BuildContext context) {
    final color = foregroundColor ?? AppColors.textPrimary;
    return StreamBuilder<int>(
      stream: jellyService.watchBalance(currentUid),
      builder: (context, snap) {
        final balance = snap.data ?? 0;
        return TextButton.icon(
          onPressed: () => openJellyShop(
            context: context,
            currentUid: currentUid,
            jellyService: jellyService,
          ),
          icon: Icon(Icons.local_fire_department_rounded, color: color),
          label: Text(
            '$balance',
            style: TextStyle(color: color, fontWeight: FontWeight.w900),
          ),
        );
      },
    );
  }
}

Future<void> openJellyShop({
  required BuildContext context,
  required String currentUid,
  required JellyService jellyService,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) =>
          JellyShopScreen(currentUid: currentUid, jellyService: jellyService),
    ),
  );
}

class _BalanceHeader extends StatelessWidget {
  final String currentUid;
  final JellyService jellyService;

  const _BalanceHeader({required this.currentUid, required this.jellyService});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.16)),
      ),
      child: StreamBuilder<int>(
        stream: jellyService.watchBalance(currentUid),
        builder: (context, snap) {
          final balance = snap.data ?? 0;
          return Row(
            children: [
              const Icon(
                Icons.local_fire_department_rounded,
                color: AppColors.primary,
                size: 34,
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '보유 젤리',
                    style: TextStyle(color: AppColors.textSecondary),
                  ),
                  Text(
                    '$balance개',
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w900,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ProductTile extends StatelessWidget {
  final _JellyProduct product;
  final VoidCallback onTap;

  const _ProductTile({required this.product, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.local_fire_department_rounded,
                color: AppColors.primary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Row(
                  children: [
                    Text(
                      '젤리 ${product.amount}개',
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w900,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    if (product.badge != null) ...[
                      const SizedBox(width: 8),
                      _ProductBadge(label: product.badge!),
                    ],
                  ],
                ),
              ),
              Text(
                product.priceLabel,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProductBadge extends StatelessWidget {
  final String label;

  const _ProductBadge({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.secondary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w800,
          color: AppColors.secondary,
        ),
      ),
    );
  }
}

class _JellyProduct {
  final int amount;
  final String priceLabel;
  final String? badge;

  const _JellyProduct({
    required this.amount,
    required this.priceLabel,
    this.badge,
  });
}
