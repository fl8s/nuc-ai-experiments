UPLOAD_HOST   ?= smbaker@198.0.0.45
UPLOAD_PATH   ?= /home/smbaker/openclaw-virtual-scott

# k3s ships its own `kubectl` symlink that auto-discovers
# /etc/rancher/k3s/k3s.yaml, but other tools (helm, jq pipes) don't have
# that shim. Export explicitly so everything agrees. Override if your
# kubeconfig lives elsewhere.
export KUBECONFIG ?= /etc/rancher/k3s/k3s.yaml

WP_NAMESPACE     := wordpress
WP_MANIFEST      := wordpress/manifest.yaml
WP_NODEPORT      := 30080

# App Passwords are persisted into this k8s secret so they survive across
# `make scott-app-password` / `make virtual-scott-app-password` runs
# rather than being re-minted on every invocation. `make passwords` dumps
# everything stored.
APP_PWD_SECRET   := openclaw-app-passwords

# Admin (scott) — values used by `wp core install` on first deploy.
# Email must validate; .local and .invalid TLDs get rejected by WP.
WP_ADMIN_USER  := scott
WP_ADMIN_PASS  := scottscott
WP_ADMIN_EMAIL := scott@example.com
WP_TITLE       := Scott's Sandbox

# Virtual Scott user — the WP account the agent posts comments under.
# Created with Editor role so it can publish comments without going
# through the moderation queue. Distinct from the `scott` admin.
VS_USER       := virtual-scott
VS_PASS       := virtual-scott
VS_EMAIL      := virtual-scott@example.com
VS_ROLE       := editor
VS_DISPLAY    := Virtual Scott

# Some Commenter — a test account used to author comments that virtual-scott
# will then respond to. Subscriber role: realistic "regular reader" identity,
# auto-approved because `configure-comments` disables the moderation queue.
SC_USER       := some-commenter
SC_PASS       := some-commenter
SC_EMAIL      := some-commenter@example.com
SC_ROLE       := subscriber
SC_DISPLAY    := Some Commenter

# OpenClaw agent — second agent on the existing daemon (alongside `main`
# from the openclaw/ HN-opinions demo). Workspace is separate to avoid
# session/auth collisions with main.
AGENT_NAME      := virtual-scott
AGENT_MODEL     := nuc/qwen3-coder
AGENT_WORKSPACE := $(HOME)/.openclaw/workspace-$(AGENT_NAME)
PERSONA_SRC     := PERSONA.md
PERSONA_DST     := $(AGENT_WORKSPACE)/PERSONA.md

# Build the WP URL from the VM's primary IP — wp-cli needs a valid URL
# even when running locally. Override with WP_URL=... if needed.
LAN_IP  := $(shell hostname -I 2>/dev/null | awk '{print $$1}')
WP_URL  ?= http://$(LAN_IP):$(WP_NODEPORT)

WP_EXEC := kubectl exec -n $(WP_NAMESPACE) deploy/wordpress --

.PHONY: help upload install upgrade uninstall status creds url \
        create-virtual-scott create-some-commenter \
        virtual-scott-app-password scott-app-password \
        rotate-virtual-scott-app-password rotate-scott-app-password \
        passwords configure-homepage configure-comments \
        create-agent install-persona install-skill agent-status \
        install-cron uninstall-cron enable-cron disable-cron cron-run \
        cron-status cron-runs poll-now pause resume \
        install-fixtures wipe-comments seed-comments reset-comments \
        wait-wp wait-wpcli _ensure-app-secret

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-26s %s\n", $$1, $$2}'

# -----------------------------------------------------------------------------
# Workstation-side
# -----------------------------------------------------------------------------

upload: ## rsync this directory to the sandbox VM (UPLOAD_HOST, UPLOAD_PATH)
	@echo "rsync -> $(UPLOAD_HOST):$(UPLOAD_PATH)/"
	@ssh $(UPLOAD_HOST) "mkdir -p $(UPLOAD_PATH)"
	@rsync -avz --delete \
		--exclude='.git' \
		--exclude='__pycache__' \
		--exclude='/medium-import/venv/' \
		./ $(UPLOAD_HOST):$(UPLOAD_PATH)/
	@echo ""
	@echo "Next on $(UPLOAD_HOST):"
	@echo "  cd $(UPLOAD_PATH) && make install"

