import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../models/fortune_model.dart';
import '../../models/user_profile.dart';
import '../../services/fortune/fortune_calculator.dart';
import '../../services/fortune/fortune_service.dart';
import '../../services/share/share_image_service.dart';
import 'widgets/ohaeng_radar_chart.dart';
import 'widgets/share_card.dart';

/// 내 사주 화면 — "내 사주 보기" 진입점.
///
/// 별자리/사주 오행은 [FortuneCalculator]로 기기에서 결정론적으로 계산하고,
/// 그 결과를 근거로 한 캐릭터 서사만 GPT(Cloud Function)에 요청한다.
class MyFortuneScreen extends StatefulWidget {
  final UserProfile profile;
  final FortuneService fortuneService;

  const MyFortuneScreen({
    super.key,
    required this.profile,
    required this.fortuneService,
  });

  @override
  State<MyFortuneScreen> createState() => _MyFortuneScreenState();
}

class _MyFortuneScreenState extends State<MyFortuneScreen> {
  late final ZodiacInfo _zodiac;
  late final SajuInfo _saju;
  late final Map<String, double> _balance;

  bool _loading = true;
  bool _sharing = false;
  String? _error;
  FortuneNarrative? _narrative;

  @override
  void initState() {
    super.initState();
    _zodiac = FortuneCalculator.getZodiacSign(widget.profile.birthDate);
    _saju = FortuneCalculator.getSaju(widget.profile.birthDate);
    _balance = FortuneCalculator.getOhaengBalance(widget.profile.birthDate);
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final narrative = await widget.fortuneService.getMyFortune(
        uid: widget.profile.uid,
        zodiac: _zodiac,
        saju: _saju,
      );
      if (mounted) setState(() => _narrative = narrative);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _shareFortuneResult() async {
    final narrative = _narrative;
    if (narrative == null || _sharing) return;

    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null
        ? Rect.zero
        : box.localToGlobal(Offset.zero) & box.size;

    setState(() => _sharing = true);
    try {
      await ShareImageService.sharePng(
        context: context,
        child: FortuneShareCard(
          profile: widget.profile,
          narrative: narrative,
          zodiac: _zodiac,
          saju: _saju,
          balance: _balance,
        ),
        fileName: 'fortune_${widget.profile.uid}.png',
        title: '나의 사주 결과',
        text: '나의 사주 캐릭터를 확인해보세요.',
        sharePositionOrigin: origin,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('공유 이미지 생성 실패: $e')));
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text(
          '내 사주',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: AppColors.background,
        elevation: 0,
      ),
      body: SafeArea(child: _buildBody()),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.error_outline_rounded,
                size: 48,
                color: AppColors.textSecondary,
              ),
              const SizedBox(height: 12),
              Text(
                '사주를 불러오지 못했어요\n$_error',
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.textSecondary),
              ),
              const SizedBox(height: 20),
              OutlinedButton(onPressed: _load, child: const Text('다시 시도')),
            ],
          ),
        ),
      );
    }

    final narrative = _narrative;
    if (narrative == null) return const SizedBox.shrink();

    return Stack(
      children: [
        ListView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
          children: [
            _AttributeRow(zodiac: _zodiac, saju: _saju),
            const SizedBox(height: 24),
            _CharacterCard(narrative: narrative),
            const SizedBox(height: 24),
            _OhaengSection(balance: _balance, saju: _saju),
            const SizedBox(height: 20),
            _ShareButton(
              label: '결과 공유하기',
              onPressed: _sharing ? null : _shareFortuneResult,
            ),
            const SizedBox(height: 24),
            if (narrative.reasons.isNotEmpty)
              _ReasonList(reasons: narrative.reasons),
          ],
        ),
        if (_sharing) const _ShareLoadingOverlay(),
      ],
    );
  }
}

class _ShareButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;

  const _ShareButton({required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: onPressed,
      icon: const Icon(Icons.ios_share_rounded),
      label: Text(label),
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.primary,
        foregroundColor: AppColors.surface,
        padding: const EdgeInsets.symmetric(vertical: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.button),
        ),
      ),
    );
  }
}

class _ShareLoadingOverlay extends StatelessWidget {
  const _ShareLoadingOverlay();

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: ColoredBox(
        color: AppColors.ink.withValues(alpha: 0.26),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(AppRadius.button),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 12),
                Text('공유 이미지 생성 중'),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 별자리/오행 속성을 시각화한 배지 두 개.
class _AttributeRow extends StatelessWidget {
  final ZodiacInfo zodiac;
  final SajuInfo saju;
  const _AttributeRow({required this.zodiac, required this.saju});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _AttributeBadge(
            label: '별자리',
            value: zodiac.sign,
            sub: '${zodiac.element} 원소',
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _AttributeBadge(
            label: '사주 일간',
            value: '${saju.dayMaster}(${saju.element})',
            sub: '오행 · ${saju.element}',
          ),
        ),
      ],
    );
  }
}

