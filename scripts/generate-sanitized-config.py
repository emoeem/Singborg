#!/usr/bin/env python3
"""Generate a sanitized sing-box config snapshot locally.

Source defaults to /etc/sing-box/config.json. Output defaults to
config/config.sanitized.json relative to this repository.

No git commands, network access, or remote uploads are performed.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import tempfile
from pathlib import Path

SECRET_KEYS = {
    "password", "secret", "uuid", "private_key", "peer_private_key",
    "token", "access_token", "client_secret",
}
PLACEHOLDER = {
    "server": "<node-server>",
    "server_port": 0,
    "password": "<password>",
    "uuid": "<uuid>",
    "secret": "<clash-api-secret>",
    "private_key": "<private-key>",
    "peer_private_key": "<private-key>",
    "sni": "<sni>",
    "host": "<host>",
}

# DNS bootstrap/public resolver addresses and names are intentionally retained.
PUBLIC_DNS_HOSTS = {
    "1.1.1.1", "1.0.0.1", "8.8.8.8", "8.8.4.4",
    "223.5.5.5", "223.6.6.6", "120.53.53.53", "1.12.12.12",
    "dns.alidns.com", "doh.pub", "cloudflare-dns.com", "dns.google",
}

def is_dns_server(obj: dict) -> bool:
    tag = str(obj.get("tag", ""))
    return obj.get("type") in {"https", "tls", "quic", "h3", "udp", "tcp"} and (
        tag.startswith("dns-") or tag == "hosts-bootstrap"
    )

def is_dns_rule(obj: dict) -> bool:
    """dns.rules 条目没有 type 字段：靠 action + server(DNS 服务器 tag) 识别。"""
    return "action" in obj and isinstance(obj.get("server"), str)

def sanitize_obj(obj, parent_key: str = "", context: str = ""):
    if isinstance(obj, dict):
        out = {}
        dns_context = context in {"dns", "dns_server"} or is_dns_server(obj) or is_dns_rule(obj)
        for key, value in obj.items():
            low = key.lower()
            if low == "server" and dns_context:
                out[key] = value
                continue
            if low == "server_port" and dns_context:
                out[key] = value
                continue
            if low in SECRET_KEYS:
                out[key] = "<clash-api-secret>" if low == "secret" else PLACEHOLDER.get(low, "<redacted>")
                continue
            if low in {"sni", "host"}:
                out[key] = PLACEHOLDER[low]
                continue
            if low == "server" and not dns_context and isinstance(value, str):
                out[key] = value if value in PUBLIC_DNS_HOSTS else "<node-server>"
                continue
            if low == "server_port" and not dns_context and isinstance(value, int):
                out[key] = 0
                continue
            child_ctx = "dns_server" if dns_context else context
            if low in {"dns", "default_domain_resolver"}:
                child_ctx = "dns"
            out[key] = sanitize_obj(value, key, child_ctx)
        return out
    if isinstance(obj, list):
        return [sanitize_obj(v, parent_key, context) for v in obj]
    return obj

def atomic_dump(data: dict, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=f".{destination.name}.", dir=destination.parent, text=True)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(data, fh, ensure_ascii=False, indent=2)
            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, destination)
    finally:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", default="/etc/sing-box/config.json")
    ap.add_argument("--output", default=str(Path(__file__).resolve().parents[1] / "config/config.sanitized.json"))
    args = ap.parse_args()

    source = Path(args.source)
    output = Path(args.output)
    data = json.loads(source.read_text(encoding="utf-8"))
    sanitized = sanitize_obj(data)
    atomic_dump(sanitized, output)

    raw = json.dumps(sanitized, ensure_ascii=False)
    # Safety checks: no obvious real credentials from the source may survive.
    source_text = source.read_text(encoding="utf-8")
    for key in ("password", "uuid", "private_key", "secret"):
        for value in re.findall(r'"' + re.escape(key) + r'"\s*:\s*"([^"]+)"', source_text):
            if value and value not in {"<password>", "<uuid>", "<private-key>", "<clash-api-secret>"} and value in raw:
                raise SystemExit(f"refusing to write: real {key} value survived sanitization")
    if '"server_port": 0' not in raw and any(o.get("type") == "shadowsocks" for o in data.get("outbounds", [])):
        raise SystemExit("refusing to write: node server_port was not sanitized")
    # W2 回归守卫：dns.rules 的 server 是 DNS 服务器 tag，不能被当成节点主机名替换掉。
    src_rules = data.get("dns", {}).get("rules", [])
    out_rules = sanitized.get("dns", {}).get("rules", [])
    if len(src_rules) != len(out_rules):
        raise SystemExit("refusing to write: dns.rules 条数在脱敏前后不一致")
    for idx, (before, after) in enumerate(zip(src_rules, out_rules)):
        if before.get("server") != after.get("server"):
            raise SystemExit(
                f"refusing to write: dns.rules[{idx}].server 被改写 "
                f"({before.get('server')!r} -> {after.get('server')!r})"
            )
    if "<node-server>" in json.dumps(sanitized.get("dns", {}), ensure_ascii=False):
        raise SystemExit("refusing to write: <node-server> 出现在 dns 段（DNS 服务器 tag 被误替换）")
    print(f"generated: {output}")
    print(f"source: {source}")
    print("network access: none")
    print("git/upload operations: none")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
