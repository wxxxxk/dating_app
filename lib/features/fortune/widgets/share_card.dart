import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/app_colors.dart';
import '../../../models/fortune_model.dart';
import '../../../models/user_profile.dart';
import '../../../services/fortune/fortune_calculator.dart';
import '../../../shared/widgets/app_components.dart';

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

    return _FortuneShareFrame(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _FortuneShareHeader(),
          const SizedBox(height: 20),

          // 핵심 결과 문장. 이 카드에서 가장 먼저 읽혀야 한다.
          Text(
            narrative.characterType,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: AppFonts.display,
              color: AppColors.textStrong,
              fontSize: 30,
              height: 1.12,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),

          _FortuneShareMetadata(zodiac: zodiac, saju: saju),
          const SizedBox(height: 16),

          _FortuneShareSummary(text: narrative.summary),

          // 남는 세로 여백은 본문과 하단 블록 사이에 모은다. 아래 3요소
          // (구분선 · 오행 요약 · 이름/앱명)는 한 덩어리로 카드 바닥에 붙어,
          // 짧은 결과에서도 아래쪽이 휑해 보이지 않는다.
          const Spacer(),
          const _FortuneShareDivider(),
          const SizedBox(height: 14),
          _FortuneElementSummary(strong: strong.key, weak: weak.key),
          const SizedBox(height: 16),
          _FortuneShareFooter(name: profile.displayName),
        ],
      ),
    );
  }
}

// ═══ FortuneShareCard 전용 presentation ══════════════════════════════════════
//
// 아래 위젯들은 FortuneShareCard에서만 쓴다. MatchShareCard는 기존
// _ShareCardFrame/_ShareHeader/_AttributePills/_QuoteText/_Watermark를 그대로
// 사용하므로 이번 변경으로 렌더 트리가 달라지지 않는다.
//
// 공유 PNG는 정적 이미지다 — 이 파일의 어떤 위젯도 애니메이션을 쓰지 않는다.
// ConnectionMotif도 기본값(progress: 1)의 완성 상태로만 그린다.

/// 웜 화이트 + 아주 옅은 민트·코랄 tonal gradient 프레임.
///
/// 캡처 크기 계약(360x450 → pixelRatio 3.0 → 1080x1350)은 그대로다.
class _FortuneShareFrame extends StatelessWidget {
  final Widget child;

  const _FortuneShareFrame({required this.child});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: fortuneShareCardSize.width,
      height: fortuneShareCardSize.height,
      child: DecoratedBox(
        // stop을 3개로 제한한다 — 너무 촘촘한 gradient는 PNG 압축 후
        // banding이 눈에 띈다.
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              AppColors.surfacePrimary,
              AppColors.expressiveAccentSoft,
              AppColors.surfaceMintSoft,
            ],
            stops: [0.08, 0.62, 1],
          ),
        ),
        child: Padding(padding: const EdgeInsets.all(28), child: child),
      ),
    );
  }
}

/// eyebrow + 시그니처 모티프. 하트/별/도장 아이콘을 쓰지 않는다.
class _FortuneShareHeader extends StatelessWidget {
  const _FortuneShareHeader();

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const Expanded(
          child: Text(
            '나의 사주 인사이트',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: AppFonts.body,
              color: AppColors.brandPrimaryStrong,
              fontSize: 12,
              height: 1.2,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.4,
            ),
          ),
        ),
        // 작은 썸네일에서도 형태가 남도록 stroke를 앱 화면보다 굵게 쓴다.
        const SizedBox(
          width: 64,
          height: 34,
          child: ConnectionMotif(strokeWidth: 2.2, opacity: 0.9),
        ),
      ],
    );
  }
}

/// 별자리·일간을 pill이 아니라 두 줄 compact metadata로 적는다.
class _FortuneShareMetadata extends StatelessWidget {
  final ZodiacInfo zodiac;
  final SajuInfo saju;

