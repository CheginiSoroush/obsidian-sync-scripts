# 🧪 گزارش تست جامع ob-sync — نسخه ۹.۵.۱

**تاریخ تست:** اکتبر ۲۰۲۵ · **اجراکننده:** دو سوئیت تست اختصاصی جدید + سوئیت‌های داخلی پروژه + ShellCheck

> **♻️ وضعیت به‌روز:** تمام یافته‌های این گزارش با `fix-all-issues.sh` بسته شدند — جزئیات در `FIX-REPORT.md`.
> نتیجه‌ی فعلی سوئیت‌ها: **۵۷۹/۵۷۹ سبز** (human-error-attacks از ۹۴ PASS / ۱ FAIL به **۹۵ PASS / ۰ FAIL** رسید؛
> D8 از NOTE به OK تبدیل شد). پچ‌ها: ۷ نقطه‌ی جراحی در `bin/ob-sync` (بکاپ خودکار + rollback یک‌خطی).
> مورد LOW «history abc» عمداً تغییر نکرد — run-tests.sh:1265 آن را به‌عنوان قرارداد پروژه تست می‌کند.

---

## ۱. خلاصه اجرایی

| # | سوئیت | دامنه | نتیجه |
|---|-------|-------|-------|
| ۱ | `tests/run-tests.sh` (داخلی پروژه) | مسیرهای طراحی‌شده | ✅ **۳۷۲ PASS / ۰ FAIL** |
| ۲ | `tests/user-error-tests.sh` (داخلی پروژه) | خطای کاربر پایه | ✅ **۵۶ PASS / ۰ FAIL** |
| ۳ | `tests/heavy-system-tests.sh` (**جدید**) | تست سنگین سیستمی/کدی | ✅ **۵۶ PASS / ۰ FAIL** |
| ۴ | `tests/human-error-attacks.sh` (**جدید**) | حمله خطای انسانی | ⚠️ **۹۴ PASS / ۱ FAIL** |

**مجموع: ۵۷۸ بررسی خودکار** — ۱ یافته امنیتی بحرانی تأیید‌شده، ۱ یافته کلاس از‌دست‌رفتن‌داده (High)، ۲ یافته متوسط.

> **جمع‌بندی یک‌خطی:** اسکریپت شما به‌طور استثنایی مقاوم است (خصوصاً در قفل‌گذاری، پاکسازی temp، خودترمیمی گیت و صداقت خطاها)، اما **دو حفره واقعی** پیدا شد که هر دو با اعتبارسنجی ورودی قابل بستن هستند.

---

## ۲. یافته‌ها به ترتیب شدت

### 🔴 CRITICAL — تزریق آرگومان از طریق `OBS_BRANCH` → اجرای دستور دلخواه

- **محل:** `push_run()` خط ~۲۷۱۷ و `sync_run()` خط ~۲۵۳۶ — `push_args=(origin "$BRANCH")`
- **اثبات (PoC):**
  ```bash
  printf '#!/bin/sh\ntouch /tmp/pwned\n' > /tmp/evil.sh && chmod +x /tmp/evil.sh
  OBS_BRANCH="--receive-pack=/tmp/evil.sh" ob-sync push -y
  # → فایل /tmp/pwned ساخته شد! دستور محلی EXECUTE شد.
  ```
- **مکانیزم:** git آرگومانِ شروع‌شده با `--` را به‌عنوان **آپشن خودش** تفسیر می‌کند، نه نام branch. `--receive-pack=<cmd>` یک آپشن واقعی git push است که سمت «ریموت» را اجرا می‌کند — و برای ریموتِ محلی/file، همان‌جا روی ماشین کاربر اجرا می‌شود.
- **سطوح ورودی آلوده:** `OBS_BRANCH` env (تأیید شد)؛ `BRANCH=` فایل کانفیگ ماشین (خط ۵۹۲، ۷۲۶-۷۲۷) نیز به همان `push_args` می‌رسد.
- **سیناریوی واقعی:** اسکریپت wrapper، فایل `.env` سورس‌شده، Tasker/Termux widget، یا هر جایی که env از منبع نیمه‌قابل‌اعتماد می‌آید. همچنین `git clone --branch "$BRANCH"` در repair (خط ۲۱۴۹) امن است چون value آپشن است، ولی `rebase origin/$BRANCH` هم به‌خاطر پیشوند `origin/` امن است — **تنها نقطه خطرناک push_args است.**
- **اصلاح پیشنهادی (یک نقطه، دو خط):** بعد از load_config_overrides/bind_session_remote (یا دقیقاً قبل از ساخت push_args):
  ```bash
  if ! git check-ref-format --branch "$BRANCH" 2>/dev/null; then
      error "Invalid branch name (unsafe refname): $BRANCH"
      return 1
  fi
  ```
  `git check-ref-format --branch` دقیقاً برای همین ساخته شده: هر نامی که شبیه آپشن باشد را رد می‌کند.

