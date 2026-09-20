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

# Curated offline baseline domain rules per category
BASELINE_DATA: Dict[str, List[str]] = {
    "openai": [
        "chat.com",
        "chatgpt.com",
        "chatgpt.site",
        "crixet.com",
        "oaistatic.com",
        "oaistatsig.com",
        "oaiusercontent.com",
        "openai.com",
        "sora.com",
        "chatgpt.livekit.cloud",
        "host.livekit.cloud",
        "turn.livekit.cloud",
        "openai.com.cdn.cloudflare.net",
        "full:openaiapi-site.azureedge.net",
        "full:openaiassets.blob.core.windows.net",
        "full:openaicom-api-bdcpf8c6d2e9atf6.z01.azurefd.net",
        "full:openaicom.imgix.net",
        "full:openaicomproductionae4b.blob.core.windows.net",
        "full:production-openaicom-storage.azureedge.net",
        "full:browser-intake-datadoghq.com",
        "full:o33249.ingest.sentry.io",
        "full:openai.qualtrics.com",
        r"regexp:^chatgpt-async-webps-prod-\S+-\d+\.webpubsub\.azure\.com$",
    ],
    "anthropic": [
        "anthropic.com",
        "clau.de",
        "claude.ai",
        "claude.com",
        "claudemcpclient.com",
        "claudemcpcontent.com",
        "claudeusercontent.com",
        "full:servd-anthropic-website.b-cdn.net",
        "full:usefathom.com",
    ],
    "google-gemini": [
        "deepmind.com",
        "deepmind.google",
        "generativeai.google",
        "ai.studio",
        "aistudio.google.com",
        "bard.google.com",
        "gemini.google",
        "gemini.google.com",
        "gemini.gstatic.com",
        "makersuite.google.com",
        "notebooklm.google",
        "notebooklm.google.com",
        "jules.google",
        "jules.google.com",
        "labs.google",
        "labs.google.com",
        "flow.google",
        "opal.google",
        "opal.google.com",
        "antigravity.google",
        "antigravity-unleash.goog",
        "antigravity.googleapis.com",
        "antigravity-pa.googleapis.com",
        "antigravity.sandbox.google.com",
        "daily-antigravity.sandbox.google.com",
        "antigravity-staging.google.com",
        "stitch.withgoogle.com",
        "ai.google.dev",
        "alkalicore-pa.clients6.google.com",
        "alkalimakersuite-pa.clients6.google.com",
        "webchannel-alkalimakersuite-pa.clients6.google.com",
        "geller-pa.googleapis.com",
        "generativelanguage.googleapis.com",
        "proactivebackend-pa.googleapis.com",
        "robinfrontend-pa.googleapis.com",
        "cloudaicompanion.googleapis.com",
        "cloudcode-pa.googleapis.com",
        "daily-cloudcode-pa.googleapis.com",
        "notebooklm-pa.googleapis.com",
        "notebooklm.googleapis.com",
        "aisandbox-pa.googleapis.com",
        "aicode.googleapis.com",
        "aida.googleapis.com",
    ],
    "antigravity": [
        "antigravity.google",
        "antigravity-unleash.goog",
        "antigravity.googleapis.com",
        "antigravity-pa.googleapis.com",
        "antigravity.sandbox.google.com",
        "daily-antigravity.sandbox.google.com",
        "antigravity-staging.google.com",
        "generativelanguage.googleapis.com",
        "cloudaicompanion.googleapis.com",
        "cloudcode-pa.googleapis.com",
        "daily-cloudcode-pa.googleapis.com",
        "aisandbox-pa.googleapis.com",
        "aicode.googleapis.com",
        "aida.googleapis.com",
        "alkalicore-pa.clients6.google.com",
        "ai.google.dev",
    ],
    "perplexity": [
        "perplexity.ai",
        "perplexity.com",
        "pplx.ai",
        "full:ppl-ai-file-upload.s3.amazonaws.com",
        "full:pplx-res.cloudinary.com",
    ],
    "cursor": [
        "cursor-cdn.com",
        "cursor.com",
        "cursor.sh",
        "cursorapi.com",
        "tether.cursor.sh",
        "repo42.cursor.sh",
    ],
    "copilot": [
        "copilot-stg.com",
        "copilot.cloud.microsoft",
        "copilot.com",
        "copilot.microsoft.com",
        "githubcopilot.com",
        "full:copilot-proxy.githubusercontent.com",
        "full:api.githubcopilot.com",
        "full:origin-tracker.githubusercontent.com",
        "full:sydney.bing.com",
        "full:edgeservices.bing.com",
    ],
    "xai": [
        "x.ai",
        "grok.com",
        "api.x.ai",
        "assets.grok.com",
    ],
    "huggingface": [
        "huggingface.co",
        "hf.co",
        "hf.space",
    ],
    "poe": [
        "poe.com",
        "poecdn.net",
    ],
    "windsurf": [
        "codeium.com",
        "codeiumdata.com",
        "windsurf.ai",
        "windsurf.com",
    ],
    "other-ai": [
        "midjourney.com",
        "cohere.ai",
        "cohere.com",
        "mistral.ai",
        "lechat.mistral.ai",
        "elevenlabs.io",
        "suno.com",
        "suno.ai",
        "udio.com",
        "runwayml.com",
        "runway.com",
        "civitai.com",
        "lumalabs.ai",
        "d-id.com",
        "pika.art",
        "manus.im",
        "openrouter.ai",
        "groq.com",
        "cerebras.ai",
        "together.ai",
        "dify.ai",
        "ollama.com",
        "lmstudio.ai",
        "anythingllm.com",
        "langchain.com",
        "crewai.com",
        "jasper.ai",
        "clipdrop.co",
        "kimi.ai",
        "moonshot.cn",
        "moonshot.ai",
        "deepseek.com",
        "tripo3d.ai",
        "openart.ai",
        "sider.ai",
        "arena.ai",
        "devin.ai",
    ]
}

