import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../models/appointment_safety_checkin.dart';
import '../../models/chat_appointment.dart';
import '../../services/chat/chat_service.dart';

/// 약속 카드 날짜를 "2026년 7월 24일 금요일" 형태로 포맷한다.
/// 새 dependency 없이 한국어 요일 라벨만 매핑한다.
String formatAppointmentDate(DateTime dt) {
  const weekdays = ['월', '화', '수', '목', '금', '토', '일'];
  final weekday = weekdays[(dt.weekday - 1) % 7];
  return '${dt.year}년 ${dt.month}월 ${dt.day}일 $weekday요일';
}

/// 약속 카드 시간을 "오후 7:00" 형태로 포맷한다.
String formatAppointmentTime(DateTime dt) {
  final isPm = dt.hour >= 12;
  final hour12 = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
  final minute = dt.minute.toString().padLeft(2, '0');
  return '${isPm ? '오후' : '오전'} $hour12:$minute';
}

/// 채팅 입력창 왼쪽 캘린더(약속 제안) 버튼. [onPressed]가 null이면 비활성화된다
/// (blocked/unmatched/제출 진행 중).
class ChatAppointmentButton extends StatelessWidget {
  final VoidCallback? onPressed;

  const ChatAppointmentButton({super.key, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return IconButton(
      key: const ValueKey('chat-appointment-button'),
      tooltip: '약속 제안',
      onPressed: onPressed,
      iconSize: 22,
      icon: const Icon(Icons.calendar_month_rounded),
      style: IconButton.styleFrom(
        backgroundColor: enabled
            ? AppColors.surfaceMintSoft
            : AppColors.canvasSubtle,
        foregroundColor: AppColors.brandPrimaryStrong,
        disabledForegroundColor: AppColors.textMuted,
        minimumSize: const Size(46, 46),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.control),
        ),
      ),
    );
  }
}

/// 약속 제안 입력 바텀시트.
///
/// 입력값 검증·제출 진행 상태·실패 시 입력 유지를 스스로 관리한다. [onSubmit]은
/// 실제 서비스 호출을 수행하고 성공 여부를 반환한다. 성공하면 시트를 닫으며
/// `true`를 pop하고, 실패하면 열린 채로 입력을 유지한다.
class AppointmentProposalSheet extends StatefulWidget {
  final Future<bool> Function({
    required DateTime scheduledAt,
    required String place,
    required String note,
  })
  onSubmit;

  /// 테스트/초기값 주입용. 실제 사용에서는 사용자가 피커로 선택한다.
  final DateTime? initialDate;
  final TimeOfDay? initialTime;
  final DateTime? now;

  const AppointmentProposalSheet({
    super.key,
    required this.onSubmit,
    this.initialDate,
    this.initialTime,
    this.now,
  });

  @override
  State<AppointmentProposalSheet> createState() =>
      _AppointmentProposalSheetState();
}

