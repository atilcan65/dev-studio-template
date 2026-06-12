# Troubleshooting

Sık karşılaşılan sorunlar ve çözümleri. 5 kategori altında organize edilmiştir.

**Hızlı erişim:**
- [Setup & Init](#setup--init) — Yeni proje başlatma sorunları
- [Agent](#agent) — Ajan davranış sorunları
- [Label](#label) — GitHub label sorunları
- [Notify (Telegram)](#notify-telegram) — Bildirim sorunları
- [CI / PR](#ci--pr) — Pipeline ve PR sorunları

**İlk teşhis komutu (her sorunda önce bunu çalıştır):**

```bash
./scripts/agent-doctor.sh
```

Bu script env değişkenleri, label tutarlılığı, GitHub erişimi, Telegram bağlantısı ve script izinlerini kontrol eder. Aşağıdaki birçok senaryo bu çıktıdan anlaşılır.

---

## Setup & Init

### S1.1 — `dev-studio-init.sh` "placeholder resolved" demiyor, sessizce çıkıyor

**Belirti:**
```
$ ./scripts/dev-studio-init.sh
$
```
Hiçbir output yok, exit code 0.

**Sebep:** Init script bash strict mode'da çalışıyor ama bir komut sessizce başarısız oluyor (genelde `sed` macOS BSD-vs-GNU farkı veya `gh` auth yok).

**Çözüm:**

1. Verbose modda çalıştır:
   ```bash
   bash -x ./scripts/dev-studio-init.sh 2>&1 | tee /tmp/init-debug.log
   ```
2. Log'ta son komuta bak — orada patlamış.
3. `gh auth status` kontrol et:
   ```bash
   gh auth status
   ```
   **Beklenen output:**
   ```
   github.com
     ✓ Logged in to github.com account atilcan65 (oauth_token)
   ```
   Yoksa: `gh auth login`

4. Hala patlıyorsa `scripts/tests/faz5-smoke.sh` çalıştır — hangi T testi düşüyor görürsün.

### S1.2 — Placeholder render edilmemiş (`{{REPO_ROOT}}` dosyalarda hala var)

**Belirti:**
```bash
$ grep -r "{{" .
./scripts/agent-watch.sh:REPO_ROOT={{REPO_ROOT}}
```

**Sebep:** Init script çalıştırılmamış veya `.tmpl` dosyalardan render başarısız olmuş.

**Çözüm:**

1. Init script'i tekrar çalıştır:
   ```bash
   ./scripts/dev-studio-init.sh
   ```
   **Beklenen output (son 3 satır):**
   ```
   ✓ All placeholders resolved
   ✓ 12 templates rendered
   ✓ Init complete
   ```

2. `.tmpl` dosyaların hala var olup olmadığını kontrol et:
   ```bash
   find . -name "*.tmpl" -not -path "./.git/*"
   ```
   Bu liste boş olmalı. Doluysa render olmamış demektir.

3. Manuel render gerekiyorsa env değişkenlerini kontrol et:
   ```bash
   cat ~/.dev-studio-env
   ```
   `REPO_ROOT`, `GITHUB_OWNER`, `GITHUB_REPO`, `HUMAN_OWNER_NAME` dolu olmalı.

### S1.3 — Template'ten yeni proje açtım, klonladım ama hiçbir script çalışmıyor

**Belirti:**
```
$ ./scripts/dev-studio-start.sh
-bash: ./scripts/dev-studio-start.sh: Permission denied
```

**Sebep:** Git Windows checkout'larda executable bit kaybolur. Linux/macOS'ta ise zip indirme veya `gh repo clone` sonrası bazen +x bit'i kaybolur.

**Çözüm:**

```bash
chmod +x scripts/*.sh scripts/tests/*.sh
ls -la scripts/dev-studio-start.sh
```

**Beklenen output:**
```
-rwxr-xr-x 1 user user ... scripts/dev-studio-start.sh
```

Kalıcı düzeltme için repo köküne git ile commit et:
```bash
git add scripts/
git update-index --chmod=+x scripts/*.sh scripts/tests/*.sh
git commit -m "chore: fix executable bits on scripts"
```

### S1.4 — Init başarılı ama label'lar yok

**Belirti:** Issue açmaya çalışınca template'lerin önerdiği `agent:pm` label'ı mevcut değil.

**Sebep:** `bootstrap-labels.sh` çalıştırılmamış. Init script bunu otomatik çağırmıyor (template şu an böyle — gelecekte değişebilir).

**Çözüm:**

```bash
./scripts/bootstrap-labels.sh
```

**Beklenen output:**
```
✓ Created label: agent:pm
✓ Created label: agent:architect
...
✓ Created label: type:vision
✓ All labels synced (N created, 0 errors)
```

Sonra doğrula:
```bash
gh label list -R atilcan65/$REPO_NAME | wc -l
```
**Beklenen:** En az 30 label.

---

## Agent

### S2.1 — Agent issue almıyor (label var ama agent silent)

**Belirti:** Issue'ya `agent:pm` label'ı düştü, ama PM agent (Claude Code instance) bir şey yapmıyor.

**Sebep adayları:**
1. `agent-watch.sh` çalışmıyor (servis down)
2. Agent zaten başka issue üzerinde çalışıyor (busy)
3. Label yazımı yanlış (örn. `agent: pm` boşluklu)
4. Webhook/polling delay (max 30 sn)

**Çözüm:**

1. agent-watch durumunu kontrol et:
   ```bash
   ./scripts/agent-watch.sh status
   ```
   **Beklenen output (sağlıklı):**
   ```
   ✓ agent-watch running (PID 12345)
   ✓ Last poll: 2026-06-12 18:00:30 (5s ago)
   ✓ Queue depth: 0
   ```

2. Servis durduysa başlat:
   ```bash
   ./scripts/agent-watch.sh start
   ```

3. Label'ı kontrol et (boşluk olmamalı):
   ```bash
   gh issue view 42 --json labels --jq '.labels[].name'
   ```
   **Beklenen:** `agent:pm` (iki nokta sonrası boşluk YOK)

4. Agent busy ise state file'a bak:
   ```bash
   cat .state/agent-state.json | jq '.agents.pm'
   ```
   **Beklenen (sağlıklı, idle):**
   ```json
   {"status": "idle", "current_issue": null, "last_active": "..."}
   ```

### S2.2 — Agent stall (15 dakikadan fazla "in_progress" ama ilerleme yok)

**Belirti:** state'te `current_issue` dolu, ama yorum veya commit yok.

**Çözüm:**

1. Agent-stall issue aç (template var):
   ```bash
   gh issue create --template agent-stall.yml
   ```

2. Eğer biliyorsan: reprime workflow:
   ```bash
   ./scripts/reprime-agent.sh <agent-name> <issue-number>
   ```
   Detay için: [docs/CONTEXT-HYGIENE.md](CONTEXT-HYGIENE.md)

3. Zorla idle'a çevir (son çare):
   ```bash
   ./scripts/agent-state.sh reset <agent-name>
   ```
   **Beklenen output:**
   ```
   ✓ Agent <name> reset to idle. Previous issue #42 marked agent:human.
   ```

### S2.3 — Agent yanlış issue'yu alıyor

**Belirti:** Architect, `agent:pm` label'lı issue'yu işliyor.

**Sebep:** `agent-watch.sh` config'inde label routing yanlış veya iki agent aynı label'ı dinliyor.

**Çözüm:**

1. Watch config'i kontrol et:
   ```bash
   grep -A 2 "AGENT_LABELS" ./scripts/agent-watch.sh
   ```
   Her label sadece bir agent'a route etmeli.

2. Label-to-agent mapping doğrula (doctor script bunu yapıyor):
   ```bash
   ./scripts/agent-doctor.sh --check label-routing
   ```

### S2.4 — "needs-human" label'ı var ama bildirim gelmedi

**Belirti:** Eski label `needs-human` kullanılmış (artık `agent:human` standardı).

**Çözüm:**

```bash
# Eski label kalmışsa yeniyle değiştir
gh issue list -R atilcan65/$REPO_NAME --label "needs-human" --json number --jq '.[].number' | while read num; do
  gh issue edit $num --remove-label "needs-human" --add-label "agent:human"
done
```

Gelecekte tutarsızlığı önlemek için: `bootstrap-labels.sh`'in son halinde sadece `agent:human` var; `needs-human` orphan label olabilir, silinmeli:
```bash
gh label delete "needs-human" --confirm
```

---

## Label

### S3.1 — Label drift (bir label silinmiş, başka renkte oluşturulmuş)

**Belirti:** İki proje arasında label setleri tutmuyor, renkler farklı.

**Çözüm:** `bootstrap-labels.sh` idempotent — varlığı kontrol eder, yoksa create, varsa update (renk + description).

```bash
./scripts/bootstrap-labels.sh
```

**Beklenen output:**
```
- Label 'agent:pm' exists, updating color #ededed
✓ Updated label: agent:pm
+ Label 'sprint:current' missing, creating
✓ Created label: sprint:current
✓ All labels synced (2 created, 8 updated, 0 errors)
```

### S3.2 — `gh: label already exists` hatası

**Belirti:**
```
HTTP 422: Validation Failed (label already exists)
```

**Sebep:** `bootstrap-labels.sh`'in eski versiyonu (idempotent değil) veya manuel `gh label create` denenmiş.

**Çözüm:** Güncel `bootstrap-labels.sh` kullan (template'in latest main'inden çek). Manuel ekleme yapma.

### S3.3 — İki label çakışıyor (örn. hem `type:bug` hem `type:feature`)

**Belirti:** Bir issue'da iki ana type label'ı var.

**Çözüm:** PM agent kararını PM'e bırak — issue'ya yorum yaz, doğru label'ı PM koyacak. Manuel temizleme:

```bash
gh issue edit <num> --remove-label "type:bug"  # ya da type:feature, hangisi yanlışsa
```

---

## Notify (Telegram)

### S4.1 — Telegram silent (notify.sh çalışıyor ama mesaj gelmiyor)

**Belirti:**
```
$ ./scripts/notify.sh -l info "test"
$ echo $?
0
```
Exit 0 ama Telegram'a düşmüyor.

**Çözüm:**

1. Env değişkenlerini kontrol et:
   ```bash
   source ~/.dev-studio-env
   echo "Token: ${TELEGRAM_BOT_TOKEN:0:10}..."
   echo "Chat: $TELEGRAM_CHAT_ID"
   ```
   **Beklenen:** İkisi de boş olmamalı.

2. Direkt curl ile test:
   ```bash
   curl -s "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
     -d chat_id="$TELEGRAM_CHAT_ID" \
     -d text="test"
   ```
   **Beklenen output:**
   ```json
   {"ok":true,"result":{...}}
   ```
   Hata varsa: `{"ok":false,"description":"..."}` — açıklama yol gösterir.

3. notify.sh içindeki STDERR'i göster (script normalde yutuyor):
   ```bash
   bash -x ./scripts/notify.sh -l info "test" 2>&1 | tail -20
   ```

Detaylı setup: [docs/TELEGRAM-SETUP.md](TELEGRAM-SETUP.md)

### S4.2 — `chat not found` hatası

**Belirti:** curl response'unda `"description":"Bad Request: chat not found"`.

**Sebep:** `TELEGRAM_CHAT_ID` yanlış veya bot ile sohbet başlatılmamış.

**Çözüm:**

1. Telegram'da bot'a "/start" yaz (sohbet başlat).
2. Chat ID'yi yeniden al:
   ```bash
   curl -s "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/getUpdates" | jq '.result[-1].message.chat.id'
   ```
3. `~/.dev-studio-env`'i güncelle.

### S4.3 — `Forbidden: bot was blocked by the user`

**Sebep:** Kullanıcı bot'u engellemiş.

**Çözüm:** Telegram'da bot'u aç → "Unblock" → tekrar "/start". Veya farklı bir chat (grup) kullan.

### S4.4 — Mesaj geliyor ama format bozuk

**Belirti:** Mesajda HTML tag'leri ham görünüyor (`<b>...</b>`).

**Çözüm:** notify.sh'ye `parse_mode` parametresi ekli mi kontrol et:
```bash
grep "parse_mode" ./scripts/notify.sh
```
**Beklenen:** `-d parse_mode=HTML` veya `Markdown` görmeli.

---

## CI / PR

### S5.1 — Conventional Commits check fail

**Belirti:** PR'da "Conventional Commits" check kırmızı.

**Sebep:** Commit mesajı format'a uymuyor. Geçerli prefix'ler:
`feat`, `fix`, `chore`, `docs`, `refactor`, `test`, `style`, `perf`, `ci`, `build`, `revert`

**Çözüm:**

```bash
# Son commit'i amend ile düzelt
git commit --amend -m "feat(scope): kısa açıklama"
git push --force-with-lease
```

**Doğru format örnekleri:**
```
feat(p3-step2): add vision-intake template
fix(notify): handle empty TELEGRAM_CHAT_ID
chore(deps): bump gh-cli to 2.40
```

### S5.2 — AI Code Review timeout

**Belirti:** "AI Code Review" check 5+ dakikadır pending.

**Sebep:** GitHub Actions runner gecikmesi veya AI servis yavaş.

**Çözüm:**

1. 10 dakika bekle.
2. Workflow run'ı re-run et:
   ```bash
   gh run list --workflow="AI PR Review" --limit 1 --json databaseId --jq '.[0].databaseId' | xargs gh run rerun
   ```
3. Hala fail ise: workflow YAML'ında `timeout-minutes` artır:
   ```yaml
   jobs:
     review:
       timeout-minutes: 15  # default 5
   ```

### S5.3 — Lint & Test fail (shellcheck)

**Belirti:** "Lint & Test" check kırmızı, log'ta `shellcheck` hatası.

**Çözüm:**

Lokal koş:
```bash
shellcheck scripts/*.sh
```

**Yaygın uyarılar:**
- `SC2086` — değişkenleri quote'la: `"$VAR"`
- `SC2155` — declare ve assign ayır: `local x; x=$(cmd)`
- `SC2034` — kullanılmayan değişken, gerçekten gereksizse sil

Belirli kural istisnası gerekirse satır başına yorum:
```bash
# shellcheck disable=SC2086
gh issue list --label $LABEL
```

### S5.4 — Direct push to main reddedildi

**Belirti:**
```
remote: error: GH006: Protected branch update failed
remote: error: 1 of 1 required pull request reviews are missing
```

**Sebep:** Main branch protected. Bu kasıtlı — direkt push yasak.

**Çözüm:** Her zaman PR ile gel. Hatta revert bile PR ile:
```bash
git revert <commit-sha>
git checkout -b revert/<commit-sha>
git push -u origin revert/<commit-sha>
gh pr create --title "revert: ..." --body "..."
```

### S5.5 — Branch silinmedi merge'den sonra

**Belirti:** `gh pr merge` sonrası feature branch hala var.

**Çözüm:**

```bash
gh pr merge <num> --squash --delete-branch
```

`--delete-branch` flag'i ŞART. Unutulmuşsa manuel:
```bash
git push origin --delete feat/old-branch
git fetch -p
```

---

## İlgili dokümanlar

- [docs/OPERATIONS.md](OPERATIONS.md) — Günlük operasyon rehberi
- [docs/CONTEXT-HYGIENE.md](CONTEXT-HYGIENE.md) — Agent context kaybı + reprime
- [docs/TELEGRAM-SETUP.md](TELEGRAM-SETUP.md) — Bot ilk kurulum
- [TEMPLATE-README.md](../TEMPLATE-README.md) — Genel mimari ve label sistemi

## Bu rehberde olmayan bir sorun var

1. `./scripts/agent-doctor.sh --verbose` çıktısını kaydet.
2. Issue aç: `gh issue create --template incident.yml` (canlı sistem) veya bug.yml (normal hata).
3. PR ile bu dosyayı güncelle — sonraki kişi için.
