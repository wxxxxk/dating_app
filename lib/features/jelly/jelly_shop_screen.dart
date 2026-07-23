import 'dart:async';

import 'package:flutter/material.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import '../../core/theme/app_colors.dart';
import '../../services/jelly/jelly_purchase_service.dart';
import '../../services/jelly/jelly_service.dart';
import '../../shared/widgets/loading_indicator.dart';
import '../../shared/widgets/premium_components.dart';
import 'jelly_history_screen.dart';

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

  bool get _realPurchaseDisabled =>
      !kJellyMockPurchases &&
      !widget.jellyPurchaseService.canLaunchStorePurchase;

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
      var shouldCompletePurchase = false;
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
            shouldCompletePurchase = true;
            if (mounted) {
              setState(() => _processing = false);
              _showSnack('젤리 충전 완료! 현재 보유: $balance개');
            }
          } catch (e) {
            if (mounted) {
              setState(() => _processing = false);
              _showSnack('구매 정보를 확인하지 못했습니다. 잠시 후 다시 시도해 주세요.');
            }
          }
          break;
      }
      if (shouldCompletePurchase) {
        try {
          await widget.jellyPurchaseService.finishPurchaseAfterGrant(purchase);
        } catch (_) {
          if (mounted) {
            _showSnack('젤리는 지급됐지만 구매 완료 처리를 다시 시도해야 합니다.');
          }
        }
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
        backgroundColor: AppColors.surfacePrimary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        icon: Container(
          width: 46,
          height: 46,
          decoration: const BoxDecoration(
            color: AppColors.surfaceMintSoft,
            shape: BoxShape.circle,
          ),
          child: const ExcludeSemantics(
            child: Icon(
              Icons.local_fire_department_rounded,
              size: 24,
              color: AppColors.mintDeep,
            ),
          ),
        ),
        title: const Text(
          '테스트 모드 충전',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w800,
            color: AppColors.textStrong,
          ),
        ),
        content: Text(
          '젤리 ${product.amount}개를 ${product.mockPriceLabel} 상품으로 '
          '충전할까요?\n\n지금은 테스트 모드라 실제 결제는 발생하지 않습니다.',
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 14,
            height: 1.55,
            color: AppColors.textBody,
          ),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(20, 4, 20, 18),
        actions: [
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.textBody,
                    side: const BorderSide(color: AppColors.borderStrong),
                    minimumSize: const Size.fromHeight(50),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadius.control),
                    ),
                  ),
                  child: const Text('취소'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(50),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadius.control),
                    ),
                  ),
                  child: const Text(
                    '충전',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
              ),
            ],
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
    if (_realPurchaseDisabled) {
      _showSnack('iOS 결제는 준비 중입니다.');
      return;
    }
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
      await widget.jellyPurchaseService.buy(details, uid: widget.currentUid);
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
    final mode = kJellyMockPurchases
        ? _PurchaseMode.test
        : _realPurchaseDisabled
        ? _PurchaseMode.disabled
        : _PurchaseMode.enabled;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        titleSpacing: 20,
        title: const Text(
          '젤리 충전',
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
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => JellyHistoryScreen(
                    currentUid: widget.currentUid,
                    jellyService: widget.jellyService,
                  ),
                ),
              ),
              style: TextButton.styleFrom(foregroundColor: AppColors.mintDeep),
              icon: const Icon(Icons.receipt_long_rounded, size: 18),
              label: const Text('내역'),
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          ListView(
            padding: EdgeInsets.fromLTRB(
              20,
              12,
              20,
              28 + MediaQuery.of(context).padding.bottom,
            ),
            children: [
              _BalanceHeader(
                currentUid: widget.currentUid,
                jellyService: widget.jellyService,
              ),
              const SizedBox(height: 14),
              const _JellyBenefitsCard(),
              const SizedBox(height: 18),
              _ModeNotice(mode: mode),
              const SizedBox(height: 18),
              Text(
                kJellyMockPurchases ? '테스트 모드 상품' : '충전 상품',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textStrong,
                ),
              ),
              const SizedBox(height: 12),
              ...JellyPurchaseCatalog.products.map(
                (product) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _ProductTile(
                    product: product,
                    priceLabel:
                        _storeDetails[product.productId]?.price ??
                        product.mockPriceLabel,
                    onTap: _processing || _realPurchaseDisabled
                        ? null
                        : () => _onProductTap(product),
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

/// 현재 화면이 어떤 결제 상태인지. 기존 조건(kJellyMockPurchases /
/// _realPurchaseDisabled)을 그대로 매핑만 한다.
enum _PurchaseMode { test, disabled, enabled }

/// 젤리로 실제 할 수 있는 것들을 보여주는 카드. JellyCosts에 있는 실제 값만
/// 쓴다 — 존재하지 않는 혜택을 만들어내지 않는다.
class _JellyBenefitsCard extends StatelessWidget {
  const _JellyBenefitsCard();

  @override
  Widget build(BuildContext context) {
    return PremiumSectionCard(
      title: '젤리로 할 수 있는 것',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: const [
          _BenefitRow(
            icon: Icons.star_rounded,
            label: '슈퍼라이크 보내기',
            cost: '${JellyCosts.superlike}개',
          ),
          _BenefitRow(
            icon: Icons.replay_rounded,
            label: '스와이프 되돌리기',
            cost: '${JellyCosts.rewind}개',
          ),
          _BenefitRow(
            icon: Icons.bolt_rounded,
            label: '30분 부스트로 우선 노출',
            cost: '${JellyCosts.boost}개',
          ),
          _BenefitRow(
            icon: Icons.favorite_rounded,
            label: '받은 좋아요 전체 보기',
            cost: '${JellyCosts.unlockReceivedLikes}개',
            isLast: true,
          ),
        ],
      ),
    );
  }
}

class _BenefitRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String cost;
  final bool isLast;

  const _BenefitRow({
    required this.icon,
    required this.label,
    required this.cost,
    this.isLast = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              Icon(icon, size: 18, color: AppColors.mintDeep),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    fontSize: 14,
                    color: AppColors.textStrong,
                  ),
                ),
              ),
              const ExcludeSemantics(
                child: Icon(
                  Icons.local_fire_department_rounded,
                  size: 14,
                  color: AppColors.mintDeep,
                ),
              ),
              const SizedBox(width: 3),
              Text(
                cost,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: AppColors.mintDeep,
                ),
              ),
            ],
          ),
        ),
        if (!isLast)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Divider(height: 1, color: AppColors.borderSubtle),
          ),
      ],
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
    // 젤리는 프리미엄 재화라, 앱바에 뜰 때도 기본으로 matchPrimary를 쓴다.
    // 아무 호출부도 foregroundColor를 넘기지 않아(전부 기본값 사용 중)
    // 이 기본값 변경만으로 Home/Discovery/받은 좋아요 앱바 전부에 반영된다.
    final color = foregroundColor ?? AppColors.matchPrimary;
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
    // 지갑 hero: 게임 상점 gradient 대신 옅은 mint wash 라이트 카드로 통일한다.
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: AppColors.surfaceMintSoft,
        borderRadius: BorderRadius.circular(AppRadius.hero),
        border: Border.all(color: AppColors.mint.withValues(alpha: 0.28)),
      ),
      child: StreamBuilder<int>(
        stream: jellyService.watchBalance(currentUid),
        builder: (context, snap) {
          final balance = snap.data ?? 0;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '보유 젤리',
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textBody,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: const BoxDecoration(
                      color: AppColors.surfacePrimary,
                      shape: BoxShape.circle,
                    ),
                    child: const ExcludeSemantics(
                      child: Icon(
                        Icons.local_fire_department_rounded,
                        color: AppColors.mintDeep,
                        size: 26,
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Text(
                    '$balance',
                    style: const TextStyle(
                      fontSize: 34,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.5,
                      height: 1,
                      color: AppColors.textStrong,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Padding(
                    padding: EdgeInsets.only(bottom: 3),
                    child: Text(
                      '개',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textBody,
                      ),
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

/// 결제 모드 안내 — 오류가 아니라 상태 안내. 기존 문구를 그대로 쓰고 톤만
/// 모드별로 구분한다(테스트=amber, 준비 중=neutral, 실제=mint).
class _ModeNotice extends StatelessWidget {
  final _PurchaseMode mode;

  const _ModeNotice({required this.mode});

  @override
  Widget build(BuildContext context) {
    late final IconData icon;
    late final Color accent;
    late final Color bg;
    late final String text;
    switch (mode) {
      case _PurchaseMode.test:
        icon = Icons.science_outlined;
        accent = AppColors.statusWarning;
        bg = AppColors.statusWarningSoft;
        text = '지금은 테스트 모드예요. 실제 결제는 발생하지 않아요.';
      case _PurchaseMode.disabled:
        icon = Icons.hourglass_empty_rounded;
        accent = AppColors.textMuted;
        bg = AppColors.surfaceSecondary;
        text = 'iOS 결제는 준비 중입니다.';
      case _PurchaseMode.enabled:
        icon = Icons.verified_user_outlined;
        accent = AppColors.mintDeep;
        bg = AppColors.surfaceMintSoft;
        text = '실제 스토어 결제가 진행됩니다.';
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadius.control),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExcludeSemantics(child: Icon(icon, size: 18, color: accent)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 13,
                height: 1.45,
                color: AppColors.textBody,
              ),
            ),
          ),
        ],
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
    final enabled = onTap != null;
    // 상품 간 차이는 amount와 price로만 전달한다(마케팅 badge 없음).
    // disabled(_processing/결제 준비 중)는 opacity로 명확히 구분한다.
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Semantics(
        button: true,
        enabled: enabled,
        label: '젤리 ${product.amount}개 $priceLabel',
        child: Material(
          color: AppColors.surfacePrimary,
          borderRadius: BorderRadius.circular(AppRadius.surface),
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadius.surface),
            onTap: onTap,
            child: Container(
              constraints: const BoxConstraints(minHeight: 76),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadius.surface),
                border: Border.all(color: AppColors.borderSubtle),
              ),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: const BoxDecoration(
                      color: AppColors.surfaceMintSoft,
                      shape: BoxShape.circle,
                    ),
                    child: const ExcludeSemantics(
                      child: Icon(
                        Icons.local_fire_department_rounded,
                        color: AppColors.mintDeep,
                        size: 22,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '젤리 ${product.amount}개',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w900,
                        color: AppColors.textStrong,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 96),
                    child: Text(
                      priceLabel,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.end,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: AppColors.textBody,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  const ExcludeSemantics(
                    child: Icon(
                      Icons.chevron_right_rounded,
                      size: 20,
                      color: AppColors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
