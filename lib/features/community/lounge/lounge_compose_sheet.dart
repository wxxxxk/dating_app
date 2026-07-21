import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../models/community/community_post.dart';
import '../../../services/community/community_service.dart';
import '../community_text_guard.dart';

/// 라운지 글쓰기 시트(Phase 4-2).
///
/// 텍스트 전용이다 — 이미지 첨부·익명 작성·해시태그는 이번 단계에 없다.
/// 작성자 정보·상태·카운트는 서버가 만든다(클라이언트는 본문만 보낸다).
Future<bool> showLoungeComposeSheet(
  BuildContext context, {
  required CommunityService communityService,
}) async {
  final created = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.sheet)),
    ),
    builder: (_) => LoungeComposeSheet(communityService: communityService),
  );
  return created == true;
}

class LoungeComposeSheet extends StatefulWidget {
  final CommunityService communityService;

  const LoungeComposeSheet({super.key, required this.communityService});

  @override
  State<LoungeComposeSheet> createState() => _LoungeComposeSheetState();
}

class _LoungeComposeSheetState extends State<LoungeComposeSheet> {
  final _controller = TextEditingController();

  bool _submitting = false;
  String? _errorMessage;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _canSubmit => _controller.text.trim().isNotEmpty && !_submitting;

  Future<void> _submit() async {
    if (_submitting) return;
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    // 공개 글 사전 확인. 막히면 입력 내용을 그대로 유지한다.
    final allowed = await confirmCommunityTextBeforeSubmit(context, text);
    if (!allowed || !mounted) return;

    setState(() {
      _submitting = true;
      _errorMessage = null;
    });
    try {
      await widget.communityService.createLoungePost(text: text);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on CommunityActionError catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _errorMessage = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _errorMessage = CommunityService.genericErrorMessage;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      key: const ValueKey('lounge-compose-sheet'),
      padding: EdgeInsets.only(bottom: bottomInset),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '라운지 글쓰기',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.bold,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '누구나 볼 수 있는 공개 글이에요.\n연락처·인증번호·금전 정보는 올리지 마세요.',
              style: TextStyle(
                fontSize: 12.5,
                height: 1.5,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              key: const ValueKey('lounge-compose-input'),
              controller: _controller,
              maxLines: 6,
              minLines: 4,
              maxLength: CommunityPost.textMaxLength,
              enabled: !_submitting,
              textInputAction: TextInputAction.newline,
              keyboardType: TextInputType.multiline,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                hintText: '가벼운 이야기부터 시작해보세요.',
                border: OutlineInputBorder(),
              ),
            ),
            if (_errorMessage != null) ...[
              const SizedBox(height: 4),
              Text(
                _errorMessage!,
                key: const ValueKey('lounge-compose-error'),
                style: const TextStyle(fontSize: 12.5, color: AppColors.error),
              ),
            ],
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    key: const ValueKey('lounge-compose-cancel'),
                    onPressed: _submitting
                        ? null
                        : () => Navigator.of(context).pop(false),
                    child: const Text('취소'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    key: const ValueKey('lounge-compose-submit'),
                    onPressed: _canSubmit ? _submit : null,
                    child: _submitting
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
          ],
        ),
      ),
    );
  }
}
