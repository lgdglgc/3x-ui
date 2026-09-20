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

# 明确排除的域名集合（国产国内服务走直连、大模型权重下载站防跑光家宽流量）
EXCLUDE_DOMAINS: Set[str] = {
    # 国产 AI 平台（国内直连速度最快，避免海外家宽导致延迟暴增或风控）
    "kimi.ai", "moonshot.cn", "moonshot.ai", "deepseek.com", "deepseek.cn",
    "zhipuai.cn", "baichuan-ai.com", "stepfun.com", "minimax.io", "minimaxi.com",
    "doubao.com", "yiyan.baidu.com", "qwen.ai", "tongyi.aliyun.com",
    # 动辄数 GB ~ 几十 GB 的模型/权重文件站（避免跑爆家宽昂贵流量）
    "civitai.com",
}

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
        "livekit.cloud",
        "host.livekit.cloud",
        "turn.livekit.cloud",
        "featuregates.org",
        "statsig.com",
        "statsigapi.net",
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
        "notebook.google",
        "notebook.google.com",
        "jules.google",
        "jules.google.com",
        "labs.google",
        "labs.google.com",
        "flow.google",
        "flow.google.com",
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
        "aiplatform.googleapis.com",
        "discoveryengine.googleapis.com",
        "dialogflow.googleapis.com",
        "experiments.withgoogle.com",
        "assistant.google.com",
        "waa-pa.clients6.google.com",
        # Google 根域名与全系核心鉴权 (让 Gemini、Google SSO 登录会话与静态资产全部统一走同一出口，避免跨 IP 拦截)
        # 注意: YouTube 核心视频流域名 (youtube.com, googlevideo.com, ytimg.com) 均为独立根域名，完全不受此影响
        "google.com",
        "googleapis.com",
        "gstatic.com",
        "googleusercontent.com",
        "accounts.google.com",
        "myaccount.google.com",
        "apis.google.com",
        "oauth2.googleapis.com",
        "lh3.googleusercontent.com",
        "generativelanguage.googleusercontent.com",
        "full:play.google.com",
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
        "cursor.blob.core.windows.net",
        "cursor-assets.com",
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
        "exafunction.com",      # Codeium 核心底层 API
    ],
    "ai-coding-tools": [
        "codeium.com",
        "codeiumdata.com",
        "windsurf.ai",
        "windsurf.com",
        "exafunction.com",
        "continue.dev",
        "supermaven.com",
        "augmentcode.com",
        "zed.dev",
        "jetbrains.ai",
        "grazie.ai",
        "grazie.aws.intellij.net",
        "trae.ai",
        "marscode.com",
        "coderabbit.ai",
        "qoder.com",
    ],
    "ai-desktop-apps": [
        "notion.so",
        "notion.com",
        "raycast.com",
        "backend.raycast.com",
        "chatboxai.app",
        "lobehub.com",
        "jan.ai",
        "cherry-ai.com",
    ],
    "ai-platforms-api": [
        "openrouter.ai",
        "groq.com",
        "together.ai",
        "together.xyz",
        "fireworks.ai",
        "deepinfra.com",
        "mistral.ai",
        "console.mistral.ai",
        "lechat.mistral.ai",
        "cohere.com",
        "cohere.ai",
        "fal.ai",
        "replicate.com",
        "meta.ai",
        "duck.ai",
        "coze.com",
        "cici.com",
        "ciciai.com",
        "ciciaicdn.com",
        "chutes.ai",
        "h2o.ai",
        "mozilla.ai",
        "gateway.ai.cloudflare.com",
    ],
    "ai-multimedia": [
        "elevenlabs.io",
        "elevenlabs.com",
        "heygen.com",
        "descript.com",
        "otter.ai",
        "novelai.net",
        "comfy.org",
        "comfyci.org",
        "comfyregistry.org",
    ],
    "other-ai": [
        "midjourney.com",
        "suno.com",
        "suno.ai",
        "udio.com",
        "runwayml.com",
        "runway.com",
        "lumalabs.ai",
        "d-id.com",
        "pika.art",
        "manus.im",
        "manuscdn.com",
        "dola.com",
        "notegpt.io",
        "cerebras.ai",
        "dify.ai",
        "ollama.com",
        "lmstudio.ai",
        "anythingllm.com",
        "langchain.com",
        "crewai.com",
        "jasper.ai",
        "clipdrop.co",
        "tripo3d.ai",
        "openart.ai",
        "sider.ai",
        "arena.ai",
        "devin.ai",
        "clawhub.ai",
        "openclaw.ai",
        "agentclientprotocol.com",
        "deepwiki.com",
        "deepwiki.org",
        "coderabbit.gallery.vsassets.io",
        "lovart.ai",
        "dreamgen.com",
        "tapnow.ai",
        "youmind.ai",
        "youmind.com",
    ]
}