### 🟠 HIGH — `OBS_ATTACH_DIR` با `..` فایل‌ها را **خارج از vault** جابجا می‌کند

- **محل:** `organize_fix_run()` خط ~۴۶۱۹ — `mkdir -p "$VAULT/$ATTACH_DIR"` و `mv "$VAULT/$f" "$VAULT/$ATTACH_DIR/$name"`
- **اثبات (PoC):**
  ```bash
  OBS_ATTACH_DIR="../escaped-attachments" ob-sync organize --fix
  # → orphan.png از vault خارج و به پوشه والد منتقل شد (rc=0، پیام موفقیت!)
  ```
- **چرا خطرناک است:** فایل از دید گیت «حذف‌شده» می‌شود؛ sync بعدی حذفش را commit و push می‌کند و فایل از **همه دستگاه‌های دیگر هم** پاک می‌شود — کلاس از‌دست‌رفتن‌داده از طریق یک اشتباه ساده کاربر (مسیر نسبی/مثل `./Attachments/` یا `..`).
- **اصلاح پیشنهادی:** قبل از اجرا اعتبارسنجی کنید:
  ```bash
  case "$ATTACH_DIR" in
      /*|*..*|"") error "OBS_ATTACH_DIR must be a relative path inside the vault (no .. , no absolute)"; return 1 ;;
  esac
  ```

### 🟡 MEDIUM — vault دارای symlink: بکاپ خودش قابل restore نیست

- **اثبات:** vault با یک symlink → `ob-sync backup` ✅ موفق → `ob-sync restore --dry-run latest` ❌ رد می‌شود («Archive contains a special member (type 'l')»).
- **تحلیل:** رفتار fail-closed عمدی و امن است (ضد tar-slip)، اما **تور ایمنی برای همین کاربر غیرقابل‌استفاده می‌شود** — دقیقاً لحظه‌ای که به آن نیاز است. Git خودش symlink را track می‌کند و sync هم مشکلی ندارد؛ ناهماهنگی بین backup (قبول) و restore (رد) آزاردهنده است.
- **پیشنهاد:** در restore، symlink های «داخل vault» که مقصدشان داخل خود vault است را بازسازی امن کنید (لینک را نه به‌عنوان عضو tar بلکه خودتان بسازید)، یا حداقل در پیام رد، راهنمای دقیق بدهید («vault شما شامل symlink است؛ از --list برای بررسی استفاده کنید»).

### 🟡 MEDIUM — پیام timeout واچداگ شبکه صادقانه نیست

- **اثبات:** با git جعلی که ۳۰۰ ثانیه hang می‌شود و `OBS_GIT_TIMEOUT=3`: بعد از کشتنِ فرآیند، پیام «**Fetch failed — check network connection and credentials**» نمایش داده می‌شود؛ هیچ اشاره‌ای به timeout نیست (rc=124 در `sync_run`/`pull_run`/`push_run` به `fetch_failed`/`push_failed` فرومی‌ریزد).
- **تناقض داخلی:** واچداگ **محلی** (backup/restore/listing) همان rc=124 را به پیام صریح «timed out after Ns — tune OBS_LOCAL_TIMEOUT» نگاشت می‌کند؛ ولی واچداگ **شبکه‌ای** نه. کاربر تلفن‌همراه (سناریوی اصلی پروژه!) با اتصال hang شده بی‌نهایت retry می‌کند بدون اینکه بفهمد واچداگ کارش را کرده و `OBS_GIT_TIMEOUT` قابل تنظیم است.
- **پیشنهاد:** در هر سه نقطه، rc را بگیرید و اگر 124 بود: `error "Fetch timed out after ${GIT_TIMEOUT}s (OBS_GIT_TIMEOUT) — the connection stalled"`.

