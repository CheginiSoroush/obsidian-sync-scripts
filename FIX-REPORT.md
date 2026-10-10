# 🛠 FIX-REPORT — همه‌ی یافته‌های TEST-REPORT.md بسته شدند

**تاریخ:** 2026-10-09 22:48:16 · **هدف:** bin/ob-sync (9.5.1) · **بکاپ:** `.fix-backups/ob-sync.20261009-224640.bak`

## وضعیت نهایی: ✅ سبز

| # | شدت | یافته | راه‌حل اعمال‌شده |
|---|-----|-------|------------------|
| ۱ | 🔴 CRITICAL | تزریق `OBS_BRANCH="--receive-pack=..."` به `git push` | `branch_guard()` با `git check-ref-format --branch` قبل از هر `push_args` (sync_run + push_run) |
| ۲ | 🟠 HIGH | `OBS_ATTACH_DIR="../x"` فایل‌ها را خارج از vault جابجا می‌کرد | گارد `case` در ابتدای `organize_fix_run()`: رد مسیر مطلق / حاوی `..` / خالی → `attach_dir_unsafe` |
| ۳ | 🟡 MEDIUM | rc=124 واچداگ شبکه → پیام گمراه‌کننده «network or credentials» | هر ۴ نقطه (fetch در sync/pull، push در sync/push) اکنون rc را می‌گیرند و پیام صریح `timed out after ${GIT_TIMEOUT}s (OBS_GIT_TIMEOUT)` می‌دهند؛ کد خطای جدید `fetch_timeout` / `push_timeout` |
| ۴ | 🟡 MEDIUM | restore برای vault دارای symlink بن‌بست بود | پیام رد شدن ۳ مرحله‌ای actionable شد (بررسی با --list، بازسازی دستی، استخراج دستی) |
| ۵ | 🔵 LOW | `history abc` به پیش‌فرض برمی‌گشت | **عمداً تغییر نکرد** — run-tests.sh:1265 این رفتار را به‌عنوان قرارداد تست می‌کند («falls back to 10»)؛ تغییرش یعنی شکستن سوئیت خودِ پروژه |
| ۶ | 🔵 LOW | exit-code داکتر در مستندات نیست | در همین گزارش مستند شد: doctor با وجود یافته rc=1 می‌دهد (صحیح) |
| ۷ | 🟡 MEDIUM | (کمپین ۷ ساعته — fuzz C7) `OBS_LOG=/dev/full` هر دستوری را برای همیشه hang می‌کرد | گارد P8 در `init_log()`: فقط فایل معمولی `wc -c` می‌گیرد؛ غیر از آن LOG_FILE خالی و ادامهٔ کار (PoC-C) |

## باتری تأیید (همه سبز)
- `bash -n` روی نسخه‌ی stage و نسخه‌ی نهایی ✅
- ShellCheck `-S warning`: صفر یافته‌ی جدید ✅
- PoC-A: تزریق branch → رد شد، دستور اجرا نشد، پیام صادقانه ✅
- PoC-B: traversal فولدر پیوست‌ها → رد شد، فایل داخل vault ماند، هیچ‌چیز بیرون نوشته نشد ✅
- سوئیت‌های کامل: run-tests (۳۷۲)، user-error-tests، heavy-system-tests، human-error-attacks (اکنون بدون FAIL عمدی) ✅
- PoC-C: `OBS_LOG=/dev/full` → خروج سریع و صادقانه، بدون hang ✅

## بازگشت به عقب (هر زمان)
```bash
bash fix-all-issues.sh rollback           # آخرین بکاپ
bash fix-all-issues.sh list-backups
```
*هیچ فایل دیگری از پروژه دست نخورده است — فقط bin/ob-sync، فقط ۸ نقطه‌ی جراحی.*
