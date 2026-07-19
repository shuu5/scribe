#!/usr/bin/env python3
"""orch_architecture_merge.py — folio inventory 群の揮発横断統合エンジン（orch-2ax / C1）。

役割 ──────────────────────────────────────────────────────────────────────────
  各 project の folio inventory.json を **read-only で読み込み**、横断統合（名前空間付与・
  (project-id, sha, @id) 三つ組グローバルキー・重複解決・relations graph merge）した
  「揮発 on-demand assembly」を stdout へ JSON で出す。中央に統合 architecture を**永続化しない**
  （top-spec §3.1・契約 orch-2ax description『揮発 on-demand assembly』）。

read-only 担保（最強モート・契約 NOTES B1-L1）─────────────────────────────────────
  inventory は `open(path)` で読むだけ。**writable foreign copy を一切作らない**（cp も書き戻しも
  しない）。出力は派生 assembly であって foreign file の copy ではない。本エンジンに write 経路は無い。

B2 = scriptorium 自前の横断統合（pk-u5h notes B2）────────────────────────────────
  folio は cross-repo 統合を ADR-0043 で明示不採用ゆえ、名前空間付与＋重複解決＋graph merge は
  scriptorium 自前責務。(project-id, sha, @id) を三つ組グローバルキーとする。inventory の正規依存は
  `specs[].relations`、`objectGraph` は best-effort、`$schema` URI は placeholder ゆえ folio version
  を pin した「出力形」として扱う（folio は現状 inventory.json を未出力＝この想定スキーマに対し防御的
  にパースする＝全フィールド optional・欠落耐性）。

想定 inventory スキーマ（folio version pin した出力形・全フィールド optional）──────────
  {
    "$schema": "<URI placeholder>",          # version 固定子（任意）
    "folioVersion": "<semver>",              # version pin（任意）
    "specs": [                                # 仕様ノード（無ければ空）
      {
        "@id": "<doc 内 id>" | "id": "...",  # @id 優先・id フォールバック
        "sha": "<content/commit hash>",      # best-effort・null 許容
        "relations": [                        # 正規依存（無ければ空）
          {"kind": "<refines|justifies|leads_to|...>", "target": "<id>"}
        ]
      }
    ],
    "objectGraph": { ... }                   # best-effort 補助グラフ（あれば名前空間付与で保持）
  }

入力 ─────────────────────────────────────────────────────────────────────────
  --source NAME=PATH を 0..N 個（NAME=project-id・PATH=inventory.json の絶対/相対パス）。
  または stdin に JSON 配列 [{"projectId": "...", "path": "..."}] を渡す（--stdin）。
  存在しない PATH / 壊れた JSON は per-source error として記録し skip（graceful・fail-soft）。
  PATH が空（呼び元が graceful skip 済み）の source は渡されない前提。

出力（stdout・揮発 assembly JSON）──────────────────────────────────────────────
  {
    "schemaPin": {...},     # 観測した $schema / folioVersion の集合（version pin 確認用）
    "sources": [...],       # 各 source の取り込み結果（specCount / error 等）
    "nodes": [...],         # 名前空間付与済みノード（三つ組キー・重複畳み込み済み）
    "edges": [...],         # relations 由来の有向辺（target を三つ組へ best-effort 解決）
    "duplicates": [...],    # 三つ組一致で畳まれた重複の痕跡
    "objectGraph": {...},   # projectId 名前空間付与で merge した best-effort グラフ
    "stats": {...}
  }
  exit 0 = 統合成功（per-source error があっても本体は成功）。exit 2 = 引数不正。

検証: selftest-orch-2ax.local.sh（worktree 直下・untracked・fail-closed・hermetic 合成 fixture）。
"""

from __future__ import annotations

import argparse
import json
import sys

# 三つ組キーの区切り（US = Unit Separator・id/sha に通常現れない制御文字）。
_SEP = ""


def _spec_id(spec: dict) -> str | None:
    """spec の doc 内 id を取り出す（@id 優先・id フォールバック・無ければ None）。"""
    if not isinstance(spec, dict):
        return None
    v = spec.get("@id")
    if v is None:
        v = spec.get("id")
    return v if isinstance(v, (str, int)) else None


def _spec_sha(spec: dict) -> str | None:
    """spec の sha（content/commit hash・best-effort・無ければ None）。"""
    if not isinstance(spec, dict):
        return None
    v = spec.get("sha")
    return v if isinstance(v, (str, int)) else None


def _triple(project_id: str, sha, node_id) -> str:
    """(project-id, sha, @id) 三つ組グローバルキー。None は空文字に正規化。"""
    return _SEP.join([str(project_id), "" if sha is None else str(sha),
                      "" if node_id is None else str(node_id)])