class _AppointmentProposalSheetState extends State<AppointmentProposalSheet> {
  final _placeController = TextEditingController();
  final _noteController = TextEditingController();
  DateTime? _date;
  TimeOfDay? _time;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.initialDate != null) {
      final d = widget.initialDate!;
      _date = DateTime(d.year, d.month, d.day);
    }
    _time = widget.initialTime;
  }

  @override
  void dispose() {
    _placeController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  DateTime get _today {
    final now = widget.now ?? DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  /// 피커 내부 로직·범위·반환값은 그대로 두고, 앱의 민트 primary만 입힌다.
  Widget _pickerTheme(BuildContext context, Widget? child) {
    return Theme(
      data: Theme.of(context).copyWith(
        colorScheme: Theme.of(context).colorScheme.copyWith(
          primary: AppColors.brandPrimaryStrong,
          onPrimary: AppColors.onBrandPrimary,
        ),
      ),
      child: child ?? const SizedBox.shrink(),
    );
  }

  Future<void> _pickDate() async {
    final today = _today;
    final picked = await showDatePicker(
      context: context,
      initialDate: _date ?? today,
      firstDate: today,
      lastDate: today.add(
        const Duration(days: ChatService.appointmentMaxDaysAhead),
      ),
      builder: _pickerTheme,
    );
    if (picked != null) {
      setState(() => _date = DateTime(picked.year, picked.month, picked.day));
    }
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _time ?? TimeOfDay.now(),
      builder: _pickerTheme,
    );
    if (picked != null) setState(() => _time = picked);
  }

  Future<void> _submit() async {
    if (_submitting) return;
    if (_date == null || _time == null) {
      setState(() => _error = '날짜와 시간을 선택해 주세요.');
      return;
    }
    final scheduledAt = DateTime(
      _date!.year,
      _date!.month,
      _date!.day,
      _time!.hour,
      _time!.minute,
    );

    try {
      ChatService.normalizeAppointmentInput(
        scheduledAt: scheduledAt,
        place: _placeController.text,
        note: _noteController.text,
        now: widget.now,
      );
    } on AppointmentValidationError catch (e) {
      setState(() => _error = e.message);
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });
    final ok = await widget.onSubmit(
      scheduledAt: scheduledAt,
      place: _placeController.text.trim(),
      note: _noteController.text.trim(),
    );
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _submitting = false;
      _error = '약속을 제안하지 못했어요.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 42,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.borderStrong,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              // 헤더: 옅은 mint tonal wash + calendar icon + 기존 제목.
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppColors.surfaceMintSoft,
                  borderRadius: BorderRadius.circular(AppRadius.surface),
                  border: Border.all(
                    color: AppColors.brandPrimary.withValues(alpha: 0.18),
                  ),
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
                      child: const Icon(
                        Icons.event_available_rounded,
                        size: 20,
                        color: AppColors.brandPrimaryStrong,
                      ),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        '약속 제안하기',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: AppColors.textStrong,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              const _SectionLabel('언제 만날까요'),
              const SizedBox(height: 10),
              LayoutBuilder(
                builder: (context, constraints) {
                  final dateField = _PickerField(
                    buttonKey: const ValueKey('chat-appointment-date'),
                    icon: Icons.calendar_today_rounded,
                    label: '날짜',
                    value: _date == null
                        ? '날짜 선택'
                        : formatAppointmentDate(_date!),
                    selected: _date != null,
                    onTap: _submitting ? null : _pickDate,
                  );
                  final timeField = _PickerField(
                    buttonKey: const ValueKey('chat-appointment-time'),
                    icon: Icons.schedule_rounded,
                    label: '시간',
                    value: _time == null
                        ? '시간 선택'
                        : formatAppointmentTime(
                            DateTime(0, 1, 1, _time!.hour, _time!.minute),
                          ),
                    selected: _time != null,
                    onTap: _submitting ? null : _pickTime,
                  );
                  // 좁은 화면에서는 Row가 답답하므로 세로로 쌓는다.
                  if (constraints.maxWidth < 340) {
                    return Column(
                      children: [
                        dateField,
                        const SizedBox(height: 10),
                        timeField,
                      ],
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: dateField),
                      const SizedBox(width: 10),
                      Expanded(child: timeField),
                    ],
                  );
                },
              ),
              const SizedBox(height: 18),
              const _SectionLabel('어디서 만날까요'),
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('chat-appointment-place'),
                controller: _placeController,
                enabled: !_submitting,
                maxLength: ChatService.appointmentPlaceMaxLength,
                style: const TextStyle(color: AppColors.textStrong),
                decoration: _fieldDecoration(
                  hint: '예: 성수역 3번 출구',
                  icon: Icons.place_outlined,
                ),
              ),
              const SizedBox(height: 12),
              const _SectionLabel('남길 말'),
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('chat-appointment-note'),
                controller: _noteController,
                enabled: !_submitting,
                minLines: 1,
                maxLines: 3,
                maxLength: ChatService.appointmentNoteMaxLength,
                style: const TextStyle(color: AppColors.textBody),
                decoration: _fieldDecoration(
                  hint: '예: 근처 카페에서 만나요',
                  icon: Icons.edit_note_rounded,
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 6),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.statusDangerSoft,
                    borderRadius: BorderRadius.circular(AppRadius.control),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(
                        Icons.error_outline_rounded,
                        size: 16,
                        color: AppColors.statusDanger,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _error!,
                          key: const ValueKey('chat-appointment-error'),
                          style: const TextStyle(
                            fontSize: 13,
                            color: AppColors.statusDanger,
                            fontWeight: FontWeight.w600,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 18),
              SizedBox(
                height: 52,
                child: FilledButton(
                  key: const ValueKey('chat-appointment-submit'),
                  onPressed: _submitting ? null : _submit,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.brandPrimaryStrong,
                    foregroundColor: AppColors.onBrandPrimary,
                  ),
                  child: _submitting
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppColors.onBrandPrimary,
                          ),
                        )
                      : const Text(
                          '약속 제안하기',
                          style: TextStyle(fontWeight: FontWeight.w800),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  InputDecoration _fieldDecoration({
    required String hint,
    required IconData icon,
  }) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: AppColors.textMuted),
      prefixIcon: Icon(icon, size: 18, color: AppColors.textMuted),
      filled: true,
      fillColor: AppColors.surfaceSecondary,
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.control),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.control),
        borderSide: const BorderSide(
          color: AppColors.brandPrimaryStrong,
          width: 1.5,
        ),
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.control),
        borderSide: BorderSide.none,
      ),
    );
  }
}

