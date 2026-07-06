import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

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
      _functions = functions ?? FirebaseFunctions.instance;

  final FirebaseFirestore _db;
  final FirebaseFunctions _functions;

  /// 내 사주 서사를 가져온다. uid는 반드시 로그인한 본인이어야 한다
  /// (함수가 request.auth.uid로만 users/{uid} 문서를 갱신하기 때문).
  Future<FortuneNarrative> getMyFortune({
    required String uid,
    required ZodiacInfo zodiac,
    required SajuInfo saju,
  }) async {
    final userDoc = await _db.collection('users').doc(uid).get();
    final cached = userDoc.data()?['fortuneNarrative'] as Map<String, dynamic>?;
    if (cached != null) return FortuneNarrative.fromMap(cached);

    final callable = _functions.httpsCallable('generateFortuneNarrative');
    final result = await callable.call({
      'attrs': {'zodiac': zodiac.toAttrs(), 'saju': saju.toAttrs()},
    });
    return FortuneNarrative.fromMap(
      Map<String, dynamic>.from(result.data as Map),
    );
  }

  /// 두 사람의 궁합 서사를 가져온다.
  Future<FortuneNarrative> getMatchFortune({
    required String matchId,
    required ZodiacInfo myZodiac,
    required SajuInfo mySaju,
    required ZodiacInfo otherZodiac,
    required SajuInfo otherSaju,
  }) async {
    final matchDoc = await _db.collection('matches').doc(matchId).get();
    final cached = matchDoc.data()?['fortuneMatch'] as Map<String, dynamic>?;
    if (cached != null) return FortuneNarrative.fromMap(cached);

    final callable = _functions.httpsCallable('generateMatchNarrative');
    final result = await callable.call({
      'matchId': matchId,
      'userA': {'zodiac': myZodiac.toAttrs(), 'saju': mySaju.toAttrs()},
      'userB': {'zodiac': otherZodiac.toAttrs(), 'saju': otherSaju.toAttrs()},
    });
    return FortuneNarrative.fromMap(
      Map<String, dynamic>.from(result.data as Map),
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
  Future<DailyFortune> getDailyFortune({
    required String uid,
    required ZodiacInfo zodiac,
    required SajuInfo saju,
    DateTime? now,
  }) async {
    final dateKey = _dateKey(now ?? DateTime.now());
    final docRef = _db
        .collection('users')
        .doc(uid)
        .collection('dailyFortune')
        .doc(dateKey);

    final cachedSnap = await docRef.get();
    if (cachedSnap.data() != null) {
      return DailyFortune.fromMap(cachedSnap.data()!);
    }

    final callable = _functions.httpsCallable('generateDailyFortune');
    final result = await callable.call({
      'date': dateKey,
      'attrs': {'zodiac': zodiac.toAttrs(), 'saju': saju.toAttrs()},
    });
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
  Future<void> backfillRecentDailyFortunes({
    required String uid,
    required ZodiacInfo zodiac,
    required SajuInfo saju,
    int days = 7,
    DateTime? now,
  }) async {
    final today = _dateOnly(now ?? DateTime.now());
    for (var index = 0; index < days; index++) {
      final date = today.subtract(Duration(days: index));
      await getDailyFortune(uid: uid, zodiac: zodiac, saju: saju, now: date);
    }
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
    } catch (e, st) {
      _debugLog('[ConversationTips] 실패 matchId=$matchId error=$e');
      _debugLog('$st');
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

  static void _debugLog(String message) {
    if (kDebugMode) {
      debugPrint(message);
    }
  }
}
