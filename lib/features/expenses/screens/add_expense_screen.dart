import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import '../../../core/state/app_container.dart';
import '../../../core/theme/app_theme.dart';
import '../expense_math.dart';
import '../expense_models.dart';
import '../expense_repository.dart';

/// Add Expense — amount + category is enough to save; everything else is
/// optional. Receipt photo is compressed at pick time and uploaded to
/// receipts/{uid}/{expenseId}.jpg; if the upload fails the user is asked —
/// the expense is NEVER saved with a fake receipt URL and never lost.
class AddExpenseScreen extends StatefulWidget {
  const AddExpenseScreen({super.key, this.expense, this.expenseId});

  final Expense? expense; // when editing
  final String? expenseId;

  bool get isEdit => expense != null;

  @override
  State<AddExpenseScreen> createState() => _AddExpenseScreenState();
}

class _AddExpenseScreenState extends State<AddExpenseScreen> {
  AppContainer get _c => AppScope.of(context);
  ExpenseRepository get _repo => _c.expenseRepository;

  final TextEditingController _amount = TextEditingController();
  final TextEditingController _merchant = TextEditingController();
  final TextEditingController _notes = TextEditingController();
  final List<TextEditingController> _splitNames = <TextEditingController>[];
  final List<TextEditingController> _splitAmounts = <TextEditingController>[];

  String _category = 'food';
  String _currency = 'INR';
  DateTime _when = DateTime.now();
  String? _tripId;
  String? _payment;
  String? _receiptPath; // local picked file (upload after save/now)
  bool _saving = false;
  bool _splitOn = false;
  String _splitMode = 'equal';

  @override
  void initState() {
    super.initState();
    final Expense? e = widget.expense;
    if (e != null) {
      _amount.text = e.amount.toStringAsFixed(2);
      _merchant.text = e.merchant;
      _notes.text = e.notes ?? '';
      _category = e.category;
      _currency = e.currency;
      _when = e.expenseDate;
      _tripId = e.tripId;
      _payment = e.paymentMethod;
      _receiptPath = e.receiptUrl; // existing remote url shown as attached
      _splitOn = e.splits.isNotEmpty;
      _splitMode = 'custom';
      for (final SplitParticipant p in e.splits) {
        final TextEditingController n = TextEditingController(text: p.name);
        final TextEditingController a =
            TextEditingController(text: p.amount.toStringAsFixed(2));
        _splitNames.add(n);
        _splitAmounts.add(a);
      }
    } else {
      // Auto-associate with the active local trip when one exists.
      final String? uid = _c.authRepository.currentUser?.uid;
      if (uid != null) {
        _c.tripPlanStore.loadFor(uid).catchError((Object _) {});
      }
      _tripId = _c.tripPlanStore.active?.id;
    }
    if (_splitNames.isEmpty && _splitOn) _addSplitRow();
  }

