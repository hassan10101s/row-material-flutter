/// The settings contract.
///
/// Implementation: `data/settings_repo.dart` (`SettingsRepo`).
///
/// ## Why a contract
///
/// `SettingsRepo` takes a `DatabaseHelper` and a `LocalSecret` in its
/// constructor, so naming it from a cubit drags the whole database and crypto
/// stack into the type graph of a file the architecture ratchet holds to
/// `domain/` only. That is what kept `general_settings_cubit.dart` and
/// `settings_screen.dart` as ratchet entries.
///
/// ## Why the surface is exactly six methods
///
/// Every method here is one a presentation file actually calls. Anything used
/// only inside the data layer - `ensureDefaults`, `getSetting`,
/// `readUsageExpiry` / `setUsageExpiry` - stays off the contract: the usage
/// expiry is sealed, so widening the contract to reach it would put a
/// ciphertext-format detail into the domain layer.
abstract interface class SettingsRepository {
  /// Value of one `settings` row, or null when the key is absent.
  Future<String?> getSettingValue(String key);

  /// Write settings rows, replacing any existing value for the key.
  Future<void> updateSettings(Map<String, String> updates);

  /// Stored logo file path, or null when no logo is set.
  Future<String?> getReportLogoPath();

  /// Stored logo as a data URI, or null when no logo is set.
  Future<String?> getReportLogoDataUri();

  /// Store the logo as both a path and a data URI, in one write.
  Future<void> setReportLogo(String path, String dataUri);

  /// Remove both halves of the logo.
  Future<void> clearReportLogo();
}