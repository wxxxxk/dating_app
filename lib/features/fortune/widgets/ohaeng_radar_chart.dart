import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../services/fortune/fortune_calculator.dart';

/// 오행 각 축의 전통 색상. 가독성을 위해 일부 조정했다
/// (금=흰색 → 회색, 수=검정 → 남색 — 흰/검정은 밝은 배경에서 대비가 부족하다).
const Map<String, Color> ohaengColors = {
  '목': AppColors.wood,
  '화': AppColors.fire,
  '토': AppColors.earth,
  '금': AppColors.metal,
  '수': AppColors.water,
};

/// 오행 밸런스를 오각형(펜타곤) 레이더 차트로 그리는 위젯.
///
/// 막대그래프가 아니라 5개 축(목·화·토·금·수)을 오각형으로 배치하고,
/// 각 축의 강도를 반지름으로 표현한 폴리곤을 채워 그린다. 6글자 기반 원본
/// 비율은 보통 0.3~0.5가 최대라 그대로 그리면 중앙에 뭉쳐 보인다. 그래서
/// 차트 안에서는 유저 자신의 최댓값을 1.0으로 맞춘 상대 스케일을 사용하고,
/// 강함/부족 판정은 호출부의 원본 [balance] 기준을 그대로 유지한다.
/// 진입 시 폴리곤이 중심(0)에서 실제 값까지 한 번 펼쳐지는 애니메이션을 재생한다.
class OhaengRadarChart extends StatefulWidget {
  final Map<String, double> balance; // key: ohaengOrder의 원소, value: 0~1

  const OhaengRadarChart({super.key, required this.balance});

  @override
  State<OhaengRadarChart> createState() => _OhaengRadarChartState();
}

class _OhaengRadarChartState extends State<OhaengRadarChart>
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
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1,
      child: AnimatedBuilder(
        animation: _animation,
        builder: (context, _) => CustomPaint(
          // 부모(AspectRatio)가 준 크기를 그대로 채운다. child가 없을 때
          // CustomPaint에 Size.infinite를 주면 부모가 허용하는 최대 크기를 쓴다.
          size: Size.infinite,
          painter: _OhaengRadarPainter(
            balance: widget.balance,
            progress: _animation.value,
          ),
        ),
      ),
    );
  }
}

class _OhaengRadarPainter extends CustomPainter {
  final Map<String, double> balance;
  final double progress; // 0(중심)~1(실제 값) 애니메이션 진행도

  _OhaengRadarPainter({required this.balance, required this.progress});

  static const _gridFractions = [0.25, 0.5, 0.75, 1.0];
  static const _visualFloor = 0.07;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    // 라벨이 그려질 여백만큼 반지름을 줄인다.
    final maxRadius = math.min(size.width, size.height) / 2 - 26;
    if (maxRadius <= 0) return;

    // 5개 축 각도: 위쪽(12시 방향, -90°)부터 시계방향으로 72°씩.
    final angles = List.generate(
      ohaengOrder.length,
      (i) => -math.pi / 2 + i * (2 * math.pi / ohaengOrder.length),
    );

