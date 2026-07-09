import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/app_colors.dart';
import '../../../models/match_model.dart';

/// 매칭 성사 시 도장(印章)이 찍히는 전체화면 축하 오버레이.
class MatchCelebrationOverlay extends StatefulWidget {
  final MatchWithProfile match;
  final String currentUserPhotoUrl;
  final VoidCallback onKeepSwiping;
  final VoidCallback onChat;

  const MatchCelebrationOverlay({
    super.key,
    required this.match,
    required this.currentUserPhotoUrl,
    required this.onKeepSwiping,
    required this.onChat,
  });

  @override
  State<MatchCelebrationOverlay> createState() =>
      _MatchCelebrationOverlayState();
}

class _MatchCelebrationOverlayState extends State<MatchCelebrationOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _profileSlide;
  late final Animation<double> _stampDrop;
  late final Animation<double> _inkBloom;
  late final Animation<int> _score;
  late final int _targetScore;
  bool _didImpact = false;

  @override
  void initState() {
    super.initState();
    _targetScore = _scoreFor(widget.match.match.matchId);
    _controller = AnimationController(
      vsync: this,
      duration: AppDurations.emphasis,
    )..addListener(_handleImpact);
    _profileSlide = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0, 0.52, curve: AppCurves.standard),
    );
    _stampDrop = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.18, 0.82, curve: AppCurves.emphasized),
    );
    _inkBloom = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.56, 1, curve: AppCurves.standard),
    );
    _score = IntTween(begin: 0, end: _targetScore).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.62, 1, curve: AppCurves.standard),
      ),
    );
    _controller.forward();
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_handleImpact)
      ..dispose();
    super.dispose();
  }

  void _handleImpact() {
    if (_didImpact || _controller.value < 0.56) return;
    _didImpact = true;
    HapticFeedback.heavyImpact();
  }

  @override
  Widget build(BuildContext context) {
    final other = widget.match.otherProfile;
    final otherPhoto = other.photoUrls.isNotEmpty ? other.photoUrls[0] : null;

    return Material(
      color: AppColors.ink.withValues(alpha: 0),
      child: Container(
        color: AppColors.background,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Column(
              children: [
                const Spacer(),
                Text(
                  '${other.displayName}님과 인연이 닿았어요',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    height: 1.25,
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  '서로의 마음이 같은 곳에 찍혔어요.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 15,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 44),
                SizedBox(
                  height: 236,
                  child: AnimatedBuilder(
                    animation: _controller,
                    builder: (context, _) {
                      return Stack(
                        alignment: Alignment.center,
                        children: [
                          _SlidingPhoto(
                            progress: _profileSlide.value,
                            alignment: Alignment.centerLeft,
                            photoUrl: widget.currentUserPhotoUrl.isNotEmpty
                                ? widget.currentUserPhotoUrl
                                : null,
                          ),
                          _SlidingPhoto(
                            progress: _profileSlide.value,
                            alignment: Alignment.centerRight,
                            photoUrl: otherPhoto,
                          ),
                          CustomPaint(
                            size: const Size(210, 210),
                            painter: _InkBloomPainter(
                              progress: _inkBloom.value,
                              color: AppColors.seal,
                            ),
                          ),
                          _StampSeal(progress: _stampDrop.value),
                        ],
                      );
                    },
                  ),
                ),
                const SizedBox(height: 24),
                AnimatedBuilder(
                  animation: _score,
                  builder: (context, _) => _ScoreReadout(score: _score.value),
                ),
                const Spacer(),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: widget.onChat,
                    // 인장/궁합 연출(seal red)은 사주 콘텐츠라 유지하되,
                    // 매칭 액션 CTA는 시그니처 민트로.
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.mint,
                      foregroundColor: AppColors.onMint,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadius.button),
                      ),
                    ),
                    child: const Text(
                      '채팅 시작하기',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                TextButton(
                  onPressed: widget.onKeepSwiping,
                  child: const Text(
                    '계속 둘러보기',
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 15,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
              ],
            ),
          ),
        ),
      ),
    );
  }

  int _scoreFor(String matchId) {
    final hash = matchId.codeUnits.fold<int>(
      0,
      (value, unit) => (value + unit) % 29,
    );
    return 72 + hash;
  }
}

