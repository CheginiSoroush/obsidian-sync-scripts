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
