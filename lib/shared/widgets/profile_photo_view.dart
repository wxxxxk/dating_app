import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

/// 프로필 사진 표시 정책을 **썸네일과 상세로 분리**한다.
///
/// 기존에는 두 경우가 같은 정책(고정 박스 + BoxFit.cover)을 썼다:
/// - 내 프로필 갤러리: `height = 화면폭 - 40` → 강제 **정사각**
/// - 상대 프로필 상세: `height: 420` 고정
///
/// 그래서 3:4 세로 사진은 위아래가, 4:3 가로 사진은 좌우가 잘려 나갔다.
/// 작은 썸네일에서는 자연스럽던 crop이 큰 사진에서는 구도를 망가뜨렸다.
///
/// 정책:
/// - 썸네일(작은 카드·아바타): crop 허용. 시각 밀도가 중요하다.
/// - 상세(큰 사진): **원본 비율 보존**. 억지로 채우지 않는다.

/// 작은 카드·아바타용. crop을 허용하고 decode 크기를 박스에 맞춰 줄인다.
///
/// [boxWidth]/[boxHeight]는 논리 픽셀 크기다. devicePixelRatio를 곱해
/// decode 상한을 정하므로 화면에서 흐려지지 않으면서 메모리를 아낀다.
/// **상세 화면에서는 이 위젯을 쓰지 않는다** — decode 상한이 그대로 따라간다.
class ProfilePhotoThumbnail extends StatelessWidget {
  const ProfilePhotoThumbnail({
    super.key,
    required this.url,
    required this.boxWidth,
    required this.boxHeight,
    this.fallbackIconSize = 38,
  });

  final String? url;
  final double boxWidth;
  final double boxHeight;
  final double fallbackIconSize;

  @override
  Widget build(BuildContext context) {
    final source = url;
    if (source == null || source.isEmpty) return _fallback();

    final ratio = MediaQuery.devicePixelRatioOf(context);
    // 긴 변 기준으로 decode 상한을 잡는다. 과하게 줄이면 다시 흐려진다.
    final cacheWidth = (boxWidth * ratio).round().clamp(1, 4096);

    return Image.network(
      source,
      fit: BoxFit.cover,
      width: boxWidth,
      height: boxHeight,
      cacheWidth: cacheWidth,
      errorBuilder: (_, _, _) => _fallback(),
    );
  }

  Widget _fallback() => ColoredBox(
    color: AppColors.surfaceElevated,
    child: Center(
      child: Icon(
        Icons.person_rounded,
        size: fallbackIconSize,
        color: AppColors.textSecondary,
      ),
    ),
  );
}

/// 큰 프로필 사진용. **원본 비율을 보존한다.**
///
/// 동작:
/// 1. 대표 사진의 실제 dimensions를 읽어 컨테이너 비율을 정한다.
/// 2. 비율은 [minAspectRatio]~[maxAspectRatio]로만 제한한다 — 파노라마처럼
///    극단적인 사진이 화면을 통째로 밀어내지 않게 하기 위한 안전장치다.
/// 3. 각 사진은 `BoxFit.contain`으로 그린다. 대표 사진은 컨테이너 비율이
///    자기 비율이므로 사실상 꽉 차고, **잘리지 않는다.**
/// 4. 여백이 생기면 같은 사진을 흐리게 깔아 자연스럽게 채운다.
///
/// decode 상한(cacheWidth)을 걸지 않는다. 큰 화면에서 흐려지면 안 된다.
class ProfilePhotoDetailView extends StatefulWidget {
  const ProfilePhotoDetailView({
    super.key,
    required this.photoUrls,
    this.onPageChanged,
    this.controller,
    this.minAspectRatio = 0.72,
    this.maxAspectRatio = 1.2,
    this.fallbackAspectRatio = 0.8,
    this.maxHeightFraction = 0.68,
    this.absoluteMaxHeight = 560,
  });

  final List<String> photoUrls;
  final ValueChanged<int>? onPageChanged;
  final PageController? controller;

  /// 세로로 가장 길게 허용할 비율(width / height).
  final double minAspectRatio;

  /// 가로로 가장 넓게 허용할 비율.
  final double maxAspectRatio;

  /// 대표 사진 크기를 아직 모를 때 쓰는 비율. layout jump를 줄인다.
  final double fallbackAspectRatio;

