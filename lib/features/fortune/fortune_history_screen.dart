import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../models/fortune_model.dart';
import '../../shared/widgets/app_components.dart';
import 'fortune_hub_controller.dart';

/// 최근 오늘의 운세 **기록** 화면(미래 예보가 아니다).
///
/// users/{uid}/dailyFortune/{yyyy-MM-dd} 캐시를 오늘부터 과거 6일까지
/// 타임라인으로 보여주고, loveScore 흐름을 작은 그래프로 시각화한다.
///
/// 상태는 [FortuneHubController]가 소유한다 — 오늘의 운세 카드와 같은 KST
/// 날짜·계정 context를 공유해야 day 0이 어긋나지 않기 때문이다. 허브에서
/// 넘겨준 controller는 여기서 dispose하지 않는다.
class FortuneHistoryScreen extends StatefulWidget {
  final FortuneHubController controller;

  const FortuneHistoryScreen({super.key, required this.controller});

  @override
  State<FortuneHistoryScreen> createState() => _FortuneHistoryScreenState();
}

class _FortuneHistoryScreenState extends State<FortuneHistoryScreen>
    with WidgetsBindingObserver {
  FortuneHubController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onControllerChanged);
    WidgetsBinding.instance.addObserver(this);
    // 허브가 이미 같은 날짜로 읽어뒀으면 추가 요청은 나가지 않는다.
    _controller.refreshForCurrentContext();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // controller의 소유자는 허브 화면이다. 여기서는 구독만 해제한다.
    _controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) _controller.handleResume();
  }

  void _showDetail(FortuneHistoryEntry entry) {
    final fortune = entry.fortune;
    if (fortune == null) return;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: AppColors.surfacePrimary,
      // 긴 message/advice가 작은 기기에서 잘리지 않도록 높이를 열어준다.
      isScrollControlled: true,
      builder: (_) => _FortuneDetailSheet(entry: entry, fortune: fortune),
    );
  }

  double _horizontalPadding(BuildContext context) =>
      MediaQuery.sizeOf(context).width < 360
      ? AppSpacing.screenHCompact
      : AppSpacing.screenH;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.warmCanvas,
      appBar: AppBar(
        // 본문에 에디토리얼 제목이 따로 있으므로 AppBar는 짧은 화면명만 갖는다.
        title: const Text('운세 기록', style: AppTextStyles.cardTitle),
        backgroundColor: AppColors.warmCanvas,
        surfaceTintColor: AppColors.warmCanvas,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: SafeArea(child: _buildBody()),
    );
  }

  Widget _buildBody() {
    final horizontal = _horizontalPadding(context);

    switch (_controller.historyStatus) {
      case FortuneHistoryStatus.idle:
      case FortuneHistoryStatus.loading:
        return _HistoryLoadingState(
          key: const Key('fortune-history-loading'),
          horizontal: horizontal,
        );
      case FortuneHistoryStatus.error:
        return _HistoryErrorState(
          key: const Key('fortune-history-error'),
          horizontal: horizontal,
          onRetry: _controller.retryHistory,
        );
      case FortuneHistoryStatus.ready:
        break;
    }

    final entries = _controller.history;
    return RefreshIndicator(
      onRefresh: _controller.retryHistory,
      color: AppColors.brandPrimaryStrong,
      backgroundColor: AppColors.surfacePrimary,
      child: ListView(
        key: const Key('fortune-history-ready'),
        padding: EdgeInsets.fromLTRB(horizontal, AppSpacing.xs, horizontal, 40),
        children: [
          const _EditorialHeader(),
          const SizedBox(height: AppSpacing.lg20),
          _WeeklyFlowHero(entries: entries),
          const SizedBox(height: AppSpacing.xxl),
          const _HistoryTitle(),
          const SizedBox(height: AppSpacing.lg),
          for (var i = 0; i < entries.length; i++)
            _HistoryTimelineItem(
              key: Key('fortune-history-day-$i'),
              entry: entries[i],
              // controller가 주는 순서는 index 0이 오늘이다. 이 순서를 바꾸지
              // 않고, "오늘" 표시와 타임라인 선 끝처리에만 index를 쓴다.
              isToday: i == 0,
              isLast: i == entries.length - 1,
              onTap: () => _showDetail(entries[i]),
            ),
        ],
      ),
    );
  }
}

