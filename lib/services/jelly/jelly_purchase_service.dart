import 'dart:io' show Platform;

import 'package:cloud_functions/cloud_functions.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

/// 실제 스토어 결제(IAP) 흐름을 담당한다.
///
/// [kJellyMockPurchases]가 true(기본값, 스토어 미등록 상태)면 화면이 이
/// 서비스를 아예 거치지 않고 JellyService.charge()로 즉시 충전한다
/// (jelly_shop_screen.dart 참고). 이 서비스는 스토어 등록 이후 실제 결제를
/// 붙일 자리를 미리 잡아두는 역할이다.
///
/// 흐름:
/// 1) queryProducts()로 스토어 상품 정보(가격 등) 조회
/// 2) buy()로 구매 시작 → 결과는 나중에 [purchaseStream]으로 온다
/// 3) 화면이 purchaseStream을 구독해 상태별로 처리하고,
///    구매 완료(purchased/restored) 시 verifyAndCredit()으로 서버 검증 요청
/// 4) 서버가 유효성을 확인하면 admin SDK로 직접 젤리를 충전한다
///    (클라이언트가 Firestore를 직접 쓰지 않는다 — 위조 방지)
class JellyPurchaseService {
  JellyPurchaseService({FirebaseFunctions? functions})
    : _iap = InAppPurchase.instance,
      _functions = functions ?? FirebaseFunctions.instance;

  final InAppPurchase _iap;
  final FirebaseFunctions _functions;

  /// 구매 상태 업데이트 스트림. 화면(State)에서 구독/해지를 관리해야 한다.
  Stream<List<PurchaseDetails>> get purchaseStream => _iap.purchaseStream;

  Future<bool> isAvailable() => _iap.isAvailable();

  /// 카탈로그(JellyPurchaseCatalog.productIds)에 등록된 상품들의 스토어
  /// 상세 정보(로컬라이즈된 가격 포함)를 조회한다.
  Future<ProductDetailsResponse> queryProducts(Set<String> productIds) {
    return _iap.queryProductDetails(productIds);
  }

  /// 젤리는 소모성(consumable) 상품이라 buyConsumable을 쓴다.
  Future<void> buy(ProductDetails product) {
    final param = PurchaseParam(productDetails: product);
    return _iap.buyConsumable(purchaseParam: param);
  }

  /// 스토어에 "처리 완료"를 알린다 — 호출하지 않으면 다음 실행 시 같은 구매가
  /// purchaseStream에 다시 나타난다(미완료 거래로 남기 때문).
  Future<void> completePurchase(PurchaseDetails purchase) {
    return _iap.completePurchase(purchase);
  }

  /// 구매 영수증/토큰을 서버(Cloud Functions)로 보내 검증하고, 유효하면
  /// 서버가 admin SDK로 직접 젤리를 충전한 뒤 최신 잔액을 반환한다.
  ///
  /// ⚠️ 서버 함수(verifyJellyPurchase)는 현재 스켈레톤이다 — 실제 App Store
  /// Server API / Google Play Developer API 검증 없이 항상 성공 처리한다
  /// (functions/index.js 주석 참고). 스토어 등록 전까지는 이 경로 자체가
  /// kJellyMockPurchases=false일 때만 실행된다.
  Future<int> verifyAndCredit(PurchaseDetails purchase) async {
    final platform = Platform.isIOS ? 'ios' : 'android';
    final callable = _functions.httpsCallable('verifyJellyPurchase');
    final result = await callable.call({
      'platform': platform,
      'productId': purchase.productID,
      'purchaseToken': purchase.verificationData.serverVerificationData,
      'transactionId':
          purchase.purchaseID ?? purchase.transactionDate ?? DateTime.now().microsecondsSinceEpoch.toString(),
    });
    final data = Map<String, dynamic>.from(result.data as Map);
    return (data['balance'] as num).toInt();
  }
}