# -----------------------------------------------------------------------------
# VM-side (after `make upload` + ssh in)
# -----------------------------------------------------------------------------

install: ## Apply the WP manifest and run `wp core install`
	@if ! kubectl version >/dev/null 2>&1; then \
		echo "ERROR: kubectl can't reach the cluster (KUBECONFIG=$(KUBECONFIG))"; \
		exit 1; \
	fi
	@kubectl apply -f $(WP_MANIFEST)
	@$(MAKE) --no-print-directory wait-wp
	@$(MAKE) --no-print-directory wait-wpcli
	@echo "Running wp core install..."
	@if $(WP_EXEC) wp --allow-root --path=/var/www/html --url=$(WP_URL) core is-installed >/dev/null 2>&1; then \
		echo "  already installed; skipping"; \
	else \
		$(WP_EXEC) wp --allow-root --path=/var/www/html core install \
			--url=$(WP_URL) \
			--title="$(WP_TITLE)" \
			--admin_user=$(WP_ADMIN_USER) \
			--admin_password=$(WP_ADMIN_PASS) \
			--admin_email=$(WP_ADMIN_EMAIL) \
			--skip-email; \
	fi
	@$(MAKE) --no-print-directory configure-homepage
	@$(MAKE) --no-print-directory configure-comments
	@$(MAKE) --no-print-directory create-virtual-scott
	@$(MAKE) --no-print-directory create-some-commenter
	@echo ""
	@$(MAKE) --no-print-directory creds
	@$(MAKE) --no-print-directory url
	@echo ""
	@echo "Next:"
	@echo "  make scott-app-password            # mint admin REST token (for medium-import)"
	@echo "  make virtual-scott-app-password    # mint agent REST token (for the reply skill)"

upgrade: ## Re-apply the manifest (idempotent)
	@kubectl apply -f $(WP_MANIFEST)
	@$(MAKE) --no-print-directory wait-wp

uninstall: ## Remove WP from k3s (PVCs are retained; delete the namespace to wipe data)
	@kubectl delete -f $(WP_MANIFEST) --ignore-not-found
	@echo "Manifest removed. PVCs retained:"
	@kubectl get pvc -n $(WP_NAMESPACE) 2>/dev/null || true
	@echo "To delete data too: kubectl delete namespace $(WP_NAMESPACE)"

status: ## Show WP pod, service, and PVC status
	@kubectl get pod,svc,pvc -n $(WP_NAMESPACE) 2>/dev/null || echo "Namespace not found."

creds: ## Print the WP admin user + password (from manifest defaults)
	@printf "User:     %s\nPassword: %s\nEmail:    %s\n" $(WP_ADMIN_USER) $(WP_ADMIN_PASS) $(WP_ADMIN_EMAIL)

url: ## Print the WP URL (LAN-reachable)
	@echo "WP URL: $(WP_URL)"
	@echo "From the VM itself: http://localhost:$(WP_NODEPORT)"

# Wait until the WP pod is Ready.
wait-wp:
	@echo "Waiting for WP pod to become Ready..."
	@kubectl wait pod -n $(WP_NAMESPACE) -l app=wordpress --for=condition=Ready --timeout=180s

# wp-cli arrives via the postStart hook ~1-2s after the container starts.
# Poll until it's executable, since exec'ing too early gets "no such file".
wait-wpcli:
	@for i in $$(seq 1 20); do \
		if $(WP_EXEC) test -x /usr/local/bin/wp 2>/dev/null; then \
			exit 0; \
		fi; \
		sleep 1; \
	done; \
	echo "ERROR: wp-cli never appeared in /usr/local/bin/wp"; exit 1

