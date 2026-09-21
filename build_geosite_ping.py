import os
import sys
import subprocess
import tempfile
import requests
from typing import Dict, List, Set, Tuple

# Domain Types matching V2Ray/Xray protobuf
TYPE_PLAIN = 0      # Keyword substring
TYPE_REGEX = 1      # Regular expression
TYPE_ROOTDOMAIN = 2 # Root domain (matches domain and all its subdomains)
TYPE_FULL = 3       # Exact full domain match

# 排除的大流量测速域名（确保 geosite_ping.dat 仅用于纯 IP 质量/延迟测试，不浪费测速流量）
EXCLUDE_SPEEDTEST_DOMAINS: Set[str] = {
    "speedtest.net", "fast.com", "fastspeedtest.com", "librespeed.org",
    "nperf.com", "measurementlab.net", "openspeedtest.com", "speedcheck.org",
    "speedof.me", "testmy.net", "testmyspeed.com", "speed.cloudflare.com",
    "speedtest.cn", "cnspeedtest.cn"
}

# 核心离线基准数据（按测试维度分类，无需测速，专注于 IP 质量、纯净度、欺诈分与 Ping 诊断）
BASELINE_DATA: Dict[str, List[str]] = {
    # 1. 欺诈分、风控、伪装度与纯净度检测
    "ip-fraud-quality": [
        "ping0.cc",
        "scamalytics.com",
        "ipqualityscore.com",
        "ipcheck.ing",
        "iphey.com",
        "incolumitas.com",
        "ipx.ac",
        "focsec.com",
        "check.place",
        "ip.check.place",
        "whoer.net",
        "whoerip.com",
        "pixelscan.net",
        "browserleaks.com",
        "fraudguard.io",
        "fraudlogix.com",
        "proxycheck.io",
        "ip-score.com",
        "ip-check.info",
        "ipcheck.net",
        "ip2location.com",
        "ip2location.io",
        "ipapi.is",
    ],
    # 2. 网络连通性、Ping 与 TCPing 诊断工具
    "ping-tools": [
        "ping.pe",
        "ping.sx",
        "public-us-pingsx.api.clonoth.com",
        "check-host.net",
        "itdog.cn",
        "tcping.cn",
        "host-tracker.com",
        "tools.ipip.net",
        "ipip.net",
        "ping.chinaz.com",
        "port.ping.pe",
        "dns.ping.pe",
    ],
    # 3. DNS / WebRTC / 隐私泄漏检测
    "leak-test": [
        "dnsleaktest.com",
        "dnscheck.tools",
        "dnsleak.com",
        "ipleak.net",
        "ipleak.org",
        "ipleak.com",
        "mullvad.net",
        "browserleaks.com",
        "webrtc.org",
        "browseraudit.com",
    ],
    # 4. IP 属性、ASN、BGP 与权威商业数据库
    "ip-info": [
        "ipinfo.io",
        "ipinfo.app",
        "ip-api.com",
        "ipapi.co",
        "ipapi.com",
        "ip.guide",
        "bgp.tools",
        "bgp.he.net",
        "peeringdb.com",
        "radb.net",
        "stat.ripe.net",
        "ripe.net",
        "apnic.net",
        "arin.net",
        "maxmind.com",
        "db-ip.com",
        "ipdata.co",
        "ipregistry.co",
        "iproyal.com",
        "ipwho.is",
        "ipwhois.io",
        "ipaddress.my",
        "ipaddress.com",
        "ipaddress.sh",
        "ipaddress.to",
        "ip8.com",
        "ipgeolocation.io",
        "ipfind.io",
        "ipfinder.io",
        "abstractapi.com",
        "extreme-ip-lookup.com",
        "zxinc.org",
    ],
    # 5. 轻量 IP 出口回显（0 流量、纯文本快速探测）
    "ip-echo": [
        "cip.cc",
        "ip.skk.moe",
        "ip.p3terx.com",
        "ip138.com",
        "ipchaxun.com",
        "ip.cat",
        "ip.sb",
        "api.ip.sb",
        "icanhazip.com",
        "ifconfig.me",
        "ifconfig.co",
        "ifconfig.io",
        "ifconfig.es",
        "ipify.org",
        "api.ipify.org",
        "ipify.cn",
        "myip.la",
        "ident.me",
        "ipecho.net",
        "curlmyip.net",
        "wtfismyip.com",
        "whatismyip.akamai.com",
        "checkip.amazonaws.com",
        "checkip.dyndns.org",
        "myip.dnsomatic.com",
        "ipw.cn",
        "iplark.com",
        "myexternalip.com",
        "showmyip.com",
        "myip.ipip.net",
    ],
    # 6. 黑名单与网络滥用查询
    "abuse-blacklist": [
        "abuseipdb.com",
        "spamhaus.org",
        "projecthoneypot.org",
        "talosintelligence.com",
        "barracudacentral.org",
        "multirbl.valli.org",
        "sorbs.net",
    ],
    # 7. IPv6 连通性测试（纯诊断无测速）
    "ipv6-test": [
        "test-ipv6.com",
        "ipv6-test.com",
        "test-ipv6.cn",
        "testipv6.cn",
        "ipv6ready.me",
        "test-ipv6.se",
        "test-ipv6.is",
        "test-ipv6.jp",
        "test-ipv6.nl",
    ]
}

