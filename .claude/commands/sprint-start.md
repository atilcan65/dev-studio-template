---
description: Yeni sprint başlat — backlog'dan story seç, agent'lara dağıt, sprint hedeflerini belirle.
---

# Sprint Start: Sprint $ARGUMENTS

Sen **Orchestrator**'sın. Sprint $ARGUMENTS'i başlatıyorsun.

## Adımlar

1. **Backlog'u oku**: `gh issue list --label "status:ready" --json number,title,labels,body --limit 50`

2. **Velocity hesapla**: Geçmiş sprint'lerin tamamlanan story point'lerinin ortalamasını al. İlk sprint ise: **20 point** hedef.

3. **Story seç**: Priority sırasına göre (P0 → P1 → P2), toplam velocity'i aşmayacak şekilde story seç.

4. **Agent ataması yap**:
   - Backend/infra → Architect + Developer
   - Frontend → Developer + Tester
   - Test/QA → Tester
   - Spec/research → Product Manager

5. **Sprint goal yaz**: 1-2 cümlede bu sprint'in ana hedefi nedir?

6. **GitHub'a yansıt**:
   - Her seçilen issue'ya `sprint:$ARGUMENTS` label ekle
   - Status'u `Ready` → `In Progress` yap (Project board)
   - Agent label'ını ata

7. **Sprint kickoff notu yaz**: `docs/sprints/sprint-$ARGUMENTS/plan.md` dosyası oluştur:
   - Sprint goal
   - Seçilen story'ler (issue link'leriyle)
   - Agent atamaları
   - Risk'ler ve bağımlılıklar
   - Kickoff tarihi

8. **Tracking issue aç**: `[Sprint $ARGUMENTS] Kickoff` başlığıyla, plan dosyasının içeriğini inline yapıştır, `@atilcan65` mention.

9. **Özet ver**: Kullanıcıya kısa bir özet sun — kaç story, toplam point, hangi agent'lara dağıldı.

## Çıktı Formatı

```
🚀 Sprint $ARGUMENTS Kickoff

📋 Goal: <sprint goal>
📊 Capacity: <X> points
📦 Stories: <N> adet

Atamalar:
- Architect: #X, #Y
- Developer: #Z, #W
- Tester: #V
- Product Manager: #U

Risk'ler: <varsa>

Tracking issue: #<NN>
Plan dosyası: docs/sprints/sprint-$ARGUMENTS/plan.md
```
