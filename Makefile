.PHONY: skill-check

skill-check:   ## skills/ と plugins/ を検証する（frontmatter / 参照切れ / shellcheck / gofmt / plugin.json / marketplace.json / claude plugin validate）
	./scripts/skill-check.sh