### 🔵 LOW — ناسازگاری‌های جزئی UX

1. **`history abc`** بی‌سروصدا به پیش‌فرض برمی‌گردد (rc=0) — در حالی که بقیه دستورات fail-closed هستند. (خواندنی و بی‌خطر، ولی ناسازگار با فلسفه پروژه.)
2. **`verify` با sidecar غایب rc=0 می‌دهد** (طبق کامنت کد، رفتار pre-9.0.0 عمدی است) — شاید ارزشش را داشته باشد در JSON حداقل `sidecar:false` برجسته‌تر شود (در JSON الان هست ✅).
3. **doctor در محیط ناقص rc=1 می‌دهد** — درست است (یافته‌ای گزارش می‌کند) ولی مستندات exit-code آن را ذکر نکرده.

---

## ۳. آنچه با موفقیت زیر فشار سنگین پاس شد (نقاط قوت)

### تست‌های سیستمی/کدی (سوئیت جدید D1–D10)
- ✅ **نام‌های فایل خصمانه:** فارسی/RTL، ایموجی، quote، `$()`، backtick، newline واقعی در نام، بایت‌های non-UTF8 (`\xff\xfe`) — sync دوسویه + مقایسه بایت‌به‌بایت بین دو دستگاه کامل صحیح.
- ✅ **JSON purity:** `status/organize/history --json` با نام‌های حاوی quote/backslash/newline/tab/DEL/بایت غیر UTF-8 همگی خروجی **JSON معتبر** تولید کردند (`json_escape` کامل کار می‌کند).
- ✅ **توپولوژی سخت:** تودرتوئی ۸۰ سطحی، فایل باینری ۸MB (مقایسه sha256 در ریموت)، vault ۱۲۰۰ فایلی (sync=۱s، backup<1s)، FIFO در vault (واچداگ ۸ ثانیه‌ای کنترل کرد).
- ✅ **Roundtrip بکاپ↔restore:** ۲۰ فایل با محتوای تصادفی → تخریب عمدی → restore → **تطابق کامل sha256 تک‌تک فایل‌ها + حفظ تاریخچه git** + کپی ایمنی `.pre-restore-*`.
- ✅ **قطع‌شدگی:** `kill -9` وسط بکاپ → لاک کهنه در sync بعدی بازپس‌گیری شد؛ `.part` زباله در بکاپ بعدی جاروب شد؛ `SIGTERM` → لاک آزاد + tempها پاک + sync بعدی سبز.
- ✅ **حالت‌های خراب git:** detached HEAD (رفتار منطقی، بدون نابودی داده)، **rebase واقعی در حالت تعارض** → self-heal کامل در sync بعدی، index خراب (شکست صادقانه بدون صدمه).
- ✅ **آتش سریع:** ۵ sync پشت‌سرهم — همگی سبز (لاک بین اجراها بی‌نقص).
- ✅ **واچداگ:** ریموت hang شده دقیقاً در deadline کشته شد (بدون هنگ).
- ✅ **Retain/tamper:** prune دقیق با `OBS_KEEP_BACKUPS=2`، تشخیص آرشیو دستکاری‌شده و **آرشیو truncated حتی با sidecar سازگار** (چک استریم مستقل کار می‌کند).
- ✅ **ضد tar-slip:** آرشیوهای مخرب با `../` (path traversal)، مسیر مطلق، و عضو symlink — همگی در dry-run و apply رد شدند؛ **هیچ فایلی خارج از vault نوشته نشد.**
- ✅ **ShellCheck:** کل پروژه (۶۸۳۴ خط) فقط **۱ info** (SC2015 در خط ۸۱۵ که الگویش امن است) — نتایج به‌شدت تمیز برای این حجم کد.

