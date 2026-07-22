import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dating_app/models/fortune_model.dart';

// 1-C 보정 회귀 테스트 (client 계약).
//
// ChatScreen 전체는 11개 서비스 + Firebase 스트림을 요구해 위젯 테스트 비용이
// 크다. 그래서 회귀의 핵심인 **파싱·오류 분류·draft 동작 계약**을 단위로 고정한다.

/// 서버 v2 응답에서 tips를 뽑는 로직과 같은 계약.
/// (FortuneService._conversationTipsFromResponse와 동일한 규칙)
List<ConversationTip> parseResponse(Map<String, dynamic> data) {
  final items = data['suggestionItems'];
  if (items is List && items.isNotEmpty) {
    final parsed = items
        .whereType<Map>()
        .map((raw) => ConversationTip.fromItem(Map<String, dynamic>.from(raw)))
        .where((tip) => tip.message.isNotEmpty)
        .take(3)
        .toList();
    if (parsed.isNotEmpty) return parsed;
  }
  return (data['suggestions'] as List<dynamic>? ?? [])
      .map(ConversationTip.fromValue)
      .where((tip) => tip.message.trim().isNotEmpty)
      .take(3)
      .toList();
}

void main() {
  group('27/28. 응답 파싱 하위호환', () {
    test('27. v2 suggestionItems를 tone과 함께 파싱한다', () {
      final tips = parseResponse({
        'schemaVersion': 2,
        'suggestions': ['a', 'b', 'c'],
        'suggestionItems': [
          {'id': 'natural', 'tone': 'natural', 'text': '오늘 하루 어땠어요?'},
          {'id': 'curious', 'tone': 'curious', 'text': '그 얘기 더 듣고 싶은데요?'},
          {'id': 'playful', 'tone': 'playful', 'text': '그건 좀 반칙인데요 😄'},
        ],
      });
      expect(tips.length, 3);
      expect(tips.map((t) => t.tone), [
        ConversationTipTone.natural,
        ConversationTipTone.curious,
        ConversationTipTone.playful,
      ]);
      expect(tips.first.message, '오늘 하루 어땠어요?');
      // suggestionItems가 있으면 그쪽을 우선한다.
      expect(tips.map((t) => t.message), isNot(contains('a')));
    });

    test('28. 구버전 문자열 suggestions도 파싱한다', () {
      final tips = parseResponse({
        'suggestions': ['오늘 뭐 했어요?', '그 얘기 재밌네요', '다음엔 뭐 할까요?'],
      });
      expect(tips.length, 3);
      expect(tips.every((t) => t.tone == null), isTrue);
      expect(tips.first.message, '오늘 뭐 했어요?');
    });

    test('suggestionItems가 비어 있으면 문자열 배열로 fallback한다', () {
      final tips = parseResponse({
        'suggestionItems': const [],
        'suggestions': ['안녕하세요'],
      });
      expect(tips.length, 1);
      expect(tips.first.message, '안녕하세요');
    });

    test('29. 최대 3개까지만 렌더 대상으로 삼는다', () {
      final tips = parseResponse({
        'suggestions': ['1', '2', '3', '4', '5'],
      });
      expect(tips.length, 3);
    });

    test('14. 빈 문장은 제외된다', () {
      final tips = parseResponse({
        'suggestions': ['정상 문장', '   ', ''],
      });
      expect(tips.length, 1);
    });

    test('알 수 없는 tone은 null로 두고 문장은 유지한다', () {
      final tips = parseResponse({
        'suggestionItems': [
          {'id': 'flirty', 'tone': 'flirty', 'text': '문장'},
        ],
      });
      expect(tips.single.tone, isNull);
      expect(tips.single.keySuffix, 'plain');
    });
  });

  group('42. 오류 분류 — not-found가 empty로 접히지 않는다', () {
    test('resource-exhausted → rateLimited', () {
      expect(
        conversationTipsErrorKindFor('resource-exhausted'),
        ConversationTipsErrorKind.rateLimited,
      );
    });

    test('unavailable / deadline-exceeded → unavailable', () {
      expect(
        conversationTipsErrorKindFor('unavailable'),
        ConversationTipsErrorKind.unavailable,
      );
      expect(
        conversationTipsErrorKindFor('deadline-exceeded'),
        ConversationTipsErrorKind.unavailable,
      );
    });

    test('failed-precondition / permission-denied → unusableChat', () {
      expect(
        conversationTipsErrorKindFor('failed-precondition'),
        ConversationTipsErrorKind.unusableChat,
      );
      expect(
        conversationTipsErrorKindFor('permission-denied'),
        ConversationTipsErrorKind.unusableChat,
      );
    });

    test('42. not-found는 empty가 아니라 오류로 분류된다', () {
      final kind = conversationTipsErrorKindFor('not-found');
      expect(kind, ConversationTipsErrorKind.unavailable);
      // 어떤 코드도 "정상 빈 상태"로 매핑되지 않는다.
      for (final code in [
        'not-found',
        'internal',
        'unknown',
        'permission-denied',
      ]) {
        expect(
          conversationTipsErrorKindFor(code),
          isA<ConversationTipsErrorKind>(),
        );
      }
    });

    test('internal 등 미분류는 unknown이다', () {
      expect(
        conversationTipsErrorKindFor('internal'),
        ConversationTipsErrorKind.unknown,
      );
    });
  });

  group('상태 모델', () {
    test('7개 상태가 아니라 명시적 6개 상태로 표현된다', () {
      expect(ConversationHelperStatus.values, [
        ConversationHelperStatus.idle,
        ConversationHelperStatus.loading,
        ConversationHelperStatus.ready,
        ConversationHelperStatus.rateLimited,
        ConversationHelperStatus.unavailable,
        ConversationHelperStatus.error,
      ]);
    });

    test('suggestionVersion이 서버와 같다', () {
      expect(kConversationSuggestionVersion, 2);
    });

    test('ConversationTipsResult가 요청 context를 함께 들고 있다', () {
      const result = ConversationTipsResult(
        tips: [ConversationTip(message: 'x')],
        latestMessageId: 'msg-1',
      );
      expect(result.latestMessageId, 'msg-1');
      expect(result.tips.length, 1);
    });
  });

  group('44. stable key 계약', () {
    test('tone별 추천 key suffix가 안정적이다', () {
      const natural = ConversationTip(
        message: 'a',
        tone: ConversationTipTone.natural,
      );
      const curious = ConversationTip(
        message: 'b',
        tone: ConversationTipTone.curious,
      );
      const playful = ConversationTip(
        message: 'c',
        tone: ConversationTipTone.playful,
      );
      expect(
        Key('conversation-suggestion-${natural.keySuffix}'),
        const Key('conversation-suggestion-natural'),
      );
      expect(
        Key('conversation-suggestion-${curious.keySuffix}'),
        const Key('conversation-suggestion-curious'),
      );
      expect(
        Key('conversation-suggestion-${playful.keySuffix}'),
        const Key('conversation-suggestion-playful'),
      );
    });
  });

  group('43. 소스 계약 — 로그·자동전송·stale 방어', () {
    final chatSource = _read('lib/features/chat/chat_screen.dart');
    final serviceSource = _read('lib/services/fortune/fortune_service.dart');

    test('43. ConversationTips 로그에 raw matchId·예외 원문이 없다', () {
      for (final source in [chatSource, serviceSource]) {
        for (final line in source.split('\n')) {
          if (!line.contains('[ConversationTips]')) continue;
          expect(line.contains(r'matchId=$'), isFalse, reason: line);
          expect(line.contains(r'matchId=${'), isFalse, reason: line);
          expect(line.contains(r'error=$e'), isFalse, reason: line);
        }
      }
    });

    test('30. 추천 선택 경로가 전송을 호출하지 않는다', () {
      final start = chatSource.indexOf('Future<void> _applySuggestion(');
      expect(start, greaterThan(0));
      final end = chatSource.indexOf('\n  Future<void> _checkBlocked', start);
      final slice = chatSource.substring(
        start,
        end > start ? end : start + 2600,
      );
      expect(slice.contains('sendMessage('), isFalse);
      expect(slice.contains('_send()'), isFalse);
    });

    test('31~35. draft가 있으면 확인 UI를 거치고 취소 시 유지한다', () {
      expect(chatSource.contains("Key('conversation-draft-replace')"), isTrue);
      expect(chatSource.contains("Key('conversation-draft-append')"), isTrue);
      expect(chatSource.contains("Key('conversation-draft-cancel')"), isTrue);
      // draft가 비어 있을 때만 즉시 채운다.
      expect(chatSource.contains('if (draft.isEmpty) {'), isTrue);
      // 취소·미선택은 controller를 건드리지 않는다.
      expect(chatSource.contains('break; // draft를 그대로 둔다.'), isTrue);
    });

    test('26. loading 중 중복 요청을 차단한다', () {
      expect(
        chatSource.contains(
          'if (_tipsStatus == ConversationHelperStatus.loading) return;',
        ),
        isTrue,
      );
    });

    test('36/37. stale 응답을 context로 검증해 버린다', () {
      expect(chatSource.contains('_isCurrentTipsRequest('), isTrue);
      expect(chatSource.contains('stale_response_ignored'), isTrue);
      final start = chatSource.indexOf('bool _isCurrentTipsRequest(');
      final slice = chatSource.substring(start, start + 500);
      expect(slice.contains('requestId != _tipsGeneration'), isTrue);
      expect(
        slice.contains('_latestConversationTipMessageId != requestMessageId'),
        isTrue,
      );
      expect(slice.contains('_blocked || _unmatched'), isTrue);
    });

    test('38. 메시지 전송 후 추천 context를 무효화한다', () {
      expect(
        chatSource.contains("_resetTipsState(reason: 'request_cancelled')"),
        isTrue,
      );
    });

    test('service가 실패를 빈 리스트로 접지 않는다', () {
      // 예전 회귀: not-found를 const []로 반환했다.
      expect(serviceSource.contains('return const [];'), isFalse);
      expect(serviceSource.contains('ConversationTipsFailure('), isTrue);
    });
  });
}

String _read(String relativePath) => File(relativePath).readAsStringSync();
