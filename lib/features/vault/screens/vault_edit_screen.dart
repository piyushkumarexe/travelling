// 🗂️ Travel Document & Booking Vault — add / edit screen.
//
// Manual entry for every field (no OCR exists in this project, so nothing
// pretends to read documents — all values come from the user). Files are
// picked with the app's existing pickers: images are pre-compressed by
// image_picker, PDFs via the system document picker. Uploads run through
// the existing StorageService with live progress, cancel and retry to the
// SAME Storage path (stable document id → no duplicate uploads/orphans).

import 'package:firebase_storage/firebase_storage.dart'
    show Task, TaskSnapshot, TaskState;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart' show XFile;
import 'package:intl/intl.dart';

import '../../../core/state/app_container.dart';
import '../../../data/models/trip_plan.dart' show TripPlan;
import '../travel_document.dart';
import '../vault_service.dart';

class VaultEditScreen extends StatefulWidget {
  const VaultEditScreen({super.key, this.documentId});

  /// Null = create a new entry.
  final String? documentId;

  @override
  State<VaultEditScreen> createState() => _VaultEditScreenState();
}

class _VaultEditScreenState extends State<VaultEditScreen> {
  AppContainer get _c => AppScope.of(context);

  TravelDocument? _existing;

  final List<TextEditingController> _ctrls = <TextEditingController>[];
  late final TextEditingController _title = _newCtrl();
  late final TextEditingController _docNumber = _newCtrl();
  late final TextEditingController _issuer = _newCtrl();
  late final TextEditingController _notes = _newCtrl();
  late final TextEditingController _pnr = _newCtrl();
  late final TextEditingController _bookingRef = _newCtrl();
  late final TextEditingController _airline = _newCtrl();
  late final TextEditingController _flightNumber = _newCtrl();
  late final TextEditingController _depAirport = _newCtrl();
  late final TextEditingController _arrAirport = _newCtrl();
  late final TextEditingController _terminal = _newCtrl();
  late final TextEditingController _seat = _newCtrl();
  late final TextEditingController _hotelName = _newCtrl();
  late final TextEditingController _address = _newCtrl();
  late final TextEditingController _contact = _newCtrl();
  late final TextEditingController _operator = _newCtrl();
  late final TextEditingController _provider = _newCtrl();
  late final TextEditingController _venue = _newCtrl();
  late final TextEditingController _location = _newCtrl();
  late final TextEditingController _depLocation = _newCtrl();
  late final TextEditingController _arrLocation = _newCtrl();

  TravelDocType _type = TravelDocType.passport;
  String? _tripId;

  DateTime? _issueDate;
  DateTime? _expiryDate;
  DateTime? _travelDate;
  DateTime? _startDate;
  DateTime? _endDate;
  DateTime? _departureDateTime;
  DateTime? _arrivalDateTime;
  DateTime? _checkInDateTime;
  DateTime? _checkOutDateTime;
  DateTime? _eventDateTime;

  XFile? _file; // newly picked file (not yet uploaded)
  double? _uploadProgress; // null = not uploading
  bool _uploadCancelled = false;
  bool _saving = false;
  String? _error;

  TextEditingController _newCtrl({String? text}) {
    final TextEditingController c = TextEditingController(text: text ?? '');
    _ctrls.add(c);
    return c;
  }

  @override
  void initState() {
    super.initState();
    final TravelDocument? doc = _c.vaultService.byId(widget.documentId);
    if (doc != null) _hydrate(doc);
  }

