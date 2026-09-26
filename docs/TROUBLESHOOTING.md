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
