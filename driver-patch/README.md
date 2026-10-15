# driver-patch

Исправления драйвера [NullMoth NVIDIA](https://github.com/nullmoth/nvidia-macos-driver) **2.0.0** (тег `v2.0.0`).

| Файл | Что это |
|---|---|
| `FIXES.patch` | все изменения относительно v2.0.0 (`patch -p1` в корне исходников драйвера) |
| `FIXES.md` | что исправлено, как проверено, что не проверено |
| `NVMTLDriver` | собранный исправленный Metal-плагин (release, x86_64, подпись ad-hoc) |
| `tools/` | тестовый стенд: грузит плагин в отдельный процесс, в систему ничего не ставит |

Кексты в патче **не собраны и не проверены** на реальной загрузке. Подробности в `FIXES.md`.

Лицензия: [PolyForm Noncommercial 1.0.0](LICENSE-PolyForm-Noncommercial.md), как у драйвера. Только
некоммерческое использование. Required Notice: Copyright (c) 2026 NullMoth Systems (https://nullmothsystems.com).
