import 'dart:convert';
import 'dart:io' show Platform;

import 'package:cloud_functions/cloud_functions.dart';
import 'package:crypto/crypto.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/billing_client_wrappers.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';

import '../../core/constants/app_constants.dart';

/// 실제 스토어 결제(IAP) 흐름을 담당한다.
///
/// [kJellyMockPurchases]가 true(기본값, 스토어 미등록 상태)면 화면이 이
/// 서비스를 아예 거치지 않고 JellyService.charge()로 즉시 충전한다
/// (jelly_shop_screen.dart 참고). 이 서비스는 스토어 등록 이후 실제 결제를
/// 붙일 자리를 미리 잡아두는 역할이다.
///
/// 흐름:
/// 1) queryProducts()로 스토어 상품 정보(가격 등) 조회
/// 2) Android buy()로 구매 시작(autoConsume:false) → 결과는 나중에 [purchaseStream]으로 온다
/// 3) 화면이 purchaseStream을 구독해 상태별로 처리하고,
///    구매 완료(purchased/restored) 시 verifyAndCredit()으로 서버 검증 요청
/// 4) 서버가 유효성을 확인하면 admin SDK로 직접 젤리를 충전한다
///    (클라이언트가 Firestore를 직접 쓰지 않는다 — 위조 방지)
/// 5) 서버 지급 성공 후 Android consumePurchase()로 소모품 처리를 완료한다
class JellyPurchaseService {
  JellyPurchaseService({FirebaseFunctions? functions})
    : _iap = InAppPurchase.instance,
      _functions =
          functions ??
          FirebaseFunctions.instanceFor(region: AppConstants.functionsRegion);

  final InAppPurchase _iap;
  final FirebaseFunctions _functions;

  /// 구매 상태 업데이트 스트림. 화면(State)에서 구독/해지를 관리해야 한다.
  Stream<List<PurchaseDetails>> get purchaseStream => _iap.purchaseStream;

  bool get canLaunchStorePurchase => !Platform.isIOS;

  static String obfuscatedAccountIdForUid(String uid) {
    return sha256.convert(utf8.encode(uid)).toString();
  }

  Future<bool> isAvailable() => _iap.isAvailable();

  /// 카탈로그(JellyPurchaseCatalog.productIds)에 등록된 상품들의 스토어
  /// 상세 정보(로컬라이즈된 가격 포함)를 조회한다.
  Future<ProductDetailsResponse> queryProducts(Set<String> productIds) {
    return _iap.queryProductDetails(productIds);
  }

  /// 젤리는 Android 소모성(consumable) 상품이다.
  ///
  /// Android에서는 autoConsume:false를 명시하고, 서버 검증/지급이 성공한 뒤
  /// [finishPurchaseAfterGrant]에서 수동 consume한다. iOS는 서버 검증이 아직
  /// 준비되지 않았으므로 구매 시작 자체를 막는다.
  Future<void> buy(ProductDetails product, {required String uid}) {
    if (Platform.isIOS) {
      throw UnsupportedError('iOS 결제는 준비 중입니다.');
    }
    if (Platform.isAndroid) {
      final param = GooglePlayPurchaseParam(
        productDetails: product,
        applicationUserName: obfuscatedAccountIdForUid(uid),
      );
      return _iap.buyConsumable(purchaseParam: param, autoConsume: false);
    }
    throw UnsupportedError('지원하지 않는 결제 플랫폼입니다.');
  }

  /// 서버 지급 성공 후에만 호출한다.
  ///
  /// Android completePurchase()는 plugin source 기준 acknowledge만 수행하므로,
  /// autoConsume:false 소모품은 Android platform addition의 consumePurchase()로
  /// 완료한다. iOS는 현재 구매 시작을 막고 있지만, 추후 검증 구현 후에는
  /// pendingCompletePurchase일 때 completePurchase()를 호출하는 흐름을 쓴다.
  Future<void> finishPurchaseAfterGrant(PurchaseDetails purchase) async {
    if (Platform.isAndroid) {
      final addition = _iap
          .getPlatformAddition<InAppPurchaseAndroidPlatformAddition>();
      final result = await addition.consumePurchase(purchase);
      if (result.responseCode != BillingResponse.ok) {
        throw InAppPurchaseException(
          source: kIAPSource,
          code: 'consume_failed',
          message: '구매 완료 처리에 실패했습니다.',
        );
      }
      return;
    }
    if (purchase.pendingCompletePurchase) {
      await _iap.completePurchase(purchase);
    }
  }

  /// 구매 영수증/토큰을 서버(Cloud Functions)로 보내 검증하고, 유효하면
  /// 서버가 admin SDK로 직접 젤리를 충전한 뒤 최신 잔액을 반환한다.
  ///
  Future<int> verifyAndCredit(PurchaseDetails purchase) async {
    final platform = Platform.isIOS ? 'ios' : 'android';
    final callable = _functions.httpsCallable('verifyJellyPurchase');
    final result = await callable.call({
      'platform': platform,
      'productId': purchase.productID,
      'purchaseToken': purchase.verificationData.serverVerificationData,
      'transactionId':
          purchase.purchaseID ??
          purchase.transactionDate ??
          DateTime.now().microsecondsSinceEpoch.toString(),
    });
    final data = Map<String, dynamic>.from(result.data as Map);
    return (data['balance'] as num).toInt();
  }
}
