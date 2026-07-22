import '../core/utils/text_sanitizer.dart';

/// GPT가 생성한 서사 속 개별 근거 항목.
class FortuneReason {
  final String icon;
  final String text;
  const FortuneReason({required this.icon, required this.text});

  factory FortuneReason.fromMap(Map<String, dynamic> map) {
    return FortuneReason(
      icon: _stripDecorativeSymbols(map['icon'] as String? ?? ''),
      text: _stripDecorativeSymbols(map['text'] as String? ?? ''),
    );
  }
}

/// Cloud Function(generateFortuneNarrative / generateMatchNarrative)이
/// 반환하는 서사 결과.
///
/// [relationshipStory]는 내 사주(개인) 서사에서는 null, 궁합 서사에서만 채워진다.
class FortuneNarrative {
  final String characterType;
  final String summary;
  final List<FortuneReason> reasons;
  final String? relationshipStory;

  /// 서버가 계산에 쓴 정밀도(Phase 5-2). 'dateOnly' | 'dateAndTime' | null(구버전).
  final String? precision;

  /// 궁합의 경우 두 사람 중 한 명이라도 출생시간이 없으면 true.
  final bool missingBirthTime;

  const FortuneNarrative({
    required this.characterType,
    required this.summary,
    required this.reasons,
    this.relationshipStory,
    this.precision,
    this.missingBirthTime = false,
  });

  factory FortuneNarrative.fromMap(Map<String, dynamic> map) {
    final rawReasons = map['reasons'] as List<dynamic>? ?? [];
    return FortuneNarrative(
      characterType: _stripDecorativeSymbols(
        map['characterType'] as String? ?? '',
      ),
      summary: _stripDecorativeSymbols(map['summary'] as String? ?? ''),
      reasons: rawReasons
          .map(
            (r) => FortuneReason.fromMap(Map<String, dynamic>.from(r as Map)),
          )
          .toList(),
      relationshipStory: (map['relationshipStory'] as String?) == null
          ? null
          : _stripDecorativeSymbols(map['relationshipStory'] as String),
      precision: map['precision'] as String?,
      missingBirthTime: map['missingBirthTime'] as bool? ?? false,
    );
  }
}

String _stripDecorativeSymbols(String value) => stripEmoji(value);

/// Cloud Function(generateDailyFortune)이 반환하는 "오늘의 운세"(애정 중심).
///
/// 하루 단위로 캐싱되므로(users/{uid}/dailyFortune/{yyyy-MM-dd}) 같은 날 다시
/// 열어도 이 값 그대로 보인다.
class DailyFortune {
  /// 1~5 사이 정수. 정밀한 확률이 아니라 하트/별 개수로 보여줄 오늘의 분위기 게이지.
  final int loveScore;
  final String mood; // 오늘의 키워드, 예: "설렘 가득"
  final String message; // 애정운 서사 2~3문장
  final String advice; // 오늘의 연애 조언 한 줄

  const DailyFortune({
    required this.loveScore,
    required this.mood,
    required this.message,
    required this.advice,
  });

  factory DailyFortune.fromMap(Map<String, dynamic> map) {
    final rawScore = map['loveScore'];
    final parsed = rawScore is int ? rawScore : int.tryParse('$rawScore') ?? 3;
    return DailyFortune(
      loveScore: parsed.clamp(1, 5),
      mood: map['mood'] as String? ?? '',
      message: map['message'] as String? ?? '',
      advice: map['advice'] as String? ?? '',
    );
  }
}

/// 특정 날짜의 운세 히스토리 항목.
///
/// [fortune]이 null이면 그날 앱을 열지 않아 캐시된 운세가 없는 상태다.
class FortuneHistoryEntry {
  final String dateKey; // yyyy-MM-dd
  final DateTime date;
  final DailyFortune? fortune;

  const FortuneHistoryEntry({
    required this.dateKey,
    required this.date,
    this.fortune,
  });

  bool get hasFortune => fortune != null;
}

/// 채팅 첫 메시지로 바로 써볼 수 있는 사주 기반 아이스브레이커.
class Icebreaker {
  final String topic;
  final String message;

  const Icebreaker({required this.topic, required this.message});

  factory Icebreaker.fromMap(Map<String, dynamic> map) {
    return Icebreaker(
      topic: map['topic'] as String? ?? '',
      message: map['message'] as String? ?? '',
    );
  }
}

/// 대화가 잠시 끊겼을 때 입력창에 채워볼 수 있는 AI 대화 코치 문장.
class ConversationTip {
  final String message;

  const ConversationTip({required this.message});

  factory ConversationTip.fromValue(Object? value) {
    return ConversationTip(message: value?.toString() ?? '');
  }
}
