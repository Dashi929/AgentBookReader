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

  @override
  String get language => 'Language';

  @override
  String get followSystem => 'Follow system';

  @override
  String get editTextLayer => 'Edit text layer';

  @override
  String get selectText => 'Select text';

  @override
  String get continuousMode => 'Continuous';

  @override
  String get singlePageMode => 'Single page';

  @override
  String get saveAs => 'Save as';

  @override
  String get overwrite => 'Overwrite';

  @override
  String get discardChanges => 'Discard changes';

  @override
  String get continueEditing => 'Keep editing';

  @override
  String get unsavedTitle => 'Unsaved changes';

  @override
  String get exitSaveOffice =>
      'Edits apply to the text layer (Agent/translate/details).\nOverwrite = save to in-app cache permanently; Save as = export a Markdown file.';

  @override
  String get exitSaveText =>
      'Overwrite = write back to the original file (a .bak backup is made); Save as = export a new file.';

  @override
  String get pageTextTitle => 'Page text (long-press to select)';

  @override
  String get copySelected => 'Copy selection';

  @override
  String get translateSelected => 'Translate selection';

  @override
  String get noPageText => '(No selectable text on this page)';

  @override
  String get editCacheSaved =>
      'Saved to edit cache; choose save/overwrite on exit';

  @override
  String get readingProgress => 'Reading progress';

  @override
  String get readingSettings => 'Reading settings';

  @override
  String get search => 'Search';

  @override
  String get brightness => 'Brightness';

  @override
  String get lineSpacing => 'Line spacing';

  @override
  String get paraSpacing => 'Paragraph spacing';

  @override
  String get pageMargin => 'Page margin';

  @override
  String get jumpToPage => 'Jump to page';

  @override
  String get keepAwake => 'Keep screen on';

  @override
  String get immersiveMode => 'Immersive (hide status bar)';

  @override
  String get searchHint => 'Search in book…';

  @override
  String get noResults => 'No results';

  @override
  String get searchIn => 'Results';

  @override
  String get theme => 'Theme';

  @override
  String get fontSize => 'Font size';
}
