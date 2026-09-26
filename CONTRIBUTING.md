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
