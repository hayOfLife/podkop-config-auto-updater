"""Export the three requested MAIN lists without printing credentials."""
import argparse
import json
import re
import shlex
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('uci_file', type=Path)
parser.add_argument('output', type=Path)
args = parser.parse_args()
words = iter(shlex.split(args.uci_file.read_text(encoding='utf-8'), comments=True))
section = None
options = {}
for word in words:
    if word == 'config':
        kind, section = next(words), next(words)
    elif word in ('list', 'option'):
        key, value = next(words), next(words)
        if section != 'main':
            continue
        if word == 'list':
            options.setdefault(key, []).append(value)
        else:
            options[key] = value
    else:
        raise ValueError('Unsupported UCI statement')

def text_values(value):
    return list(dict.fromkeys(filter(None, re.split(r'[\s,]+', re.sub(r'//[^\n]*', '', value)))))

feed = {'schema_version': 2, 'revision': 'initial-2026-10-22-v2', 'main': options, 'settings': {}}
for field in ('user_domains', 'user_subnets'):
    options[field] = text_values(options.pop(field + '_text', ''))
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(json.dumps(feed, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
print(json.dumps({key: len(options[key]) for key in ('urltest_proxy_links', 'user_domains', 'user_subnets')}))
