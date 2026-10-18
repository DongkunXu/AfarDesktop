#!/usr/bin/env python3
"""Merges the strings the Swift compiler found in the sources into Resources/Localizable.xcstrings.

    tools/sync-strings.py <stringsdata-dir> <catalog.xcstrings>

New strings are added untranslated, strings no longer used are removed, translations of the
remaining ones are kept. This is what Xcode does on build; the app is built with SwiftPM, so the build script runs
it instead (the compiler writes the .stringsdata files with -emit-localized-strings).
"""
import glob
import json
import os
import sys


def main(stringsdata_dir: str, catalog_path: str) -> None:
    found = {}
    for path in sorted(glob.glob(os.path.join(stringsdata_dir, "*.stringsdata"))):
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        # Lists left over from a source file that has since been deleted or renamed.
        if not os.path.exists(data.get("source", "")):
            os.remove(path)
            continue
        for entry in data.get("tables", {}).get("Localizable", []):
            found.setdefault(entry["key"], entry.get("comment"))

    if os.path.exists(catalog_path):
        with open(catalog_path, encoding="utf-8") as f:
            catalog = json.load(f)
    else:
        catalog = {"sourceLanguage": "en", "strings": {}, "version": "1.0"}

    strings = catalog.setdefault("strings", {})
    added = [key for key in found if key not in strings]
    for key, comment in found.items():
        entry = strings.setdefault(key, {})
        entry.pop("extractionState", None)
        if comment:
            entry["comment"] = comment
    stale = [key for key in strings if key not in found and strings[key].get("extractionState") != "manual"]
    for key in stale:
        del strings[key]

    catalog["strings"] = dict(sorted(strings.items(), key=lambda item: item[0].lower()))
    text = json.dumps(catalog, ensure_ascii=False, indent=2, separators=(",", " : "))
    with open(catalog_path, "w", encoding="utf-8") as f:
        f.write(text + "\n")

    languages = {lang for e in strings.values() for lang in e.get("localizations", {})}
    for lang in sorted(languages):
        missing = [k for k, e in strings.items()
                   if lang not in e.get("localizations", {}) and e.get("shouldTranslate", True)]
        if missing:
            print(f"warning: {len(missing)} strings untranslated for {lang}:", file=sys.stderr)
            for key in missing:
                print(f"  {key}", file=sys.stderr)
    if added:
        print(f"Added {len(added)} new strings to {os.path.basename(catalog_path)}")
    if stale:
        print(f"Removed {len(stale)} strings no longer used")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
