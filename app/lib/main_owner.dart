import 'app.dart';
import 'app_state.dart';

/// App B — "The Hub Experience": the Owner's command center over every
/// paired client. Build with:
///   flutter run --flavor owner -t lib/main_owner.dart
Future<void> main() async {
  await runHotlineApp(AppFlavor.owner);
}
