import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../models/fortune_model.dart';
import '../../../models/user_profile.dart';
import '../../../services/fortune/fortune_calculator.dart';

/// SNS 공유용 이미지 카드의 고정 크기.
///
/// 360x450 logical px를 pixelRatio 3.0으로 캡처하면 1080x1350 PNG가 된다.
const Size fortuneShareCardSize = Size(360, 450);

/// 내 사주 결과 공유용 카드.
class FortuneShareCard extends StatelessWidget {
  final UserProfile profile;
  final FortuneNarrative narrative;
  final ZodiacInfo zodiac;
  final SajuInfo saju;
  final Map<String, double> balance;

  const FortuneShareCard({
    super.key,
    required this.profile,
    required this.narrative,
    required this.zodiac,
    required this.saju,
    required this.balance,
  });

  @override
  Widget build(BuildContext context) {
    final strong = FortuneCalculator.strongestElement(balance);
    final weak = FortuneCalculator.weakestElement(balance);

    return _ShareCardFrame(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _ShareHeader(label: '나의 사주 캐릭터'),
          const Spacer(),
          Text(
            narrative.characterType,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 34,
              fontWeight: FontWeight.w900,
              height: 1.05,
            ),
          ),
          const SizedBox(height: 14),
          _AttributePills(
            values: [
              '${zodiac.sign} · ${zodiac.element}',
              '일간 ${saju.dayMaster}(${saju.element})',
            ],
          ),
          const SizedBox(height: 20),
          _QuoteText(text: narrative.summary),
          const SizedBox(height: 18),
          _OhaengSummary(strong: strong.key, weak: weak.key),
          const Spacer(),
          _Watermark(name: profile.displayName),
        ],
      ),
    );
  }
}

/// 두 사람 궁합 결과 공유용 카드.
class MatchShareCard extends StatelessWidget {
  final UserProfile myProfile;
  final UserProfile otherProfile;
  final FortuneNarrative narrative;
  final ZodiacInfo myZodiac;
  final SajuInfo mySaju;
  final ZodiacInfo otherZodiac;
  final SajuInfo otherSaju;

  const MatchShareCard({
    super.key,
    required this.myProfile,
    required this.otherProfile,
    required this.narrative,
    required this.myZodiac,
    required this.mySaju,
    required this.otherZodiac,
    required this.otherSaju,
  });

  @override
  Widget build(BuildContext context) {
    final hint = FortuneCalculator.getCompatibilityHint(
      myProfile.birthDate,
      otherProfile.birthDate,
    );
    final story = narrative.relationshipStory?.trim();

    return _ShareCardFrame(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _ShareHeader(label: '우리의 사주 궁합'),
          const Spacer(),
          _CoupleNames(myProfile: myProfile, otherProfile: otherProfile),
          const SizedBox(height: 16),
          _HeartLine(label: '${hint.emoji} ${hint.shortLabel}'),
          const SizedBox(height: 18),
          Text(
            narrative.characterType,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.w900,
              height: 1.08,
            ),
          ),
          const SizedBox(height: 14),
          _AttributePills(
            values: [
              '${myZodiac.sign} · ${mySaju.element}',
              '${otherZodiac.sign} · ${otherSaju.element}',
            ],
          ),
          const SizedBox(height: 20),
          _QuoteText(
            text: story?.isNotEmpty == true ? story! : narrative.summary,
          ),
          const Spacer(),
          _Watermark(
            name: '${myProfile.displayName} × ${otherProfile.displayName}',
          ),
        ],
      ),
    );
  }
}

class _ShareCardFrame extends StatelessWidget {
  final Widget child;

  const _ShareCardFrame({required this.child});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: fortuneShareCardSize.width,
      height: fortuneShareCardSize.height,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFFF4E6A), Color(0xFFFF8E53), Color(0xFF7C5CFF)],
          ),
        ),
        child: Stack(
          children: [
            Positioned(
              top: -54,
              right: -48,
              child: _GlowCircle(size: 170, color: Colors.white24),
            ),
            Positioned(
              bottom: -70,
              left: -55,
              child: _GlowCircle(size: 190, color: Colors.white12),
            ),
            Padding(padding: const EdgeInsets.all(28), child: child),
          ],
        ),
      ),
    );
  }
}

class _ShareHeader extends StatelessWidget {
  final String label;

  const _ShareHeader({required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Icon(
            Icons.favorite_rounded,
            color: Colors.white,
            size: 18,
          ),
        ),
        const SizedBox(width: 10),
        Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }
}

class _AttributePills extends StatelessWidget {
  final List<String> values;

  const _AttributePills({required this.values});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final value in values)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: Colors.white24),
            ),
            child: Text(
              value,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
      ],
    );
  }
}

class _QuoteText extends StatelessWidget {
  final String text;

  const _QuoteText({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
      ),
      child: Text(
        text,
        maxLines: 4,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 14,
          height: 1.5,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _OhaengSummary extends StatelessWidget {
  final String strong;
  final String weak;

  const _OhaengSummary({required this.strong, required this.weak});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _MiniMetric(label: '강한 기운', value: strong),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _MiniMetric(label: '채울 기운', value: weak),
        ),
      ],
    );
  }
}

class _MiniMetric extends StatelessWidget {
  final String label;
  final String value;

  const _MiniMetric({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

class _CoupleNames extends StatelessWidget {
  final UserProfile myProfile;
  final UserProfile otherProfile;

  const _CoupleNames({required this.myProfile, required this.otherProfile});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: _NameBlock(name: myProfile.displayName)),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 10),
          child: Icon(Icons.favorite_rounded, color: Colors.white, size: 28),
        ),
        Expanded(child: _NameBlock(name: otherProfile.displayName)),
      ],
    );
  }
}

class _NameBlock extends StatelessWidget {
  final String name;

  const _NameBlock({required this.name});

  @override
  Widget build(BuildContext context) {
    return Text(
      name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 20,
        fontWeight: FontWeight.w900,
      ),
    );
  }
}

class _HeartLine extends StatelessWidget {
  final String label;

  const _HeartLine({required this.label});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: Colors.white24),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

class _Watermark extends StatelessWidget {
  final String name;

  const _Watermark({required this.name});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(width: 10),
        const Text(
          AppConstants.appName,
          style: TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w900,
            letterSpacing: 0.2,
          ),
        ),
      ],
    );
  }
}

class _GlowCircle extends StatelessWidget {
  final double size;
  final Color color;

  const _GlowCircle({required this.size, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(shape: BoxShape.circle, color: color),
    );
  }
}
