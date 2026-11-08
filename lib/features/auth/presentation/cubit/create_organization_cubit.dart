import '../../../../app/auth_gate.dart';
import '../../../../core/constants/app_strings.dart';
import '../../../../core/state/app_cubit.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../domain/auth_repository.dart';
import '../../../organizations/domain/organization_repository.dart';
import 'create_organization_state.dart';

/// `noProfile` step of the state machine (plan §8.5): create a new organization
/// or claim an existing invitation.
class CreateOrganizationCubit extends AppCubit<CreateOrganizationState> {
  CreateOrganizationCubit({
    required this.auth,
    required this.organizations,
    required this.gate,
  }) : super(const CreateOrganizationState());

  final AuthRepository auth;
  final OrganizationRepository organizations;
  final AuthGate gate;

  void useInvite() => safeEmit(state.copyWith(mode: CreateMode.invite));

  void useCreate() => safeEmit(state.copyWith(mode: CreateMode.create));

  void setName(String value) =>
      safeEmit(state.copyWith(name: value, error: null));

  void setInviteCode(String value) =>
      safeEmit(state.copyWith(inviteCode: value, error: null));

  /// One-time probe of the Firebase e-mail verification flag. A False result
  /// shows the verification banner (the server refuses genesis for unverified
  /// addresses); a failure stays silent — the submit path reports precisely.
  Future<void> loadEmailVerified() async {
    if (state.emailVerified != null) return;
    try {
      safeEmit(
        state.copyWith(emailVerified: await auth.refreshEmailVerified()),
      );
    } on Object {
      // Unknown until the next probe; the banner stays hidden.
    }
  }

  /// Re-sends the verification link; the message lands on the banner.
  Future<void> resendVerificationEmail() async {
    if (state.verificationBusy) return;
    safeEmit(state.copyWith(verificationBusy: true, notice: null, error: null));
    try {
      await auth.sendEmailVerification();
      safeEmit(
        state.copyWith(
          verificationBusy: false,
          notice: AppText.t(
            'أُرسل رابط التوثيق من جديد — افتح بريدك واضغط الرابط.',
            'The verification link was sent again — open your inbox and click it.',
          ),
        ),
      );
    } on Object catch (e) {
      safeEmit(
        state.copyWith(verificationBusy: false, error: AppError.friendly(e)),
      );
    }
  }

  /// The user clicked the link and reports back: re-read the flag. When it
  /// flipped to verified, the banner disappears and creation may proceed.
  Future<void> refreshEmailVerified() async {
    if (state.verificationBusy) return;
    safeEmit(state.copyWith(verificationBusy: true, notice: null, error: null));
    try {
      final verified = await auth.refreshEmailVerified();
      safeEmit(
        state.copyWith(
          verificationBusy: false,
          emailVerified: verified,
          notice: verified
              ? null
              : AppText.t(
                  'لم نرصد التوثيق بعد — تأكد من فتح الرابط وانتظر بضع ثوان ثم أعد الفحص.',
                  'Not verified yet — make sure you opened the link, wait a few seconds, then check again.',
                ),
        ),
      );
    } on Object catch (e) {
      safeEmit(
        state.copyWith(verificationBusy: false, error: AppError.friendly(e)),
      );
    }
  }

  Future<bool> submit() async {
    final create = state.mode == CreateMode.create;
    if (create && state.name.trim().isEmpty) {
      safeEmit(
        state.copyWith(
          error: AppText.t('اسم الشركة مطلوب', 'Company name is required.'),
        ),
      );
      return false;
    }
    if (!create && state.inviteCode.trim().isEmpty) {
      safeEmit(
        state.copyWith(
          error: AppText.t('كود الشركة مطلوب', 'Company code is required.'),
        ),
      );
      return false;
    }
    // Single-company policy (§2): never attempt the remote write when the
    // current session is still bound (invited/pending/active). Sign-out alone
    // never unblocks this; only leaving does.
    if (create && auth.session.blocksNewCompany) {
      safeEmit(
        state.copyWith(
          error: AppText.t(
            'هذا الحساب مرتبط بشركة حالية. غادر الشركة الحالية أولًا لإنشاء شركة جديدة.',
            'This account is already linked to a company. Leave the current company first to create a new one.',
          ),
        ),
      );
      return false;
    }
    safeEmit(state.copyWith(busy: true, error: null));
    try {
      if (create) {
        await organizations.createOrganization(name: state.name);
      } else {
        await organizations.joinWithInvite(
          organizationId: state.inviteCode.trim(),
        );
      }
      // `resolveProfile` re-reads `users/{uid}` and binds the organization
      // database; the router then moves on (dashboard or waiting-activation).
      await auth.resolveProfile();
      gate.updated();
      safeEmit(state.copyWith(busy: false));
      return true;
    } on OrganizationFailure catch (e) {
      safeEmit(state.copyWith(busy: false, error: AppError.friendly(e)));
      return false;
    } on Object catch (e) {
      safeEmit(state.copyWith(busy: false, error: AppError.friendly(e)));
      return false;
    }
  }
}
