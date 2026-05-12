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
  - `properties` に下記の標準 STAC フィールドと OAM 固有フィールドを保持

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

### STAC Item の `properties` フィールド

| フィールド | STAC 標準 | 導出元 (OAM API) | 説明 |
|---|---|---|---|
| `datetime` | ✅ 必須 | `acquisition_start` 等 | 撮影日時（UTC ISO8601）|
| `start_datetime` | ✅ 任意 | `acquisition_start` 等 | 撮影開始日時（`end_datetime` が存在する場合のみ付与）|
| `end_datetime` | ✅ 任意 | `acquisition_end` | 撮影終了日時 |
| `updated` | ✅ 任意 | `uploaded_at` | メタデータ最終更新日時（UTC ISO8601 に変換できない場合は省略）|
| `title` | ✅ 任意 | `title` / `name` | 画像タイトル（空白・無効値は省略）|
| `description` | ✅ 任意 | `description` | 説明文（空白・無効値は省略）|
| `platform` | ✅ 任意 | `platform` | 撮影プラットフォーム（UAV 等）（空白・無効値は省略）|
| `gsd` | ✅ 任意 | `gsd` | 地上解像度（m/pixel）|
| `license` | ✅ 任意 | `license` | ライセンス識別子（バリデーター安全な識別子に正規化できる場合のみ付与）|
| `provider` | OAM 固有 | `provider` | 提供者名（空白・無効値は省略）|
| `eo:bands` | `eo` 拡張 | `properties.bands` | バンド情報（利用可能な場合のみ）|

null になる項目は出力から除去します（`datetime` のみ null を許容）。

**設計方針：valid-first（バリデーション優先）**

コンバーターは「バリデーターを通らないリッチなデータ」より「シンプルでもバリデーターを通るデータ」を優先します。
任意プロパティはバリデーター安全な値に変換できると確信できる場合のみ出力し、できない場合はそのプロパティを省略します。
`license` は既知の識別子（`CC-BY-4.0`、`CC-BY-SA-4.0`、`CC0-1.0` 等）に正規化できる場合のみ付与します。

### STAC Extensions

OAM-STARC は、利用可能なデータが揃っている Item にのみ Extension を付与します。
宣言された Extension はすべて `stac_extensions` 配列に URL として記載されます。

| Extension | Schema URL | 付与条件 |
|---|---|---|
| `eo` | `https://stac-extensions.github.io/eo/v1.0.0/schema.json` | OAM メタデータに `properties.bands` が存在する場合 |

将来的な候補: `proj`（EPSG コードがメタデータに含まれる場合）、`view`（太陽角度情報が利用可能な場合）、`raster`（COG アセットが存在する場合）

### Asset の役割（roles）

| Asset キー | `roles` | `type` | 説明 |
|---|---|---|---|
| `metadata` | `["metadata"]` | `application/json` | OAM メタデータ JSON |
| `imagery` | `["overview"]` | `image/png` | TMS タイル URL（`{z}/{x}/{y}` 形式）|
| `imagery` | `["ortho", "data"]` | `image/tiff; application=geotiff; profile=cloud-optimized` | GeoTIFF ファイル |
| `thumbnail` | `["thumbnail"]` | `image/jpeg` または `image/png` | サムネイル画像 |

TMS URL（`{z}/{x}/{y}` を含む）は `overview` ロールとして分類し、正射画像ファイルは `ortho` ロールとして分類します。
これにより、下流クライアントが画像種別（DSM / 正射 等）でフィルタリングしやすくなります。

### provider / platform / uploaded_at の配置方針

- 3項目は Item ごとに意味を持つため、Catalog 直下ではなく各 Item の `properties` に配置。
- `platform` は STAC Item の文脈でも自然な属性のため、キー名をそのまま維持。ただし空白・無効値は省略する。
- `provider` は OAM 依存の実務属性として保持。ただし文字列として安全な値のみ出力する。
- `updated` は STAC 標準フィールドとして `uploaded_at` の値から導出する。UTC ISO8601 に変換できない場合は省略する。
- `thumbnail` は画像アセットなので `properties` ではなく `assets.thumbnail` として配置。
- `license` はバリデーター安全な識別子（`^[\w\-\.\+]+$` に一致）に正規化できる場合のみ `properties` に付与する。正規化できない場合は省略する。

## バリデーション

`docs/catalog.json` に含まれる STAC Item の妥当性を [stac-validator](https://github.com/stac-utils/stac-validator) で検証できます。

```bash
pip install stac-validator
python scripts/validate_catalog.py docs/catalog.json
```

検証スクリプトは各 Item を個別に評価し、失敗した Item の ID と原因（Extension / property 等）をログに出力します。

## 運用

- GitHub Actions: `.github/workflows/update-catalog.yml`
  - 6時間ごと + 手動実行で Catalog を再生成
  - `docs/catalog.json` に差分がある場合のみ自動 commit
  - GitHub Pages で `docs/` を公開して配布
- GitHub Actions: `.github/workflows/validate-stac.yml`
  - `docs/catalog.json` または生成スクリプトの変更を含む PR / push で自動実行
  - STAC 仕様への適合を自動チェックし、失敗時はどの Item / Extension が原因かをログに出力

このリポジトリは STARC の「派生・非公式・置き場所」として、中立性・保守容易性・fork 可能性を重視します。
