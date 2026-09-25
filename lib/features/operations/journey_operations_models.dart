import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

enum JourneyToolKind {
  medicine,
  luggage,
  taskBoard,
  contacts,
  connectivity,
  dietary,
  accessibility,
  souvenirs,
  journal,
  checkpoints,
  homeReadiness,
  localKnowledge,
}

@immutable
class JourneyToolDefinition {
  const JourneyToolDefinition({
    required this.kind,
    required this.title,
    required this.description,
    required this.icon,
    required this.primaryLabel,
    required this.detailLabel,
    required this.extraLabel,
    this.canComplete = false,
    this.completionLabel = 'Done',
    this.extraIsPhone = false,
  });

  final JourneyToolKind kind;
  final String title;
  final String description;
  final IconData icon;
  final String primaryLabel;
  final String detailLabel;
  final String extraLabel;
  final bool canComplete;
  final String completionLabel;
  final bool extraIsPhone;
}

const List<JourneyToolDefinition> journeyToolDefinitions =
    <JourneyToolDefinition>[
  JourneyToolDefinition(
    kind: JourneyToolKind.medicine,
    title: 'Medicine plan',
    description: 'Keep medicine, dosage and timing together.',
    icon: Icons.medication_outlined,
    primaryLabel: 'Medicine name',
    detailLabel: 'Dosage and instructions',
    extraLabel: 'Time / schedule',
    canComplete: true,
    completionLabel: 'Taken / packed',
  ),
  JourneyToolDefinition(
    kind: JourneyToolKind.luggage,
    title: 'Luggage inventory',
    description: 'Know which item is inside which bag.',
    icon: Icons.luggage_outlined,
    primaryLabel: 'Item',
    detailLabel: 'Bag or compartment',
    extraLabel: 'Quantity / identifying note',
    canComplete: true,
    completionLabel: 'Packed',
  ),
  JourneyToolDefinition(
    kind: JourneyToolKind.taskBoard,
    title: 'Shared task board',
    description: 'Assign preparation work and track completion.',
    icon: Icons.group_work_outlined,
    primaryLabel: 'Task',
    detailLabel: 'Assigned to',
    extraLabel: 'Due date or note',
    canComplete: true,
  ),
  JourneyToolDefinition(
    kind: JourneyToolKind.contacts,
    title: 'Travel contacts',
    description: 'Store callable hotel, guide and local contacts.',
    icon: Icons.contact_phone_outlined,
    primaryLabel: 'Contact name',
    detailLabel: 'Role / organisation',
    extraLabel: 'Phone number',
    extraIsPhone: true,
  ),
  JourneyToolDefinition(
    kind: JourneyToolKind.connectivity,
    title: 'Connectivity plan',
    description: 'Record SIM, roaming, Wi-Fi and support details.',
    icon: Icons.sim_card_outlined,
    primaryLabel: 'Provider or plan',
    detailLabel: 'Data / roaming details',
    extraLabel: 'Support or activation note',
    canComplete: true,
    completionLabel: 'Activated',
  ),
  JourneyToolDefinition(
    kind: JourneyToolKind.dietary,
    title: 'Diet and allergy card',
    description: 'Keep important food restrictions easy to show.',
    icon: Icons.restaurant_menu_outlined,
    primaryLabel: 'Restriction or allergy',
    detailLabel: 'Severity / safe alternative',
    extraLabel: 'Local-language note',
  ),
  JourneyToolDefinition(
    kind: JourneyToolKind.accessibility,
    title: 'Accessibility requests',
    description: 'Track assistance requested from travel providers.',
    icon: Icons.accessible_outlined,
    primaryLabel: 'Assistance needed',
    detailLabel: 'Provider / location',
    extraLabel: 'Confirmation reference or note',
    canComplete: true,
    completionLabel: 'Confirmed',
  ),
  JourneyToolDefinition(
    kind: JourneyToolKind.souvenirs,
    title: 'Gift and souvenir tracker',
    description: 'Plan recipients and budgets without duplicate buys.',
    icon: Icons.redeem_outlined,
    primaryLabel: 'Item or idea',
    detailLabel: 'For whom',
    extraLabel: 'Budget / shop note',
    canComplete: true,
    completionLabel: 'Bought',
  ),
  JourneyToolDefinition(
    kind: JourneyToolKind.journal,
    title: 'Trip journal',
    description: 'Save memories, observations and useful discoveries.',
    icon: Icons.auto_stories_outlined,
    primaryLabel: 'Entry title',
    detailLabel: 'Journal entry',
    extraLabel: 'Place / date note',
  ),
  JourneyToolDefinition(
    kind: JourneyToolKind.checkpoints,
    title: 'Checkpoint readiness',
    description: 'Track airport, station and border requirements.',
    icon: Icons.fact_check_outlined,
    primaryLabel: 'Checkpoint or requirement',
    detailLabel: 'Document / action needed',
    extraLabel: 'Terminal, deadline or note',
    canComplete: true,
    completionLabel: 'Ready',
  ),
  JourneyToolDefinition(
    kind: JourneyToolKind.homeReadiness,
    title: 'Home departure check',
    description: 'Secure utilities, keys, pets and deliveries.',
    icon: Icons.home_work_outlined,
    primaryLabel: 'Home task',
    detailLabel: 'Responsible person',
    extraLabel: 'Deadline / instruction',
    canComplete: true,
    completionLabel: 'Secured',
  ),
  JourneyToolDefinition(
    kind: JourneyToolKind.localKnowledge,
    title: 'Local knowledge notebook',
    description: 'Save verified customs, phrases and practical tips.',
    icon: Icons.psychology_alt_outlined,
    primaryLabel: 'Tip or local custom',
    detailLabel: 'Place / situation',
    extraLabel: 'Source / verification note',
  ),
];

