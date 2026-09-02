# Masume Web/PWA版 実現可能性調査

## 背景

macOS ネイティブアプリ Masume を Web アプリ（PWA）化すれば、Windows ユーザーにもリーチできるのでは？という検討。

## 結論

**技術的に実現可能。** Masume のモデル/レンダラー/UI は綺麗に分離されており、Web 技術で同等の機能をほぼすべて再現できる。

## 機能ごとの移植可否

| 機能 | Web での対応 | 備考 |
|------|-------------|------|
| 矢印・矩形・楕円・線の描画 | Canvas 2D API | CoreGraphics と同等の描画が可能 |
| テキスト追加・編集 | contenteditable / textarea overlay | NSTextView の代替 |
| ぼかし (Pixelate) | Canvas ピクセル操作 | CIFilter 不要、JS で十分 |
| Undo/Redo | JS でスナップショット方式をそのまま移植 | 言語非依存のアーキテクチャ |
| クリップボード連携 | Clipboard API (`navigator.clipboard.write()`) | `Cmd+C` / `Cmd+V` 対応可 |
| ファイル保存 | ダウンロード / File System Access API | Chromium 系は直接保存も可 |
| PWA 化 | Service Worker + manifest.json | オフライン動作可 |

## ネイティブアプリの優位性

機能面での差はほぼない。優位性は操作フローにある。

- **スクリーンショット統合**: `Cmd+Shift+4` → 即 `Cmd+V` で編集開始。Web だとブラウザを開くステップが増える。
- **ドラッグアウト**: Finder や Slack にファイルとして直接ドラッグ可。Web ではできないが、`Cmd+C` でコピー → `Cmd+V` で貼り付けで代替すれば実用上問題なし。
- **起動速度**: ネイティブは即起動。PWA もキャッシュがあれば速いが、ネイティブほどではない。

## 既存の競合 Web ツール

| ツール | 特徴 | PWA | 料金 |
|--------|------|-----|------|
| PureMark Annotate | ペースト→アノテーション→コピーの流れ。完全クライアント処理。最も Skitch に近い | Yes | 無料 |
| Annotely | 2010 年から存在。矢印・図形・テキスト・ぼかし対応 | No | 無料 |
| Markup Hero | チーム向け。クラウド保存・共有リンク付き | No | フリーミアム |
| ImageAnnotation.org | 12 種以上のツール。クライアント処理 | No | 無料 |

既存ツールは機能は揃っているが、描画のレスポンスや UI のキレで差がつきやすい。Masume のネイティブで感じる操作の軽さを Web 版でも出せれば差別化になる。

## Raycast Extension 案

Raycast extension の標準 UI（List/Grid/Detail/Form）にはキャンバス描画やマウスインタラクションの API がない。Swift ヘルパー + WKWebView で別ウィンドウを開く抜け道はあるが（Simple Draw extension が実例）、実質スタンドアロン WebView アプリを Raycast 経由で起動しているだけ。既にネイティブアプリがあるなら Raycast のカスタムコマンドで `open -a Masume` する方がシンプル。

## Skitch がネイティブだった理由

Skitch 初版は 2007 年、Evernote 買収が 2011 年。Canvas API や Clipboard API が実用的になったのはここ数年で、当時は Web で同等のことをやるのが現実的ではなかった。

## 今後やるなら

Web 版を作るなら独立した PWA が最も筋がいい。差別化ポイントは機能ではなく操作の軽快さとデザイン。
