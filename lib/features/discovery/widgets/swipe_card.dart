import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';

/// 드래그 스와이프 카드 위젯.
///
/// 사용법:
/// - [profileUid]를 반드시 현재 프로필의 uid로 넘길 것.
///   didUpdateWidget에서 uid가 바뀌면 애니메이션 상태를 완전 초기화한다.
///   이 초기화가 없으면, 이전 카드의 fly-off 위치(_offset)가 남아
///   새 카드가 화면 밖에 렌더되는 잔상/깜빡임이 발생한다.
/// - [onSwiped]는 애니메이션이 끝난 뒤 'like', 'pass', 'superlike'를 받아 호출된다.
/// - 외부에서 프로그래밍 방식으로 스와이프하려면 `GlobalKey<SwipeCardState>`로 접근해
///   [triggerSwipe]를 호출한다.
class SwipeCard extends StatefulWidget {
  final String profileUid;
  final Widget child;
  final void Function(String action) onSwiped;
  final String? rewindEntryAction;
  final int rewindEntryToken;

  const SwipeCard({
    super.key,
    required this.profileUid,
    required this.child,
    required this.onSwiped,
    this.rewindEntryAction,
    this.rewindEntryToken = 0,
  });

  @override
  State<SwipeCard> createState() => SwipeCardState();
}