JourneyToolDefinition definitionFor(JourneyToolKind kind) =>
    journeyToolDefinitions.firstWhere(
      (JourneyToolDefinition item) => item.kind == kind,
    );

@immutable
class JourneyOperation {
  const JourneyOperation({
    required this.id,
    required this.userId,
    required this.kind,
    required this.title,
    required this.detail,
    required this.extra,
    required this.completed,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String userId;
  final JourneyToolKind kind;
  final String title;
  final String detail;
  final String extra;
  final bool completed;
  final DateTime createdAt;
  final DateTime updatedAt;

  JourneyOperation copyWith({bool? completed}) => JourneyOperation(
        id: id,
        userId: userId,
        kind: kind,
        title: title,
        detail: detail,
        extra: extra,
        completed: completed ?? this.completed,
        createdAt: createdAt,
        updatedAt: DateTime.now(),
      );

  Map<String, dynamic> toFirestore() => <String, dynamic>{
        'id': id,
        'userId': userId,
        'kind': kind.name,
        'title': title,
        'detail': detail,
        'extra': extra,
        'completed': completed,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'updatedAt': updatedAt.millisecondsSinceEpoch,
      };

  static JourneyOperation fromFirestore(Map<String, dynamic> data) {
    final String kindName = (data['kind'] as String?) ?? '';
    return JourneyOperation(
      id: (data['id'] as String?) ?? '',
      userId: (data['userId'] as String?) ?? '',
      kind: JourneyToolKind.values.firstWhere(
        (JourneyToolKind kind) => kind.name == kindName,
        orElse: () => JourneyToolKind.taskBoard,
      ),
      title: (data['title'] as String?) ?? '',
      detail: (data['detail'] as String?) ?? '',
      extra: (data['extra'] as String?) ?? '',
      completed: (data['completed'] as bool?) ?? false,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        ((data['createdAt'] as num?) ?? 0).toInt(),
      ),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        ((data['updatedAt'] as num?) ?? 0).toInt(),
      ),
    );
  }
}
