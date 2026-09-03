import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_ja.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('ja'),
    Locale('zh'),
    Locale('zh', 'TW'),
  ];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'AgentBookReader'**
  String get appTitle;

  /// No description provided for @library.
  ///
  /// In en, this message translates to:
  /// **'Library'**
  String get library;

  /// No description provided for @settings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settings;

  /// No description provided for @reader.
  ///
  /// In en, this message translates to:
  /// **'Reader'**
  String get reader;

  /// No description provided for @importFiles.
  ///
  /// In en, this message translates to:
  /// **'Import files'**
  String get importFiles;

  /// No description provided for @importFailed.
  ///
  /// In en, this message translates to:
  /// **'Import failed: {reason}'**
  String importFailed(String reason);

  /// No description provided for @agentPanel.
  ///
  /// In en, this message translates to:
  /// **'Agent'**
  String get agentPanel;

  /// No description provided for @agentAsk.
  ///
  /// In en, this message translates to:
  /// **'Ask about this document…'**
  String get agentAsk;

  /// No description provided for @agentWorkspaceSelect.
  ///
  /// In en, this message translates to:
  /// **'Select documents to process (multi-select)'**
  String get agentWorkspaceSelect;

  /// No description provided for @agentWorkspaceAsk.
  ///
  /// In en, this message translates to:
  /// **'Ask the agent to work on the selected documents…'**
  String get agentWorkspaceAsk;

  /// No description provided for @translate.
  ///
  /// In en, this message translates to:
  /// **'Translate'**
  String get translate;

  /// No description provided for @translateJobRunning.
  ///
  /// In en, this message translates to:
  /// **'Translating {done}/{total}…'**
  String translateJobRunning(int done, int total);

  /// No description provided for @originalText.
  ///
  /// In en, this message translates to:
  /// **'Original'**
  String get originalText;

  /// No description provided for @translatedText.
  ///
  /// In en, this message translates to:
  /// **'Translation'**
  String get translatedText;

  /// No description provided for @section.
  ///
  /// In en, this message translates to:
  /// **'Section {n}'**
  String section(int n);

  /// No description provided for @page.
  ///
  /// In en, this message translates to:
  /// **'Page {n}'**
  String page(int n);

  /// No description provided for @words.
  ///
  /// In en, this message translates to:
  /// **'{count} words'**
  String words(int count);

  /// No description provided for @confirm.
  ///
  /// In en, this message translates to:
  /// **'Confirm'**
  String get confirm;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @llmBaseUrl.
  ///
  /// In en, this message translates to:
  /// **'Base URL'**
  String get llmBaseUrl;

  /// No description provided for @llmApiKey.
  ///
  /// In en, this message translates to:
  /// **'API Key'**
  String get llmApiKey;

  /// No description provided for @llmModel.
  ///
  /// In en, this message translates to:
  /// **'Model'**
  String get llmModel;

  /// No description provided for @proposalTitle.
  ///
  /// In en, this message translates to:
  /// **'Rewrite proposal'**
  String get proposalTitle;

  /// No description provided for @reject.
  ///
  /// In en, this message translates to:
  /// **'Reject'**
  String get reject;

  /// No description provided for @apply.
  ///
  /// In en, this message translates to:
  /// **'Apply'**
  String get apply;

  /// No description provided for @editSection.
  ///
  /// In en, this message translates to:
  /// **'Edit section'**
  String get editSection;

  /// No description provided for @unTranslated.
  ///
  /// In en, this message translates to:
  /// **'[This section is not translated yet] {title}'**
  String unTranslated(String title);

  /// No description provided for @annotations.
  ///
  /// In en, this message translates to:
  /// **'Annotations'**
  String get annotations;

  /// No description provided for @export.
  ///
  /// In en, this message translates to:
  /// **'Export'**
  String get export;

  /// No description provided for @chapters.
  ///
  /// In en, this message translates to:
  /// **'Chapters'**
  String get chapters;

  /// No description provided for @writeBack.
  ///
  /// In en, this message translates to:
  /// **'Write to original file (.bak)'**
  String get writeBack;

  /// No description provided for @originalFileUpdated.
  ///
  /// In en, this message translates to:
  /// **'Original file backed up and updated'**
  String get originalFileUpdated;

  /// No description provided for @bookDetail.
  ///
  /// In en, this message translates to:
  /// **'Book Details'**
  String get bookDetail;

  /// No description provided for @author.
  ///
  /// In en, this message translates to:
  /// **'Author'**
  String get author;

  /// No description provided for @synopsis.
  ///
  /// In en, this message translates to:
  /// **'Synopsis'**
  String get synopsis;

  /// No description provided for @preview.
  ///
  /// In en, this message translates to:
  /// **'Preview'**
  String get preview;

  /// No description provided for @startReading.
  ///
  /// In en, this message translates to:
  /// **'Start Reading'**
  String get startReading;

  /// No description provided for @aiComplete.
  ///
  /// In en, this message translates to:
  /// **'Complete with AI'**
  String get aiComplete;

  /// No description provided for @unknownAuthor.
  ///
  /// In en, this message translates to:
  /// **'Unknown author'**
  String get unknownAuthor;

  /// No description provided for @aiCompleteDone.
  ///
  /// In en, this message translates to:
  /// **'Metadata updated'**
  String get aiCompleteDone;

  /// No description provided for @noSynopsis.
  ///
  /// In en, this message translates to:
  /// **'No synopsis yet — use \"Complete with AI\"'**
  String get noSynopsis;

  /// No description provided for @continueReading.
  ///
  /// In en, this message translates to:
  /// **'Continue reading: {page}'**
  String continueReading(String page);

  /// No description provided for @language.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get language;

  /// No description provided for @followSystem.
  ///
  /// In en, this message translates to:
  /// **'Follow system'**
  String get followSystem;

  /// No description provided for @editTextLayer.
  ///
  /// In en, this message translates to:
  /// **'Edit text layer'**
  String get editTextLayer;

  /// No description provided for @selectText.
  ///
  /// In en, this message translates to:
  /// **'Select text'**
  String get selectText;

  /// No description provided for @continuousMode.
  ///
  /// In en, this message translates to:
  /// **'Continuous'**
  String get continuousMode;

  /// No description provided for @singlePageMode.
  ///
  /// In en, this message translates to:
  /// **'Single page'**
  String get singlePageMode;

  /// No description provided for @saveAs.
  ///
  /// In en, this message translates to:
  /// **'Save as'**
  String get saveAs;

  /// No description provided for @overwrite.
  ///
  /// In en, this message translates to:
  /// **'Overwrite'**
  String get overwrite;

  /// No description provided for @discardChanges.
  ///
  /// In en, this message translates to:
  /// **'Discard changes'**
  String get discardChanges;

  /// No description provided for @continueEditing.
  ///
  /// In en, this message translates to:
  /// **'Keep editing'**
  String get continueEditing;

  /// No description provided for @unsavedTitle.
  ///
  /// In en, this message translates to:
  /// **'Unsaved changes'**
  String get unsavedTitle;

  /// No description provided for @exitSaveOffice.
  ///
  /// In en, this message translates to:
  /// **'Edits apply to the text layer (Agent/translate/details).\nOverwrite = save to in-app cache permanently; Save as = export a Markdown file.'**
  String get exitSaveOffice;

  /// No description provided for @exitSaveText.
  ///
  /// In en, this message translates to:
  /// **'Overwrite = write back to the original file (a .bak backup is made); Save as = export a new file.'**
  String get exitSaveText;

  /// No description provided for @pageTextTitle.
  ///
  /// In en, this message translates to:
  /// **'Page text (long-press to select)'**
  String get pageTextTitle;

  /// No description provided for @copySelected.
  ///
  /// In en, this message translates to:
  /// **'Copy selection'**
  String get copySelected;

  /// No description provided for @translateSelected.
  ///
  /// In en, this message translates to:
  /// **'Translate selection'**
  String get translateSelected;

  /// No description provided for @noPageText.
  ///
  /// In en, this message translates to:
  /// **'(No selectable text on this page)'**
  String get noPageText;

  /// No description provided for @editCacheSaved.
  ///
  /// In en, this message translates to:
  /// **'Saved to edit cache; choose save/overwrite on exit'**
  String get editCacheSaved;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'ja', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when language+country codes are specified.
  switch (locale.languageCode) {
    case 'zh':
      {
        switch (locale.countryCode) {
          case 'TW':
            return AppLocalizationsZhTw();
        }
        break;
      }
  }

  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'ja':
      return AppLocalizationsJa();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
