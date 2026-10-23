# Quickstart: bounded checks

Scratch repository with fake sections (the shape `checks/08-budget.sh` builds):

```bash
# a section that hangs, with a child and a reparented grandchild
mkdir -p /tmp/x/checks && cp check.sh /tmp/x/ && cd /tmp/x && git init -q
printf '# budget: 2\n(sleep 300 &)\nsleep 301\n' > checks/10-hang.sh
printf 'check "ok" true\n' > checks/20-ok.sh
./check.sh            # ends ~7 s at most; prints the over-budget line, exit 1
pgrep -f 'sleep 30[01]'   # nothing
./check.sh checks/20-ok.sh  # only that section, with its time and the slowest list
```

Expected: `FAIL 10-hang over its budget of 2 s: stopped after 2.x s`,
`10-hang took 2.x s`, a `Slowest sections` block, `Some checks failed`, exit 1.
Contract: [contracts/check-budget.md](contracts/check-budget.md).
