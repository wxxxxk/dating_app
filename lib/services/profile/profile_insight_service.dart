import 'dart:convert';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:crypto/crypto.dart';

import '../../core/constants/app_constants.dart';
import '../../models/profile_insight_model.dart';
import '../../models/user_profile.dart';

class ProfileInsightService {
  // TODO(Phase 0-B follow-up): move profile insight cache/read behavior behind an authenticated server API that accepts targetUid without exposing target users/{uid} reads to clients.
  ProfileInsightService({FirebaseFunctions? functions})
    : _functions =
          functions ??
          FirebaseFunctions.instanceFor(region: AppConstants.functionsRegion);

  final FirebaseFunctions _functions;

  Future<ProfileInsight> getProfileInsight({
    required UserProfile profile,
    bool refresh = false,
  }) async {
    final callable = _functions.httpsCallable('generateProfileInsight');
    final result = await callable.call({
      'targetUid': profile.uid,
      'refresh': refresh,
    });
    return ProfileInsight.fromMap(
      Map<String, dynamic>.from(result.data as Map),
    );
  }

  String inputHashForProfile(UserProfile profile) {
    final photoUrl = profile.photoUrls.isNotEmpty
        ? profile.photoUrls.first
        : '';
    final input = <String, dynamic>{
      'photoUrl': photoUrl,
      'bio': _limit(profile.bio, 500),
      'interests': profile.interests,
      'personalityTags': profile.personalityTags,
      'idealTags': profile.idealTags,
      'relationshipGoal': profile.relationshipGoal ?? '',
      'mbti': profile.mbti ?? '',
      'birthDate': _dateKeyInSeoul(profile.birthDate),
    };
    return sha256.convert(utf8.encode(jsonEncode(input))).toString();
  }

  String _limit(String value, int maxLength) {
    if (value.length <= maxLength) return value;
    return value.substring(0, maxLength);
  }

  String _dateKeyInSeoul(DateTime date) {
    final seoulDate = date.toUtc().add(const Duration(hours: 9));
    final year = seoulDate.year.toString().padLeft(4, '0');
    final month = seoulDate.month.toString().padLeft(2, '0');
    final day = seoulDate.day.toString().padLeft(2, '0');
    return '$year-$month-$day';
  }
}
