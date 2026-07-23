import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../models/appointment_safety_checkin.dart';

/// 도움 시트에서 사용자가 고른 후속 행동. 실제 신고·차단은 호출부(ChatScreen)의
/// 기존 흐름이 수행한다 — 이 시트가 자동으로 실행하지 않는다.
enum AppointmentSupportAction { reportUser, blockUser, safetyGuide }

const List<String> kPreDateSafetyChecklist = [
  '공개된 장소에서 만나기로 했어요',
  '믿을 수 있는 사람에게 약속을 알려두었어요',
  '돌아오는 방법을 미리 확인했어요',
  '주소·인증번호·금전 정보는 공유하지 않을게요',
];

/// 만남 전 안전 체크리스트 시트. 네 항목을 모두 확인해야 완료할 수 있다.
///
/// 체크 항목의 개별 선택값은 저장되지 않는다(완료 시각만 기록).
/// 완료하면 `true`를 반환하고, 취소·바깥 탭이면 null을 반환한다.
Future<bool?> showPreDateSafetySheet(BuildContext context) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surfacePrimary,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(AppRadius.sheet),
      ),
    ),
    builder: (_) => const _PreDateSafetySheet(),
  );
}

/// 만남 후 상태 확인 시트. 선택 후 "상태 기록하기"를 눌러야 확정된다.
Future<AppointmentPostSafetyStatus?> showPostDateSafetySheet(
  BuildContext context,
) {
  return showModalBottomSheet<AppointmentPostSafetyStatus>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surfacePrimary,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(AppRadius.sheet),
      ),
    ),
    builder: (_) => const _PostDateSafetySheet(),
  );
}

/// 도움이 필요한 상태에서 여는 안내 시트. 앱 기능보다 지역 긴급기관·주변
/// 도움을 먼저 권하고, 신고/차단/안전 가이드로 연결만 한다.
Future<AppointmentSupportAction?> showAppointmentSupportSheet(
  BuildContext context,
) {
  return showModalBottomSheet<AppointmentSupportAction>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surfacePrimary,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(AppRadius.sheet),
      ),
    ),
    builder: (_) => const _AppointmentSupportSheet(),
  );
}

class _SheetHandle extends StatelessWidget {
  const _SheetHandle();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 42,
        height: 4,
        decoration: BoxDecoration(
          color: AppColors.borderStrong,
          borderRadius: BorderRadius.circular(AppRadius.chip),
        ),
      ),
    );
  }
}

/// 작은 화면·키보드·큰 글자에서도 overflow가 나지 않도록 공통으로 감싼다.
class _SheetShell extends StatelessWidget {
  final Key contentKey;
  final List<Widget> children;

  const _SheetShell({required this.contentKey, required this.children});

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.85;

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(20, 8, 20, 20 + bottomInset),
          child: Column(
            key: contentKey,
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _SheetHandle(),
              const SizedBox(height: 18),
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}

/// 시트 헤더 — 옅은 mint(또는 지정 accent) tonal wash + 아이콘 + 기존 제목.
class _SheetHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  final Color accent;

  const _SheetHeader({
    required this.icon,
    required this.title,
    this.accent = AppColors.brandPrimaryStrong,
  });

