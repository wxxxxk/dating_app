import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String serviceSource() =>
      File('lib/services/jelly/jelly_purchase_service.dart').readAsStringSync();
  String screenSource() =>
      File('lib/features/jelly/jelly_shop_screen.dart').readAsStringSync();

  test(
    'Android 구매 시작은 GooglePlayPurchaseParam + account hash + autoConsume=false',
    () {
      final src = serviceSource();

      expect(src, contains("import 'dart:convert';"));
      expect(src, contains("import 'package:crypto/crypto.dart';"));
      expect(
        src,
        contains(
          "import 'package:in_app_purchase_android/in_app_purchase_android.dart';",
        ),
      );
      expect(src, contains('sha256.convert(utf8.encode(uid)).toString()'));
      expect(src, isNot(contains('applicationUserName: uid')));
      expect(src, contains('GooglePlayPurchaseParam('));
      expect(
        src,
        contains('applicationUserName: obfuscatedAccountIdForUid(uid)'),
      );
      expect(src, contains('autoConsume: false'));
    },
  );

  test('iOS는 StoreKit purchase launch가 비활성화되어 있다', () {
    final service = serviceSource();
    final screen = screenSource();

    expect(
      service,
      contains('bool get canLaunchStorePurchase => !Platform.isIOS;'),
    );
    expect(service, contains("throw UnsupportedError('iOS 결제는 준비 중입니다.');"));
    expect(screen, contains('bool get _realPurchaseDisabled'));
    expect(screen, contains("'iOS 결제는 준비 중입니다.'"));
    expect(screen, contains('onTap: _processing || _realPurchaseDisabled'));
  });

  test('purchaseStream은 서버 지급 성공 후에만 consume/finish를 호출한다', () {
    final src = screenSource();
    final verifyIndex = src.indexOf('verifyAndCredit(');
    final shouldFinishIndex = src.indexOf('shouldCompletePurchase = true;');
    final finishIndex = src.indexOf('finishPurchaseAfterGrant(purchase)');
    final pendingCase = src.substring(
      src.indexOf('case PurchaseStatus.pending:'),
      src.indexOf('case PurchaseStatus.error:'),
    );
    final cancelCase = src.substring(
      src.indexOf('case PurchaseStatus.canceled:'),
      src.indexOf('case PurchaseStatus.purchased:'),
    );

    expect(verifyIndex, greaterThanOrEqualTo(0));
    expect(shouldFinishIndex, greaterThan(verifyIndex));
    expect(finishIndex, greaterThan(shouldFinishIndex));
    expect(pendingCase, isNot(contains('finishPurchaseAfterGrant')));
    expect(cancelCase, isNot(contains('finishPurchaseAfterGrant')));
  });

  test(
    'Android 완료 책임은 consumePurchase이고 completePurchase는 Android 경로가 아니다',
    () {
      final src = serviceSource();
      final finishStart = src.indexOf('Future<void> finishPurchaseAfterGrant');
      final finishSrc = src.substring(finishStart);

      expect(finishSrc, contains('Platform.isAndroid'));
      expect(finishSrc, contains('consumePurchase(purchase)'));
      expect(finishSrc, contains('result.responseCode != BillingResponse.ok'));
      expect(finishSrc, contains('purchase.pendingCompletePurchase'));
      expect(
        finishSrc.indexOf('consumePurchase(purchase)'),
        lessThan(finishSrc.indexOf('purchase.pendingCompletePurchase')),
      );
    },
  );
}