create-virtual-scott: ## Create the virtual-scott WP user (Editor role) — idempotent
	@if $(WP_EXEC) wp --allow-root --path=/var/www/html user get $(VS_USER) >/dev/null 2>&1; then \
		echo "User '$(VS_USER)' exists, skipping create"; \
	else \
		echo "Creating WP user '$(VS_USER)' with role '$(VS_ROLE)'..."; \
		$(WP_EXEC) wp --allow-root --path=/var/www/html user create \
			$(VS_USER) $(VS_EMAIL) \
			--role=$(VS_ROLE) \
			--user_pass=$(VS_PASS) \
			--display_name="$(VS_DISPLAY)" 2>&1 | sed 's/^/  /'; \
	fi

create-some-commenter: ## Create the some-commenter WP user (Subscriber role) — idempotent
	@if $(WP_EXEC) wp --allow-root --path=/var/www/html user get $(SC_USER) >/dev/null 2>&1; then \
		echo "User '$(SC_USER)' exists, skipping create"; \
	else \
		echo "Creating WP user '$(SC_USER)' with role '$(SC_ROLE)'..."; \
		$(WP_EXEC) wp --allow-root --path=/var/www/html user create \
			$(SC_USER) $(SC_EMAIL) \
			--role=$(SC_ROLE) \
			--user_pass=$(SC_PASS) \
			--display_name="$(SC_DISPLAY)" 2>&1 | sed 's/^/  /'; \
	fi

# Internal: make sure the storage secret exists (idempotent).
_ensure-app-secret:
	@kubectl get secret -n $(WP_NAMESPACE) $(APP_PWD_SECRET) >/dev/null 2>&1 || \
		kubectl create secret generic $(APP_PWD_SECRET) -n $(WP_NAMESPACE) >/dev/null

virtual-scott-app-password: _ensure-app-secret ## Get (or mint) virtual-scott's REST Application Password (persisted)
	@existing=$$(kubectl get secret -n $(WP_NAMESPACE) $(APP_PWD_SECRET) \
		-o jsonpath='{.data.virtual-scott}' 2>/dev/null | base64 -d); \
	if [ -z "$$existing" ]; then \
		echo "Minting new Application Password for $(VS_USER)..."; \
		new=$$($(WP_EXEC) wp --allow-root --path=/var/www/html \
			user application-password create $(VS_USER) openclaw-agent --porcelain); \
		kubectl patch secret -n $(WP_NAMESPACE) $(APP_PWD_SECRET) --type merge \
			-p "{\"data\":{\"virtual-scott\":\"$$(printf %s "$$new" | base64 -w0)\"}}" >/dev/null; \
		existing="$$new"; \
		echo "  (saved to secret/$(APP_PWD_SECRET) key=virtual-scott)"; \
	else \
		echo "Application Password for $(VS_USER) (cached):"; \
	fi; \
	echo "  $$existing"; \
	echo ""; \
	echo "Stash in the sandbox VM's systemd env:"; \
	echo "  VS_WP_USER=$(VS_USER)"; \
	echo "  VS_WP_APP_PASSWORD=$$existing"; \
	echo "  VS_WP_URL=http://localhost:$(WP_NODEPORT)"

scott-app-password: _ensure-app-secret ## Get (or mint) scott's REST Application Password (persisted; used by medium-import)
	@existing=$$(kubectl get secret -n $(WP_NAMESPACE) $(APP_PWD_SECRET) \
		-o jsonpath='{.data.scott}' 2>/dev/null | base64 -d); \
	if [ -z "$$existing" ]; then \
		echo "Minting new Application Password for $(WP_ADMIN_USER)..."; \
		new=$$($(WP_EXEC) wp --allow-root --path=/var/www/html \
			user application-password create $(WP_ADMIN_USER) openclaw-content-import --porcelain); \
		kubectl patch secret -n $(WP_NAMESPACE) $(APP_PWD_SECRET) --type merge \
			-p "{\"data\":{\"scott\":\"$$(printf %s "$$new" | base64 -w0)\"}}" >/dev/null; \
		existing="$$new"; \
		echo "  (saved to secret/$(APP_PWD_SECRET) key=scott)"; \
	else \
		echo "Application Password for $(WP_ADMIN_USER) (cached):"; \
	fi; \
	echo "  $$existing"; \
	echo ""; \
	echo "From workstation, run medium-import/import.py with:"; \
	echo "  export WP_URL=$(WP_URL)"; \
	echo "  export WP_USER=$(WP_ADMIN_USER)"; \
	echo "  export WP_APP_PASSWORD='$$existing'"

