# GlassDock

GlassDock показывает обои за строкой меню и между значками нижнего Dock. В окне приложения два отдельных переключателя. Можно включить один эффект, оба или выключить их в любой момент.

**[Скачать GlassDock для Mac (.dmg)](https://github.com/vjachikslavny-crypto/glassdock/releases/latest/download/GlassDock.dmg)** · [Все версии и контрольные суммы](https://github.com/vjachikslavny-crypto/glassdock/releases)

### Установка

1. Открой образ и перетащи **GlassDock** в **Программы**.
2. Запусти GlassDock и включи «Строка меню», «Dock» или оба переключателя.
3. При первом включении macOS может запросить разрешение для выбранного компонента. Для восстановления выбора после перезагрузки включи «Запускать выбранные эффекты при входе».

Публичная сборка 0.1.0 выпускается без нотарификации Apple. При предупреждении о неизвестном разработчике macOS позволяет подтвердить запуск конкретного приложения в разделе «Конфиденциальность и безопасность». [Инструкция Apple](https://support.apple.com/ru-ru/102445)

### Совместимость и разрешения

- Образ содержит версии для **Apple Silicon и Intel**. Проверено на Apple Silicon с macOS 15.6.1 Sequoia. На Intel проверена сборка. Минимальная версия macOS — 15.0.
- **Верхняя строка** работает через Sheer 1.3.1. Ему нужен «Универсальный доступ». Для живых обоев macOS также запрашивает доступ к записи экрана. На macOS 26 и новее верхняя строка уже поддерживает прозрачность. [Sheer](https://github.com/AzurLiu/sheer)
- **Нижний Dock** рассчитан на нижний край основного экрана. GlassDock Dock читает нижние полосы двух системных окон, с Dock и с обоями. Для этого macOS требует разрешение «Запись экрана и системного звука». Звук отключён, изображения обрабатываются в памяти. При одинаковых кадрах фон не перерисовывается. Когда за Dock заходит окно, появляется штатная подложка.
- При первом включении контроллер использует уже установленный компонент или создаёт его копию в `~/Library/Application Support/GlassDock/Helpers`. Закрытие окна GlassDock оставляет запущенные эффекты на экране. Чтобы убрать их, снова открой GlassDock и выключи переключатели.

### Build from source

On macOS with Xcode Command Line Tools and the macOS 15 SDK or later, run `bash build.sh`. The universal disk image and its SHA-256 checksum appear in `build/`.

The build fetches the official, version-pinned Sheer archive, verifies its checksum and signature, and preserves its license with the bundled application. To build offline, set `SHEER_RELEASE_ZIP` to a copy of the same archive. [Sheer license](upper/LICENSE.Sheer)
