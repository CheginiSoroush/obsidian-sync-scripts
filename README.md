
cd ~/obsidian-sync-scripts

# ═══════════════════════════════════════════
# ۱. ساخت LICENSE
# ═══════════════════════════════════════════

cat > LICENSE << 'EOF'
MIT License

Copyright (c) 2026 CheginiSoroush

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
EOF

# ═══════════════════════════════════════════
# ۲. ساخت .gitignore
# ═══════════════════════════════════════════

cat > .gitignore << 'EOF'
# فایل‌های موقت
*.tmp
*.bak
*~
.DS_Store

# فایل‌های حساس
.env
*.token
*.key

# پوشه‌های سیستم
__pycache__/
*.pyc
node_modules/

# فایل‌های Editor
.vscode/
.idea/
*.swp
*.swo

# فایل‌های بکاپ
*.tar.gz
*.zip
EOF

# ═══════════════════════════════════════════
# ۳. ساخت CONTRIBUTING.md
# ═══════════════════════════════════════════

cat > CONTRIBUTING.md << 'EOF'
# 🤝 راهنمای مشارکت

ممنون که می‌خواهید کمک کنید!

## نحوه مشارکت

1. **Fork** کنید
2. **Branch** جدید بسازید:
   ```bash
   git checkout -b feature/amazing-feature
   ```
3. **تغییرات** را اعمال کنید
4. **Commit** کنید:
   ```bash
   git commit -m 'Add amazing feature'
   ```
5. **Push** کنید:
   ```bash
   git push origin feature/amazing-feature
   ```
6. **Pull Request** بفرستید

## استانداردها

- کد را تمیز بنویسید
- کامنت‌گذاری کنید
- تست کنید
- مستندات را به‌روز کنید
- از ShellCheck استفاده کنید

## ساختار Commit

```
type(scope): description

[optional body]

[optional footer]
```

### Types:
- `feat`: ویژگی جدید
- `fix`: رفع باگ
- `docs`: مستندات
- `style`: فرمت‌بندی
- `refactor`: بازنویسی
- `test`: تست
- `chore`: کارهای جانبی

### مثال:
```
feat(desktop): add backup command
fix(mobile): resolve conflict issue
docs(readme): update installation guide
```

## ساختار پروژه

```
obsidian-sync-scripts/
├── desktop/
│   └── obsidian-sync    # اسکریپت کامپیوتر
├── mobile/
│   └── ob-sync          # اسکریپت موبایل
├── docs/                # مستندات اضافی
├── .gitignore
├── CONTRIBUTING.md
├── LICENSE
└── README.md
```
EOF

# ═══════════════════════════════════════════
# ۴. ساخت فایل نصب خودکار برای کامپیوتر
# ═══════════════════════════════════════════

cat > desktop/install.sh << 'EOF'
#!/bin/bash

echo "🚀 نصب Obsidian Sync برای کامپیوتر..."

# ۱. دانلود اسکریپت اصلی
wget -q https://raw.githubusercontent.com/CheginiSoroush/obsidian-sync-scripts/main/desktop/obsidian-sync -O ~/obsidian-sync

# ۲. تنظیم مجوز
chmod +x ~/obsidian-sync

# ۳. ایجاد Alias
if ! grep -q "obsidian-sync" ~/.bashrc; then
    echo 'alias obsidian-sync="$HOME/obsidian-sync"' >> ~/.bashrc
fi

# ۴. اعمال تغییرات
source ~/.bashrc

# ۵. بررسی
if [ -f ~/obsidian-sync ]; then
    echo "✅ نصب موفقیت‌آمیز بود!"
    echo ""
    echo "📖 دستورات:"
    echo "  obsidian-sync          - Sync کامل"
    echo "  obsidian-sync pull     - فقط Pull"
    echo "  obsidian-sync push     - فقط Push"
    echo "  obsidian-sync status   - وضعیت"
    echo "  obsidian-sync backup   - بکاپ"
    echo "  obsidian-sync help     - راهنما"
    echo ""
    echo "💡 برای شروع: obsidian-sync status"
else
    echo "❌ نصب ناموفق!"
    echo "لطفاً دستی نصب کنید"
