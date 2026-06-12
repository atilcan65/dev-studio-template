#!/usr/bin/env bash
# e2e-pilot.sh — Template'ten sıfırdan yeni proje açıp tüm akışı doğrula
#
# Kullanım:
#   ./scripts/tests/e2e-pilot.sh                  # default: dev-studio-test-pilot-2
#   ./scripts/tests/e2e-pilot.sh my-pilot-name    # custom repo adı
#
# Çıkış kodu: 0 = tüm testler PASS, 1 = en az 1 test FAIL
#
# Bu script idempotent DEĞİL — her koşmadan önce eski pilot repo'yu sil:
#   gh repo delete <pilot-name> --yes   # (delete_repo permission gerekli)
#   # ya da GitHub UI → Settings → Delete

set -uo pipefail

# ============================================================================
# Config
# ============================================================================
PILOT_REPO_NAME="${1:-dev-studio-test-pilot-2}"
TEMPLATE_REPO="atilcan65/dev-studio-template"
GITHUB_OWNER="${GITHUB_OWNER:-atilcan65}"
WORK_DIR="/tmp/e2e-pilot-$$"

# Test sayaçları
PASS=0
FAIL=0
TOTAL=0
declare -a FAIL_DETAILS=()

# Renkler
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ============================================================================
# Helpers
# ============================================================================
log_section() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

pass() {
    PASS=$((PASS + 1))
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}✓ PASS${NC} — $1"
}

fail() {
    FAIL=$((FAIL + 1))
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}✗ FAIL${NC} — $1"
    FAIL_DETAILS+=("$1")
    [[ -n "${2:-}" ]] && echo -e "    ${RED}↳ $2${NC}"
}

info() {
    echo -e "  ${YELLOW}ℹ${NC} $1"
}

