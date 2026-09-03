// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Japanese (`ja`).
class AppLocalizationsJa extends AppLocalizations {
  AppLocalizationsJa([String locale = 'ja']) : super(locale);

  @override
  String get appTitle => 'AgentBookReader';

  @override
  String get library => 'ライブラリ';

  @override
  String get settings => '設定';

  @override
  String get reader => 'リーダー';

  @override
  String get importFiles => 'ファイルをインポート';

  @override
  String importFailed(String reason) {
    return 'インポート失敗：$reason';
  }

  @override
  String get agentPanel => 'スマートアシスタント';

  @override
  String get agentAsk => 'この本についてアシスタントに質問…';

  @override
  String get agentWorkspaceSelect => '処理するドキュメントを選択（複数可）';

  @override
  String get agentWorkspaceAsk => '選択したドキュメントを Agent に処理させる…';

  @override
  String get translate => '翻訳';

  @override
  String translateJobRunning(int done, int total) {
    return '翻訳中 $done/$total…';
  }

  @override
  String get originalText => '原文';

  @override
  String get translatedText => '訳文';

  @override
  String section(int n) {
    return '第$nセクション';
  }

  @override
  String page(int n) {
    return '$n ページ';
  }

  @override
  String words(int count) {
    return '$count 文字';
  }

  @override
  String get confirm => '確認';

  @override
  String get cancel => 'キャンセル';

  @override
  String get llmBaseUrl => 'APIエンドポイント';

  @override
  String get llmApiKey => 'API Key';

  @override
  String get llmModel => 'モデル名';

  @override
  String get proposalTitle => 'リライト提案';

  @override
  String get reject => '却下';

  @override
  String get apply => '適用';

  @override
  String get editSection => 'このセクションを編集';

  @override
  String unTranslated(String title) {
    return '【未翻訳のセクション】$title';
  }

  @override
  String get annotations => '注釈';

  @override
  String get export => 'エクスポート';

  @override
  String get chapters => '目次';

  @override
  String get writeBack => '元ファイルに書き戻す(.bak)';

  @override
  String get originalFileUpdated => '元ファイルをバックアップして更新しました';

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
    return '続きから読む：$page';
  }

  @override
  String get language => '言語';

  @override
  String get followSystem => 'システムに従う';

  @override
  String get editTextLayer => '文字層を編集';

  @override
  String get selectText => '文字を選択';

  @override
  String get continuousMode => '連続スクロール';

  @override
  String get singlePageMode => 'シングルページ';

  @override
  String get saveAs => '名前を付けて保存';

  @override
  String get overwrite => '上書き';

  @override
  String get discardChanges => '変更を破棄';

  @override
  String get continueEditing => '編集を続ける';

  @override
  String get unsavedTitle => '未保存の変更があります';

  @override
  String get exitSaveOffice =>
      'この形式の編集は文字層（Agent/翻訳/詳細）に適用されます。\n上書き = アプリ内キャッシュに永続保存；保存 = Markdown ファイルとしてエクスポート。';

  @override
  String get exitSaveText =>
      '上書き = 元のファイルに書き戻す（.bak 自動バックアップ）；保存 = 新しいファイルとしてエクスポート。';

  @override
  String get pageTextTitle => 'ページの文字（長押しで選択）';

  @override
  String get copySelected => '選択範囲をコピー';

  @override
  String get translateSelected => '選択範囲を翻訳';

  @override
  String get noPageText => '（このページに選択できる文字はありません）';

  @override
  String get editCacheSaved => '編集キャッシュに保存しました（終了時に保存方法を選択）';

  @override
  String get readingProgress => '読書の進捗';

  @override
  String get readingSettings => '読書設定';

  @override
  String get search => '検索';

  @override
  String get brightness => '明るさ';

  @override
  String get lineSpacing => '行間';

  @override
  String get paraSpacing => '段落間隔';

  @override
  String get pageMargin => '余白';

  @override
  String get jumpToPage => 'ページへ移動';

  @override
  String get keepAwake => '画面を常にオン';

  @override
  String get immersiveMode => '没入モード（ステータスバー非表示）';

  @override
  String get searchHint => '本の中を検索…';

  @override
  String get noResults => '結果なし';

  @override
  String get searchIn => '検索結果';

  @override
  String get theme => 'テーマ';

  @override
  String get fontSize => '文字サイズ';
}
