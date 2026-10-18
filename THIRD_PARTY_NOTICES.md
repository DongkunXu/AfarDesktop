# Third-party software

Afar Desktop includes the following software, built from source by `scripts/build-deps.sh`
at the versions pinned in `Vendor/versions.env` and linked statically into the app.

## FreeRDP

- Project: https://www.freerdp.com, https://github.com/FreeRDP/FreeRDP
- License: Apache License 2.0 (the same text as this repository's `LICENSE`)
- Copyright: the FreeRDP contributors

FreeRDP provides the RDP protocol, security negotiation, codecs and virtual channels
(display control, graphics pipeline, clipboard, audio). Afar Desktop modifies it with the
patches in `Vendor/patches/`, which add a VideoToolbox H.264 decoder
(`libfreerdp/codec/h264_videotoolbox.c`); the patches are under the same license.

## OpenSSL

- Project: https://www.openssl.org
- License: Apache License 2.0 (the same text as this repository's `LICENSE`)
- Copyright: The OpenSSL Project Authors

OpenSSL provides TLS and the cryptography FreeRDP relies on.

## Background pictures

The pictures in `Resources/Backgrounds/` are photographs from [Unsplash](https://unsplash.com),
used under the [Unsplash License](https://unsplash.com/license): free to use, attribution not
required. They were scaled down and their metadata removed. With thanks to the photographers:

1. Adrianna Geo
2. Cristina Gottardi
3. Anders Jildén
4. NASA
5. Milad Fakurian
6. Shigeki Wakabayashi
7. BoliviaInteligente
8. Anders Jildén
9. Vadim Sherbakov

These pictures are not covered by this repository's Apache License.