  void _hydrate(TravelDocument d) {
    _existing = d;
    _type = d.type;
    _tripId = d.tripId;
    _title.text = d.title;
    _docNumber.text = d.documentNumber ?? '';
    _issuer.text = d.issuer ?? '';
    _notes.text = d.notes ?? '';
    _pnr.text = d.pnr ?? '';
    _bookingRef.text = d.bookingRef ?? '';
    _airline.text = d.airline ?? '';
    _flightNumber.text = d.flightNumber ?? '';
    _depAirport.text = d.departureAirport ?? '';
    _arrAirport.text = d.arrivalAirport ?? '';
    _terminal.text = d.terminal ?? '';
    _seat.text = d.seat ?? '';
    _hotelName.text = d.hotelName ?? '';
    _address.text = d.address ?? '';
    _contact.text = d.contact ?? '';
    _operator.text = d.operatorName ?? '';
    _provider.text = d.providerName ?? '';
    _venue.text = d.venue ?? '';
    _location.text = d.location ?? '';
    _depLocation.text = d.departureLocation ?? '';
    _arrLocation.text = d.arrivalLocation ?? '';
    _issueDate = d.issueDate;
    _expiryDate = d.expiryDate;
    _travelDate = d.travelDate;
    _startDate = d.startDate;
    _endDate = d.endDate;
    _departureDateTime = d.departureDateTime;
    _arrivalDateTime = d.arrivalDateTime;
    _checkInDateTime = d.checkInDateTime;
    _checkOutDateTime = d.checkOutDateTime;
    _eventDateTime = d.eventDateTime;
  }

  @override
  void dispose() {
    for (final TextEditingController c in _ctrls) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _c.vaultService,
      builder: (BuildContext context, _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    if (widget.documentId != null && _existing == null) {
      // Editing: wait for the metadata stream (or report missing).
      final TravelDocument? doc = _c.vaultService.byId(widget.documentId);
      if (doc == null && _c.vaultService.loading) {
        return Scaffold(
          appBar: AppBar(),
          body: const Center(child: CircularProgressIndicator()),
        );
      }
      if (doc == null) {
        return Scaffold(
          appBar: AppBar(title: const Text('Document')),
          body: const Center(
              child: Text(
                  'This document no longer exists in your vault (it may have '
                  'been deleted on another device).')),
        );
      }
      _hydrate(doc);
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(_existing == null
            ? 'Add Document/Booking'
            : 'Edit ${_type.label}'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: <Widget>[
          _typeSelector(),
          _section('Essentials'),
          _field(_title, 'Title *',
              hint: 'e.g. Passport — summary page, Flight to Dubai'),
          _tripSelector(),
          _fileSection(),
          ..._typeFields(),
          _section('Notes'),
          _field(_notes, 'Notes (private, optional)', maxLines: 3),
          const SizedBox(height: 8),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(_error!,
                  style: const TextStyle(color: Colors.red, fontSize: 12.5)),
            ),
          if (_uploadProgress != null) ...<Widget>[
            LinearProgressIndicator(value: _uploadProgress! <= 0 ? null : _uploadProgress),
            const SizedBox(height: 6),
            Row(children: <Widget>[
              Text(
                  _uploadProgress! <= 0
                      ? 'Starting upload…'
                      : 'Uploading file… ${(_uploadProgress! * 100).toStringAsFixed(0)}%',
                  style: const TextStyle(fontSize: 12)),
              const Spacer(),
              TextButton(
                onPressed: _cancelUpload,
                child: const Text('Cancel upload'),
              ),
            ]),
          ],
          FilledButton.icon(
            onPressed: _saving || _uploadProgress != null
                ? null
                : _save,
            icon: Icon(_existing == null ? Icons.add : Icons.save),
            label: Text(_existing == null
                ? 'Add to vault'
                : 'Save changes'),
          ),
        ],
      ),
    );
  }

  // ---------------- pickers ----------------

