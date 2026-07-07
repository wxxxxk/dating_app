import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../../core/constants/app_constants.dart';
import '../../models/ideal_type_model.dart';

class IdealTypeService {
  IdealTypeService({FirebaseFirestore? firestore, FirebaseFunctions? functions})
    : _db = firestore ?? FirebaseFirestore.instance,
      _functions =
          functions ??
          FirebaseFunctions.instanceFor(region: AppConstants.functionsRegion);

  final FirebaseFirestore _db;
  final FirebaseFunctions _functions;

  Future<IdealTypeImageResult?> getCachedImage(String uid) async {
    final snap = await _db.collection('users').doc(uid).get();
    final cached = snap.data()?['idealTypeImage'] as Map<String, dynamic>?;
    if (cached == null) return null;
    final result = IdealTypeImageResult.fromMap(cached);
    return result.imageUrl.isEmpty ? null : result;
  }

  Future<IdealTypeImageResult> generateImage({
    required IdealTypeImageOptions options,
  }) async {
    final callable = _functions.httpsCallable('generateIdealTypeImage');
    final result = await callable.call(options.toMap());
    return IdealTypeImageResult.fromMap(
      Map<String, dynamic>.from(result.data as Map),
    );
  }
}