class _SlidingPhoto extends StatelessWidget {
  final double progress;
  final Alignment alignment;
  final String? photoUrl;

  const _SlidingPhoto({
    required this.progress,
    required this.alignment,
    required this.photoUrl,
  });

  @override
  Widget build(BuildContext context) {
    final direction = alignment == Alignment.centerLeft ? -1.0 : 1.0;
    return Align(
      alignment: alignment,
      child: Opacity(
        opacity: progress,
        child: Transform.translate(
          offset: Offset(direction * 68 * (1 - progress), 0),
          child: _PhotoCircle(photoUrl: photoUrl),
        ),
      ),
    );
  }
}

class _StampSeal extends StatelessWidget {
  final double progress;

  const _StampSeal({required this.progress});

  @override
  Widget build(BuildContext context) {
    final y = -96 * (1 - progress);
    final scale = _stampScale(progress);
    return Opacity(
      opacity: progress.clamp(0, 1),
      child: Transform.translate(
        offset: Offset(0, y),
        child: Transform.rotate(
          angle: -math.pi / 32,
          child: Transform.scale(
            scale: scale,
            child: Container(
              width: 116,
              height: 116,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.seal,
                border: Border.all(
                  color: AppColors.surface.withValues(alpha: 0.78),
                  width: 3,
                ),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.seal.withValues(alpha: 0.3),
                    blurRadius: 24,
                    offset: const Offset(0, 14),
                  ),
                ],
              ),
              child: Container(
                width: 92,
                height: 92,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: AppColors.surface.withValues(alpha: 0.72),
                    width: 2,
                  ),
                ),
                child: const Text(
                  '緣',
                  style: TextStyle(
                    fontFamily: AppFonts.display,
                    color: AppColors.surface,
                    fontSize: 54,
                    fontWeight: FontWeight.w700,
                    height: 1,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  double _stampScale(double value) {
    if (value <= 0) return 1.4;
    if (value < 0.62) {
      return 1.4 + (0.95 - 1.4) * (value / 0.62);
    }
    return 0.95 + (1.0 - 0.95) * ((value - 0.62) / 0.38).clamp(0, 1);
  }
}

class _InkBloomPainter extends CustomPainter {
  final double progress;
  final Color color;

  const _InkBloomPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;
    final center = size.center(Offset.zero);
    final maxRadius = size.shortestSide / 2;
    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = color.withValues(alpha: (1 - progress) * 0.28);
    canvas.drawCircle(center, maxRadius * progress, ringPaint);

    final washPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = color.withValues(alpha: (1 - progress) * 0.08);
    canvas.drawCircle(center, maxRadius * progress * 0.86, washPaint);
  }

  @override
  bool shouldRepaint(covariant _InkBloomPainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.color != color;
  }
}

class _ScoreReadout extends StatelessWidget {
  final int score;

  const _ScoreReadout({required this.score});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const Text(
          '궁합 점수',
          style: TextStyle(
            color: AppColors.textSecondary,
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '$score%',
          style: const TextStyle(
            fontFamily: AppFonts.display,
            color: AppColors.seal,
            fontSize: 42,
            fontWeight: FontWeight.w700,
            height: 1,
          ),
        ),
      ],
    );
  }
}

class _PhotoCircle extends StatelessWidget {
  final String? photoUrl;
  const _PhotoCircle({required this.photoUrl});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 112,
      height: 112,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: AppColors.surface, width: 4),
        color: AppColors.surface,
        image: photoUrl != null
            ? DecorationImage(image: NetworkImage(photoUrl!), fit: BoxFit.cover)
            : null,
        boxShadow: [
          BoxShadow(
            color: AppColors.ink.withValues(alpha: 0.14),
            blurRadius: 22,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: photoUrl == null
          ? const Icon(
              Icons.person_rounded,
              size: 52,
              color: AppColors.textSecondary,
            )
          : null,
    );
  }
}
