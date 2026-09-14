// 🗂️ Travel Document & Booking Vault — document detail screen.
//
// Shows stored metadata (only real, user-entered data), the linked trip and
// the attached file. The file itself is downloaded only here — the list
// screens stay metadata-only. Actions: Edit, Replace File, Delete. File
// deletion always runs before metadata deletion so no orphan files remain.

import 'package:firebase_storage/firebase_storage.dart' show Task, TaskState;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart' show XFile;
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/state/app_container.dart';
import '../../../core/theme/app_theme.dart';
import '../travel_document.dart';

class VaultDetailScreen extends StatefulWidget {
  const VaultDetailScreen({super.key, required this.documentId});

  final String documentId;

  @override
  State<VaultDetailScreen> createState() => _VaultDetailScreenState();
}

class _VaultDetailScreenState extends State<VaultDetailScreen> {
  AppContainer get _c => AppScope.of(context);

  double? _replaceProgress;

  TravelDocument? get _doc => _c.vaultService.byId(widget.documentId);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_doc?.type.label ?? 'Document')),
      body: ListenableBuilder(
        listenable: _c.vaultService,
        builder: (BuildContext context, _) {
          final TravelDocument? d = _doc;
          if (d == null) {
            return _c.vaultService.loading
                ? const Center(child: CircularProgressIndicator())
                : const Center(
                    child: Text(
                        'This document is no longer in your vault — it may '
                        'have been deleted.'));
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: <Widget>[
              _header(d),
              if (d.tripId != null) ...<Widget>[
                const SizedBox(height: 12),
                _tripCard(d),
              ],
              const SizedBox(height: 12),
              _detailsCard(d),
              const SizedBox(height: 12),
              _fileCard(d),
              const SizedBox(height: 16),
              _actions(d),
            ],
          );
        },
      ),
    );
  }

  // ---------------- sections ----------------

  Widget _header(TravelDocument d) {
    final VaultExpiryStatus st = d.expiryDate == null
        ? VaultExpiryStatus.valid
        : d.expiryStatus(DateTime.now());
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(children: <Widget>[
              Text(d.type.emoji, style: const TextStyle(fontSize: 30)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(d.title,
                        style: const TextStyle(
                            fontSize: 17, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 2),
                    Text(d.type.label,
                        style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
            ]),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                if (d.expiryDate != null) _chip(_expiryText(d), _expiryColor(st)),
                if (d.uploadStatus == VaultUploadStatus.uploadFailed)
                  _chip('File upload failed', AppTheme.danger),
                if (d.uploadStatus == VaultUploadStatus.none)
                  _chip('No file attached', Colors.grey),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _tripCard(TravelDocument d) {
    final String name = _c.vaultService.tripName(d.tripId);
    return Card(
      child: ListTile(
        leading: const Icon(Icons.luggage),
        title: const Text('Linked trip',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
        subtitle: Text(name.isEmpty ? 'Trip (details on this device)' : name,
            style: const TextStyle(fontSize: 13)),
      ),
    );
  }

  Widget _detailsCard(TravelDocument d) {
    final List<(String, String)> rows = <(String, String)>[
      if (_nz(d.documentNumber)) ('Document / booking number', d.documentNumber!),
      if (_nz(d.issuer)) ('Issuer / provider', d.issuer!),
      if (_nz(d.pnr)) ('PNR', d.pnr!),
      if (_nz(d.bookingRef)) ('Booking reference', d.bookingRef!),
      if (_nz(d.airline)) ('Airline', d.airline!),
      if (_nz(d.flightNumber)) ('Flight number', d.flightNumber!),
      if (_nz(d.departureAirport)) ('From (airport)', d.departureAirport!),
      if (_nz(d.arrivalAirport)) ('To (airport)', d.arrivalAirport!),
      if (_nz(d.departureLocation)) ('From', d.departureLocation!),
      if (_nz(d.arrivalLocation)) ('To', d.arrivalLocation!),
      if (_nz(d.terminal)) ('Terminal', d.terminal!),
      if (_nz(d.seat)) ('Seat / coach', d.seat!),
      if (_nz(d.hotelName)) ('Hotel', d.hotelName!),
      if (_nz(d.address)) ('Address', d.address!),
      if (_nz(d.contact)) ('Contact', d.contact!),
      if (_nz(d.operatorName)) ('Operator', d.operatorName!),
      if (_nz(d.providerName)) ('Provider', d.providerName!),
      if (_nz(d.venue)) ('Venue', d.venue!),
      if (_nz(d.location)) ('Location', d.location!),
      if (d.issueDate != null) ('Issue date', _fmt(d.issueDate!)),
      if (d.expiryDate != null) ('Expiry date', _fmt(d.expiryDate!)),
      if (d.travelDate != null) ('Travel date', _fmt(d.travelDate!)),
      if (d.startDate != null) ('Start date', _fmt(d.startDate!)),
      if (d.endDate != null) ('End date', _fmt(d.endDate!)),
      if (d.departureDateTime != null)
        ('Departure', _fmtTime(d.departureDateTime!)),
      if (d.arrivalDateTime != null) ('Arrival', _fmtTime(d.arrivalDateTime!)),
      if (d.checkInDateTime != null) ('Check-in', _fmtTime(d.checkInDateTime!)),
      if (d.checkOutDateTime != null)
        ('Check-out', _fmtTime(d.checkOutDateTime!)),
      if (d.eventDateTime != null) ('Event', _fmtTime(d.eventDateTime!)),
      if (_nz(d.notes)) ('Notes', d.notes!),
    ];
    if (rows.isEmpty) {
      return const Card(
        child: Padding(
            padding: EdgeInsets.all(14),
            child: Text(
                'No extra details were saved for this document. Tap Edit to '
                'add numbers, dates or names.')),
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          children: <Widget>[
            for (final (String, String) r in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    SizedBox(
                      width: 132,
                      child: Text(r.$1,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(fontWeight: FontWeight.w700)),
                    ),
                    Expanded(
                        child: SelectableText(r.$2,
                            style: const TextStyle(fontSize: 13.5))),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _fileCard(TravelDocument d) {
    final bool hasFile = d.fileUrl != null && d.storagePath != null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(children: <Widget>[
              Icon(
                hasFile ? Icons.description : Icons.no_sim,
                size: 20,
                color: hasFile ? Theme.of(context).colorScheme.primary : Colors.grey,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  hasFile
                      ? (d.fileName ?? 'Attached file')
                      : 'No file attached (manual entry)',
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 13.5),
                ),
              ),
              if (d.fileSize != null && d.fileSize! > 0)
                Text(_sizeLabel(d.fileSize!),
                    style: Theme.of(context).textTheme.bodySmall),
            ]),
            if (_replaceProgress != null) ...<Widget>[
              const SizedBox(height: 10),
              LinearProgressIndicator(
                  value: _replaceProgress! <= 0 ? null : _replaceProgress),
              const SizedBox(height: 4),
              Text(
                  _replaceProgress! <= 0
                      ? 'Starting upload…'
                      : 'Uploading… ${(_replaceProgress! * 100).toStringAsFixed(0)}%',
                  style: const TextStyle(fontSize: 12)),
            ],
            if (hasFile) ...<Widget>[
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  FilledButton.tonalIcon(
                    onPressed:
                        _replaceProgress == null ? () => _openFile(d) : null,
                    icon: const Icon(Icons.open_in_new, size: 16),
                    label: const Text('Preview / open',
                        style: TextStyle(fontSize: 12.5)),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _actions(TravelDocument d) => Column(
        children: <Widget>[
          Row(children: <Widget>[
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => context.push('/vault/edit', extra: d.id),
                icon: const Icon(Icons.edit, size: 18),
                label: const Text('Edit'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _replaceProgress == null
                    ? () => _replaceFile(d)
                    : null,
                icon: const Icon(Icons.sync, size: 18),
                label: const Text('Replace file'),
              ),
            ),
          ]),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.danger,
                side: const BorderSide(color: AppTheme.danger),
              ),
              onPressed: () => _confirmDelete(d),
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('Delete document'),
            ),
          ),
        ],
      );

  // ---------------- actions ----------------

  Future<void> _openFile(TravelDocument d) async {
    final bool isImage =
        (d.fileName ?? '').toLowerCase().endsWith('.pdf') == false;
    if (isImage) {
      await showDialog<void>(
        context: context,
        builder: (BuildContext ctx) => Dialog(
          insetPadding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              AppBar(
                title: const Text('Preview'),
                actions: <Widget>[
                  IconButton(
                    icon: const Icon(Icons.open_in_new),
                    tooltip: 'Open externally',
                    onPressed: () => _launchExternal(ctx, d.fileUrl!),
                  ),
                ],
              ),
              Flexible(
                child: InteractiveViewer(
                  child: Image.network(
                    d.fileUrl!,
                    fit: BoxFit.contain,
                    loadingBuilder: (BuildContext c, Widget w,
                            ImageChunkEvent? p) =>
                        const Padding(
                            padding: EdgeInsets.all(40),
                            child: CircularProgressIndicator()),
                    errorBuilder: (_, __, ___) => const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                          'Could not load the preview. Check your internet '
                          'connection, or open the file externally.'),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    } else {
      await _launchExternal(context, d.fileUrl!);
    }
  }

  Future<void> _launchExternal(BuildContext context, String url) async {
    try {
      final bool ok = await launchUrl(Uri.parse(url),
          mode: LaunchMode.externalApplication);
      if (!ok && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('No app on this device could open the file.')));
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Could not open the file (no internet or no app available '
                'for this file type).')));
      }
    }
  }

  Future<void> _replaceFile(TravelDocument d) async {
    final XFile? file = await _pickReplacement();
    if (file == null || !mounted) return;
    final String? uid = _c.authRepository.currentUser?.uid;
    if (uid == null) return;
    setState(() => _replaceProgress = 0.0);
    try {
      final Task task =
          await _c.vaultService.startUpload(file, uid, d.id);
      task.snapshotEvents.listen((TaskSnapshot s) {
        if (!mounted) return;
        if (s.state == TaskState.running && s.totalBytes > 0) {
          setState(() => _replaceProgress = s.bytesTransferred / s.totalBytes);
        }
      });
      await task;
      final String url = await task.ref.getDownloadURL();
      await _c.vaultService.completeUpload(
        uid: uid,
        docId: d.id,
        fileUrl: url,
        storagePath: 'users/$uid/travelDocuments/${d.id}/file',
        fileName: file.name,
        fileSize: await file.length(),
      );
      if (!mounted || !context.mounted) return;
      setState(() => _replaceProgress = null);
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('File replaced.')));
    } catch (_) {
      if (!mounted || !context.mounted) return;
      setState(() => _replaceProgress = null);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text(
              'Upload failed — the previous file is still in place. '
              'Check your internet connection and try again.'),
          action: SnackBarAction(label: 'Retry', onPressed: () => _replaceFile(d))));
    }
  }

  Future<XFile?> _pickReplacement() async {
    final String? choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.image),
              title: const Text('Pick an image (JPG/PNG)'),
              onTap: () => Navigator.pop(ctx, 'image'),
            ),
            ListTile(
              leading: const Icon(Icons.picture_as_pdf),
              title: const Text('Pick a PDF'),
              onTap: () => Navigator.pop(ctx, 'pdf'),
            ),
          ],
        ),
      ),
    );
    if (choice == null) return null;
    try {
      return choice == 'pdf'
          ? await _c.storageService.pickVaultPdf()
          : await _c.storageService.pickVaultImage();
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Could not open the file picker.')));
      }
      return null;
    }
  }

  Future<void> _confirmDelete(TravelDocument d) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('Delete this document?'),
        content: Text(
            '"${d.title}" and its attached file (if any) will be permanently '
            'deleted from your vault. This cannot be undone.'),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted || !context.mounted) return;
    try {
      await _c.vaultService.deleteDocument(d);
      if (!context.mounted) return;
      Navigator.of(context).pop(true);
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'The attached file could not be deleted from the server, so the '
              'entry was kept to avoid leaving an orphaned file. Check your '
              'internet connection and try again.')));
    }
  }

  // ---------------- small helpers ----------------

  Widget _chip(String label, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                color: color)),
      );

  Color _expiryColor(VaultExpiryStatus st) => switch (st) {
        VaultExpiryStatus.expired => AppTheme.danger,
        VaultExpiryStatus.expiresToday => AppTheme.danger,
        VaultExpiryStatus.expiresSoon => AppTheme.warning,
        VaultExpiryStatus.valid => AppTheme.success,
      };

  String _expiryText(TravelDocument d) => switch (d.expiryStatus(DateTime.now())) {
        VaultExpiryStatus.expired => 'Expired',
        VaultExpiryStatus.expiresToday => 'Expires today',
        VaultExpiryStatus.expiresSoon => 'Expires in ${d.daysUntilExpiry()} days',
        VaultExpiryStatus.valid =>
          'Valid until ${DateFormat('dd MMM yyyy').format(d.expiryDate!)}',
      };

  static bool _nz(String? s) => s != null && s.trim().isNotEmpty;

  static String _fmt(DateTime d) => DateFormat('dd MMM yyyy').format(d);

  static String _fmtTime(DateTime d) =>
      DateFormat('dd MMM yyyy, HH:mm').format(d);

  static String _sizeLabel(int bytes) {
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
