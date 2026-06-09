---
description: Günlük standup — tüm agent'ların dünkü iş, bugünkü plan ve blocker'larını topla.
---

# Daily Standup

Sen **Orchestrator**'sın. Günlük standup raporu hazırla.

## Adımlar

1. **Aktif sprint'i bul**: `gh project item-list 1 --owner atilcan65 --format json` ile mevcut sprint'i tespit et.

2. **Her agent için son 24 saatte yapılan işi topla**:
   - Kapatılan issue'lar: `gh issue list --state closed --search "closed:>$(date -d '24 hours ago' --iso-8601)"`
   - Merge edilen PR'lar: `gh pr list --state merged --search "merged:>$(date -d '24 hours ago' --iso-8601)"`
   - Açık PR'lar (review bekliyor)
   - In Progress issue'lar
   - Heartbeat dosyaları: `/var/log/dev-studio/<agent>.heartbeat` → son timestamp.

3. **Blocker'ları tespit et**:
   - `status:blocked` label'lı issue'lar
   - 48 saatten uzun süredir hareket etmeyen In Progress issue'lar
   - CI fail eden PR'lar
   - Heartbeat'i 1 saatten eski olan agent'lar (STALE)

4. **Standup raporu yaz**: `docs/standups/standup-$(date +%Y-%m-%d).md` dosyası oluştur.

5. **Sprint issue'sına comment olarak ekle**: `[Sprint NN] Daily Standup` issue'sına aynı içeriği comment olarak post et.

6. **Discord'a gönder** (`scripts/notify.sh` ile): Özet + standup linkini paylaş.

7. **Eğer P0/P1 blocker varsa**: Ayrı bir `[Blocker]` issue aç ve `@atilcan65` mention.

## Çıktı Formatı

```
📅 Daily Standup — <YYYY-MM-DD>

🏗️ Architect
- ✅ Dün: <tamamlanan iş>
- 🔄 Bugün: <planlanan iş>
- 🚧 Blocker: <varsa>
- Heartbeat: OK | STALE

💻 Developer
- ✅ Dün: ...
- 🔄 Bugün: ...
- 🚧 Blocker: ...
- Heartbeat: OK | STALE

🧪 Tester
- ✅ Dün: ...
- 🔄 Bugün: ...
- 🚧 Blocker: ...
- Heartbeat: OK | STALE

📋 Product Manager
- ✅ Dün: ...
- 🔄 Bugün: ...
- 🚧 Blocker: ...
- Heartbeat: OK | STALE

⚠️ Sprint Risk: <varsa>
📊 Burndown: <kalan point> / <toplam point>
🔥 P0/P1 Blocker: <count> — <one-liner>
```
