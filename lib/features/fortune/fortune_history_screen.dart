import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../models/fortune_model.dart';
import '../../models/user_profile.dart';
import '../../services/fortune/fortune_service.dart';

/// 최근 오늘의 운세 기록 화면.
///
/// users/{uid}/dailyFortune/{yyyy-MM-dd} 캐시를 최근 7일 타임라인으로 보여주고,
/// loveScore 흐름을 작은 그래프로 시각화한다.
class FortuneHistoryScreen extends StatefulWidget {
  final UserProfile profile;
  final FortuneService fortuneService;
  final int days;

  const FortuneHistoryScreen({
    super.key,
    required this.profile,
    required this.fortuneService,
    this.days = 7,
  });

  @override
  State<FortuneHistoryScreen> createState() => _FortuneHistoryScreenState();
}

class _FortuneHistoryScreenState extends State<FortuneHistoryScreen> {

  bool _loading = true;
  bool _backfilling = false;
  String? _error;
  List<FortuneHistoryEntry> _entries = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await widget.fortuneService.getFortuneHistory(
        uid: widget.profile.uid,
        days: widget.days,
      );
      if (mounted) setState(() => _entries = entries);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // 개발용, 출시 전 제거: 발표/데모에서 히스토리를 빠르게 채우기 위한 버튼.
  Future<void> _backfillRecentFortunes() async {
    if (_backfilling) return;
    setState(() => _backfilling = true);
    try {
      await widget.fortuneService.backfillRecentDailyFortunes(
        uid: widget.profile.uid,
        days: widget.days,
      );
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('최근 7일 운세를 채웠어요.')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('운세 채우기 실패: $e')));
    } finally {
      if (mounted) setState(() => _backfilling = false);
    }
  }

  void _showDetail(FortuneHistoryEntry entry) {
    final fortune = entry.fortune;
    if (fortune == null) return;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: AppColors.background,
      builder: (_) => _FortuneDetailSheet(entry: entry, fortune: fortune),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text(
          '운세 기록',
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
                '운세 기록을 불러오지 못했어요\n$_error',
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

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
        children: [
          _LoveTrendSection(entries: _entries),
          const SizedBox(height: 20),
          if (kDebugMode) ...[
            // 개발용, 출시 전 제거: 자연 축적 전 발표 데이터 생성용.
            SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton.icon(
                onPressed: _backfilling ? null : _backfillRecentFortunes,
                icon: _backfilling
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.auto_fix_high_rounded),
                label: const Text('최근 7일 운세 채우기'),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.mint,
                  foregroundColor: AppColors.onMint,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.button),
                  ),
                  textStyle: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),
          ],
          const _HistoryTitle(),
          const SizedBox(height: 10),
          ..._entries.map(
            (entry) =>
                _HistoryTile(entry: entry, onTap: () => _showDetail(entry)),
          ),
        ],
      ),
    );
  }
}

class _LoveTrendSection extends StatelessWidget {
  final List<FortuneHistoryEntry> entries;

  const _LoveTrendSection({required this.entries});

  @override
  Widget build(BuildContext context) {
    final filledCount = entries.where((entry) => entry.hasFortune).length;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '이번 주 애정운 흐름',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            filledCount < 2
                ? '$filledCount일 기록됨 · 비어있는 날은 앱을 열지 않은 날이에요 · 기록이 적으면 흐름이 단순하게 표시돼요'
                : '$filledCount일 기록됨 · 비어있는 날은 앱을 열지 않은 날이에요',
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(height: 150, child: _LoveScoreChart(entries: entries)),
        ],
      ),
    );
  }
}

class _LoveScoreChart extends StatefulWidget {
  final List<FortuneHistoryEntry> entries;

  const _LoveScoreChart({required this.entries});

  @override
  State<_LoveScoreChart> createState() => _LoveScoreChartState();
}