### تست‌های خطای انسانی (سوئیت جدید H1–H12)
- ✅ **سوءاستفاده CLI:** ۱۸ حمله (دستور ناشناس، آرگومان اضافی روی sync/backup/verify، flag ناشناس، target شبیه flag برای restore، `--` positional، فلگ‌های تکراری) — همه fail-closed با پیام actionable، **بدون هیچ نویز interpreter**.
- ✅ **Env خراب:** OBS_VAULT=file، OBS_BACKUP_DIR=file، OBS_LOG در مسیر ناموجود (sync بی‌تأثیر سبز)، TMPDIR ناموجود/file → rc=2 صادقانه، vault هرگز صدمه ندید.
- ✅ **کانفیگ شکنجه‌شده:** chmod 000، کانفیگ ۱MB زباله، کلیدهای تکراری (آخرین می‌برد)، BOM — همگی تحمل شدند.
- ✅ **لاک‌گذاری در برابر خرابکاری:** لاکِ file به‌جای dir، pid زباله، pid منفی، pid عظیم، pid مُرده → همه stale-reclaim صحیح؛ pid زنده → stand-down صحیح؛ pid-file به‌صورت directory → محافظت سنی ۵ ثانیه درست کار کرد.
- ✅ **ریموت خصمانه:** تزریق `ext::sh -c ...` (transport injection) — git آن را مسدود کرد و ob-sync هیچ‌جا `protocol.ext.allow` را فعال **نکرد** ✅؛ remote با فاصله در مسیر end-to-end کار کرد؛ env remote هرگز origin برقرار را بی‌صدا re-point نکرد.
- ✅ **ابزارهای حذف‌شده:** PATH بدون tar / بدون git / بدون hash-tool → همگی شکست صادقانه با لیست دقیق ابزارهای missing و hint نصب.
- ✅ **EOF در پرامپت‌ها:** init بدون remote با `</dev/null` → رد صادقانه؛ restore بدون `-y` غیرتعاملی → رد بدون تغییر vault.
- ✅ **Locale/زمان:** LC_ALL=C با نام فارسی، TZ=`Mars/Olympus-Mons`، LC_NUMERIC اعشاریِ کاما — همگی بی‌تأثیر و سبز.
- ✅ **اعداد مرزی:** `OBS_KEEP_BACKUPS=0/1/99999999999999999999`، `OBS_GIT_TIMEOUT` monster — بدون کرش، بدون نویز (bash 5.2 بی‌صدا saturate می‌کند).
- ✅ **هویت vault بین اجراها:** vault حذف‌شده → status هشدار actionable؛ vault=file → sync/repair رد صادقانه؛ vault=symlink → بدون کرش و **بدون نوشتن در مقصد symlink**.
- ✅ **اعتبارسنجی cron:** `%`، newline، ۶-فیلدی، `25:99` — همگی رد شدند (مطابق release notes خودتان).

---

## ۴. فایل‌های تحویلی

| فایل | توضیح |
|------|-------|
| `tests/heavy-system-tests.sh` | سوئیت تست سنگین سیستمی (D1–D10) — ۵۶ بررسی |
| `tests/human-error-attacks.sh` | سوئیت حمله خطای انسانی (H1–H12) — ۹۵ بررسی |
| `TEST-REPORT.md` | همین گزارش |

**اجرا:**
```bash
bash tests/run-tests.sh            # ۳۷۲ بررسی پایه
bash tests/user-error-tests.sh     # ۵۶ بررسی خطای کاربر
bash tests/heavy-system-tests.sh   # ۵۶ بررسی سنگین سیستمی
bash tests/human-error-attacks.sh  # ۹۵ بررسی حمله انسانی
```
هر دو سوئیت جدید self-contained هستند (sandbox یکبار‌مصرف، ریموت محلی، بدون شبکه، بدون روت) و در CI قابل استفاده‌اند. خروجی `FAIL` در human-error-attacks عمداً همان یافته CRITICAL را نگه می‌دارد تا تا اصلاح نشده، رد نشود.

---

## ۵. اولویت‌های اصلاح پیشنهادی

