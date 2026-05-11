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
  - assets に metadata / imagery へのリンクを設定

## 実装

単一 Ruby スクリプトで生成します。

```bash
ruby scripts/generate_catalog.rb
```

必要に応じて環境変数で上書きできます。

- `OAM_METADATA_API_URL` (default: `https://api.openaerialmap.org/meta`)
- `STARC_OUTPUT_PATH` (default: `docs/catalog.json`)
- `STARC_CATALOG_URL` (default: `https://optgeo.github.io/oam-starc/catalog.json`)

## 運用

- GitHub Actions: `.github/workflows/update-catalog.yml`
- 6時間ごと + 手動実行で Catalog を再生成
- `docs/catalog.json` に差分がある場合のみ自動 commit
- GitHub Pages で `docs/` を公開して配布

このリポジトリは STARC の「派生・非公式・置き場所」として、中立性・保守容易性・fork 可能性を重視します。
