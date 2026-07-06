import 'package:cloud_firestore/cloud_firestore.dart';

class JellyCosts {
  static const int superlike = 5;
  static const int boost = 30;
  static const int unlockReceivedLikes = 20;
  static const Duration boostDuration = Duration(minutes: 30);

  JellyCosts._();
}

/// 실제 스토어 연결 없이 젤리 상점 UI를 테스트하기 위한 플래그.
///
/// 스토어(App Store Connect / Google Play Console)에 상품이 아직 등록되지
/// 않은 상태(예: 발표/시연)에서도 구매 UI를 그대로 보여주면서, 실제
/// in_app_purchase 결제 대신 즉시 성공 처리하려고 둔다.
/// 기본값은 true — 지금은 스토어 등록 전이라 이 값을 끄면 실제 구매가 실패한다.
///
/// 실제 스토어 연동을 테스트하려면 다음처럼 빌드하면 된다:
///   flutter run --dart-define=JELLY_MOCK_PURCHASES=false
const bool kJellyMockPurchases = bool.fromEnvironment(
  'JELLY_MOCK_PURCHASES',
  defaultValue: true,
);

/// 젤리 상점에서 판매하는 상품 하나.
///
/// [productId]는 실제 스토어 연동 시 App Store Connect / Google Play
/// Console에 등록하는 상품 ID와 반드시 문자 그대로 일치해야 한다.
class JellyProduct {
  final String productId;
  final int amount;

  /// 스토어 미연결(목업 모드)일 때 보여줄 참고 가격.
  /// 실제 스토어 연동 후에는 ProductDetails.price(스토어가 내려주는 로컬라이즈
  /// 가격)를 우선 사용하고, 조회 실패 시에만 이 값으로 대체 표시한다.
  final String mockPriceLabel;
  final String? badge;

  const JellyProduct({
    required this.productId,
    required this.amount,
    required this.mockPriceLabel,
    this.badge,
  });
}

/// 젤리 상품 카탈로그 — 화면(가격 표시)과 IAP 조회(상품 ID) 양쪽에서 쓰는
/// 단일 소스. functions/index.js의 JELLY_PRODUCTS와 productId·amount가
/// 반드시 같아야 한다(서버가 충전량을 계산하는 근거이기 때문).
class JellyPurchaseCatalog {
  JellyPurchaseCatalog._();

  static const products = <JellyProduct>[
    JellyProduct(productId: 'jelly_30', amount: 30, mockPriceLabel: '₩1,900'),
    JellyProduct(
      productId: 'jelly_100',
      amount: 100,
      mockPriceLabel: '₩4,900',
      badge: '인기',
    ),
    JellyProduct(
      productId: 'jelly_300',
      amount: 300,
      mockPriceLabel: '₩12,900',
      badge: '최대 혜택',
    ),
  ];

  static Set<String> get productIds =>
      products.map((p) => p.productId).toSet();

  static JellyProduct? byProductId(String productId) {
    for (final product in products) {
      if (product.productId == productId) return product;
    }
    return null;
  }
}

class JellyService {
  JellyService({FirebaseFirestore? firestore})
    : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  DocumentReference<Map<String, dynamic>> _userRef(String uid) =>
      _db.collection('users').doc(uid);

  CollectionReference<Map<String, dynamic>> _txRef(String uid) =>
      _userRef(uid).collection('jellyTransactions');

  Stream<int> watchBalance(String uid) {
    return _userRef(uid).snapshots().map((snap) {
      return (snap.data()?['jelly'] as num?)?.toInt() ?? 0;
    });
  }

  Future<int> getBalance(String uid) async {
    final snap = await _userRef(uid).get();
    return (snap.data()?['jelly'] as num?)?.toInt() ?? 0;
  }