fi
EOF

chmod +x desktop/install.sh

# ═══════════════════════════════════════════
# ۵. ساخت فایل نصب خودکار برای موبایل
# ═══════════════════════════════════════════

cat > mobile/install.sh << 'EOF'
#!/bin/bash

echo "🚀 نصب Obsidian Sync برای موبایل..."

# ۱. دانلود اسکریپت
curl -sSL https://raw.githubusercontent.com/CheginiSoroush/obsidian-sync-scripts/main/mobile/ob-sync -o ~/ob-sync

# ۲. تنظیم مجوز
chmod +x ~/ob-sync

# ۳. ایجاد Alias
if ! grep -q "ob-sync" ~/.bashrc; then
    echo 'alias ob-sync="$HOME/ob-sync"' >> ~/.bashrc
fi

# ۴. اعمال تغییرات
source ~/.bashrc

# ۵. بررسی
if [ -f ~/ob-sync ]; then
    echo "✅ نصب موفقیت‌آمیز بود!"
    echo ""
    echo "📖 دستورات:"
    echo "  ob-sync          - Sync کامل"
    echo "  ob-sync pull     - فقط Pull"
    echo "  ob-sync push     - فقط Push"
    echo "  ob-sync status   - وضعیت"
    echo "  ob-sync help     - راهنما"
    echo ""
    echo "💡 برای شروع: ob-sync status"
else
    echo "❌ نصب ناموفق!"
    echo "لطفاً دستی نصب کنید"
fi
EOF

chmod +x mobile/install.sh

# ═══════════════════════════════════════════
# ۶. ساخت docs/TROUBLESHOOTING.md
# ═══════════════════════════════════════════

cat > docs/TROUBLESHOOTING.md << 'EOF'
# 🔧 راهنمای عیب‌یابی کامل

## فهرست مشکلات