// ═══ A. Editorial header ═════════════════════════════════════════════════════

class _EditorialHeader extends StatelessWidget {
  const _EditorialHeader();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('지난 7일 연애운', style: AppTextStyles.screenTitle),
        SizedBox(height: AppSpacing.xs),
        Text('최근 일주일의 감정과 인연 흐름을 돌아보세요', style: AppTextStyles.bodySecondary),
      ],
    );
  }
}

// ═══ B. Weekly flow hero ═════════════════════════════════════════════════════

/// 그래프 + 실제 기록 기반 요약을 한 덩어리로 묶은 히어로.
///
/// 요약 문구는 전부 이미 로드된 [FortuneHistoryEntry] 필드에서만 뽑는다 —
/// 평균·확률·주간 총평처럼 원본 계약에 없는 해석을 만들지 않는다.
class _WeeklyFlowHero extends StatelessWidget {
  final List<FortuneHistoryEntry> entries;

  const _WeeklyFlowHero({required this.entries});

  /// 가장 최근에 기록이 남은 항목. controller 순서상 index 0이 오늘이므로
  /// 앞에서부터 처음 만나는 기록이 곧 "가장 최근"이다.
  FortuneHistoryEntry? get _latestRecorded {
    for (final entry in entries) {
      if (entry.hasFortune) return entry;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final recordedCount = entries.where((entry) => entry.hasFortune).length;
    final latest = _latestRecorded;
    final isEmpty = recordedCount == 0;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.lg20),
      decoration: BoxDecoration(
        // 화면 전체가 아니라 이 히어로 안에서만 아주 옅은 tonal gradient를 쓴다.
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.surfacePrimary, AppColors.surfaceMintSoft],
          stops: [0.55, 1],
        ),
        borderRadius: BorderRadius.circular(AppRadius.heroSoft),
        border: Border.all(color: AppColors.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Stack(
            children: [
              // ConnectionMotif는 이 화면에서 여기 한 번만 쓴다. 콘텐츠보다
              // 먼저 보이지 않도록 낮은 불투명도로 제목 오른쪽에 둔다.
              Positioned(
                top: -6,
                right: -4,
                width: 74,
                height: 40,
                child: IgnorePointer(
                  child: ConnectionMotif(strokeWidth: 1.3, opacity: 0.55),
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('최근 7일 애정운 흐름', style: AppTextStyles.label),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    isEmpty ? '아직 기록이 없어요' : '7일 중 $recordedCount일의 기록이 있어요',
                    style: AppTextStyles.caption,
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg20),
          SizedBox(
            height: 146,
            child: isEmpty
                ? _WeeklyFlowEmptyPreview(entries: entries)
                : _WeeklyFlowChart(entries: entries),
          ),
          if (latest != null) ...[
            const SizedBox(height: AppSpacing.lg),
            const Divider(height: 1, color: AppColors.borderSubtle),
            const SizedBox(height: AppSpacing.md),
            _WeeklySummaryRow(latest: latest.fortune!),
          ],
        ],
      ),
    );
  }
}

/// 그래프 아래 compact summary. 큰 통계 카드를 따로 만들지 않는다.
class _WeeklySummaryRow extends StatelessWidget {
  final DailyFortune latest;

