import 'dart:async';

import 'package:flutter/material.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import '../../core/theme/app_colors.dart';
import '../../services/jelly/jelly_purchase_service.dart';
import '../../services/jelly/jelly_service.dart';
import '../../shared/widgets/loading_indicator.dart';

/// 젤리 충전 화면.
///
/// [kJellyMockPurchases](기본값 true, 스토어 미등록 상태)일 때는 실제 결제
/// 없이 즉시 성공 처리한다("테스트 모드"). false로 빌드하면 실제
/// in_app_purchase 결제 → Cloud Functions(verifyJellyPurchase) 검증 →
/// 서버가 admin SDK로 충전하는 흐름을 탄다. 두 모드 모두 같은 상품
/// 카탈로그(JellyPurchaseCatalog)와 같은 구매 UI를 쓴다.
class JellyShopScreen extends StatefulWidget {
  final String currentUid;
  final JellyService jellyService;
  final JellyPurchaseService jellyPurchaseService;

  const JellyShopScreen({
    super.key,
    required this.currentUid,
    required this.jellyService,
    required this.jellyPurchaseService,
  });

  @override
  State<JellyShopScreen> createState() => _JellyShopScreenState();
}

class _JellyShopScreenState extends State<JellyShopScreen> {
  StreamSubscription<List<PurchaseDetails>>? _purchaseSub;
  Map<String, ProductDetails> _storeDetails = {};

  // 결제 진행 중에는 화면을 잠가 중복 탭/중복 구매를 막는다.
  bool _processing = false;

  @override
  void initState() {
    super.initState();
    if (!kJellyMockPurchases) {
      // 테스트 모드에서는 실제 IAP 플랫폼 채널을 아예 건드리지 않는다 —
      // 스토어 미등록 상태에서 조회/구독 자체가 에러를 낼 수 있어서다.
      _purchaseSub = widget.jellyPurchaseService.purchaseStream.listen(
        _handlePurchaseUpdates,
        onError: (Object error) {
          if (mounted) _showSnack('결제 스트림 오류: $error');
        },
      );
      _loadStoreProducts();
    }
  }

  @override
  void dispose() {
    _purchaseSub?.cancel();
    super.dispose();
  }

  Future<void> _loadStoreProducts() async {
    try {
      final response = await widget.jellyPurchaseService.queryProducts(
        JellyPurchaseCatalog.productIds,
      );
      if (!mounted) return;
      setState(() {
        _storeDetails = {
          for (final detail in response.productDetails) detail.id: detail,
        };
      });
    } catch (_) {
      // 조회 실패해도 mockPriceLabel로 대체 표시하면 되므로 조용히 무시한다.
    }
  }

  // ── 실제 스토어 구매 상태 처리 ────────────────────────────────────────────

  Future<void> _handlePurchaseUpdates(List<PurchaseDetails> purchases) async {
    for (final purchase in purchases) {
      switch (purchase.status) {
        case PurchaseStatus.pending:
          if (mounted) setState(() => _processing = true);
          break;
        case PurchaseStatus.error:
          if (mounted) {
            setState(() => _processing = false);
            _showSnack('결제 실패: ${purchase.error?.message ?? "알 수 없는 오류"}');
          }
          break;
        case PurchaseStatus.canceled:
          if (mounted) setState(() => _processing = false);
          break;
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          try {
            final balance = await widget.jellyPurchaseService.verifyAndCredit(
              purchase,
            );
            if (mounted) {
              setState(() => _processing = false);
              _showSnack('젤리 충전 완료! 현재 보유: $balance개');
            }
          } catch (e) {
            if (mounted) {
              setState(() => _processing = false);
              _showSnack('영수증 검증 실패: $e');
            }
          }
          break;
      }
      if (purchase.pendingCompletePurchase) {
        await widget.jellyPurchaseService.completePurchase(purchase);
      }
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // ── 상품 탭 처리 ──────────────────────────────────────────────────────────

  Future<void> _onProductTap(JellyProduct product) {
    return kJellyMockPurchases
        ? _confirmMockCharge(product)
        : _startRealPurchase(product);
  }

  Future<void> _confirmMockCharge(JellyProduct product) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('테스트 모드 충전'),
        content: Text(
          '젤리 ${product.amount}개를 ${product.mockPriceLabel} 상품으로 '
          '충전할까요?\n\n지금은 테스트 모드라 실제 결제는 발생하지 않습니다.',
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

    await widget.jellyService.charge(
      uid: widget.currentUid,
      amount: product.amount,
      reason: 'mock_purchase_${product.productId}',
    );
    if (!mounted) return;
    _showSnack('젤리 ${product.amount}개 충전 완료');
  }

  Future<void> _startRealPurchase(JellyProduct product) async {
    setState(() => _processing = true);
    try {
      final available = await widget.jellyPurchaseService.isAvailable();
      if (!available) {
        throw Exception('스토어에 연결할 수 없습니다.');
      }
      final details = _storeDetails[product.productId];
      if (details == null) {
        throw Exception('스토어에서 상품을 찾을 수 없습니다(상품 등록 필요).');
      }
      await widget.jellyPurchaseService.buy(details);
      // 이후 진행 상황은 purchaseStream 구독(_handlePurchaseUpdates)이 처리한다.
    } catch (e) {
      if (mounted) {
        setState(() => _processing = false);
        _showSnack('결제 시작 실패: $e');
      }
    }
  }

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
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
            children: [
              _BalanceHeader(
                currentUid: widget.currentUid,
                jellyService: widget.jellyService,
              ),
              const SizedBox(height: 14),
              Text(
                kJellyMockPurchases ? '테스트 모드 상품' : '충전 상품',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                kJellyMockPurchases
                    ? '지금은 테스트 모드예요. 실제 결제는 발생하지 않아요.'
                    : '실제 스토어 결제가 진행됩니다.',
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 14),
              ...JellyPurchaseCatalog.products.map(
                (product) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _ProductTile(
                    product: product,
                    priceLabel:
                        _storeDetails[product.productId]?.price ??
                        product.mockPriceLabel,
                    onTap: _processing ? null : () => _onProductTap(product),
                  ),
                ),
              ),
            ],
          ),
          if (_processing) const LoadingIndicator(overlay: true),
        ],
      ),
    );
  }
}

class JellyBalanceButton extends StatelessWidget {
  final String currentUid;
  final JellyService jellyService;
  final JellyPurchaseService jellyPurchaseService;
  final Color? foregroundColor;

  const JellyBalanceButton({
    super.key,
    required this.currentUid,
    required this.jellyService,
    required this.jellyPurchaseService,
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
            jellyPurchaseService: jellyPurchaseService,
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
  required JellyPurchaseService jellyPurchaseService,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => JellyShopScreen(
        currentUid: currentUid,
        jellyService: jellyService,
        jellyPurchaseService: jellyPurchaseService,
      ),
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
        borderRadius: BorderRadius.circular(AppRadius.card),
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
  final JellyProduct product;
  final String priceLabel;
  final VoidCallback? onTap;

  const _ProductTile({
    required this.product,
    required this.priceLabel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(AppRadius.card),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.card),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.card),
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
                priceLabel,
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
        borderRadius: BorderRadius.circular(AppRadius.chip),
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