  /// 화면 높이 대비 사진 영역의 상한.
  ///
  /// 세로로 긴 사진이나 태블릿처럼 넓은 화면에서 사진 하나가 화면을 통째로
  /// 차지하면 아래 프로필 정보가 보이지 않는다. 높이만 제한하고 폭은 그대로
  /// 두므로, 제한이 걸려도 사진은 `contain`으로 잘리지 않는다.
  final double maxHeightFraction;

  /// 화면과 무관한 절대 상한(논리 px).
  ///
  /// 태블릿·가로 모드처럼 폭이 아주 넓으면 화면 비율만으로는 사진 하나가
  /// 스크롤 한 화면을 다 먹는다. 폭이 넓어도 이 값을 넘지 않게 한다.
  final double absoluteMaxHeight;

  @override
  State<ProfilePhotoDetailView> createState() => _ProfilePhotoDetailViewState();
}

class _ProfilePhotoDetailViewState extends State<ProfilePhotoDetailView> {
  double? _mainAspectRatio;
  ImageStream? _stream;
  ImageStreamListener? _listener;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolveMainPhotoSize();
  }

  @override
  void didUpdateWidget(covariant ProfilePhotoDetailView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.photoUrls.isEmpty ||
        widget.photoUrls.isEmpty ||
        oldWidget.photoUrls.first != widget.photoUrls.first) {
      _mainAspectRatio = null;
      _resolveMainPhotoSize();
    }
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  void _detach() {
    final stream = _stream;
    final listener = _listener;
    if (stream != null && listener != null) stream.removeListener(listener);
    _stream = null;
    _listener = null;
  }

  /// 대표 사진의 실제 크기를 읽어 컨테이너 비율을 정한다.
  void _resolveMainPhotoSize() {
    if (widget.photoUrls.isEmpty) return;
    _detach();
    final provider = NetworkImage(widget.photoUrls.first);
    final stream = provider.resolve(createLocalImageConfiguration(context));
    final listener = ImageStreamListener(
      (info, _) {
        final image = info.image;
        if (!mounted || image.height == 0) return;
        setState(() {
          _mainAspectRatio = image.width / image.height;
        });
      },
      onError: (_, _) {
        if (mounted) setState(() => _mainAspectRatio = null);
      },
    );
    _stream = stream;
    _listener = listener;
    stream.addListener(listener);
  }

  /// 안전 범위로 제한한 표시 비율.
  double get effectiveAspectRatio {
    final resolved = _mainAspectRatio ?? widget.fallbackAspectRatio;
    return resolved.clamp(widget.minAspectRatio, widget.maxAspectRatio);
  }

  @override
  Widget build(BuildContext context) {
    final viewportCap =
        MediaQuery.sizeOf(context).height * widget.maxHeightFraction;
    final maxHeight = viewportCap < widget.absoluteMaxHeight
        ? viewportCap
        : widget.absoluteMaxHeight;

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final naturalHeight = width / effectiveAspectRatio;
        final height = naturalHeight > maxHeight ? maxHeight : naturalHeight;
        return SizedBox(
          height: height,
          child: widget.photoUrls.isEmpty
              ? const ColoredBox(
                  color: AppColors.surfaceElevated,
                  child: Icon(
                    Icons.person_rounded,
                    size: 90,
                    color: AppColors.textMutedOnDark,
                  ),
                )
              : PageView.builder(
                  controller: widget.controller,
                  itemCount: widget.photoUrls.length,
                  onPageChanged: widget.onPageChanged,
                  itemBuilder: (_, index) =>
                      _Page(url: widget.photoUrls[index]),
                ),
        );
      },
    );
  }
}

/// 한 장을 그린다. 잘리지 않게 contain으로 두고, 남는 여백은 같은 사진의
/// 흐린 확대본으로 채워 흰 letterbox가 보이지 않게 한다.
class _Page extends StatelessWidget {
  const _Page({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // 배경: 같은 사진을 흐리게. 앱 톤과 자연스럽게 이어진다.
        ImageFiltered(
          imageFilter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: Image.network(
            url,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) =>
                const ColoredBox(color: AppColors.surfaceElevated),
          ),
        ),
        const ColoredBox(color: Color(0x22000000)),
        // 본 사진: 원본 비율 그대로. 어떤 경우에도 잘리지 않는다.
        Image.network(
          url,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.medium,
          errorBuilder: (_, _, _) => const Center(
            child: Icon(
              Icons.person_rounded,
              size: 72,
              color: AppColors.textMutedOnDark,
            ),
          ),
        ),
      ],
    );
  }
}