  @override
  Widget build(BuildContext context) {
    final wash = accent == AppColors.statusDanger
        ? AppColors.statusDangerSoft
        : AppColors.surfaceMintSoft;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: wash,
        borderRadius: BorderRadius.circular(AppRadius.surface),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: const BoxDecoration(
              color: AppColors.surfacePrimary,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 20, color: accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                height: 1.25,
                color: AppColors.textStrong,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 저장/공개 범위를 알리는 작은 privacy notice.
class _PrivacyNotice extends StatelessWidget {
  final String text;
  const _PrivacyNotice(this.text);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surfaceSecondary,
        borderRadius: BorderRadius.circular(AppRadius.control),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.lock_outline_rounded,
            size: 16,
            color: AppColors.textMuted,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 12.5,
                height: 1.45,
                color: AppColors.textBody,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 만남 전 체크리스트 행 — 행 전체 tap, 선택 시 mint check + soft mint 배경.
class _ChecklistRow extends StatelessWidget {
  final Key rowKey;
  final String label;
  final bool checked;
  final VoidCallback onTap;

  const _ChecklistRow({
    required this.rowKey,
    required this.label,
    required this.checked,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      checked: checked,
      button: true,
      label: label,
      child: InkWell(
        key: rowKey,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          constraints: const BoxConstraints(minHeight: 52),
          color: checked ? AppColors.surfaceMintSoft : AppColors.surfacePrimary,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 22,
                height: 22,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: checked
                      ? AppColors.brandPrimaryStrong
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: checked
                        ? AppColors.brandPrimaryStrong
                        : AppColors.borderStrong,
                    width: 1.5,
                  ),
                ),
                child: checked
                    ? const Icon(
                        Icons.check_rounded,
                        size: 15,
                        color: AppColors.onBrandPrimary,
                      )
                    : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.35,
                    fontWeight: checked ? FontWeight.w700 : FontWeight.w500,
                    color: checked ? AppColors.textStrong : AppColors.textBody,
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

/// 만남 후 상태 선택 tile — 아이콘 + 라벨, 선택 시 accent border/배경.
class _SelectionTile extends StatelessWidget {
  final Key tileKey;
  final IconData icon;
  final String label;
  final Color accent;
  final bool selected;
  final VoidCallback onTap;

  const _SelectionTile({
    required this.tileKey,
    required this.icon,
    required this.label,
    required this.accent,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: selected,
      button: true,
      label: label,
      child: InkWell(
        key: tileKey,
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.surface),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          constraints: const BoxConstraints(minHeight: 56),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: selected
                ? accent.withValues(alpha: 0.10)
                : AppColors.surfacePrimary,
            borderRadius: BorderRadius.circular(AppRadius.surface),
            border: Border.all(
              color: selected ? accent : AppColors.borderSubtle,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: 20,
                color: selected ? accent : AppColors.textMuted,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                    color: selected ? AppColors.textStrong : AppColors.textBody,
                  ),
                ),
              ),
              Icon(
                selected
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_unchecked_rounded,
                size: 20,
                color: selected ? accent : AppColors.borderStrong,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 지원 시트의 명확한 tap row.
class _SupportRow extends StatelessWidget {
  final Key rowKey;
  final IconData icon;
  final String label;
  final Color accent;
  final bool muted;
  final VoidCallback onTap;

  const _SupportRow({
    required this.rowKey,
    required this.icon,
    required this.label,
    required this.accent,
    required this.onTap,
    this.muted = false,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: rowKey,
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.control),
      child: Container(
        constraints: const BoxConstraints(minHeight: 52),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
        child: Row(
          children: [
            Icon(icon, size: 20, color: accent),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: muted ? FontWeight.w600 : FontWeight.w700,
                  color: muted ? AppColors.textMuted : AppColors.textStrong,
                ),
              ),
            ),
            if (!muted)
              const Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: AppColors.textMuted,
              ),
          ],
        ),
      ),
    );
  }
}

class _PreDateSafetySheet extends StatefulWidget {
  const _PreDateSafetySheet();

  @override
  State<_PreDateSafetySheet> createState() => _PreDateSafetySheetState();
}

class _PreDateSafetySheetState extends State<_PreDateSafetySheet> {
  final List<bool> _checked = List<bool>.filled(
    kPreDateSafetyChecklist.length,
    false,
  );

  bool get _allChecked => _checked.every((value) => value);

  @override
  Widget build(BuildContext context) {
    final checkedCount = _checked.where((v) => v).length;
    return _SheetShell(
      contentKey: const ValueKey('pre-date-safety-sheet'),
      children: [
        const _SheetHeader(icon: Icons.shield_outlined, title: '만나기 전 안전 확인'),
        const SizedBox(height: 14),
        // 로컬 진행 표시 — 저장하지 않고 현재 선택 수만 보여준다.
        Text(
          '$checkedCount / ${kPreDateSafetyChecklist.length} 확인',
          style: const TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
            color: AppColors.brandPrimaryStrong,
          ),
        ),
        const SizedBox(height: 10),
        Container(
          decoration: BoxDecoration(
            color: AppColors.surfacePrimary,
            borderRadius: BorderRadius.circular(AppRadius.surface),
            border: Border.all(color: AppColors.borderSubtle),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (
                var index = 0;
                index < kPreDateSafetyChecklist.length;
                index++
              ) ...[
                if (index > 0)
                  const Divider(
                    height: 1,
                    thickness: 1,
                    color: AppColors.borderSubtle,
                  ),
                _ChecklistRow(
                  rowKey: ValueKey('pre-date-safety-check-$index'),
                  label: kPreDateSafetyChecklist[index],
                  checked: _checked[index],
                  onTap: () =>
                      setState(() => _checked[index] = !_checked[index]),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 10),
        const _PrivacyNotice('체크 항목 자체는 저장되지 않고, 확인 완료 시각만 기록돼요.'),
        const SizedBox(height: 18),
        SizedBox(
          width: double.infinity,
          height: 52,
          child: FilledButton(
            key: const ValueKey('pre-date-safety-submit-button'),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.brandPrimaryStrong,
              foregroundColor: AppColors.onBrandPrimary,
              disabledBackgroundColor: AppColors.canvasSubtle,
              disabledForegroundColor: AppColors.textMuted,
            ),
            onPressed: _allChecked ? () => Navigator.pop(context, true) : null,
            child: const Text(
              '안전 확인 완료',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
        ),
      ],
    );
  }
}

class _PostDateSafetySheet extends StatefulWidget {
  const _PostDateSafetySheet();

  @override
  State<_PostDateSafetySheet> createState() => _PostDateSafetySheetState();
}

class _PostDateSafetySheetState extends State<_PostDateSafetySheet> {
  AppointmentPostSafetyStatus? _status;

  static const Map<AppointmentPostSafetyStatus, String> _labels = {
    AppointmentPostSafetyStatus.safe: '무사히 돌아왔어요',
    AppointmentPostSafetyStatus.needsSupport: '도움이 필요해요',
    AppointmentPostSafetyStatus.cancelled: '만남이 취소됐어요',
  };

  static const Map<AppointmentPostSafetyStatus, IconData> _icons = {
    AppointmentPostSafetyStatus.safe: Icons.check_circle_rounded,
    AppointmentPostSafetyStatus.needsSupport: Icons.support_agent_rounded,
    AppointmentPostSafetyStatus.cancelled: Icons.event_busy_rounded,
  };

  Color _accent(AppointmentPostSafetyStatus status) {
    switch (status) {
      case AppointmentPostSafetyStatus.safe:
        return AppColors.brandPrimaryStrong;
      case AppointmentPostSafetyStatus.needsSupport:
        return AppColors.statusDanger;
      case AppointmentPostSafetyStatus.cancelled:
        return AppColors.textMuted;
    }
  }

  @override
  Widget build(BuildContext context) {
    return _SheetShell(
      contentKey: const ValueKey('post-date-safety-sheet'),
      children: [
        const _SheetHeader(icon: Icons.how_to_reg_rounded, title: '만남은 괜찮았나요?'),
        const SizedBox(height: 10),
        const _PrivacyNotice('이 선택은 상대에게 공개되지 않아요.'),
        const SizedBox(height: 14),
        ..._labels.entries.map((entry) {
          final selected = _status == entry.key;
          final accent = _accent(entry.key);
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _SelectionTile(
              tileKey: ValueKey('post-date-safety-option-${entry.key.name}'),
              icon: _icons[entry.key]!,
              label: entry.value,
              accent: accent,
              selected: selected,
              onTap: () => setState(() => _status = entry.key),
            ),
          );
        }),
        const SizedBox(height: 6),
        SizedBox(
          width: double.infinity,
          height: 52,
          child: FilledButton(
            key: const ValueKey('post-date-safety-submit-button'),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.brandPrimaryStrong,
              foregroundColor: AppColors.onBrandPrimary,
              disabledBackgroundColor: AppColors.canvasSubtle,
              disabledForegroundColor: AppColors.textMuted,
            ),
            onPressed: _status == null
                ? null
                : () => Navigator.pop(context, _status),
            child: const Text(
              '상태 기록하기',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
        ),
      ],
    );
  }
}

class _AppointmentSupportSheet extends StatelessWidget {
  const _AppointmentSupportSheet();

  @override
  Widget build(BuildContext context) {
    return _SheetShell(
      contentKey: const ValueKey('appointment-support-sheet'),
      children: [
        const _SheetHeader(
          icon: Icons.support_agent_rounded,
          title: '도움이 필요하신가요?',
          accent: AppColors.statusDanger,
        ),
        const SizedBox(height: 12),
        // 긴급 안내 — 옅은 danger surface. 전체 카드를 빨갛게 채우지 않는다.
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.statusDangerSoft,
            borderRadius: BorderRadius.circular(AppRadius.surface),
          ),
          child: const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.priority_high_rounded,
                size: 18,
                color: AppColors.statusDanger,
              ),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  '지금 위험한 상황이라면 앱 안의 기능보다 지역 긴급기관이나 주변의 믿을 수 있는 사람에게 먼저 도움을 요청하세요.',
                  style: TextStyle(
                    fontSize: 13.5,
                    height: 1.5,
                    color: AppColors.textStrong,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _SupportRow(
          rowKey: const ValueKey('appointment-support-report'),
          icon: Icons.flag_outlined,
          label: '사용자 신고하기',
          accent: AppColors.statusDanger,
          onTap: () =>
              Navigator.pop(context, AppointmentSupportAction.reportUser),
        ),
        _SupportRow(
          rowKey: const ValueKey('appointment-support-block'),
          icon: Icons.block_rounded,
          label: '사용자 차단하기',
          accent: AppColors.statusDanger,
          onTap: () =>
              Navigator.pop(context, AppointmentSupportAction.blockUser),
        ),
        _SupportRow(
          rowKey: const ValueKey('appointment-support-guide'),
          icon: Icons.shield_outlined,
          label: '안전 가이드 보기',
          accent: AppColors.brandPrimaryStrong,
          onTap: () =>
              Navigator.pop(context, AppointmentSupportAction.safetyGuide),
        ),
        const SizedBox(height: 4),
        _SupportRow(
          rowKey: const ValueKey('appointment-support-close'),
          icon: Icons.close_rounded,
          label: '닫기',
          accent: AppColors.textMuted,
          muted: true,
          onTap: () => Navigator.pop(context),
        ),
      ],
    );
  }
}
