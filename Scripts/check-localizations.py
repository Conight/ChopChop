#!/usr/bin/env python3
"""Validate catalog coverage and format arguments without launching or driving the app."""
import collections
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
FORMAT = re.compile(r'%(?:(\d+)\$)?(?:\.\d+)?((?:ll|l)?[diufg@])')


def arguments(value):
    # Literal percent signs must not be interpreted as an argument.
    value = value.replace('%%', '')
    return collections.Counter((int(position) if position else index + 1, kind)
                               for index, (position, kind) in enumerate(FORMAT.findall(value)))


def units(node):
    if 'stringUnit' in node:
        return [node['stringUnit']['value']]
    return [value for variation in node.get('variations', {}).values() for child in variation.values() for value in units(child)]


def main():
    count = 0
    for name in ('Localizable', 'AppShortcuts'):
        catalog = json.loads((ROOT / 'ChopChop' / f'{name}.xcstrings').read_text())
        assert catalog['sourceLanguage'] == 'en'
        for key, item in catalog['strings'].items():
            localizations = item['localizations']
            assert {'en', 'zh-Hans'} <= localizations.keys(), key
            for language in ('en', 'zh-Hans'):
                for value in units(localizations[language]):
                    assert value, f'Empty {language} translation: {key}'
                    assert arguments(key) == arguments(value), f'Format mismatch ({language}): {key} -> {value}'
                    assert sorted(re.findall(r'\$\{\w+\}', key)) == sorted(re.findall(r'\$\{\w+\}', value)), key
            count += 1
    print(f'Validated {count} English / Simplified Chinese catalog entries and their format arguments.')


if __name__ == '__main__':
    try:
        main()
    except (AssertionError, KeyError, ValueError) as error:
        sys.exit(f'Localization validation failed: {error}')