class _LoveScoreChartState extends State<_LoveScoreChart>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: AppDurations.emphasis,
    );
    _animation = CurvedAnimation(
      parent: _controller,
      curve: AppCurves.standard,
    );
    _controller.forward();
  }

  @override
  void didUpdateWidget(covariant _LoveScoreChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entries != widget.entries) {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (_, child) => CustomPaint(
        painter: _LoveScoreChartPainter(
          entries: widget.entries.reversed.toList(), // 왼쪽=오래된 날, 오른쪽=오늘
          progress: _animation.value,
        ),
        child: child,
      ),
      child: const SizedBox.expand(),
    );
  }
}

class _LoveScoreChartPainter extends CustomPainter {
  final List<FortuneHistoryEntry> entries;
  final double progress;

  _LoveScoreChartPainter({required this.entries, required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    if (entries.isEmpty) {
      _drawText(
        canvas,
        '기록이 쌓이면 흐름이 보여요',
        Offset(size.width / 2, size.height / 2),
        const TextStyle(fontSize: 12, color: AppColors.textSecondary),
      );
      return;
    }

    final chartLeft = 10.0;
    final chartRight = size.width - 10;
    final chartTop = 10.0;
    final chartBottom = size.height - 30;
    final chartWidth = chartRight - chartLeft;
    final chartHeight = chartBottom - chartTop;
    final revealRight = chartLeft + chartWidth * progress.clamp(0, 1);
    final scoreRange = _scoreRange();

    final gridPaint = Paint()
      ..color = AppColors.border.withValues(alpha: 0.55)
      ..strokeWidth = 1;
    final missingGuidePaint = Paint()
      ..color = AppColors.border.withValues(alpha: 0.5)
      ..strokeWidth = 1;

    for (var i = 1; i <= 5; i++) {
      final score =
          scoreRange.min + (scoreRange.max - scoreRange.min) * ((i - 1) / 4);
      final y = _scoreToY(
        score,
        chartTop,
        chartBottom,
        chartHeight,
        scoreRange,
      );
      canvas.drawLine(Offset(chartLeft, y), Offset(chartRight, y), gridPaint);
    }

    final points = <_ChartPoint>[];
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      final x = entries.length == 1
          ? size.width / 2
          : chartLeft + chartWidth * (i / (entries.length - 1));
      final actualScore = entry.fortune?.loveScore;
      final displayScore = _displayScoreForIndex(i);
      points.add(
        _ChartPoint(
          offset: Offset(
            x,
            _scoreToY(
              displayScore,
              chartTop,
              chartBottom,
              chartHeight,
              scoreRange,
            ),
          ),
          actualScore: actualScore,
        ),
      );

      _drawText(
        canvas,
        '${entry.date.month}/${entry.date.day}',
        Offset(x, chartBottom + 14),
        const TextStyle(fontSize: 10, color: AppColors.textSecondary),
      );

      if (actualScore == null) {
        canvas.drawLine(
          Offset(x, chartTop),
          Offset(x, chartBottom),
          missingGuidePaint,
        );
      }
    }

    if (points.isEmpty) return;

    final linePath = _smoothPath(points.map((point) => point.offset).toList());
    final areaPath = Path.from(linePath)
      ..lineTo(points.last.offset.dx, chartBottom)
      ..lineTo(points.first.offset.dx, chartBottom)
      ..close();

    canvas.save();
    canvas.clipRect(Rect.fromLTRB(chartLeft, 0, revealRight, size.height));

    final areaPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = AppColors.seal.withValues(alpha: 0.12);
    canvas.drawPath(areaPath, areaPaint);

    final glowPaint = Paint()
      ..color = AppColors.fortuneAccent.withValues(alpha: 0.16)
      ..strokeWidth = 10
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
    canvas.drawPath(linePath, glowPaint);

    final linePaint = Paint()
      ..color = AppColors.seal
      ..strokeWidth = 3.2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(linePath, linePaint);

    canvas.restore();

    for (final point in points) {
      if (point.offset.dx > revealRight + 2) continue;
      final isActual = point.actualScore != null;
      final outerPaint = Paint()
        ..color = isActual
            ? AppColors.fortuneAccent.withValues(alpha: 0.2)
            : AppColors.border.withValues(alpha: 0.45);
      final fillPaint = Paint()
        ..color = isActual ? AppColors.surface : AppColors.surface;
      final strokePaint = Paint()
        ..color = isActual ? AppColors.fortuneAccent : AppColors.textSecondary
        ..style = PaintingStyle.stroke
        ..strokeWidth = isActual ? 2.2 : 1.4;

      canvas.drawCircle(point.offset, isActual ? 8 : 5.5, outerPaint);
      canvas.drawCircle(point.offset, isActual ? 4.6 : 3.6, fillPaint);
      canvas.drawCircle(point.offset, isActual ? 4.6 : 3.6, strokePaint);
    }
  }

