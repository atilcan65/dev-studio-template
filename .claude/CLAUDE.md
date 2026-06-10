# Project Context — for all agents

> Read this file at the start of every session. It is the single source of truth for product, team, and process context.

## Product
- **Name**: atilprojects
- **Vision**: <one paragraph from `docs/product/vision.md`>
- **Current sprint**: see `docs/sprints/current/plan.md`
- **Source of truth for backlog**: GitHub Project board (Projects v2)

## Team (5 agents + 1 human)
| Role | Who | Soul file |
|---|---|---|
| Human owner | atil can | — |
| Orchestrator | Claude Code / MiniMax-M3 | `.claude/agents/orchestrator.md` |
| Product Manager | Claude Code / MiniMax-M3 | `.claude/agents/product-manager.md` |
| Architect | Claude Code / MiniMax-M3 | `.claude/agents/architect.md` |
| Developer | Claude Code / MiniMax-M3 | `.claude/agents/developer.md` |
| Tester | Claude Code / MiniMax-M3 | `.claude/agents/tester.md` |
| Test Runner / Incident Bot | Codex CLI / gpt-5.5 | (separate process, see `scripts/codex-runner.sh`) |

## Process
- **Scrum** with 2-week sprints.
- **GitHub Projects v2** is the board. Columns: Backlog → Ready → In Progress → In Review → Done.
- **All PRs are draft** until Tester signoff + human approval.
- **Branch protection** on `main`: no direct push (enforced by local pre-push hook + human discipline), 1 human approval required, CI green.
- **Conventional commits**: `feat(scope): ...`, `fix(scope): ...`, `chore(scope): ...`.
- **Daily standup** at 09:00 Europe/Istanbul (auto-triggered or human-initiated).
- **Health check** every 30 minutes (systemd timer).

## Tech stack
<FILL IN: languages, frameworks, infra. Architect maintains this.>

## Definition of Done
A story is "Done" only if ALL of these hold:
1. All acceptance criteria pass automated tests.
2. Code merged to `main` via PR with human approval.
3. CI is green on `main` post-merge.
4. Docs updated (README, changelog, ADR if applicable).
5. Project card moved to Done by orchestrator.
6. No new P0/P1 bugs filed against the story within 24h.

## Communication conventions
- **Issues**: use templates in `.github/ISSUE_TEMPLATE/`.
- **PR comments**: structured (see developer.md and tester.md).
- **Cross-agent**: never DM-style. Always via GitHub Issue or PR comment.
- **Escalation to human**: Telegram (`scripts/notify.sh -l human`) + GitHub `@`-mention to @atilcan65.

## Auto-Ping Hard-Rule (Cross-Agent Communication)

**TL;DR**: Asla insandan "şunu söyle" / "şunu ilet" / "şuna haber ver" diye isteme. Kendin yap.

### The Rule

İki durumda **insandan onay almadan, doğrudan** `scripts/notify.sh -l <role>` ile Telegram ping at:

1. **Görev tamamlandığında** → bir sonraki agent'a "senin sıran" pingi at
2. **Başka agent'tan input bekler hale geldiğinde** → kim'i, ne için beklediğini explicit söyle

### Format

```
[FROM→TO] <≤80 char reason>
<PR/Issue link>
<≤2 satır context (opsiyonel)>
```

Örnek:
```
scripts/notify.sh -l architect "[DEV→ARCH] PR #20 ready for design-alignment review
https://github.com/atilcan65/atilprojects/pull/20
Check: import path, bind string, sync handler"
```

### Hangi durumda kime

| Senin durumun | Auto-ping → | Tipik mesaj |
|---|---|---|
| PR draft açtın, review istiyorsun | architect + tester | `[DEV→ARCH+TEST] PR #N ready for review` |
| Review verdin (🟢/🟡/🔴) | developer | `[ARCH→DEV] PR #N approved` / `PR #N has suggestions` |
| Sign-off verdin (tester) | developer | `[TEST→DEV] PR #N tests accepted` |
| Story sizing'i bitirdin | orchestrator | `[<ROLE>→ORCH] sizing posted on issue #N` |
| Grooming/scope-change tamamlandı | orchestrator | `[PM→ORCH] backlog refreshed, issue #N closed` |
| ADR yazdın | dev + tester + orch | `[ARCH→ALL] ADR-NNNN accepted, see docs/decisions/` |
| Bug filed | developer + orch | `[TEST→DEV] bug #N filed, P0/P1` |
| Sprint ceremony zamanı | all | `[ORCH→ALL] standup in 5 min, post your status` |
| Blocked > 1h | orch + human | `[<ROLE>→ORCH+HUMAN] blocked on X, need decision` |

### What you do NOT need to ask

- ❌ "Sana mesaj atayım mı?" / "Bunu iletmemi ister misin?" — **Hayır, direkt at.**
- ❌ "Atilcan, sen architect'e söyler misin?" — **Senin işin, sen söyle.**
- ❌ "Bekleyeyim mi, ping atayım mı?" — **Ping at, sonra bekle.**

