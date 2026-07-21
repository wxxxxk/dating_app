import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/theme/app_colors.dart';
import '../../../models/community/community_post.dart';
import '../../../models/community/feed_draft_image.dart';
import '../../../services/auth/auth_service.dart';
import '../../../services/community/community_media_service.dart';
import '../../../services/community/community_service.dart';
import '../community_text_guard.dart';

/// 피드 글쓰기 화면(Phase 4-3).
///
/// bottom sheet 대신 full screen이다 — 이미지 미리보기 여러 장 + 키보드 +
/// 업로드 진행 상태를 작은 화면에서도 넘치지 않게 담기 위해서다.
///
/// 흐름: postId 생성 → 이미지 업로드 → createFeedPost 호출.
/// 서버 호출이 실패하면 서버가 방금 올라간 파일을 정리한다.
class FeedComposeScreen extends StatefulWidget {
  final AuthService authService;
  final CommunityService communityService;
  final CommunityMediaService mediaService;

  const FeedComposeScreen({
    super.key,
    required this.authService,
    required this.communityService,
    required this.mediaService,
  });

  @override
  State<FeedComposeScreen> createState() => _FeedComposeScreenState();
}

class _FeedComposeScreenState extends State<FeedComposeScreen> {
  static const String privacyCheckLabel =
      '사진에 전화번호·신분증·QR 코드·인증번호·금융정보가 보이지 않는 것을 확인했어요.';

  final _controller = TextEditingController();
  final List<FeedDraftImage> _images = [];

  bool _submitting = false;
  bool _picking = false;
  bool _privacyConfirmed = false;
  String? _errorMessage;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _canSubmit =>
      _controller.text.trim().isNotEmpty &&
      _images.isNotEmpty &&
      _privacyConfirmed &&
      !_submitting;

  int get _remainingSlots => CommunityMediaService.maxImages - _images.length;

  void _setError(String? message) {
    if (!mounted) return;
    setState(() => _errorMessage = message);
  }

  // ── 이미지 선택 ─────────────────────────────────────────────────────────