# -----------------------------------------------------------------------------
# OpenClaw agent
# -----------------------------------------------------------------------------

create-agent: ## Add the virtual-scott OpenClaw agent (idempotent) + install persona
	@if openclaw agents list 2>/dev/null | grep -qE "^- $(AGENT_NAME)( |$$)"; then \
		echo "Agent '$(AGENT_NAME)' exists, skipping create"; \
	else \
		echo "Creating OpenClaw agent '$(AGENT_NAME)'..."; \
		openclaw agents add $(AGENT_NAME) \
			--workspace $(AGENT_WORKSPACE) \
			--model $(AGENT_MODEL) \
			--non-interactive; \
	fi
	@$(MAKE) --no-print-directory install-persona
	@echo ""
	@echo "Agent created. Verify with: make agent-status"

install-persona: ## Install PERSONA.md + IDENTITY/USER/SOUL into the workspace; remove BOOTSTRAP.md
	@mkdir -p $(AGENT_WORKSPACE)
	@cp $(PERSONA_SRC) $(PERSONA_DST)
	@cp $(PERSONA_SRC) $(AGENT_WORKSPACE)/SOUL.md
	@cp agent-workspace/IDENTITY.md $(AGENT_WORKSPACE)/IDENTITY.md
	@cp agent-workspace/USER.md     $(AGENT_WORKSPACE)/USER.md
	@rm -f $(AGENT_WORKSPACE)/BOOTSTRAP.md
	@echo "Persona installed:"
	@echo "  $(PERSONA_DST)              (canonical authoring source)"
	@echo "  $(AGENT_WORKSPACE)/SOUL.md  (== PERSONA.md content; this is what the agent actually loads)"
	@echo "  $(AGENT_WORKSPACE)/IDENTITY.md (replaced template)"
	@echo "  $(AGENT_WORKSPACE)/USER.md     (replaced template)"
	@echo "  BOOTSTRAP.md removed so the agent skips the wake-up wizard"

# -----------------------------------------------------------------------------
# Autonomous cron loop
# -----------------------------------------------------------------------------

VS_CRON_NAME    := virtual-scott-tick
VS_CRON_EVERY   ?= 5m
VS_PAUSED_FILE  := $(AGENT_WORKSPACE)/PAUSED

install-cron: ## Register the autonomous tick cron job (disabled by default). Use enable-cron to activate.
	@openclaw cron add \
		--name $(VS_CRON_NAME) \
		--agent $(AGENT_NAME) \
		--every $(VS_CRON_EVERY) \
		--message 'Read /home/smbaker/.openclaw/workspace-virtual-scott/skills/virtual-scott-tick/SKILL.md and execute it.' \
		--session-key agent:$(AGENT_NAME):tick \
		--no-deliver \
		--disabled 2>&1 | tail -10
	@echo ""
	@echo "Cron job '$(VS_CRON_NAME)' added (disabled). To start firing:"
	@echo "  make enable-cron"
	@echo ""
	@echo "Optional: drop a Telegram conf so the orchestrator pushes a phone"
	@echo "notification on every successful reply (see TELEGRAM-SETUP.md):"
	@echo "  ~/.config/systemd/user/openclaw-gateway.service.d/telegram.conf"
	@echo "    Environment=VS_TELEGRAM_BOT_TOKEN=..."
	@echo "    Environment=VS_TELEGRAM_CHAT_ID=..."
	@echo "  systemctl --user daemon-reload && systemctl --user restart openclaw-gateway"