  /// 클라이언트에서 직접 충전한다.
  ///
  /// [kJellyMockPurchases]가 true일 때(테스트 모드) jelly_shop_screen.dart가
  /// 이 메서드를 바로 호출한다. 실제 스토어 결제 흐름(kJellyMockPurchases=false)은
  /// JellyPurchaseService가 영수증을 Cloud Functions(verifyJellyPurchase)로
  /// 보내 서버가 admin SDK로 직접 충전하므로 이 메서드를 거치지 않는다.
  Future<void> charge({
    required String uid,
    required int amount,
    required String reason,
  }) async {
    if (amount <= 0) return;
    final userRef = _userRef(uid);
    final txRef = _txRef(uid).doc();

    await _db.runTransaction((transaction) async {
      final userSnap = await transaction.get(userRef);
      final current = (userSnap.data()?['jelly'] as num?)?.toInt() ?? 0;
      transaction.update(userRef, {'jelly': current + amount});
      transaction.set(txRef, {
        'type': 'charge',
        'amount': amount,
        'reason': reason,
        'createdAt': FieldValue.serverTimestamp(),
      });
    });
  }

  Future<bool> spend({
    required String uid,
    required int amount,
    required String reason,
  }) async {
    if (amount <= 0) return true;
    final userRef = _userRef(uid);
    final txRef = _txRef(uid).doc();

    return _db.runTransaction((transaction) async {
      final userSnap = await transaction.get(userRef);
      final current = (userSnap.data()?['jelly'] as num?)?.toInt() ?? 0;
      if (current < amount) return false;
      transaction.update(userRef, {'jelly': current - amount});
      transaction.set(txRef, {
        'type': 'spend',
        'amount': -amount,
        'reason': reason,
        'createdAt': FieldValue.serverTimestamp(),
      });
      return true;
    });
  }

  Future<bool> activateBoost(String uid) async {
    final userRef = _userRef(uid);
    final txRef = _txRef(uid).doc();
    final now = DateTime.now();
    final boostUntil = now.add(JellyCosts.boostDuration);

    return _db.runTransaction((transaction) async {
      final userSnap = await transaction.get(userRef);
      final data = userSnap.data() ?? const <String, dynamic>{};
      final current = (data['jelly'] as num?)?.toInt() ?? 0;
      final currentBoostUntil = (data['boostUntil'] as Timestamp?)?.toDate();
      if (currentBoostUntil != null && currentBoostUntil.isAfter(now)) {
        return true;
      }
      if (current < JellyCosts.boost) return false;

      transaction.update(userRef, {
        'jelly': current - JellyCosts.boost,
        'boostUntil': Timestamp.fromDate(boostUntil),
      });
      transaction.set(txRef, {
        'type': 'spend',
        'amount': -JellyCosts.boost,
        'reason': 'boost',
        'createdAt': FieldValue.serverTimestamp(),
      });
      return true;
    });
  }

  Future<bool> unlockReceivedLikes(String uid) async {
    final userRef = _userRef(uid);
    final txRef = _txRef(uid).doc();

    return _db.runTransaction((transaction) async {
      final userSnap = await transaction.get(userRef);
      final data = userSnap.data() ?? const <String, dynamic>{};
      if (data['likesUnlocked'] == true) return true;
      final current = (data['jelly'] as num?)?.toInt() ?? 0;
      if (current < JellyCosts.unlockReceivedLikes) return false;

      transaction.update(userRef, {
        'jelly': current - JellyCosts.unlockReceivedLikes,
        'likesUnlocked': true,
      });
      transaction.set(txRef, {
        'type': 'spend',
        'amount': -JellyCosts.unlockReceivedLikes,
        'reason': 'unlock_received_likes',
        'createdAt': FieldValue.serverTimestamp(),
      });
      return true;
    });
  }

  Stream<bool> watchReceivedLikesUnlocked(String uid) {
    return _userRef(
      uid,
    ).snapshots().map((snap) => snap.data()?['likesUnlocked'] == true);
  }
}
