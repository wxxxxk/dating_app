import 'package:dating_app/models/match_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MatchModel.unmatchedBy', () {
    MatchModel buildMatch({List<String> unmatchedBy = const []}) {
      return MatchModel(
        matchId: 'a_b',
        participants: const ['a', 'b'],
        uid1: 'a',
        uid2: 'b',
        matchedAt: DateTime(2026, 1, 1),
        unmatchedBy: unmatchedBy,
      );
    }

    test('생성자 기본값은 빈 배열이다', () {
      final match = MatchModel(
        matchId: 'a_b',
        participants: const ['a', 'b'],
        uid1: 'a',
        uid2: 'b',
        matchedAt: DateTime(2026, 1, 1),
      );

      expect(match.unmatchedBy, isEmpty);
      expect(match.isUnmatched, isFalse);
    });

    test('unmatchedBy가 비어있지 않으면 isUnmatched는 true다', () {
      final match = buildMatch(unmatchedBy: const ['a']);

      expect(match.isUnmatched, isTrue);
    });

    test('한쪽만 해제해도(상대 uid는 안 넣어도) isUnmatched는 true다', () {
      // "양쪽 모두 목록에서 사라지게" 요구사항의 핵심 — 배열에 누가 들어있는지가
      // 아니라 "비어있는지 아닌지"만으로 숨김 여부를 판단해야 한다.
      final match = buildMatch(unmatchedBy: const ['b']);

      expect(match.isUnmatched, isTrue);
    });

    test('celebratedBy와 unmatchedBy는 서로 독립적으로 동작한다', () {
      final match = MatchModel(
        matchId: 'a_b',
        participants: const ['a', 'b'],
        uid1: 'a',
        uid2: 'b',
        matchedAt: DateTime(2026, 1, 1),
        celebratedBy: const ['a'],
        unmatchedBy: const ['b'],
      );

      expect(match.hasCelebrated('a'), isTrue);
      expect(match.isPendingCelebrationFor('b'), isTrue);
      expect(match.isUnmatched, isTrue);
    });
  });
}