uninstall-cron: ## Remove the cron job entirely
	@CRON_ID=$$(openclaw cron show $(VS_CRON_NAME) 2>/dev/null | awk '/^id:/ {print $$2}'); \
	if [ -z "$$CRON_ID" ]; then \
		echo "Cron '$(VS_CRON_NAME)' not registered; nothing to remove."; exit 0; \
	fi; \
	openclaw cron rm "$$CRON_ID" 2>&1 | tail -5

enable-cron: ## Start the autonomous loop firing every $(VS_CRON_EVERY)
	@CRON_ID=$$(openclaw cron show $(VS_CRON_NAME) 2>/dev/null | awk '/^id:/ {print $$2}'); \
	if [ -z "$$CRON_ID" ]; then \
		echo "ERROR: cron job '$(VS_CRON_NAME)' not registered. Run 'make install-cron' first."; exit 1; \
	fi; \
	openclaw cron enable "$$CRON_ID" 2>&1 | tail -5; \
	echo "Cron '$(VS_CRON_NAME)' enabled. Firing every $(VS_CRON_EVERY)."; \
	echo "Kill switch: make pause"

disable-cron: ## Stop the autonomous loop (does not delete the job)
	@CRON_ID=$$(openclaw cron show $(VS_CRON_NAME) 2>/dev/null | awk '/^id:/ {print $$2}'); \
	if [ -z "$$CRON_ID" ]; then \
		echo "Cron '$(VS_CRON_NAME)' not registered; nothing to disable."; exit 0; \
	fi; \
	openclaw cron disable "$$CRON_ID" 2>&1 | tail -5; \
	echo "Cron '$(VS_CRON_NAME)' disabled."

cron-status: ## Show cron scheduler status + this job
	@openclaw cron status 2>&1 | head -20
	@echo ""
	@echo "=== virtual-scott-tick job ==="
	@openclaw cron show $(VS_CRON_NAME) 2>&1 | head -20 || echo "(not installed; run 'make install-cron')"

cron-runs: ## Show the last N cron run history (set N=20 for more)
	@CRON_ID=$$(openclaw cron show $(VS_CRON_NAME) 2>/dev/null | awk '/^id:/ {print $$2}'); \
	if [ -z "$$CRON_ID" ]; then \
		echo "Cron '$(VS_CRON_NAME)' not registered."; exit 0; \
	fi; \
	openclaw cron runs "$$CRON_ID" 2>&1 | head -$${N:-10}

poll-now: ## Run one tick of the autonomous loop manually (bypasses cron)
	@echo "Running vs-tick.py directly (bypassing cron)..."
	@python3 $(AGENT_WORKSPACE)/scripts/vs-tick.py

pause: ## Engage the kill switch — next tick (cron or manual) will be a no-op
	@touch $(VS_PAUSED_FILE)
	@echo "Paused. Created: $(VS_PAUSED_FILE)"
	@echo "Resume with: make resume"

resume: ## Disengage the kill switch
	@rm -f $(VS_PAUSED_FILE)
	@echo "Resumed. Removed: $(VS_PAUSED_FILE)"

cron-run: ## Fire the cron job once immediately (via openclaw, not bypassing it)
	@CRON_ID=$$(openclaw cron show $(VS_CRON_NAME) 2>/dev/null | awk '/^id:/ {print $$2}'); \
	if [ -z "$$CRON_ID" ]; then \
		echo "ERROR: cron job '$(VS_CRON_NAME)' not registered. Run 'make install-cron' first."; \
		exit 1; \
	fi; \
	echo "Firing cron job $$CRON_ID..."; \
	openclaw cron run "$$CRON_ID" 2>&1 | tail -10

# -----------------------------------------------------------------------------
# WP demo fixtures (repeatable test seeding)
# -----------------------------------------------------------------------------

FIXTURES_SRC_DIR := fixtures
FIXTURES_DST_DIR := $(AGENT_WORKSPACE)/fixtures

