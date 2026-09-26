import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/state/app_container.dart';
import '../../../core/widgets/app_card.dart';
import '../journey_operations_models.dart';

class JourneyOperationsScreen extends StatefulWidget {
  const JourneyOperationsScreen({super.key});

  @override
  State<JourneyOperationsScreen> createState() =>
      _JourneyOperationsScreenState();
}

class _JourneyOperationsScreenState extends State<JourneyOperationsScreen> {
  StreamSubscription<List<JourneyOperation>>? _subscription;
  List<JourneyOperation> _items = const <JourneyOperation>[];
  Map<JourneyToolKind, List<JourneyOperation>> _itemsByKind =
      const <JourneyToolKind, List<JourneyOperation>>{};
  JourneyToolKind? _selected;
  bool _loading = true;
  bool _showOpenOnly = false;
  String? _error;
  String _query = '';
  String _toolQuery = '';

  AppContainer get _container => AppScope.of(context);
  String get _uid => _container.currentUid();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_subscription != null) return;
    _subscription = _container.journeyOperations.watch(_uid).listen(
      (List<JourneyOperation> items) {
        if (!mounted) return;
        final Map<JourneyToolKind, List<JourneyOperation>> indexed =
            _indexByKind(items);
        setState(() {
          _items = items;
          _itemsByKind = indexed;
          _loading = false;
          _error = null;
        });
      },
      onError: (Object error) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = error.toString().contains('permission-denied')
              ? 'Journey Operations could not open cloud sync. Restart the screen to use the private on-device copy.'
              : 'Could not sync your journey operations. Check the connection and retry.';
        });
      },
    );
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  static Map<JourneyToolKind, List<JourneyOperation>> _indexByKind(
    List<JourneyOperation> items,
  ) {
    final Map<JourneyToolKind, List<JourneyOperation>> indexed =
        <JourneyToolKind, List<JourneyOperation>>{};
    for (final JourneyOperation item in items) {
      (indexed[item.kind] ??= <JourneyOperation>[]).add(item);
    }
    return indexed;
  }

  List<JourneyOperation> _forKind(JourneyToolKind kind) =>
      _itemsByKind[kind] ?? const <JourneyOperation>[];

  List<JourneyToolDefinition> get _visibleToolDefinitions {
    final String query = _toolQuery.trim().toLowerCase();
    if (query.isEmpty) return journeyToolDefinitions;
    return journeyToolDefinitions
        .where((JourneyToolDefinition definition) =>
            '${definition.title} ${definition.description}'
                .toLowerCase()
                .contains(query))
        .toList(growable: false);
  }

  List<JourneyOperation> get _visibleItems {
    final JourneyToolKind? selected = _selected;
    if (selected == null) return const <JourneyOperation>[];
    final String query = _query.trim().toLowerCase();
    return _forKind(selected).where((JourneyOperation item) {
      if (_showOpenOnly && item.completed) return false;
      if (query.isEmpty) return true;
      return '${item.title} ${item.detail} ${item.extra}'
          .toLowerCase()
          .contains(query);
    }).toList(growable: false);
  }

  Future<void> _edit(
    JourneyToolDefinition definition, [
    JourneyOperation? existing,
  ]) async {
    final TextEditingController title =
        TextEditingController(text: existing?.title);
    final TextEditingController detail =
        TextEditingController(text: existing?.detail);
    final TextEditingController extra =
        TextEditingController(text: existing?.extra);
    final bool? save = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text(existing == null
            ? 'Add to ${definition.title}'
            : 'Edit ${definition.title}'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextField(
                controller: title,
                autofocus: true,
                maxLength: 160,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  labelText: definition.primaryLabel,
                  prefixIcon: Icon(definition.icon),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: detail,
                minLines: definition.kind == JourneyToolKind.journal ? 4 : 1,
                maxLines: definition.kind == JourneyToolKind.journal ? 8 : 3,
                maxLength: 2000,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(labelText: definition.detailLabel),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: extra,
                maxLines: 2,
                maxLength: 500,
                keyboardType: definition.extraIsPhone
                    ? TextInputType.phone
                    : TextInputType.text,
                decoration: InputDecoration(labelText: definition.extraLabel),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (title.text.trim().isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('${definition.primaryLabel} is required.')),
                );
                return;
              }
              Navigator.pop(dialogContext, true);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    final String titleValue = title.text;
    final String detailValue = detail.text;
    final String extraValue = extra.text;
    title.dispose();
    detail.dispose();
    extra.dispose();
    if (save != true || !mounted) return;
    try {
      await _container.journeyOperations.save(
        uid: _uid,
        kind: definition.kind,
        title: titleValue,
        detail: detailValue,
        extra: extraValue,
        existing: existing,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Saved and synced securely.')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Save failed. Nothing was reported as synced.')),
        );
      }
    }
  }

  Future<void> _toggle(JourneyOperation item, bool value) async {
    try {
      await _container.journeyOperations.setCompleted(
        uid: _uid,
        item: item,
        completed: value,
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not update this item.')),
        );
      }
    }
  }

  Future<void> _delete(JourneyOperation item) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Delete this item?'),
        content: Text('“${item.title}” will be removed from your account.'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _container.journeyOperations.delete(_uid, item.id);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Delete failed. Please retry.')),
        );
      }
    }
  }

  Future<void> _call(String rawNumber) async {
    final String number = rawNumber.replaceAll(RegExp(r'[^0-9+]'), '');
    bool opened = false;
    if (number.isNotEmpty) {
      try {
        opened = await launchUrl(
          Uri(scheme: 'tel', path: number),
          mode: LaunchMode.externalApplication,
        );
      } catch (_) {}
    }
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No phone app could open this number.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final JourneyToolKind? selected = _selected;
    final JourneyToolDefinition? definition =
        selected == null ? null : definitionFor(selected);
    return Scaffold(
      appBar: AppBar(
        leading: selected == null
            ? null
            : IconButton(
                tooltip: 'All tools',
                onPressed: () => setState(() {
                  _selected = null;
                  _query = '';
                }),
                icon: const Icon(Icons.arrow_back),
              ),
        title: Text(definition?.title ?? 'Journey Operations'),
        actions: <Widget>[
          if (definition != null)
            IconButton(
              tooltip: 'Add item',
              onPressed: () => _edit(definition),
              icon: const Icon(Icons.add_circle_outline),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _ErrorPanel(message: _error!)
              : definition == null
                  ? _buildDashboard()
                  : _buildTool(definition),
      floatingActionButton: definition == null
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _edit(definition),
              icon: const Icon(Icons.add),
              label: const Text('Add'),
            ),
    );
  }

  Widget _buildDashboard() => LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final int columns = constraints.maxWidth >= 700 ? 3 : 2;
          final List<JourneyToolDefinition> definitions =
              _visibleToolDefinitions;
          return CustomScrollView(
            slivers: <Widget>[
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
                sliver: SliverToBoxAdapter(
                  child: AppCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text('${journeyToolDefinitions.length} synced travel tools',
                            style: Theme.of(context).textTheme.headlineSmall),
                        const SizedBox(height: 8),
                        const Text(
                          'Organise documents, transport, health, groups, stays and practical trip details. '
                          'Every saved item is private to your signed-in account.',
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: <Widget>[
                            const Icon(Icons.cloud_done_outlined, size: 18),
                            const SizedBox(width: 8),
                            Text('${_items.length} synced items'),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                sliver: SliverToBoxAdapter(
                  child: TextField(
                    onChanged: (String value) =>
                        setState(() => _toolQuery = value),
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: 'Find a travel tool',
                    ),
                  ),
                ),
              ),
              if (definitions.isEmpty)
                const SliverPadding(
                  padding: EdgeInsets.all(24),
                  sliver: SliverToBoxAdapter(
                    child: Center(child: Text('No travel tool matches that search.')),
                  ),
                ),
              // A real sliver grid lazily builds visible cards. The previous
              // shrink-wrapped nested GridView eagerly laid out every tool,
              // which became costly as the operations suite grew.
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
                sliver: SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                    childAspectRatio: columns == 3 ? 1.35 : 0.95,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (BuildContext context, int index) {
                      final JourneyToolDefinition item = definitions[index];
                      final List<JourneyOperation> records = _forKind(item.kind);
                      final int completed = records
                          .where((JourneyOperation record) => record.completed)
                          .length;
                      return AppCard(
                        padding: const EdgeInsets.all(14),
                        onTap: () => setState(() => _selected = item.kind),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Icon(item.icon,
                                color: Theme.of(context).colorScheme.primary),
                            const Spacer(),
                            Text(item.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleSmall),
                            const SizedBox(height: 5),
                            Text(item.description,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall),
                            const Spacer(),
                            Text(item.canComplete && records.isNotEmpty
                                ? '$completed/${records.length} complete'
                                : '${records.length} saved'),
                          ],
                        ),
                      );
                    },
                    childCount: definitions.length,
                  ),
                ),
              ),
            ],
          );
        },
      );

  Widget _buildTool(JourneyToolDefinition definition) {
    final List<JourneyOperation> visible = _visibleItems;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
      children: <Widget>[
        AppCard(
          child: Row(
            children: <Widget>[
              Icon(definition.icon,
                  size: 34, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 14),
              Expanded(child: Text(definition.description)),
            ],
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          onChanged: (String value) => setState(() => _query = value),
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search),
            hintText: 'Search saved items',
          ),
        ),
        if (definition.canComplete)
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Show open items only'),
            value: _showOpenOnly,
            onChanged: (bool value) => setState(() => _showOpenOnly = value),
          ),
        const SizedBox(height: 6),
        if (visible.isEmpty)
          AppCard(
            child: Column(
              children: <Widget>[
                Icon(definition.icon, size: 42),
                const SizedBox(height: 12),
                Text(
                  _query.isEmpty
                      ? 'No items saved yet.'
                      : 'No item matches your search.',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                if (_query.isEmpty)
                  FilledButton.icon(
                    onPressed: () => _edit(definition),
                    icon: const Icon(Icons.add),
                    label: const Text('Add first item'),
                  ),
              ],
            ),
          )
        else
          ...visible.map(
            (JourneyOperation item) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: AppCard(
                padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    if (definition.canComplete)
                      Checkbox.adaptive(
                        value: item.completed,
                        onChanged: (bool? value) =>
                            _toggle(item, value ?? false),
                      )
                    else
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Icon(definition.icon, size: 22),
                      ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              item.title,
                              style: Theme.of(context)
                                  .textTheme
                                  .titleMedium
                                  ?.copyWith(
                                    decoration: item.completed
                                        ? TextDecoration.lineThrough
                                        : null,
                                  ),
                            ),
                            if (item.detail.isNotEmpty) ...<Widget>[
                              const SizedBox(height: 4),
                              Text(item.detail),
                            ],
                            if (item.extra.isNotEmpty) ...<Widget>[
                              const SizedBox(height: 5),
                              Text(item.extra,
                                  style: Theme.of(context).textTheme.bodySmall),
                            ],
                            if (definition.extraIsPhone &&
                                item.extra.isNotEmpty) ...<Widget>[
                              const SizedBox(height: 6),
                              TextButton.icon(
                                onPressed: () => _call(item.extra),
                                icon: const Icon(Icons.call_outlined, size: 18),
                                label: const Text('Call'),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    PopupMenuButton<String>(
                      onSelected: (String action) {
                        if (action == 'edit') {
                          _edit(definition, item);
                        } else {
                          _delete(item);
                        }
                      },
                      itemBuilder: (BuildContext context) =>
                          const <PopupMenuEntry<String>>[
                        PopupMenuItem<String>(
                          value: 'edit',
                          child: Text('Edit'),
                        ),
                        PopupMenuItem<String>(
                          value: 'delete',
                          child: Text('Delete'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: AppCard(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Icon(Icons.cloud_off_outlined, size: 44),
                const SizedBox(height: 12),
                Text(message, textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
      );
}
