import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

import '../../core/constants/app_constants.dart';
import '../../models/fortune_model.dart';
import 'fortune_calculator.dart';

/// 사주/궁합 GPT 서사를 요청·표시하는 서비스.
///
/// OpenAI API 키는 앱에 전혀 포함되지 않는다 — 이 서비스는 Cloud Functions
/// callable(functions/index.js의 generateFortuneNarrative/generateMatchNarrative/
/// generateDailyFortune/generateIcebreakers/generateConversationTips)만 호출하고,
/// 실제 GPT 호출과 키 보관은 서버가 전담한다.
///
/// 캐싱: 함수가 Firestore(users/{uid}.fortuneNarrative,
/// matches/{matchId}.fortuneMatch, users/{uid}/dailyFortune/{yyyy-MM-dd},
/// matches/{matchId}.icebreakers, matches/{matchId}.conversationTips)에 결과를
/// 저장해두므로, 여기서 먼저 그 문서를 직접 읽어 캐시가 있으면 함수 호출
/// (콜드스타트 포함) 없이 즉시 보여준다. 캐시가 없을 때만 함수를 호출하고,
/// 함수도 내부적으로 한 번 더 캐시를 확인해 같은 요청이 중복 과금되지 않게 한다.
class FortuneService {
  FortuneService({FirebaseFirestore? firestore, FirebaseFunctions? functions})
    : _db = firestore ?? FirebaseFirestore.instance,
      _functions =
          functions ??
          FirebaseFunctions.instanceFor(region: AppConstants.functionsRegion);

  final FirebaseFirestore _db;
  final FirebaseFunctions _functions;

  /// 내 사주 서사를 가져온다. uid는 반드시 로그인한 본인이어야 한다
  /// (함수가 request.auth.uid로만 users/{uid} 문서를 갱신하기 때문).
  ///
  /// Phase 5-2부터 별자리·일간 같은 계산값을 클라이언트가 보내지 않는다.
  /// 서버가 비공개 출생정보로 직접 계산하는 것이 유일한 근거다.
  Future<FortuneNarrative> getMyFortune({required String uid}) async {
    final result = await _callFunction(() {
      final callable = _functions.httpsCallable('generateFortuneNarrative');
      return callable.call(<String, dynamic>{});
    }, label: 'generateFortuneNarrative');
    return FortuneNarrative.fromMap(
      Map<String, dynamic>.from(result.data as Map),
    );
  }

  /// 두 사람의 궁합 서사를 가져온다.
  Future<MatchFortuneResult> getMatchFortune({
    required String matchId,
    required String currentUid,
    required String otherUid,
  }) async {
    final result = await _callFunction(() {
      final callable = _functions.httpsCallable('generateMatchNarrative');
      return callable.call({'matchId': matchId});
    }, label: 'generateMatchNarrative');
    final data = Map<String, dynamic>.from(result.data as Map);
    final narrative = FortuneNarrative.fromMap(
      Map<String, dynamic>.from(data['narrative'] as Map),
    );
    final participantAttrs = Map<String, dynamic>.from(
      data['participantAttrs'] as Map,
    );
    final myAttrs = Map<String, dynamic>.from(
      participantAttrs[currentUid] as Map,
    );
    final otherAttrs = Map<String, dynamic>.from(
      participantAttrs[otherUid] as Map,
    );
    return MatchFortuneResult(
      narrative: narrative,
      myZodiac: _zodiacFromAttrs(myAttrs['zodiac']),
      mySaju: _sajuFromAttrs(myAttrs['saju']),
      otherZodiac: _zodiacFromAttrs(otherAttrs['zodiac']),
      otherSaju: _sajuFromAttrs(otherAttrs['saju']),
    );
  }

  /// 매치 궁합 서사 캐시만 읽는다.
  ///
  /// 홈의 "오늘의 인연"처럼 빠른 추천 UI에서는 새 GPT 호출을 만들지 않고,
  /// 이미 생성된 matches/{matchId}.fortuneMatch가 있을 때만 문구를 재사용한다.
  Future<FortuneNarrative?> getCachedMatchFortune(String matchId) async {
    final matchDoc = await _db.collection('matches').doc(matchId).get();
    final cached = matchDoc.data()?['fortuneMatch'] as Map<String, dynamic>?;
    if (cached == null) return null;
    return FortuneNarrative.fromMap(cached);
  }

