/// User entity (features/auth/domain).
class User {
  final int? id;
  final String username;
  final String fullName;
  final String role;
  final bool isActive;
  final String? passwordHash;
  final String createdAt;

  const User({
    this.id,
    required this.username,
    required this.fullName,
    required this.role,
    this.isActive = true,
    this.passwordHash,
    required this.createdAt,
  });

  bool get isDeveloper => role == 'Developer';
  bool get canManageSettings =>
      role == 'Developer' || role == 'Admin';
  bool get canEditInspections =>
      role == 'Developer' || role == 'Admin' || role == 'Lab User';
  bool get canEditUsers => role == 'Developer';
  bool get canSeeSettings => role == 'Developer' || role == 'Admin';

  factory User.fromMap(Map<String, dynamic> map) => User(
        id: map['id'] as int?,
        username: '${map['username'] ?? ''}',
        fullName: '${map['full_name'] ?? ''}',
        role: '${map['role'] ?? 'Viewer'}',
        isActive: (map['is_active'] as num?)?.toInt() == 1,
        passwordHash: map['password_hash'] as String?,
        createdAt: '${map['created_at'] ?? ''}',
      );

  Map<String, dynamic> toMap({bool withId = true}) => {
        if (withId && id != null) 'id': id,
        'username': username,
        'full_name': fullName,
        'role': role,
        'is_active': isActive ? 1 : 0,
        if (passwordHash != null) 'password_hash': passwordHash,
        'created_at': createdAt,
      };
}

/// Session wrapper exposed to the UI.
class AppSession {
  final User? user;
  final bool needsAdminSetup;
  final bool needsSetup;
  const AppSession({
    this.user,
    this.needsAdminSetup = false,
    this.needsSetup = false,
  });

  bool get isAuthenticated => user != null;
}