/// Сотрудник с бейджем в разделе «Бейджи» (ADHOC-65): без номера - номер выдаёт сервер только
/// на печать.
class BadgeHolder {
  const BadgeHolder({
    required this.id,
    required this.fullName,
    required this.positionName,
    required this.isAdmin,
    required this.stored,
  });

  factory BadgeHolder.fromJson(Map<String, dynamic> json) => BadgeHolder(
    id: json['id'] as String,
    fullName: json['full_name'] as String? ?? '',
    positionName: json['position_name'] as String? ?? '',
    isAdmin: json['is_admin'] as bool? ?? false,
    stored: json['stored'] as bool? ?? false,
  );

  final String id;
  final String fullName;
  final String positionName;

  /// Системная должность «Администратор».
  final bool isAdmin;

  /// Номер сохранён на сервере - бейдж можно напечатать.
  final bool stored;
}

/// Бейдж к печати: 16 цифр и ФИО.
typedef BadgeNumber = ({String fullName, String number});