  /// 오늘의 운세(애정 중심)를 가져온다.
  ///
  /// users/{uid}/dailyFortune/{yyyy-MM-dd} 문서로 하루 단위 캐싱한다 —
  /// 날짜가 바뀌면 문서 키가 달라져 자연히 새로 생성되고, 같은 날 재진입은
  /// 캐시를 그대로 읽어 GPT를 다시 부르지 않는다.
  ///
  /// Phase 5-2부터 날짜와 사주 근거를 모두 서버가 정한다 — 클라이언트 날짜와
  /// 계산값은 보내지 않는다. 로컬 날짜는 캐시 선조회에만 쓴다.
  Future<DailyFortune> getDailyFortune({
    required String uid,
    DateTime? now,
  }) async {
    final dateKey = _dateKey(now ?? DateTime.now());
    final docRef = _db
        .collection('users')
        .doc(uid)
        .collection('dailyFortune')
        .doc(dateKey);

    final cachedSnap = await docRef.get();
    final cached = cachedSnap.data();
    // 캐시 metadata가 없는 옛 문서는 서버가 재생성하도록 그냥 흘려보낸다.
    if (cached != null && cached['inputFingerprint'] is String) {
      return DailyFortune.fromMap(cached);
    }

    final result = await _callFunction(() {
      final callable = _functions.httpsCallable('generateDailyFortune');
      return callable.call(<String, dynamic>{});
    }, label: 'generateDailyFortune');
    return DailyFortune.fromMap(Map<String, dynamic>.from(result.data as Map));
  }

  /// 최근 [days]일의 오늘의 운세 기록을 날짜 역순으로 가져온다.
  ///
  /// 문서 ID가 yyyy-MM-dd라 최근 날짜 목록을 클라이언트에서 만든 뒤 각 문서를
  /// 직접 조회한다. 운세가 없는 날짜는 [FortuneHistoryEntry.fortune]을 null로
  /// 두어 "앱을 열지 않은 날"로 표시한다.
  Future<List<FortuneHistoryEntry>> getFortuneHistory({
    required String uid,
    int days = 7,
    DateTime? now,
  }) async {
    final today = _dateOnly(now ?? DateTime.now());
    final entries = await Future.wait(
      List.generate(days, (index) async {
        final date = today.subtract(Duration(days: index));
        final dateKey = _dateKey(date);
        final doc = await _db
            .collection('users')
            .doc(uid)
            .collection('dailyFortune')
            .doc(dateKey)
            .get();
        final data = doc.data();
        return FortuneHistoryEntry(
          dateKey: dateKey,
          date: date,
          fortune: data == null ? null : DailyFortune.fromMap(data),
        );
      }),
    );
    return entries;
  }

  /// 최근 [days]일의 운세 캐시를 생성한다.
  ///
  /// 발표/데모용 개발 기능에서만 호출한다. 실제 서비스에서는 사용자가 매일
  /// 사주 탭을 열 때 [getDailyFortune]이 자연스럽게 그날 문서를 만든다.
  ///
  /// Phase 5-2부터 서버가 Asia/Seoul 기준 오늘 날짜만 생성하므로, 이 호출은
  /// 과거 날짜 문서를 만들지 못하고 오늘 문서만 확인한다. 데모용 잔재다.
  Future<void> backfillRecentDailyFortunes({
    required String uid,
    int days = 7,
    DateTime? now,
  }) async {
    await getDailyFortune(uid: uid, now: now);
  }

  /// 매칭 채팅의 첫 대화 물꼬를 가져온다.
  ///
  /// matches/{matchId}.icebreakers에 3개 배열로 캐싱된다. 캐시가 없을 때만
  /// generateIcebreakers callable을 호출하며, 서버가 참가자 권한과 프로필 조회,
  /// GPT 호출을 모두 처리한다.
  Future<List<Icebreaker>> getIcebreakers(String matchId) async {
    _debugLog('[Icebreakers] 캐시 확인 시작 matchId=$matchId');
    try {
      final matchDoc = await _db.collection('matches').doc(matchId).get();
      final cached = matchDoc.data()?['icebreakers'] as List<dynamic>?;
      if (cached != null && cached.isNotEmpty) {
        final items = cached
            .map(
              (item) =>
                  Icebreaker.fromMap(Map<String, dynamic>.from(item as Map)),
            )
            .where((item) => item.topic.isNotEmpty && item.message.isNotEmpty)
            .toList();
        _debugLog('[Icebreakers] 캐시 hit count=${items.length}');
        return items;
      }

      _debugLog('[Icebreakers] 캐시 miss, callable 호출 matchId=$matchId');
      final callable = _functions.httpsCallable('generateIcebreakers');
      final result = await callable.call({'matchId': matchId});
      final data = Map<String, dynamic>.from(result.data as Map);
      final rawIcebreakers = data['icebreakers'] as List<dynamic>? ?? [];
      final items = rawIcebreakers
          .map(
            (item) =>
                Icebreaker.fromMap(Map<String, dynamic>.from(item as Map)),
          )
          .where((item) => item.topic.isNotEmpty && item.message.isNotEmpty)
          .toList();
      _debugLog('[Icebreakers] callable 성공 count=${items.length}');
      return items;
    } catch (e, st) {
      _debugLog('[Icebreakers] 실패 matchId=$matchId error=$e');
      _debugLog('$st');
      rethrow;
    }
  }