  const _WeeklySummaryRow({required this.latest});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AppSpacing.md,
      runSpacing: AppSpacing.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          '가장 최근 애정운 ${latest.loveScore}점',
          style: AppTextStyles.caption.copyWith(
            color: AppColors.textBody,
            fontWeight: FontWeight.w700,
          ),
        ),
        Container(
          width: 3,
          height: 3,
          decoration: const BoxDecoration(
            color: AppColors.borderStrong,
            shape: BoxShape.circle,
          ),
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 200),
          child: Text(
            '최근 분위기 · ${latest.mood}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.caption,
          ),
        ),
      ],
    );
  }
}

/// 7일이 전부 비어 있을 때. 오류가 아니라 "아직 쌓이지 않았다"로 읽히도록
/// 그래프 프레임과 날짜 축은 그대로 두고 선·점만 그리지 않는다.
class _WeeklyFlowEmptyPreview extends StatelessWidget {
  final List<FortuneHistoryEntry> entries;

  const _WeeklyFlowEmptyPreview({required this.entries});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '최근 7일 애정운 기록이 아직 없습니다.',
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _WeeklyFlowPainter(
                entries: entries.reversed.toList(growable: false),
                progress: 1,
                drawSeries: false,
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: 28,
            child: Column(
              children: [
                SizedBox(
                  width: 92,
                  height: 34,
                  child: ConnectionMotif(strokeWidth: 1.4, opacity: 0.5),
                ),
                const SizedBox(height: AppSpacing.md),
                const Text(
                  '운세를 확인하면 이곳에 흐름이 기록돼요',
                  textAlign: TextAlign.center,
                  style: AppTextStyles.caption,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// loveScore 흐름 그래프.
///
/// 진입 시 좌→우로 한 번 그려지는 짧은 reveal만 유지한다. 반복 애니메이션,
/// pulse, glow 반복은 쓰지 않는다(Motion Phase로 미룬 항목).
class _WeeklyFlowChart extends StatefulWidget {
  final List<FortuneHistoryEntry> entries;

  const _WeeklyFlowChart({required this.entries});

  @override
  State<_WeeklyFlowChart> createState() => _WeeklyFlowChartState();
}

class _WeeklyFlowChartState extends State<_WeeklyFlowChart>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: AppMotion.content);
    _animation = CurvedAnimation(
      parent: _controller,
      curve: AppMotion.standard,
    );
    _controller.forward();
  }

  @override
  void didUpdateWidget(covariant _WeeklyFlowChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entries != widget.entries) _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final recorded = widget.entries.where((entry) => entry.hasFortune).toList();
    final latestScore = recorded.isEmpty
        ? null
        : recorded.first.fortune!.loveScore;

    return Semantics(
      // 그래프는 시각 정보라서 스크린리더에는 값을 말로 전달한다.
      label: latestScore == null
          ? '최근 7일 애정운 흐름 그래프. 기록 없음.'
          : '최근 7일 애정운 흐름 그래프. '
                '7일 중 ${recorded.length}일 기록됨. '
                '가장 최근 애정운 5점 중 $latestScore점.',
      excludeSemantics: true,
      child: AnimatedBuilder(
        animation: _animation,
        builder: (_, child) => CustomPaint(
          painter: _WeeklyFlowPainter(
            // 그리기용 복사본만 역순으로 쓴다 — 왼쪽이 오래된 날, 오른쪽이 오늘.
            // controller의 history 정렬과 목록 순서는 건드리지 않는다.
            entries: widget.entries.reversed.toList(growable: false),
            progress: _animation.value,
          ),
          child: child,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _WeeklyFlowPainter extends CustomPainter {
  /// 시간순(왼쪽=오래된 날, 오른쪽=오늘).
  final List<FortuneHistoryEntry> entries;
  final double progress;

  /// false면 축과 가이드만 그린다(빈 상태 프레임).
  final bool drawSeries;

  _WeeklyFlowPainter({
    required this.entries,
    required this.progress,
    this.drawSeries = true,
  });

  // 점수 축은 항상 1~5로 고정한다. 데이터 범위에 맞춰 확대하면 1점 차이가
  // 큰 등락처럼 보여서 점수 의미를 과장하게 된다.
  static const double _minScore = 1;
  static const double _maxScore = 5;
  static const List<String> _weekdays = ['월', '화', '수', '목', '금', '토', '일'];

  @override
  void paint(Canvas canvas, Size size) {
    if (entries.isEmpty || size.isEmpty) return;

    const axisHeight = 34.0;
    const sidePad = 10.0;
    final chartLeft = sidePad;
    final chartRight = size.width - sidePad;
    final chartTop = 6.0;
    final chartBottom = size.height - axisHeight;
    final chartWidth = chartRight - chartLeft;
    final chartHeight = chartBottom - chartTop;
    if (chartWidth <= 0 || chartHeight <= 0) return;

    final revealRight = chartLeft + chartWidth * progress.clamp(0.0, 1.0);

    double xFor(int index) => entries.length == 1
        ? chartLeft + chartWidth / 2
        : chartLeft + chartWidth * (index / (entries.length - 1));
    double yFor(num score) {
      final normalized =
          (score.toDouble().clamp(_minScore, _maxScore) - _minScore) /
          (_maxScore - _minScore);
      return chartBottom - chartHeight * normalized;
    }

    // ── 1 / 3 / 5 최소 guide만. 축선·눈금은 그리지 않는다. ────────────────
    final guidePaint = Paint()
      ..color = AppColors.borderSubtle
      ..strokeWidth = 1;
    for (final score in const [1, 3, 5]) {
      final y = yFor(score);
      canvas.drawLine(Offset(chartLeft, y), Offset(chartRight, y), guidePaint);
    }

    _paintAxis(canvas, xFor, chartBottom);

    if (!drawSeries) return;

    // ── 기록이 있는 날만 좌표로 만든다. 없는 날은 좌표 자체를 만들지 않아
    //    "0점"으로 오해될 여지를 없앤다. ────────────────────────────────────
    final points = <({int index, Offset offset})>[];
    for (var i = 0; i < entries.length; i++) {
      final score = entries[i].fortune?.loveScore;
      if (score == null) continue;
      points.add((index: i, offset: Offset(xFor(i), yFor(score))));
    }
    if (points.isEmpty) return;

    // 연속으로 기록된 구간(run)만 실선으로 잇는다.
    final runs = <List<Offset>>[];
    var current = <Offset>[points.first.offset];
    for (var i = 1; i < points.length; i++) {
      if (points[i].index == points[i - 1].index + 1) {
        current.add(points[i].offset);
      } else {
        runs.add(current);
        current = [points[i].offset];
      }
    }
    runs.add(current);

    canvas.save();
    canvas.clipRect(Rect.fromLTRB(0, 0, revealRight + 0.5, size.height));

    // 빠진 날을 사이에 둔 구간은 실선으로 잇지 않고 옅은 점선으로만 연결한다.
    // "그 날에도 값이 있었다"로 보이지 않게 하기 위한 규칙이다.
    for (var i = 1; i < runs.length; i++) {
      _drawDashedLine(canvas, runs[i - 1].last, runs[i].first);
    }

    for (final run in runs) {
      if (run.length < 2) continue;
      final linePath = _smoothPath(run);

      final areaPath = Path.from(linePath)
        ..lineTo(run.last.dx, chartBottom)
        ..lineTo(run.first.dx, chartBottom)
        ..close();
      canvas.drawPath(
        areaPath,
        Paint()
          ..shader =
              const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0x2916A874), Color(0x0016A874)],
              ).createShader(
                Rect.fromLTRB(chartLeft, chartTop, chartRight, chartBottom),
              ),
      );

      canvas.drawPath(
        linePath,
        Paint()
          ..color = AppColors.brandPrimary
          ..strokeWidth = 2.6
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }
    canvas.restore();

    // ── 포인트. 가장 최근 기록만 코랄 accent로 구분한다. ──────────────────
    final latestOffset = points.last.offset;
    for (final point in points) {
      if (point.offset.dx > revealRight + 1) continue;
      final isLatest = point.offset == latestOffset;
      final accent = isLatest
          ? AppColors.expressiveAccent
          : AppColors.brandPrimary;

      if (isLatest) {
        canvas.drawCircle(
          point.offset,
          8.5,
          Paint()..color = accent.withValues(alpha: 0.18),
        );
      }
      canvas.drawCircle(
        point.offset,
        isLatest ? 5 : 3.6,
        Paint()..color = AppColors.surfacePrimary,
      );
      canvas.drawCircle(
        point.offset,
        isLatest ? 5 : 3.6,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = isLatest ? 2.6 : 2
          ..color = accent,
      );
    }
  }

  /// 요일 + 일자 2줄 축. 월/연 경계를 넘어도 숫자로 구분된다.
  void _paintAxis(
    Canvas canvas,
    double Function(int) xFor,
    double chartBottom,
  ) {
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      final isLatestDay = i == entries.length - 1;
      final recorded = entry.hasFortune;
      final color = isLatestDay
          ? AppColors.brandPrimaryStrong
          : (recorded ? AppColors.textBody : AppColors.textMuted);

      _drawText(
        canvas,
        isLatestDay ? '오늘' : _weekdays[entry.date.weekday - 1],
        Offset(xFor(i), chartBottom + 13),
        TextStyle(
          fontFamily: AppFonts.body,
          fontSize: 11,
          height: 1,
          fontWeight: isLatestDay ? FontWeight.w800 : FontWeight.w600,
          color: color,
        ),
      );
      _drawText(
        canvas,
        '${entry.date.day}',
        Offset(xFor(i), chartBottom + 27),
        TextStyle(
          fontFamily: AppFonts.body,
          fontSize: 10,
          height: 1,
          fontWeight: FontWeight.w500,
          color: recorded ? AppColors.textMuted : AppColors.borderStrong,
        ),
      );
    }
  }

  void _drawDashedLine(Canvas canvas, Offset from, Offset to) {
    const dash = 3.0;
    const gap = 4.0;
    final paint = Paint()
      ..color = AppColors.brandPrimary.withValues(alpha: 0.28)
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;

    final delta = to - from;
    final distance = delta.distance;
    if (distance <= 0) return;
    final step = delta / distance;

    var travelled = 0.0;
    while (travelled < distance) {
      final end = math.min(travelled + dash, distance);
      canvas.drawLine(from + step * travelled, from + step * end, paint);
      travelled = end + gap;
    }
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
  bool shouldRepaint(covariant _WeeklyFlowPainter old) =>
      old.entries != entries ||
      old.progress != progress ||
      old.drawSeries != drawSeries;
}

// ═══ C. 기록 타임라인 ════════════════════════════════════════════════════════

class _HistoryTitle extends StatelessWidget {
  const _HistoryTitle();

  @override
  Widget build(BuildContext context) {
    return const Text('지난 7일 기록', style: AppTextStyles.sectionTitle);
  }
}

/// 날짜별 기록 한 줄.
///
/// 흰색 카드 7개를 반복하지 않는다. 왼쪽 날짜 열 → 가는 타임라인 선 → 오른쪽
/// 콘텐츠 구조로, 기록이 있는 날은 캔버스 위에 바로 읽히게 둔다. 오늘만 옅은
/// 브랜드 서피스로 감싸 구분한다(코랄 전체 배경은 쓰지 않는다).
class _HistoryTimelineItem extends StatelessWidget {
  final FortuneHistoryEntry entry;
  final bool isToday;
  final bool isLast;
  final VoidCallback onTap;

  const _HistoryTimelineItem({
    super.key,
    required this.entry,
    required this.isToday,
    required this.isLast,
    required this.onTap,
  });

  static const _weekdays = ['월', '화', '수', '목', '금', '토', '일'];

  @override
  Widget build(BuildContext context) {
    final fortune = entry.fortune;
    final weekday = _weekdays[entry.date.weekday - 1];

    final content = fortune == null
        ? const _EmptyDayContent()
        : _RecordedDayContent(fortune: fortune, isToday: isToday);

    // 타임라인 선이 항목 높이만큼 이어져야 하므로 Row에 유한한 높이를 준다.
    // (ListView 안에서는 세로가 unbounded라 Expanded 선이 성립하지 않는다.)
    final row = IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 40,
            child: Padding(
              padding: const EdgeInsets.only(top: AppSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    weekday,
                    style: AppTextStyles.caption.copyWith(
                      fontWeight: FontWeight.w700,
                      color: fortune == null
                          ? AppColors.textMuted
                          : AppColors.textBody,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${entry.date.day}',
                    style: TextStyle(
                      fontFamily: AppFonts.body,
                      fontSize: 17,
                      height: 1.1,
                      fontWeight: FontWeight.w800,
                      color: fortune == null
                          ? AppColors.textMuted
                          : AppColors.textStrong,
                    ),
                  ),
                ],
              ),
            ),
          ),
          _TimelineGutter(
            isToday: isToday,
            isLast: isLast,
            recorded: fortune != null,
          ),
          Expanded(child: content),
        ],
      ),
    );

