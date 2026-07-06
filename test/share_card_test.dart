import 'package:dating_app/features/fortune/widgets/share_card.dart';
import 'package:dating_app/models/fortune_model.dart';
import 'package:dating_app/models/user_profile.dart';
import 'package:dating_app/services/fortune/fortune_calculator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('FortuneShareCard는 공유 캡처용 고정 비율로 렌더된다', (tester) async {
    final profile = UserProfile(
      uid: 'user_001',
      displayName: '테스트',
      birthDate: DateTime(1996, 3, 15),
      gender: 'other',
      bio: '',
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );
    final zodiac = FortuneCalculator.getZodiacSign(profile.birthDate);
    final saju = FortuneCalculator.getSaju(profile.birthDate);
    final balance = FortuneCalculator.getOhaengBalance(profile.birthDate);
    const narrative = FortuneNarrative(
      characterType: '✨ 테스트형',
      summary: '차분하지만 자기만의 리듬이 분명한 사람입니다.',
      reasons: [],
    );

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: FortuneShareCard(
            profile: profile,
            narrative: narrative,
            zodiac: zodiac,
            saju: saju,
            balance: balance,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final size = tester.getSize(find.byType(FortuneShareCard));
    expect(size, fortuneShareCardSize);
    expect(size.width * 3, 1080);
    expect(size.height * 3, 1350);
  });
}