def _load_inventory(path: str):
    """inventory.json を read-only で読む。(inventory_dict, error_str)。

    read-only 担保: open(..., 'r') の read のみ。writable copy を作らない。
    """
    try:
        with open(path, "r", encoding="utf-8") as fh:  # read-only
            data = json.load(fh)
    except FileNotFoundError:
        return None, "not-found"
    except (OSError, ValueError) as exc:
        return None, f"unreadable: {exc.__class__.__name__}: {exc}"
    if not isinstance(data, dict):
        return None, "not-an-object (inventory root must be a JSON object)"
    return data, None


def merge(sources: list[dict]) -> dict:
    """sources=[{projectId, path}] を横断統合した揮発 assembly を返す。

    防御的: 各フィールド欠落・型不一致に耐える（folio 未出力の想定スキーマに対する fail-soft）。
    """
    source_reports: list[dict] = []
    schema_pins: dict[str, int] = {}
    folio_versions: dict[str, int] = {}

    # 三つ組キー -> 畳み込みノード
    nodes_by_key: dict[str, dict] = {}
    edges: list[dict] = []
    object_graph: dict[str, object] = {}

    for src in sources:
        project_id = src.get("projectId")
        path = src.get("path")
        if not project_id or not path:
            source_reports.append({"projectId": project_id, "path": path,
                                    "error": "malformed-source (need projectId and path)",
                                    "specCount": 0})
            continue

        inv, err = _load_inventory(path)
        if err is not None:
            # graceful: 不在/破損は記録して skip（契約 acceptance『inventory 不在=graceful skip』）。
            source_reports.append({"projectId": project_id, "path": path,
                                   "error": err, "specCount": 0})
            continue

        schema = inv.get("$schema")
        if isinstance(schema, str):
            schema_pins[schema] = schema_pins.get(schema, 0) + 1
        fver = inv.get("folioVersion")
        if isinstance(fver, (str, int)):
            folio_versions[str(fver)] = folio_versions.get(str(fver), 0) + 1

        specs = inv.get("specs")
        spec_count = 0
        if isinstance(specs, list):
            for spec in specs:
                node_id = _spec_id(spec)
                sha = _spec_sha(spec)
                key = _triple(project_id, sha, node_id)
                spec_count += 1

                relations = []
                rels = spec.get("relations") if isinstance(spec, dict) else None
                if isinstance(rels, list):
                    for rel in rels:
                        if isinstance(rel, dict):
                            # 防御的正規化: kind/target は後段で hashable キー（id_index 引き・
                            # seen_edges sig）に使われる。dict/list 等の非 hashable / 想定外型は
                            # _spec_id 同様 coerce する＝target は str/int のみ受理（他は None＝未解決
                            # 辺）・kind は str のみ受理（他は None）。これで構造的に正当だが型乱用な
                            # JSON が merge() 本体で未捕捉 TypeError を投げ assembly 全体を落とすのを塞ぐ
                            # （per-source 隔離・防御的パース契約の保証）。
                            t = rel.get("target")
                            t = t if isinstance(t, (str, int)) else None
                            k = rel.get("kind")
                            k = k if isinstance(k, str) else None
                            relations.append({"kind": k, "target": t})

                if key in nodes_by_key:
                    # 三つ組一致＝重複解決（名前空間付与後も衝突する＝同 project・同 sha・同 id）。
                    existing = nodes_by_key[key]
                    existing["_dupCount"] += 1
                    # relations は union 連結（重複 relation は後段の node 確定時に dedup する）。
                    existing["relations"].extend(relations)
                else:
                    nodes_by_key[key] = {
                        "key": key,
                        "projectId": project_id,
                        "sha": sha,
                        "id": node_id,
                        "relations": relations,
                        "_dupCount": 1,
                    }

        source_reports.append({"projectId": project_id, "path": path,
                               "error": None, "specCount": spec_count,
                               "schema": schema if isinstance(schema, str) else None,
                               "folioVersion": str(fver) if isinstance(fver, (str, int)) else None})

        # objectGraph は best-effort・projectId 名前空間付与で保持（merge と言っても衝突回避の付与）。
        og = inv.get("objectGraph")
        if og is not None:
            object_graph[project_id] = og

    # ノードを安定順序で確定し、id -> 三つ組キー群の索引（同 project 内の relation target 解決用）。
    # id 無し（id is None）のノードは target になり得ない（誰も None を指せない）ので索引に入れない。
    # 入れると relation target=null との (projectId, None) 一致で誤 resolve する（false-positive edge）。
    nodes = sorted(nodes_by_key.values(), key=lambda n: n["key"])
    # 重複畳み込み（三つ組一致）で relations が union 連結され重複しうるため、(kind, target) で
    # 安定 dedup する（順序保持・初出のみ残す）。signature は json で取り任意 JSON 値に耐える。
    for n in nodes:
        seen_rel: set[str] = set()
        deduped: list[dict] = []
        for rel in n["relations"]:
            sig = json.dumps([rel.get("kind"), rel.get("target")],
                             sort_keys=True, ensure_ascii=False)
            if sig in seen_rel:
                continue
            seen_rel.add(sig)
            deduped.append(rel)
        n["relations"] = deduped
    id_index: dict[tuple, list[str]] = {}
    for n in nodes:
        if n["id"] is None:
            continue
        id_index.setdefault((n["projectId"], n["id"]), []).append(n["key"])

    # relations -> edges。target を「同 project 内の id」へ best-effort 解決（cross-project は未解決のまま）。
    seen_edges: set[tuple] = set()
    duplicates: list[dict] = []
    for n in nodes:
        if n["_dupCount"] > 1:
            duplicates.append({"key": n["key"], "projectId": n["projectId"],
                               "sha": n["sha"], "id": n["id"], "count": n["_dupCount"]})
        for rel in n["relations"]:
            target_id = rel.get("target")
            kind = rel.get("kind")
            # target が null / 欠落（None）の relation は辺を張れない＝未解決で固定する。
            # （None を id_index に引くと id 無しノードへ誤 resolve するため early-out する。）
            if target_id is None:
                resolved = []
            else:
                resolved = id_index.get((n["projectId"], target_id), [])
            to_key = resolved[0] if len(resolved) == 1 else None
            sig = (n["key"], kind, str(target_id), to_key)
            if sig in seen_edges:
                continue
            seen_edges.add(sig)
            edges.append({
                "fromKey": n["key"],
                "kind": kind,
                "targetId": target_id,
                "toKey": to_key,           # 一意解決できた時のみ三つ組キー・他は None（best-effort）
                "projectId": n["projectId"],
                "resolved": to_key is not None,
            })

    # 内部用 _dupCount を出力から落とす。
    for n in nodes:
        n.pop("_dupCount", None)

    return {
        "schemaPin": {
            "schemas": schema_pins,
            "folioVersions": folio_versions,
        },
        "sources": source_reports,
        "nodes": nodes,
        "edges": edges,
        "duplicates": duplicates,
        "objectGraph": object_graph,
        "stats": {
            "sourcesTotal": len(source_reports),
            "sourcesWithInventory": sum(1 for s in source_reports if s.get("error") is None),
            "sourcesSkipped": sum(1 for s in source_reports if s.get("error") is not None),
            "nodes": len(nodes),
            "edges": len(edges),
            "edgesResolved": sum(1 for e in edges if e["resolved"]),
            "duplicatesCollapsed": len(duplicates),
        },
    }