def parse_rule_line(line: str) -> Tuple[int, str]:
    line = line.strip()
    if not line or line.startswith('#'):
        return None, None
    parts = line.split()
    rule = parts[0]
    
    if rule.startswith('full:'):
        return TYPE_FULL, rule[5:].strip().lower()
    elif rule.startswith('regexp:'):
        return TYPE_REGEX, rule[7:].strip()
    elif rule.startswith('keyword:'):
        return TYPE_PLAIN, rule[8:].strip().lower()
    elif rule.startswith('domain:'):
        return TYPE_ROOTDOMAIN, rule[7:].strip().lower()
    else:
        return TYPE_ROOTDOMAIN, rule.strip().lower()

def fetch_online_list(name: str) -> List[str]:
    url = f"https://raw.githubusercontent.com/v2fly/domain-list-community/master/data/{name}"
    try:
        resp = requests.get(url, timeout=5)
        if resp.status_code == 200:
            lines = []
            for l in resp.text.splitlines():
                l = l.strip()
                if l and not l.startswith('#'):
                    lines.append(l)
            return lines
    except Exception:
        pass
    return []

def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    out_dat_path = os.path.join(script_dir, "geosite_myai.dat")
    out_txt_path = os.path.join(script_dir, "geosite_myai_domains.txt")

    print("Collecting AI domain rules...")
    fetched_data = {}
    names = ['openai', 'anthropic', 'google-deepmind', 'perplexity', 'cursor', 'github-copilot', 'xai', 'poe', 'windsurf', 'huggingface', 'elevenlabs', 'groq']
    for n in names:
        lines = fetch_online_list(n)
        if lines:
            fetched_data[n] = lines
            print(f"  [Online] Loaded {len(lines)} rules for {n}")
        else:
            print(f"  [Offline] Using baseline rules for {n}")

    cat_rules: Dict[str, Dict[Tuple[int, str], None]] = {}
    
    def add_rules(cat: str, raw_lines: List[str]):
        if cat not in cat_rules:
            cat_rules[cat] = {}
        for line in raw_lines:
            t, v = parse_rule_line(line)
            if t is not None and v:
                cat_rules[cat][(t, v)] = None

    for cat, default_lines in BASELINE_DATA.items():
        online_key = cat
        if cat == 'copilot':
            online_key = 'github-copilot'
        elif cat == 'google-gemini':
            online_key = 'google-deepmind'
        
        lines = list(default_lines)
        if online_key in fetched_data:
            lines.extend(fetched_data[online_key])
        add_rules(cat, lines)

    all_rules: Dict[Tuple[int, str], None] = {}
    for cat, rdict in cat_rules.items():
        all_rules.update(rdict)
    
    print(f"Total unique rules across all AI categories: {len(all_rules)}")

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

        tag_definitions: Dict[str, Dict[Tuple[int, str], None]] = {
            "myai": all_rules,
            "ai": all_rules,
            "category-ai-!cn": all_rules,
            "category-ai-chat-!cn": all_rules,
            "openai": cat_rules["openai"],
            "chatgpt": cat_rules["openai"],
            "anthropic": cat_rules["anthropic"],
            "claude": cat_rules["anthropic"],
            "google-gemini": cat_rules["google-gemini"],
            "gemini": cat_rules["google-gemini"],
            "deepmind": cat_rules["google-gemini"],
            "perplexity": cat_rules["perplexity"],
            "cursor": cat_rules["cursor"],
            "copilot": cat_rules["copilot"],
            "github-copilot": cat_rules["copilot"],
            "xai": cat_rules["xai"],
            "grok": cat_rules["xai"],
            "huggingface": cat_rules["huggingface"],
            "poe": cat_rules["poe"],
            "windsurf": cat_rules["windsurf"],
            "antigravity": cat_rules["antigravity"],
        }

        for tag_name, rules in tag_definitions.items():
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
            tf.write(f"# geosite_myai.dat Domain List ({len(all_rules)} total rules)\n")
            tf.write("# Generated for AI Home Broadband Routing / 家宽分流\n\n")
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