    // 기록이 없는 날은 기존 계약대로 탭할 수 없다(상세를 열 데이터가 없다).
    if (fortune == null) {
      return Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.xs),
        child: row,
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: AppPressable(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.surface),
        child: row,
      ),
    );
  }
}

/// 날짜 사이를 잇는 가는 흐름선 + 점.
///
/// ConnectionMotif의 "두 점 + 곡선"을 7번 반복하지 않고, 얇은 직선과 작은
/// 점으로만 변형해 쓴다. 오늘 점만 코랄 accent를 갖는다.
class _TimelineGutter extends StatelessWidget {
  final bool isToday;
  final bool isLast;
  final bool recorded;

  const _TimelineGutter({
    required this.isToday,
    required this.isLast,
    required this.recorded,
  });

  @override
  Widget build(BuildContext context) {
    final dotColor = isToday
        ? AppColors.expressiveAccent
        : (recorded ? AppColors.brandPrimary : AppColors.borderStrong);

    return SizedBox(
      width: 26,
      child: Column(
        children: [
          const SizedBox(height: AppSpacing.lg),
          Container(
            width: isToday ? 11 : 8,
            height: isToday ? 11 : 8,
            decoration: BoxDecoration(
              color: recorded ? dotColor : AppColors.surfacePrimary,
              shape: BoxShape.circle,
              border: Border.all(color: dotColor, width: recorded ? 0 : 1.4),
            ),
          ),
          if (!isLast)
            Expanded(
              child: Container(width: 1.4, color: AppColors.borderSubtle),
            ),
        ],
      ),
    );
  }
}

