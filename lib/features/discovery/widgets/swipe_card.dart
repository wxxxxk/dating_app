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

  const SwipeCard({
    super.key,
    required this.profileUid,
    required this.child,
    required this.onSwiped,
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

  @override
  void initState() {
    super.initState();
    _controller =
        AnimationController(
            vsync: this,
            duration: const Duration(milliseconds: 320),
          )
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
      _controller.reset(); // 0으로 리셋 → _onTick은 _anim이 null이라 no-op
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
    _anim = Tween<Offset>(
      begin: _offset,
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.elasticOut));
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
      'superlike' => Offset(_offset.dx, -sh * 1.4),
      _ => Offset(-sw * 2.0, _offset.dy + 60),
    };
    _pendingAction = action;
    _anim = Tween<Offset>(
      begin: _offset,
      end: target,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));
    _controller.forward(from: 0);
  }

  /// 결제/검증 실패처럼 스와이프를 취소해야 할 때 현재 카드를 원위치로 되돌린다.
  void resetPosition() {
    _controller.stop();
    _anim = null;
    _pendingAction = null;
    if (mounted) setState(() => _offset = Offset.zero);
  }

  // ── 빌드 ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final sw = MediaQuery.sizeOf(context).width;

    // 최대 ±23도 회전 (카드 하단을 기준으로 회전해 자연스러운 스와이프 느낌)
    final angle = (_offset.dx / sw) * 0.4;

    // 임계값의 20% 지점부터 라벨 페이드인
    final likeOpacity = (_offset.dx / (sw * 0.2)).clamp(0.0, 1.0);
    final passOpacity = (-_offset.dx / (sw * 0.2)).clamp(0.0, 1.0);
    final superlikeOpacity = (-_offset.dy / (sw * 0.18)).clamp(0.0, 1.0);

    return GestureDetector(
      onPanUpdate: _onPanUpdate,
      onPanEnd: _onPanEnd,
      child: Transform.translate(
        offset: _offset,
        child: Transform.rotate(
          angle: angle,
          alignment: Alignment.bottomCenter,
          child: Stack(
            children: [
              widget.child,
              if (likeOpacity > 0)
                Positioned(
                  top: 52,
                  left: 20,
                  child: Opacity(
                    opacity: likeOpacity,
                    child: _SwipeLabel(
                      label: 'LIKE',
                      color: const Color(0xFF4CAF50),
                    ),
                  ),
                ),
              if (passOpacity > 0)
                Positioned(
                  top: 52,
                  right: 20,
                  child: Opacity(
                    opacity: passOpacity,
                    child: _SwipeLabel(label: 'PASS', color: AppColors.error),
                  ),
                ),
              if (superlikeOpacity > 0)
                Positioned(
                  top: 52,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Opacity(
                      opacity: superlikeOpacity,
                      child: const _SwipeLabel(
                        label: 'STAR',
                        color: Color(0xFF4F8CFF),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── 내부 위젯 ──────────────────────────────────────────────────────────────────

class _SwipeLabel extends StatelessWidget {
  final String label;
  final Color color;

  const _SwipeLabel({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: color, width: 3),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        child: Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 28,
            fontWeight: FontWeight.bold,
            letterSpacing: 2.5,
          ),
        ),
      ),
    );
  }
}
