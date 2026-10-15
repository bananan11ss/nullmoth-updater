# SSDT для сборщика EFI

`aml/` — скомпилированные таблицы, их кладёт в сборку вкладка «Сборка EFI»; `src/` — исходники.

| Таблица | Когда ставится | Происхождение |
|---|---|---|
| `SSDT-PLUG-ALT` | процессоры объявлены как Device (`ACPI0007`), Alder Lake и новее | OpenCorePkg AcpiSamples |
| `SSDT-PLUG` | процессоры объявлены как `Processor()` | OpenCorePkg AcpiSamples |
| `SSDT-EC-LAPTOP-<корень>-<LPC>` | ноутбук без устройства `EC`, видимого macOS; в сборке называется `SSDT-EC.aml` | свой |
| `SSDT-USBX` | всегда | свой (половина USBX из `SSDT-EC-USBX`) |
| `SSDT-AWAC-DISABLE` | есть часы `AWAC` (`ACPI000E`) | OpenCorePkg AcpiSamples |
| `SSDT-SBUS-MCHC-<корень>` | есть `SBUS`, нет `MCHC` | OpenCorePkg AcpiSamples, путь заменён |
| `SSDT-PNLF` | ноутбук с работающей встроенной графикой Intel до 11-го поколения | OpenCorePkg AcpiSamples |
| `SSDT-ALS0` | не используется сборщиком сейчас | OpenCorePkg AcpiSamples |

Пересобрать: `iasl` из [MaciASL](https://github.com/acidanthera/MaciASL) (`MaciASL.app/Contents/MacOS/iasl-stable`),
`iasl -p aml/<имя> src/<имя>.dsl`.

Образцы OpenCorePkg: Copyright (c) 2019-2026 acidanthera, лицензия BSD-3-Clause
(https://github.com/acidanthera/OpenCorePkg/blob/master/LICENSE.txt).
