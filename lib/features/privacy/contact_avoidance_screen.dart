import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../models/contact_avoidance_settings.dart';
import '../../services/privacy/contact_avoidance_service.dart';
import '../../shared/widgets/premium_components.dart';

/// 지인 피하기 화면(Phase 3-4).
///
/// 연락처 전화번호를 기기에서 해시로 바꿔 가입자를 찾고, 서로의 추천에서
/// 숨긴다. 연락처 이름·전화번호 원문은 서버로 보내지 않는다.
class ContactAvoidanceScreen extends StatefulWidget {
  final String uid;
  final ContactAvoidanceService service;

  /// 전화 인증 완료 여부. 미완료면 선행 안내만 보여준다.
  final bool phoneVerified;

  /// 전화 인증 화면으로 이동하는 콜백(기존 흐름 재사용).
  final VoidCallback? onVerifyPhone;

  const ContactAvoidanceScreen({
    super.key,
    required this.uid,
    required this.service,
    required this.phoneVerified,
    this.onVerifyPhone,
  });

  @override
  State<ContactAvoidanceScreen> createState() => _ContactAvoidanceScreenState();
}

class _ContactAvoidanceScreenState extends State<ContactAvoidanceScreen> {
  /// build()에서 만들면 setState마다 새 스트림이 생겨 로딩으로 되돌아간다.
  late final Stream<ContactAvoidanceSettings?> _settingsStream = widget.service
      .watchSettings(widget.uid);

  bool _consented = false;
  bool _syncing = false;
  bool _permissionDenied = false;

