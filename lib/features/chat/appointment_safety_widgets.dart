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
    backgroundColor: AppColors.background,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.sheet)),
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
    backgroundColor: AppColors.background,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.sheet)),
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
    backgroundColor: AppColors.background,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.sheet)),
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
          color: AppColors.border,
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
            children: [const _SheetHandle(), const SizedBox(height: 18), ...children],
          ),
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
    return _SheetShell(
      contentKey: const ValueKey('pre-date-safety-sheet'),
      children: [
        Row(
          children: [
            const Icon(
              Icons.shield_outlined,
              size: 20,
              color: AppColors.mintDeep,
            ),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                '만나기 전 안전 확인',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        ...List.generate(kPreDateSafetyChecklist.length, (index) {
          return CheckboxListTile(
            key: ValueKey('pre-date-safety-check-$index'),
            value: _checked[index],
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(
              kPreDateSafetyChecklist[index],
              style: const TextStyle(fontSize: 14, height: 1.35),
            ),
            onChanged: (value) =>
                setState(() => _checked[index] = value ?? false),
          );
        }),
        const SizedBox(height: 6),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(AppRadius.button),
            border: Border.all(color: AppColors.border),
          ),
          child: const Text(
            '체크 항목 자체는 저장되지 않고, 확인 완료 시각만 기록돼요.',
            style: TextStyle(
              fontSize: 12.5,
              height: 1.45,
              color: AppColors.textSecondary,
            ),
          ),
        ),
        const SizedBox(height: 18),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            key: const ValueKey('pre-date-safety-submit-button'),
            onPressed: _allChecked ? () => Navigator.pop(context, true) : null,
            child: const Text('안전 확인 완료'),
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

  @override
  Widget build(BuildContext context) {
    return _SheetShell(
      contentKey: const ValueKey('post-date-safety-sheet'),
      children: [
        const Text(
          '만남은 괜찮았나요?',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          '이 선택은 상대에게 공개되지 않아요.',
          style: TextStyle(
            fontSize: 13,
            height: 1.45,
            color: AppColors.textSecondary,
          ),
        ),
        const SizedBox(height: 10),
        ..._labels.entries.map((entry) {
          final selected = _status == entry.key;
          return ListTile(
            key: ValueKey('post-date-safety-option-${entry.key.name}'),
            contentPadding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            leading: Icon(
              selected
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_unchecked_rounded,
              color: selected ? AppColors.primary : AppColors.textSecondary,
            ),
            title: Text(entry.value),
            onTap: () => setState(() => _status = entry.key),
          );
        }),
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            key: const ValueKey('post-date-safety-submit-button'),
            onPressed: _status == null
                ? null
                : () => Navigator.pop(context, _status),
            child: const Text('상태 기록하기'),
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
        const Text(
          '도움이 필요하신가요?',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 10),
        const Text(
          '지금 위험한 상황이라면 앱 안의 기능보다 지역 긴급기관이나 주변의 믿을 수 있는 사람에게 먼저 도움을 요청하세요.',
          style: TextStyle(
            fontSize: 13.5,
            height: 1.5,
            color: AppColors.textSecondary,
          ),
        ),
        const SizedBox(height: 8),
        ListTile(
          key: const ValueKey('appointment-support-report'),
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.flag_outlined, color: AppColors.error),
          title: const Text('사용자 신고하기'),
          onTap: () =>
              Navigator.pop(context, AppointmentSupportAction.reportUser),
        ),
        ListTile(
          key: const ValueKey('appointment-support-block'),
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.block_rounded, color: AppColors.error),
          title: const Text('사용자 차단하기'),
          onTap: () =>
              Navigator.pop(context, AppointmentSupportAction.blockUser),
        ),
        ListTile(
          key: const ValueKey('appointment-support-guide'),
          contentPadding: EdgeInsets.zero,
          leading: const Icon(
            Icons.shield_outlined,
            color: AppColors.mintDeep,
          ),
          title: const Text('안전 가이드 보기'),
          onTap: () =>
              Navigator.pop(context, AppointmentSupportAction.safetyGuide),
        ),
        ListTile(
          key: const ValueKey('appointment-support-close'),
          contentPadding: EdgeInsets.zero,
          leading: const Icon(
            Icons.close_rounded,
            color: AppColors.textSecondary,
          ),
          title: const Text('닫기'),
          onTap: () => Navigator.pop(context),
        ),
      ],
    );
  }
}