### Eskalasyon istisnaları (HUMAN'a ping atılacak durumlar)

Bu durumlar **soul-level decisions** — auto-ping yetmez, HUMAN'a explicit eskalasyon:

- Branch protection / `.github/workflows/` değişikliği gerekiyor
- Sprint scope-change (story add/remove/swap)
- ADR'ler arasında conflict var, agent-level çözülmüyor
- Bir agent 2 kez refused / stuck loop'ta
- Production deploy/release kararı

Bunlarda: `scripts/notify.sh -l human "<eskalasyon nedeni> + öneri + link"`.

### Why this rule exists

Insan "kurye" değil. Insan **gate-keeper**. Sen agent olarak peer'larınla doğrudan konuşmalısın — GitHub + Telegram + heartbeat senin iletişim kanallarındır. Insan sadece merge/scope-change kararı verir.

## Autonomy Loop — GitHub-native wake-up (ADR-0002)

**TL;DR**: Senin work queue'n GitHub'ın kendisi. `scripts/agent-watch.sh <your-role>` ile her 60 saniyede bir kendi queue'una bak. İnsanın seni uyandırmasını bekleme.

### Why this exists

`scripts/notify.sh` Telegram'a yazar. Telegram'ı **insan** okur, agent'lar okumaz. Yani Auto-Ping tek başına yetmez — peer agent ping'i görmez. Bu boşluğu GitHub kapatır: her ping'in **bir GitHub artefact eşi** vardır (issue label, PR comment, mention, label change). Agent'lar bunu polling ile fark eder.

### The loop (her session başında, her aksiyon sonrası)

```bash
bash scripts/agent-watch.sh <your-role>
```

Çıktı JSON:

```json
{
  "role": "<your-role>",
  "polled_at_utc": "...",
  "new_events": [
    { "id": "...", "kind": "issue_assigned|pr_review_requested|pr_comment_mention|label_change",
      "number": 42, "title": "...", "url": "...", "updated_at": "...",
      "context": { ... } }
  ],
  "next_poll_sec": 60
}
```

`new_events` boşsa: 60 saniye uyu, tekrar bak. Dolu ise: her event için aksiyon al, sonra tekrar bak.

### Trigger → action mapping (kind-by-kind)

| `kind` | Anlamı | Senin aksiyonun |
|---|---|---|
| `issue_assigned` | Sana `agent:<your-role>` label'lı yeni iş atandı | Story'i oku, branch aç, çalışmaya başla |
| `pr_review_requested` | `cc:<your-role>` label'lı bir PR review bekliyor | PR'ı oku, review yap, comment + auto-ping |
| `pr_comment_mention` | Bir peer comment'inde sana `@<your-role>` diye seslendi | Comment'i oku, ilgili aksiyonu al veya yanıt yaz |
| `label_change` | (Orchestrator-only lens) Board'da bir label değişti | Sprint plan / WIP limit kontrolü |

### State management

- State dosyan: `/var/log/dev-studio/agent-state/<your-role>.json`
- `agent-watch.sh` her event'i otomatik olarak `processed_event_ids` listesine ekler — aynı event'i iki kez işlemezsin
- `last_seen_utc` her poll sonrası güncellenir
- Eğer event'i yanlışlıkla skip ettiğini düşünüyorsan: state file'ı manuel edit et veya `scripts/agent-state.sh set <role> last_seen_utc <ISO-timestamp>` ile geri sar

### Polling cadence

- **Varsayılan**: 60 saniye (`AGENT_POLL_INTERVAL_SEC=60`)
- **Burst mode**: aktif iş yaparken (PR review yazma, test koşturma, vb.) loop pause edilir; iş bitince devam eder
- **Hızlandırma**: kritik handoff bekliyorsan `scripts/agent-state.sh set <role> poll_interval_sec 15` ile 15s'ye düşür, sonra geri al

### What you do NOT do

- ❌ İnsanın "şimdi şu story'e başla" demesini bekleme — atandığında **kendiliğinden** başla
- ❌ Aynı event'i tekrar tekrar işleme — `processed_event_ids` zaten engelliyor, ama tool call'larını tekrar etme
- ❌ Polling'i 30 saniyenin altına düşürme — GitHub API rate limit
- ❌ State dosyasını sil/reset etme — last_seen ileri sarılı, geçmiş event'ler kaybolur
- ❌ İnsan'a "polling yapayım mı?" diye sorma — ADR-0002 zaten karar verildi, sen sadece uygula

### Coupling with Auto-Ping Hard-Rule

Auto-Ping (`notify.sh`) ve Autonomy Loop (`agent-watch.sh`) **birlikte** çalışır:

