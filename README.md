# Nothing Phone (4a) Pro Kernel Build System

Its just a wrapper script for bazel so it patches before building.
Also, its AI generated. So my life would be easier.

## Quick build

Run from the repository root:

```sh
tools/bazel run --config=stamp //froggerpro:kernel
tools/bazel run --config=stamp //froggerpro:kernel_ksu
tools/bazel run --config=stamp //froggerpro:kernel_ksun
tools/bazel run --config=stamp //froggerpro:kernel_sukisu
tools/bazel run --config=stamp //froggerpro:kernel_resukisu
```
## Configuration

Signing configuration files are located at:

- `froggerpro/sign.conf`

Signing key what you need to supply:
- `froggerpro/avb_sign_key.key`
When no key is supplied, the testkey_rsa4096.pem will be used from mkbootimg 