METACUBEX_URLS: Dict[str, str] = {
    "category-ip-geo-detect": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/category-ip-geo-detect.json",
    "pingpe": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/pingpe.json",
    "pingsx": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/pingsx.json",
    "test-ipv6": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/test-ipv6.json",
}

def to_list(val) -> List[str]:
    if not val:
        return []
    if isinstance(val, str):
        return [val.strip()]
    return [str(x).strip() for x in val if x]

def parse_rule_entry(rule_str: str) -> Tuple[int, str]:
    """Parse string entry to (TYPE, value)"""
    rule_str = rule_str.strip()
    if rule_str.startswith("full:"):
        return TYPE_FULL, rule_str[5:].strip().lower()
    elif rule_str.startswith("domain:"):
        return TYPE_ROOTDOMAIN, rule_str[7:].strip().lower()
    elif rule_str.startswith("regexp:"):
        return TYPE_REGEX, rule_str[7:].strip()
    elif rule_str.startswith("keyword:"):
        return TYPE_PLAIN, rule_str[8:].strip().lower()
    else:
        return TYPE_ROOTDOMAIN, rule_str.lower()

def fetch_metacubex_rules(url: str) -> List[Tuple[int, str]]:
    """Fetch and parse sing/meta-rules-dat json format"""
    rules: List[Tuple[int, str]] = []
    try:
        resp = requests.get(url, timeout=10)
        if resp.status_code == 200:
            data = resp.json()
            for r in data.get("rules", []):
                for val in to_list(r.get("domain")):
                    if len(val) >= 3:
                        rules.append((TYPE_FULL, val.lower()))
                for val in to_list(r.get("domain_suffix")):
                    if len(val) >= 3:
                        rules.append((TYPE_ROOTDOMAIN, val.lower()))
                for val in to_list(r.get("domain_keyword")):
                    if len(val) >= 3:
                        rules.append((TYPE_PLAIN, val.lower()))
                for val in to_list(r.get("domain_regex")):
                    if val:
                        rules.append((TYPE_REGEX, val))
    except Exception as e:
        print(f"  [Warning] Failed to fetch {url}: {e}")
    return rules

