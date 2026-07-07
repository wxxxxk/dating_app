import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../../core/constants/app_constants.dart';
import '../../models/charm_model.dart';

/// 프로필 기반 매력 리포트와 받은 관심 요약을 담당한다.
///
/// OpenAI API 키는 앱에 없고, generateCharmReport callable만 호출한다.
/// 리포트는 users/{uid}.charmReport에 캐싱되어 재진입 시 GPT를 다시 부르지 않는다.
class CharmService {
  CharmService({FirebaseFirestore? firestore, FirebaseFunctions? functions})
    : _db = firestore ?? FirebaseFirestore.instance,
      _functions =
          functions ??
          FirebaseFunctions.instanceFor(region: AppConstants.functionsRegion);

  final FirebaseFirestore _db;
  final FirebaseFunctions _functions;

  Future<CharmReport> getCharmReport({
    required String uid,
    bool refresh = false,
  }) async {
    if (!refresh) {
      final userDoc = await _db.collection('users').doc(uid).get();
      final cached = userDoc.data()?['charmReport'] as Map<String, dynamic>?;
      if (cached != null) return CharmReport.fromMap(cached);
    }

    final callable = _functions.httpsCallable('generateCharmReport');
    final result = await callable.call({'refresh': refresh});
    return CharmReport.fromMap(Map<String, dynamic>.from(result.data as Map));
  }

  /// 받은 like/superlike를 정성 등급으로 보여주기 위한 요약이다.
  ///
  /// 화면에는 구체 숫자를 크게 강조하지 않고, 뱃지 문구 중심으로 표시한다.
  Future<CharmInterestSummary> getReceivedInterestSummary({
    required String uid,
  }) async {
    final snap = await _db
        .collectionGroup('swipes')
        .where('targetUid', isEqualTo: uid)
        .where('action', whereIn: ['like', 'superlike'])
        .orderBy('timestamp', descending: true)
        .get();

    var likes = 0;
    var superlikes = 0;
    for (final doc in snap.docs) {
      final action = doc.data()['action'] as String?;
      if (action == 'superlike') {
        superlikes++;
      } else {
        likes++;
      }
    }
    return CharmInterestSummary(likeCount: likes, superlikeCount: superlikes);
  }
}