1. **همین امروز:** `git check-ref-format --branch "$BRANCH"` قبل از push_args (بستن CRITICAL با ~۴ خط کد).
2. **همین هفته:** اعتبارسنجی `ATTACH_DIR` (رد کردن `..` و مسیر مطلق).
3. **نسخه بعد:** نگاشت rc=124 → پیام صریح timeout در fetch/push؛ تصمیم‌گیری درباره symlink در restore.
4. **پیشنهاد CI:** اضافه کردن هر ۴ سوئیت به `.github/workflows/lint.yml` تا هر PR این ۵۷۸ بررسی را پاس کند.

---

*تست‌ها روی Linux x86_64، bash 5.2.37، git 2.43، ShellCheck 0.10.0 انجام شد. دو «دستگاه» شبیه‌سازی‌شده با HOME/CONFIG/TMPDIR ایزوله و ریموت‌های bare محلی (بدون شبکه).*

---

## ۶. تأیید مجدد روی v9.6.1 (بازیابی باتری توسعه‌یافته — 2026-10-10)

باتری توسعه‌یافته همین گزارش روی شاخه‌ی جدید `v9.6.1` (که backport سخت‌سازی‌های P1–P8 را در خود دارد) دوباره اجرا شد:

| سوئیت | نتیجه روی v9.6.1 |
|---|---|
| `human-error-attacks.sh` | **PASS=95 FAIL=0 SKIP=0** ✅ |
| `heavy-system-tests.sh` | **PASS=56 FAIL=0 SKIP=0** ✅ (بعد از اصلاح hermetic) |
| PoC-A (تزریق branch) | رد شد؛ دستور اجرا نشد ✅ |
| PoC-B (traversal پیوست‌ها) | رد شد؛ هیچ‌چیز بیرون vault ننوشت ✅ |
| PoC-C (`OBS_LOG=/dev/full`) | خروج فوری، بدون hang ✅ |

**اصلاح hermetic در همین PR:** در D5-C (سناریوی HEAD جنینی)، `git init` بدون پین‌کردن شاخه به پیش‌فرض محیطی وابسته بود (`master` در git استوک، `main` در برخی سندباکس‌ها) و چکِ «محتوا adopt شد» روی یک مسیر میانی لغز می‌شد (rc=0 بدون محتوا). الان `-c init.defaultBranch=main` پین شده است.

**یافته‌های میدانی از همین بازآزمون (برای نسخه‌های بعدی):**
1. ریموت bare بعد از `ob-sync init` همچنان HEAD symref=`master` دارد در حالی که شاخه‌ی واقعی `main` است — `git clone` بعدی با هشدار روبرو می‌شود. پیشنهاد: `git symbolic-ref HEAD refs/heads/main` بعد از اولین push.
2. adopt شدن دستگاه تازه (unborn) وقتی ریموت کارت هویت (`.ob-sync/config`) در تاریخچه دارد → تضاد کارت هویت و توقف صادقانه (rc=1). رفتار درست است، ولی تجربه‌اش می‌تواند بهتر شود: در سناریوی adoption می‌شد نسخه‌ی remote کارت هویت را گرفت (`take theirs`) تا دستگاه جدید بی‌دردسر تاریخچه را به فرزند بیاورد.
3. دستگاه تازه با نام شاخه‌ی محلی متفاوت (master) به‌جای adopt، بی‌سروصدا شاخه‌ی موازی را push می‌کند (rc=0، بدون محتوا) — در v9.6.1 فقط وقتی ریموت کارت هویت دارد صادقانه rc=1 می‌شود؛ حالت «ریموت بدون کارت هویت» همچنان fork خاموش است.
4. **احتیاط اجرای سوئیت‌ها:** تست‌های ۴۲ (self-update) وقتی بیرونِ یک checkout واقعی git اجرا شوند (یعنی `.git` غایب است)، گارد checkout غیرفعال می‌شود و تست «release جدید» می‌تواند `bin/ob-sync` واقعی را با payload آزمایشی جابجا کند (بازتولید و تأیید شد). داخل clone واقعی همه‌چیز محافظت شده است — تأیید نهایی: `run-tests.sh` کامل روی v9.6.1 → **PASS=425 FAIL=0** و `bin/ob-sync` بایت‌به‌بایت دست‌نخورده.