/// 제안 시트 section 라벨.
class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 14,
          height: 2,
          decoration: BoxDecoration(
            color: AppColors.brandPrimary,
            borderRadius: BorderRadius.circular(AppRadius.chip),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          text,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.2,
            color: AppColors.brandPrimaryStrong,
          ),
        ),
      ],
    );
  }
}

class _PickerField extends StatelessWidget {
  final Key buttonKey;
  final IconData icon;
  final String label;
  final String value;
  final bool selected;
  final VoidCallback? onTap;

  const _PickerField({
    required this.buttonKey,
    required this.icon,
    required this.label,
    required this.value,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: buttonKey,
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.control),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.surfaceMintSoft
              : AppColors.surfaceSecondary,
          borderRadius: BorderRadius.circular(AppRadius.control),
          border: Border.all(
            color: selected
                ? AppColors.brandPrimary.withValues(alpha: 0.55)
                : AppColors.borderSubtle,
          ),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 17,
              color: selected
                  ? AppColors.brandPrimaryStrong
                  : AppColors.textMuted,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: AppColors.textMuted,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      color: selected
                          ? AppColors.textStrong
                          : AppColors.textBody,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 약속 제안 메시지를 카드로 렌더링한다. appointment 문서를 실시간 구독해
/// pending/accepted/declined 상태를 반영하고, 수신자에게만 응답 버튼을 보인다.
class AppointmentMessageCard extends StatefulWidget {
  final String appointmentId;
  final String currentUid;
  final Stream<ChatAppointment?> stream;
  final Future<void> Function(ChatAppointmentStatus status) onRespond;

  /// appointment 로드 실패 시 안전 대체 문구.
  final String fallbackText;

  // ── 안전 확인(Phase 2-5) ────────────────────────────────────────────────
  //
  // 아래 값들은 **본인 것만** 흘러들어온다. 상대의 안전 확인 상태는 rules에서
  // 읽을 수 없고, 화면에도 표시하지 않는다.

  /// 본인 안전 확인 상태 스트림. null이면 안전 영역을 표시하지 않는다.
  final Stream<AppointmentSafetyCheckin?>? safetyCheckinStream;
  final VoidCallback? onOpenPreSafetyCheck;

  /// 만남 후 상태 확인. 카드가 이미 알고 있는 약속 시각을 함께 넘겨,
  /// 호출부가 appointment 스트림을 다시 구독하지 않아도 되게 한다.
  final void Function(DateTime scheduledAt)? onOpenPostSafetyCheck;
  final VoidCallback? onOpenSupportActions;

  /// 단계 판정 기준 시각. 테스트에서 주입한다.
  final DateTime? now;

  const AppointmentMessageCard({
    super.key,
    required this.appointmentId,
    required this.currentUid,
    required this.stream,
    required this.onRespond,
    this.fallbackText = '약속을 불러오지 못했어요.',
    this.safetyCheckinStream,
    this.onOpenPreSafetyCheck,
    this.onOpenPostSafetyCheck,
    this.onOpenSupportActions,
    this.now,
  });

  @override
  State<AppointmentMessageCard> createState() => _AppointmentMessageCardState();
}

class _AppointmentMessageCardState extends State<AppointmentMessageCard> {
  bool _responding = false;

  Future<void> _respond(ChatAppointmentStatus status) async {
    if (_responding) return;
    setState(() => _responding = true);
    try {
      await widget.onRespond(status);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('응답하지 못했어요.')));
      }
    } finally {
      if (mounted) setState(() => _responding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<ChatAppointment?>(
      stream: widget.stream,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
          return _CardShell(
            appointmentId: widget.appointmentId,
            child: const _AppointmentLoading(),
          );
        }
        final appointment = snap.data;
        if (appointment == null) {
          return _CardShell(
            appointmentId: widget.appointmentId,
            child: Text(
              widget.fallbackText,
              style: const TextStyle(fontSize: 14, color: AppColors.textBody),
            ),
          );
        }
        return _CardShell(
          appointmentId: widget.appointmentId,
          child: _buildContent(appointment),
        );
      },
    );
  }

  Widget _buildContent(ChatAppointment appointment) {
    final isRecipient = appointment.isRecipient(widget.currentUid);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(
              Icons.event_rounded,
              size: 17,
              color: AppColors.brandPrimaryStrong,
            ),
            const SizedBox(width: 6),
            const Text(
              '약속 제안',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.2,
                color: AppColors.brandPrimaryStrong,
              ),
            ),
            const Spacer(),
            _StatusBadge(status: appointment.status),
          ],
        ),
        const SizedBox(height: 12),
        // 날짜가 가장 강한 정보.
        Text(
          formatAppointmentDate(appointment.scheduledAt),
          style: const TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w800,
            height: 1.25,
            color: AppColors.textStrong,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          formatAppointmentTime(appointment.scheduledAt),
          style: const TextStyle(
            fontSize: 14.5,
            color: AppColors.textBody,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(
              Icons.place_rounded,
              size: 16,
              color: AppColors.brandPrimaryStrong,
            ),
            const SizedBox(width: 5),
            Expanded(
              child: Text(
                appointment.place,
                style: const TextStyle(
                  fontSize: 14,
                  height: 1.4,
                  color: AppColors.textStrong,
                ),
              ),
            ),
          ],
        ),
        if (appointment.note.isNotEmpty) ...[
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: AppColors.surfaceSecondary,
              borderRadius: BorderRadius.circular(AppRadius.control),
            ),
            child: Text(
              appointment.note,
              style: const TextStyle(
                fontSize: 13,
                color: AppColors.textBody,
                height: 1.45,
              ),
            ),
          ),
        ],
        const SizedBox(height: 14),
        _buildStatusFooter(appointment, isRecipient),
      ],
    );
  }

  Widget _buildStatusFooter(ChatAppointment appointment, bool isRecipient) {
    switch (appointment.status) {
      case ChatAppointmentStatus.pending:
        if (isRecipient) {
          final decline = OutlinedButton(
            key: ValueKey('chat-appointment-decline-${widget.appointmentId}'),
            onPressed: _responding
                ? null
                : () => _respond(ChatAppointmentStatus.declined),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.textBody,
              side: const BorderSide(color: AppColors.borderStrong),
              minimumSize: const Size.fromHeight(48),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadius.control),
              ),
            ),
            child: const Text(
              '이번에는 어려워요',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          );
          final accept = FilledButton(
            key: ValueKey('chat-appointment-accept-${widget.appointmentId}'),
            onPressed: _responding
                ? null
                : () => _respond(ChatAppointmentStatus.accepted),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.brandPrimaryStrong,
              foregroundColor: AppColors.onBrandPrimary,
              minimumSize: const Size.fromHeight(48),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadius.control),
              ),
            ),
            child: const Text(
              '수락',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
          );
          // 좁은 폭/큰 글자에서 두 버튼 label이 잘리면 세로로 쌓는다.
          return LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth < 280) {
                return Column(
                  children: [accept, const SizedBox(height: 8), decline],
                );
              }
              return Row(
                children: [
                  Expanded(child: decline),
                  const SizedBox(width: 8),
                  Expanded(child: accept),
                ],
              );
            },
          );
        }
        return _StatusFooterText(
          icon: Icons.hourglass_empty_rounded,
          text: '상대의 답변을 기다리고 있어요.',
        );
      case ChatAppointmentStatus.accepted:
        return _buildSafetySection(appointment);
      case ChatAppointmentStatus.declined:
        return _StatusFooterText(
          icon: Icons.event_busy_rounded,
          text: '이번 약속은 성사되지 않았어요.',
        );
    }
  }

  /// 수락된 약속에만 붙는 안전 확인 영역. 참여자가 아니거나 스트림이 없으면
  /// 아무것도 표시하지 않는다.
  Widget _buildSafetySection(ChatAppointment appointment) {
    final stream = widget.safetyCheckinStream;
    final isParticipant =
        appointment.isProposer(widget.currentUid) ||
        appointment.isRecipient(widget.currentUid);
    if (stream == null || !isParticipant) return const SizedBox.shrink();

    return StreamBuilder<AppointmentSafetyCheckin?>(
      stream: stream,
      builder: (context, snap) {
        return _AppointmentSafetySection(
          appointmentId: widget.appointmentId,
          scheduledAt: appointment.scheduledAt,
          checkin: snap.data,
          now: widget.now ?? DateTime.now(),
          onOpenPreSafetyCheck: widget.onOpenPreSafetyCheck,
          onOpenPostSafetyCheck: widget.onOpenPostSafetyCheck,
          onOpenSupportActions: widget.onOpenSupportActions,
        );
      },
    );
  }
}