  Future<void> _addImages(Future<List<XFile>> Function() pick) async {
    if (_picking || _submitting) return;
    if (_remainingSlots <= 0) {
      _setError('사진은 최대 ${CommunityMediaService.maxImages}장까지 올릴 수 있어요.');
      return;
    }
    setState(() {
      _picking = true;
      _errorMessage = null;
    });
    try {
      final files = await pick();
      for (final file in files) {
        if (_images.length >= CommunityMediaService.maxImages) break;
        try {
          final draft = await widget.mediaService.prepareFeedImage(file);
          // 같은 사진을 두 번 담지 않는다.
          if (_images.any((image) => image.fingerprint == draft.fingerprint)) {
            continue;
          }
          _images.add(draft);
        } on CommunityMediaError catch (e) {
          _setError(e.message);
        }
      }
      CommunityMediaService.assertTotalWithinLimit(_images);
    } on CommunityMediaError catch (e) {
      _setError(e.message);
    } catch (_) {
      _setError(CommunityMediaService.genericErrorMessage);
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _pickFromCamera() {
    return _addImages(() async {
      final file = await widget.mediaService.pickFeedImageFromCamera();
      return file == null ? const <XFile>[] : <XFile>[file];
    });
  }

  Future<void> _pickFromGallery() {
    return _addImages(() async {
      return widget.mediaService.pickFeedImagesFromGallery(
        remainingSlots: _remainingSlots,
      );
    });
  }

  void _removeImage(int index) {
    if (_submitting) return;
    if (index < 0 || index >= _images.length) return;
    setState(() {
      _images.removeAt(index);
      _errorMessage = null;
    });
  }

  // ── 제출 ────────────────────────────────────────────────────────────────

  Future<void> _submit() async {
    if (_submitting) return;
    final uid = widget.authService.currentUser?.uid;
    final text = _controller.text.trim();
    if (uid == null || uid.isEmpty || text.isEmpty || _images.isEmpty) return;
    if (!_privacyConfirmed) return;

    // 공개 글 사전 확인. 막히면 입력 내용과 사진을 그대로 유지한다.
    final allowed = await confirmCommunityTextBeforeSubmit(context, text);
    if (!allowed || !mounted) return;

    setState(() {
      _submitting = true;
      _errorMessage = null;
    });

    try {
      final postId = widget.communityService.createPostId();
      final imagePaths = await widget.mediaService.uploadFeedImages(
        uid: uid,
        postId: postId,
        images: List<FeedDraftImage>.unmodifiable(_images),
      );
      await widget.communityService.createFeedPost(
        postId: postId,
        text: text,
        imagePaths: imagePaths,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on CommunityActionError catch (e) {
      _failSubmit(e.message);
    } on CommunityMediaUploadFailure catch (e) {
      _failSubmit(e.message);
    } on CommunityMediaError catch (e) {
      _failSubmit(e.message);
    } catch (_) {
      _failSubmit(CommunityService.genericErrorMessage);
    }
  }

  /// 실패해도 본문과 로컬 미리보기는 유지한다(다시 고르게 하지 않는다).
  void _failSubmit(String message) {
    if (!mounted) return;
    setState(() {
      _submitting = false;
      _errorMessage = message;
    });
  }

  @override
  Widget build(BuildContext context) {
    // 제출 중에는 뒤로가기로 화면을 벗어나지 못하게 막는다(중복 업로드 방지).
    return PopScope(
      canPop: !_submitting,
      child: Scaffold(
        key: const ValueKey('feed-compose-screen'),
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: AppColors.background,
          elevation: 0,
          title: const Text('피드 올리기'),
        ),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                  children: [
                    const Text(
                      '누구나 볼 수 있는 공개 게시물이에요.\n'
                      '사진의 위치 정보나 개인정보가 포함되지 않았는지 확인해주세요.',
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.5,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 14),
                    _ImagePickerRow(
                      busy: _picking || _submitting,
                      remainingSlots: _remainingSlots,
                      onCamera: _pickFromCamera,
                      onGallery: _pickFromGallery,
                    ),
                    if (_images.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      _DraftImageStrip(
                        images: _images,
                        enabled: !_submitting,
                        onRemove: _removeImage,
                      ),
                    ],
                    const SizedBox(height: 16),
                    TextField(
                      key: const ValueKey('feed-compose-input'),
                      controller: _controller,
                      maxLines: 6,
                      minLines: 4,
                      maxLength: CommunityPost.textMaxLength,
                      enabled: !_submitting,
                      textInputAction: TextInputAction.newline,
                      keyboardType: TextInputType.multiline,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        hintText: '사진에 대한 이야기를 적어주세요.',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 4),
                    _PrivacyCheckbox(
                      value: _privacyConfirmed,
                      enabled: !_submitting,
                      onChanged: (value) =>
                          setState(() => _privacyConfirmed = value),
                    ),
                    if (_errorMessage != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        _errorMessage!,
                        key: const ValueKey('feed-compose-error'),
                        style: const TextStyle(
                          fontSize: 12.5,
                          color: AppColors.error,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              _SubmitBar(
                submitting: _submitting,
                canSubmit: _canSubmit,
                onCancel: () => Navigator.of(context).pop(false),
                onSubmit: _submit,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ImagePickerRow extends StatelessWidget {
  final bool busy;
  final int remainingSlots;
  final VoidCallback onCamera;
  final VoidCallback onGallery;

  const _ImagePickerRow({
    required this.busy,
    required this.remainingSlots,
    required this.onCamera,
    required this.onGallery,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = !busy && remainingSlots > 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                key: const ValueKey('feed-compose-camera'),
                onPressed: enabled ? onCamera : null,
                icon: const Icon(Icons.photo_camera_outlined, size: 18),
                label: const Text('카메라로 촬영'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                key: const ValueKey('feed-compose-gallery'),
                onPressed: enabled ? onGallery : null,
                icon: const Icon(Icons.photo_library_outlined, size: 18),
                label: const Text('갤러리에서 선택'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          '사진 ${CommunityMediaService.maxImages - remainingSlots}/'
          '${CommunityMediaService.maxImages}장 · 한 장당 5MB까지 (jpg, png)',
          style: const TextStyle(fontSize: 11.5, color: AppColors.textSecondary),
        ),
      ],
    );
  }
}

/// 선택한 사진 미리보기. 원본 파일 경로·이름은 표시하지 않는다.
class _DraftImageStrip extends StatelessWidget {
  static const double tileSize = 92;

  final List<FeedDraftImage> images;
  final bool enabled;
  final void Function(int index) onRemove;

  const _DraftImageStrip({
    required this.images,
    required this.enabled,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: const ValueKey('feed-compose-preview'),
      height: tileSize,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: images.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          return SizedBox(
            width: tileSize,
            height: tileSize,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.button),
                  child: Image.memory(images[index].bytes, fit: BoxFit.cover),
                ),
                Positioned(
                  top: 2,
                  right: 2,
                  child: Material(
                    color: AppColors.night.withValues(alpha: 0.62),
                    shape: const CircleBorder(),
                    child: InkWell(
                      key: ValueKey('feed-compose-remove-$index'),
                      customBorder: const CircleBorder(),
                      onTap: enabled ? () => onRemove(index) : null,
                      child: const Padding(
                        padding: EdgeInsets.all(4),
                        child: Icon(
                          Icons.close_rounded,
                          size: 14,
                          color: AppColors.onNight,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _PrivacyCheckbox extends StatelessWidget {
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  const _PrivacyCheckbox({
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: const ValueKey('feed-compose-privacy-check'),
      onTap: enabled ? () => onChanged(!value) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Checkbox(
              value: value,
              onChanged: enabled ? (next) => onChanged(next == true) : null,
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            const SizedBox(width: 8),
            const Expanded(
              child: Padding(
                padding: EdgeInsets.only(top: 2),
                child: Text(
                  _FeedComposeScreenState.privacyCheckLabel,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.4,
                    color: AppColors.textSecondary,
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

class _SubmitBar extends StatelessWidget {
  final bool submitting;
  final bool canSubmit;
  final VoidCallback onCancel;
  final VoidCallback onSubmit;

  const _SubmitBar({
    required this.submitting,
    required this.canSubmit,
    required this.onCancel,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 8,
        bottom: 12 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton(
              key: const ValueKey('feed-compose-cancel'),
              onPressed: submitting ? null : onCancel,
              child: const Text('취소'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: FilledButton(
              key: const ValueKey('feed-compose-submit'),
              onPressed: canSubmit ? onSubmit : null,
              child: submitting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('게시하기'),
            ),
          ),
        ],
      ),
    );
  }
}
