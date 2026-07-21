import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/theme/app_colors.dart';
import '../../models/affiliation_verification_request.dart';
import '../../services/verification/affiliation_verification_service.dart';
import '../../shared/widgets/premium_components.dart';

/// 직장·학교 소속 인증 화면(Phase 3-3).
///
/// 운영자가 증빙을 **수동으로** 확인한다. 앱은 OCR이나 문서 자동 판정을 하지
/// 않으며, 인증 배지는 서버 승인 후에만 반영된다.
class AffiliationVerificationScreen extends StatefulWidget {
  final String uid;
  final AffiliationVerificationType type;
  final AffiliationVerificationService service;

  const AffiliationVerificationScreen({
    super.key,
    required this.uid,
    required this.type,
    required this.service,
  });

  @override
  State<AffiliationVerificationScreen> createState() =>
      _AffiliationVerificationScreenState();
}

class _AffiliationVerificationScreenState
    extends State<AffiliationVerificationScreen> {
  /// build()에서 만들면 setState(키 입력 등)마다 새 스트림이 만들어져 로딩
  /// 상태로 되돌아간다. 화면 수명 동안 하나만 유지한다.
  late final Stream<AffiliationVerificationRequest?> _requestStream = widget
      .service
      .watchRequest(uid: widget.uid, type: widget.type);
  final _institutionController = TextEditingController();
  final _detailController = TextEditingController();
  late String _proofType = affiliationProofTypesByType[widget.type]!.first;
  XFile? _proof;
  bool _consented = false;
  bool _submitting = false;

  @override
  void dispose() {
    _institutionController.dispose();
    _detailController.dispose();
    super.dispose();
  }

  bool get _canSubmit =>
      _proof != null &&
      _consented &&
      !_submitting &&
      _institutionController.text.trim().length >=
          AffiliationVerificationRequest.institutionNameMinLength;

  Future<void> _pick({required bool fromCamera}) async {
    if (_submitting) return;
    try {
      final picked = fromCamera
          ? await widget.service.pickProofFromCamera()
          : await widget.service.pickProofFromGallery();
      // 선택을 취소하면 기존 상태를 유지한다.
      if (picked == null || !mounted) return;
      setState(() {
        _proof = picked;
        _consented = false;
      });
    } catch (e) {
      _debugLog('[AffiliationVerification] 이미지 선택 실패 code=${e.runtimeType}');
      if (mounted) _showSnack('이미지를 불러오지 못했어요. 잠시 후 다시 시도해주세요.');
    }
  }

  Future<void> _submit() async {
    final proof = _proof;
    if (proof == null || !_canSubmit) return;

    setState(() => _submitting = true);
    try {
      await widget.service.submitVerification(
        uid: widget.uid,
        type: widget.type,
        institutionName: _institutionController.text,
        affiliationDetail: _detailController.text,
        proofType: _proofType,
        proof: proof,
      );
      if (!mounted) return;
      setState(() {
        _proof = null;
        _consented = false;
      });
      _showSnack('인증 요청을 제출했어요. 검토 결과를 기다려주세요.');
    } on AffiliationVerificationError catch (e) {
      // 서비스가 만든 사용자 안전 문구만 노출한다.
      if (mounted) _showSnack(e.message);
    } catch (e) {
      _debugLog('[AffiliationVerification] 제출 실패 code=${e.runtimeType}');
      if (mounted) _showSnack('인증 요청을 제출하지 못했어요. 잠시 후 다시 시도해주세요.');
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

  String get _typeLabel => affiliationVerificationTypeLabel(widget.type);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: Text(_typeLabel),
      ),
      body: SafeArea(
        child: StreamBuilder<AffiliationVerificationRequest?>(
          stream: _requestStream,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting &&
                !snap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final request = snap.data;
            return SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                20,
                12,
                20,
                28 + MediaQuery.viewInsetsOf(context).bottom,
              ),
              child: Column(
                key: const ValueKey('affiliation-verification-body'),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '소속을 확인할 수 있는 증빙을 운영자가 직접 확인해요.\n증빙 이미지는 공개되지 않으며 검토 후 삭제됩니다.',
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

  List<Widget> _buildStateSection(AffiliationVerificationRequest? request) {
    if (request != null && request.isPending) {
      return [
        _StatusCard(
          key: const ValueKey('affiliation-verification-pending'),
          icon: Icons.hourglass_top_rounded,
          title: '$_typeLabel 검토 중',
          body: '검토가 끝나면 인증 상태가 자동으로 반영돼요.',
        ),
      ];
    }
    if (request != null && request.isApproved) {
      return [
        _StatusCard(
          key: const ValueKey('affiliation-verification-approved'),
          icon: Icons.verified_rounded,
          title: '$_typeLabel 완료',
          body: '프로필에 인증 배지가 표시돼요.',
          color: AppColors.mintDeep,
        ),
      ];
    }

    return [
      if (request != null && request.isRejected) ...[
        _StatusCard(
          key: const ValueKey('affiliation-verification-rejected'),
          icon: Icons.error_outline_rounded,
          title: '인증 자료를 다시 확인해주세요',
          body: request.rejectionLabel ?? affiliationRejectionReasonLabel(null),
          color: AppColors.error,
        ),
        const SizedBox(height: 16),
      ],
      ..._buildForm(resubmit: request?.isRejected ?? false),
    ];
  }

  List<Widget> _buildForm({required bool resubmit}) {
    final proofTypes = affiliationProofTypesByType[widget.type]!;
    return [
      TextField(
        key: const ValueKey('affiliation-institution-field'),
        controller: _institutionController,
        enabled: !_submitting,
        maxLength: AffiliationVerificationRequest.institutionNameMaxLength,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          labelText: '기관명',
          hintText: widget.type == AffiliationVerificationType.work
              ? '재직 중인 회사·기관 이름'
              : '재학 중인 학교 이름',
        ),
      ),
      TextField(
        key: const ValueKey('affiliation-detail-field'),
        controller: _detailController,
        enabled: !_submitting,
        maxLength: AffiliationVerificationRequest.affiliationDetailMaxLength,
        decoration: InputDecoration(
          labelText: '상세 소속 (선택)',
          hintText: widget.type == AffiliationVerificationType.work
              ? '부서·팀 등'
              : '학과·과정 등',
        ),
      ),
      const SizedBox(height: 6),
      const Text(
        '증빙 유형',
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: AppColors.textPrimary,
        ),
      ),
      ...proofTypes.map((key) {
        final selected = _proofType == key;
        return ListTile(
          key: ValueKey('affiliation-proof-$key'),
          contentPadding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
          leading: Icon(
            selected
                ? Icons.radio_button_checked_rounded
                : Icons.radio_button_unchecked_rounded,
            color: selected ? AppColors.primary : AppColors.textSecondary,
          ),
          title: Text(affiliationProofTypeLabel(key)),
          onTap: _submitting ? null : () => setState(() => _proofType = key),
        );
      }),
      const SizedBox(height: 8),
      PremiumSectionCard(
        title: '제출 전 확인해주세요',
        child: const Column(
          key: ValueKey('affiliation-privacy-guide'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '기관명과 현재 소속을 확인할 수 있는 부분만 남겨주세요.\n\n'
              '주민등록번호, 학생·사원번호, 집 주소, 전화번호, QR 코드와 바코드는 가린 뒤 제출해주세요.\n\n'
              '증빙 이미지는 공개되지 않으며 운영 검토 후 삭제됩니다.',
              style: TextStyle(
                fontSize: 13,
                height: 1.5,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 14),
      if (_proof != null) ...[
        ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.card),
          child: AspectRatio(
            aspectRatio: 4 / 3,
            child: Image.file(
              File(_proof!.path),
              key: const ValueKey('affiliation-proof-preview'),
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => Container(
                color: AppColors.surface,
                alignment: Alignment.center,
                child: const Text(
                  '이미지 미리보기를 표시할 수 없어요.',
                  style: TextStyle(
                    fontSize: 13,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
      ],
      Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              key: const ValueKey('affiliation-camera-button'),
              onPressed: _submitting ? null : () => _pick(fromCamera: true),
              icon: const Icon(Icons.photo_camera_rounded, size: 17),
              label: const Text('카메라로 촬영'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: OutlinedButton.icon(
              key: const ValueKey('affiliation-gallery-button'),
              onPressed: _submitting ? null : () => _pick(fromCamera: false),
              icon: const Icon(Icons.photo_library_rounded, size: 17),
              label: const Text('갤러리에서 선택'),
            ),
          ),
        ],
      ),
      const SizedBox(height: 6),
      CheckboxListTile(
        key: const ValueKey('affiliation-consent'),
        value: _consented,
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        title: const Text(
          '민감한 번호·주소·QR 코드를 가렸으며, 증빙 이미지가 운영 검토에 사용되고 검토 후 삭제되는 것에 동의해요.',
          style: TextStyle(fontSize: 13, height: 1.4),
        ),
        onChanged: (_submitting || _proof == null)
            ? null
            : (value) => setState(() => _consented = value ?? false),
      ),
      const SizedBox(height: 10),
      SizedBox(
        width: double.infinity,
        child: FilledButton(
          key: const ValueKey('affiliation-submit-button'),
          onPressed: _canSubmit ? _submit : null,
          child: Text(
            _submitting
                ? '제출 중…'
                : resubmit
                ? '다시 제출하기'
                : '인증 요청 제출',
          ),
        ),
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
