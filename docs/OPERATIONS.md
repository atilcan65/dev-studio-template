# Operations Guide

Günlük operasyon rehberi. Yeni proje açmaktan agent monitoring'e, sprint yönetiminden backup'a kadar her şey burada.

**Hedef kitle:** Bu template'i bir projede ilk kez kuran ya da rutin operasyon yapan kişi (genellikle insan operatör = sen).

**İçindekiler:**
1. [Yeni proje başlatma](#1-yeni-proje-başlatma)
2. [Sprint yönetimi](#2-sprint-yönetimi)
3. [Agent monitoring](#3-agent-monitoring)
4. [Reprime workflow](#4-reprime-workflow)
5. [PR review akışı](#5-pr-review-akışı)
6. [Backup & restore](#6-backup--restore)
7. [Sık kullanılan komutlar (cheatsheet)](#7-cheatsheet)

---

## 1. Yeni proje başlatma

Template'ten sıfırdan bir proje çıkarmak için.

### 1.1 GitHub UI üzerinden (önerilen)

1. `https://github.com/atilcan65/dev-studio-template` aç.
2. Sağ üstte yeşil **"Use this template"** → **"Create a new repository"**.
3. Yeni repo bilgilerini gir:
   - **Owner:** atilcan65 (veya organizasyon)
   - **Repository name:** `my-new-project`
   - **Description:** kısa açıklama
   - **Visibility:** Private (önerilen)
4. **"Create repository from template"** bas.

### 1.2 Lokal clone + init

```bash
# Klonla
gh repo clone atilcan65/my-new-project
cd my-new-project

# Init script — placeholder'ları doldur
./scripts/dev-studio-init.sh
```

Init script şunları soracak:
```
REPO_ROOT [/home/atilcan/my-new-project]:
GITHUB_OWNER [atilcan65]:
GITHUB_REPO [my-new-project]:
HUMAN_OWNER_NAME [atil]:
```
Enter'larsa default'u kabul eder.

**Beklenen output (son 5 satır):**
```
✓ Resolved 4 placeholders
✓ Rendered 12 template files
✓ Removed .tmpl extensions
✓ Created ~/.dev-studio-env
✓ Init complete — next: bootstrap-labels.sh
```

### 1.3 Label setini kur

```bash
./scripts/bootstrap-labels.sh
```

**Beklenen:** N label oluşturuldu/güncellendi, 0 hata.

### 1.4 Telegram kur

[docs/TELEGRAM-SETUP.md](TELEGRAM-SETUP.md) takip et:
- BotFather'dan bot oluştur
- Chat ID al
- `~/.dev-studio-env`'e ekle

Sonra test:
```bash
./scripts/notify.sh -l info "test from $(hostname)"
```
Telegram'a "test from ..." gelmeli.

### 1.5 Vision intake (proje vizyonu)

```bash
gh issue create --template vision-intake.yml
```

9 alan doldur. PM agent bunu alıp Architect'e devredecek, sonra epic'lere kıracak.

**Bu sadece bir kez yapılır — proje başlangıcında.**

### 1.6 Agent watch servisini başlat

```bash
./scripts/agent-watch.sh start
```

**Beklenen:**
```
✓ agent-watch started (PID 12345)
✓ Polling every 30s
✓ Initial sync complete: 0 open issues
```

Bu noktada sistem hazır — yeni issue'lar label'larına göre otomatik agent'lara route edilecek.

---

## 2. Sprint yönetimi

Sprint = `sprint:current` label'lı issue'lar set'i. Aktif sprint 1 tanedir.

### 2.1 Sprint başlatma

PM agent vision'dan epic'leri kırıp issue'lar açtıktan sonra:

```bash
# PM önerdiği issue'ları sprint'e taşı
gh issue edit 5 --add-label "sprint:current"
gh issue edit 6 --add-label "sprint:current"
gh issue edit 7 --add-label "sprint:current"

# Yeni sprint'in başladığını duyur
./scripts/notify.sh -l info "[ORCH→ALL] Sprint started: 3 issues (#5, #6, #7)"
```

### 2.2 Sprint sırasında

`agent-watch.sh` otomatik route ediyor. Sen sadece bekle ve PR'lara review yap.

İlerlemeyi görmek için:
```bash
./scripts/agent-state.sh sprint-status
```

**Beklenen output:**
```
Sprint: current (3 issues)
├─ #5 [type:feature] developer: in_progress (2h 15m)
├─ #6 [type:feature] tester: in_progress (45m)
└─ #7 [type:feature] backlog (waiting for dependency #5)
```

### 2.3 Sprint kapanışı

Tüm `sprint:current` issue'ları "closed" olduğunda:

```bash
# Eski sprint label'ı kaldır, backlog'a at (geçmiş referans için label kalsın)
gh issue list --label "sprint:current" --state closed --json number --jq '.[].number' | while read n; do
  gh issue edit $n --remove-label "sprint:current" --add-label "sprint:backlog"
done

# Yeni sprint için sprint:next'i sprint:current yap
gh issue list --label "sprint:next" --json number --jq '.[].number' | while read n; do
  gh issue edit $n --remove-label "sprint:next" --add-label "sprint:current"
done
```

Retrospektif için PR/issue özetini çıkar:
```bash
gh pr list --state merged --search "merged:>$(date -d '14 days ago' +%Y-%m-%d)" --json number,title,mergedAt
```

---

## 3. Agent monitoring

### 3.1 Anlık durum

```bash
./scripts/agent-watch.sh status
```

**Beklenen (sağlıklı):**
```
✓ agent-watch running (PID 12345)
✓ Last poll: 2026-06-12 18:00:30 (5s ago)
✓ Queue depth: 0
✓ Agents:
  pm:         idle    (last activity: 12m ago)
  architect:  idle    (last activity: 2h ago)
  developer:  busy    (#42, started 35m ago)
  tester:     idle    (last activity: 4h ago)
```

### 3.2 Detaylı health check

```bash
./scripts/agent-doctor.sh
```

**Kontrol ettiği şeyler:**
- Env değişkenleri (REPO_ROOT, GITHUB_OWNER, GITHUB_REPO, TELEGRAM_*)
- GitHub erişim (`gh auth status`)
- Telegram bağlantı (curl test)
- Label seti tam mı (bootstrap-labels.sh ile uyumlu mu)
- Script izinleri (+x)
- Disk doluluk (.state/, logs/)
- Stale agent'lar (15dk+ in_progress)

**Beklenen output (sağlıklı):**
```
[1/8] Env vars ........... ✓ OK
[2/8] GitHub auth ........ ✓ OK (user: atilcan65)
[3/8] Telegram .......... ✓ OK (test message sent)
[4/8] Label set ......... ✓ OK (30/30 expected)
[5/8] Script perms ...... ✓ OK
[6/8] Disk usage ........ ✓ OK (.state: 4.2K, logs: 12M)
[7/8] Stale agents ...... ✓ OK (0 stale)
[8/8] State integrity ... ✓ OK

✓ All checks passed
```

Verbose mod (her check'in detayını gör):
```bash
./scripts/agent-doctor.sh --verbose
```

### 3.3 Log'lar

Logs `logs/` klasöründe (init script tarafından oluşturuluyor):
```bash
tail -f logs/agent-watch.log         # canlı watch loop
tail -f logs/agent-pm.log            # PM agent yorumları
tail -f logs/notify.log              # Telegram mesajları
```

### 3.4 Hızlı sağlık kontrolü (alias önerisi)

`.bashrc` veya `.zshrc`'ye:
```bash
alias ds-status='./scripts/agent-watch.sh status'
alias ds-doc='./scripts/agent-doctor.sh'
alias ds-log='tail -f logs/agent-watch.log'
```

---

## 4. Reprime workflow

Agent uzun context'ten dolayı tutarsız davranmaya başladıysa, "context hygiene" gerekir. Detaylı doktrin: [docs/CONTEXT-HYGIENE.md](CONTEXT-HYGIENE.md).

### 4.1 Reprime ne zaman gerekli

- Agent kendi rolünü unutmuş gibi davranıyor (ör. developer architect kararı veriyor)
- Agent eski (closed) issue'ya yorum yazıyor
- Agent labelları yanlış kullanmaya başlamış
- Sprint geçti ama agent hala önceki sprint'in kontekstinde

### 4.2 Reprime komutu

```bash
./scripts/reprime-agent.sh <agent-name> <issue-number>
```

**Örnek:**
```bash
./scripts/reprime-agent.sh developer 42
```

**Beklenen output:**
```
✓ Loaded role prime: scripts/kickoff/developer.txt
✓ Fetched issue #42 + last 10 comments
✓ Generated reprime payload (2.3 KB)
✓ Posted to Telegram → developer chat
✓ Issue commented with reprime notice
```

Sonra agent'ı yeniden çağır (Telegram mesajını kopyala → Claude Code'a paste).

### 4.3 Otomatik reprime tetikleyici

Şu durumlarda `agent-watch.sh` otomatik reprime tetikler:
- Aynı issue'da 5+ ardışık yorum (loop riski)
- 30+ dakika aynı issue'da kal (stall riski)
- Agent'tan ardışık 2 hata mesajı

Bu thresholds `scripts/agent-watch.sh`'in üst kısmında:
```bash
REPRIME_AFTER_COMMENTS=5
REPRIME_AFTER_MINUTES=30
```

---

## 5. PR review akışı

### 5.1 PR açıldığında

`agent-watch.sh` otomatik PR'a Tester'ı atar (agent:tester label'ı). Tester ilk review yapar.

Tester yeşil verirse PR'a `status:ready-for-human` label'ı düşer + sana Telegram gelir.

### 5.2 İnsan review (sen)

```bash
# PR detayını gör
gh pr view <num>

# CI durumu
gh pr checks <num>

# Diff
gh pr diff <num>
```

### 5.3 Merge

**Sadece squash merge** kullan (linear history için).

```bash
gh pr merge <num> --squash --delete-branch
```

**`--delete-branch` flag'i ZORUNLU** — feature branch'lerin birikmesini önler.

### 5.4 Merge sonrası

`agent-watch.sh` otomatik:
- Issue'yu kapatır (linked issue varsa)
- Telegram'a duyurur: `[ORCH→ALL] PR #15 merged, issue #42 closed`
- Sprint durumunu günceller

---

## 6. Backup & restore

### 6.1 Neyi yedeklemek gerekir

| Dosya/Klasör | Önem | Frekans |
|---|---|---|
| `~/.dev-studio-env` | Kritik (token'lar) | İlk setup + her değişiklikte |
| `.state/agent-state.json` | Orta (regenerate edilebilir) | Günlük |
| `logs/` | Düşük | Haftalık |
| `docs/decisions/` | Yüksek (ADR'lar git'te ama yedek iyidir) | Git push ile zaten |

### 6.2 State backup

```bash
mkdir -p backups
cp .state/agent-state.json backups/agent-state-$(date +%Y%m%d-%H%M).json
```

Bunu cron'a koy (günlük):
```cron
0 2 * * * cd /home/atilcan/my-project && cp .state/agent-state.json backups/agent-state-$(date +\%Y\%m\%d).json
```

### 6.3 Label snapshot (referans için)

```bash
gh label list --json name,color,description > backups/labels-$(date +%Y%m%d).json
```

Restore (label çakışırsa bootstrap script daha güvenli, bunu nadiren kullan):
```bash
jq -r '.[] | "gh label create \"\(.name)\" --color \(.color) --description \"\(.description)\" --force"' backups/labels-20260612.json | bash
```

### 6.4 .env backup (şifreli)

`.env` git'e gitmemeli (zaten `.gitignore`'da). Manuel yedek için:
```bash
# GPG ile şifrele
gpg -c ~/.dev-studio-env  # şifre sorar, .gpg dosyası oluşur
mv ~/.dev-studio-env.gpg backups/
```

Restore:
```bash
gpg -d backups/.dev-studio-env.gpg > ~/.dev-studio-env
chmod 600 ~/.dev-studio-env
```

---

## 7. Cheatsheet

### Günlük 5 komut

```bash
./scripts/agent-watch.sh status       # genel durum
./scripts/agent-doctor.sh             # sağlık check
./scripts/agent-state.sh sprint-status  # sprint progress
tail -f logs/agent-watch.log          # canlı log
gh pr list --state open               # bekleyen PR'lar
```

### Yeni proje (tek seferlik)

```bash
gh repo create my-new-project --template atilcan65/dev-studio-template --private --clone
cd my-new-project
./scripts/dev-studio-init.sh
./scripts/bootstrap-labels.sh
# Telegram setup → docs/TELEGRAM-SETUP.md
gh issue create --template vision-intake.yml
./scripts/agent-watch.sh start
```

### Sorun çıkınca

```bash
./scripts/agent-doctor.sh --verbose   # ilk teşhis
# bulguya göre:
./scripts/agent-watch.sh restart       # watch servis donduysa
./scripts/agent-state.sh reset <agent> # agent stuck'sa (son çare)
./scripts/reprime-agent.sh <agent> <issue>  # context drift varsa
```

### Sprint kapanışı

```bash
# closed'ları backlog'a:
gh issue list --label "sprint:current" --state closed --json number --jq '.[].number' \
  | while read n; do gh issue edit $n --remove-label "sprint:current" --add-label "sprint:backlog"; done

# next → current:
gh issue list --label "sprint:next" --json number --jq '.[].number' \
  | while read n; do gh issue edit $n --remove-label "sprint:next" --add-label "sprint:current"; done
```

### PR merge

```bash
gh pr merge <num> --squash --delete-branch
```

---

## İlgili dokümanlar

- [docs/TROUBLESHOOTING.md](TROUBLESHOOTING.md) — Sorun → çözüm rehberi
- [docs/CONTEXT-HYGIENE.md](CONTEXT-HYGIENE.md) — Reprime doktrini
- [docs/TELEGRAM-SETUP.md](TELEGRAM-SETUP.md) — Bot kurulumu
- [TEMPLATE-README.md](../TEMPLATE-README.md) — Mimari ve label sistemi
