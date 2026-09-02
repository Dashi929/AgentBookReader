import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'agent/agent_settings.dart';
import 'infra/database.dart';
import 'l10n/app_localizations.dart';
import 'state/app_state.dart';
import 'ui/library_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await PrefsService.init();
  await AgentSettings.init();
  runApp(ProviderScope(
    overrides: [appDatabaseProvider.overrideWithValue(AppDatabase())],
    child: const AgentBookReaderApp(),
  ));
}

class AgentBookReaderApp extends StatelessWidget {
  const AgentBookReaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      onGenerateTitle: (context) => AppLocalizations.of(context)!.appTitle,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: const LibraryPage(),
    );
  }
}