  Future<void> _pickDate(void Function(DateTime) onPicked) async {
    final DateTime now = DateTime.now();
    final DateTime? d = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: DateTime(now.year - 15),
      lastDate: DateTime(now.year + 15),
    );
    if (d != null) onPicked(d);
  }

  Future<void> _pickDateTime(void Function(DateTime) onPicked) async {
    final DateTime now = DateTime.now();
    final DateTime? d = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: DateTime(now.year - 15),
      lastDate: DateTime(now.year + 15),
    );
    if (d == null) return;
    if (!mounted || !context.mounted) return;
    final TimeOfDay? t =
        await showTimePicker(context: context, initialTime: TimeOfDay.now());
    final TimeOfDay time = t ?? const TimeOfDay(hour: 0, minute: 0);
    onPicked(DateTime(d.year, d.month, d.day, time.hour, time.minute));
  }

  Future<void> _pickFile({required bool pdf}) async {
    try {
      final XFile? f = pdf
          ? await _c.storageService.pickVaultPdf()
          : await _c.storageService.pickVaultImage();
      if (!mounted) return;
      if (f == null) return;
      setState(() => _file = f);
    } catch (_) {
      if (!mounted) return;
      setState(() => _error =
          'Could not open the file picker. Check the app has the needed '
          'permission on this device.');
    }
  }

  // ---------------- save / upload ----------------

  Future<void> _save() async {
    final String? uid = _c.authRepository.currentUser?.uid;
    if (uid == null) {
      setState(() => _error = 'You are signed out. Sign in and try again.');
      return;
    }
    final String title = _title.text.trim();
    if (title.isEmpty) {
      setState(() => _error = 'Give this document a title so you can find '
          'it later.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final String docId = _existing?.id ?? _c.vaultService.newDocumentId();
    final TravelDocument doc = _buildDocument(docId, uid);
    try {
      if (_file != null) {
        await _uploadThenSave(doc, uid);
      } else {
        if (_existing == null) {
          await _c.vaultService.createDocument(doc);
        } else {
          await _c.vaultService.updateDocument(doc);
        }
        if (!mounted || !context.mounted) return;
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = VaultService.describeVaultError(e);
      });
    }
  }

  Future<void> _uploadThenSave(TravelDocument doc, String uid) async {
    final XFile file = _file!;
    _uploadCancelled = false;
    setState(() => _uploadProgress = 0.0);
    try {
      final Task task = await _c.vaultService.startUpload(file, uid, doc.id);
      task.snapshotEvents.listen((TaskSnapshot s) {
        if (!mounted) return;
        if (s.state == TaskState.running && s.totalBytes > 0) {
          setState(
              () => _uploadProgress = s.bytesTransferred / s.totalBytes);
        }
      });
      final TaskSnapshot snap =
          await task; // throws FirebaseException('canceled') / errors
      final String url = await snap.ref.getDownloadURL();
      final TravelDocument withFile = doc.copyWith(
        fileUrl: url,
        storagePath: 'users/$uid/travelDocuments/${doc.id}/file',
        fileName: file.name,
        fileSize: await file.length(),
        uploadStatus: VaultUploadStatus.uploaded,
      );
      if (_existing == null) {
        await _c.vaultService.createDocument(withFile);
      } else {
        await _c.vaultService.updateDocument(withFile);
      }
      if (!mounted || !context.mounted) return;
      Navigator.of(context).pop(true);
    } catch (_) {
      if (!mounted) return;
      if (_uploadCancelled) {
        setState(() => _uploadProgress = null);
        return;
      }
      final bool? saveWithoutFile = await showDialog<bool>(
        context: context,
        builder: (BuildContext ctx) => AlertDialog(
          title: const Text('Upload failed'),
          content: const Text(
              'Your file could not be uploaded (check your internet '
              'connection). You can retry, or save this entry without the '
              'file and attach it later.'),
          actions: <Widget>[
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Save without file')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, null),
                child: const Text('Retry upload')),
          ],
        ),
      );
      if (!mounted) return;
      if (saveWithoutFile == null) {
        setState(() => _uploadProgress = null);
        await _uploadThenSave(doc, uid); // retry same path — no duplicates
      } else if (saveWithoutFile) {
        setState(() => _uploadProgress = null);
        if (_existing == null) {
          await _c.vaultService.createDocument(doc);
        } else {
          await _c.vaultService.updateDocument(doc);
        }
        if (!mounted || !context.mounted) return;
        Navigator.of(context).pop(true);
      } else {
        setState(() => _uploadProgress = null);
      }
    }
  }

  void _cancelUpload() {
    _uploadCancelled = true;
    setState(() => _uploadProgress = null);
  }

  TravelDocument _buildDocument(String docId, String uid) {
    final DateTime now = DateTime.now();
    final TravelDocument? base = _existing;
    String? s(TextEditingController c) {
      final String v = c.text.trim();
      return v.isEmpty ? null : v;
    }

    return TravelDocument(
      id: docId,
      userId: uid,
      tripId: _tripId,
      type: _type,
      title: _title.text.trim(),
      documentNumber: s(_docNumber),
      issuer: s(_issuer),
      issueDate: _issueDate,
      expiryDate: _expiryDate,
      travelDate: _travelDate,
      startDate: _startDate,
      endDate: _endDate,
      departureLocation: s(_depLocation),
      arrivalLocation: s(_arrLocation),
      notes: s(_notes),
      fileUrl: base?.fileUrl,
      storagePath: base?.storagePath,
      fileName: base?.fileName,
      fileSize: base?.fileSize,
      uploadStatus: base?.uploadStatus ?? VaultUploadStatus.none,
      pnr: s(_pnr),
      bookingRef: s(_bookingRef),
      airline: s(_airline),
      flightNumber: s(_flightNumber),
      departureAirport: s(_depAirport),
      arrivalAirport: s(_arrAirport),
      terminal: s(_terminal),
      seat: s(_seat),
      departureDateTime: _departureDateTime,
      arrivalDateTime: _arrivalDateTime,
      hotelName: s(_hotelName),
      checkInDateTime: _checkInDateTime,
      checkOutDateTime: _checkOutDateTime,
      address: s(_address),
      contact: s(_contact),
      operatorName: s(_operator),
      providerName: s(_provider),
      venue: s(_venue),
      location: s(_location),
      eventDateTime: _eventDateTime,
      createdAt: base?.createdAt ?? now,
      updatedAt: now,
    );
  }

  // ---------------- form widgets ----------------

  Widget _typeSelector() => Wrap(
        spacing: 6,
        runSpacing: 6,
        children: <Widget>[
          for (final TravelDocType t in TravelDocType.values)
            ChoiceChip(
              label: Text('${t.emoji} ${t.label}',
                  style: const TextStyle(fontSize: 12)),
              selected: _type == t,
              onSelected: (bool v) => setState(() => _type = v ? t : _type),
            ),
        ],
      );

  Widget _section(String label) => Padding(
        padding: const EdgeInsets.only(top: 18, bottom: 6),
        child: Text(label, style: Theme.of(context).textTheme.titleSmall),
      );

  Widget _field(TextEditingController ctrl, String label,
          {int maxLines = 1, String? hint, IconData? icon}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextField(
          controller: ctrl,
          maxLines: maxLines,
          decoration: InputDecoration(
            labelText: label,
            hintText: hint,
            prefixIcon:
                icon == null ? null : Icon(icon, size: 18),
            isDense: true,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
      );

  Widget _dateField(String label, DateTime? value, VoidCallback onPick,
          {IconData icon = Icons.event, VoidCallback? onClear}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onPick,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
            decoration: BoxDecoration(
              border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: <Widget>[
                Icon(icon, size: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    value == null
                        ? label
                        : '$label — ${DateFormat('dd MMM yyyy').format(value)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 13.5,
                        color: value == null
                            ? Theme.of(context).hintColor
                            : Theme.of(context).textTheme.bodyMedium?.color),
                  ),
                ),
                if (onClear != null)
                  GestureDetector(
                    onTap: onClear,
                    child: const Icon(Icons.close, size: 16),
                  ),
              ],
            ),
          ),
        ),
      );

  Widget _dateO(String label, DateTime? value, void Function(DateTime?) set,
          {IconData icon = Icons.event}) =>
      _dateField(label, value,
          () => _pickDate((DateTime d) => setState(() => set(d))),
          icon: icon,
          onClear: value == null
              ? null
              : () => setState(() => set(null)));

  Widget _datetime(String label, DateTime? value, void Function(DateTime?) set) =>
      _dateField(label, value,
          () => _pickDateTime((DateTime d) => setState(() => set(d))),
          icon: Icons.schedule,
          onClear: value == null
              ? null
              : () => setState(() => set(null)));

  Widget _tripSelector() {
    final List<TripPlan> trips = _c.tripPlanStore.plans;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: DropdownButtonFormField<String?>(
        value: _tripId,
        isDense: true,
        decoration: InputDecoration(
          labelText: 'Link to trip (optional)',
          prefixIcon: const Icon(Icons.luggage),
          isDense: true,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          helperText: trips.isEmpty
              ? 'No saved trips yet — you can add this document without a trip.'
              : 'Only a reference is stored; trip data is not duplicated.',
          helperMaxLines: 2,
        ),
        items: <DropdownMenuItem<String?>>[
          const DropdownMenuItem<String?>(
              value: null, child: Text('No trip', style: TextStyle(fontSize: 13))),
          for (final TripPlan t in trips)
            DropdownMenuItem<String?>(
                value: t.id,
                child: Text(
                    '${t.destination} — ${DateFormat('dd MMM').format(t.startDate)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13))),
        ],
        onChanged: (String? v) => setState(() => _tripId = v),
      ),
    );
  }

  Widget _fileSection() {
    final bool hasExistingFile = _existing?.fileUrl != null;
    return Card(
      margin: const EdgeInsets.only(bottom: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(children: <Widget>[
              const Icon(Icons.attach_file, size: 18),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _file != null
                      ? '${_file!.name} (ready to upload)'
                      : hasExistingFile
                          ? 'Attached: ${_existing!.fileName ?? 'file'}'
                          : 'Attach a file (PDF, JPG or PNG) — optional',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5),
                ),
              ),
            ]),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                OutlinedButton.icon(
                  onPressed: _uploadProgress == null
                      ? () => _pickFile(pdf: false)
                      : null,
                  icon: const Icon(Icons.image, size: 18),
                  label: const Text('Image', style: TextStyle(fontSize: 12.5)),
                ),
                OutlinedButton.icon(
                  onPressed: _uploadProgress == null
                      ? () => _pickFile(pdf: true)
                      : null,
                  icon: const Icon(Icons.picture_as_pdf, size: 18),
                  label: const Text('PDF', style: TextStyle(fontSize: 12.5)),
                ),
                if (_file != null)
                  TextButton(
                    onPressed: () => setState(() => _file = null),
                    child: const Text('Remove chosen file',
                        style: TextStyle(fontSize: 12.5)),
                  ),
              ],
            ),
            if (_file != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                    'Images are automatically resized/compressed for upload '
                    'while staying readable. Maximum size 10 MB.',
                    style: Theme.of(context).textTheme.bodySmall),
              ),
          ],
        ),
      ),
    );
  }

  // ---------------- per-type fields (all optional) ----------------

  List<Widget> _typeFields() => switch (_type) {
        TravelDocType.passport ||
        TravelDocType.visa ||
        TravelDocType.idProof =>
          <Widget>[
            _section('Document details'),
            _field(_docNumber, 'Document number (optional)'),
            _field(_issuer, 'Issued by (optional)',
                hint: 'e.g. Passport office / consulate'),
            _dateO('Issue date', _issueDate, (DateTime? v) => _issueDate = v),
            _dateO('Expiry date', _expiryDate, (DateTime? v) => _expiryDate = v,
                icon: Icons.timer_outlined),
          ],
        TravelDocType.flightTicket => <Widget>[
            _section('Flight details'),
            _field(_airline, 'Airline (optional)'),
            _field(_flightNumber, 'Flight number (optional)', hint: 'e.g. AI-806'),
            _field(_pnr, 'PNR (optional)'),
            _field(_depAirport, 'From — airport / city (optional)'),
            _field(_arrAirport, 'To — airport / city (optional)'),
            _datetime('Departure date & time', _departureDateTime,
                (DateTime? v) => _departureDateTime = v),
            _datetime('Arrival date & time', _arrivalDateTime,
                (DateTime? v) => _arrivalDateTime = v),
            _field(_terminal, 'Terminal (optional)'),
            _field(_seat, 'Seat (optional)'),
            _field(_bookingRef, 'Booking reference (optional)'),
            _field(_issuer, 'Booked with (optional)'),
          ],
        TravelDocType.trainTicket ||
        TravelDocType.busTicket =>
          <Widget>[
            _section('${_type == TravelDocType.trainTicket ? 'Train' : 'Bus'} details'),
            _field(_operator, 'Operator (optional)', hint: 'e.g. IRCTC / RedBus operator'),
            _field(_pnr, 'PNR / booking ID (optional)'),
            _field(_depLocation, 'From — station / stop (optional)'),
            _field(_arrLocation, 'To — station / stop (optional)'),
            _datetime('Departure date & time', _departureDateTime,
                (DateTime? v) => _departureDateTime = v),
            _datetime('Arrival date & time', _arrivalDateTime,
                (DateTime? v) => _arrivalDateTime = v),
            _field(_seat, 'Seat / coach (optional)'),
            _field(_bookingRef, 'Booking reference (optional)'),
          ],
        TravelDocType.hotelBooking => <Widget>[
            _section('Stay details'),
            _field(_hotelName, 'Hotel name (optional)'),
            _field(_bookingRef, 'Booking ID (optional)'),
            _datetime('Check-in', _checkInDateTime,
                (DateTime? v) => _checkInDateTime = v),
            _datetime('Check-out', _checkOutDateTime,
                (DateTime? v) => _checkOutDateTime = v),
            _field(_address, 'Address (optional)'),
            _field(_contact, 'Contact (optional)'),
            _field(_issuer, 'Booked with (optional)'),
          ],
        TravelDocType.cabRental => <Widget>[
            _section('Cab / car rental details'),
            _field(_operator, 'Operator (optional)'),
            _field(_bookingRef, 'Booking ID (optional)'),
            _field(_depLocation, 'Pickup location (optional)'),
            _dateO('Start date', _startDate, (DateTime? v) => _startDate = v),
            _dateO('End date', _endDate, (DateTime? v) => _endDate = v),
          ],
        TravelDocType.activityTicket => <Widget>[
            _section('Activity / event details'),
            _field(_provider, 'Provider (optional)'),
            _field(_bookingRef, 'Booking ID (optional)'),
            _field(_venue, 'Venue (optional)'),
            _datetime('Event date & time', _eventDateTime,
                (DateTime? v) => _eventDateTime = v),
            _field(_location, 'Location (optional)'),
          ],
        TravelDocType.travelInsurance => <Widget>[
            _section('Policy details'),
            _field(_provider, 'Insurer (optional)'),
            _field(_docNumber, 'Policy number (optional)'),
            _dateO('Issue date', _issueDate, (DateTime? v) => _issueDate = v),
            _dateO('Expiry date', _expiryDate, (DateTime? v) => _expiryDate = v,
                icon: Icons.timer_outlined),
          ],
        TravelDocType.other => <Widget>[
            _section('Details'),
            _field(_docNumber, 'Document / reference number (optional)'),
            _field(_issuer, 'Issuer / provider (optional)'),
            _dateO('Issue date', _issueDate, (DateTime? v) => _issueDate = v),
            _dateO('Expiry date', _expiryDate, (DateTime? v) => _expiryDate = v,
                icon: Icons.timer_outlined),
            _dateO('Travel date', _travelDate, (DateTime? v) => _travelDate = v),
          ],
      };
}
