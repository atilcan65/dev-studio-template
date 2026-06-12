# Telegram Bot Kurulumu

Bu doc, dev studio'nun Telegram bildirimleri için bot oluşturma + token alma + chat ID bulma + `.env` yazma adımlarını anlatır.

Tamamlandığında `scripts/notify.sh "test"` komutu Telegram'ına mesaj atacak.

---

## Adım 1: Bot oluştur

1. Telegram'da [@BotFather](https://t.me/BotFather)'ı aç.
2. `/newbot` komutunu gönder.
3. Bot için bir **isim** ver (görünen ad, ör. "Dev Studio Notifier").
4. Bot için bir **username** ver (sonu `bot` ile bitmeli, ör. `mydevstudio_bot`).
5. BotFather sana bir **token** verir, şu formatta:
   ```
   1234567890:ABCdefGHIjklMNOpqrSTUvwxYZ
   ```
   **Bu token gizli, kimseyle paylaşma.** Bu sayıyı `TELEGRAM_BOT_TOKEN` olarak kullanacaksın.

---

## Adım 2: Chat ID bul

Telegram bot'un kime mesaj atacağını bilmiyor. Senin chat ID'ini bulmamız lazım.

### Yöntem A — Bot'a "/start" gönder, sonra API'dan oku

1. Telegram'da bot'unu aç (BotFather'da verdiğin username, ör. `@mydevstudio_bot`).
2. Bot ile sohbeti başlat, `/start` veya herhangi bir mesaj gönder.
3. Tarayıcıda şu URL'yi aç (TOKEN yerine kendi token'ını koy):
   ```
   https://api.telegram.org/bot<TOKEN>/getUpdates
   ```
4. Dönen JSON'da `"chat":{"id":12345678,...}` kısmındaki sayıyı al. Bu senin chat ID'in.

### Yöntem B — @userinfobot kullan

1. Telegram'da [@userinfobot](https://t.me/userinfobot)'u aç.
2. `/start` gönder.
3. Bot sana ID'ini verir (ör. `Id: 12345678`).

**Grup chat'e mesaj atacaksan:** Bot'u önce gruba ekle, gruba bir mesaj gönder, sonra Yöntem A'daki `getUpdates` URL'sinden grup chat ID'ini al (genelde negatif sayı, ör. `-1001234567890`).

---

## Adım 3: `.env` dosyasını yaz

VM'de `~/.dev-studio-env` dosyasını oluştur (her kullanıcının home dizininde):

```bash
cat > ~/.dev-studio-env <<'EOF'
export TELEGRAM_BOT_TOKEN="1234567890:ABCdefGHIjklMNOpqrSTUvwxYZ"
export TELEGRAM_CHAT_ID="12345678"
EOF

chmod 600 ~/.dev-studio-env  # sadece sen okuyabilirsin
```

**Önemli:** `~/.dev-studio-env` dosyası repo dışında, asla commit edilmemeli. Repo'daki `.gitignore` zaten bunu hariç tutar.

---

## Adım 4: Doğrulama

```bash
# Env'i source et (yeni shell açtıysan)
source ~/.dev-studio-env

# Test mesajı gönder
bash scripts/notify.sh "Test from $(hostname)"

# Severity level'lar
bash scripts/notify.sh -l ok    "All good ✅"
bash scripts/notify.sh -l warn  "Heads up ⚠️"
bash scripts/notify.sh -l error "Critical 🚨"
```

Telegram'da 4 mesajı görmen lazım. Görmedin mi?

| Hata mesajı | Çözüm |
|---|---|
| `TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID not set` | `source ~/.dev-studio-env` çalıştır, sonra tekrar dene |
| `401 Unauthorized` | Bot token yanlış. BotFather'dan `/mybots` ile yeniden al |
| `400 Bad Request: chat not found` | Chat ID yanlış. Adım 2'yi tekrarla |
| `Forbidden: bot was blocked by the user` | Telegram'da bot'a `/start` gönder, sohbeti aç |

---

## Adım 5: systemd service'lere env aktarımı (production setup)

Eğer `scripts/install/dev-studio-install-systemd.sh` ile systemd watcher kurduysan, service dosyaları **env'i otomatik source etmez**. İki seçenek:

### Seçenek A — `EnvironmentFile=` ekle

Service dosyalarına ekle:

```ini
[Service]
EnvironmentFile=/home/<username>/.dev-studio-env
```

`systemd/dev-studio-watcher@.service.tmpl` zaten bu pattern'i destekliyor (init script render ederken `{{HUMAN_OWNER_NAME}}` placeholder'ını çözüyor).

### Seçenek B — System-wide env (önerilmez)

`/etc/environment` dosyasına ekle (tüm kullanıcılara açık olur, **token sızıntısı riski**). Sadece tek-kullanıcılı kişisel sunucu için.

---

## Güvenlik notları

- Token sızdırırsan: BotFather'da `/revoke` ile yeni token al, eski token anında ölür.
- `~/.dev-studio-env` dosyasını **asla** commit etme. `.gitignore` zaten korur ama elle `git add -f` deme.
- Bot token GitHub'a sızdıysa GitHub secret scanner yakalar, BotFather otomatik revoke eder — yine de elle hemen `/revoke` yap.
- Production'da bot'un yetkilerini kısıt: BotFather'da `/setjoingroups` → Disable (sadece direct chat).

---

## Birden fazla chat'e gönderme

Şu an `notify.sh` tek chat ID'e gönderiyor. Eğer takım arkadaşların da bildirimleri almalı ise:

- **A)** Grup chat oluştur, bot'u ekle, `TELEGRAM_CHAT_ID`'i grup ID'si (negatif sayı) yap
- **B)** `notify.sh`'ı genişlet, `TELEGRAM_CHAT_IDS="id1,id2,id3"` formatını destekle (kod değişikliği gerekir)

Önerilen: A — basit, devops yükü yok.