1. Sen iş bitirip Auto-Ping atarsın → Telegram'a düşer (insan görür) **VE** GitHub'da label/comment olarak işlenir (peer görür)
2. Peer agent kendi `agent-watch.sh` loop'unda bu GitHub artefact'i fark eder → wake-up sinyali
3. Peer aksiyon alır → kendi Auto-Ping'ini atar → cycle devam eder

**Kural**: her `notify.sh` çağrısı *aynı zamanda* bir GitHub artefact'i tetiklemelidir (label ekleme, comment yazma, assignee/cc değiştirme). Sadece Telegram'a yazıp GitHub'a yazmamak = peer'ı uyandırmamak.

## Handoff Label Discipline — the universal contract

**TL;DR**: `cc:*` etiketleri "topun kimde olduğunu" gösterir. Bir aksiyon bitince **kendi** `cc:<your-role>` label'ını çıkar, **sonraki rolün** `cc:<next-role>` label'ını ekle. Aksi halde watcher loop seni aynı PR'da tekrar tekrar uyandırır ya da sistem freeze olur.

### The contract (gelişmesi gereken her PR/Issue için)

Her agent **kendi işini bitirdiğinde**:

1. **Çıkar**: `gh pr edit N --remove-label cc:<your-role>` (kendi top'unu indir)
2. **Ekle**: `gh pr edit N --add-label cc:<next-role>` (sıradaki rolü işaretle) — veya `status:ready` (insan için sinyal)
3. **Auto-ping**: `scripts/notify.sh -l <next-role> "[<YOU>→<NEXT>] PR #N <reason>"` (Telegram mirror)

Bu üç adım **atomik tek bir hareket** olarak düşünülür. Birini atlamak loop'u kırar.

### Label semantik sözlüğü

| Label | Anlamı | Kim koyar | Kim kaldırır |
|---|---|---|---|
| `agent:<role>` | Issue/story bu role atandı (sahip) | orchestrator (story oluşturulduğunda) | story Done olunca orchestrator |
| `cc:<role>` | Top şu an o role düşütülüyor (active queue) | top'u atan rol | o rolü kendisi (işi bitince) |
| `status:in-review` | PR review sürecinde | developer (PR ready iken) | orchestrator/human (merge öncesi) |
| `status:ready` | Tester+arch onayı var, insan merge edebilir | tester (APPROVED verdict ile birlikte) | human (merge ile birlikte) |
| `needs-architect-review` | Mimari etki var, arch müdahalesi lazım | developer veya tester (şüphe olduğunda) | architect (review yazınca) |

### Tipik handoff zinciri (mutlu yol)

```
PM yazar story  → add cc:tester           (test plan için)
Tester plan yaz → remove cc:tester, add cc:developer (TDD red ready)
Developer push  → remove cc:developer, add cc:tester (re-review)
Tester APPROVED → remove cc:tester, add status:ready (human merge)
Human merge     → remove status:ready, close PR
```

Dallanmalar:
- ARCH input gerekirse herhangi bir noktada: `add cc:architect`
- CHANGES REQUESTED: tester `add cc:developer` (fix loop'a geri dön)
- Question/blocker: PM veya ARCH'a `add cc:<role>` + issue link

### Anti-patterns (sistem-wide yasaklı)

- ❌ **Çift `cc:*` label**: Aynı anda `cc:tester` + `cc:developer` tutmak — top kimde belirsiz.
- ❌ **Kendi `cc:*`'ini bırakmak**: İşi bitirdin ama label'ı kaldırmadın — watcher loop seni aynı event'le tekrar uyandırır (processed-id koruma var ama label state hala kirli).
- ❌ **Label flip + notify.sh ayrılması**: Sadece label değiştirmek = peer GitHub poll'una kadar bekler. Sadece notify.sh = insan görür ama peer GitHub artefact'ı görmez. İkisi birlikte zorunlu.
- ❌ **Kendine `cc:` koymak**: Watcher zaten seni atanan işlerde otomatik uyandırır; kendine etiket koymak gereksiz.
- ❌ **Soul kurallarını atlatmak**: Her rolün soul dosyasında §Handoff Discipline tablosu var — onu referans al, ad-hoc karar verme.

## Things agents must NEVER do
- Push directly to `main`.
- Merge their own PRs.
- Modify `.github/workflows/`, secrets, branch protection without explicit human approval.
- Roll their own auth/crypto.
- Disable failing tests to make CI green.
- Edit other agents' soul files.

## File ownership matrix
| Path | Owner |
|---|---|
| `docs/product/` | @product-manager |
| `docs/backlog/` | @product-manager |
| `docs/designs/` | @architect |
| `docs/decisions/` (ADRs) | @architect |
| `docs/tech-debt.md` | @architect |
| `docs/sprints/` | @orchestrator |
| `docs/bugs/` | @tester |
| `src/`, `tests/` | @developer (writes), @tester (test files), @architect (reviews) |
| `.claude/` | human only |
| `.github/workflows/` | human only (agents propose via PR) |