class _RecordedDayContent extends StatelessWidget {
  final DailyFortune fortune;
  final bool isToday;

  const _RecordedDayContent({required this.fortune, required this.isToday});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(left: AppSpacing.xs, bottom: AppSpacing.md),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.lg,
      ),
      decoration: BoxDecoration(
        color: isToday ? AppColors.surfaceMintSoft : AppColors.surfacePrimary,
        borderRadius: BorderRadius.circular(AppRadius.surface),
        border: Border.all(
          color: isToday
              ? AppColors.brandPrimary.withValues(alpha: 0.28)
              : AppColors.borderSubtle,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (isToday) ...[const _TodayPill(), const SizedBox(width: 8)],
              Expanded(
                child: Text(
                  fortune.mood,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.cardTitle.copyWith(fontSize: 15),
                ),
              ),
              const Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: AppColors.textMuted,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            fortune.message,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.bodySecondary.copyWith(fontSize: 13),
          ),
          const SizedBox(height: AppSpacing.md),
          _ScoreMeter(score: fortune.loveScore, compact: true),
        ],
      ),
    );
  }
}

class _TodayPill extends StatelessWidget {
  const _TodayPill();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.brandPrimaryStrong,
        borderRadius: BorderRadius.circular(AppRadius.chip),
      ),
      child: const Text(
        '오늘',
        style: TextStyle(
          fontFamily: AppFonts.body,
          fontSize: 11,
          height: 1.2,
          fontWeight: FontWeight.w800,
          color: AppColors.onBrandPrimary,
        ),
      ),
    );
  }
}

