# Droid Peek

Droid Peek puts one paired Android phone in an Omarchy bar panel. Pair over
Wireless debugging, watch the phone through unmodified scrcpy, and use
keyboard shortcuts while the panel is open.

It does not install an Android companion app, and it is not a replacement for
scrcpy.

> [!IMPORTANT]
> The first release supports x86_64 Arch Linux running Omarchy 4, plus one
> Android 16 phone on the same trusted local network. ARM, other Linux
> distributions, earlier Omarchy versions, and Android 14/15 are not supported.

## Install

1. Install the reviewed plugin source:

   ```bash
   omarchy plugin add https://github.com/ollieedgeley/droid-peek.git
   ```

2. Decline Omarchy's enable prompt so you can inspect the checkout first.

3. From the plugin checkout, run explicit setup:

   ```bash
   scripts/setup-droid-peek
   ```

4. Review the planned changes, confirm them, then enable Droid Peek when setup
   verifies successfully.

See [Install and maintain Droid Peek](docs/INSTALL.md) for prerequisites,
Android preparation, updates, and cleanup.

## Pair your phone

Open the Droid Peek icon in the Omarchy bar. On the phone, open **Wireless
debugging**, choose **Pair device with QR code**, and scan the panel. After
that first pairing, opening the panel reconnects to the remembered phone.

## Use and configure

The bar icon opens or closes the panel. Super+Alt+A closes it only while
phone mode is active. While the panel is interactive, pointer input, ordinary typing, and
the toolbar quick actions control the phone.

Setup creates `~/.config/hypr/droid-peek.lua` once. Edit that file to add
Android app bindings or optional scrcpy arguments. Later setup and updates
never overwrite it. See [Configure Droid Peek](docs/CONFIGURATION.md).

## Documentation

- [Install and maintain](docs/INSTALL.md)
- [Configuration](docs/CONFIGURATION.md)
- [How Droid Peek works](docs/ARCHITECTURE.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [Verification](docs/VERIFICATION.md)

## Credit and support

Droid Peek uses [scrcpy](https://github.com/Genymobile/scrcpy) unchanged for
Android mirroring and control.

- [Ollie on X](https://x.com/OllieEdgeley)
- [Support Droid Peek on PayPal](https://www.paypal.com/paypalme/my/profile)

Released under the [MIT License](LICENSE).