    _drawGrid(canvas, center, maxRadius, angles);
    _drawLabels(canvas, center, maxRadius, angles);
    _drawDataPolygon(canvas, center, maxRadius, angles);
  }

  void _drawGrid(
    Canvas canvas,
    Offset center,
    double maxRadius,
    List<double> angles,
  ) {
    final gridPaint = Paint()
      ..color = AppColors.border
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    // 동심 오각형 격자 (0.25/0.5/0.75/1.0 단계).
    for (final fraction in _gridFractions) {
      final path = Path();
      for (var i = 0; i < angles.length; i++) {
        final p = _pointOnAxis(center, angles[i], maxRadius * fraction);
        if (i == 0) {
          path.moveTo(p.dx, p.dy);
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      path.close();
      canvas.drawPath(path, gridPaint);
    }

    // 중심 → 각 축 끝으로 뻗는 방사선.
    for (final angle in angles) {
      canvas.drawLine(
        center,
        _pointOnAxis(center, angle, maxRadius),
        gridPaint,
      );
    }
  }

  void _drawLabels(
    Canvas canvas,
    Offset center,
    double maxRadius,
    List<double> angles,
  ) {
    for (var i = 0; i < ohaengOrder.length; i++) {
      final key = ohaengOrder[i];
      final labelPos = _pointOnAxis(center, angles[i], maxRadius + 18);
      final color = ohaengColors[key] ?? AppColors.textPrimary;

      final textPainter = TextPainter(
        text: TextSpan(
          text: key,
          style: TextStyle(
            color: color,
            fontWeight: FontWeight.bold,
            fontSize: 14,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      textPainter.paint(
        canvas,
        Offset(
          labelPos.dx - textPainter.width / 2,
          labelPos.dy - textPainter.height / 2,
        ),
      );
    }
  }

  void _drawDataPolygon(
    Canvas canvas,
    Offset center,
    double maxRadius,
    List<double> angles,
  ) {
    final displayBalance = _displayBalance(balance);
    final points = <Offset>[
      for (var i = 0; i < ohaengOrder.length; i++)
        _pointOnAxis(
          center,
          angles[i],
          maxRadius *
              (displayBalance[ohaengOrder[i]] ?? 0).clamp(0.0, 1.0) *
              _axisProgress(i),
        ),
    ];

    final path = Path()..addPolygon(points, true);

    final fillPaint = Paint()
      ..color = AppColors.seal.withValues(alpha: 0.18)
      ..style = PaintingStyle.fill;
    canvas.drawPath(path, fillPaint);

    // 은은한 글로우(흐린 외곽선).
    final glowPaint = Paint()
      ..color = AppColors.fortuneAccent.withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
    canvas.drawPath(path, glowPaint);

    // 선명한 외곽선.
    final strokePaint = Paint()
      ..color = AppColors.fortuneAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawPath(path, strokePaint);

    // 꼭짓점 강조 점. 실제 0%인 축은 시각 바닥값으로만 표시하고 회색 처리한다.
    for (var i = 0; i < points.length; i++) {
      final key = ohaengOrder[i];
      final actualValue = (balance[key] ?? 0).clamp(0.0, 1.0);
      final isZero = actualValue <= 0;
      final pointColor = isZero
          ? AppColors.textSecondary.withValues(alpha: 0.45)
          : ohaengColors[key] ?? AppColors.fortuneAccent;
      canvas.drawCircle(points[i], 4.5, Paint()..color = pointColor);
      canvas.drawCircle(
        points[i],
        4.5,
        Paint()
          ..color = AppColors.surface
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
  }

  Offset _pointOnAxis(Offset center, double angle, double radius) {
    return Offset(
      center.dx + radius * math.cos(angle),
      center.dy + radius * math.sin(angle),
    );
  }

  /// 시각화 전용 스케일.
  ///
  /// 원본 비율의 최댓값을 1.0으로 맞춰 폴리곤이 충분히 펼쳐지게 한다.
  /// 0% 축도 중심점까지 완전히 붕괴하지 않도록 표시 전용 바닥값을 둔다.
  /// 하단 퍼센트 라벨과 강함/부족 판정은 원본 [balance]를 그대로 사용한다.
  Map<String, double> _displayBalance(Map<String, double> source) {
    final values = [
      for (final key in ohaengOrder) (source[key] ?? 0).clamp(0.0, 1.0),
    ];
    final maxValue = values.fold<double>(0, math.max);
    return {
      for (final key in ohaengOrder) key: _displayValue(source[key], maxValue),
    };
  }

  double _displayValue(double? value, double maxValue) {
    if (maxValue <= 0) return _visualFloor;
    final normalized = (value ?? 0).clamp(0.0, 1.0) / maxValue;
    return math.max(_visualFloor, normalized);
  }

  double _axisProgress(int index) {
    final shifted = progress - index * 0.1;
    return (shifted / 0.6).clamp(0.0, 1.0);
  }

  @override
  bool shouldRepaint(covariant _OhaengRadarPainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.balance != balance;
  }
}