/// 기록이 없는 날. 오류가 아니라 "이 날은 앱을 열지 않았다"로 읽히게 한다.
/// 카드 전체를 흐리게 만들지 않고, 높이만 낮춰 흐름에서 물러나게 한다.
class _EmptyDayContent extends StatelessWidget {
  const _EmptyDayContent();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(
        left: AppSpacing.lg,
        top: AppSpacing.md,
        bottom: AppSpacing.xl,
      ),
      child: Text('기록 없음', style: AppTextStyles.caption),
    );
  }
}

/// FortuneHub의 애정운 meter와 같은 문법(세그먼트 5칸 + 숫자 텍스트).
///
/// 허브 쪽 구현은 private이고 이번 Phase에서 허브 파일을 수정하지 않으므로
/// 여기서는 같은 문법을 복제한다. 두 화면의 meter를 공통 컴포넌트로 합치는
/// 것은 사주 영역 1차 리디자인이 끝난 뒤 정리할 후속 과제다.
class _ScoreMeter extends StatelessWidget {
  final int score;
  final bool compact;

  const _ScoreMeter({required this.score, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final height = compact ? 5.0 : 8.0;
    return Row(
      children: [
        Expanded(
          child: Row(
            children: [
              for (var i = 0; i < 5; i++) ...[
                if (i > 0) const SizedBox(width: 5),
                Expanded(
                  child: Container(
                    height: height,
                    decoration: BoxDecoration(
                      color: i < score
                          ? AppColors.brandPrimary
                          : AppColors.canvasSubtle,
                      borderRadius: BorderRadius.circular(AppRadius.chip),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        // 색상만으로 값을 전달하지 않는다. %가 아니라 원래 1~5 척도를 유지한다.
        Text(
          '$score점',
          style: AppTextStyles.caption.copyWith(
            color: AppColors.textBody,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

// ═══ 상태 화면 ═══════════════════════════════════════════════════════════════

/// FortuneHub loading과 같은 문법. 화면 골격을 유지해서 로딩 후 레이아웃이
/// 튀지 않게 하고, 이전 계정·이전 날짜 기록은 절대 다시 그리지 않는다.
class _HistoryLoadingState extends StatelessWidget {
  final double horizontal;

  const _HistoryLoadingState({super.key, required this.horizontal});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.fromLTRB(
        horizontal,
        AppSpacing.xs,
        horizontal,
        AppSpacing.xxl,
      ),
      physics: const NeverScrollableScrollPhysics(),
      children: [
        const _SkeletonBar(width: 168, height: 24),
        const SizedBox(height: AppSpacing.md),
        const _SkeletonBar(width: 232, height: 13),
        const SizedBox(height: AppSpacing.lg20),
        Container(
          padding: const EdgeInsets.all(AppSpacing.lg20),
          decoration: BoxDecoration(
            color: AppColors.surfacePrimary,
            borderRadius: BorderRadius.circular(AppRadius.heroSoft),
            border: Border.all(color: AppColors.borderSubtle),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const _SkeletonBar(width: 128, height: 13),
                  const Spacer(),
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.brandPrimary.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.lg20),
              const _SkeletonBar(height: 118, radius: AppRadius.small),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.xxl),
        const _SkeletonBar(width: 104, height: 18),
        const SizedBox(height: AppSpacing.lg),
        for (var i = 0; i < 3; i++) ...[
          const _TimelineSkeletonRow(),
          const SizedBox(height: AppSpacing.md),
        ],
      ],
    );
  }
}

class _TimelineSkeletonRow extends StatelessWidget {
  const _TimelineSkeletonRow();

  @override
  Widget build(BuildContext context) {
    return const Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 40,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _SkeletonBar(width: 18, height: 11),
              SizedBox(height: 5),
              _SkeletonBar(width: 22, height: 15),
            ],
          ),
        ),
        SizedBox(
          width: 26,
          child: Center(child: _SkeletonBar(width: 9, height: 9)),
        ),
        Expanded(child: _SkeletonBar(height: 76, radius: AppRadius.surface)),
      ],
    );
  }
}

class _SkeletonBar extends StatelessWidget {
  final double? width;
  final double height;
  final double radius;

  const _SkeletonBar({
    this.width,
    required this.height,
    this.radius = AppRadius.chip,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: AppColors.canvasSubtle,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

/// 화면 구조를 유지한 채 정돈된 오류 서피스를 보여준다. danger는 작은 아이콘
/// 배지에만 쓰고, 오류 원인을 임의로 다시 분류하지 않는다.
class _HistoryErrorState extends StatelessWidget {
  final double horizontal;
  final VoidCallback onRetry;

  const _HistoryErrorState({
    super.key,
    required this.horizontal,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.fromLTRB(
        horizontal,
        AppSpacing.xs,
        horizontal,
        AppSpacing.xxl,
      ),
      children: [
        const _EditorialHeader(),
        const SizedBox(height: AppSpacing.lg20),
        AppSurfaceCard(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: AppColors.statusDangerSoft,
                    borderRadius: BorderRadius.circular(AppRadius.small),
                  ),
                  child: const Icon(
                    Icons.error_outline_rounded,
                    size: 24,
                    color: AppColors.statusDanger,
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              const Text(
                '최근 운세 기록을 불러오지 못했어요.',
                textAlign: TextAlign.center,
                style: AppTextStyles.bodySecondary,
              ),
              const SizedBox(height: AppSpacing.lg20),
              AppBrandButton(
                key: const Key('fortune-history-retry'),
                label: '다시 시도',
                icon: Icons.refresh_rounded,
                onPressed: onRetry,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ═══ 기록 상세 ═══════════════════════════════════════════════════════════════

/// 기록 상세 바텀시트. navigation 형태(showModalBottomSheet)는 그대로 두고
/// 내부 구성만 다시 짠다. ConnectionMotif는 여기서 쓰지 않는다 — 히어로에서
/// 이미 한 번 썼기 때문에 반복하면 장식 과잉이 된다.
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
      child: ConstrainedBox(
        // 내용이 길어도 화면을 넘지 않고, 짧으면 그만큼만 차지한다.
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.82,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.screenH,
            AppSpacing.xs,
            AppSpacing.screenH,
            AppSpacing.xl,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('$dateLabel 애정운', style: AppTextStyles.label),
              const SizedBox(height: AppSpacing.sm),
              Text(
                fortune.mood,
                style: AppTextStyles.insight.copyWith(fontSize: 24),
              ),
              const SizedBox(height: AppSpacing.lg20),
              _ScoreMeter(score: fortune.loveScore),
              const SizedBox(height: AppSpacing.lg20),
              Text(fortune.message, style: AppTextStyles.body),
              const SizedBox(height: AppSpacing.lg20),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.lg,
                  vertical: AppSpacing.lg,
                ),
                decoration: BoxDecoration(
                  color: AppColors.surfaceMintSoft,
                  borderRadius: BorderRadius.circular(AppRadius.small),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.tips_and_updates_rounded,
                      size: 18,
                      color: AppColors.brandPrimaryStrong,
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Text(
                        fortune.advice,
                        style: AppTextStyles.bodySecondary.copyWith(
                          color: AppColors.textStrong,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
