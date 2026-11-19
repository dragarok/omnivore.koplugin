"""Check the patches from gen_patches.lua against diff-match-patch (what Omnivore uses).

Each patch must
  1. be byte-identical to what diff_match_patch.patch_make writes for the same highlight, and
  2. apply to the text, also when the text has shifted (as in a reader that adds a header).
"""
import json
import re
import sys

from diff_match_patch import diff_match_patch

START, END = "<omnivore_highlight>", "</omnivore_highlight>"


def norm(s):
    return re.sub(r"\s+", " ", s).strip()


def main(out_dir):
    raw = open(f"{out_dir}/text.txt", "rb").read()
    text = raw.decode("utf-8")
    failures = 0
    for line in open(f"{out_dir}/cases.jsonl", encoding="utf-8"):
        case = json.loads(line)
        if case["a"] is None:
            print(f"FAIL not found: {case['quote']!r}")
            failures += 1
            continue
        a = len(raw[: case["a"] - 1].decode())
        b = len(raw[: case["b"] - 1].decode())
        quote = text[a:b]
        problems = []
        if norm(quote) != norm(case["quote"]):
            problems.append(f"located {quote!r}")

        dmp = diff_match_patch()
        # Omnivore measures positions in UTF-16 code units; diff-match-patch for Python uses code
        # points, so only compare patches for text without astral characters before the quote.
        astral_before = any(ord(c) > 0xFFFF for c in text[:b])
        expected = dmp.patch_toText(dmp.patch_make(text, text[:a] + START + quote + END + text[b:]))
        if not astral_before and expected != case["patch"]:
            problems.append(f"differs from patch_make:\n    got      {case['patch']!r}\n    expected {expected!r}")

        shifted = "Title\nBy someone\n" * 10 + text
        for label, target in (("exact", text), ("shifted", shifted)):
            new, applied = dmp.patch_apply(dmp.patch_fromText(case["patch"]), target)
            if not all(applied):  # Omnivore retries with looser matching
                dmp.Match_Threshold, dmp.Match_Distance = 0.5, 4000
                new, applied = dmp.patch_apply(dmp.patch_fromText(case["patch"]), target)
            m = re.search(re.escape(START) + r"([\s\S]*?)" + re.escape(END), new)
            if not (all(applied) and m and m.group(1) == quote):
                problems.append(f"does not apply ({label})")

        status = "ok  " if not problems else "FAIL"
        print(f"{status} {case['quote'][:50]!r}")
        for p in problems:
            print("    " + p)
        failures += bool(problems)
    print(f"{failures} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