def parse_rule_line(line: str) -> Tuple[int, str]:
    line = line.strip()
    # 忽略空行、注释行、以及上游未展开的 include 嵌套语法 (如 include:cloudflare, include:openai)
    if not line or line.startswith('#') or line.startswith('include:'):
        return None, None
    
    parts = line.split()
    rule = parts[0]
    
    # 过滤 @cn, @!cn, @ads 等属性标记 (如 example.com @cn)
    clean_domain = rule.split('@')[0].strip()
    if not clean_domain:
        return None, None

    # 检查是否命中明确排除的国内服务或大模型下载站
    check_domain = clean_domain
    for prefix in ('full:', 'regexp:', 'keyword:', 'domain:'):
        if check_domain.startswith(prefix):
            check_domain = check_domain[len(prefix):]
            break
    if check_domain.lower() in EXCLUDE_DOMAINS:
        return None, None

    if clean_domain.startswith('full:'):
        return TYPE_FULL, clean_domain[5:].strip().lower()
    elif clean_domain.startswith('regexp:'):
        return TYPE_REGEX, clean_domain[7:].strip()
    elif clean_domain.startswith('keyword:'):
        return TYPE_PLAIN, clean_domain[8:].strip().lower()
    elif clean_domain.startswith('domain:'):
        return TYPE_ROOTDOMAIN, clean_domain[7:].strip().lower()
    else:
        return TYPE_ROOTDOMAIN, clean_domain.strip().lower()

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
    names = ['openai', 'anthropic', 'perplexity', 'cursor', 'github-copilot', 'xai', 'poe', 'windsurf', 'huggingface', 'elevenlabs', 'groq', 'google-deepmind']
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

    # 核心聚合规则库 (ai / myai): 专注对话交互、编程助手与轻量 API，排除 GB 级大模型下载站 (如 huggingface)
    HEAVY_TRAFFIC_CATEGORIES = {'huggingface'}

    all_rules: Dict[Tuple[int, str], None] = {}
    for cat, rdict in cat_rules.items():
        if cat not in HEAVY_TRAFFIC_CATEGORIES:
            all_rules.update(rdict)
    
    print(f"Total unique rules across core AI categories (excluding heavy traffic): {len(all_rules)}")

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
            "ai-coding-tools": cat_rules["ai-coding-tools"],
            "ai-desktop-apps": cat_rules["ai-desktop-apps"],
            "ai-platforms-api": cat_rules["ai-platforms-api"],
            "ai-multimedia": cat_rules["ai-multimedia"],
            "notion": cat_rules["ai-desktop-apps"],
            "raycast": cat_rules["ai-desktop-apps"],
            "chatbox": cat_rules["ai-desktop-apps"],
            "openrouter": cat_rules["ai-platforms-api"],
            "groq": cat_rules["ai-platforms-api"],
            "mistral": cat_rules["ai-platforms-api"],
            "cohere": cat_rules["ai-platforms-api"],
            "together": cat_rules["ai-platforms-api"],
            "elevenlabs": cat_rules["ai-multimedia"],
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
