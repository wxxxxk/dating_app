import 'package:cloud_firestore/cloud_firestore.dart';

class JellyCosts {
  static const int superlike = 5;
  static const int boost = 30;
  static const int unlockReceivedLikes = 20;
  static const Duration boostDuration = Duration(minutes: 30);

  JellyCosts._();
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

  /// 목업 충전이다. 실제 출시 시 in_app_purchase 영수증 검증 후 서버에서 충전해야 한다.
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
