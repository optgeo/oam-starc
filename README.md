# oam-starc

OAM (OpenAerialMap) の STARC (SpatioTemporal Asset Resource Catalog) を生成・公開するリポジトリです。

## 目的

- OpenAerialMap metadata API への直接依存を避ける第三層を提供
- STAC v1.0.0 互換の静的 Catalog / Item を生成
- GitHub Pages で `docs/` を公開し、安定参照点を提供
- 運用を自動化し、保守負荷を最小化

## 非目的

- STAC API (`/search` など) は実装しない
- OpenAerialMap の公式サービスや canonical truth を名乗らない
- 完全性・網羅性・リアルタイム性・更新保証は提供しない

## 生成物

- `docs/catalog.json`
  - STAC Catalog (`stac_version: 1.0.0`)
  - OpenAerialMap metadata API のレコードを STAC Item として内包
  - geometry は center point (`Point`)
  - bbox は point から算出
  - assets に metadata / imagery / thumbnail へのリンクを設定
  - `properties` に `provider` / `platform` / `uploaded_at` / `license` を保持

## 実装

単一 Ruby スクリプトで生成します。

```bash
ruby scripts/generate_catalog.rb
```

`/meta` API は pagination されるため、generator は `page` / `limit` を使って全ページを取得してから `docs/catalog.json` を生成します。

必要に応じて環境変数で上書きできます。

- `OAM_METADATA_API_URL` (default: `https://api.openaerialmap.org/meta`)
- `OAM_METADATA_API_LIMIT` (default: `100`)
- `STARC_OUTPUT_PATH` (default: `docs/catalog.json`)
- `STARC_CATALOG_URL` (default: `https://optgeo.github.io/oam-starc/catalog.json`)

### provider / platform / uploaded_at の配置方針

- 3項目は Item ごとに意味を持つため、Catalog 直下ではなく各 Item の `properties` に配置。
- `platform` は STAC Item の文脈でも自然な属性のため、キー名をそのまま維持。
- `provider` と `uploaded_at` は OAM 依存の実務属性として、取得元 API の語彙を崩さずに保持。
- `uploaded_at` は日時として解釈可能な場合は UTC ISO8601 に正規化し、解釈不能な値は欠落させず文字列として保持。
- `thumbnail` は画像アセットなので `properties` ではなく `assets.thumbnail` として配置。
- 追加で実務上利用頻度が高い `license` を `properties` に保持し、ライセンス判定を容易化。

## 運用

- GitHub Actions: `.github/workflows/update-catalog.yml`
- 6時間ごと + 手動実行で Catalog を再生成
- `docs/catalog.json` に差分がある場合のみ自動 commit
- GitHub Pages で `docs/` を公開して配布

このリポジトリは STARC の「派生・非公式・置き場所」として、中立性・保守容易性・fork 可能性を重視します。