def _parse_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        prog="orch_architecture_merge.py",
        description="folio inventory 群の揮発横断統合（read-only・副作用ゼロ）")
    p.add_argument("--source", action="append", default=[], metavar="NAME=PATH",
                   help="project-id=inventory.json パス（複数可）")
    p.add_argument("--stdin", action="store_true",
                   help='stdin から JSON 配列 [{"projectId","path"}] を読む')
    return p.parse_args(argv)


def main(argv: list[str]) -> int:
    ns = _parse_args(argv)
    sources: list[dict] = []

    if ns.stdin:
        try:
            raw = json.load(sys.stdin)
        except ValueError as exc:
            print(f"orch_architecture_merge: stdin JSON parse error: {exc}", file=sys.stderr)
            return 2
        if not isinstance(raw, list):
            print("orch_architecture_merge: --stdin payload must be a JSON array", file=sys.stderr)
            return 2
        for item in raw:
            if isinstance(item, dict):
                sources.append({"projectId": item.get("projectId"), "path": item.get("path")})

    for tok in ns.source:
        if "=" not in tok:
            print(f"orch_architecture_merge: --source must be NAME=PATH: {tok!r}", file=sys.stderr)
            return 2
        name, path = tok.split("=", 1)
        if not name or not path:
            print(f"orch_architecture_merge: --source NAME and PATH must be non-empty: {tok!r}",
                  file=sys.stderr)
            return 2
        sources.append({"projectId": name, "path": path})

    result = merge(sources)
    json.dump(result, sys.stdout, indent=2, ensure_ascii=False, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
