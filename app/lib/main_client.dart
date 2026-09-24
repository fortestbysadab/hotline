import 'app.dart';
import 'app_state.dart';

/// App A — "The Guest Experience": a client's private, direct hotline to the
/// Owner. Build with:
///   flutter run --flavor client -t lib/main_client.dart
Future<void> main() async {
  await runHotlineApp(AppFlavor.client);
}