  const _FortuneShareMetadata({required this.zodiac, required this.saju});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _FortuneShareMetaLine(
          color: AppColors.brandPrimary,
          text: '${zodiac.sign} · ${zodiac.element}',
        ),
        const SizedBox(height: 5),
        _FortuneShareMetaLine(
          color: AppColors.expressiveAccent,
          text: '일간 ${saju.dayMaster}(${saju.element})',
        ),
      ],
    );
  }
}

class _FortuneShareMetaLine extends StatelessWidget {
  final Color color;
  final String text;

  const _FortuneShareMetaLine({required this.color, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 5,
          height: 5,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: AppFonts.body,
              color: AppColors.textBody,
              fontSize: 12,
              height: 1.3,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

/// 어두운 quote 박스를 폐기하고, 왼쪽 민트 rule이 붙은 본문으로 읽게 한다.
/// summary 원문은 그대로 쓰고 재작성·요약하지 않는다.
class _FortuneShareSummary extends StatelessWidget {
  final String text;

  /// 내 사주 카드는 4줄, 궁합 카드는 관계 서사가 길어 5줄까지 쓴다.
  final int maxLines;

  const _FortuneShareSummary({required this.text, this.maxLines = 4});

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            width: 2,
            decoration: BoxDecoration(
              color: AppColors.brandPrimary.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              maxLines: maxLines,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: AppFonts.body,
                color: AppColors.textStrong,
                fontSize: 13.5,
                height: 1.55,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 본문과 하단 요약 블록을 나누는 아주 얇은 구분선.
class _FortuneShareDivider extends StatelessWidget {
  const _FortuneShareDivider();

  @override
  Widget build(BuildContext context) {
    // 1px은 PNG 압축 후 사라질 수 있어 1.2px로 둔다(캡처 시 3.6px).
    return Container(height: 1.2, color: AppColors.borderSubtle);
  }
}

/// 강한 기운 / 채울 기운. label과 값은 기존 계약 그대로이고, 큰 반투명 카드
/// 대신 canvas 위 definition row로 적는다. 오행 전통 5색은 쓰지 않는다.
class _FortuneElementSummary extends StatelessWidget {
  final String strong;
  final String weak;

  const _FortuneElementSummary({required this.strong, required this.weak});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _FortuneElementRow(
          label: '강한 기운',
          value: strong,
          dotColor: AppColors.brandPrimary,
        ),
        const SizedBox(height: 6),
        _FortuneElementRow(
          label: '채울 기운',
          value: weak,
          dotColor: AppColors.expressiveAccent,
        ),
      ],
    );
  }
}

class _FortuneElementRow extends StatelessWidget {
  final String label;
  final String value;
  final Color dotColor;

  const _FortuneElementRow({
    required this.label,
    required this.value,
    required this.dotColor,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 5,
          height: 5,
          decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
        ),
        const SizedBox(width: 7),
        Text(
          label,
          style: const TextStyle(
            fontFamily: AppFonts.body,
            color: AppColors.textMuted,
            fontSize: 11.5,
            height: 1.2,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: AppFonts.body,
              color: AppColors.textStrong,
              fontSize: 20,
              height: 1.15,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ],
    );
  }
}

/// 사용자 이름 + 앱명. 이름이 길어도 앱명이 밀려나지 않도록 이름 쪽만 줄인다.
class _FortuneShareFooter extends StatelessWidget {
  final String name;

  const _FortuneShareFooter({required this.name});

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
              fontFamily: AppFonts.body,
              color: AppColors.textMuted,
              fontSize: 11,
              height: 1.2,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(width: 10),
        const Text(
          AppConstants.appName,
          style: TextStyle(
            fontFamily: AppFonts.body,
            color: AppColors.brandPrimaryStrong,
            fontSize: 12,
            height: 1.2,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.2,
          ),
        ),
      ],
    );
  }
}

