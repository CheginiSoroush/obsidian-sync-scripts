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