1. [مشکلات SSH](#مشکلات-ssh)
2. [مشکلات Git](#مشکلات-git)
3. [مشکلات Storage](#مشکلات-storage)
4. [مشکلات Termux](#مشکلات-termux)
5. [مشکلات Windows](#مشکلات-windows)

---

## مشکلات SSH

### Permission denied (publickey)

**علت:** کلید SSH به GitHub اضافه نشده است.

```bash
# راه‌حل:
# ۱. بررسی کلید:
ls ~/.ssh/
cat ~/.ssh/id_ed25519.pub

# ۲. اضافه کردن به GitHub:
# GitHub → Settings → SSH and GPG keys → New SSH key
# Title: Desktop/Mobile
# Key: محتوای فایل id_ed25519.pub

# ۳. تست:
ssh -T git@github.com
```

### Connection closed by port 22

**علت:** فایروال یا ISP پورت 22 را مسدود کرده.

```bash
# راه‌حل: استفاده از پورت 443
cat >> ~/.ssh/config << 'EOF'
Host github.com
  Hostname ssh.github.com
  Port 443
  User git
EOF

# تست:
ssh -T git@github.com
```

---

## مشکلات Git

### Repository not found

**علت:** Remote URL اشتباه است.

```bash
# بررسی:
git remote -v

# اصلاح:
git remote set-url origin git@github.com:YourUsername/obsidian.git
```

### Merge conflict

**علت:** تغییرات همزمان در دو دستگاه.

```bash
# راه‌حل ۱ (کامپیوتر):
obsidian-sync pull

# راه‌حل ۲ (دستی):
cd /path/to/vault
git rebase --abort
git fetch origin
git reset --hard origin/main
```

### Detected dubious ownership

**علت:** مشکل مالکیت فایل‌ها.

```bash
# راه‌حل:
git config --global --add safe.directory "*"
```

### Index file too small

**علت:** فایل‌های Git خراب شده‌اند.

```bash
# راه‌حل:
cd /path/to/vault

# ۱. بکاپ:
tar -czf ~/vault-backup.tar.gz -C . .

# ۲. بازسازی:
rm -rf .git
git init
git remote add origin https://github.com/YourUsername/obsidian.git
git fetch origin
git checkout -b main
git branch --set-upstream-to=origin/main main
git pull origin main
```

### Author identity unknown

**علت:** Git هویت شما را نمی‌شناسد.

```bash
# راه‌حل:
git config --global user.name "Your Name"
git config --global user.email "your_email@example.com"
```

---

## مشکلات Storage

### درایو مشترک Mount نمی‌شود (Dual Boot)

**علت:** تنظیمات fstab ناقص است.

```bash
# ۱. بررسی UUID:
sudo blkid

# ۲. تنظیم fstab:
sudo nano /etc/fstab
# اضافه کنید:
UUID=xxxx-xxxx /media/username/shared ntfs-3g defaults,uid=1000,gid=1000,umask=007 0 0

# ۳. Mount:
sudo mount -a
```

### دسترسی به Documents ندارم (Termux)

**علت:** دسترسی حافظه فعال نشده.

```bash
# راه‌حل:
termux-setup-storage
# روی Allow بزنید

# تست:
ls ~/storage/shared/Documents/
```

---

## مشکلات Termux

### Package installation failed

```bash
# راه‌حل:
pkg update && pkg upgrade -y
pkg install git openssh -y
```

### Storage permission denied

```bash
# ۱. Termux را ببندید
# ۲. به Settings → Apps → Termux
# ۳. Permissions → Storage → Allow
# ۴. Termux را دوباره باز کنید
# ۵. اجرای:
termux-setup-storage
```

### Git commands not working

```bash
# بررسی نصب:
which git
git --version

# اگر نصب نیست:
pkg install git -y

# تنظیمات:
git config --global user.name "Your Name"
git config --global user.email "your_email@example.com"
git config --global --add safe.directory "*"
```

---

## مشکلات Windows

### Git Bash slow

```bash
# راه‌حل:
git config --global core.preloadindex true
git config --global core.fscache true
git config --global gc.auto 256
```

### Line ending issues

```bash
# راه‌حل:
git config --global core.autocrlf true
```

---

## بازیابی داده‌ها

### بازیابی از Git History

```bash
# ۱. لیست commits:
git log --oneline

# ۲. برگشت به commit خاص:
git checkout <commit-hash> -- .

# ۳. Commit:
git add .
git commit -m "Recover from commit"
```

### بازیابی از بکاپ

```bash
# ۱. لیست بکاپ‌ها:
ls -la /home/user/obsidian-backups/

# ۲. بازیابی:
tar -xzf backup-YYYYMMDD.tar.gz -C /path/to/vault
```

### بازیابی از Timeshift (کامپیوتر)

```bash
sudo timeshift --list
sudo timeshift --restore --snapshot "YYYY-MM-DD_HH-MM-SS"
```
EOF

echo ""
echo "═══════════════════════════════════════════"
echo "  🎉 همه فایل‌ها ساخته شدند!"
echo "═══════════════════════════════════════════"
echo ""
echo "📊 ساختار نهایی:"
find . -type f -not -path "./.git/*" | sort
```

---

## 🚀 حالا Commit و Push کنید:

```bash
# ۱. اضافه کردن همه فایل‌ها:
git add .

# ۲. Commit:
git commit -m "feat: add mobile script, comprehensive documentation, and installation scripts

- Add mobile/ob-sync script for Android/Termux
- Add desktop/install.sh for automatic installation
- Add mobile/install.sh for automatic installation
- Add comprehensive README with installation, usage, troubleshooting
- Add docs/TROUBLESHOOTING.md with detailed solutions
- Add LICENSE (MIT)
- Add CONTRIBUTING.md
- Add .gitignore"

# ۳. Push:
git push origin main

# ۴. بررسی نهایی:
echo "═══════════════════════════════════════════"
echo "  🎉 ریپازیتوری کامل شد!"
echo "═══════════════════════════════════════════"
echo ""
echo "📊 ساختار نهایی:"
find . -type f -not -path "./.git/*" | sort
echo ""
echo "📊 Git Status:"
git status
echo ""
echo "🔗 لینک ریپازیتوری:"
echo "https://github.com/CheginiSoroush/obsidian-sync-scripts"
echo ""
echo "✅ تمام!"