  double _displayScoreForIndex(int index) {
    final direct = entries[index].fortune?.loveScore;
    if (direct != null) return direct.toDouble();

    int? previousIndex;
    int? nextIndex;
    for (var i = index - 1; i >= 0; i--) {
      if (entries[i].fortune?.loveScore != null) {
        previousIndex = i;
        break;
      }
    }
    for (var i = index + 1; i < entries.length; i++) {
      if (entries[i].fortune?.loveScore != null) {
        nextIndex = i;
        break;
      }
    }

    final previousScore = previousIndex == null
        ? null
        : entries[previousIndex].fortune!.loveScore.toDouble();
    final nextScore = nextIndex == null
        ? null
        : entries[nextIndex].fortune!.loveScore.toDouble();

    if (previousScore != null && nextScore != null) {
      final t = (index - previousIndex!) / (nextIndex! - previousIndex);
      return previousScore + (nextScore - previousScore) * t;
    }
    if (previousScore != null) return previousScore;
    if (nextScore != null) return nextScore;
    return 3;
  }

  ({double min, double max}) _scoreRange() {
    final scores = entries
        .map((entry) => entry.fortune?.loveScore.toDouble())
        .whereType<double>()
        .toList();
    if (scores.length < 2) return (min: 1, max: 5);

    var minScore = scores.first;
    var maxScore = scores.first;
    for (final score in scores.skip(1)) {
      if (score < minScore) minScore = score;
      if (score > maxScore) maxScore = score;
    }

    if (minScore == maxScore) {
      return (
        min: (minScore - 1).clamp(1, 5).toDouble(),
        max: (maxScore + 1).clamp(1, 5).toDouble(),
      );
    }

    final padding = (maxScore - minScore) < 2 ? 0.35 : 0.15;
    return (
      min: (minScore - padding).clamp(1, 5).toDouble(),
      max: (maxScore + padding).clamp(1, 5).toDouble(),
    );
  }

  double _scoreToY(
    double score,
    double chartTop,
    double chartBottom,
    double chartHeight,
    ({double min, double max}) scoreRange,
  ) {
    final range = scoreRange.max - scoreRange.min;
    if (range <= 0) return chartBottom - chartHeight / 2;
    final normalized =
        ((score.clamp(scoreRange.min, scoreRange.max) - scoreRange.min) / range)
            .toDouble();
    return chartBottom - chartHeight * normalized;
  }

  Path _smoothPath(List<Offset> points) {
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    if (points.length == 1) return path;

    for (var i = 0; i < points.length - 1; i++) {
      final p0 = i == 0 ? points[i] : points[i - 1];
      final p1 = points[i];
      final p2 = points[i + 1];
      final p3 = i + 2 < points.length ? points[i + 2] : p2;
      final cp1 = p1 + (p2 - p0) / 6;
      final cp2 = p2 - (p3 - p1) / 6;
      path.cubicTo(cp1.dx, cp1.dy, cp2.dx, cp2.dy, p2.dx, p2.dy);
    }

    return path;
  }

