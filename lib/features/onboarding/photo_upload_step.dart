import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/theme/app_colors.dart';
import '../../shared/widgets/primary_button.dart';

/// 온보딩 스텝 0 — 사진 선택 (메인 1장 + 일상 사진 최대 3장).
///
/// 선택 결과는 콜백으로 상위(OnboardingScreen)에 올려 보낸다.
/// 이 위젯은 UI와 이미지 피커 호출에만 집중한다.
class PhotosUploadStep extends StatefulWidget {
  final File? mainImage;
  final List<File> subImages; // 최대 3장

  /// 메인 사진이 바뀔 때 호출. null 전달 시 선택 취소.
  final void Function(File?) onMainImageChanged;

  /// 일상 사진 목록 전체가 바뀔 때 호출.
  final void Function(List<File>) onSubImagesChanged;

  final VoidCallback onNext;

  const PhotosUploadStep({
    super.key,
    required this.mainImage,
    required this.subImages,
    required this.onMainImageChanged,
    required this.onSubImagesChanged,
    required this.onNext,
  });

  @override
  State<PhotosUploadStep> createState() => _PhotosUploadStepState();
}

class _PhotosUploadStepState extends State<PhotosUploadStep> {
  final ImagePicker _picker = ImagePicker();

  Future<void> _pickMainImage() async {
    final XFile? image = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
      maxWidth: 1080,
    );
    if (image != null) {
      widget.onMainImageChanged(File(image.path));
    }
  }

  Future<void> _pickSubImage(int index) async {
    // index: 0~2 (서브 슬롯 번호)
    final XFile? image = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 80,
      maxWidth: 1080,
    );
    if (image == null) return;
    final updated = List<File>.from(widget.subImages);
    if (index < updated.length) {
      updated[index] = File(image.path);
    } else {
      updated.add(File(image.path));
    }
    widget.onSubImagesChanged(updated);
  }

  void _removeSubImage(int index) {
    final updated = List<File>.from(widget.subImages)..removeAt(index);
    widget.onSubImagesChanged(updated);
  }

  @override
  Widget build(BuildContext context) {
    final hasMain = widget.mainImage != null;

    // Expanded + SingleChildScrollView: 메인 사진(1:1 AspectRatio)이 커서
    // 작은 화면에서 Column + Spacer 구조가 overflow를 일으킨다.
    // 콘텐츠를 스크롤 영역에 넣고 버튼만 하단에 고정한다.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 28, 24, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  '프로필 사진 추가',
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                const Text(
                  '나를 잘 표현하는 사진을 선택해주세요',
                  style: TextStyle(
                    fontSize: 15,
                    color: AppColors.textSecondary,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),

                // ── 메인 사진 (대형 슬롯) ──────────────────────────────────
                _MainPhotoSlot(image: widget.mainImage, onTap: _pickMainImage),
                const SizedBox(height: 20),

                // ── 일상 사진 (소형 슬롯 3개) ─────────────────────────────
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      '일상 사진 (선택)',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    Text(
                      '${widget.subImages.length}/3',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: List.generate(3, (i) {
                    final hasImage = i < widget.subImages.length;
                    return Expanded(
                      child: Padding(
                        padding: EdgeInsets.only(right: i < 2 ? 10 : 0),
                        child: _SubPhotoSlot(
                          image: hasImage ? widget.subImages[i] : null,
                          onTap: () => _pickSubImage(i),
                          onRemove: hasImage ? () => _removeSubImage(i) : null,
                        ),
                      ),
                    );
                  }),
                ),
              ],
            ),
          ),
        ),

        // 버튼은 스크롤 밖 하단에 고정
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
          child: PrimaryButton(
            label: '다음',
            // 메인 사진이 있어야 다음으로 진행 가능
            onPressed: hasMain ? widget.onNext : null,
          ),
        ),
      ],
    );
  }
}

/// 메인 사진 슬롯 — 큰 정사각형, 탭하면 갤러리 열림.
class _MainPhotoSlot extends StatelessWidget {
  final File? image;
  final VoidCallback onTap;

  const _MainPhotoSlot({required this.image, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AspectRatio(
        aspectRatio: 1,
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(color: AppColors.border),
            image: image != null
                ? DecorationImage(image: FileImage(image!), fit: BoxFit.cover)
                : null,
          ),
          child: image == null
              ? const Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.add_a_photo_rounded,
                      size: 44,
                      color: AppColors.textSecondary,
                    ),
                    SizedBox(height: 10),
                    Text(
                      '메인 사진 선택 (필수)',
                      style: TextStyle(
                        fontSize: 14,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                )
              : Align(
                  alignment: Alignment.bottomRight,
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: _EditBadge(onTap: onTap),
                  ),
                ),
        ),
      ),
    );
  }
}

/// 일상 사진 슬롯 (3개) — 작은 정사각형.
class _SubPhotoSlot extends StatelessWidget {
  final File? image;
  final VoidCallback onTap;
  final VoidCallback? onRemove;

  const _SubPhotoSlot({
    required this.image,
    required this.onTap,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AspectRatio(
        aspectRatio: 1,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Container(
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(AppRadius.button),
                border: Border.all(
                  color: image != null ? AppColors.primary : AppColors.border,
                  width: image != null ? 1.5 : 1,
                ),
                image: image != null
                    ? DecorationImage(
                        image: FileImage(image!),
                        fit: BoxFit.cover,
                      )
                    : null,
              ),
              child: image == null
                  ? const Icon(
                      Icons.add_rounded,
                      size: 28,
                      color: AppColors.textSecondary,
                    )
                  : null,
            ),
            // 삭제 버튼 (오른쪽 상단)
            if (image != null && onRemove != null)
              Positioned(
                top: 4,
                right: 4,
                child: GestureDetector(
                  onTap: onRemove,
                  child: Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      color: AppColors.ink.withValues(alpha: 0.54),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.close_rounded,
                      size: 14,
                      color: AppColors.surface,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// "편집" 배지 — 메인 사진 오른쪽 하단에 표시.
class _EditBadge extends StatelessWidget {
  final VoidCallback onTap;
  const _EditBadge({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: AppColors.ink.withValues(alpha: 0.54),
          borderRadius: BorderRadius.circular(AppRadius.button),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.edit_rounded, size: 13, color: AppColors.surface),
            SizedBox(width: 4),
            Text(
              '변경',
              style: TextStyle(fontSize: 12, color: AppColors.surface),
            ),
          ],
        ),
      ),
    );
  }
}