class _AttributeBadge extends StatelessWidget {
  final String label;
  final String value;
  final String sub;
  const _AttributeBadge({
    required this.label,
    required this.value,
    required this.sub,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.bold,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            sub,
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _CharacterCard extends StatelessWidget {
  final FortuneNarrative narrative;
  const _CharacterCard({required this.narrative});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.seal,
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            narrative.characterType,
            style: const TextStyle(
              fontFamily: AppFonts.display,
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: AppColors.surface,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            narrative.summary,
            style: const TextStyle(
              fontFamily: AppFonts.display,
              fontSize: 15,
              color: AppColors.surface,
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }
}

/// 오행 밸런스 레이더 차트 + 강함/부족 요약 + 보완 매칭 안내.
class _OhaengSection extends StatelessWidget {
  final Map<String, double> balance;
  final SajuInfo saju;
  const _OhaengSection({required this.balance, required this.saju});

  /// 오행 이름 뒤에 붙는 주격 조사(이/가). 다섯 글자뿐이라 표를 직접 둔다.
  static const _particle = {'목': '이', '화': '가', '토': '가', '금': '이', '수': '가'};

  @override
  Widget build(BuildContext context) {
    final strong = FortuneCalculator.strongestElement(balance);
    final weak = FortuneCalculator.weakestElement(balance);
    final nourishing = FortuneCalculator.nourishingElement(weak.key);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '오행 밸런스',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.bold,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 12),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(AppRadius.card),
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: OhaengRadarChart(balance: balance),
              ),
              const SizedBox(height: 12),
              _OhaengRatioRow(balance: balance),
              const SizedBox(height: 12),
              Text(
                '${strong.key}${_particle[strong.key]} 강하고 ${weak.key}${_particle[weak.key]} 부족해요',
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              _DayMasterNote(saju: saju),
              const SizedBox(height: 8),
              const Text(
                '일간은 나의 기본 성향, 오행 밸런스는 년·월·일 6글자의 전체 기운이에요. '
                '그래서 일간 원소와 가장 강한 원소가 다를 수 있어요.',
                style: TextStyle(
                  fontSize: 12,
                  height: 1.45,
                  color: AppColors.textSecondary,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              const Text(
                '출생 시각과 지장간은 반영하지 않은 간단 분석이에요.',
                style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: AppColors.secondary.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(AppRadius.button),
            border: Border.all(
              color: AppColors.secondary.withValues(alpha: 0.2),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.auto_awesome_rounded,
                size: 18,
                color: AppColors.secondary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '이런 사람과 잘 맞아요\n'
                  '$nourishing${_particle[nourishing]} 기운을 가진 상대가 당신의 부족한 부분을 채워줄 수 있어요.',
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.textPrimary,
                    height: 1.5,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _OhaengRatioRow extends StatelessWidget {
  final Map<String, double> balance;
  const _OhaengRatioRow({required this.balance});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final key in ohaengOrder)
          _OhaengRatioChip(
            element: key,
            percent: ((balance[key] ?? 0) * 100).round(),
          ),
      ],
    );
  }
}

class _OhaengRatioChip extends StatelessWidget {
  final String element;
  final int percent;

  const _OhaengRatioChip({required this.element, required this.percent});

  @override
  Widget build(BuildContext context) {
    final color = ohaengColors[element] ?? AppColors.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.chip),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Text(
        '$element $percent%',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}

class _DayMasterNote extends StatelessWidget {
  final SajuInfo saju;
  const _DayMasterNote({required this.saju});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: (ohaengColors[saju.element] ?? AppColors.primary).withValues(
          alpha: 0.1,
        ),
        borderRadius: BorderRadius.circular(AppRadius.chip),
        border: Border.all(
          color: (ohaengColors[saju.element] ?? AppColors.primary).withValues(
            alpha: 0.25,
          ),
        ),
      ),
      child: Text(
        '일간 ${saju.dayMaster}(${saju.element}) · 본질 원소',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: ohaengColors[saju.element] ?? AppColors.textPrimary,
        ),
      ),
    );
  }
}

class _ReasonList extends StatelessWidget {
  final List<FortuneReason> reasons;
  const _ReasonList({required this.reasons});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '이렇게 해석했어요',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.bold,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 10),
        ...reasons.map(
          (r) => Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(AppRadius.button),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.auto_awesome_rounded,
                  size: 18,
                  color: AppColors.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    r.text,
                    style: const TextStyle(
                      fontSize: 14,
                      color: AppColors.textPrimary,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
