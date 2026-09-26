# 🔄 Obsidian Sync Scripts

<div align="center">

![Obsidian Sync](https://img.shields.io/badge/Obsidian-Sync-blue?style=for-the-badge&logo=obsidian)
![Platform](https://img.shields.io/badge/Platform-Desktop%20%7C%20Mobile-green?style=for-the-badge&logo=android)
![License](https://img.shields.io/badge/License-MIT-yellow?style=for-the-badge)
![Version](https://img.shields.io/badge/Version-1.0.0-orange?style=for-the-badge)

**اسکریپت‌های همگام‌سازی Obsidian با Git برای کامپیوتر و موبایل**

[نصب کامپیوتر](#-نصب-اسکریپت-کامپیوتر) • [نصب موبایل](#-نصب-اسکریپت-موبایل) • [راهنمای استفاده](#-راهنمای-استفاده)

</div>

---

## 📖 فهرست مطالب

- [معرفی پروژه](#-معرفی-پروژه)
- [ویژگی‌ها](#-ویژگی‌ها)
- [معماری سیستم](#%EF%B8%8F-معماری-سیستم)
- [پیش‌نیازها](#-پیش-نیازها)
- [نصب اسکریپت کامپیوتر](#-نصب-اسکریپت-کامپیوتر)
- [نصب اسکریپت موبایل](#-نصب-اسکریپت-موبایل)
- [راهنمای استفاده](#-راهنمای-استفاده)
- [Workflow روزانه](#-workflow-روزانه)
- [عیب‌یابی](#-عیب-یابی)
- [سوالات متداول](#-سوالات-متداول)
- [مجوز](#-مجوز)

---

## 🎯 معرفی پروژه

این پروژه شامل دو اسکریپت Bash قدرتمند برای همگام‌سازی یادداشت‌های **Obsidian** با استفاده از **Git** و **GitHub** است.

### چرا این اسکریپت‌ها؟

| ویژگی | توضیح |
|--------|--------|
| 🆓 **رایگان** | بدون نیاز به سرویس پولی |
| 🔒 **امن** | استفاده از SSH و Git |
| 🎮 **کنترل کامل** | بدون conflict خودکار |
| 🚀 **سریع** | یک دستور برای همه کارها |
| 💾 **بکاپ** | بکاپ خودکار قابل بازیابی |
| 📱 **چندسکویی** | Desktop و Mobile |

---

## ✨ ویژگی‌ها

### 💻 اسکریپت کامپیوتر (`obsidian-sync`)

```bash
obsidian-sync          # Sync کامل (Pull + Push)
obsidian-sync pull     # دریافت از GitHub
obsidian-sync push     # ارسال به GitHub
obsidian-sync status   # نمایش وضعیت
obsidian-sync info     # اطلاعات Vault
obsidian-sync backup   # بکاپ فوری
obsidian-sync help     # راهنما
```

### 📱 اسکریپت موبایل (`ob-sync`)

```bash
ob-sync          # Sync کامل
ob-sync pull     # دریافت از GitHub
ob-sync push     # ارسال به GitHub
ob-sync status   # وضعیت
ob-sync help     # راهنما
```

---

## 🏗️ معماری سیستم

```
┌─────────────────────────────────────────┐
│         GitHub Repository               │
│      (YourUsername/obsidian)            │
└─────────────────┬───────────────────────┘
                  │
         HTTPS + SSH
                  │
    ┌─────────────┴─────────────┐
    │                           │
    ▼                           ▼
┌──────────┐          ┌──────────┐
│ کامپیوتر │          │  گوشی    │
│ (Ubuntu) │          │ (Android)│
├──────────┤          ├──────────┤
│ obsidian │          │  ob-sync │
│  -sync   │          │          │
└──────────┘          └──────────┘
```

---

## 📋 پیش‌نیازها

### کامپیوتر:
- Git (`sudo apt install git`)
- SSH Key
- Obsidian

### موبایل:
- Termux (از F-Droid)
- Git (`pkg install git`)
- Obsidian Android

### GitHub:
- Repository خصوصی برای یادداشت‌ها
- Personal Access Token (PAT) برای موبایل

---

## 💻 نصب اسکریپت کامپیوتر

### روش ۱: نصب خودکار (توصیه می‌شود)

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/CheginiSoroush/obsidian-sync-scripts/main/desktop/install.sh)"
```

### روش ۲: نصب دستی

```bash
# ۱. دانلود
wget https://raw.githubusercontent.com/CheginiSoroush/obsidian-sync-scripts/main/desktop/obsidian-sync -O ~/obsidian-sync

# ۲. مجوز اجرا
chmod +x ~/obsidian-sync

# ۳. ایجاد Alias
echo 'alias obsidian-sync="$HOME/obsidian-sync"' >> ~/.bashrc
source ~/.bashrc
```

---

## 📱 نصب اسکریپت موبایل

### گام ۱: راه‌اندازی Termux

```bash
pkg update && pkg upgrade -y
pkg install git openssh -y
termux-setup-storage
```

### گام ۲: نصب اسکریپت

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/CheginiSoroush/obsidian-sync-scripts/main/mobile/install.sh)"
```

### گام ۳: تنظیم Git

```bash
git config --global user.name "Your Name"
git config --global user.email "your_email@example.com"
git config --global --add safe.directory "*"
```

---

## 📖 راهنمای استفاده

### کامپیوتر:

```bash
# دریافت تغییرات
obsidian-sync pull

# ارسال تغییرات
obsidian-sync push

# Sync کامل
obsidian-sync

# بکاپ
obsidian-sync backup
```

### موبایل:

```bash
# دریافت تغییرات
ob-sync pull

# ارسال تغییرات
ob-sync push

# Sync کامل
ob-sync
```

---

## 📅 Workflow روزانه

### ⚠️ قوانین طلایی:

1. **هرگز همزمان** در دو دستگاه ننویسید
2. **قبل از نوشتن**، Pull کنید
3. **بعد از نوشتن**، Push کنید

### مثال روزانه:

```
صبح:
  کامپیوتر: obsidian-sync pull

روز:
  در Obsidian بنویسید

شب:
  کامپیوتر: obsidian-sync push
```

---

## 🔧 عیب‌یابی

<details>
<summary><b>مشکل: Permission denied</b></summary>

```bash
ssh-add ~/.ssh/id_ed25519
ssh -T git@github.com
```
</details>

<details>
<summary><b>مشکل: Merge conflict</b></summary>

```bash
obsidian-sync pull
# اگر حل نشد:
cd /path/to/vault
git rebase --abort
git fetch origin
git reset --hard origin/main
```
</details>

<details>
<summary><b>مشکل: dubious ownership</b></summary>

```bash
git config --global --add safe.directory "*"
```
</details>

### راهنمای کامل: [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)

---

## ❓ سوالات متداول

<details>
<summary><b>آیا رایگان است؟</b></summary>

بله، کاملاً رایگان. فقط GitHub و Git استفاده می‌شود.
</details>

<details>
<summary><b>آیا امن است؟</b></summary>

بله:
- Repository خصوصی
- انتقال با SSH رمزنگاری شده
- تاریخچه کامل Git
</details>

<details>
<summary><b>چقدر فضا لازم است؟</b></summary>

GitHub خصوصی: ۱ گیگابایت (برای متن کافی است)
</details>

---

## 🤝 مشارکت

برای مشارکت، [CONTRIBUTING.md](CONTRIBUTING.md) را بخوانید.

---

## 📄 مجوز

این پروژه تحت [مجوز MIT](LICENSE) منتشر شده است.

---

<div align="center">

**ساخته شده با ❤️ برای جامعه Obsidian**

</div>
