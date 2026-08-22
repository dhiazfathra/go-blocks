#!/usr/bin/env bash
# Deterministic verification of the go-blocks approach documents.
# Usage: bash verify-docs.sh   (run from the repository root)
set -uo pipefail
fail=0
step() { printf '\n== %s\n' "$1"; }

step "1. Files present (10 expected)"
ls docs/approaches/*.md | tee /dev/stderr | wc -l | xargs -I{} test {} -eq 10 &&
	echo "OK: 10 documents" || {
	echo "FAIL: wrong file count"
	fail=1
}

step "2. Prettier formatting"
npx --yes prettier --check docs/ README.md || fail=1

step "3. Mermaid diagrams compile"
python3 - <<'PY' >/tmp/diagrams.txt
import pathlib,re
n=0
for f in sorted(pathlib.Path('docs').rglob('*.md')):
    for m in re.finditer(r'```mermaid\n(.*?)```', f.read_text(), re.S):
        n+=1; pathlib.Path(f'/tmp/d{n}.mmd').write_text(m.group(1))
print(n)
PY
count=$(cat /tmp/diagrams.txt)
echo "found $count diagram(s)"
for i in $(seq 1 "$count"); do
	mmdc -i "/tmp/d$i.mmd" -o "/tmp/d$i.svg" >/dev/null 2>&1 &&
		echo "OK: diagram $i compiles" || {
		echo "FAIL: diagram $i"
		fail=1
	}
done

step "4. Internal markdown links resolve"
python3 - <<'PY' || fail=1
import pathlib,re,sys
bad=[]
files=sorted(pathlib.Path('.').glob('README.md'))+sorted(pathlib.Path('docs').rglob('*.md'))
for f in files:
    # strip fenced code blocks so Go/proto samples are not scanned for links
    prose=re.sub(r'```.*?```', '', f.read_text(), flags=re.S)
    for _,href in re.findall(r'\[([^\]]+)\]\(([^)\s]+)\)', prose):
        if href.startswith(('http','#','mailto:')): continue
        if not (f.parent/href.split('#')[0]).resolve().exists():
            bad.append(f'{f}: {href}')
print('OK: all internal links resolve' if not bad else 'FAIL:\n'+'\n'.join(bad))
sys.exit(1 if bad else 0)
PY

step "5. Effort figures agree between summary and Approach 5"
# accept either wording: "50 ew" or "50 engineer-weeks"
for pat in '50 (ew|engineer-weeks)' '162'; do
	a=$(grep -cE "$pat" docs/approaches/README.md)
	b=$(grep -cE "$pat" docs/approaches/05-approach-hybrid-staged.md)
	[ "$a" -gt 0 ] && [ "$b" -gt 0 ] &&
		echo "OK: '$pat' present in both ($a / $b)" ||
		{
			echo "FAIL: '$pat' missing (README=$a, 05=$b)"
			fail=1
		}
done

step "6. No unverified citations reintroduced"
# Art. 46/53/57 were verified and are allowed. Art. 56 (transfers) and the
# criminal chapter (67-73) were deliberately left uncited; catch regressions.
if grep -nE 'Art(icle)?\.? *(56|6[7-9]|7[0-3])\b' docs/approaches/10-compliance-blocks.md; then
	echo "FAIL: a deliberately-omitted PDP article number reappeared"
	fail=1
else
	echo "OK: deliberately omitted PDP article numbers still absent"
fi

printf '\n== RESULT: %s\n' "$([ $fail -eq 0 ] && echo PASS || echo FAIL)"
exit $fail