/// 약속 전·후 안전 확인 UI. 본인 상태만 보여주며, 한 번 기록한 결과를 다시
/// 제출하는 버튼은 제공하지 않는다.
class _AppointmentSafetySection extends StatelessWidget {
  final String appointmentId;
  final DateTime scheduledAt;
  final AppointmentSafetyCheckin? checkin;
  final DateTime now;
  final VoidCallback? onOpenPreSafetyCheck;
  final void Function(DateTime scheduledAt)? onOpenPostSafetyCheck;
  final VoidCallback? onOpenSupportActions;

  const _AppointmentSafetySection({
    required this.appointmentId,
    required this.scheduledAt,
    required this.checkin,
    required this.now,
    required this.onOpenPreSafetyCheck,
    required this.onOpenPostSafetyCheck,
    required this.onOpenSupportActions,
  });

  @override
  Widget build(BuildContext context) {
    final phase = appointmentSafetyPhase(scheduledAt: scheduledAt, now: now);
    final children = phase == AppointmentSafetyPhase.preDate
        ? _preDateChildren()
        : _postDateChildren();
    final stageLabel = phase == AppointmentSafetyPhase.preDate
        ? '만남 전 안전 확인'
        : '만남 후 상태 확인';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surfaceMintSoft,
        borderRadius: BorderRadius.circular(AppRadius.surface),
        border: Border.all(
          color: AppColors.brandPrimary.withValues(alpha: 0.18),
        ),
      ),
      child: Column(
        key: ValueKey('appointment-safety-section-$appointmentId'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 약속 확정 → 현재 단계. 실제 phase만 표시하고 새 상태를 만들지 않는다.
          Row(
            children: [
              const Icon(
                Icons.verified_rounded,
                size: 15,
                color: AppColors.brandPrimaryStrong,
              ),
              const SizedBox(width: 6),
              Text(
                '약속 확정 · $stageLabel',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.2,
                  color: AppColors.brandPrimaryStrong,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ...children,
        ],
      ),
    );
  }

  List<Widget> _preDateChildren() {
    if (checkin?.hasCompletedPreCheck ?? false) {
      return const [
        _SafetyStatusRow(icon: Icons.verified_user_rounded, label: '안전 확인 완료'),
        SizedBox(height: 4),
        _SafetyHint('만남 전 준비를 확인했어요.'),
      ];
    }
    return [
      const _SafetyHint('만나기 전에 장소와 귀가 계획을 한 번 확인해보세요.'),
      const SizedBox(height: 10),
      FilledButton.icon(
        key: ValueKey('appointment-pre-safety-button-$appointmentId'),
        onPressed: onOpenPreSafetyCheck,
        icon: const Icon(Icons.shield_outlined, size: 18),
        label: const Text('만남 전 안전 확인'),
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.brandPrimaryStrong,
          foregroundColor: AppColors.onBrandPrimary,
          minimumSize: const Size.fromHeight(48),
        ),
      ),
    ];
  }

