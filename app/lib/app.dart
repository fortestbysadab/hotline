import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'core/network/relay_api.dart';
import 'core/storage/local_store.dart';
import 'features/invite/invite_entry_screen.dart';
import 'features/shell/client_home.dart';
import 'features/shell/owner_home.dart';
import 'shared/theme.dart';

/// Single bootstrap for both flavors. Wires storage, relay API and state,
/// then routes to the flavor's first screen.
Future<void> runHotlineApp(AppFlavor flavor) async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = await LocalStore.init();
  final state = HotlineAppState(
    flavor: flavor,
    store: store,
    api: RelayApi(),
  );
  // Boot runs async so the first frame paints instantly (splash).
  state.boot();

  runApp(
    MultiProvider(
      providers: [
        Provider<AppFlavor>.value(value: flavor),
        Provider<LocalStore>.value(value: store),
        ChangeNotifierProvider<HotlineAppState>.value(value: state),
      ],
      child: HotlineApp(flavor: flavor),
    ),
  );
}

class HotlineApp extends StatelessWidget {
  const HotlineApp({super.key, required this.flavor});

  final AppFlavor flavor;

  @override
  Widget build(BuildContext context) {
    final title = flavor == AppFlavor.client ? 'Hotline' : 'Hotline Command';
    return MaterialApp(
      title: title,
      debugShowCheckedModeBanner: false,
      theme: HotlineTheme.dark(),
      home: _HomeGate(flavor: flavor),
    );
  }
}

class _HomeGate extends StatelessWidget {
  const _HomeGate({required this.flavor});

  final AppFlavor flavor;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<HotlineAppState>();
    if (!state.booted) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (flavor == AppFlavor.client) {
      // Paired → straight into the hotline; otherwise invite entry.
      return state.store.myPairing != null
          ? const ClientHome()
          : const InviteEntryScreen();
    }
    return const OwnerHome();
  }
}