install-fixtures: scott-app-password ## Install fixture scripts + JSON into agent workspace (substitutes WP host + scott App Password)
	@SCOTT_PWD=$$(kubectl get secret -n $(WP_NAMESPACE) $(APP_PWD_SECRET) \
		-o jsonpath='{.data.scott}' 2>/dev/null | base64 -d); \
	if [ -z "$$SCOTT_PWD" ]; then \
		echo "ERROR: no scott App Password in secret. Run 'make scott-app-password' first."; \
		exit 1; \
	fi; \
	SCOTT_AUTH_B64=$$(printf "%s" "$(WP_ADMIN_USER):$$SCOTT_PWD" | base64 -w0); \
	WP_HOST=$$(hostname -I | awk '{print $$1}'); \
	mkdir -p $(FIXTURES_DST_DIR); \
	for f in $(FIXTURES_SRC_DIR)/*; do \
		name=$$(basename $$f); \
		sed -e "s|__SCOTT_AUTH_B64__|$$SCOTT_AUTH_B64|g" \
		    -e "s|__WP_HOST__|$$WP_HOST|g" \
			$$f \
			> $(FIXTURES_DST_DIR)/$$name; \
		case "$$name" in *.sh) chmod +x $(FIXTURES_DST_DIR)/$$name;; esac; \
		echo "  $(FIXTURES_DST_DIR)/$$name"; \
	done

wipe-comments: ## Delete ALL WP comments (uses wp-cli in the pod). DESTRUCTIVE.
	@if [ ! -f $(FIXTURES_DST_DIR)/wipe-comments.sh ]; then \
		$(MAKE) --no-print-directory install-fixtures; \
	fi
	@bash $(FIXTURES_DST_DIR)/wipe-comments.sh

seed-comments: install-fixtures ## POST canonical some-commenter test comments (idempotent only after wipe; otherwise duplicates)
	@cd $(FIXTURES_DST_DIR) && bash $(FIXTURES_DST_DIR)/seed-comments.sh some-commenter-comments.json

reset-comments: wipe-comments seed-comments ## Wipe + re-seed in one step for a clean demo state
	@echo ""
	@echo "WP comment state reset. Current:"
	@kubectl exec -n $(WP_NAMESPACE) deploy/wordpress -- \
		wp --allow-root --path=/var/www/html comment list --fields=comment_ID,comment_author,comment_post_ID,comment_content --format=table 2>&1 | head -15

agent-status: ## Show OpenClaw agents + virtual-scott workspace contents
	@openclaw agents list 2>&1 | head -30
	@echo ""
	@echo "Workspace at $(AGENT_WORKSPACE):"
	@ls -la $(AGENT_WORKSPACE) 2>/dev/null || echo "  (workspace not created yet — run 'make create-agent')"
	@echo ""
	@echo "Skills:"
	@ls -la $(AGENT_WORKSPACE)/skills 2>/dev/null || echo "  (no skills installed — run 'make install-skill')"

install-skill: virtual-scott-app-password ## Install ALL skills + helper scripts into the agent workspace (substitutes App Password + WP host)
	@APP_PWD=$$(kubectl get secret -n $(WP_NAMESPACE) $(APP_PWD_SECRET) \
		-o jsonpath='{.data.virtual-scott}' 2>/dev/null | base64 -d); \
	if [ -z "$$APP_PWD" ]; then \
		echo "ERROR: no virtual-scott App Password in secret. Run 'make virtual-scott-app-password' first."; \
		exit 1; \
	fi; \
	AUTH_B64=$$(printf "%s" "$(VS_USER):$$APP_PWD" | base64 -w0); \
	WP_HOST=$$(hostname -I | awk '{print $$1}'); \
	echo "Installing skills (WP host: http://$$WP_HOST:$(WP_NODEPORT)):"; \
	for d in skills/*/; do \
		name=$$(basename $$d); \
		mkdir -p $(AGENT_WORKSPACE)/skills/$$name; \
		sed -e "s|__VS_WP_AUTH_B64__|$$AUTH_B64|g" \
		    -e "s|__WP_HOST__|$$WP_HOST|g" \
			$$d/SKILL.md \
			> $(AGENT_WORKSPACE)/skills/$$name/SKILL.md; \
		echo "  $(AGENT_WORKSPACE)/skills/$$name/SKILL.md"; \
	done; \
	if [ -d agent-workspace/scripts ]; then \
		echo "Installing helper scripts:"; \
		mkdir -p $(AGENT_WORKSPACE)/scripts; \
		for f in agent-workspace/scripts/*; do \
			name=$$(basename $$f); \
			sed -e "s|__VS_WP_AUTH_B64__|$$AUTH_B64|g" \
			    -e "s|__WP_HOST__|$$WP_HOST|g" \
				$$f \
				> $(AGENT_WORKSPACE)/scripts/$$name; \
			chmod +x $(AGENT_WORKSPACE)/scripts/$$name; \
			echo "  $(AGENT_WORKSPACE)/scripts/$$name"; \
		done; \
	fi

configure-comments: ## Disable comment moderation (all comments auto-publish)
	@$(WP_EXEC) wp --allow-root --path=/var/www/html option update comment_moderation 0 >/dev/null
	@$(WP_EXEC) wp --allow-root --path=/var/www/html option update comment_previously_approved 0 >/dev/null
	@$(WP_EXEC) wp --allow-root --path=/var/www/html option update default_comment_status open >/dev/null
	@$(WP_EXEC) wp --allow-root --path=/var/www/html option update comment_registration 0 >/dev/null
	@echo "Comment moderation disabled — all comments auto-publish."

configure-homepage: ## Set the homepage to a clean list-of-titles page (idempotent)
	@PAGE_ID=$$($(WP_EXEC) wp --allow-root --path=/var/www/html \
		post list --post_type=page --name=posts --field=ID 2>/dev/null | head -1); \
	if [ -z "$$PAGE_ID" ]; then \
		echo "Creating 'Posts' index page..."; \
		PAGE_ID=$$($(WP_EXEC) wp --allow-root --path=/var/www/html post create \
			--post_type=page --post_status=publish \
			--post_title="Posts" --post_name=posts \
			--post_content='<!-- wp:latest-posts {"postsToShow":100,"displayPostDate":true,"displayPostContent":false,"displayFeaturedImage":false,"orderBy":"date","order":"desc"} /-->' \
			--porcelain); \
		echo "  created page id=$$PAGE_ID"; \
	else \
		echo "'Posts' page exists (id=$$PAGE_ID), reusing"; \
	fi; \
	$(WP_EXEC) wp --allow-root --path=/var/www/html option update show_on_front page >/dev/null; \
	$(WP_EXEC) wp --allow-root --path=/var/www/html option update page_on_front $$PAGE_ID >/dev/null; \
	echo "Homepage now points at the 'Posts' index."

passwords: _ensure-app-secret ## Print all stored Application Passwords
	@echo "Stored Application Passwords (from secret/$(APP_PWD_SECRET)):"
	@for key in scott virtual-scott; do \
		val=$$(kubectl get secret -n $(WP_NAMESPACE) $(APP_PWD_SECRET) \
			-o jsonpath="{.data.$$key}" 2>/dev/null | base64 -d); \
		if [ -n "$$val" ]; then \
			printf "  %-15s %s\n" "$$key:" "$$val"; \
		else \
			printf "  %-15s (not minted yet — run 'make %s-app-password')\n" "$$key:" "$$key"; \
		fi; \
	done

rotate-scott-app-password: ## Force-mint a fresh App Password for scott (replaces stored)
	@kubectl patch secret -n $(WP_NAMESPACE) $(APP_PWD_SECRET) --type=json \
		-p '[{"op":"remove","path":"/data/scott"}]' 2>/dev/null || true
	@$(MAKE) --no-print-directory scott-app-password

rotate-virtual-scott-app-password: ## Force-mint a fresh App Password for virtual-scott (replaces stored)
	@kubectl patch secret -n $(WP_NAMESPACE) $(APP_PWD_SECRET) --type=json \
		-p '[{"op":"remove","path":"/data/virtual-scott"}]' 2>/dev/null || true
	@$(MAKE) --no-print-directory virtual-scott-app-password