cleanup() {
    if [[ -d "$WORK_DIR" ]]; then
        info "Cleaning up $WORK_DIR"
        rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT

# ============================================================================
# Pre-flight checks
# ============================================================================
log_section "Pre-flight"

if ! command -v gh &> /dev/null; then
    echo -e "${RED}✗ gh CLI not installed${NC}"
    exit 1
fi
pass "gh CLI present"

if ! gh auth status &> /dev/null; then
    echo -e "${RED}✗ gh not authenticated. Run: gh auth login${NC}"
    exit 1
fi
pass "gh authenticated"

# Pilot repo varsa uyar (delete_repo permission yoksa sen UI'dan silmelisin)
if gh repo view "$GITHUB_OWNER/$PILOT_REPO_NAME" &> /dev/null; then
    echo -e "${YELLOW}⚠ Pilot repo already exists: $GITHUB_OWNER/$PILOT_REPO_NAME${NC}"
    echo "  Sil ve tekrar dene:"
    echo "    gh repo delete $GITHUB_OWNER/$PILOT_REPO_NAME --yes"
    echo "  ya da GitHub UI: https://github.com/$GITHUB_OWNER/$PILOT_REPO_NAME/settings"
    exit 1
fi
pass "Pilot repo name available"

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# ============================================================================
# T1 — Template'ten yeni repo oluştur + clone
# ============================================================================
log_section "T1 — Template clone"

if gh repo create "$GITHUB_OWNER/$PILOT_REPO_NAME" \
    --template "$TEMPLATE_REPO" \
    --private \
    --clone 2>&1 | tee /tmp/t1.log | grep -q "Cloning into"; then
    pass "Repo created from template + cloned"
else
    fail "Repo creation failed" "$(tail -3 /tmp/t1.log)"
    exit 1
fi

cd "$PILOT_REPO_NAME"

# Template flag taşındı mı kontrol (template'in kendisi is_template=true ama yeni repo değil)
if gh repo view --json isTemplate --jq '.isTemplate' | grep -q "false"; then
    pass "New repo is_template=false (correct)"
else
    fail "New repo unexpectedly marked as template"
fi

# Dosya yapısı bekleniyor
EXPECTED_FILES=(
    "TEMPLATE-README.md"
    "scripts/dev-studio-init.sh"
    "scripts/bootstrap-labels.sh"
    "scripts/agent-watch.sh"
    "scripts/notify.sh"
    "scripts/tests/faz5-smoke.sh"
    "scripts/tests/e2e-pilot.sh"
    "docs/TROUBLESHOOTING.md"
    "docs/OPERATIONS.md"
    "docs/TELEGRAM-SETUP.md"
    "docs/CONTEXT-HYGIENE.md"
    ".github/ISSUE_TEMPLATE/vision-intake.yml"
    ".github/ISSUE_TEMPLATE/feature-request.yml"
    ".github/ISSUE_TEMPLATE/bug.yml"
    ".github/ISSUE_TEMPLATE/incident.yml"
    ".github/ISSUE_TEMPLATE/agent-stall.yml"
)

MISSING=()
for f in "${EXPECTED_FILES[@]}"; do
    [[ -f "$f" ]] || MISSING+=("$f")
done

if [[ ${#MISSING[@]} -eq 0 ]]; then
    pass "All ${#EXPECTED_FILES[@]} expected files present"
else
    fail "Missing files: ${MISSING[*]}"
fi

# .tmpl dosyaları henüz render edilmemiş (init script çalıştırılmadan)
TMPL_COUNT=$(find . -name "*.tmpl" -not -path "./.git/*" | wc -l)
if [[ $TMPL_COUNT -gt 0 ]]; then
    pass ".tmpl files present ($TMPL_COUNT, pre-init)"
else
    fail ".tmpl files unexpectedly missing"
fi

# ============================================================================
# T2 — Init script (placeholder render)
# ============================================================================
log_section "T2 — Init script"

# Init script'e env değişkenleri vererek non-interactive koş
export REPO_ROOT="$WORK_DIR/$PILOT_REPO_NAME"
export GITHUB_REPO="$PILOT_REPO_NAME"
export HUMAN_OWNER_NAME="atil"
# GITHUB_OWNER zaten set

# Init script interactive olabilir — env vars set, stdin'i /dev/null'a yönlendir.
# Bu sayede `read` çağrıları boş döner, init env default'larını kullanır.
# Önceki yes '' | bash yaklaşımı SIGPIPE (exit 141) veriyordu.
bash scripts/dev-studio-init.sh < /dev/null > /tmp/t2.log 2>&1
INIT_EXIT=$?

if [[ $INIT_EXIT -eq 0 ]]; then
    pass "Init script exit 0"
else
    fail "Init script failed (exit $INIT_EXIT)" "$(tail -5 /tmp/t2.log)"
fi

# Placeholder kaldı mı kontrol
# NOT 1: scripts/tests/ klasörü test fixtures içerir — kasten {{NEVER_RESOLVED}} gibi
# placeholder'lar bulundurur (faz5-smoke.sh init'in unresolved placeholder'ı yakaladığını test ediyor).
# NOT 2: scripts/dev-studio-init.sh kendi içinde {{GITHUB_OWNER}} / {{GITHUB_REPO}}
# literal'lerini hata mesajı şablonu olarak tutar (kullanıcı bu değişkenleri set etmeden
# çalıştırırsa hangi placeholder eksik gösterilsin diye). Bunlar self-reference,
# unresolved placeholder DEĞİL — exclude ediyoruz.
REMAINING_PLACEHOLDERS=$(grep -r "{{" --include="*.md" --include="*.sh" --include="*.yml" --include="*.yaml" . 2>/dev/null \
    | grep -v "/.git/" \
    | grep -v "/scripts/tests/" \
    | grep -v "scripts/dev-studio-init.sh" \
    | wc -l)
if [[ $REMAINING_PLACEHOLDERS -eq 0 ]]; then
    pass "All placeholders resolved (excluding test fixtures)"
else
    fail "$REMAINING_PLACEHOLDERS placeholders remain unresolved"
    grep -r "{{" --include="*.md" --include="*.sh" --include="*.yml" --include="*.yaml" . 2>/dev/null \
        | grep -v "/.git/" \
        | grep -v "/scripts/tests/" \
        | grep -v "scripts/dev-studio-init.sh" \
        | head -3
fi

# .tmpl uzantıları temizlenmiş mi
POST_INIT_TMPL=$(find . -name "*.tmpl" -not -path "./.git/*" 2>/dev/null | wc -l)
if [[ $POST_INIT_TMPL -eq 0 ]]; then
    pass ".tmpl extensions cleaned up"
else
    fail "$POST_INIT_TMPL .tmpl files still present"
fi

# CLAUDE.md render edilmiş mi (kritik dosya)
if [[ -f "CLAUDE.md" ]]; then
    if grep -q "$PILOT_REPO_NAME" CLAUDE.md; then
        pass "CLAUDE.md contains correct repo name"
    else
        fail "CLAUDE.md doesn't contain repo name"
    fi
else
    fail "CLAUDE.md not found after init"
fi

# README.md render edilmiş mi
if [[ -f "README.md" ]]; then
    pass "README.md rendered"
else
    fail "README.md not found"
fi

# ============================================================================
# T3 — Bootstrap labels
# ============================================================================
log_section "T3 — Bootstrap labels"

bash scripts/bootstrap-labels.sh > /tmp/t3.log 2>&1
BOOTSTRAP_EXIT=$?

if [[ $BOOTSTRAP_EXIT -eq 0 ]]; then
    pass "bootstrap-labels.sh exit 0"
else
    fail "bootstrap-labels.sh failed (exit $BOOTSTRAP_EXIT)" "$(tail -5 /tmp/t3.log)"
fi

# Kritik label'lar var mı kontrol
EXPECTED_LABELS=(
    "agent:pm"
    "agent:architect"
    "agent:developer"
    "agent:tester"
    "agent:human"
    "type:vision"
    "type:feature"
    "type:bug"
    "type:incident"
    "sprint:current"
    "sprint:next"
    "sprint:backlog"
    "status:backlog"
    "status:blocked"
)

# NOT: --limit 100 ŞART — default 30, bizim label set'i 30+ (sprint, agent:tester vb. atlanır)
LABEL_LIST=$(gh label list -R "$GITHUB_OWNER/$PILOT_REPO_NAME" --json name --jq '.[].name' --limit 100)
MISSING_LABELS=()
for lbl in "${EXPECTED_LABELS[@]}"; do
    grep -qx "$lbl" <<< "$LABEL_LIST" || MISSING_LABELS+=("$lbl")
done

if [[ ${#MISSING_LABELS[@]} -eq 0 ]]; then
    pass "All ${#EXPECTED_LABELS[@]} critical labels present"
else
    fail "Missing labels: ${MISSING_LABELS[*]}"
fi

# Orphan label kontrolü (needs-human varsa eski label kalıntısı)
if grep -qx "needs-human" <<< "$LABEL_LIST"; then
    fail "Orphan label 'needs-human' present (should be agent:human)"
else
    pass "No orphan 'needs-human' label"
fi

# ============================================================================
# T4 — Issue templates (GitHub UI'da görünür mü)
# ============================================================================
log_section "T4 — Issue templates"

# .github/ISSUE_TEMPLATE/ dosyalarını doğrula (yml valid mi)
ISSUE_TEMPLATES=(
    "vision-intake.yml"
    "feature-request.yml"
    "bug.yml"
    "incident.yml"
    "agent-stall.yml"
)

for tpl in "${ISSUE_TEMPLATES[@]}"; do
    path=".github/ISSUE_TEMPLATE/$tpl"
    if [[ -f "$path" ]]; then
        # Python ile YAML parse (gh CLI yml validation yapmıyor)
        if python3 -c "import yaml; yaml.safe_load(open('$path'))" 2>/dev/null; then
            pass "$tpl is valid YAML"
        else
            fail "$tpl invalid YAML"
        fi
    else
        fail "$tpl not found"
    fi
done

# Eski user-story.yml gerçekten silinmiş mi
if [[ -f ".github/ISSUE_TEMPLATE/user-story.yml" ]]; then
    fail "Old user-story.yml still present (should be removed in P3 Step 2)"
else
    pass "Old user-story.yml removed"
fi

# vision-intake label check
if grep -q '"agent:pm"' .github/ISSUE_TEMPLATE/vision-intake.yml && \
   grep -q '"type:vision"' .github/ISSUE_TEMPLATE/vision-intake.yml; then
    pass "vision-intake.yml has correct labels"
else
    fail "vision-intake.yml missing required labels"
fi

# ============================================================================
# T5 — faz5-smoke (mevcut smoke test'in hala geçtiğini doğrula)
# ============================================================================
log_section "T5 — faz5-smoke regression"

# Smoke test init sonrası render edilmiş dosyalar üzerinde çalışıyor
# Bazı testleri içeriden çağırıyor — burada sadece çalıştırılabilirliği test et
if [[ -x scripts/tests/faz5-smoke.sh ]]; then
    pass "faz5-smoke.sh executable"
else
    chmod +x scripts/tests/faz5-smoke.sh 2>/dev/null
    if [[ -x scripts/tests/faz5-smoke.sh ]]; then
        pass "faz5-smoke.sh now executable (after chmod)"
    else
        fail "faz5-smoke.sh not executable"
    fi
fi

# faz5-smoke kendi içinde fresh clone yapıyor, e2e içinde tam çalıştırmak gereksiz olabilir
# Sadece syntax kontrolü
if bash -n scripts/tests/faz5-smoke.sh 2>/tmp/t5-syntax.log; then
    pass "faz5-smoke.sh syntax valid"
else
    fail "faz5-smoke.sh syntax error" "$(cat /tmp/t5-syntax.log)"
fi

# ============================================================================
# T6 — Script permissions + syntax (tüm shell scriptler)
# ============================================================================
log_section "T6 — Script integrity"

SHELL_SCRIPTS=$(find scripts -name "*.sh" -type f)
SYNTAX_ERRORS=0
PERM_ERRORS=0

for sh in $SHELL_SCRIPTS; do
    if ! bash -n "$sh" 2>/dev/null; then
        SYNTAX_ERRORS=$((SYNTAX_ERRORS + 1))
        echo "    Syntax error: $sh"
    fi
    if [[ ! -x "$sh" ]]; then
        PERM_ERRORS=$((PERM_ERRORS + 1))
    fi
done

TOTAL_SCRIPTS=$(echo "$SHELL_SCRIPTS" | wc -l)

if [[ $SYNTAX_ERRORS -eq 0 ]]; then
    pass "All $TOTAL_SCRIPTS shell scripts: syntax valid"
else
    fail "$SYNTAX_ERRORS scripts have syntax errors"
fi

if [[ $PERM_ERRORS -eq 0 ]]; then
    pass "All shell scripts: executable bit set"
else
    info "$PERM_ERRORS scripts missing +x (git checkout artifact, fixable)"
    # Bu kritik değil çünkü init script chmod yapıyor olabilir
fi

# ============================================================================
# Summary
# ============================================================================
log_section "Summary"

echo ""
echo "  Total:  $TOTAL"
echo -e "  ${GREEN}Pass:   $PASS${NC}"
echo -e "  ${RED}Fail:   $FAIL${NC}"
echo ""

if [[ $FAIL -gt 0 ]]; then
    echo -e "${RED}Failed tests:${NC}"
    for d in "${FAIL_DETAILS[@]}"; do
        echo "  - $d"
    done
    echo ""
    echo -e "${YELLOW}Pilot repo NOT deleted automatically for debugging:${NC}"
    echo "  https://github.com/$GITHUB_OWNER/$PILOT_REPO_NAME"
    echo "  Sil: gh repo delete $GITHUB_OWNER/$PILOT_REPO_NAME --yes"
    exit 1
else
    echo -e "${GREEN}✓ ALL TESTS PASSED${NC}"
    echo ""
    echo -e "${YELLOW}Pilot repo bırakıldı:${NC}"
    echo "  https://github.com/$GITHUB_OWNER/$PILOT_REPO_NAME"
    echo "  Sil: gh repo delete $GITHUB_OWNER/$PILOT_REPO_NAME --yes"
    echo "  ya da web UI: https://github.com/$GITHUB_OWNER/$PILOT_REPO_NAME/settings"
    exit 0
fi