  Future<void> _sync() async {
    if (_syncing) return;
    setState(() {
      _syncing = true;
      _permissionDenied = false;
    });
    try {
      final result = await widget.service.syncContacts(uid: widget.uid);
      if (!mounted) return;
      _showSnack('연락처 ${result.contactCount}개를 동기화했어요.');
    } on ContactPermissionDeniedError {
      if (mounted) setState(() => _permissionDenied = true);
    } on ContactAvoidanceError catch (e) {
      // 서비스가 만든 사용자 안전 문구만 노출한다.
      if (mounted) _showSnack(e.message);
    } catch (e) {
      _debugLog('[ContactAvoidance] 동기화 실패 code=${e.runtimeType}');
      if (mounted) _showSnack('동기화하지 못했어요. 잠시 후 다시 시도해주세요.');
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _confirmDisable() async {
    if (_syncing) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('지인 피하기를 끌까요?'),
        content: const Text(
          '연락처로 찾은 숨김이 해제돼요. 기존 매칭과 대화는 그대로 유지됩니다.\n\n'
          '상대방이 나를 연락처에 저장해 지인 피하기를 사용 중이면 서로 추천에서 계속 숨겨질 수 있어요.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.error,
              foregroundColor: AppColors.surface,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('끄기'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _syncing = true);
    try {
      await widget.service.disable(uid: widget.uid);
      if (!mounted) return;
      setState(() => _consented = false);
      _showSnack('지인 피하기를 껐어요.');
    } on ContactAvoidanceError catch (e) {
      if (mounted) _showSnack(e.message);
    } catch (e) {
      _debugLog('[ContactAvoidance] 끄기 실패 code=${e.runtimeType}');
      if (mounted) _showSnack('설정을 변경하지 못했어요. 잠시 후 다시 시도해주세요.');
    } finally {
      if (mounted) setState(() => _syncing = false);
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
        title: const Text('지인 피하기'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
          child: Column(
            key: const ValueKey('contact-avoidance-body'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: widget.phoneVerified
                ? _buildVerifiedBody()
                : _buildPhoneRequired(),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildPhoneRequired() {
    return [
      const _InfoCard(
        key: ValueKey('contact-avoidance-phone-required'),
        icon: Icons.phone_iphone_rounded,
        title: '전화 인증이 필요해요',
        body: '지인 피하기를 사용하려면 먼저 전화 인증이 필요해요.',
      ),
      const SizedBox(height: 18),
      SizedBox(
        width: double.infinity,
        child: FilledButton(
          key: const ValueKey('contact-avoidance-verify-phone-button'),
          onPressed: widget.onVerifyPhone,
          child: const Text('전화 인증하기'),
        ),
      ),
    ];
  }

  List<Widget> _buildVerifiedBody() {
    return [
      StreamBuilder<ContactAvoidanceSettings?>(
        stream: _settingsStream,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          final settings = snap.data ?? ContactAvoidanceSettings.disabled;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: settings.enabled
                ? _buildActive(settings)
                : _buildIntro(),
          );
        },
      ),
    ];
  }

  List<Widget> _buildIntro() {
    return [
      const Text(
        '연락처에 있는 가입자를 찾아 서로 추천에서 숨겨요.\n기존 매치와 대화는 영향을 받지 않아요.',
        style: TextStyle(
          fontSize: 14,
          height: 1.5,
          color: AppColors.textPrimary,
        ),
      ),
      const SizedBox(height: 16),
      PremiumSectionCard(
        title: '개인정보 안내',
        child: const Column(
          key: ValueKey('contact-avoidance-privacy-guide'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '전화번호는 기기에서 암호화된 형태로 변환되며, 연락처 이름과 전화번호 원문은 서버에 저장되지 않아요.\n\n'
              '연락처가 바뀌면 다시 동기화해주세요.',
              style: TextStyle(
                fontSize: 13,
                height: 1.5,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
      if (_permissionDenied) ...[
        const SizedBox(height: 14),
        const _InfoCard(
          key: ValueKey('contact-avoidance-permission-denied'),
          icon: Icons.contacts_outlined,
          title: '연락처 권한이 필요해요',
          body: '기기 설정에서 연락처 접근을 허용한 뒤 다시 시도해주세요.',
          color: AppColors.error,
        ),
      ],
      const SizedBox(height: 8),
      CheckboxListTile(
        key: const ValueKey('contact-avoidance-consent'),
        value: _consented,
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        title: const Text(
          '연락처 전화번호를 기기에서 변환해 가입자 확인에 사용하는 것에 동의해요.',
          style: TextStyle(fontSize: 13, height: 1.4),
        ),
        onChanged: _syncing
            ? null
            : (value) => setState(() => _consented = value ?? false),
      ),
      const SizedBox(height: 10),
      SizedBox(
        width: double.infinity,
        child: FilledButton(
          key: const ValueKey('contact-avoidance-sync-button'),
          onPressed: (!_consented || _syncing) ? null : _sync,
          child: Text(
            _syncing
                ? '동기화 중…'
                : _permissionDenied
                ? '다시 시도'
                : '연락처 동기화하고 지인 숨기기',
          ),
        ),
      ),
    ];
  }

  List<Widget> _buildActive(ContactAvoidanceSettings settings) {
    return [
      _InfoCard(
        key: const ValueKey('contact-avoidance-active'),
        icon: Icons.visibility_off_rounded,
        title: '지인 피하기 사용 중',
        body: '연락처에 있는 가입자를 서로 추천에서 숨기고 있어요.',
        color: AppColors.mintDeep,
      ),
      const SizedBox(height: 14),
      PremiumSectionCard(
        title: '동기화 상태',
        child: Column(
          key: const ValueKey('contact-avoidance-summary'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SummaryRow(
              label: '동기화한 연락처',
              value: '${settings.contactCount}개',
            ),
            _SummaryRow(label: '숨긴 가입자', value: '${settings.hiddenCount}명'),
            _SummaryRow(
              label: '마지막 동기화',
              value: _formatSyncedAt(settings.syncedAt),
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      const Text(
        '기존 매칭과 대화는 계속 유지돼요.\n연락처가 바뀌면 다시 동기화해주세요.\n\n'
        '기능을 꺼도 상대방이 나를 연락처에 저장해 지인 피하기를 사용 중이면 서로 추천에서 계속 숨겨질 수 있어요.',
        style: TextStyle(
          fontSize: 12.5,
          height: 1.5,
          color: AppColors.textSecondary,
        ),
      ),
      const SizedBox(height: 18),
      SizedBox(
        width: double.infinity,
        child: FilledButton(
          key: const ValueKey('contact-avoidance-resync-button'),
          onPressed: _syncing ? null : _sync,
          child: Text(_syncing ? '동기화 중…' : '연락처 다시 동기화'),
        ),
      ),
      const SizedBox(height: 10),
      SizedBox(
        width: double.infinity,
        child: OutlinedButton(
          key: const ValueKey('contact-avoidance-disable-button'),
          onPressed: _syncing ? null : _confirmDisable,
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.error,
            side: const BorderSide(color: AppColors.error),
          ),
          child: const Text('지인 피하기 끄기'),
        ),
      ),
      if (_permissionDenied) ...[
        const SizedBox(height: 14),
        const _InfoCard(
          key: ValueKey('contact-avoidance-permission-denied'),
          icon: Icons.contacts_outlined,
          title: '연락처 권한이 필요해요',
          body: '기기 설정에서 연락처 접근을 허용한 뒤 다시 시도해주세요.',
          color: AppColors.error,
        ),
      ],
    ];
  }

  static String _formatSyncedAt(DateTime? value) {
    if (value == null) return '아직 없음';
    final local = value.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '${local.year}.$month.$day $hour:$minute';
  }
}

class _SummaryRow extends StatelessWidget {
  final String label;
  final String value;

  const _SummaryRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 13,
                color: AppColors.textSecondary,
              ),
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  final Color color;

  const _InfoCard({
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