  List<Widget> _postDateChildren() {
    final status = checkin?.postStatus;
    if (status == null) {
      return [
        const _SafetyHint('만남을 마친 뒤 현재 상태를 알려주세요.'),
        const SizedBox(height: 10),
        FilledButton.icon(
          key: ValueKey('appointment-post-safety-button-$appointmentId'),
          onPressed: onOpenPostSafetyCheck == null
              ? null
              : () => onOpenPostSafetyCheck!(scheduledAt),
          icon: const Icon(Icons.how_to_reg_rounded, size: 18),
          label: const Text('만남 후 상태 확인'),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.brandPrimaryStrong,
            foregroundColor: AppColors.onBrandPrimary,
            minimumSize: const Size.fromHeight(48),
          ),
        ),
      ];
    }

    switch (status) {
      case AppointmentPostSafetyStatus.safe:
        return const [
          _SafetyStatusRow(
            icon: Icons.check_circle_rounded,
            label: '무사히 돌아왔다고 기록했어요',
          ),
        ];
      case AppointmentPostSafetyStatus.cancelled:
        return const [
          _SafetyStatusRow(
            icon: Icons.event_busy_rounded,
            label: '만남이 취소되었다고 기록했어요',
          ),
        ];
      case AppointmentPostSafetyStatus.needsSupport:
        return [
          const _SafetyStatusRow(
            icon: Icons.support_rounded,
            label: '도움이 필요한 상태로 기록했어요',
            color: AppColors.statusDanger,
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            key: ValueKey('appointment-support-button-$appointmentId'),
            onPressed: onOpenSupportActions,
            icon: const Icon(Icons.support_agent_rounded, size: 18),
            label: const Text('신고·차단 도움 보기'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.statusDanger,
              side: const BorderSide(color: AppColors.statusDanger),
              minimumSize: const Size.fromHeight(48),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadius.control),
              ),
            ),
          ),
        ];
    }
  }
}

