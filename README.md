# evcc Images for Raspberry Pi and other SBCs

[![Built with Depot](https://depot.dev/badges/built-with-depot.svg)](https://depot.dev/?utm_source=evcc)

> **⚠️ Still experimental, feedback welcome!**  
> These images are currently in experimental phase. Please [report any issues](https://github.com/evcc-io/images/issues) or share your feedback to help us improve.

Repository for ready-to-use Debian-based [evcc](https://evcc.io) images for popular single-board computers like Raspberry Pi, Radxa and NanoPi.

## Image contents

- ☀️🚗 [evcc](https://evcc.io) for smart energy management
- 🔒 [Caddy](https://caddyserver.com) reverse proxy for HTTPS
- 🛠️ [Cockpit](https://cockpit-project.org) web console for administration
- 📶 [wifi-connect](https://github.com/balena-os/wifi-connect) for WiFi setup without ethernet
- 🐧 [Armbian](https://www.armbian.com) base image and build system

## Getting Started

1. Download your image file from [releases](https://github.com/evcc-io/images/releases).
2. Flash your image to an SD card using [balenaEtcher](https://www.balena.io/etcher/) or [USBImager](https://gitlab.com/bztsrc/usbimager).
3. Insert your SD card and connect your device with power and ethernet.
4. Navigate to `https://evcc.local/` in your browser. Accept the self-signed certificate.
5. You should see the evcc web interface.
6. Alternatively: Use the [evcc iOS/Android app](http://github.com/evcc-io/app) to connect to your evcc instance.

## Administration

- Login into the [Cockpit](https://cockpit-project.org) web console on `https://evcc.local:9090/`
  - username `admin`
  - password `admin`
- You'll be prompted to change your password. **Remember the new password.** There is no reset.
- You can see system health, update packages and run terminal commands.
- Alternatively: connect via SSH `ssh admin@evcc.local`

## Supported Boards

| Name                                                                                      | Tested | Image Name                                                 | Instructions                                                                                                                                                                                                     |
| ----------------------------------------------------------------------------------------- | ------ | ---------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [Raspberry Pi 5](https://www.raspberrypi.com/products/raspberry-pi-5/)                    | ✅     | [`rpi4b`](https://github.com/evcc-io/images/releases)      | see above                                                                                                                                                                                                        |
| [Raspberry Pi 4](https://www.raspberrypi.com/products/raspberry-pi-4-model-b/)            | ✅     | [`rpi4b`](https://github.com/evcc-io/images/releases)      | see above                                                                                                                                                                                                        |
| [Raspberry Pi 3b](https://www.raspberrypi.com/products/raspberry-pi-3-model-b/)           | ⚠️     | [`rpi4b`](https://github.com/evcc-io/images/releases)      | see above                                                                                                                                                                                                        |
| [NanoPi R3S](https://www.friendlyelec.com/index.php?route=product/product&product_id=311) | ✅     | [`nanopi-r3s`](https://github.com/evcc-io/images/releases) | see above, [then copy to eMMC](https://docs.armbian.com/User-Guide_Getting-Started/#installation)                                                                                                                |
| [Radxa E52C](https://radxa.com/products/network-computer/e52c/)                           | ✅     | [`radxa-e52c`](https://github.com/evcc-io/images/releases) | see above, [then copy to eMMC](https://docs.armbian.com/User-Guide_Getting-Started/#installation)<br/>alternative: [flash directly to eMMC](https://docs.radxa.com/en/e/e52c/getting-started/install-os/maskrom) |

✅ tested<br/>
⚠️ untested (but should work)

## Hardware Recommendations

### Storage

16GB storage should be enough when only using evcc.
We recommend running your system from eMMC instead of SD card.
**Radxa and NanoPi boards come with built-in eMMC storage.**
If you decide to run your system directly from SD card, be sure to read [Armbian's recommendations](https://docs.armbian.com/User-Guide_Getting-Started/#armbian-getting-started-guide) first.

### CPU and RAM

All above boards have plenty of CPU and RAM for evcc.
1GB RAM should be enough.
Pick 2GB if you want to be on the safe side.

## Network Recommendations

For reliability we **strongly suggest** using a **wired ethernet connection**.

### Wireless Setup

If a wired setup is not possible, this image includes an automatic wireless configuration system.
The device will create a WiFi setup hotspot (`evcc-setup`) whenever no network connection is available.

1. Power your device
2. Wait a moment for the device to detect no network connection
3. Connect to `evcc-setup` network from your phone or laptop
4. A captive portal will open automatically (or browse to any website)
5. Select your WiFi network and enter the password
6. The device will connect to your network and the setup hotspot will disappear
7. Connect back to your home network
8. Continue with step 4 from [Getting Started](#getting-started)

**Note**: The `evcc-setup` hotspot will automatically appear whenever the device loses network connectivity, making it easy to reconfigure WiFi at a new location or recover from network issues.

For ethernet-only boards like the Radxa and NanoPi, you can use WiFi USB dongles. The following adapters have been tested successfully:

- EDUP EP-B8508GS
- _add your's here ..._

## Contributing

- [Report issues](https://github.com/evcc-io/images/issues)
- [Submit pull requests](https://github.com/evcc-io/images/pulls)

## License

- [MIT](LICENSE)

## Thanks 💚

Huge thanks to the [Armbian](https://www.armbian.com) project for making building these images easy!
They also accept [donations](https://www.armbian.com/donate/). Wink wink.