  @override
  void dispose() {
    _amount.dispose();
    _merchant.dispose();
    _notes.dispose();
    for (final TextEditingController c in <TextEditingController>[
      ..._splitNames,
      ..._splitAmounts
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _addSplitRow() {
    setState(() {
      _splitNames.add(TextEditingController());
      _splitAmounts.add(TextEditingController());
    });
  }

  Future<void> _save() async {
    final double? amount = double.tryParse(_amount.text.trim());
    if (amount == null || amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enter a valid amount.')));
      return;
    }
    setState(() => _saving = true);

    // Optional location (only if permission already granted).
    final ({double? lat, double? lng, String? name})? place =
        await _repo.currentPlace(_c.locationService);
    if (!mounted) return;

    // Splits (validated BEFORE saving).
    List<SplitParticipant> splits = const <SplitParticipant>[];
    if (_splitOn) {
      if (_splitMode == 'equal') {
        final List<String> names = <String>[
          for (final TextEditingController c in _splitNames) c.text.trim(),
        ];
        splits = ExpenseMath.equalSplit(
            amount: amount,
            names: names.where((String n) => n.isNotEmpty).toList(),
            selfName: _c.authRepository.currentUser?.displayName ?? 'Me');
      } else {
        splits = <SplitParticipant>[
          for (int i = 0; i < _splitNames.length; i++)
            if (_splitNames[i].text.trim().isNotEmpty)
              SplitParticipant(
                name: _splitNames[i].text.trim(),
                amount: double.tryParse(_splitAmounts[i].text.trim()) ?? 0,
                isSelf: i == 0,
              ),
        ];
      }
      final String? err = ExpenseMath.validateSplit(amount, splits);
      if (err != null) {
        setState(() => _saving = false);
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(err)));
        return;
      }
    }

    final String uid = _c.authRepository.currentUser?.uid ?? '';
    if (widget.isEdit && widget.expense != null) {
      await _repo.updateExpense(widget.expense!.copyWith(
        amount: amount,
        currency: _currency,
        category: _category,
        merchant: _merchant.text.trim(),
        notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
        clearNotes: _notes.text.trim().isEmpty,
        expenseDate: _when,
        tripId: _tripId,
        clearTrip: _tripId == null,
        paymentMethod: _payment,
        clearPayment: _payment == null,
        splits: splits,
        updatedAt: DateTime.now(),
      ));
      if (mounted) Navigator.pop(context);
      return;
    }

    final Expense e = Expense(
      id: _repo.newId(),
      userId: uid,
      amount: amount,
      currency: _currency,
      category: _category,
      merchant: _merchant.text.trim(),
      expenseDate: _when,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      tripId: _tripId,
      paymentMethod: _payment,
      notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
      latitude: place?.lat,
      longitude: place?.lng,
      locationName: place?.name,
      splits: splits,
      sync: ExpenseSync.local,
    );

    // Save first (local cache + queue — user data can never be lost), then
    // best-effort receipt upload. On failure the record has NO receipt URL
    // (never a fake one) and the user decides what to do.
    bool receiptFailed = false;
    final bool hasLocalReceipt =
        _receiptPath != null && !_receiptPath!.startsWith('http');
    try {
      await _repo.addExpense(
          e, receipt: hasLocalReceipt ? XFile(_receiptPath!) : null);
    } catch (_) {
      receiptFailed = true;
    }
    if (receiptFailed && mounted) {
      await showDialog<void>(
        context: context,
        builder: (BuildContext ctx) => AlertDialog(
          title: const Text('Receipt upload failed'),
          content: const Text(
              'The expense is saved on your phone and will sync — but the '
              'receipt could not be uploaded right now. You can attach it '
              'again later from the expense details.'),
          actions: <Widget>[
            FilledButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('OK — saved without receipt')),
          ],
        ),
      );
    }
    if (mounted) Navigator.pop(context);
  }

