// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'AgentBookReader';

  @override
  String get library => 'Library';

  @override
  String get settings => 'Settings';

  @override
  String get reader => 'Reader';

  @override
  String get importFiles => 'Import files';

  @override
  String importFailed(String reason) {
    return 'Import failed: $reason';
  }

  @override
  String get agentPanel => 'Agent';

  @override
  String get agentAsk => 'Ask about this document…';

  @override
  String get agentWorkspaceSelect =>
      'Select documents to process (multi-select)';

  @override
  String get agentWorkspaceAsk =>
      'Ask the agent to work on the selected documents…';

  @override
  String get translate => 'Translate';

  @override
  String translateJobRunning(int done, int total) {
    return 'Translating $done/$total…';
  }

  @override
  String get originalText => 'Original';

  @override
  String get translatedText => 'Translation';

  @override
  String section(int n) {
    return 'Section $n';
  }

  @override
  String page(int n) {
    return 'Page $n';
  }

  @override
  String words(int count) {
    return '$count words';
  }

  @override
  String get confirm => 'Confirm';

  @override
  String get cancel => 'Cancel';

  @override
  String get llmBaseUrl => 'Base URL';

  @override
  String get llmApiKey => 'API Key';

  @override
  String get llmModel => 'Model';

  @override
  String get proposalTitle => 'Rewrite proposal';

  @override
  String get reject => 'Reject';

  @override
  String get apply => 'Apply';

  @override
  String get editSection => 'Edit section';

  @override
  String unTranslated(String title) {
    return '[This section is not translated yet] $title';
  }

  @override
  String get annotations => 'Annotations';

  @override
  String get export => 'Export';

  @override
  String get chapters => 'Chapters';

  @override
  String get writeBack => 'Write to original file (.bak)';

  @override
  String get originalFileUpdated => 'Original file backed up and updated';

  @override
  String get bookDetail => 'Book Details';

  @override
  String get author => 'Author';

  @override
  String get synopsis => 'Synopsis';

  @override
  String get preview => 'Preview';

  @override
  String get startReading => 'Start Reading';

  @override
  String get aiComplete => 'Complete with AI';

  @override
  String get unknownAuthor => 'Unknown author';

  @override
  String get aiCompleteDone => 'Metadata updated';

  @override
  String get noSynopsis => 'No synopsis yet — use \"Complete with AI\"';

  @override
  String continueReading(String page) {
    return 'Continue reading: $page';
  }
}
