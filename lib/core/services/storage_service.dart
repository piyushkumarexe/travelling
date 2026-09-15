import 'dart:io' show File;

import 'package:file_picker/file_picker.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';

import '../app_config.dart';

/// Validates + uploads user media to Firebase Storage under strict
/// path/type/size rules (mirrored server-side by storage rules).

class StorageValidationException implements Exception {
  StorageValidationException(this.message);
  final String message;
  @override
  String toString() => message;
}

class StorageService {
  final FirebaseStorage _storage = FirebaseStorage.instance;
  final ImagePicker _picker = ImagePicker();

  static const Set<String> _imageExts = <String>{'jpg', 'jpeg', 'png', 'webp'};
  static const Set<String> _videoExts = <String>{'mp4', 'mov', 'webm'};

  String _ext(XFile file) {
    final String name = file.name;
    final int dot = name.lastIndexOf('.');
    return dot >= 0 ? name.substring(dot + 1).toLowerCase() : '';
  }

  Future<void> _validateImage(XFile file) async {
    final String ext = _ext(file);
    if (!_imageExts.contains(ext)) {
      throw StorageValidationException(
          'Unsupported image format. Use JPG, PNG or WEBP.');
    }
    if (await file.length() > AppConfig.maxImageBytes) {
      throw StorageValidationException(
          'Image is too large. Maximum size is 10 MB.');
    }
  }

  Future<void> _validateVideo(XFile file) async {
    final String ext = _ext(file);
    if (!_videoExts.contains(ext)) {
      throw StorageValidationException(
          'Unsupported video format. Use MP4, MOV or WEBM.');
    }
    if (await file.length() > AppConfig.maxVideoBytes) {
      throw StorageValidationException(
          'Video is too large. Maximum size is 50 MB.');
    }
  }

  Future<void> _validateAvatar(XFile file) async {
    await _validateImage(file);
    if (await file.length() > AppConfig.maxAvatarBytes) {
      throw StorageValidationException('Avatar is too large. Maximum 5 MB.');
    }
  }

  String _contentType(XFile file) {
    final String? mime = file.mimeType;
    if (mime != null && mime.isNotEmpty) return mime;
    final String ext = _ext(file);
    const Map<String, String> byExt = <String, String>{
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'png': 'image/png',
      'webp': 'image/webp',
      'mp4': 'video/mp4',
      'mov': 'video/quicktime',
      'webm': 'video/webm',
    };
    return byExt[ext] ?? 'application/octet-stream';
  }

  Future<String> uploadIncidentImage(XFile file, String uid) async {
    await _validateImage(file);
    final Reference ref = _storage
        .ref()
        .child('incidents')
        .child(uid)
        .child('${DateTime.now().millisecondsSinceEpoch}_img.${_ext(file)}');
    await ref.putFile(File(file.path), SettableMetadata(contentType: _contentType(file)));
    return ref.getDownloadURL();
  }

  Future<String> uploadIncidentVideo(XFile file, String uid) async {
    await _validateVideo(file);
    final Reference ref = _storage
        .ref()
        .child('incidents')
        .child(uid)
        .child('${DateTime.now().millisecondsSinceEpoch}_vid.${_ext(file)}');
    await ref.putFile(File(file.path), SettableMetadata(contentType: _contentType(file)));
    return ref.getDownloadURL();
  }

  Future<String> uploadAvatar(XFile file, String uid) async {
    await _validateAvatar(file);
    final Reference ref = _storage
        .ref()
        .child('avatars')
        .child(uid)
        .child('${DateTime.now().millisecondsSinceEpoch}_avatar.${_ext(file)}');
    await ref.putFile(File(file.path), SettableMetadata(contentType: _contentType(file)));
    return ref.getDownloadURL();
  }

  /// Receipt photos for Travel Expense Guard: receipts/{uid}/{expenseId}.jpg.
  /// image_picker already resized/compressed at pick time; ownership is
  /// enforced by the storage rules on this exact path.
  Future<String> uploadReceipt(XFile file, String uid, String expenseId) async {
    await _validateImage(file);
    final Reference ref = _storage
        .ref()
        .child('receipts')
        .child(uid)
        .child('$expenseId.jpg');
    await ref.putFile(
        File(file.path), SettableMetadata(contentType: _contentType(file)));
    return ref.getDownloadURL();
  }

  /// Camera capture pre-compressed for a readable, small receipt photo.
  Future<XFile?> pickReceipt({ImageSource source = ImageSource.camera}) =>
      _picker.pickImage(
          source: source, maxWidth: 1600, imageQuality: 80);

  Future<XFile?> pickImage() =>
      _picker.pickImage(source: ImageSource.gallery, maxWidth: 1600, imageQuality: 85);

  Future<XFile?> pickVideo() =>
      _picker.pickVideo(source: ImageSource.gallery);

  Future<XFile?> pickAvatar() =>
      _picker.pickImage(source: ImageSource.gallery, maxWidth: 600, imageQuality: 85);

  // ---------------- Travel Document & Booking Vault ----------------

  /// Maximum size for a vault document file (PDF or image).
  static const int maxVaultDocumentBytes = 10 * 1024 * 1024; // 10 MB

  /// Gallery/camera pick pre-compressed by image_picker (resized to a
  /// readable 1600px / ~80 quality) — keeps documents legible and small.
  Future<XFile?> pickVaultImage({bool fromCamera = false}) =>
      _picker.pickImage(
          source: fromCamera ? ImageSource.camera : ImageSource.gallery,
          maxWidth: 1600,
          imageQuality: 80);

  /// PDF pick via the system document picker (no storage permission needed
  /// on modern Android). Returns null when the user cancels.
  Future<XFile?> pickVaultPdf() async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: <String>['pdf'],
      withData: false,
    );
    final String? path = result?.files.single.path;
    if (path == null) return null;
    return XFile(path, mimeType: 'application/pdf');
  }

  /// Starts a resumable upload of a vault document file to the strict
  /// owner path `users/{uid}/travelDocuments/{documentId}/file` (mirrored
  /// by storage.rules). Returns the Storage [Task] so callers can show
  /// progress, cancel or retry — the upload never blocks the app.
  Future<Task> startVaultUpload(
      XFile file, String uid, String documentId) async {
    final String ext = _ext(file);
    final bool isPdf = ext == 'pdf';
    if (!isPdf && !_imageExts.contains(ext)) {
      throw StorageValidationException(
          'Unsupported file format. Use PDF, JPG or PNG.');
    }
    if (await file.length() > maxVaultDocumentBytes) {
      throw StorageValidationException(
          'File is too large. Maximum size is 10 MB.');
    }
    final Reference ref = _storage
        .ref()
        .child('users')
        .child(uid)
        .child('travelDocuments')
        .child(documentId)
        .child('file');
    return ref.putFile(
      File(file.path),
      SettableMetadata(
        contentType: isPdf ? 'application/pdf' : _contentType(file),
      ),
    );
  }

  /// Deletes a vault file by its Storage path. A missing object is treated
  /// as already deleted; any other error is rethrown so the caller can
  /// surface a real failure instead of leaving an orphan silently.
  Future<void> deleteVaultFile(String storagePath) async {
    try {
      await _storage.ref(storagePath).delete();
    } on FirebaseException catch (e) {
      if (e.code != 'object-not-found') rethrow;
    }
  }
}