class SwipeCardState extends State<SwipeCard>
    with SingleTickerProviderStateMixin {
  Offset _offset = Offset.zero;
  late AnimationController _controller;

  // 진행 중인 위치 애니메이션. 드래그 중엔 null.
  Animation<Offset>? _anim;

  // 스와이프 애니메이션 완료 후 onSwiped에 전달할 액션 ('like' | 'pass' | 'superlike').
  // 스냅백 중엔 null.
  String? _pendingAction;
  String? _activeMotionAction;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: AppDurations.base)
      ..addListener(_onTick)
      ..addStatusListener(_onStatus);
  }

  @override
  void didUpdateWidget(SwipeCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // profileUid가 달라지면 새 카드가 들어온 것 — 이전 fly-off 위치를 초기화한다.
    // 초기화하지 않으면 이전 카드의 _offset(off-screen)이 남아
    // 새 카드가 화면 밖에 렌더되는 잔상이 생긴다.
    if (oldWidget.profileUid != widget.profileUid) {
      _offset = Offset.zero;
      _anim = null;
      _pendingAction = null;
      _activeMotionAction = null;
      _controller.reset(); // 0으로 리셋 → _onTick은 _anim이 null이라 no-op
    }
    if (oldWidget.rewindEntryToken != widget.rewindEntryToken &&
        widget.rewindEntryAction != null) {
      _startRewindEntry(widget.rewindEntryAction!);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onTick() {
    final a = _anim;
    if (a != null) setState(() => _offset = a.value);
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      final action = _pendingAction;
      if (action != null) {
        _pendingAction = null;
        _activeMotionAction = null;
        widget.onSwiped(action);
      }
    }
  }

  // ── 드래그 핸들러 ──────────────────────────────────────────────────────────

  void _onPanUpdate(DragUpdateDetails d) {
    _controller.stop();
    _anim = null;
    setState(() => _offset += Offset(d.delta.dx, d.delta.dy));
  }

  void _onPanEnd(DragEndDetails _) {
    final sw = MediaQuery.sizeOf(context).width;
    final sh = MediaQuery.sizeOf(context).height;
    if (_offset.dy < -sh * 0.18) {
      triggerSwipe('superlike');
    } else if (_offset.dx.abs() > sw * 0.35) {
      triggerSwipe(_offset.dx > 0 ? 'like' : 'pass');
    } else {
      _snapBack();
    }
  }

  // ── 애니메이션 ─────────────────────────────────────────────────────────────

  void _snapBack() {
    _pendingAction = null;
    _activeMotionAction = null;
    _anim = Tween<Offset>(begin: _offset, end: Offset.zero).animate(
      CurvedAnimation(parent: _controller, curve: AppCurves.returnToCenter),
    );
    _controller.forward(from: 0);
  }

  /// 프로그래밍 방식으로 스와이프를 완료한다 (예: 하단 버튼 탭).
  ///
  /// [action]: 'like'(오른쪽), 'pass'(왼쪽), 'superlike'(위쪽).
  void triggerSwipe(String action) {
    final sw = MediaQuery.sizeOf(context).width;
    final sh = MediaQuery.sizeOf(context).height;
    final target = switch (action) {
      'like' => Offset(sw * 2.0, _offset.dy + 60),
      'superlike' => Offset(_offset.dx * 0.35, -sh * 1.4),
      _ => Offset(-sw * 2.0, _offset.dy + 60),
    };
    _pendingAction = action;
    _activeMotionAction = action;
    _anim = Tween<Offset>(
      begin: _offset,
      end: target,
    ).animate(CurvedAnimation(parent: _controller, curve: AppCurves.standard));
    _controller.forward(from: 0);
  }

  void _startRewindEntry(String action) {
    final sw = MediaQuery.sizeOf(context).width;
    final start = action == 'like'
        ? Offset(sw * 1.15, 28)
        : Offset(-sw * 1.15, 28);
    _pendingAction = null;
    _activeMotionAction = null;
    _offset = start;
    _anim = Tween<Offset>(begin: start, end: Offset.zero).animate(
      CurvedAnimation(parent: _controller, curve: AppCurves.returnToCenter),
    );
    _controller.forward(from: 0);
  }

  /// 결제/검증 실패처럼 스와이프를 취소해야 할 때 현재 카드를 원위치로 되돌린다.
  void resetPosition() {
    _controller.stop();
    _anim = null;
    _pendingAction = null;
    _activeMotionAction = null;
    if (mounted) setState(() => _offset = Offset.zero);
  }

  // ── 빌드 ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final sw = MediaQuery.sizeOf(context).width;

    // 최대 ±12도 회전.
    final angle = ((_offset.dx / sw) * (math.pi / 15)).clamp(
      -math.pi / 15,
      math.pi / 15,
    );

    // 임계값의 20% 지점부터 라벨 페이드인
    final likeOpacity = (_offset.dx / (sw * 0.2)).clamp(0.0, 1.0);
    final passOpacity = (-_offset.dx / (sw * 0.2)).clamp(0.0, 1.0);
    final superlikeOpacity = (-_offset.dy / (sw * 0.18)).clamp(0.0, 1.0);
    final isSuperlikeExit =
        _activeMotionAction == 'superlike' && _controller.isAnimating;
    final exitProgress = isSuperlikeExit ? _controller.value : 0.0;
    final cardScale = isSuperlikeExit ? 1.0 + 0.06 * exitProgress : 1.0;
    final cardOpacity = isSuperlikeExit
        ? (1.0 - exitProgress * 0.55).clamp(0.0, 1.0)
        : 1.0;

    return GestureDetector(
      onPanUpdate: _onPanUpdate,
      onPanEnd: _onPanEnd,
      child: Opacity(
        opacity: cardOpacity,
        child: Transform.translate(
          offset: _offset,
          child: Transform.rotate(
            angle: angle,
            alignment: Alignment.bottomCenter,
            child: Transform.scale(
              scale: cardScale,
              child: Stack(
                children: [
                  widget.child,
                  if (likeOpacity > 0)
                    Positioned(
                      top: 56,
                      left: 24,
                      child: Transform.rotate(
                        angle: -math.pi / 20,
                        child: Opacity(
                          opacity: likeOpacity,
                          child: _SwipeStamp(
                            icon: Icons.favorite_rounded,
                            label: 'LIKE',
                            color: AppColors.matchPrimary,
                            intensity: likeOpacity,
                          ),
                        ),
                      ),
                    ),
                  if (passOpacity > 0)
                    Positioned(
                      top: 56,
                      right: 24,
                      child: Transform.rotate(
                        angle: math.pi / 20,
                        child: Opacity(
                          opacity: passOpacity,
                          child: _SwipeStamp(
                            icon: Icons.close_rounded,
                            label: 'PASS',
                            color: AppColors.inkSecondary,
                            intensity: passOpacity,
                          ),
                        ),
                      ),
                    ),
                  if (superlikeOpacity > 0)
                    Positioned(
                      top: 56,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: Opacity(
                          opacity: superlikeOpacity,
                          child: _SwipeStamp(
                            icon: Icons.arrow_upward_rounded,
                            label: 'SUPER',
                            color: AppColors.water,
                            intensity: superlikeOpacity,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── 내부 위젯 ──────────────────────────────────────────────────────────────────

/// 드래그 중 뜨는 LIKE/PASS/SUPER 표시.
///
/// 큰 텍스트 블록 대신 아이콘 배지 + 얇은 라벨 + 은은한 글로우로 구성한다.
/// [intensity](드래그 진행도, 0~1)에 따라 배지가 살짝 커지고 글로우가
/// 짙어져 "드래그할수록 반응이 강해지는" 느낌을 준다.
class _SwipeStamp extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final double intensity;

  const _SwipeStamp({
    required this.icon,
    required this.label,
    required this.color,
    required this.intensity,
  });

  @override
  Widget build(BuildContext context) {
    final clamped = intensity.clamp(0.0, 1.0);
    final scale = 0.86 + 0.14 * clamped;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Transform.scale(
          scale: scale,
          child: Container(
            width: 60,
            height: 60,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.surface.withValues(alpha: 0.94),
              border: Border.all(
                color: color.withValues(alpha: 0.85),
                width: 2,
              ),
              boxShadow: [
                BoxShadow(
                  color: color.withValues(alpha: 0.32 * clamped),
                  blurRadius: 16,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: Icon(icon, color: color, size: 28),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: TextStyle(
            color: color,
            fontFamily: AppFonts.body,
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: 2.4,
          ),
        ),
      ],
    );
  }
}