/// 궁합 결과 공유용 카드 (Design Phase 1-G).
///
/// **공개/비공개 경계**: 이 카드는 상대의 [UserProfile]이나 birthDate를 받지
/// 않는다. 화면이 이미 서버에서 받아 표시 중인 안전한 값(표시 이름, 별자리,
/// 일간/오행, 서사)만 문자열로 전달받는다. 그래서 공유를 위해 상대의 비공개
/// 프로필을 새로 조회할 이유 자체가 없다.
///
/// 아래 [MatchShareCard]는 상대 UserProfile을 요구하는 구버전이라 그대로 두되
/// 사용하지 않는다(호출부 없음).
class MatchFortuneShareCard extends StatelessWidget {
  final String myDisplayName;
  final String otherDisplayName;
  final FortuneNarrative narrative;
  final ZodiacInfo myZodiac;
  final SajuInfo mySaju;
  final ZodiacInfo otherZodiac;
  final SajuInfo otherSaju;

  const MatchFortuneShareCard({
    super.key,
    required this.myDisplayName,
    required this.otherDisplayName,
    required this.narrative,
    required this.myZodiac,
    required this.mySaju,
    required this.otherZodiac,
    required this.otherSaju,
  });

  @override
  Widget build(BuildContext context) {
    // 관계 서사가 있으면 그쪽을 쓰고, 없으면 요약을 쓴다. 원문은 그대로다.
    final story = narrative.relationshipStory?.trim();
    final body = (story != null && story.isNotEmpty)
        ? story
        : narrative.summary;

    return _FortuneShareFrame(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _MatchShareHeader(),
          const SizedBox(height: 18),

          _MatchSharePair(
            myDisplayName: myDisplayName,
            otherDisplayName: otherDisplayName,
            myZodiac: myZodiac,
            mySaju: mySaju,
            otherZodiac: otherZodiac,
            otherSaju: otherSaju,
          ),
          const SizedBox(height: 18),

          // 궁합의 핵심 결과. 점수나 확률은 만들지 않는다.
          Text(
            narrative.characterType,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: AppFonts.display,
              color: AppColors.textStrong,
              fontSize: 26,
              height: 1.15,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),

          _FortuneShareSummary(text: body, maxLines: 5),

          const Spacer(),
          const _FortuneShareDivider(),
          const SizedBox(height: 14),
          _FortuneShareFooter(name: '$myDisplayName × $otherDisplayName'),
        ],
      ),
    );
  }
}

/// 궁합 카드 header. 하트를 쓰지 않는다.
///
/// 모티프는 여기에 두지 않는다 — 이 카드에서는 두 사람 사이를 잇는 곡선이
/// 곧 모티프이고, 상단에 한 번 더 그리면 같은 도형이 두 번 반복된다.
class _MatchShareHeader extends StatelessWidget {
  const _MatchShareHeader();

  @override
  Widget build(BuildContext context) {
    return const Text(
      '우리의 궁합 인사이트',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontFamily: AppFonts.body,
        color: AppColors.brandPrimaryStrong,
        fontSize: 12,
        height: 1.2,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.4,
      ),
    );
  }
}

/// 두 사람 블록 — 이름 + 별자리·일간. 사진을 쓰지 않으므로 네트워크 로딩에
/// 의존하지 않고, 캡처 시점과 무관하게 항상 같은 결과가 나온다.
class _MatchSharePair extends StatelessWidget {
  final String myDisplayName;
  final String otherDisplayName;
  final ZodiacInfo myZodiac;
  final SajuInfo mySaju;
  final ZodiacInfo otherZodiac;
  final SajuInfo otherSaju;