/// pending/declined 등 액션 없는 상태를 아이콘+문구로 표시하는 compact footer.
class _StatusFooterText extends StatelessWidget {
  final IconData icon;
  final String text;

  const _StatusFooterText({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 15, color: AppColors.textMuted),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              fontSize: 13,
              color: AppColors.textBody,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

class _SafetyStatusRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _SafetyStatusRow({
    required this.icon,
    required this.label,
    this.color = AppColors.brandPrimaryStrong,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ),
      ],
    );
  }
}

class _SafetyHint extends StatelessWidget {
  final String text;

  const _SafetyHint(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 12.5,
        height: 1.45,
        color: AppColors.textBody,
      ),
    );
  }
}

class _CardShell extends StatelessWidget {
  final String appointmentId;
  final Widget child;

  const _CardShell({required this.appointmentId, required this.child});

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: ValueKey('chat-appointment-card-$appointmentId'),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Container(
        width: double.infinity,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: AppColors.surfacePrimary,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: AppColors.borderSubtle),
          boxShadow: AppShadows.card,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 상단 mint/coral 옅은 accent 띠 — 일반 텍스트 버블과 확실히 구분.
            Container(
              height: 4,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [AppColors.brandPrimary, AppColors.expressiveAccent],
                ),
              ),
            ),
            Padding(padding: const EdgeInsets.all(16), child: child),
          ],
        ),
      ),
    );
  }
}

class _AppointmentLoading extends StatelessWidget {
  const _AppointmentLoading();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: [
        SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: AppColors.brandPrimary,
          ),
        ),
        SizedBox(width: 10),
        Text(
          '약속을 불러오는 중이에요',
          style: TextStyle(fontSize: 14, color: AppColors.textBody),
        ),
      ],
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final ChatAppointmentStatus status;

  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    late final String label;
    late final Color fg;
    late final Color bg;
    late final IconData icon;
    switch (status) {
      case ChatAppointmentStatus.accepted:
        label = '약속 확정';
        fg = AppColors.brandPrimaryStrong;
        bg = AppColors.surfaceMintSoft;
        icon = Icons.check_circle_rounded;
        break;
      case ChatAppointmentStatus.declined:
        label = '제안 종료';
        fg = AppColors.textMuted;
        bg = AppColors.surfaceSecondary;
        icon = Icons.remove_circle_outline_rounded;
        break;
      case ChatAppointmentStatus.pending:
        label = '답변 대기';
        fg = AppColors.statusWarning;
        bg = AppColors.statusWarningSoft;
        icon = Icons.hourglass_bottom_rounded;
        break;
    }
    // 색상만으로 상태를 전달하지 않도록 항상 아이콘 + 라벨을 함께 쓴다.
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: fg),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: fg,
            ),
          ),
        ],
      ),
    );
  }
}

/// 약속 수락/거절 결과를 가운데 정렬된 작은 시스템 행으로 표시한다.
/// 일반 사용자 말풍선 grouping과 섞이지 않는다.
class AppointmentResponseRow extends StatelessWidget {
  final String text;

  const AppointmentResponseRow({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: AppColors.surfaceSecondary,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            text,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.textMuted,
            ),
          ),
        ),
      ),
    );
  }
}
