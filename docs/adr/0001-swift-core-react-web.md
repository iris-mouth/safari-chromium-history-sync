---
status: accepted
date: 2026-11-12
---

# Swiftの収集・Reader/APIとReactの画面を同じ製品として配布する

統合製品の収集・Reader/APIはSwift、Web画面はReactとし、実行時にPython・Node.jsを必要としない構成を採用する。既存Python APIの実行時再利用よりも、移植先の配布方針に合わせて保守する実行環境をそろえることを優先する。ユーザーが設計質問Q5の推奨を採用した。

現在のHTTPの振る舞いと受け入れ試験を移植の基準にする。NFKC・casefold・かな変換を含む検索の意味は、現行Python実装との一致で検証する。履歴はQ8により統合DBへ蓄積する。Q14・Q15により、FDAのない独立Viewerと収集元ごとの障害分離を採用する。

HistorySyncWebの「別repoの独立したPython Reader/API」という判断は、新しい統合製品ではこの開発・配布方針へ見直す。稼働中のHistorySyncWebへの変更や切替は、このADRだけでは実施しない。