  void _drawText(Canvas canvas, String text, Offset center, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      Offset(center.dx - painter.width / 2, center.dy - painter.height / 2),
    );
  }

  @override
  bool shouldRepaint(covariant _LoveScoreChartPainter oldDelegate) {
    return oldDelegate.entries != entries || oldDelegate.progress != progress;
  }
}

class _ChartPoint {
  final Offset offset;
  final int? actualScore;

  const _ChartPoint({required this.offset, required this.actualScore});
}

class _HistoryTitle extends StatelessWidget {
  const _HistoryTitle();

  @override
  Widget build(BuildContext context) {
    return const Text(
      '최근 기록',
      style: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.bold,
        color: AppColors.textPrimary,
      ),
    );
  }
}

class _HistoryTile extends StatelessWidget {
  final FortuneHistoryEntry entry;
  final VoidCallback onTap;

  const _HistoryTile({required this.entry, required this.onTap});

  static const _weekdays = ['월', '화', '수', '목', '금', '토', '일'];

  @override
  Widget build(BuildContext context) {
    final fortune = entry.fortune;
    final dateLabel =
        '${entry.date.month}월 ${entry.date.day}일 (${_weekdays[entry.date.weekday - 1]})';

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        onTap: fortune == null ? null : onTap,
        borderRadius: BorderRadius.circular(AppRadius.card),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(
              color: fortune == null
                  ? AppColors.border
                  : AppColors.fortuneAccent.withValues(alpha: 0.16),
            ),
          ),
          child: Row(
            children: [
              _DateBadge(date: entry.date),
              const SizedBox(width: 14),
              Expanded(
                child: fortune == null
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            dateLabel,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              color: AppColors.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 5),
                          const Text(
                            '기록 없음',
                            style: TextStyle(
                              fontSize: 13,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  dateLabel,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.textPrimary,
                                  ),
                                ),
                              ),
                              _HeartScore(score: fortune.loveScore),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            fortune.mood,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: AppColors.fortuneAccent,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            fortune.message,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13,
                              height: 1.4,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
              ),
              if (fortune != null)
                const Icon(
                  Icons.chevron_right_rounded,
                  color: AppColors.textSecondary,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DateBadge extends StatelessWidget {
  final DateTime date;

  const _DateBadge({required this.date});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 52,
      height: 58,
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(AppRadius.button),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            '${date.month}월',
            style: const TextStyle(
              fontSize: 11,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '${date.day}',
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w900,
              color: AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

class _HeartScore extends StatelessWidget {
  final int score;

  const _HeartScore({required this.score});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(
        5,
        (index) => Icon(
          index < score
              ? Icons.favorite_rounded
              : Icons.favorite_border_rounded,
          size: 13,
          color: AppColors.fortuneAccent,
        ),
      ),
    );
  }
}

class _FortuneDetailSheet extends StatelessWidget {
  final FortuneHistoryEntry entry;
  final DailyFortune fortune;

  const _FortuneDetailSheet({required this.entry, required this.fortune});

  static const _weekdays = ['월', '화', '수', '목', '금', '토', '일'];

  @override
  Widget build(BuildContext context) {
    final dateLabel =
        '${entry.date.month}월 ${entry.date.day}일 (${_weekdays[entry.date.weekday - 1]})';
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$dateLabel 애정운',
              style: const TextStyle(
                fontSize: 13,
                color: AppColors.textSecondary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    fortune.mood,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
                _HeartScore(score: fortune.loveScore),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              fortune.message,
              style: const TextStyle(
                fontSize: 15,
                height: 1.55,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.fortuneAccent.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(AppRadius.button),
              ),
              child: Text(
                ' ${fortune.advice}',
                style: const TextStyle(
                  fontSize: 14,
                  height: 1.45,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
