import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/theme/app_colors.dart';
import '../../models/photo_verification_request.dart';
import '../../services/verification/photo_verification_service.dart';
import '../../shared/widgets/premium_components.dart';

/// 사진 인증 화면(Phase 3-2).
///
/// 운영자가 프로필 사진과 비교해 **수동으로** 검토할 셀피를 제출한다.
/// 앱은 얼굴 인식이나 생체 판정을 하지 않으며, 인증 배지는 서버 승인 후에만
/// 반영된다.
class PhotoVerificationScreen extends StatefulWidget {
  final String uid;
  final PhotoVerificationService service;

  const PhotoVerificationScreen({
    super.key,
    required this.uid,
    required this.service,
  });

  @override
  State<PhotoVerificationScreen> createState() =>
      _PhotoVerificationScreenState();
}

class _PhotoVerificationScreenState extends State<PhotoVerificationScreen> {
  XFile? _captured;
  bool _consented = false;
  bool _submitting = false;

  Future<void> _capture() async {
    if (_submitting) return;
    try {
      final photo = await widget.service.captureVerificationPhoto();
      // 사용자가 촬영을 취소하면 기존 상태를 그대로 둔다.
      if (photo == null || !mounted) return;
      setState(() {
        _captured = photo;
        _consented = false;
      });
    } catch (e) {
      _debugLog('[PhotoVerification] 촬영 실패 code=${e.runtimeType}');
      if (mounted) _showSnack('카메라를 열지 못했어요. 잠시 후 다시 시도해주세요.');
    }
  }

  Future<void> _submit() async {
    final photo = _captured;
    if (photo == null || !_consented || _submitting) return;

    setState(() => _submitting = true);
    try {
      await widget.service.submitVerificationPhoto(
        uid: widget.uid,
        photo: photo,
      );
      if (!mounted) return;
      setState(() {
        _captured = null;
        _consented = false;
      });
      _showSnack('사진 인증을 요청했어요. 검토 결과를 기다려주세요.');
    } on PhotoVerificationError catch (e) {
      // 서비스가 만든 사용자 안전 문구만 노출한다.
      if (mounted) _showSnack(e.message);
    } catch (e) {
      _debugLog('[PhotoVerification] 제출 실패 code=${e.runtimeType}');
      if (mounted) _showSnack('사진 인증을 제출하지 못했어요. 잠시 후 다시 시도해주세요.');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _debugLog(String message) {
    if (kDebugMode) debugPrint(message);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: const Text('사진 인증'),
      ),
      body: SafeArea(
        child: StreamBuilder<PhotoVerificationRequest?>(
          stream: widget.service.watchRequest(widget.uid),
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting &&
                !snap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final request = snap.data;
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
              child: Column(
                key: const ValueKey('photo-verification-body'),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '프로필 사진이 본인의 사진인지 운영자가 확인해요.\n인증용 사진은 공개되지 않으며 검토 후 삭제돼요.',
                    style: TextStyle(
                      fontSize: 13.5,
                      height: 1.5,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 16),
                  ..._buildStateSection(request),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  List<Widget> _buildStateSection(PhotoVerificationRequest? request) {
    if (request != null && request.isPending) {
      return const [
        _StatusCard(
          key: ValueKey('photo-verification-pending'),
          icon: Icons.hourglass_top_rounded,
          title: '사진 인증 검토 중',
          body: '검토가 끝나면 인증 상태가 자동으로 반영돼요.',
        ),
      ];
    }
    if (request != null && request.isApproved) {
      return const [
        _StatusCard(
          key: ValueKey('photo-verification-approved'),
          icon: Icons.verified_rounded,
          title: '사진 인증 완료',
          body: '프로필에 사진 인증 배지가 표시돼요.',
          color: AppColors.mintDeep,
        ),
      ];
    }

    return [
      if (request != null && request.isRejected) ...[
        _StatusCard(
          key: const ValueKey('photo-verification-rejected'),
          icon: Icons.error_outline_rounded,
          title: '사진을 다시 확인해주세요',
          body: request.rejectionLabel ?? photoRejectionReasonLabel(null),
          color: AppColors.error,
        ),
        const SizedBox(height: 16),
      ],
      if (_captured == null) ..._buildGuide(request) else ..._buildPreview(),
    ];
  }

  List<Widget> _buildGuide(PhotoVerificationRequest? request) {
    return [
      PremiumSectionCard(
        title: '촬영 전 확인해주세요',
        child: Column(
          key: const ValueKey('photo-verification-guide'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const [
            _GuideLine('밝은 장소에서 촬영해주세요.'),
            _GuideLine('얼굴 전체가 잘 보이게 촬영해주세요.'),
            _GuideLine('마스크·선글라스 등 얼굴을 가리는 물건은 벗어주세요.'),
            _GuideLine('프로필 사진과 본인 확인이 가능한 현재 모습으로 촬영해주세요.'),
            _GuideLine('인증 사진은 공개되지 않고 검토 후 삭제돼요.'),
          ],
        ),
      ),
      const SizedBox(height: 18),
      SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          key: const ValueKey('photo-verification-capture-button'),
          onPressed: _submitting ? null : _capture,
          icon: const Icon(Icons.photo_camera_rounded, size: 18),
          label: Text(
            request != null && request.isRejected ? '다시 촬영하기' : '인증 사진 촬영하기',
          ),
        ),
      ),
    ];
  }

  List<Widget> _buildPreview() {
    return [
      ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.card),
        child: AspectRatio(
          aspectRatio: 3 / 4,
          child: Image.file(
            File(_captured!.path),
            key: const ValueKey('photo-verification-preview'),
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => Container(
              color: AppColors.surface,
              alignment: Alignment.center,
              child: const Text(
                '사진 미리보기를 표시할 수 없어요.',
                style: TextStyle(
                  fontSize: 13,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
          ),
        ),
      ),
      const SizedBox(height: 14),
      CheckboxListTile(
        key: const ValueKey('photo-verification-consent'),
        value: _consented,
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        title: const Text(
          '인증 사진이 운영 검토에 사용되고 검토 후 삭제되는 것에 동의해요.',
          style: TextStyle(fontSize: 13.5, height: 1.4),
        ),
        onChanged: _submitting
            ? null
            : (value) => setState(() => _consented = value ?? false),
      ),
      const SizedBox(height: 10),
      Row(
        children: [
          Expanded(
            child: OutlinedButton(
              key: const ValueKey('photo-verification-retake-button'),
              onPressed: _submitting ? null : _capture,
              child: const Text('다시 촬영'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: FilledButton(
              key: const ValueKey('photo-verification-submit-button'),
              onPressed: (!_consented || _submitting) ? null : _submit,
              child: Text(_submitting ? '제출 중…' : '인증 요청 제출'),
            ),
          ),
        ],
      ),
    ];
  }
}

class _StatusCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  final Color color;

  const _StatusCard({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    this.color = AppColors.textSecondary,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: color == AppColors.textSecondary
                        ? AppColors.textPrimary
                        : color,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  body,
                  style: const TextStyle(
                    fontSize: 13,
                    height: 1.45,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _GuideLine extends StatelessWidget {
  final String text;

  const _GuideLine(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 5, right: 8),
            child: Icon(Icons.circle, size: 5, color: AppColors.mintDeep),
          ),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 13.5,
                height: 1.45,
                color: AppColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
