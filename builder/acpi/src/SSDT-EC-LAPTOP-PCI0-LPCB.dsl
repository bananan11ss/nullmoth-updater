/*
 * A dummy EC device for macOS on a laptop whose embedded controller is not named EC (EC0, H_EC, ECDV …).
 * The real controller keeps working for the battery; this one exists only so macOS finds "EC". Path: \_SB.PCI0.LPCB
 */
DefinitionBlock ("", "SSDT", 2, "NMUPD", "SsdtEC", 0x00001000)
{
    External (_SB_.PCI0.LPCB, DeviceObj)
    Scope (\_SB.PCI0.LPCB)
    {
        Device (EC)
        {
            Name (_HID, "ACID0001")
            Method (_STA, 0, NotSerialized)
            {
                If (_OSI ("Darwin")) { Return (0x0F) }
                Return (Zero)
            }
        }
    }
}
