/// Runtime settings shared by application coordinators and interaction UI.
///
/// The actual haptic/overlay implementation remains in `app_feedback.dart`;
/// this value keeps application code independent from Flutter widgets.
abstract final class AppInteractionFeedbackSettings {
  static bool hapticFeedbackEnabled = true;
}
