#!/usr/bin/env bash
# Deterministic verification of the go-blocks approach documents.
# Usage: bash verify-docs.sh   (run from the repository root)
set -uo pipefail
fail=0
step() { printf '\n== %s\n' "$1"; }

# Private scratch dir: fixed /tmp names are hijackable via a pre-created symlink.
work=$(mktemp -d) || {
	echo "FAIL: cannot create temp dir"
	exit 1
}
trap 'rm -rf "$work"' EXIT

step "1. Files present (11 expected)"
shopt -s nullglob
docs=(docs/approaches/*.md)
shopt -u nullglob
printf '%s\n' "${docs[@]}"
if [ "${#docs[@]}" -eq 11 ]; then
	echo "OK: 11 documents"
else
	echo "FAIL: wrong file count (${#docs[@]})"
	fail=1
fi

step "2. Prettier formatting"
npx --yes prettier --check docs/ README.md || fail=1

step "3. Mermaid diagrams compile"
if python3 - "$work" <<'PY' >"$work/diagrams.txt"; then
import pathlib,re,sys
out=pathlib.Path(sys.argv[1])
n=0
for f in sorted(pathlib.Path('docs').rglob('*.md')):
    for m in re.finditer(r'```mermaid\n(.*?)```', f.read_text(), re.S):
        n+=1; (out/f'd{n}.mmd').write_text(m.group(1))
print(n)
PY
	count=$(cat "$work/diagrams.txt")
	echo "found $count diagram(s)"
	if [ "$count" -eq 0 ]; then
		echo "FAIL: no diagrams extracted (expected at least one)"
		fail=1
	fi
	for i in $(seq 1 "$count"); do
		if mmdc -i "$work/d$i.mmd" -o "$work/d$i.svg" >/dev/null 2>&1; then
			echo "OK: diagram $i compiles"
		else
			echo "FAIL: diagram $i"
			fail=1
		fi
	done
else
	echo "FAIL: mermaid extraction failed"
	fail=1
fi

step "4. Internal markdown links resolve"
python3 - <<'PY' || fail=1
import pathlib,re,sys
bad=[]
files=sorted(pathlib.Path('.').glob('README.md'))+sorted(pathlib.Path('docs').rglob('*.md'))

def anchors(path):
    """GitHub-style slugs for every ATX heading, ignoring fenced code."""
    prose=re.sub(r'```.*?```','',path.read_text(),flags=re.S)
    out=set()
    for line in prose.splitlines():
        m=re.match(r'#{1,6}\s+(.*?)\s*$', line)
        if not m: continue
        t=m.group(1)
        t=re.sub(r'`([^`]*)`',r'\1',t)                     # drop code ticks
        t=re.sub(r'\[([^\]]*)\]\([^)]*\)',r'\1',t)         # link text only
        s=re.sub(r'[^\w\s-]','',t.lower()).strip().replace(' ','-')
        out.add(s)
    return out

cache={}
for f in files:
    prose=re.sub(r'```.*?```','',f.read_text(),flags=re.S)
    for _,href in re.findall(r'\[([^\]]+)\]\(([^)\s]+)\)', prose):
        if href.startswith(('http','mailto:')): continue
        path,_,frag=href.partition('#')
        target=f if not path else (f.parent/path)
        if path:
            if not target.resolve().exists():
                bad.append(f'{f}: {href} (missing file)'); continue
        if frag:
            key=target.resolve()
            if key not in cache: cache[key]=anchors(target)
            if frag.lower() not in cache[key]:
                bad.append(f'{f}: {href} (missing anchor)')
print('OK: all internal links and anchors resolve' if not bad else 'FAIL:\n'+'\n'.join(bad))
sys.exit(1 if bad else 0)
PY

step "5. Effort figures agree between summary and Approach 5"
# accept either wording: "50 ew" or "50 engineer-weeks"
for pat in '50 (ew|engineer-weeks)' '162'; do
	a=$(grep -cE "$pat" docs/approaches/README.md)
	b=$(grep -cE "$pat" docs/approaches/05-approach-hybrid-staged.md)
	if [ "$a" -gt 0 ] && [ "$b" -gt 0 ]; then
		echo "OK: '$pat' present in both ($a / $b)"
	else
		echo "FAIL: '$pat' missing (README=$a, 05=$b)"
		fail=1
	fi
done

step "6. No unverified citations reintroduced"
# Art. 46/53/57 were verified and are allowed. Art. 56 (transfers) and the
# criminal chapter (67-73) were deliberately left uncited; catch regressions.
# Matches singular and plural (Art/Arts/Article/Articles) and hyphen, en-dash,
# or em-dash ranges, so "Arts. 67–73" cannot slip past this gate.
if grep -nE 'Art(icle)?s?\.? *(56|6[7-9]|7[0-3])\b' docs/approaches/10-compliance-blocks.md; then
	echo "FAIL: a deliberately-omitted PDP article number reappeared"
	fail=1
else
	echo "OK: deliberately omitted PDP article numbers still absent"
fi

printf '\n== RESULT: %s\n' "$([ $fail -eq 0 ] && echo PASS || echo FAIL)"
exit $fail