  const _MatchSharePair({
    required this.myDisplayName,
    required this.otherDisplayName,
    required this.myZodiac,
    required this.mySaju,
    required this.otherZodiac,
    required this.otherSaju,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _MatchSharePerson(
            dotColor: AppColors.brandPrimary,
            name: myDisplayName,
            zodiac: myZodiac,
            saju: mySaju,
          ),
        ),
        // 두 사람을 잇는 완성된 곡선(progress 기본값 1.0).
        const SizedBox(
          width: 56,
          height: 46,
          child: ConnectionMotif(strokeWidth: 2.2),
        ),
        Expanded(
          child: _MatchSharePerson(
            dotColor: AppColors.expressiveAccent,
            name: otherDisplayName,
            zodiac: otherZodiac,
            saju: otherSaju,
            alignEnd: true,
          ),
        ),
      ],
    );
  }
}

class _MatchSharePerson extends StatelessWidget {
  final Color dotColor;
  final String name;
  final ZodiacInfo zodiac;
  final SajuInfo saju;
  final bool alignEnd;

  const _MatchSharePerson({
    required this.dotColor,
    required this.name,
    required this.zodiac,
    required this.saju,
    this.alignEnd = false,
  });

  @override
  Widget build(BuildContext context) {
    final align = alignEnd ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final textAlign = alignEnd ? TextAlign.right : TextAlign.left;

    return Column(
      crossAxisAlignment: align,
      children: [
        Row(
          mainAxisAlignment: alignEnd
              ? MainAxisAlignment.end
              : MainAxisAlignment.start,
          children: [
            if (!alignEnd) ...[_Dot(color: dotColor), const SizedBox(width: 6)],
            Flexible(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: textAlign,
                style: const TextStyle(
                  fontFamily: AppFonts.body,
                  color: AppColors.textStrong,
                  fontSize: 15,
                  height: 1.2,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            if (alignEnd) ...[const SizedBox(width: 6), _Dot(color: dotColor)],
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '${zodiac.sign} · ${saju.dayMaster}(${saju.element})',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: textAlign,
          style: const TextStyle(
            fontFamily: AppFonts.body,
            color: AppColors.textBody,
            fontSize: 11,
            height: 1.35,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _Dot extends StatelessWidget {
  final Color color;

  const _Dot({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 5,
      height: 5,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
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
          _HeartLine(label: hint.shortLabel),
          const SizedBox(height: 18),
          Text(
            narrative.characterType,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: AppColors.surface,
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
        decoration: const BoxDecoration(color: AppColors.seal),
        child: Stack(
          children: [
            Positioned(
              top: -54,
              right: -48,
              child: _GlowCircle(
                size: 170,
                color: AppColors.surface.withValues(alpha: 0.24),
              ),
            ),
            Positioned(
              bottom: -70,
              left: -55,
              child: _GlowCircle(
                size: 190,
                color: AppColors.surface.withValues(alpha: 0.12),
              ),
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
            color: AppColors.surface.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(AppRadius.button),
          ),
          child: const Icon(
            Icons.favorite_rounded,
            color: AppColors.surface,
            size: 18,
          ),
        ),
        const SizedBox(width: 10),
        Text(
          label,
          style: const TextStyle(
            color: AppColors.surface,
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
              color: AppColors.surface.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(AppRadius.chip),
              border: Border.all(
                color: AppColors.surface.withValues(alpha: 0.24),
              ),
            ),
            child: Text(
              value,
              style: const TextStyle(
                color: AppColors.surface,
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
        color: AppColors.ink.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.surface.withValues(alpha: 0.16)),
      ),
      child: Text(
        text,
        maxLines: 4,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: AppColors.surface,
          fontSize: 14,
          height: 1.5,
          fontWeight: FontWeight.w600,
        ),
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
          child: Icon(
            Icons.favorite_rounded,
            color: AppColors.surface,
            size: 28,
          ),
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
        color: AppColors.surface,
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
          color: AppColors.surface.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(AppRadius.chip),
          border: Border.all(color: AppColors.surface.withValues(alpha: 0.24)),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: AppColors.surface,
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
            style: TextStyle(
              color: AppColors.surface.withValues(alpha: 0.7),
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(width: 10),
        const Text(
          AppConstants.appName,
          style: TextStyle(
            color: AppColors.surface,
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