  Future<void> _pickReceipt({bool camera = true}) async {
    final XFile? picked = await _c.storageService.pickReceipt(
        source: camera ? ImageSource.camera : ImageSource.gallery);
    if (picked == null) return;
    setState(() {
      _receiptPath = picked.path;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: Text(widget.isEdit ? 'Edit expense' : 'Add expense')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                flex: 5,
                child: TextField(
                  controller: _amount,
                  autofocus: !widget.isEdit,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  style: const TextStyle(
                      fontSize: 28, fontWeight: FontWeight.w900),
                  decoration: InputDecoration(
                    prefixText: '₹ ',
                    hintText: '0',
                    labelText: 'Amount *',
                    border: const OutlineInputBorder(),
                    suffix: _currency == 'INR' ? null : Text(_currency),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: DropdownButtonFormField<String>(
                  value: _currency,
                  decoration:
                      const InputDecoration(labelText: 'Currency'),
                  items: <DropdownMenuItem<String>>[
                    for (final String c in Currencies.common)
                      DropdownMenuItem<String>(value: c, child: Text(c)),
                  ],
                  onChanged: (String? v) =>
                      setState(() => _currency = v ?? 'INR'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final ExpenseCategory c in ExpenseCategory.all)
                ChoiceChip(
                  label: Text('${c.emoji} ${c.label}'),
                  selected: _category == c.id,
                  onSelected: (bool _) => setState(() => _category = c.id),
                ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _merchant,
            decoration: const InputDecoration(
                labelText: 'Merchant / description (optional)',
                hintText: 'e.g. Sharma Tea Stall',
                border: OutlineInputBorder()),
          ),
          const SizedBox(height: 10),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.event),
            title: Text(DateFormat('EEE, d MMM yyyy, h:mm a').format(_when)),
            trailing: const Icon(Icons.edit, size: 16),
            onTap: () async {
              final DateTime? d = await showDatePicker(
                  context: context,
                  initialDate: _when,
                  firstDate: DateTime(2020),
                  lastDate: DateTime.now().add(const Duration(days: 1)));
              if (d == null) return;
              if (!mounted) return;
              final TimeOfDay? t = await showTimePicker(
                  context: context, initialTime: TimeOfDay.fromDateTime(_when));
              if (!mounted) return;

              setState(() {
                _when = DateTime(d.year, d.month, d.day,
                    t?.hour ?? _when.hour, t?.minute ?? _when.minute);
              });
            },
          ),
          DropdownButtonFormField<String?>(
            value: _tripId,
            decoration: const InputDecoration(
                labelText: 'Trip (optional)',
                border: OutlineInputBorder()),
            items: <DropdownMenuItem<String?>>[
              const DropdownMenuItem<String?>(
                  value: null, child: Text('No trip')),
              for (final trip in _c.tripPlanStore.plans)
                DropdownMenuItem<String?>(
                    value: trip.id, child: Text(trip.destination)),
            ],
            onChanged: (String? v) => setState(() => _tripId = v),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String?>(
            value: _payment,
            decoration: const InputDecoration(
                labelText: 'Payment method (optional)',
                border: OutlineInputBorder()),
            items: <DropdownMenuItem<String?>>[
              const DropdownMenuItem<String?>(
                  value: null, child: Text('—')),
              for (final String m in Expense.paymentMethods)
                DropdownMenuItem<String?>(value: m, child: Text(m)),
            ],
            onChanged: (String? v) => setState(() => _payment = v),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _notes,
            maxLines: 2,
            decoration: const InputDecoration(
                labelText: 'Notes (optional)', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 14),
          _receiptSection(),
          const SizedBox(height: 14),
          _splitSection(),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.check),
              label: Text(widget.isEdit ? 'Update expense' : 'Save expense'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _receiptSection() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(Icons.receipt, size: 18),
              const SizedBox(width: 8),
              const Expanded(
                  child: Text('Receipt photo (optional)',
                      style: TextStyle(fontWeight: FontWeight.w700))),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
              'Photo is compressed automatically and stored securely in your '
              'own cloud storage. (No OCR exists in the app — the amount '
              'stays exactly what you type.)',
              style: TextStyle(fontSize: 11)),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              OutlinedButton.icon(
                onPressed: () => _pickReceipt(camera: true),
                icon: const Icon(Icons.photo_camera, size: 16),
                label: const Text('Camera'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: () => _pickReceipt(camera: false),
                icon: const Icon(Icons.photo_library, size: 16),
                label: const Text('Gallery'),
              ),
              if (_receiptPath != null)
                IconButton(
                  tooltip: 'Remove receipt',
                  onPressed: () => setState(() => _receiptPath = null),
                  icon: const Icon(Icons.delete_outline),
                ),
            ],
          ),
          if (_receiptPath != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                _receiptPath!.startsWith('http')
                    ? 'Receipt attached (stored in your cloud)'
                    : 'Receipt ready — uploads when you save.',
                style: const TextStyle(fontSize: 12, color: AppTheme.success),
              ),
            ),
        ],
      ),
    );
  }

  Widget _splitSection() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Shared / split',
                style: TextStyle(fontWeight: FontWeight.w700)),
            subtitle: const Text(
                'Group travel — who owes what. Saved inside this expense.',
                style: TextStyle(fontSize: 11)),
            value: _splitOn,
            onChanged: (bool v) {
              setState(() {
                _splitOn = v;
                if (_splitOn && _splitNames.isEmpty) _addSplitRow();
              });
            },
          ),
          if (_splitOn) ...<Widget>[
            SegmentedButton<String>(
              segments: const <ButtonSegment<String>>[
                ButtonSegment<String>(value: 'equal', label: Text('Equal')),
                ButtonSegment<String>(value: 'custom', label: Text('Custom')),
              ],
              selected: <String>{_splitMode},
              onSelectionChanged: (Set<String> s) =>
                  setState(() => _splitMode = s.first),
            ),
            const SizedBox(height: 8),
            for (int i = 0; i < _splitNames.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: <Widget>[
                    Expanded(
                        flex: 5,
                        child: TextField(
                          controller: _splitNames[i],
                          decoration: InputDecoration(
                              hintText: i == 0 ? 'You' : 'Name ${i + 1}',
                              isDense: true,
                              border: const OutlineInputBorder()),
                        )),
                    const SizedBox(width: 8),
                    Expanded(
                        flex: 3,
                        child: TextField(
                          controller: _splitAmounts[i],
                          enabled: _splitMode == 'custom',
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          decoration: const InputDecoration(
                              hintText: '0', isDense: true,
                              border: OutlineInputBorder()),
                        )),
                    IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => setState(() {
                        _splitNames.removeAt(i).dispose();
                        _splitAmounts.removeAt(i).dispose();
                      }),
                    ),
                  ],
                ),
              ),
            TextButton.icon(
              onPressed: _addSplitRow,
              icon: const Icon(Icons.person_add_alt, size: 16),
              label: const Text('Add person'),
            ),
          ],
        ],
      ),
    );
  }
}