def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    out_dat_path = os.path.join(script_dir, "geosite_ping.dat")
    out_txt_path = os.path.join(script_dir, "geosite_ping_domains.txt")

    print("Collecting IP Quality & Ping diagnosis domain rules (Speedtest excluded)...")

    # Aggregate categories
    cat_rules: Dict[str, Dict[Tuple[int, str], None]] = {}

    # 1. Load Baseline
    for cat, items in BASELINE_DATA.items():
        cat_rules[cat] = {}
        for item in items:
            t, v = parse_rule_entry(item)
            if v not in EXCLUDE_SPEEDTEST_DOMAINS:
                cat_rules[cat][(t, v)] = None

    # 2. Fetch online supplements from MetaCubeX
    for name, url in METACUBEX_URLS.items():
        online_entries = fetch_metacubex_rules(url)
        if online_entries:
            print(f"  [Online] Loaded {len(online_entries)} rules from MetaCubeX '{name}'")
            if name not in cat_rules:
                cat_rules[name] = {}
            for t, v in online_entries:
                if v not in EXCLUDE_SPEEDTEST_DOMAINS:
                    cat_rules[name][(t, v)] = None

    # Total aggregated rules
    all_rules: Dict[Tuple[int, str], None] = {}
    for cat, rdict in cat_rules.items():
        all_rules.update(rdict)

    print(f"Total unique rules across all IP/Ping categories: {len(all_rules)}")

    # Protobuf definition
    proto_str = """syntax = "proto3";
package router;

message Domain {
  enum Type {
    Plain = 0;
    Regex = 1;
    RootDomain = 2;
    Full = 3;
  }
  Type type = 1;
  string value = 2;

  message Attribute {
    string key = 1;
    oneof typed_value {
      bool bool_value = 2;
      int64 int_value = 3;
    }
  }
  repeated Attribute attribute = 3;
}

message GeoSite {
  string country_code = 1;
  repeated Domain domain = 2;
}

message GeoSiteList {
  repeated GeoSite entry = 1;
}
"""

    with tempfile.TemporaryDirectory() as td:
        proto_file = os.path.join(td, 'geosite.proto')
        with open(proto_file, 'w', encoding='utf-8') as f:
            f.write(proto_str)
        res = subprocess.run([sys.executable, '-m', 'grpc_tools.protoc', f'-I{td}', f'--python_out={td}', proto_file], capture_output=True, text=True)
        if res.returncode != 0:
            print("protoc error:", res.stderr)
            sys.exit(1)
        sys.path.insert(0, td)
        import geosite_pb2

        geosite_list = geosite_pb2.GeoSiteList()

        # Tag definitions for Xray / 3X-UI:
        # e.g. ext:geosite_ping.dat:ping
        #      ext:geosite_ping.dat:ip
        #      ext:geosite_ping.dat:ip-check
        #      ext:geosite_ping.dat:fraud
        tag_definitions: Dict[str, Dict[Tuple[int, str], None]] = {
            "ping": all_rules,
            "ip": all_rules,
            "ip-check": all_rules,
            "quality": all_rules,
            "fraud": cat_rules.get("ip-fraud-quality", {}),
            "ping-tools": cat_rules.get("ping-tools", {}),
            "leak": cat_rules.get("leak-test", {}),
            "ip-info": cat_rules.get("ip-info", {}),
            "ip-echo": cat_rules.get("ip-echo", {}),
            "blacklist": cat_rules.get("abuse-blacklist", {}),
            "category-ip-geo-detect": cat_rules.get("category-ip-geo-detect", all_rules),
        }

        for tag_name, rules in tag_definitions.items():
            if not rules:
                continue
            site_upper = geosite_list.entry.add()
            site_upper.country_code = tag_name.upper()
            for (dtype, dval) in sorted(rules.keys(), key=lambda x: (x[0], x[1])):
                d = site_upper.domain.add()
                d.type = dtype
                d.value = dval

            if tag_name.upper() != tag_name.lower():
                site_lower = geosite_list.entry.add()
                site_lower.country_code = tag_name.lower()
                for (dtype, dval) in sorted(rules.keys(), key=lambda x: (x[0], x[1])):
                    d = site_lower.domain.add()
                    d.type = dtype
                    d.value = dval

        binary_data = geosite_list.SerializeToString()
        with open(out_dat_path, 'wb') as out_f:
            out_f.write(binary_data)
        print(f"Written {len(binary_data)} bytes to {out_dat_path}")

        with open(out_txt_path, 'w', encoding='utf-8') as tf:
            tf.write(f"# geosite_ping.dat Domain List ({len(all_rules)} total rules)\n")
            tf.write("# IP Quality / Fraud Score / Purity / Ping / ASN / DNS Leaks (NO Speedtest)\n\n")
            for (dtype, dval) in sorted(all_rules.keys(), key=lambda x: (x[0], x[1])):
                prefix = ""
                if dtype == TYPE_FULL:
                    prefix = "full:"
                elif dtype == TYPE_REGEX:
                    prefix = "regexp:"
                elif dtype == TYPE_PLAIN:
                    prefix = "keyword:"
                tf.write(f"{prefix}{dval}\n")
        print(f"Domain list exported to {out_txt_path}")

if __name__ == '__main__':
    main()