  /// 진행 중인 채팅을 자연스럽게 이어갈 AI 코치 문장을 가져온다.
  ///
  /// 서버와 동일하게 최신 메시지 ID 기준 짧은 캐시를 먼저 확인한다.
  /// 메시지가 없는 채팅방은 아이스브레이커 카드가 담당하므로 빈 리스트를 반환한다.
  Future<List<ConversationTip>> getConversationTips(String matchId) async {
    _debugLog('[ConversationTips] 캐시 확인 시작 matchId=$matchId');
    try {
      final matchRef = _db.collection('matches').doc(matchId);
      final latestMessageSnap = await matchRef
          .collection('messages')
          .orderBy('createdAt', descending: true)
          .limit(1)
          .get();
      if (latestMessageSnap.docs.isEmpty) {
        _debugLog('[ConversationTips] 메시지 없음 matchId=$matchId');
        return const [];
      }

      final latestMessageId = latestMessageSnap.docs.first.id;
      final matchDoc = await matchRef.get();
      final cached = matchDoc.data()?['conversationTips'];
      if (cached is Map) {
        final cacheMap = Map<String, dynamic>.from(cached);
        final tips = _conversationTipsFromList(
          cacheMap['suggestions'] as List<dynamic>?,
        );
        if (cacheMap['lastMessageId'] == latestMessageId && tips.length >= 2) {
          _debugLog('[ConversationTips] 캐시 hit count=${tips.length}');
          return tips;
        }
      }

      _debugLog('[ConversationTips] 캐시 miss, callable 호출 matchId=$matchId');
      final callable = _functions.httpsCallable('generateConversationTips');
      final result = await callable.call({'matchId': matchId});
      final data = Map<String, dynamic>.from(result.data as Map);
      final tips = _conversationTipsFromList(
        data['suggestions'] as List<dynamic>?,
      );
      _debugLog('[ConversationTips] callable 성공 count=${tips.length}');
      return tips;
    } on FirebaseFunctionsException catch (e) {
      if (e.code == 'not-found') {
        _debugLog('[ConversationTips] 대상 없음 matchId=$matchId');
        return const [];
      }
      _debugLog(
        '[ConversationTips] callable 실패 matchId=$matchId code=${e.code}',
      );
      rethrow;
    } catch (e) {
      _debugLog('[ConversationTips] 실패 matchId=$matchId error=$e');
      rethrow;
    }
  }

  List<ConversationTip> _conversationTipsFromList(List<dynamic>? rawItems) {
    return (rawItems ?? [])
        .map(ConversationTip.fromValue)
        .where((item) => item.message.trim().isNotEmpty)
        .take(3)
        .toList();
  }

  static String _dateKey(DateTime d) {
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '$y-$m-$day';
  }

  static DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  Future<HttpsCallableResult<dynamic>> _callFunction(
    Future<HttpsCallableResult<dynamic>> Function() call, {
    required String label,
  }) async {
    try {
      return await call();
    } on FirebaseFunctionsException catch (e) {
      final code = FortuneFailure.safeCode(e.code);
      _debugLog('[FortuneService] callable_failed label=$label code=$code');
      throw FortuneFailure(code);
    }
  }

  static void _debugLog(String message) {
    if (kDebugMode) {
      debugPrint(message);
    }
  }
}

class FortuneFailure implements Exception {
  final String code;

  const FortuneFailure(this.code);

  static const _allowedCodes = {
    'unauthenticated',
    'permission-denied',
    'failed-precondition',
    'resource-exhausted',
    'unavailable',
    'deadline-exceeded',
    'internal',
    'unknown',
  };

  static String safeCode(String code) =>
      _allowedCodes.contains(code) ? code : 'unknown';
}

class MatchFortuneResult {
  final FortuneNarrative narrative;
  final ZodiacInfo myZodiac;
  final SajuInfo mySaju;
  final ZodiacInfo otherZodiac;
  final SajuInfo otherSaju;

  const MatchFortuneResult({
    required this.narrative,
    required this.myZodiac,
    required this.mySaju,
    required this.otherZodiac,
    required this.otherSaju,
  });
}

ZodiacInfo _zodiacFromAttrs(Object? value) {
  final map = Map<String, dynamic>.from(value as Map);
  return ZodiacInfo(
    sign: map['sign'] as String? ?? '',
    element: map['element'] as String? ?? '',
  );
}

SajuInfo _sajuFromAttrs(Object? value) {
  final map = Map<String, dynamic>.from(value as Map);
  return SajuInfo(
    dayMaster: map['dayMaster'] as String? ?? '',
    element: map['element'] as String? ?? '',
  );
}
